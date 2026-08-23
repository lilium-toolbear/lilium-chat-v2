defmodule LiliumChatWeb.MessageSendWSTest do
  @moduledoc """
  Socket-level `message.send` fanout tests (issue #9, AC4).

  Exercises the full pipeline: browser socket → `message.send` → per-channel
  writer process (single PG txn) → PubSub `channel:<id>` broadcast → socket
  membership gate → client delivery. Verifies fanout **ordering** and the
  **membership gate** on the live path.
  """

  use LiliumChatWeb.ChannelCase, async: false

  alias LiliumChat.{Channel, Repo, MembershipCache}
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

  defp seed_member!(channel_id, user_id, status \\ "active") do
    Repo.query!(
      "INSERT INTO chat_v2.channel_members (channel_id, user_id, role, joined_at, status) VALUES ($1, $2, 'member', $3, $4)",
      [channel_id, user_id, DateTime.utc_now(), status]
    )

    :ok
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

  # --------------------------------------------------------- AC4: fanout

  test "message.send via socket → committed ack + ordered, gated live event fanout" do
    cid = seed_channel!("ch-fanout-001", 3)
    seed_member!(cid, @uid)

    socket = connect_and_join(@uid)

    ref = push(socket, "command", Frames.command("session.live_start", "cmd-fs-ls", %{}))
    assert_reply(ref, :ok, _ack)
    assert MembershipCache.get(cid) == 3

    # Warm up the per-channel writer process (lazy start + recover_seq) BEFORE the
    # timed assertions, so the cold-start latency does not race the reply window.
    Channel.ensure_started(cid)

    ref1 =
      push(
        socket,
        "command",
        Frames.command("message.send", "cmd-fs-1", %{"type" => "text", "text" => "first"}, cid)
      )

    assert_reply(ref1, :ok, ack1)
    assert ack1["frame_type"] == "command_ack"
    assert ack1["status"] == "committed"
    assert ack1["payload"]["channel_id"] == cid
    assert ack1["payload"]["message"]["text"] == "first"

    ref2 =
      push(
        socket,
        "command",
        Frames.command("message.send", "cmd-fs-2", %{"type" => "text", "text" => "second"}, cid)
      )

    assert_reply(ref2, :ok, ack2)
    assert ack2["payload"]["message"]["text"] == "second"

    # AC4: the two committed events are fanned out, in commit order, gated by
    # the membership_version carried on each broadcast frame.
    assert_receive %{event: "event", payload: e1}, 2_000
    assert_receive %{event: "event", payload: e2}, 2_000

    # ordering preserved
    assert e1["payload"]["message"]["text"] == "first"
    assert e2["payload"]["message"]["text"] == "second"
    assert e1["event_id"] < e2["event_id"]

    # event envelope shape (contract §10.4)
    assert e1["frame_type"] == "event"
    assert e1["api_version"] == "lilium.chat.v1"
    assert e1["type"] == "message.created"
    assert e1["channel_id"] == cid
    assert is_binary(e1["occurred_at"])

    # gate metadata present + the broadcast event_id matches the committed ack
    assert e1["membership_version_at_event"] == 3
    assert e1["event_id"] == ack1["payload"]["event_id"]
    assert e2["event_id"] == ack2["payload"]["event_id"]

    # the live message projection carries the resolved sender
    assert e1["payload"]["message"]["sender"]["kind"] == "user"
    assert e1["payload"]["message"]["sender"]["user"]["user_id"] == @uid
  end

  test "message.send validation error over socket → command_error envelope" do
    cid = seed_channel!("ch-fanout-err", 1)
    seed_member!(cid, @uid)

    socket = connect_and_join(@uid)

    ref = push(socket, "command", Frames.command("session.live_start", "cmd-fs-err-ls", %{}))
    assert_reply(ref, :ok, _ack)

    ref2 =
      push(
        socket,
        "command",
        Frames.command("message.send", "cmd-fs-err", %{"type" => "text", "text" => "  "}, cid)
      )

    assert_reply(ref2, :error, err)
    assert err["frame_type"] == "command_error"
    assert err["command_id"] == "cmd-fs-err"
    assert err["error"]["code"] == "INVALID_MESSAGE"
  end

  test "message.send for non-member over socket → CHANNEL_NOT_FOUND command_error" do
    cid = seed_channel!("ch-fanout-nm", 1)
    # @uid is not a member of this channel

    socket = connect_and_join(@uid)

    ref = push(socket, "command", Frames.command("session.live_start", "cmd-fs-nm-ls", %{}))
    assert_reply(ref, :ok, _ack)

    ref2 =
      push(
        socket,
        "command",
        Frames.command("message.send", "cmd-fs-nm", %{"type" => "text", "text" => "hi"}, cid)
      )

    assert_reply(ref2, :error, err)
    assert err["error"]["code"] == "CHANNEL_NOT_FOUND"
  end
end
