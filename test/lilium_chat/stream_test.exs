defmodule LiliumChat.StreamTest do
  @moduledoc """
  `Stream.<channel_id>#<message_id>` process (contract §9.15, issue #18).

  Acceptance:

  * append / finalize + seq/ack frames (A5)
  * finalize is idempotent (same hash → same result)
  * `ack_seq` (durable flush) is separate from `received_seq` (connection)
  """

  use LiliumChat.DataCase, async: false

  import LiliumChatWeb.ReadFixtures

  alias LiliumChat.{Errors, Query, Repo, Stream}

  @channel "ch-stream-0001"
  @bot "bot-stream-0001"
  @mid "msg-stream-0001"

  setup do
    seed_channel(@channel)
    kill_stream!(@channel, @mid)

    on_exit(fn -> kill_stream!(@channel, @mid) end)

    :ok
  end

  defp start!(mid \\ @mid) do
    {:ok, handle} =
      Stream.start_stream(@channel, mid, @bot, %{"type" => "text", "format" => "plain"})

    handle
  end

  defp kill_stream!(channel_id, message_id) do
    Enum.each(1..40, fn _ ->
      case Registry.lookup(LiliumChat.Streams.Registry, {channel_id, message_id}) do
        [] ->
          :ok

        [{pid, _}] ->
          Process.exit(pid, :kill)
          Process.sleep(5)
      end
    end)

    :ok
  end

  # --------------------------------------------------------------- start

  test "start_stream returns the Stream WS handle and does not insert a message" do
    handle = start!()

    assert handle["channel_id"] == @channel
    assert handle["message_id"] == @mid
    assert handle["ws_url"] == "/api/chat/bot/channels/#{@channel}/streams/#{@mid}/ws"
    assert {:ok, %DateTime{}, _} = DateTime.from_iso8601(handle["expires_at"])

    rows =
      Query.rows(
        Repo.query("SELECT 1 FROM chat_v2.messages WHERE message_id = $1", [@mid], type: true)
      )

    assert rows == []
  end

  test "attach returns ready fields with ack_seq and resets received_seq" do
    start!()
    {:ok, :accepted} = Stream.append(@channel, @mid, 1, "a")

    state = Stream.debug_state(@channel, @mid)
    assert state.received_seq == 1
    assert state.ack_seq == 0

    assert {:ok, ready} = Stream.attach(@channel, @mid, self())
    assert ready.ack_seq == 0
    assert ready.channel_id == @channel
    assert ready.message_id == @mid

    # Rehydrate: received_seq falls back to ack_seq (contract §9.15.3).
    state = Stream.debug_state(@channel, @mid)
    assert state.received_seq == 0
    assert state.ack_seq == 0
  end

  # --------------------------------------------------------------- seq/ack

  test "ack_seq / received_seq separation: accept, gap, unacked dup, durable no-op" do
    start!()
    Stream.attach(@channel, @mid, self())

    assert {:ok, :accepted} = Stream.append(@channel, @mid, 1, "Hel")
    state = Stream.debug_state(@channel, @mid)
    assert state.received_seq == 1
    assert state.ack_seq == 0
    assert state.flushed_text == ""

    # Same seq + same delta: unacked duplicate (no error, no re-accept).
    assert {:ok, :unacked_duplicate} = Stream.append(@channel, @mid, 1, "Hel")

    # Same seq + different delta: conflict.
    assert {:error, %Errors.ApiError{code: "BOT_STREAM_CONFLICT"}} =
             Stream.append(@channel, @mid, 1, "XXX")

    # Gap vs received_seq (not ack_seq).
    assert {:error, %Errors.ApiError{code: "BOT_STREAM_SEQUENCE_GAP", retryable: true}} =
             Stream.append(@channel, @mid, 3, "lo")

    assert {:ok, :accepted} = Stream.append(@channel, @mid, 2, "lo")

    {:ok, ack_seq} = Stream.flush(@channel, @mid)
    assert ack_seq == 2

    state = Stream.debug_state(@channel, @mid)
    assert state.ack_seq == 2
    assert state.received_seq == 2
    assert state.flushed_text == "Hello"

    # seq <= ack_seq is a durable no-op (returns current ack).
    assert {:ok, {:durable_noop, 2}} = Stream.append(@channel, @mid, 1, "Hel")
    assert {:ok, {:durable_noop, 2}} = Stream.append(@channel, @mid, 2, "lo")
  end

  test "start_stream / append / empty abandon emit live-only stream_event frames" do
    Phoenix.PubSub.subscribe(LiliumChat.PubSub, "channel:#{@channel}")

    start!()
    Stream.broadcast_started(@channel, @mid)

    assert_receive {:broadcast, _,
                    %{
                      "frame_type" => "stream_event",
                      "type" => "message.stream_started",
                      "channel_id" => @channel
                    }}

    Stream.attach(@channel, @mid, self())
    {:ok, :accepted} = Stream.append(@channel, @mid, 1, "x")
    # Force the fanout cadence.
    send(pid_of!(@channel, @mid), :fanout_due)

    assert_receive {:broadcast, _,
                    %{
                      "frame_type" => "stream_event",
                      "type" => "message.stream_delta",
                      "payload" => %{"delta" => "x"}
                    }}

    # Drop the unflushed pending so abandon is empty/live-only.
    Stream.attach(@channel, @mid, self())
    {:ok, :cleanup} = Stream.abandon(@channel, @mid)

    assert_receive {:broadcast, _,
                    %{
                      "frame_type" => "stream_event",
                      "type" => "message.stream_abandon_cleanup"
                    }}
  end

  defp pid_of!(channel_id, message_id) do
    [{pid, _}] = Registry.lookup(LiliumChat.Streams.Registry, {channel_id, message_id})
    pid
  end

  test "flush emits append_ack to the attached channel pid" do
    start!()
    Stream.attach(@channel, @mid, self())
    {:ok, :accepted} = Stream.append(@channel, @mid, 1, "x")

    {:ok, 1} = Stream.flush(@channel, @mid)

    assert_receive {:stream_push, %{"type" => "append_ack", "ack_seq" => 1}}
  end

  # --------------------------------------------------------------- finalize

  test "finalize writes canonical message + stream_finalized and is idempotent" do
    start!()
    Stream.attach(@channel, @mid, self())
    {:ok, :accepted} = Stream.append(@channel, @mid, 1, "Hello")
    {:ok, :accepted} = Stream.append(@channel, @mid, 2, " world")

    assert {:ok, first} = Stream.finalize(@channel, @mid, %{"final_seq" => 2})
    assert first["message_id"] == @mid
    assert is_binary(first["event_id"])

    rows =
      Query.rows(
        Repo.query(
          "SELECT stream_state, status, text FROM chat_v2.messages WHERE message_id = $1",
          [@mid],
          type: true
        )
      )

    assert [%{"stream_state" => "final", "status" => "normal", "text" => "Hello world"}] = rows

    events =
      Query.rows(
        Repo.query(
          "SELECT event_type FROM chat_v2.events WHERE event_id = $1",
          [first["event_id"]],
          type: true
        )
      )

    assert [%{"event_type" => "message.stream_finalized"}] = events

    # Repeat finalize with the same request → same result.
    assert {:ok, replay} = Stream.finalize(@channel, @mid, %{"final_seq" => 2})
    assert replay == first

    # Different request hash (different final_seq) → conflict.
    assert {:error, %Errors.ApiError{code: "BOT_STREAM_CONFLICT"}} =
             Stream.finalize(@channel, @mid, %{"final_seq" => 1})
  end

  test "finalize remains idempotent after the Stream process is killed" do
    start!()
    Stream.attach(@channel, @mid, self())
    {:ok, :accepted} = Stream.append(@channel, @mid, 1, "crash-ok")
    assert {:ok, first} = Stream.finalize(@channel, @mid, %{"final_seq" => 1})

    kill_stream!(@channel, @mid)
    assert Registry.lookup(LiliumChat.Streams.Registry, {@channel, @mid}) == []

    assert {:ok, replay} = Stream.finalize(@channel, @mid, %{"final_seq" => 1})
    assert replay == first
  end

  test "finalize rejects sequence gap, behind received, components, attachment_ids" do
    start!()
    Stream.attach(@channel, @mid, self())
    {:ok, :accepted} = Stream.append(@channel, @mid, 1, "a")

    assert {:error, %Errors.ApiError{code: "BOT_STREAM_SEQUENCE_GAP"}} =
             Stream.finalize(@channel, @mid, %{"final_seq" => 2})

    {:ok, :accepted} = Stream.append(@channel, @mid, 2, "b")

    assert {:error, %Errors.ApiError{code: "BOT_STREAM_CONFLICT"}} =
             Stream.finalize(@channel, @mid, %{"final_seq" => 1})

    assert {:error, %Errors.ApiError{code: "BOT_EFFECT_INVALID"}} =
             Stream.finalize(@channel, @mid, %{
               "final_seq" => 2,
               "components" => [%{"type" => "button"}]
             })

    assert {:error, %Errors.ApiError{code: "BOT_EFFECT_INVALID"}} =
             Stream.finalize(@channel, @mid, %{
               "final_seq" => 2,
               "attachment_ids" => ["att-1"]
             })

    # Still streaming — a clean finalize succeeds.
    assert {:ok, _} = Stream.finalize(@channel, @mid, %{"final_seq" => 2})
  end

  # --------------------------------------------------------------- abandon

  test "empty abandon is live-only cleanup (no message / event)" do
    start!()
    Stream.attach(@channel, @mid, self())

    assert {:ok, :cleanup} = Stream.abandon(@channel, @mid)

    rows =
      Query.rows(
        Repo.query("SELECT 1 FROM chat_v2.messages WHERE message_id = $1", [@mid], type: true)
      )

    assert rows == []

    events =
      Query.rows(
        Repo.query(
          "SELECT 1 FROM chat_v2.events WHERE channel_id = $1 AND event_type = 'message.stream_abandoned'",
          [@channel],
          type: true
        )
      )

    assert events == []

    state = Stream.debug_state(@channel, @mid)
    assert state.status == :abandoned

    # Repeated empty cleanup is a no-op.
    assert {:ok, :cleanup} = Stream.abandon(@channel, @mid)
  end

  test "non-empty abandon writes failed/abandoned message + canonical event" do
    start!()
    Stream.attach(@channel, @mid, self())
    {:ok, :accepted} = Stream.append(@channel, @mid, 1, "partial")
    {:ok, _} = Stream.flush(@channel, @mid)

    assert {:ok, %{"message_id" => @mid, "event_id" => event_id}} = Stream.abandon(@channel, @mid)

    rows =
      Query.rows(
        Repo.query(
          "SELECT stream_state, status, text FROM chat_v2.messages WHERE message_id = $1",
          [@mid],
          type: true
        )
      )

    assert [%{"stream_state" => "abandoned", "status" => "failed", "text" => "partial"}] = rows

    events =
      Query.rows(
        Repo.query("SELECT event_type FROM chat_v2.events WHERE event_id = $1", [event_id],
          type: true
        )
      )

    assert [%{"event_type" => "message.stream_abandoned"}] = events

    # Idempotent same-hash abandon.
    assert {:ok, %{"event_id" => ^event_id}} = Stream.abandon(@channel, @mid)

    # Finalize after abandon is rejected.
    assert {:error, %Errors.ApiError{code: "BOT_STREAM_EXPIRED"}} =
             Stream.finalize(@channel, @mid, %{"final_seq" => 1})
  end

  test "unknown stream → BOT_STREAM_NOT_FOUND" do
    assert {:error, %Errors.ApiError{code: "BOT_STREAM_NOT_FOUND"}} =
             Stream.append(@channel, "no-such", 1, "x")
  end
end
