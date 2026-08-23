defmodule LiliumChat.ReadStateTest do
  @moduledoc """
  `channel.mark_read` write-path tests (issue #10, contract §5.5).

  Process-level tests against `LiliumChat.ReadState.mark_read/4`: ack shape,
  monotonic "return stored" semantics, unread-count semantics (old Worker
  `getUnreadCount`), membership gate, and the multi-session
  `read_state_updated` broadcast (other sessions only).
  """

  use LiliumChat.DataCase, async: false

  import LiliumChatWeb.ReadFixtures

  alias LiliumChat.{Query, ReadState, Repo}

  @uid "6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e6f"
  @other "7a2f3d4e-5b6c-8d9e-0f1a-2b3c4d5e6f70"

  # ----------------------------------------------------------------- helpers

  defp channel! do
    cid = "ch-rs-" <> Ecto.UUID.generate()
    seed_channel(cid, kind: "channel", visibility: "private", status: "active")
    seed_membership(cid, @uid, "member")
    cid
  end

  defp mark_read!(channel_id, command_id, last_read_event_id) do
    ReadState.mark_read(@uid, command_id, channel_id, %{
      "last_read_event_id" => last_read_event_id
    })
  end

  defp stored_cursor(channel_id) do
    Query.rows(
      Repo.query(
        "SELECT last_read_event_id, updated_at FROM chat_v2.read_state WHERE user_id = $1 AND channel_id = $2",
        [@uid, channel_id]
      )
    )
    |> List.first()
  end

  # -------------------------------------------------------------- AC: shape

  test "mark_read → committed ack {channel_id, last_read_event_id, unread_count}; row created" do
    cid = channel!()

    {:ok, ack} = mark_read!(cid, "cmd-rs-001", eid(3))

    assert ack["frame_type"] == "command_ack"
    assert ack["command"] == "channel.mark_read"
    assert ack["command_id"] == "cmd-rs-001"
    assert ack["status"] == "committed"
    assert ack["payload"]["channel_id"] == cid
    assert ack["payload"]["last_read_event_id"] == eid(3)
    assert ack["payload"]["unread_count"] == 0

    cursor = stored_cursor(cid)
    assert cursor["last_read_event_id"] == eid(3)
  end

  test "no timeline event is written for mark_read (contract §5.5)" do
    cid = channel!()
    seed_message("msg-rs-001", cid, @other, "hello", event_id: eid(1))

    {:ok, _} = mark_read!(cid, "cmd-rs-002", eid(1))

    types =
      Query.rows(Repo.query("SELECT event_type FROM chat_v2.events WHERE channel_id = $1", [cid]))
      |> Enum.map(& &1["event_type"])

    refute "channel.mark_read" in types
    assert types == ["message.created"]
  end

  # ------------------------------------------------- AC: monotonic cursor

  test "monotonic: newer cursor advances; same/older cursor returns stored, no error, no write" do
    cid = channel!()
    seed_message("msg-rs-003", cid, @other, "a", event_id: eid(1))
    seed_message("msg-rs-004", cid, @other, "b", event_id: eid(2))

    {:ok, ack1} = mark_read!(cid, "cmd-rs-003", eid(2))
    assert ack1["payload"]["last_read_event_id"] == eid(2)
    assert ack1["payload"]["unread_count"] == 0

    # same cursor → "return stored", still committed
    {:ok, ack2} = mark_read!(cid, "cmd-rs-004", eid(2))
    assert ack2["payload"]["last_read_event_id"] == eid(2)

    # OLDER cursor → the stored (newer) value is returned, not the request
    {:ok, ack3} = mark_read!(cid, "cmd-rs-005", eid(1))
    assert ack3["payload"]["last_read_event_id"] == eid(2)

    cursor = stored_cursor(cid)
    assert cursor["last_read_event_id"] == eid(2)
  end

  test "concurrent first mark_reads: no double-INSERT, stored cursor is the max" do
    cid = channel!()

    # Two sessions racing the FIRST mark_read for the same (user, channel).
    # Before the atomic GREATEST upsert this was a read-modify-write: one side
    # could hit the PK (double INSERT) or a lost update.
    results =
      for cursor <- [eid(1), eid(2)] do
        Task.async(fn ->
          ReadState.mark_read(@uid, "cmd-rs-race-#{cursor}", cid, %{
            "last_read_event_id" => cursor
          })
        end)
      end
      |> Enum.map(&Task.await(&1, 3_000))

    for {:ok, ack} <- results do
      assert ack["payload"]["channel_id"] == cid
      assert ack["payload"]["last_read_event_id"] in [eid(1), eid(2)]
    end

    # the upsert is monotonic: the stored cursor is the MAX of the races
    stored = stored_cursor(cid)
    assert stored["last_read_event_id"] == eid(2)
  end

  # ---------------------------------------------------- AC: unread_count

  test "unread_count counts message.created after the stored cursor, excluding own messages" do
    cid = channel!()

    # 2 messages by another + 1 by the caller
    seed_message("msg-rs-101", cid, @other, "1", event_id: eid(1))
    seed_message("msg-rs-102", cid, @other, "2", event_id: eid(2))
    seed_message("msg-rs-103", cid, @uid, "mine", event_id: eid(3))

    # advance to eid(1): after-cursor events are eid(2) + eid(3); my own
    # (eid(3)) is excluded → 1 unread
    {:ok, ack} = mark_read!(cid, "cmd-rs-101", eid(1))
    assert ack["payload"]["unread_count"] == 1

    # same cursor again (no advance): still counts after the stored cursor
    {:ok, ack2} = mark_read!(cid, "cmd-rs-102", eid(1))
    assert ack2["payload"]["last_read_event_id"] == eid(1)
    assert ack2["payload"]["unread_count"] == 1

    # advance to eid(3) → 0 unread
    {:ok, ack3} = mark_read!(cid, "cmd-rs-103", eid(3))
    assert ack3["payload"]["unread_count"] == 0
  end

  # ------------------------------------------------------------- gates

  test "non-member → FORBIDDEN 'not an active member'" do
    cid = "ch-rs-nm"
    seed_channel(cid, kind: "channel", visibility: "private", status: "active")
    seed_membership(cid, @other, "member")

    assert {:error,
            %LiliumChat.Errors.ApiError{code: "FORBIDDEN", message: "not an active member"}} =
             mark_read!(cid, "cmd-rs-201", eid(1))
  end

  test "missing/blank last_read_event_id → INVALID_MESSAGE" do
    cid = channel!()

    assert {:error,
            %LiliumChat.Errors.ApiError{
              code: "INVALID_MESSAGE",
              message: "last_read_event_id required"
            }} =
             ReadState.mark_read(@uid, "cmd-rs-202", cid, %{})

    assert {:error, %LiliumChat.Errors.ApiError{code: "INVALID_MESSAGE"}} =
             ReadState.mark_read(@uid, "cmd-rs-203", cid, %{"last_read_event_id" => ""})
  end

  # ------------------------------------------------- AC: multi-session

  test "advance → read_state_updated to the user's OTHER sessions, not the sender" do
    cid = channel!()
    topic = "user:#{@uid}"

    parent = self()

    # A stand-in for the user's other live session.
    other_session =
      Task.async(fn ->
        Phoenix.PubSub.subscribe(LiliumChat.PubSub, topic)
        send(parent, :other_ready)

        receive do
          :go -> :going
        end

        receive do
          {:broadcast_user, ^topic, frame, _sender} ->
            frame
        after
          2_000 -> :timeout
        end
      end)

    assert_receive :other_ready, 2_000

    # The sender session: a separate process that — like the browser socket —
    # calls mark_read (so self() IS the broadcast sender) and applies the
    # `sender_pid == self()` exclusion before "pushing" to the client.
    # It reports whether it would have pushed the hint.
    sender_session =
      Task.async(fn ->
        Phoenix.PubSub.subscribe(LiliumChat.PubSub, topic)

        receive do
          {:mark_read, channel_id, command_id, cursor} ->
            result =
              ReadState.mark_read(@uid, command_id, channel_id, %{"last_read_event_id" => cursor})

            receive do
              {:broadcast_user, ^topic, frame, sender_pid} ->
                # the socket's exclusion rule
                {result, if(sender_pid == self(), do: :excluded, else: {:delivered, frame})}
            after
              500 -> {result, :no_broadcast}
            end
        end
      end)

    send(other_session.pid, :go)
    send(sender_session.pid, {:mark_read, cid, "cmd-rs-301", eid(5)})
    {{:ok, ack}, exclusion} = Task.await(sender_session, 3_000)

    assert ack["payload"]["last_read_event_id"] == eid(5)
    assert ack["payload"]["unread_count"] == 0

    # the sender session is excluded (it already received the ack)
    assert exclusion == :excluded

    # the other session receives the hint
    frame = Task.await(other_session, 2_000)
    assert frame["frame_type"] == "read_state_updated"
    assert frame["channel_id"] == cid
    assert frame["last_read_event_id"] == eid(5)
    assert frame["unread_count"] == 0
  end

  test "same/older cursor (no advance) → NO read_state_updated broadcast" do
    cid = channel!()
    {:ok, _} = mark_read!(cid, "cmd-rs-302", eid(1))

    parent = self()

    other_session =
      Task.async(fn ->
        Phoenix.PubSub.subscribe(LiliumChat.PubSub, "user:#{@uid}")

        receive do
          {:broadcast_user, _, frame, _} ->
            send(parent, {:got, frame})
            frame
        after
          300 -> :none
        end
      end)

    # no advance → no broadcast
    {:ok, ack} = mark_read!(cid, "cmd-rs-303", eid(1))
    assert ack["payload"]["last_read_event_id"] == eid(1)

    assert Task.await(other_session, 2_000) == :none
  end
end
