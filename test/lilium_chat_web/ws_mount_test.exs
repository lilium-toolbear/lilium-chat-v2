defmodule LiliumChatWeb.WSMountTest do
  @moduledoc """
  WS endpoint mount tests (issue #24, contract §9.7 / §10.1).

  The sockets must be reachable at their contract paths — `/api/chat/ws`
  (browser) and `/api/chat/bot/ws` (bot) — **without** Phoenix's default
  `/websocket` path suffix. The existing socket suites (browser_ws_test /
  bot_ws_test / bot_stream_ws_test) use `Phoenix.ChannelTest` or call
  `connect/3` directly: neither goes through the endpoint's plug chain,
  so a mount regression (a missing `path: ""` option) passes all of them
  and only surfaces as a 404 on a real WebSocket client — which is
  exactly what the conformance `worker,elixir` gate hit at step 3.

  These tests drive a full upgrade request through
  `LiliumChatWeb.Endpoint` (Plug.Test adapter, `server: false`) and
  assert the 101 the websocket transport returns once `connect/3`
  succeeds. A catch-all mount regression turns the 101 into the plain
  `404 Not Found` text body of `NotFoundController`.
  """

  use LiliumChatWeb.ConnCase, async: true

  import LiliumChat.TestJWT
  import LiliumChatWeb.BotFixtures

  alias LiliumChat.BotTokens

  @uid "6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e6f"
  @origin "https://lilium.kuma.homes"

  # ------------------------------------------------------------- helpers

  defp upgrade_conn(path, subprotocols) do
    headers = [
      {"host", "chat.kuma.homes"},
      {"connection", "Upgrade"},
      {"upgrade", "websocket"},
      {"sec-websocket-version", "13"},
      {"sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ=="},
      {"sec-websocket-protocol", subprotocols},
      {"origin", @origin}
    ]

    # Bandit puts every raw request header into `req_headers` (including
    # `host`); the Plug.Test adapter does not synthesize one, and
    # `Plug.Conn.put_req_header/3` refuses the `host` key, so seed both
    # the field and the list for it.
    headers
    |> Enum.reduce(Plug.Test.conn(:get, path), fn {name, value}, conn ->
      if name == "host" do
        %{conn | host: value, req_headers: [{name, value} | conn.req_headers]}
      else
        Plug.Conn.put_req_header(conn, name, value)
      end
    end)
  end

  defp call_endpoint(conn) do
    opts = LiliumChatWeb.Endpoint.init([])
    LiliumChatWeb.Endpoint.call(conn, opts)
  end

  defp seed_token(bot_id) do
    plaintext = BotTokens.generate_plaintext()
    seed_bot_token(bot_id, plaintext)
    plaintext
  end

  # ------------------------------------------------------------- browser

  test "browser socket upgrades at the contract path /api/chat/ws" do
    jwt = sign(%{"sub" => @uid})

    conn =
      upgrade_conn("/api/chat/ws", "lilium.chat.v2, bearer.#{jwt}")
      |> call_endpoint()

    assert conn.status == 101
  end

  test "browser socket rejects a bogus bearer JWT at /api/chat/ws (connect/3 ran)" do
    conn =
      upgrade_conn("/api/chat/ws", "lilium.chat.v2, bearer.not-a-jwt")
      |> call_endpoint()

    # 403 = transport error response after connect/3 failed; a 404 would
    # mean the request never reached the socket (catch-all mount).
    assert conn.status == 403
  end

  # --------------------------------------------------------------- bot

  test "bot socket upgrades at the contract path /api/chat/bot/ws" do
    bot_id = seed_bot("owner-mount-1", bot_id: "bot-mount-0001")
    plaintext = seed_token(bot_id)

    conn =
      upgrade_conn("/api/chat/bot/ws", "lilium.chat.bot.v1, bearer.#{plaintext}")
      |> call_endpoint()

    assert conn.status == 101
  end

  test "bot socket renders the contract 401 envelope for a bad token (connect/3 ran)" do
    _bot_id = seed_bot("owner-mount-2", bot_id: "bot-mount-0002")

    conn =
      upgrade_conn("/api/chat/bot/ws", "lilium.chat.bot.v1, bearer.lcbot_bogus")
      |> call_endpoint()

    assert conn.status == 401
  end
end
