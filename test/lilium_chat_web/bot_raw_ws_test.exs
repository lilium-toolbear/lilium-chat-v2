defmodule LiliumChatWeb.BotRawWSTest do
  @moduledoc """
  Raw-frame bot WS protocol tests (issue #27, contract §9.7 / §9.15).

  The contract bot wire protocols are RAW JSON frames (`{"type": ...,
  "api_version": ...}`) — the bot does NOT speak Phoenix Channels (no join,
  no `phx_*` envelopes). `LiliumChatWeb.BotSocket` and
  `LiliumChatWeb.BotStreamSocket` adapt Phoenix to that protocol with the
  same transport seam as `BrowserSocket`:

  * inbound raw frames are routed into a lazily-joined BotChannel /
    BotStreamChannel process (`event = frame["type"]`);
  * Phoenix `phx_reply` / push frames carrying bot frames are unwrapped
    back into raw frames before they reach the wire.

  These tests drive the sockets' transport callbacks (`handle_in/2` /
  `handle_info/2`) directly against a connected socket state — the same
  seam the in-process WebSocket transport uses — with real channel
  processes and assert that only raw frames ever cross the transport
  boundary.
  """

  use LiliumChatWeb.ChannelCase, async: false

  import LiliumChatWeb.BotFixtures
  import LiliumChatWeb.ReadFixtures

  alias LiliumChat.{BotTokens, Stream}
  alias LiliumChatWeb.{BotSocket, BotStreamSocket}

  @bot "bot-raw-0001"
  @channel "ch-raw-0001"
  @mid "msg-raw-0001"
  @api "lilium.chat.bot.v1"
  @stream_api "lilium.chat.bot.stream.v1"
  @v1_serializer Phoenix.Socket.V1.JSONSerializer

  setup do
    seed_bot("owner-1", bot_id: @bot)
    seed_channel(@channel)
    kill_stream!(@channel, @mid)

    {:ok, _} = Stream.start_stream(@channel, @mid, @bot, %{"type" => "text"})

    on_exit(fn -> kill_stream!(@channel, @mid) end)
    :ok
  end

  # ------------------------------------------------------------- helpers

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

  defp gateway_socket(bot_id) do
    %Phoenix.Socket{
      handler: BotSocket,
      endpoint: LiliumChatWeb.Endpoint,
      transport: :websocket,
      serializer: @v1_serializer,
      pubsub_server: LiliumChat.PubSub,
      # the test process plays the socket (transport) process role
      transport_pid: self(),
      assigns: %{bot_identity: %{bot_id: bot_id, scopes: ["chat:runtime:connect"]}}
    }
  end

  defp stream_socket(bot_id) do
    %Phoenix.Socket{
      handler: BotStreamSocket,
      endpoint: LiliumChatWeb.Endpoint,
      transport: :websocket,
      serializer: @v1_serializer,
      pubsub_server: LiliumChat.PubSub,
      transport_pid: self(),
      assigns: %{
        bot_identity: %{bot_id: bot_id, scopes: ["chat:runtime:connect", "chat:messages:write"]},
        channel_id: @channel,
        message_id: @mid
      }
    }
  end

  defp send_raw(handler, socket, raw_frame) do
    payload = Jason.encode!(raw_frame)
    {:ok, {nil, socket}} = handler.handle_in({payload, [opcode: :text]}, {nil, socket})
    socket
  end

  defp wire!(iodata), do: IO.iodata_to_binary(iodata)

  defp unwrap!(handler, {:socket_push, :text, payload}) do
    assert {:push, {:text, raw}, _} =
             handler.handle_info({:socket_push, :text, payload}, {nil, %Phoenix.Socket{}})

    Jason.decode!(wire!(raw))
  end

  # ------------------------------------------------ gateway raw frames

  test "raw hello → lazy bot channel join → raw ready frame" do
    socket = gateway_socket(@bot)

    socket =
      send_raw(BotSocket, socket, %{
        "type" => "hello",
        "api_version" => @api,
        "last_received_delivery_id" => nil
      })

    assert is_pid(socket.assigns[:bot_channel_pid])

    assert_receive {:socket_push, :text, wire}, 2_000
    ready = unwrap!(BotSocket, {:socket_push, :text, wire})

    assert ready["type"] == "ready"
    assert ready["api_version"] == @api
    assert ready["bot_id"] == @bot
    assert is_binary(ready["session_id"])
    assert is_binary(ready["server_time"])
  end

  test "raw ping → raw pong" do
    socket = gateway_socket(@bot)
    _ = send_raw(BotSocket, socket, %{"type" => "ping", "api_version" => @api})

    assert_receive {:socket_push, :text, wire}, 2_000
    pong = unwrap!(BotSocket, {:socket_push, :text, wire})
    assert pong == %{"type" => "pong", "api_version" => @api}
  end

  test "raw delivery_result with unknown delivery_id → raw delivery_ack failed" do
    socket = gateway_socket(@bot)

    _ =
      send_raw(BotSocket, socket, %{
        "type" => "delivery_result",
        "api_version" => @api,
        "delivery_id" => "0199c0aa-0000-7000-8000-0000000000aa",
        "status" => "ok",
        "effects" => []
      })

    assert_receive {:socket_push, :text, wire}, 2_000
    ack = unwrap!(BotSocket, {:socket_push, :text, wire})

    assert ack["type"] == "delivery_ack"
    assert ack["api_version"] == @api
    assert ack["delivery_id"] == "0199c0aa-0000-7000-8000-0000000000aa"
    assert ack["status"] == "failed"
    assert ack["error"]["code"] == "BOT_EFFECT_INVALID"
    assert ack["error"]["message"] == "unknown delivery_id"
  end

  test "second raw frame reuses the joined bot channel (no second spawn)" do
    socket = gateway_socket(@bot)

    socket = send_raw(BotSocket, socket, %{"type" => "hello", "api_version" => @api})
    pid1 = socket.assigns[:bot_channel_pid]
    assert is_pid(pid1)
    assert_receive {:socket_push, :text, _}, 2_000

    socket = send_raw(BotSocket, socket, %{"type" => "ping", "api_version" => @api})
    assert socket.assigns[:bot_channel_pid] == pid1

    assert_receive {:socket_push, :text, _}, 2_000
  end

  test "Phoenix-format message still takes the standard transport path (gateway)" do
    socket = gateway_socket(@bot)

    payload =
      Jason.encode!(%{
        "topic" => "phoenix",
        "event" => "heartbeat",
        "ref" => "hb-1",
        "payload" => %{}
      })

    state = %{channels: %{}, channels_inverse: %{}, max_channels_per_transport: 100}

    {:reply, :ok, _reply, _state} =
      BotSocket.handle_in({payload, [opcode: :text]}, {state, socket})
  end

  test "raw session acks are silent (old-Worker parity, contract §9.7.4)" do
    # The old Worker's BotConnection answers `session.start_ack` /
    # `session.input_ack` / `session.close` with NO bot-visible frame — the
    # bot learns the outcome from server-pushed frames (`session.closed`,
    # the `stateful_session.*` fanout, …). A Phoenix reply would leak a
    # phx_reply envelope onto the raw wire (the seam only unwraps replies
    # whose payload is a bot frame, i.e. carries `type`).
    socket = gateway_socket(@bot)
    socket = send_raw(BotSocket, socket, %{"type" => "hello", "api_version" => @api})
    assert_receive {:socket_push, :text, _}, 2_000

    _ =
      send_raw(
        BotSocket,
        socket,
        %{"type" => "session.start_ack", "api_version" => @api, "session_id" => "sess-silent"}
      )

    refute_receive {:socket_push, :text, _}, 300

    _ =
      send_raw(
        BotSocket,
        socket,
        %{
          "type" => "session.input_ack",
          "api_version" => @api,
          "session_id" => "sess-silent",
          "last_received_seq" => 1
        }
      )

    refute_receive {:socket_push, :text, _}, 300

    _ =
      send_raw(
        BotSocket,
        socket,
        %{"type" => "session.close", "api_version" => @api, "session_id" => "sess-silent"}
      )

    refute_receive {:socket_push, :text, _}, 300
  end

  test "phx_reply carrying a bot frame is unwrapped to a raw frame (gateway)" do
    frame = %{
      "type" => "delivery_ack",
      "api_version" => @api,
      "delivery_id" => "d-1",
      "status" => "applied",
      "effect_results" => []
    }

    reply = %Phoenix.Socket.Message{
      topic: "bot:#{@bot}",
      event: "phx_reply",
      ref: "r1",
      payload: %{status: "ok", response: frame}
    }

    {:socket_push, :text, wire} = @v1_serializer.encode!(reply)
    assert unwrap!(BotSocket, {:socket_push, :text, wire}) == Jason.decode!(Jason.encode!(frame))
  end

  test "push carrying a bot frame is unwrapped; non-frame pushes pass through" do
    frame = %{
      "type" => "delivery",
      "api_version" => @api,
      "delivery_id" => "d-2",
      "kind" => "command_invocation",
      "channel_id" => @channel
    }

    push = %Phoenix.Socket.Message{topic: "bot:#{@bot}", event: "delivery", payload: frame}
    {:socket_push, :text, wire} = @v1_serializer.encode!(push)
    assert unwrap!(BotSocket, {:socket_push, :text, wire}) == Jason.decode!(Jason.encode!(frame))

    passthrough = %Phoenix.Socket.Message{
      topic: "bot:#{@bot}",
      event: "custom",
      payload: %{foo: "bar"}
    }

    {:socket_push, :text, wire2} = @v1_serializer.encode!(passthrough)

    assert {:push, {:text, out}, _} =
             BotSocket.handle_info({:socket_push, :text, wire2}, {nil, %Phoenix.Socket{}})

    assert wire!(out) == wire!(wire2)
  end

  # --------------------------------------- stream raw frames

  test "raw stream hello → lazy stream channel join → raw ready frame" do
    socket = stream_socket(@bot)

    socket = send_raw(BotStreamSocket, socket, %{"type" => "hello", "api_version" => @stream_api})

    assert is_pid(socket.assigns[:bot_stream_channel_pid])

    assert_receive {:socket_push, :text, wire}, 2_000
    ready = unwrap!(BotStreamSocket, {:socket_push, :text, wire})

    assert ready["type"] == "ready"
    assert ready["api_version"] == @stream_api
    assert ready["channel_id"] == @channel
    assert ready["message_id"] == @mid
    assert ready["ack_seq"] == 0
    assert is_binary(ready["expires_at"])
  end

  test "raw stream append → durable flush → raw append_ack push" do
    socket = stream_socket(@bot)
    socket = send_raw(BotStreamSocket, socket, %{"type" => "hello", "api_version" => @stream_api})
    assert_receive {:socket_push, :text, _}, 2_000

    _ =
      send_raw(BotStreamSocket, socket, %{
        "type" => "append",
        "api_version" => @stream_api,
        "seq" => 1,
        "delta" => "raw "
      })

    # the ack is a push (durable flush cadence ~250ms), not a reply
    assert_receive {:socket_push, :text, wire}, 5_000
    ack = unwrap!(BotStreamSocket, {:socket_push, :text, wire})

    assert ack == %{"type" => "append_ack", "api_version" => @stream_api, "ack_seq" => 1}
  end

  test "raw stream ping → raw pong" do
    socket = stream_socket(@bot)
    _ = send_raw(BotStreamSocket, socket, %{"type" => "ping", "api_version" => @stream_api})

    assert_receive {:socket_push, :text, wire}, 2_000
    pong = unwrap!(BotStreamSocket, {:socket_push, :text, wire})
    assert pong == %{"type" => "pong", "api_version" => @stream_api}
  end

  test "raw stream finalize → raw finalized_ack frame" do
    socket = stream_socket(@bot)
    socket = send_raw(BotStreamSocket, socket, %{"type" => "hello", "api_version" => @stream_api})
    assert_receive {:socket_push, :text, _}, 2_000

    _ =
      send_raw(BotStreamSocket, socket, %{
        "type" => "finalize",
        "api_version" => @stream_api,
        "final_seq" => 0
      })

    assert_receive {:socket_push, :text, wire}, 2_000
    ack = unwrap!(BotStreamSocket, {:socket_push, :text, wire})

    assert ack["type"] == "finalized_ack"
    assert ack["ok"] == true
    assert ack["message_id"] == @mid
    assert is_binary(ack["event_id"])
  end

  test "Phoenix-format message still takes the standard transport path (stream)" do
    socket = stream_socket(@bot)

    payload =
      Jason.encode!(%{
        "topic" => "phoenix",
        "event" => "heartbeat",
        "ref" => "hb-2",
        "payload" => %{}
      })

    state = %{channels: %{}, channels_inverse: %{}, max_channels_per_transport: 100}

    {:reply, :ok, _reply, _state} =
      BotStreamSocket.handle_in({payload, [opcode: :text]}, {state, socket})
  end

  test "phx_reply carrying a stream frame is unwrapped to a raw frame" do
    frame = %{
      "type" => "stream_error",
      "api_version" => @stream_api,
      "code" => "X",
      "message" => "m",
      "retryable" => false
    }

    reply = %Phoenix.Socket.Message{
      topic: "stream:#{@channel}##{@mid}",
      event: "phx_reply",
      ref: "r2",
      payload: %{status: "ok", response: frame}
    }

    {:socket_push, :text, wire} = @v1_serializer.encode!(reply)

    assert unwrap!(BotStreamSocket, {:socket_push, :text, wire}) ==
             Jason.decode!(Jason.encode!(frame))
  end

  # ------------------------------------------------------ connect auth

  test "connect: bearer subprotocol token + scopes + live stream → ok" do
    plaintext = BotTokens.generate_plaintext()
    seed_bot_token(@bot, plaintext, scopes: ["chat:runtime:connect", "chat:messages:write"])
    socket = %Phoenix.Socket{handler: BotStreamSocket, transport: :websocket}

    assert {:ok, socket} =
             BotStreamSocket.connect(
               %{"channel_id" => @channel, "message_id" => @mid},
               socket,
               %{
                 sec_websocket_headers: [
                   {"sec-websocket-protocol", "#{@stream_api}, bearer.#{plaintext}"}
                 ]
               }
             )

    assert socket.assigns[:bot_identity].bot_id == @bot
  end
end
