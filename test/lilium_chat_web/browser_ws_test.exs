defmodule LiliumChatWeb.BrowserWSTest do
  @moduledoc """
  Browser WS + live fanout pipeline tests (issue #8, contract §5.11/§5.12/§10.1).

  Uses `Phoenix.ChannelTest` to exercise the full channel lifecycle:
  join → session.live_start → session.heartbeat → broadcast delivery.

  Acceptance criteria covered:
  * A4: subprotocol negotiation + connect/join validation
  * live_start / heartbeat semantics (v2.11)
  * committed_ack frame shapes (including payload-bearing)
  * PubSub topic subscription + membership gate
  """

  use LiliumChatWeb.ChannelCase, async: false

  import Ecto.Query
  import LiliumChat.TestJWT

  alias LiliumChat.{Repo, MembershipCache}
  alias LiliumChat.WebSockets.Frames

  @uid "6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e6f"
  @uid2 "7a2f3d4e-5b6c-8d9e-af10-2b3c4d5e6f7a"

  # ------------------------------------------------------------- helpers

  defp identity_for(uid) do
    %LiliumChat.Auth.Identity{user_id: uid, is_admin: false}
  end

  defp seed_channel!(channel_id, membership_version \\ 1) do
    now = DateTime.utc_now()

    Repo.query!(
      "INSERT INTO chat_v2.channels (channel_id, kind, visibility, title, status, created_by, created_at, updated_at, member_count, membership_version) VALUES ($1, 'channel', 'private', 'Test Channel', 'active', $2, $3, $4, 1, $5)",
      [channel_id, @uid, now, now, membership_version]
    )

    channel_id
  end

  defp seed_member!(channel_id, user_id, status \\ "active") do
    now = DateTime.utc_now()

    Repo.query!(
      "INSERT INTO chat_v2.channel_members (channel_id, user_id, role, joined_at, status) VALUES ($1, $2, 'member', $3, $4)",
      [channel_id, user_id, now, status]
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

  # ------------------------------------------------------ A4: join tests

  test "join succeeds with valid identity" do
    socket =
      socket(
        LiliumChatWeb.BrowserSocket,
        "browser:#{@uid}",
        %{identity: identity_for(@uid)}
      )

    {:ok, reply, socket} =
      subscribe_and_join(socket, LiliumChatWeb.BrowserChannel, "browser:#{@uid}", %{})

    assert reply == %{}
    assert socket.assigns[:user_id] == @uid
    assert socket.assigns[:live?] == false
    assert is_binary(socket.assigns[:session_id])
  end

  test "join fails for non-browser topic" do
    socket =
      socket(
        LiliumChatWeb.BrowserSocket,
        "other:topic",
        %{identity: identity_for(@uid)}
      )

    {:error, %{reason: reason}} =
      subscribe_and_join(socket, LiliumChatWeb.BrowserChannel, "other:topic", %{})

    assert reason == "bad_topic"
  end

  # --------------------------------------------------- live_start tests

  test "session.live_start with no channels → ack with count 0" do
    socket = connect_and_join(@uid)

    ref = push(socket, "command", Frames.command("session.live_start", "cmd-live-001", %{}))
    assert_reply(ref, :ok, ack)

    assert ack["frame_type"] == "command_ack"
    assert ack["command"] == "session.live_start"
    assert ack["command_id"] == "cmd-live-001"
    assert ack["status"] == "committed"
    assert ack["payload"]["subscribed_channel_count"] == 0
    assert is_binary(ack["payload"]["session_id"])
    assert is_binary(ack["payload"]["lease_expires_at"])
  end

  test "session.live_start with active channels → ack with correct count" do
    ch1 = seed_channel!("ch-live-001", 5)
    ch2 = seed_channel!("ch-live-002", 3)
    seed_member!(ch1, @uid)
    seed_member!(ch2, @uid)

    socket = connect_and_join(@uid)

    ref = push(socket, "command", Frames.command("session.live_start", "cmd-live-002", %{}))
    assert_reply(ref, :ok, ack)

    assert ack["payload"]["subscribed_channel_count"] == 2
    assert is_binary(ack["payload"]["session_id"])
    assert is_binary(ack["payload"]["lease_expires_at"])

    # ETS cache is populated
    assert MembershipCache.get(ch1) == 5
    assert MembershipCache.get(ch2) == 3
  end

  test "session.live_start is idempotent (re-entry with same channels)" do
    ch1 = seed_channel!("ch-idem-001", 1)
    seed_member!(ch1, @uid)

    socket = connect_and_join(@uid)

    ref1 = push(socket, "command", Frames.command("session.live_start", "cmd-idem-001", %{}))
    assert_reply(ref1, :ok, ack1)
    assert ack1["payload"]["subscribed_channel_count"] == 1

    ref2 = push(socket, "command", Frames.command("session.live_start", "cmd-idem-002", %{}))
    assert_reply(ref2, :ok, ack2)
    assert ack2["payload"]["subscribed_channel_count"] == 1
  end

  test "session.live_start excludes dissolved channels" do
    ch1 = seed_channel!("ch-diss-001", 1)
    ch2 = seed_channel!("ch-diss-002", 1)
    seed_member!(ch1, @uid)
    seed_member!(ch2, @uid)

    # Dissolve ch2
    query = from c in "channels", prefix: "chat_v2", where: c.channel_id == ^ch2
    Repo.update_all(query, set: [status: "dissolved"])

    socket = connect_and_join(@uid)

    ref = push(socket, "command", Frames.command("session.live_start", "cmd-diss-001", %{}))
    assert_reply(ref, :ok, ack)

    assert ack["payload"]["subscribed_channel_count"] == 1
  end

  test "session.live_start excludes non-active members" do
    ch1 = seed_channel!("ch-inact-001", 1)
    seed_member!(ch1, @uid, "left")

    socket = connect_and_join(@uid)

    ref = push(socket, "command", Frames.command("session.live_start", "cmd-inact-001", %{}))
    assert_reply(ref, :ok, ack)

    assert ack["payload"]["subscribed_channel_count"] == 0
  end

  # -------------------------------------------------- heartbeat tests

  test "session.heartbeat before live_start → SESSION_NOT_LIVE" do
    socket = connect_and_join(@uid)

    ref = push(socket, "command", Frames.command("session.heartbeat", "cmd-hb-001", %{}))
    assert_reply(ref, :error, error_frame)

    assert error_frame["frame_type"] == "command_error"
    assert error_frame["command_id"] == "cmd-hb-001"
    assert error_frame["error"]["code"] == "SESSION_NOT_LIVE"
  end

  test "session.heartbeat after live_start → ack with lease_expires_at" do
    ch1 = seed_channel!("ch-hb-001", 1)
    seed_member!(ch1, @uid)

    socket = connect_and_join(@uid)

    # Start live
    ref1 = push(socket, "command", Frames.command("session.live_start", "cmd-hb-live", %{}))
    assert_reply(ref1, :ok, _ack1)

    # Heartbeat
    ref2 = push(socket, "command", Frames.command("session.heartbeat", "cmd-hb-002", %{}))
    assert_reply(ref2, :ok, ack2)

    assert ack2["frame_type"] == "command_ack"
    assert ack2["command"] == "session.heartbeat"
    assert ack2["command_id"] == "cmd-hb-002"
    assert ack2["status"] == "committed"
    assert is_binary(ack2["payload"]["session_id"])
    assert is_binary(ack2["payload"]["lease_expires_at"])
  end

  # -------------------------------------------- unknown command / frame

  test "unknown command → INVALID_COMMAND error" do
    socket = connect_and_join(@uid)

    ref = push(socket, "command", Frames.command("channel.unknown", "cmd-unk-001", %{}))
    assert_reply(ref, :error, error_frame)

    assert error_frame["frame_type"] == "command_error"
    assert error_frame["error"]["code"] == "INVALID_COMMAND"
  end

  test "malformed command frame (missing command) → error" do
    socket = connect_and_join(@uid)

    bad_frame = %{"frame_type" => "command", "command_id" => "cmd-bad-001"}
    ref = push(socket, "command", bad_frame)
    assert_reply(ref, :error, error_frame)

    assert error_frame["frame_type"] == "command_error"
  end

  # ------------------------------------------------- broadcast tests

  test "channel event broadcast is delivered to subscribed channel" do
    ch1 = seed_channel!("ch-bcast-001", 1)
    seed_member!(ch1, @uid)

    socket = connect_and_join(@uid)

    # Start live
    ref = push(socket, "command", Frames.command("session.live_start", "cmd-bcast-001", %{}))
    assert_reply(ref, :ok, _ack)

    # Broadcast an event via PubSub
    frame =
      Frames.event(
        "evt-bcast-001",
        "message.created",
        ch1,
        "2026-08-19T12:00:00Z",
        %{"message" => %{"message_id" => "msg-bcast-001"}}
      )
      |> Map.put("membership_version_at_event", 1)

    Phoenix.PubSub.broadcast(
      LiliumChat.PubSub,
      "channel:" <> ch1,
      {:broadcast, "channel:" <> ch1, frame}
    )

    # The channel should receive and push the event to the client
    assert_receive %{event: "event", payload: payload}, 1000
    assert payload["frame_type"] == "event"
    assert payload["event_id"] == "evt-bcast-001"
    assert payload["type"] == "message.created"
    assert payload["channel_id"] == ch1
  end

  test "membership gate: newer mv triggers recheck" do
    ch1 = seed_channel!("ch-gate-001", 1)
    seed_member!(ch1, @uid)

    socket = connect_and_join(@uid)

    # Start live (caches mv=1)
    ref = push(socket, "command", Frames.command("session.live_start", "cmd-gate-001", %{}))
    assert_reply(ref, :ok, _ack)

    # Verify cache
    assert MembershipCache.get(ch1) == 1

    # Gate check: mv=1 matches → deliver
    assert MembershipCache.gate_check(ch1, 1) == :deliver

    # Gate check: mv=2 > 1 → recheck
    assert MembershipCache.gate_check(ch1, 2) == :recheck

    # After recheck + cache update
    MembershipCache.put(ch1, 2)
    assert MembershipCache.gate_check(ch1, 2) == :deliver
  end
end
