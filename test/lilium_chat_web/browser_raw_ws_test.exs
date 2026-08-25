defmodule LiliumChatWeb.BrowserRawWSTest do
  @moduledoc """
  Raw-frame browser WS protocol tests (issue #27, contract §10.1 / §10.4).

  The contract wire protocol is RAW JSON frames: the client connects
  (subprotocol + JWT) and immediately sends `{"frame_type": "command", ...}`
  frames — it does NOT speak Phoenix Channels (no join, no `phx_*`
  envelopes). `LiliumChatWeb.BrowserSocket` adapts Phoenix to that protocol:

  * inbound raw `command` frames are routed to a lazily-joined
    `BrowserChannel` process;
  * Phoenix `phx_reply` / push frames are unwrapped back into raw frames
    before they reach the wire.

  These tests drive the socket's transport callbacks (`handle_in/2` /
  `handle_info/2`) directly against a connected socket state — the same
  seam the in-process WebSocket transport uses — with a real
    `BrowserChannel` process (real PubSub subscription, real Repo queries)
  and assert that only raw frames ever cross the transport boundary.
  """

  use LiliumChatWeb.ChannelCase, async: false

  import Ecto.Query

  alias LiliumChat.{Repo, Auth}
  alias LiliumChat.WebSockets.Frames
  alias LiliumChatWeb.{BrowserSocket, BrowserChannel}
  alias Phoenix.Socket.Message

  @uid "6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e6f"
  @v1_serializer Phoenix.Socket.V1.JSONSerializer

  # ------------------------------------------------------------- helpers

  defp connected_socket(uid) do
    identity = %Auth.Identity{user_id: uid, is_admin: false}

    %Phoenix.Socket{
      handler: BrowserSocket,
      endpoint: LiliumChatWeb.Endpoint,
      transport: :websocket,
      serializer: @v1_serializer,
      # `__connect__` copies these from the endpoint config on a real
      # connection; the channel join needs them (init_join/3).
      pubsub_server: LiliumChat.PubSub,
      # The in-process transport is the socket process itself; in these
      # tests the test process plays that role (assert_receive below).
      transport_pid: self(),
      assigns: %{identity: identity}
    }
  end

  defp send_raw(socket, raw_frame) do
    payload = Jason.encode!(raw_frame)
    {:ok, {nil, socket}} = BrowserSocket.handle_in({payload, [opcode: :text]}, {nil, socket})
    socket
  end

  defp wire!(iodata), do: IO.iodata_to_binary(iodata)

  defp unwrap!({:socket_push, :text, payload}) do
    assert {:push, {:text, raw}, _} =
             BrowserSocket.handle_info({:socket_push, :text, payload}, {nil, %Phoenix.Socket{}})

    Jason.decode!(wire!(raw))
  end

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

  # ------------------------------------------- inbound routing (handle_in)

  test "raw session.live_start → lazy channel join → raw command_ack frame" do
    socket = connected_socket(@uid)
    frame = Frames.command("session.live_start", "cmd-raw-live-1", %{})

    socket = send_raw(socket, frame)

    # the channel process was lazily joined for this socket
    assert is_pid(socket.assigns[:browser_channel_pid])

    # the ack crosses the transport boundary as a RAW frame (no phx_reply
    # wrapper reaches the client)
    assert_receive {:socket_push, :text, wire}, 2_000
    ack = unwrap!({:socket_push, :text, wire})

    assert ack["frame_type"] == "command_ack"
    assert ack["command"] == "session.live_start"
    assert ack["command_id"] == "cmd-raw-live-1"
    assert ack["status"] == "committed"
    assert ack["payload"]["subscribed_channel_count"] == 0
    assert is_binary(ack["payload"]["session_id"])
    assert is_binary(ack["payload"]["lease_expires_at"])
  end

  test "second raw frame reuses the joined channel (no second spawn)" do
    socket = connected_socket(@uid)

    socket = send_raw(socket, Frames.command("session.live_start", "cmd-raw-r1", %{}))
    pid1 = socket.assigns[:browser_channel_pid]
    assert_receive {:socket_push, :text, _}, 2_000

    socket = send_raw(socket, Frames.command("session.heartbeat", "cmd-raw-r2", %{}))
    assert socket.assigns[:browser_channel_pid] == pid1

    assert_receive {:socket_push, :text, wire}, 2_000
    ack = unwrap!({:socket_push, :text, wire})
    assert ack["frame_type"] == "command_ack"
    assert ack["command"] == "session.heartbeat"
    assert ack["status"] == "committed"
    assert is_binary(ack["payload"]["lease_expires_at"])
  end

  test "raw unknown command → raw command_error frame (INVALID_COMMAND)" do
    socket = connected_socket(@uid)
    send_raw(socket, Frames.command("channel.unknown", "cmd-raw-unk", %{}))

    assert_receive {:socket_push, :text, wire}, 2_000
    frame = unwrap!({:socket_push, :text, wire})

    assert frame["frame_type"] == "command_error"
    assert frame["command_id"] == "cmd-raw-unk"
    assert frame["error"]["code"] == "INVALID_COMMAND"
  end

  test "raw command with missing command_id → raw command_error frame" do
    socket = connected_socket(@uid)

    raw_frame = %{"frame_type" => "command", "command" => "session.live_start"}
    send_raw(socket, raw_frame)

    assert_receive {:socket_push, :text, wire}, 2_000
    frame = unwrap!({:socket_push, :text, wire})
    assert frame["frame_type"] == "command_error"
    assert frame["command_id"] == "unknown"
    assert frame["error"]["code"] == "missing command_id"
  end

  test "Phoenix-format message still takes the standard transport path" do
    socket = connected_socket(@uid)

    # a phoenix.js client's heartbeat on the "phoenix" topic must keep
    # working through the same socket (the standard __in__/2 dispatch)
    payload =
      Jason.encode!(%{
        "topic" => "phoenix",
        "event" => "heartbeat",
        "ref" => "hb-1",
        "payload" => %{}
      })

    state = %{channels: %{}, channels_inverse: %{}, max_channels_per_transport: 100}

    {:reply, :ok, _reply, _state} =
      BrowserSocket.handle_in({payload, [opcode: :text]}, {state, socket})
  end

  # ------------------------------------------ outbound unwrap (handle_info)

  test "phx_reply carrying a command frame is unwrapped to a raw frame" do
    ack = Frames.command_ack("session.heartbeat", "cmd-x", %{"lease_expires_at" => "later"})

    reply = %Message{
      topic: "browser:#{@uid}",
      event: "phx_reply",
      ref: "r1",
      payload: %{status: "ok", response: ack}
    }

    {:socket_push, :text, wire} = @v1_serializer.encode!(reply)
    frame = unwrap!({:socket_push, :text, wire})

    assert frame == Jason.decode!(Jason.encode!(ack))
  end

  test "event push is unwrapped to a raw event frame" do
    event = Frames.event("evt-raw-1", "message.created", "ch-1", "2026-08-25T00:00:00Z", %{})
    push = %Message{topic: "browser:#{@uid}", event: "event", payload: event}

    {:socket_push, :text, wire} = @v1_serializer.encode!(push)
    frame = unwrap!({:socket_push, :text, wire})

    assert frame["frame_type"] == "event"
    assert frame["event_id"] == "evt-raw-1"
  end

  test "user-scoped push (event name = frame_type) is unwrapped to a raw frame" do
    hint = Frames.read_state_updated("ch-1", "evt-0", 0)
    push = %Message{topic: "browser:#{@uid}", event: "read_state_updated", payload: hint}

    {:socket_push, :text, wire} = @v1_serializer.encode!(push)
    frame = unwrap!({:socket_push, :text, wire})

    assert frame["frame_type"] == "read_state_updated"
    assert frame["channel_id"] == "ch-1"
  end

  test "non-frame payload passes through untouched (phoenix.js clients)" do
    push = %Message{topic: "browser:#{@uid}", event: "custom", payload: %{foo: "bar"}}
    {:socket_push, :text, wire} = @v1_serializer.encode!(push)

    assert {:push, {:text, passthrough}, _} =
             BrowserSocket.handle_info({:socket_push, :text, wire}, {nil, %Phoenix.Socket{}})

    # the original phoenix envelope is unchanged
    assert passthrough == wire
  end

  # ------------------------------------------- full raw fanout (e2e seam)

  test "raw live_start + PubSub broadcast → gated raw event frame on the wire" do
    cid = seed_channel!("ch-raw-fanout", 2)
    seed_member!(cid, @uid)

    socket = connected_socket(@uid)
    send_raw(socket, Frames.command("session.live_start", "cmd-raw-fanout", %{}))

    assert_receive {:socket_push, :text, _live_ack}, 2_000

    frame =
      Frames.event("evt-raw-fanout", "message.created", cid, "2026-08-25T00:00:00Z", %{
        "message" => %{"message_id" => "msg-raw-1"}
      })
      |> Map.put("membership_version_at_event", 2)

    Phoenix.PubSub.broadcast(
      LiliumChat.PubSub,
      "channel:#{cid}",
      {:broadcast, "channel:#{cid}", frame}
    )

    assert_receive {:socket_push, :text, wire}, 2_000
    delivered = unwrap!({:socket_push, :text, wire})

    assert delivered["frame_type"] == "event"
    assert delivered["event_id"] == "evt-raw-fanout"
    assert delivered["type"] == "message.created"
    assert delivered["channel_id"] == cid
    # The D8 gate reads `membership_version_at_event` in-process (BEFORE the
    # push); the contract §10.4 EventEnvelope has no such field, so the wire
    # frame is stripped of it by BrowserSocket.
    assert delivered["membership_version_at_event"] == nil
  end

  test "raw message.send → committed ack + raw message.created fanout (parity path)" do
    cid = seed_channel!("ch-raw-send", 1)
    seed_member!(cid, @uid)

    socket = connected_socket(@uid)
    socket = send_raw(socket, Frames.command("session.live_start", "cmd-raw-send-live", %{}))
    assert_receive {:socket_push, :text, _live_ack}, 2_000

    # warm up the per-channel writer before the timed assertions
    Repo.all(
      from c in "channels",
        prefix: "chat_v2",
        where: c.channel_id == ^cid,
        select: c.channel_id
    )

    send_raw(
      socket,
      Frames.command("message.send", "cmd-raw-send-1", %{"type" => "text", "text" => "raw"}, cid)
    )

    assert_receive {:socket_push, :text, ack_wire}, 2_000
    ack = unwrap!({:socket_push, :text, ack_wire})

    assert ack["frame_type"] == "command_ack"
    assert ack["command"] == "message.send"
    assert ack["status"] == "committed"
    assert ack["payload"]["message"]["text"] == "raw"

    assert_receive {:socket_push, :text, event_wire}, 2_000
    event = unwrap!({:socket_push, :text, event_wire})

    assert event["frame_type"] == "event"
    assert event["type"] == "message.created"
    assert event["event_id"] == ack["payload"]["event_id"]
  end

  test "raw heartbeat before live_start → raw SESSION_NOT_LIVE command_error" do
    socket = connected_socket(@uid)
    send_raw(socket, Frames.command("session.heartbeat", "cmd-raw-hb-no-live", %{}))

    assert_receive {:socket_push, :text, wire}, 2_000
    frame = unwrap!({:socket_push, :text, wire})

    assert frame["frame_type"] == "command_error"
    assert frame["error"]["code"] == "SESSION_NOT_LIVE"
  end

  # ----------------------------------------------------------- channel ref

  test "join failure falls back to a raw CHAT_WORKER_UNAVAILABLE command_error" do
    # a socket without identity cannot join — the adapter must answer with a
    # raw command_error instead of crashing the transport (1011)
    base = connected_socket(@uid)
    socket = %{base | assigns: %{}}
    send_raw(socket, Frames.command("session.live_start", "cmd-raw-joinfail", %{}))

    assert_receive {:socket_push, :text, wire}, 2_000
    frame = unwrap!({:socket_push, :text, wire})

    assert frame["frame_type"] == "command_error"
    assert frame["command_id"] == "cmd-raw-joinfail"
    assert frame["error"]["code"] == "CHAT_WORKER_UNAVAILABLE"
  end

  test "channel exits when its socket (transport) process exits" do
    # A helper process plays the socket process: the channel joins there
    # (transport_pid + monitor target = the helper), so killing the helper
    # must take the channel down with it — no orphan channels.
    test_pid = self()

    helper =
      spawn(fn ->
        socket = connected_socket(@uid)
        socket = send_raw(socket, Frames.command("session.live_start", "cmd-raw-orphan", %{}))
        send(test_pid, {:channel_pid, socket.assigns[:browser_channel_pid]})

        receive do
          :kill -> :ok
        after
          5_000 -> :ok
        end
      end)

    assert_receive {:channel_pid, channel_pid}, 2_000
    assert is_pid(channel_pid)

    ref = Process.monitor(channel_pid)
    Process.exit(helper, :kill)
    assert_receive {:DOWN, ^ref, :process, ^channel_pid, _}, 2_000
  end

  test "BrowserChannel module is the joined channel for the raw socket" do
    socket = connected_socket(@uid)
    socket = send_raw(socket, Frames.command("session.live_start", "cmd-raw-mod", %{}))
    pid = socket.assigns[:browser_channel_pid]
    assert_receive {:socket_push, :text, _}, 2_000
    assert Process.alive?(pid)
    assert %Phoenix.Socket{channel: channel} = Phoenix.Channel.Server.socket(pid)
    assert channel == BrowserChannel
  end
end
