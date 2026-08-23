defmodule LiliumChatWeb.MessageMutationWSTest do
  @moduledoc """
  Socket-level tests for the #10 commands: `message.edit` / `message.recall` /
  `message.delete`, `channel.pin_message` / `channel.unpin_message`, and
  `channel.mark_read`.

  Exercises the full pipeline: browser socket → per-channel writer process
  (single PG txn) → PubSub `channel:<id>` / `user:<id>` broadcast → socket
  membership gate → client delivery. Verifies the committed ack shapes
  (contract §6.3–§6.7 / §5.5) and the live fanout ordering.
  """

  use LiliumChatWeb.ChannelCase, async: false

  alias LiliumChat.{Channel, MembershipCache, Repo}
  alias LiliumChat.WebSockets.Frames

  @uid "6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e6f"

  # ----------------------------------------------------------------- helpers

  defp identity_for(uid), do: %LiliumChat.Auth.Identity{user_id: uid, is_admin: false}

  defp seed_channel!(channel_id, mv) do
    now = DateTime.utc_now()

    Repo.query!(
      "INSERT INTO chat_v2.channels (channel_id, kind, visibility, title, status, created_by, created_at, updated_at, member_count, membership_version) VALUES ($1, 'channel', 'private', 'Test', 'active', $2, $3, $4, 1, $5)",
      [channel_id, @uid, now, now, mv]
    )

    channel_id
  end

  defp seed_member!(channel_id, user_id) do
    Repo.query!(
      "INSERT INTO chat_v2.channel_members (channel_id, user_id, role, joined_at, status) VALUES ($1, $2, 'owner', $3, 'active')",
      [channel_id, user_id, DateTime.utc_now()]
    )

    :ok
  end

  defp seed_message!(message_id, channel_id, sender_id, text, event_id) do
    Repo.query!(
      "INSERT INTO chat_v2.messages (message_id, command_id, dedupe_principal_key, channel_id, " <>
        "sender_kind, sender_user_id, type, format, status, text, stream_state, created_at, updated_at, event_id) " <>
        "VALUES ($1, $2, $3, $4, 'user', $5, 'text', 'plain', 'normal', $6, 'none', $7, $7, $8)",
      [
        message_id,
        Ecto.UUID.generate(),
        "user:" <> sender_id,
        channel_id,
        sender_id,
        text,
        DateTime.utc_now(),
        event_id
      ]
    )

    message_id
  end

  defp connect_and_join(uid) do
    socket =
      socket(
        LiliumChatWeb.BrowserSocket,
        "browser:#{uid}",
        %{identity: identity_for(uid)}
      )

    {:ok, _reply, socket} =
      subscribe_and_join(socket, LiliumChatWeb.BrowserChannel, "browser:#{uid}", %{})

    socket
  end

  defp live_start!(socket, tag) do
    ref = push(socket, "command", Frames.command("session.live_start", "cmd-ws-ls-#{tag}", %{}))
    assert_reply(ref, :ok, _ack)
  end

  defp command(socket, command, command_id, payload, channel_id) do
    ref = push(socket, "command", Frames.command(command, command_id, payload, channel_id))
    ref
  end

  # ------------------------------------------------------- edit/recall/delete

  test "message.edit over socket → committed ack + message.updated fanout" do
    cid = seed_channel!("ch-ws-edit", 3)
    seed_member!(cid, @uid)

    mid =
      seed_message!(
        "msg-ws-edit-1",
        cid,
        @uid,
        "original",
        "00000000-0000-7000-8000-000000000001"
      )

    socket = connect_and_join(@uid)
    live_start!(socket, "edit")
    assert MembershipCache.get(cid) == 3
    Channel.ensure_started(cid)

    ref =
      command(
        socket,
        "message.edit",
        "cmd-ws-edit-2",
        %{"message_id" => mid, "text" => "fixed"},
        cid
      )

    assert_reply(ref, :ok, ack)

    assert ack["frame_type"] == "command_ack"
    assert ack["command"] == "message.edit"
    assert ack["status"] == "committed"
    assert ack["payload"]["channel_id"] == cid
    assert ack["payload"]["message"]["text"] == "fixed"
    assert ack["payload"]["message"]["status"] == "edited"

    assert_receive %{event: "event", payload: frame}, 2_000
    assert frame["frame_type"] == "event"
    assert frame["type"] == "message.updated"
    assert frame["channel_id"] == cid
    assert frame["event_id"] == ack["payload"]["event_id"]
    assert frame["membership_version_at_event"] == 3
    assert frame["payload"]["message"]["text"] == "fixed"
    # contract §6.2 / §10.4: message.* event PAYLOAD also carries the ids
    assert frame["payload"]["channel_id"] == cid
    assert frame["payload"]["event_id"] == frame["event_id"]
  end

  test "message.delete by owner of another's message → message.deleted + system.notice fanout" do
    other = "7a2f3d4e-5b6c-8d9e-0f1a-2b3c4d5e6f70"
    cid = seed_channel!("ch-ws-del", 2)
    seed_member!(cid, @uid)
    seed_member!(cid, other)

    mid =
      seed_message!("msg-ws-del-1", cid, other, "theirs", "00000000-0000-7000-8000-000000000001")

    socket = connect_and_join(@uid)
    live_start!(socket, "del")
    Channel.ensure_started(cid)

    ref = command(socket, "message.delete", "cmd-ws-del-2", %{"message_id" => mid}, cid)
    assert_reply(ref, :ok, ack)
    assert ack["payload"]["message"]["status"] == "deleted"

    assert_receive %{event: "event", payload: deleted}, 2_000
    assert deleted["type"] == "message.deleted"
    assert deleted["event_id"] == ack["payload"]["event_id"]
    assert deleted["payload"]["channel_id"] == cid
    assert deleted["payload"]["event_id"] == deleted["event_id"]

    # the notice follows in event_id order, with resolved actor/target summaries
    assert_receive %{event: "event", payload: notice}, 2_000
    assert notice["type"] == "system.notice"
    assert notice["event_id"] > deleted["event_id"]
    assert notice["payload"]["notice_kind"] == "message.deleted"
    assert notice["payload"]["actor"]["user_id"] == @uid
    assert notice["payload"]["target_user"]["user_id"] == other
    assert notice["payload"]["message_id"] == mid
    assert notice["payload"]["channel_changes"] == nil
  end

  test "missing channel_id over socket → CHANNEL_NOT_FOUND command_error" do
    ref =
      push(
        connect_and_join(@uid),
        "command",
        Frames.command("message.recall", "cmd-ws-nocid", %{"message_id" => "m"}, nil)
      )

    assert_reply(ref, :error, err)
    assert err["error"]["code"] == "CHANNEL_NOT_FOUND"
    assert err["error"]["message"] == "missing channel_id"
  end

  # ------------------------------------------------------------- pins (WS)

  test "channel.pin_message over socket → ack with ChannelPin wire + channel.pin.set fanout" do
    cid = seed_channel!("ch-ws-pin", 4)
    seed_member!(cid, @uid)

    mid =
      seed_message!(
        "msg-ws-pin-1",
        cid,
        @uid,
        "keep this",
        "00000000-0000-7000-8000-000000000001"
      )

    socket = connect_and_join(@uid)
    live_start!(socket, "pin")
    Channel.ensure_started(cid)

    ref =
      command(socket, "channel.pin_message", "cmd-ws-pin-2", %{"source_message_id" => mid}, cid)

    assert_reply(ref, :ok, ack)

    assert ack["payload"]["channel_id"] == cid
    pin = ack["payload"]["pin"]
    assert pin["pin_kind"] == "pinned_message"
    assert pin["priority"] == 10
    assert pin["source_message_id"] == mid
    assert pin["message"]["text"] == "keep this"
    assert pin["last_pin_event_id"] == ack["payload"]["event_id"]

    assert_receive %{event: "event", payload: frame}, 2_000
    assert frame["type"] == "channel.pin.set"
    assert frame["payload"]["pin"]["pin_id"] == pin["pin_id"]

    # unpin by pin_id
    ref2 =
      command(socket, "channel.unpin_message", "cmd-ws-pin-3", %{"pin_id" => pin["pin_id"]}, cid)

    assert_reply(ref2, :ok, unack)
    assert unack["payload"]["channel_id"] == cid
    assert is_binary(unack["payload"]["event_id"])

    assert_receive %{event: "event", payload: cleared}, 2_000
    assert cleared["type"] == "channel.pin.cleared"
    assert cleared["payload"]["pin_id"] == pin["pin_id"]
  end

  # ----------------------------------------------------------- mark_read (WS)

  test "channel.mark_read over socket → ack with unread_count; other session gets read_state_updated" do
    cid = seed_channel!("ch-ws-rs", 5)
    seed_member!(cid, @uid)
    # seed one message + its message.created event (before the cursor below)
    seed_message!("msg-ws-rs-1", cid, @uid, "hi", "00000000-0000-7000-8000-000000000001")

    socket1 = connect_and_join(@uid)
    socket2 = connect_and_join(@uid)
    live_start!(socket1, "rs1")
    live_start!(socket2, "rs2")

    cursor = "00000000-0000-7000-8000-0000000000ff"

    ref =
      command(socket1, "channel.mark_read", "cmd-ws-rs-2", %{"last_read_event_id" => cursor}, cid)

    assert_reply(ref, :ok, ack)

    assert ack["payload"]["channel_id"] == cid
    assert ack["payload"]["last_read_event_id"] == cursor
    # the seeded message event (…0001) is BEFORE the cursor → no unread
    assert ack["payload"]["unread_count"] == 0

    # the user's OTHER live session receives the user-local hint
    assert_receive %{event: "read_state_updated", payload: hint}, 2_000
    assert hint["frame_type"] == "read_state_updated"
    assert hint["channel_id"] == cid
    assert hint["last_read_event_id"] == cursor
    assert hint["unread_count"] == 0

    # the sender's socket (socket1) did NOT also receive the hint: no duplicate
    refute_receive %{event: "read_state_updated"}, 300
  end

  test "channel.mark_read with missing last_read_event_id → INVALID_MESSAGE" do
    cid = seed_channel!("ch-ws-rs2", 6)
    seed_member!(cid, @uid)

    socket = connect_and_join(@uid)
    live_start!(socket, "rs3")

    ref = command(socket, "channel.mark_read", "cmd-ws-rs4", %{}, cid)
    assert_reply(ref, :error, err)
    assert err["error"]["code"] == "INVALID_MESSAGE"
    assert err["error"]["message"] == "last_read_event_id required"
  end
end
