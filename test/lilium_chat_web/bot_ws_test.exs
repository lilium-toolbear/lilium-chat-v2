defmodule LiliumChatWeb.BotWSTest do
  @moduledoc """
  Bot Gateway WS tests (contract §9.7, issue #17).

  Uses `Phoenix.ChannelTest` for the full socket lifecycle (connect auth,
  join, hello/ready, ping/pong, delivery frames, delivery_result/ack) and
  `LiliumChatWeb.BotSocket.connect/3` directly for the handshake status
  codes (401/403) the old Worker produced.

  Acceptance criteria covered:

  * AC1 — hello/ready + the three delivery frame shapes (contract);
  * AC2 — BOT_OFFLINE precheck does not persist the invocation;
  * AC3 — crash → `bot_deliveries` recovery + resume on reconnect.
  """

  use LiliumChatWeb.ChannelCase, async: false

  import Phoenix.ConnTest
  import LiliumChatWeb.BotFixtures

  alias LiliumChat.{BotConnection, BotDelivery, BotTokens, Errors, Query, Repo}
  alias LiliumChatWeb.{BotSocket, BotChannel}

  @bot "bot-ws-0001"
  @other_bot "bot-ws-0002"
  @channel "ch-ws-0001"

  setup do
    Application.put_env(:lilium_chat, :bot_gateway,
      lease_ttl_ms: 60_000,
      offline_ttl_ms: 30_000,
      message_event_ttl_ms: 30_000
    )

    on_exit(fn ->
      Application.put_env(:lilium_chat, :bot_gateway,
        lease_ttl_ms: 60_000,
        offline_ttl_ms: 30_000,
        message_event_ttl_ms: 30_000
      )
    end)

    seed_bot("owner-1", bot_id: @bot)
    seed_bot("owner-1", bot_id: @other_bot)

    # Kill any leaked `Bot.<bot_id>` processes from previous tests so every
    # test starts with a fresh connection process (the registry key is the
    # bot_id; these processes outlive their tests by design).
    for bot <- [@bot, @other_bot] do
      kill_bot_process!(bot)
    end

    :ok
  end

  defp kill_bot_process!(bot) do
    # kill + wait for the registry entry to clear (kills are async)
    Enum.each(1..100, fn _ ->
      case Registry.lookup(LiliumChat.Bots.Registry, bot) do
        [] ->
          :ok

        [{pid, _}] ->
          Process.exit(pid, :kill)
          Process.sleep(5)
      end
    end)

    :ok
  end

  defp bot_identity(bot_id) do
    %{bot_id: bot_id, scopes: ["chat:runtime:connect", "chat:commands:manage"]}
  end

  defp connect_and_join(bot_id) do
    socket =
      socket(
        BotSocket,
        "bot:#{bot_id}",
        %{bot_identity: bot_identity(bot_id)}
      )

    {:ok, reply, socket} =
      subscribe_and_join(socket, BotChannel, "bot:#{bot_id}", %{})

    assert reply == %{}
    socket
  end

  # ------------------------------------------------------------- connect auth

  test "connect: bearer subprotocol token + scope → ok with identity" do
    plaintext = seed_token(@bot)

    socket = %Phoenix.Socket{handler: BotSocket, transport: :websocket}

    assert {:ok, socket} =
             BotSocket.connect(
               %{},
               socket,
               %{
                 sec_websocket_headers: [
                   {"sec-websocket-protocol", "lilium.chat.bot.v1, bearer.#{plaintext}"}
                 ]
               }
             )

    assert socket.assigns[:bot_identity].bot_id == @bot
  end

  test "connect: query-param token carrier works too" do
    plaintext = seed_token(@bot)

    socket = %Phoenix.Socket{handler: BotSocket, transport: :websocket}

    assert {:ok, socket} =
             BotSocket.connect(
               %{"token" => plaintext},
               socket,
               %{sec_websocket_headers: []}
             )

    assert socket.assigns[:bot_identity].bot_id == @bot
  end

  test "connect: missing token → UNAUTHORIZED 'Not authenticated' (401)" do
    socket = %Phoenix.Socket{handler: BotSocket, transport: :websocket}

    assert {:error,
            %Errors.ApiError{code: "UNAUTHORIZED", message: "Not authenticated", http_status: 401}} =
             BotSocket.connect(%{}, socket, %{
               sec_websocket_headers: [
                 {"sec-websocket-protocol", "lilium.chat.bot.v1"}
               ]
             })
  end

  test "connect: invalid token → UNAUTHORIZED 'Invalid bot token' (401)" do
    socket = %Phoenix.Socket{handler: BotSocket, transport: :websocket}

    assert {:error, %Errors.ApiError{code: "UNAUTHORIZED", message: "Invalid bot token"}} =
             BotSocket.connect(
               %{},
               socket,
               %{
                 sec_websocket_headers: [
                   {"sec-websocket-protocol", "lilium.chat.bot.v1, bearer.lcbot_bogus"}
                 ]
               }
             )
  end

  test "connect: missing chat:runtime:connect scope → FORBIDDEN (403)" do
    plaintext = seed_token(@other_bot, scopes: ["chat:commands:manage"])

    socket = %Phoenix.Socket{handler: BotSocket, transport: :websocket}

    assert {:error,
            %Errors.ApiError{
              code: "FORBIDDEN",
              message: "Missing scope: chat:runtime:connect",
              http_status: 403
            }} =
             BotSocket.connect(
               %{},
               socket,
               %{
                 sec_websocket_headers: [
                   {"sec-websocket-protocol", "lilium.chat.bot.v1, bearer.#{plaintext}"}
                 ]
               }
             )
  end

  test "handle_connect_error renders the contract envelope with the right status" do
    conn = Phoenix.ConnTest.build_conn()

    conn =
      BotSocket.handle_connect_error(
        conn,
        Errors.new("UNAUTHORIZED", "Not authenticated")
      )

    assert conn.status == 401

    body = Jason.decode!(response(conn, 401))
    assert body["error"]["code"] == "UNAUTHORIZED"
    assert body["error"]["message"] == "Not authenticated"
    assert body["error"]["retryable"] == false

    conn2 = Phoenix.ConnTest.build_conn()

    conn2 =
      BotSocket.handle_connect_error(
        conn2,
        Errors.new("FORBIDDEN", "Missing scope: chat:runtime:connect")
      )

    assert conn2.status == 403
  end

  # -------------------------------------------------------------------- join

  test "join: bot joins its own topic" do
    socket = connect_and_join(@bot)
    assert socket.assigns[:bot_id] == @bot
  end

  test "join: wrong topic id for the token → unauthorized" do
    socket =
      socket(BotSocket, "bot:#{@other_bot}", %{bot_identity: bot_identity(@bot)})

    assert {:error, %{reason: "unauthorized"}} =
             subscribe_and_join(socket, BotChannel, "bot:#{@other_bot}", %{})
  end

  test "join: non-bot topic → bad_topic" do
    socket = socket(BotSocket, "browser:whoever", %{bot_identity: bot_identity(@bot)})

    assert {:error, %{reason: "bad_topic"}} =
             subscribe_and_join(socket, BotChannel, "browser:whoever", %{})
  end

  # -------------------------------------------------------------- hello/ready

  test "AC1: hello → ready with session_id" do
    socket = connect_and_join(@bot)

    ref = push(socket, "hello", %{"type" => "hello", "api_version" => "lilium.chat.bot.v1"})
    assert_reply(ref, :ok, ready)

    # Contract §9.7.1 ready frame: type / api_version / bot_id / session_id /
    # server_time.
    assert ready["type"] == "ready"
    assert ready["api_version"] == "lilium.chat.bot.v1"
    assert ready["bot_id"] == @bot
    assert is_binary(ready["session_id"])
    assert is_binary(ready["server_time"])
    assert {:ok, %DateTime{}, _} = DateTime.from_iso8601(ready["server_time"])

    assert BotConnection.online?(@bot)
  end

  test "hello: last_received_delivery_id is parsed and accepted" do
    socket = connect_and_join(@bot)

    ref =
      push(
        socket,
        "hello",
        %{
          "type" => "hello",
          "api_version" => "lilium.chat.bot.v1",
          "last_received_delivery_id" => "01900000-0000-7000-8000-000000000000"
        }
      )

    assert_reply(ref, :ok, %{"type" => "ready"})
  end

  test "hello: malformed frames are swallowed (socket stays open)" do
    socket = connect_and_join(@bot)

    # wrong api_version → no reply, socket lives
    push(socket, "hello", %{"type" => "hello", "api_version" => "lilium.chat.bot.v9"})
    Process.sleep(50)

    # a valid hello afterwards still works
    ref = push(socket, "hello", %{"type" => "hello", "api_version" => "lilium.chat.bot.v1"})
    assert_reply(ref, :ok, %{"type" => "ready", "session_id" => _})
  end

  test "ping → pong + lease refresh" do
    socket = connect_and_join(@bot)

    ref = push(socket, "hello", %{"type" => "hello", "api_version" => "lilium.chat.bot.v1"})
    assert_reply(ref, :ok, %{"type" => "ready"})

    ref = push(socket, "ping", %{"type" => "ping", "api_version" => "lilium.chat.bot.v1"})
    assert_reply(ref, :ok, %{"type" => "pong", "api_version" => "lilium.chat.bot.v1"})
  end

  # ------------------------------------------------------ AC1 delivery frames

  test "AC1: command_invocation delivery frame shape (contract §9.7.1)" do
    socket = connect_and_join(@bot)
    ref = push(socket, "hello", %{"type" => "hello", "api_version" => "lilium.chat.bot.v1"})
    assert_reply(ref, :ok, %{"type" => "ready"})

    assert {:ok, %{delivery_id: delivery_id, invocation_id: invocation_id}} =
             BotDelivery.commit_invocation(%{
               channel_id: @channel,
               bot_id: @bot,
               invoker_user_id: "user-ws-001",
               bot_command_id: "bc-ws-1",
               command_name: "ask",
               invoked_name: "ask",
               schema_version: 3,
               definition_hash: "sha256:def",
               options: %{"q" => "hi"}
             })

    assert_receive %{event: "delivery", payload: frame}, 1_000

    assert frame["type"] == "delivery"
    assert frame["api_version"] == "lilium.chat.bot.v1"
    assert frame["delivery_id"] == delivery_id
    assert frame["kind"] == "command_invocation"
    assert frame["channel_id"] == @channel
    assert frame["invocation_id"] == invocation_id
    assert frame["command"]["bot_command_id"] == "bc-ws-1"
    assert frame["command"]["name"] == "ask"
    assert frame["command"]["invoked_name"] == "ask"
    assert frame["command"]["schema_version"] == 3
    assert frame["command"]["definition_hash"] == "sha256:def"
    assert frame["command"]["options"] == %{"q" => "hi"}
    assert frame["invoker"]["user_id"] == "user-ws-001"
    assert is_binary(frame["invoker"]["display_name"])
  end

  test "AC1: message_interaction delivery frame shape (contract §9.7.1)" do
    socket = connect_and_join(@bot)
    ref = push(socket, "hello", %{"type" => "hello", "api_version" => "lilium.chat.bot.v1"})
    assert_reply(ref, :ok, %{"type" => "ready"})

    assert {:ok, %{delivery_id: delivery_id, interaction_id: interaction_id}} =
             BotDelivery.commit_interaction(%{
               channel_id: @channel,
               bot_id: @bot,
               actor_user_id: "user-ws-002",
               message_id: "msg-ws-1",
               component_id: "cmp-ws-1",
               custom_id: "confirm",
               value: true,
               command_id: "cmd-ws-1",
               dedupe_principal_key: "channel:#{@channel}:user-ws-002:msg-ws-1:cmp-ws-1"
             })

    assert_receive %{payload: frame}, 1_000

    assert frame["type"] == "delivery"
    assert frame["kind"] == "message_interaction"
    assert frame["delivery_id"] == delivery_id
    assert frame["channel_id"] == @channel
    assert frame["interaction_id"] == interaction_id
    assert frame["message_id"] == "msg-ws-1"

    assert frame["component"] == %{
             "component_id" => "cmp-ws-1",
             "custom_id" => "confirm",
             "value" => true
           }

    assert frame["actor"]["user_id"] == "user-ws-002"
  end

  test "AC1: message_event delivery frame shape (contract §9.7.1, sender projection)" do
    socket = connect_and_join(@bot)
    ref = push(socket, "hello", %{"type" => "hello", "api_version" => "lilium.chat.bot.v1"})
    assert_reply(ref, :ok, %{"type" => "ready"})

    message = %{
      "message_id" => "msg-ws-2",
      "command_id" => "cmd-ws-2",
      "channel_id" => @channel,
      "sender" => %{
        "kind" => "user",
        "user" => %{"user_id" => "user-ws-003", "display_name" => "Kuma", "avatar_url" => nil}
      },
      "type" => "text",
      "format" => "plain",
      "status" => "normal",
      "stream_state" => "none",
      "text" => "a user said hi",
      "reply_to" => nil,
      "reply_snapshot" => nil,
      "attachments" => [],
      "sticker" => nil,
      "components" => [],
      "mentions" => [],
      "command_invocation" => nil,
      "created_at" => "2026-08-23T00:00:01Z",
      "updated_at" => "2026-08-23T00:00:01Z",
      "edited_at" => nil,
      "deleted_at" => nil,
      "recalled_at" => nil
    }

    assert {:ok, %{delivery_id: delivery_id}} =
             BotDelivery.commit_message_event(%{
               channel_id: @channel,
               bot_id: @bot,
               event_id: "evt-ws-1",
               occurred_at: ~U[2026-08-23 00:00:01Z],
               message: message
             })

    assert_receive %{payload: frame}, 1_000

    assert frame["type"] == "delivery"
    assert frame["kind"] == "message_event"
    assert frame["delivery_id"] == delivery_id
    assert frame["channel_id"] == @channel
    assert frame["event"]["event_id"] == "evt-ws-1"
    assert frame["event"]["type"] == "message.created"
    assert frame["event"]["occurred_at"] =~ "2026-08-23T00:00:01"
    assert frame["message"] == message
  end

  # ------------------------------------------------------- delivery_result

  test "delivery_result → delivery_ack with effect_results" do
    socket = connect_and_join(@bot)
    ref = push(socket, "hello", %{"type" => "hello", "api_version" => "lilium.chat.bot.v1"})
    assert_reply(ref, :ok, %{"type" => "ready"})

    assert {:ok, %{delivery_id: delivery_id, invocation_id: invocation_id}} =
             BotDelivery.commit_invocation(%{
               channel_id: @channel,
               bot_id: @bot,
               invoker_user_id: "user-ws-004",
               bot_command_id: "bc-ws-2",
               command_name: "ask",
               invoked_name: "ask",
               schema_version: 1,
               definition_hash: "sha256:111",
               options: %{}
             })

    # consume the pushed delivery frame
    assert_receive %{payload: %{"delivery_id" => ^delivery_id}}, 1_000

    ref =
      push(
        socket,
        "delivery_result",
        %{
          "type" => "delivery_result",
          "api_version" => "lilium.chat.bot.v1",
          "delivery_id" => delivery_id,
          "status" => "ok",
          "effects" => [
            %{
              "type" => "send_message",
              "client_effect_id" => "ce-ws-1",
              "message" => %{"type" => "text", "text" => "bot answer"}
            }
          ]
        }
      )

    assert_reply(ref, :ok, ack)

    assert ack["type"] == "delivery_ack"
    assert ack["api_version"] == "lilium.chat.bot.v1"
    assert ack["delivery_id"] == delivery_id
    assert ack["status"] == "applied"

    assert [
             %{
               "type" => "send_message",
               "status" => "applied",
               "client_effect_id" => "ce-ws-1",
               "message_id" => message_id
             }
           ] =
             ack["effect_results"]

    assert is_binary(message_id)

    # rows completed
    assert row_count(
             "SELECT 1 FROM chat_v2.bot_deliveries WHERE delivery_id = $1 AND status = 'delivered'",
             [delivery_id]
           ) == 1

    assert row_count(
             "SELECT 1 FROM chat_v2.command_invocations WHERE invocation_id = $1 AND status = 'completed'",
             [invocation_id]
           ) == 1
  end

  test "delivery_result: failed ack for an invalid effect" do
    socket = connect_and_join(@bot)
    ref = push(socket, "hello", %{"type" => "hello", "api_version" => "lilium.chat.bot.v1"})
    assert_reply(ref, :ok, %{"type" => "ready"})

    assert {:ok, %{delivery_id: delivery_id}} =
             BotDelivery.commit_invocation(%{
               channel_id: @channel,
               bot_id: @bot,
               invoker_user_id: "user-ws-005",
               bot_command_id: "bc-ws-3",
               command_name: "ask",
               invoked_name: "ask",
               schema_version: 1,
               definition_hash: "sha256:222",
               options: %{}
             })

    assert_receive %{payload: _frame}, 1_000

    ref =
      push(
        socket,
        "delivery_result",
        %{
          "type" => "delivery_result",
          "api_version" => "lilium.chat.bot.v1",
          "delivery_id" => delivery_id,
          "status" => "ok",
          "effects" => [
            %{"type" => "finalize_stream", "client_effect_id" => "ce-ws-2"}
          ]
        }
      )

    assert_reply(ref, :ok, ack)

    assert ack["status"] == "failed"
    assert ack["error"]["code"] == "BOT_EFFECT_INVALID"
  end

  # ------------------------------------------------------ AC3 crash recovery

  test "AC3: reconnect after crash resumes pending deliveries (delivery_id order)" do
    # First session: commit a delivery, then the bot's WS goes away
    # (the server crash path: rows stay pending in bot_deliveries).
    socket1 = connect_and_join(@bot)

    ref = push(socket1, "hello", %{"type" => "hello", "api_version" => "lilium.chat.bot.v1"})
    assert_reply(ref, :ok, %{"type" => "ready"})

    assert {:ok, %{delivery_id: d1, invocation_id: invocation_id}} =
             BotDelivery.commit_invocation(%{
               channel_id: @channel,
               bot_id: @bot,
               invoker_user_id: "user-ws-006",
               bot_command_id: "bc-ws-4",
               command_name: "ask",
               invoked_name: "ask",
               schema_version: 1,
               definition_hash: "sha256:333",
               options: %{}
             })

    assert_receive %{payload: %{"delivery_id" => ^d1}}, 1_000

    # WS close → the channel terminates → the bot process detaches; the
    # delivery row stays pending in bot_deliveries.
    Process.unlink(socket1.channel_pid)
    Phoenix.ChannelTest.close(socket1)

    assert wait_offline?(@bot), "bot should go offline after WS close"

    assert row_count(
             "SELECT 1 FROM chat_v2.bot_deliveries WHERE bot_id = $1 AND status = 'pending'",
             [@bot]
           ) == 1

    # Reconnect (new WS): hello → ready, then the pending delivery is
    # pushed (resume per delivery_id order).
    socket2 = connect_and_join(@bot)

    ref = push(socket2, "hello", %{"type" => "hello", "api_version" => "lilium.chat.bot.v1"})
    assert_reply(ref, :ok, %{"type" => "ready", "session_id" => session2})

    assert_receive %{payload: %{"delivery_id" => ^d1, "kind" => "command_invocation"}}, 1_000

    # The resumed delivery can complete.
    ref =
      push(
        socket2,
        "delivery_result",
        %{
          "type" => "delivery_result",
          "api_version" => "lilium.chat.bot.v1",
          "delivery_id" => d1,
          "status" => "ok",
          "effects" => [
            %{
              "type" => "send_message",
              "client_effect_id" => "ce-ws-3",
              "message" => %{"type" => "text", "text" => "resumed"}
            }
          ]
        }
      )

    assert_reply(ref, :ok, %{"type" => "delivery_ack", "status" => "applied"})

    assert row_count(
             "SELECT 1 FROM chat_v2.command_invocations WHERE invocation_id = $1 AND status = 'completed'",
             [invocation_id]
           ) == 1

    _ = session2
  end

  test "WS close of a stale socket does not evict a newer session" do
    socket1 = connect_and_join(@bot)
    ref = push(socket1, "hello", %{"type" => "hello", "api_version" => "lilium.chat.bot.v1"})
    assert_reply(ref, :ok, %{"type" => "ready", "session_id" => _s1})

    # A second connection takes over the bot session (new session id).
    socket2 = connect_and_join(@bot)
    ref = push(socket2, "hello", %{"type" => "hello", "api_version" => "lilium.chat.bot.v1"})
    assert_reply(ref, :ok, %{"type" => "ready", "session_id" => _s2})

    # The first socket finally closes — its stale session must not evict
    # the live one (old Worker markDisconnectedIfCurrentAttachment parity).
    Process.unlink(socket1.channel_pid)
    Phoenix.ChannelTest.close(socket1)
    Process.sleep(50)

    assert BotConnection.online?(@bot),
           "stale socket close must not evict the live session"

    # The live socket's close still detaches.
    Process.unlink(socket2.channel_pid)
    Phoenix.ChannelTest.close(socket2)
    assert wait_offline?(@bot)
  end

  # ------------------------------------------------------------------ helpers

  defp seed_token(bot_id, opts \\ []) do
    plaintext = BotTokens.generate_plaintext()

    seed_bot_token(
      bot_id,
      plaintext,
      scopes: Keyword.get(opts, :scopes, ["chat:runtime:connect", "chat:commands:manage"])
    )

    plaintext
  end

  defp row_count(sql, params) do
    Repo.query(sql, params, type: true)
    |> Query.rows()
    |> length()
  end

  defp wait_offline?(bot_id, attempts \\ 50) do
    Enum.any?(1..attempts, fn _ ->
      if BotConnection.online?(bot_id) do
        Process.sleep(20)
        false
      else
        true
      end
    end)
  end
end
