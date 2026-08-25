defmodule LiliumChatWeb.BotStreamWSTest do
  @moduledoc """
  Bot Stream WS socket + channel (contract §9.15, issue #18).
  """

  use LiliumChatWeb.ChannelCase, async: false

  import LiliumChatWeb.BotFixtures
  import LiliumChatWeb.ReadFixtures
  import Phoenix.ConnTest

  alias LiliumChat.{BotTokens, Errors, Stream}
  alias LiliumChatWeb.{BotStreamChannel, BotStreamSocket}

  @bot "bot-sws-0001"
  @other "bot-sws-0002"
  @channel "ch-sws-0001"
  @mid "msg-sws-0001"
  @api "lilium.chat.bot.stream.v1"

  setup do
    seed_bot("owner-1", bot_id: @bot)
    seed_bot("owner-1", bot_id: @other)
    seed_channel(@channel)
    kill_stream!(@channel, @mid)

    {:ok, _} = Stream.start_stream(@channel, @mid, @bot, %{"type" => "text"})

    on_exit(fn -> kill_stream!(@channel, @mid) end)
    :ok
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

  defp identity(bot_id) do
    %{bot_id: bot_id, scopes: ["chat:runtime:connect", "chat:messages:write"]}
  end

  defp topic(channel_id \\ @channel, message_id \\ @mid), do: "stream:#{channel_id}##{message_id}"

  defp connect_and_join(bot_id \\ @bot) do
    socket =
      socket(BotStreamSocket, topic(), %{
        bot_identity: identity(bot_id),
        channel_id: @channel,
        message_id: @mid
      })

    {:ok, reply, socket} = subscribe_and_join(socket, BotStreamChannel, topic(), %{})
    assert reply == %{}
    socket
  end

  defp seed_token(bot_id, opts \\ []) do
    plaintext = BotTokens.generate_plaintext()

    seed_bot_token(
      bot_id,
      plaintext,
      scopes: Keyword.get(opts, :scopes, ["chat:runtime:connect", "chat:messages:write"])
    )

    plaintext
  end

  # ------------------------------------------------------------- connect auth

  test "connect: bearer token + both scopes → ok" do
    plaintext = seed_token(@bot)
    socket = %Phoenix.Socket{handler: BotStreamSocket, transport: :websocket}

    assert {:ok, socket} =
             BotStreamSocket.connect(
               %{"channel_id" => @channel, "message_id" => @mid},
               socket,
               %{
                 sec_websocket_headers: [
                   {"sec-websocket-protocol", "#{@api}, bearer.#{plaintext}"}
                 ]
               }
             )

    assert socket.assigns[:bot_identity].bot_id == @bot
    assert socket.assigns[:channel_id] == @channel
    assert socket.assigns[:message_id] == @mid
  end

  test "connect: missing write scope → BOT_SCOPE_DENIED" do
    plaintext = seed_token(@bot, scopes: ["chat:runtime:connect"])
    socket = %Phoenix.Socket{handler: BotStreamSocket, transport: :websocket}

    assert {:error, %Errors.ApiError{code: "BOT_SCOPE_DENIED"}} =
             BotStreamSocket.connect(
               %{"channel_id" => @channel, "message_id" => @mid},
               socket,
               %{
                 sec_websocket_headers: [
                   {"sec-websocket-protocol", "#{@api}, bearer.#{plaintext}"}
                 ]
               }
             )
  end

  test "connect: missing write scope → old Worker scope wording parity" do
    plaintext = seed_token(@bot, scopes: ["chat:runtime:connect"])
    socket = %Phoenix.Socket{handler: BotStreamSocket, transport: :websocket}

    assert {:error,
            %Errors.ApiError{
              code: "BOT_SCOPE_DENIED",
              message: "Missing scope: chat:messages:write"
            }} =
             BotStreamSocket.connect(
               %{"channel_id" => @channel, "message_id" => @mid},
               socket,
               %{
                 sec_websocket_headers: [
                   {"sec-websocket-protocol", "#{@api}, bearer.#{plaintext}"}
                 ]
               }
             )
  end

  test "connect: unknown stream → BOT_STREAM_NOT_FOUND (old Worker route 404 parity)" do
    plaintext = seed_token(@bot)
    socket = %Phoenix.Socket{handler: BotStreamSocket, transport: :websocket}

    assert {:error,
            %Errors.ApiError{code: "BOT_STREAM_NOT_FOUND", message: "stream registry not found"}} =
             BotStreamSocket.connect(
               %{"channel_id" => @channel, "message_id" => "msg-sws-unknown"},
               socket,
               %{
                 sec_websocket_headers: [
                   {"sec-websocket-protocol", "#{@api}, bearer.#{plaintext}"}
                 ]
               }
             )
  end

  test "connect: foreign owner → BOT_STREAM_NOT_FOUND (old Worker route 404 parity)" do
    plaintext = seed_token(@other)
    socket = %Phoenix.Socket{handler: BotStreamSocket, transport: :websocket}

    assert {:error,
            %Errors.ApiError{code: "BOT_STREAM_NOT_FOUND", message: "stream registry not found"}} =
             BotStreamSocket.connect(
               %{"channel_id" => @channel, "message_id" => @mid},
               socket,
               %{
                 sec_websocket_headers: [
                   {"sec-websocket-protocol", "#{@api}, bearer.#{plaintext}"}
                 ]
               }
             )
  end

  test "connect: finalized stream → BOT_STREAM_EXPIRED (old Worker route 410 parity)" do
    {:ok, _} =
      Stream.finalize(@channel, @mid, %{
        "final_seq" => 0,
        "components" => nil,
        "attachment_ids" => nil
      })

    plaintext = seed_token(@bot)
    socket = %Phoenix.Socket{handler: BotStreamSocket, transport: :websocket}

    assert {:error,
            %Errors.ApiError{code: "BOT_STREAM_EXPIRED", message: "stream registry expired"}} =
             BotStreamSocket.connect(
               %{"channel_id" => @channel, "message_id" => @mid},
               socket,
               %{
                 sec_websocket_headers: [
                   {"sec-websocket-protocol", "#{@api}, bearer.#{plaintext}"}
                 ]
               }
             )
  end

  test "connect: missing token → UNAUTHORIZED" do
    socket = %Phoenix.Socket{handler: BotStreamSocket, transport: :websocket}

    assert {:error, %Errors.ApiError{code: "UNAUTHORIZED"}} =
             BotStreamSocket.connect(
               %{"channel_id" => @channel, "message_id" => @mid},
               socket,
               %{sec_websocket_headers: [{"sec-websocket-protocol", @api}]}
             )
  end

  test "handle_connect_error renders the contract envelope" do
    conn = Phoenix.ConnTest.build_conn()

    conn =
      BotStreamSocket.handle_connect_error(
        conn,
        Errors.new("BOT_SCOPE_DENIED", "Missing required bot scope: chat:messages:write")
      )

    assert conn.status == 403
    body = Jason.decode!(response(conn, 403))
    assert body["error"]["code"] == "BOT_SCOPE_DENIED"
  end

  # -------------------------------------------------------------------- join

  test "join: matching topic + hello → ready with ack_seq" do
    socket = connect_and_join()

    ref = push(socket, "hello", %{"type" => "hello", "api_version" => @api})
    assert_reply ref, :ok, ready

    assert ready["type"] == "ready"
    assert ready["api_version"] == @api
    assert ready["channel_id"] == @channel
    assert ready["message_id"] == @mid
    assert ready["ack_seq"] == 0
    assert is_binary(ready["expires_at"])
  end

  test "join: wrong bot for the stream topic → unauthorized" do
    socket =
      socket(BotStreamSocket, topic(), %{
        bot_identity: identity(@other),
        channel_id: @channel,
        message_id: @mid
      })

    assert {:error, %{reason: "unauthorized"}} =
             subscribe_and_join(socket, BotStreamChannel, topic(), %{})
  end

  test "ping → pong" do
    socket = connect_and_join()
    ref = push(socket, "ping", %{"type" => "ping", "api_version" => @api})
    assert_reply ref, :ok, pong
    assert pong["type"] == "pong"
  end

  # ---------------------------------------------------------- append/finalize

  test "append then finalize: seq/ack frames + idempotent finalized_ack" do
    socket = connect_and_join()
    ref = push(socket, "hello", %{"type" => "hello", "api_version" => @api})
    assert_reply ref, :ok, _ready

    ref =
      push(socket, "append", %{
        "type" => "append",
        "api_version" => @api,
        "seq" => 1,
        "delta" => "Hi"
      })

    # Durable flush is cadence-driven (250ms); append_ack is a server push,
    # not a Phoenix reply to the append frame.
    assert_push "append_ack", %{"type" => "append_ack", "ack_seq" => 1}, 500
    refute_reply ref, :ok, %{}, 10

    ref =
      push(socket, "finalize", %{
        "type" => "finalize",
        "api_version" => @api,
        "final_seq" => 1
      })

    assert_reply ref, :ok, ack
    assert ack["type"] == "finalized_ack"
    assert ack["ok"] == true
    assert ack["message_id"] == @mid
    assert is_binary(ack["event_id"])

    ref =
      push(socket, "finalize", %{
        "type" => "finalize",
        "api_version" => @api,
        "final_seq" => 1
      })

    assert_reply ref, :ok, replay
    assert replay == ack
  end

  test "append sequence gap → stream_error BOT_STREAM_SEQUENCE_GAP" do
    socket = connect_and_join()
    ref = push(socket, "hello", %{"type" => "hello", "api_version" => @api})
    assert_reply ref, :ok, _

    ref =
      push(socket, "append", %{
        "type" => "append",
        "api_version" => @api,
        "seq" => 2,
        "delta" => "x"
      })

    assert_reply ref, :error, err
    assert err["type"] == "stream_error"
    assert err["code"] == "BOT_STREAM_SEQUENCE_GAP"
    assert err["retryable"] == true
  end

  test "finalize with components → stream_error BOT_EFFECT_INVALID" do
    socket = connect_and_join()
    ref = push(socket, "hello", %{"type" => "hello", "api_version" => @api})
    assert_reply ref, :ok, _

    ref =
      push(socket, "finalize", %{
        "type" => "finalize",
        "api_version" => @api,
        "final_seq" => 0,
        "components" => [%{"type" => "button"}]
      })

    assert_reply ref, :error, err
    assert err["type"] == "stream_error"
    assert err["code"] == "BOT_EFFECT_INVALID"
  end
end
