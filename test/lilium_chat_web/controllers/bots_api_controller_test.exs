defmodule LiliumChatWeb.BotsApiControllerTest do
  @moduledoc """
  Full-endpoint integration tests for the Developer + Admin Bots APIs
  (contract §9.10 / §9.11, issue #16) — old-Worker wire parity.

  Parity anchors pinned here (issue #27 batch D, conformance
  `bot-http`):

  * `POST /api/chat/bots/{bot_id}/tokens` → **201** (the old Worker's
    `createBotTokenHandler` answers 201; §9.10 leaves the status silent —
    the reference implementation wins).
  * bot LOOKUP MISS on show/update/token routes → **503
    CHAT_WORKER_UNAVAILABLE "worker temporarily unavailable"** (retryable):
    in the old Worker these routes call the singleton BotRegistry DO via a
    stub RPC; a miss arrives as an untyped remote error and falls into the
    worker-wide catch-all (`src/index.ts`: unknown → CHAT_WORKER_UNAVAILABLE),
    while a DELETED bot is an explicit local `ApiError(BOT_NOT_FOUND)` → 404.
    §9.10 / §9.11 do not enumerate per-route errors, so the reference
    wire behavior is pinned.
  * deleted bot → 404 BOT_NOT_FOUND; non-owner dev access → 403 FORBIDDEN
    (checked before the deleted check).
  """

  use LiliumChatWeb.ConnCase, async: false

  import LiliumChat.TestJWT
  import LiliumChatWeb.BotFixtures

  alias LiliumChat.Repo

  @owner "6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e6f"
  @other "22222222-2222-7222-8222-222222222222"
  @bot "aaaaaaaa-bbbb-7ccc-8ddd-eeeeeeeeee01"
  @ghost "00000000-0000-7000-8000-00000000b0f1"

  setup do
    seed_bot(@owner, bot_id: @bot, display_name: "API Bot")

    on_exit(fn ->
      Repo.query!(
        "DELETE FROM chat_v2.bot_apps WHERE bot_id IN ($1, $2)",
        [@bot, @ghost],
        type: true
      )
    end)

    :ok
  end

  # ------------------------------------------------------------- helpers

  defp request(method, path, headers, body) do
    conn =
      case body do
        nil ->
          Plug.Test.conn(method, path) |> apply_headers(headers)

        json ->
          Plug.Test.conn(method, path, Jason.encode!(json))
          |> apply_headers([{"content-type", "application/json"} | headers])
      end

    opts = LiliumChatWeb.Endpoint.init([])
    LiliumChatWeb.Endpoint.call(conn, opts)
  end

  defp apply_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end)
  end

  defp jwt_headers(sub, extra_claims \\ %{}) do
    claims = Map.put(Map.new(extra_claims), "sub", sub)
    [{"authorization", "Bearer " <> sign(claims)}]
  end

  defp body_json(conn) do
    case Jason.decode(conn.resp_body) do
      {:ok, json} -> json
      :error -> conn.resp_body
    end
  end

  defp set_status!(bot_id, status) do
    Repo.query!(
      "UPDATE chat_v2.bot_apps SET status = $2, updated_at = $3 WHERE bot_id = $1",
      [bot_id, status, DateTime.utc_now()],
      type: true
    )
  end

  # -------------------------------------------------- token create (201)

  test "POST /bots/{bot_id}/tokens → 201 with one-time plaintext" do
    conn =
      request(
        :post,
        "/api/chat/bots/#{@bot}/tokens",
        jwt_headers(@owner) ++ [{"idempotency-key", "test-token-create-1"}],
        %{"name" => "deploy"}
      )

    assert 201 = conn.status
    body = body_json(conn)
    assert is_binary(body["token"]["plaintext"])
    assert body["token"]["name"] == "deploy"
  end

  # ------------------------------------------- lookup miss → 503 parity

  test "dev show: unknown bot → 503 CHAT_WORKER_UNAVAILABLE (old-Worker DO-RPC parity)" do
    conn = request(:get, "/api/chat/bots/#{@ghost}", jwt_headers(@owner), nil)
    assert 503 = conn.status

    assert body_json(conn)["error"] == %{
             "code" => "CHAT_WORKER_UNAVAILABLE",
             "message" => "worker temporarily unavailable",
             "retryable" => true
           }
  end

  test "admin show: unknown bot → 503 CHAT_WORKER_UNAVAILABLE (old-Worker DO-RPC parity)" do
    conn =
      request(
        :get,
        "/api/chat/admin/bots/#{@ghost}",
        jwt_headers(@owner, %{"admin" => true}),
        nil
      )

    assert 503 = conn.status

    assert body_json(conn)["error"] == %{
             "code" => "CHAT_WORKER_UNAVAILABLE",
             "message" => "worker temporarily unavailable",
             "retryable" => true
           }
  end

  test "admin show: non-admin → 403 ADMIN_ACCESS_REQUIRED before the lookup" do
    conn = request(:get, "/api/chat/admin/bots/#{@ghost}", jwt_headers(@owner), nil)
    assert 403 = conn.status
    assert body_json(conn)["error"]["code"] == "ADMIN_ACCESS_REQUIRED"
  end

  # --------------------------------------------- deleted bot → 404 parity

  test "dev show: deleted bot → 404 BOT_NOT_FOUND" do
    set_status!(@bot, "deleted")

    conn = request(:get, "/api/chat/bots/#{@bot}", jwt_headers(@owner), nil)
    assert 404 = conn.status

    assert body_json(conn)["error"] == %{
             "code" => "BOT_NOT_FOUND",
             "message" => "bot not found",
             "retryable" => false
           }
  end

  test "admin show: deleted bot → 404 BOT_NOT_FOUND" do
    set_status!(@bot, "deleted")

    conn =
      request(:get, "/api/chat/admin/bots/#{@bot}", jwt_headers(@owner, %{"admin" => true}), nil)

    assert 404 = conn.status
    assert body_json(conn)["error"]["code"] == "BOT_NOT_FOUND"
  end

  # --------------------------------------------------- ownership ordering

  test "dev show: non-owner → 403 FORBIDDEN 'bot access denied' (before deleted check)" do
    set_status!(@bot, "deleted")

    conn = request(:get, "/api/chat/bots/#{@bot}", jwt_headers(@other), nil)
    assert 403 = conn.status

    assert body_json(conn)["error"] == %{
             "code" => "FORBIDDEN",
             "message" => "bot access denied",
             "retryable" => false
           }
  end
end
