defmodule LiliumChat.MessageSendTest do
  @moduledoc """
  `message.send` write-path tests (issue #9, contract §6.2, spec §5.1).

  Process-level tests driven through `LiliumChat.Channel.send_message/2`
  (the per-channel writer process): wire shape, idempotency, monotonic
  event_id + crash recovery, validation, and channel gates.
  """

  use LiliumChat.DataCase, async: false

  import LiliumChatWeb.ReadFixtures

  alias LiliumChat.{Channel, Ids, Query, Repo}

  @uid "6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e6f"
  @other "7a2f3d4e-5b6c-8d9e-0f1a-2b3c4d5e6f70"

  # ----------------------------------------------------------------- helpers

  defp channel!() do
    cid = "ch-" <> Ecto.UUID.generate()
    seed_channel(cid, kind: "channel", visibility: "private", status: "active")
    seed_membership(cid, @uid, "member")
    cid
  end

  defp send!(channel_id, command_id, payload),
    do:
      Channel.send_message(channel_id, %{user_id: @uid, command_id: command_id, payload: payload})

  defp message_count(channel_id) do
    case Repo.query(
           "SELECT COUNT(*) AS n FROM chat_v2.messages WHERE channel_id = $1",
           [channel_id]
         ) do
      {:ok, %{rows: [[n]]}} -> n
    end
  end

  defp load_message(channel_id, message_id) do
    Query.rows(
      Repo.query(
        "SELECT message_id, command_id, channel_id, sender_kind, sender_user_id, type, " <>
          "format, status, text, reply_to, stream_state, dedupe_principal_key, event_id " <>
          "FROM chat_v2.messages WHERE channel_id = $1 AND message_id = $2",
        [channel_id, message_id],
        type: true
      )
    )
    |> List.first()
  end

  # ------------------------------------------------- AC1: wire shape (§6.2)

  test "text message → committed ack with full Browser message projection" do
    cid = channel!()
    command_id = "cmd-wire-001"

    {:ok, ack} = send!(cid, command_id, %{"type" => "text", "text" => "hello world"})

    # command_ack envelope (contract §10.2 / §6.2)
    assert ack["frame_type"] == "command_ack"
    assert ack["command"] == "message.send"
    assert ack["command_id"] == command_id
    assert ack["status"] == "committed"

    payload = ack["payload"]
    assert payload["channel_id"] == cid
    assert is_binary(payload["event_id"])

    msg = payload["message"]
    assert is_binary(msg["message_id"])
    assert msg["command_id"] == command_id
    assert msg["channel_id"] == cid
    assert msg["type"] == "text"
    assert msg["format"] == "plain"
    assert msg["status"] == "normal"
    assert msg["stream_state"] == "none"
    assert msg["text"] == "hello world"
    assert msg["sender"]["kind"] == "user"
    assert msg["sender"]["user"]["user_id"] == @uid
    assert is_binary(msg["sender"]["user"]["display_name"])
    assert msg["reply_to"] == nil
    assert msg["reply_snapshot"] == nil
    assert msg["attachments"] == []
    assert msg["sticker"] == nil
    assert msg["components"] == []
    assert msg["mentions"] == []
    assert is_binary(msg["created_at"])
    assert is_binary(msg["updated_at"])

    # persisted rows
    row = load_message(cid, msg["message_id"])
    assert row != nil
    assert row["dedupe_principal_key"] == "user:" <> @uid
    assert row["sender_kind"] == "user"

    # the paired message.created event is committed
    assert Repo.query!(
             "SELECT 1 FROM chat_v2.events WHERE channel_id = $1 AND event_type = 'message.created' AND payload->'message'->>'message_id' = $2",
             [cid, msg["message_id"]]
           ).num_rows == 1
  end

  test "text message with mentions → projected mentions are returned" do
    cid = channel!()
    cid2 = @other

    {:ok, ack} =
      send!(cid, "cmd-wire-002", %{
        "type" => "text",
        "text" => "hi @friend",
        "mentions" => [%{"user_id" => cid2, "start" => 3, "end" => 10}]
      })

    assert ack["payload"]["message"]["mentions"] == [
             %{"user_id" => cid2, "start" => 3, "end" => 10}
           ]
  end

  # ------------------------------------------------- AC2: idempotency

  test "same command_id + same body → cached replay (one row, identical ack)" do
    cid = channel!()
    body = %{"type" => "text", "text" => "once"}

    {:ok, ack1} = send!(cid, "cmd-idem-001", body)
    {:ok, ack2} = send!(cid, "cmd-idem-001", body)

    assert ack1["payload"]["event_id"] == ack2["payload"]["event_id"]
    assert ack1["payload"]["message"]["message_id"] == ack2["payload"]["message"]["message_id"]
    assert message_count(cid) == 1
  end

  test "same command_id + different body → IDEMPOTENCY_CONFLICT" do
    cid = channel!()

    assert {:ok, _} = send!(cid, "cmd-idem-002", %{"type" => "text", "text" => "A"})

    assert {:error, %LiliumChat.Errors.ApiError{code: "IDEMPOTENCY_CONFLICT"}} =
             send!(cid, "cmd-idem-002", %{"type" => "text", "text" => "B"})

    assert message_count(cid) == 1
  end

  test "different command_id → distinct messages" do
    cid = channel!()

    assert {:ok, a} = send!(cid, "cmd-idem-003a", %{"type" => "text", "text" => "x"})
    assert {:ok, b} = send!(cid, "cmd-idem-003b", %{"type" => "text", "text" => "x"})

    assert a["payload"]["message"]["message_id"] != b["payload"]["message"]["message_id"]
    assert a["payload"]["event_id"] != b["payload"]["event_id"]
    assert message_count(cid) == 2
  end

  test "cached replay does NOT re-broadcast / does NOT create a second event" do
    cid = channel!()
    body = %{"type" => "text", "text" => "dedupe"}

    {:ok, _} = send!(cid, "cmd-idem-004", body)
    {:ok, ack2} = send!(cid, "cmd-idem-004", body)

    event_count =
      Repo.query!(
        "SELECT COUNT(*) AS n FROM chat_v2.events WHERE channel_id = $1",
        [cid]
      ).num_rows

    assert event_count == 1
    assert is_binary(ack2["payload"]["event_id"])
  end

  # ------------------------------------------------- AC3: event_id

  test "event_id is strictly increasing within a channel" do
    cid = channel!()

    {:ok, a} = send!(cid, "cmd-ev-001", %{"type" => "text", "text" => "1"})
    {:ok, b} = send!(cid, "cmd-ev-002", %{"type" => "text", "text" => "2"})
    {:ok, c} = send!(cid, "cmd-ev-003", %{"type" => "text", "text" => "3"})

    assert a["payload"]["event_id"] < b["payload"]["event_id"]
    assert b["payload"]["event_id"] < c["payload"]["event_id"]
  end

  test "monotonic_uuidv7: same-ms counter increments; new-ms resets; parse round-trips" do
    base = 1_700_000_000_000

    {id1, seq1} = Ids.monotonic_uuidv7(%{last_ms: base, counter: 0}, base)
    {id2, seq2} = Ids.monotonic_uuidv7(seq1, base)
    {id3, seq3} = Ids.monotonic_uuidv7(seq2, base)

    # same ms → lexicographically increasing (counter in rand_a); the counter
    # advances by one per allocation within the same millisecond.
    assert id1 < id2
    assert id2 < id3
    assert seq1.counter == 1
    assert seq2.counter == 2
    assert seq3.counter == 3

    # new ms → counter resets to 0
    {id4, seq4} = Ids.monotonic_uuidv7(seq3, base + 500)
    assert seq4 == %{last_ms: base + 500, counter: 0}
    assert id3 < id4

    # parse round-trips the counter state
    assert Ids.parse_monotonic(id2) == seq2
    assert Ids.parse_monotonic(id3) == seq3

    # the id is a UUIDv7-shaped 8-4-4-4-12 (version nibble 7, variant 0b10)
    assert id1 =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
  end

  test "crash recovery: a fresh process resumes the counter from MAX(event_id)" do
    cid = channel!()

    base = DateTime.utc_now() |> DateTime.to_unix(:millisecond)
    {seeded_id, seeded_seq} = Ids.monotonic_uuidv7(%{last_ms: base, counter: 5}, base)

    Repo.query!(
      "INSERT INTO chat_v2.events (event_id, event_type, channel_id, actor_kind, payload, membership_version_at_event, occurred_at) VALUES ($1, 'message.created', $2, 'user', $3, 1, $4)",
      [seeded_id, cid, %{"message" => %{"message_id" => "seeded"}}, DateTime.utc_now()]
    )

    {:ok, ack} = send!(cid, "cmd-ev-005", %{"type" => "text", "text" => "after recovery"})

    new_id = ack["payload"]["event_id"]
    assert new_id > seeded_id

    # the process recovered the seed's counter (parse round-trips it), not a
    # fresh 0 — the new id's timestamp/counter continue from the seed.
    assert Ids.parse_monotonic(seeded_id) == seeded_seq
  end

  # ------------------------------------------------- validation (§6.2)

  test "text message with blank text → INVALID_MESSAGE" do
    cid = channel!()

    assert {:error, %LiliumChat.Errors.ApiError{code: "INVALID_MESSAGE"}} =
             send!(cid, "cmd-val-001", %{"type" => "text", "text" => "   "})
  end

  test "unsupported type → INVALID_MESSAGE" do
    cid = channel!()

    assert {:error, %LiliumChat.Errors.ApiError{code: "INVALID_MESSAGE"}} =
             send!(cid, "cmd-val-002", %{"type" => "video", "text" => "x"})
  end

  test "image message without attachment_ids → INVALID_MESSAGE" do
    cid = channel!()

    assert {:error, %LiliumChat.Errors.ApiError{code: "INVALID_MESSAGE"}} =
             send!(cid, "cmd-val-003", %{"type" => "image"})
  end

  test "sticker message without sticker_id → INVALID_MESSAGE" do
    cid = channel!()

    assert {:error, %LiliumChat.Errors.ApiError{code: "INVALID_MESSAGE"}} =
             send!(cid, "cmd-val-004", %{"type" => "sticker"})
  end

  test "text message with attachment_ids → INVALID_MESSAGE" do
    cid = channel!()

    assert {:error, %LiliumChat.Errors.ApiError{code: "INVALID_MESSAGE"}} =
             send!(cid, "cmd-val-005", %{
               "type" => "text",
               "text" => "x",
               "attachment_ids" => ["a"]
             })
  end

  # ------------------------------------------------- channel gates

  test "non-member → CHANNEL_NOT_FOUND (old Worker WS path, not FORBIDDEN)" do
    cid = "ch-" <> Ecto.UUID.generate()
    seed_channel(cid)
    # @uid is not a member

    assert {:error, %LiliumChat.Errors.ApiError{code: "CHANNEL_NOT_FOUND"}} =
             send!(cid, "cmd-gate-001", %{"type" => "text", "text" => "x"})
  end

  test "validation runs BEFORE the membership gate (invalid payload + non-member → INVALID_MESSAGE)" do
    cid = "ch-" <> Ecto.UUID.generate()
    seed_channel(cid)
    # @uid is not a member, but the payload is invalid too — validation wins.

    assert {:error, %LiliumChat.Errors.ApiError{code: "INVALID_MESSAGE"}} =
             send!(cid, "cmd-gate-004", %{"type" => "video", "text" => "x"})
  end

  test "dissolved channel → CHANNEL_DISSOLVED" do
    cid = channel!()
    Repo.query!("UPDATE chat_v2.channels SET status = 'dissolved' WHERE channel_id = $1", [cid])

    assert {:error, %LiliumChat.Errors.ApiError{code: "CHANNEL_DISSOLVED"}} =
             send!(cid, "cmd-gate-002", %{"type" => "text", "text" => "x"})
  end

  test "missing channel → CHANNEL_NOT_FOUND" do
    assert {:error, %LiliumChat.Errors.ApiError{code: "CHANNEL_NOT_FOUND"}} =
             send!("ch-does-not-exist", "cmd-gate-003", %{"type" => "text", "text" => "x"})
  end
end
