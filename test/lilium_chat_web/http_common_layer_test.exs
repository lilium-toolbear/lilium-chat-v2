defmodule LiliumChatWeb.HTTPCommonLayerTest do
  @moduledoc """
  Full-endpoint integration tests for the HTTP common layer (issue #2).

  Runs real conns through the ENTIRE endpoint pipeline (CORS plug →
  RequestId plug → router → AuthPlug → controller), exactly as Bandit would
  serve them. Covers the issue's acceptance criteria:

    * no token / invalid token / expired token → correct code + envelope +
      X-Request-Id;
    * JWT boundaries (MACHINE_TOKEN_NOT_ALLOWED / SESSION_NOT_ALLOWED / admin);
    * CORS / Origin whitelist behavior identical to the old Worker;
    * 404 notFound parity and CHAT_WORKER_UNAVAILABLE fallback.
  """

  use LiliumChatWeb.ConnCase, async: true

  import LiliumChat.TestJWT

  @origin "https://lilium.kuma.homes"
  @uid "6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e6f"

  # ------------------------------------------------------------------ helpers

  defp request(method, path, headers) do
    conn =
      Plug.Test.conn(method, path)
      |> apply_headers(headers)

    opts = LiliumChatWeb.Endpoint.init([])
    LiliumChatWeb.Endpoint.call(conn, opts)
  end

  defp apply_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end)
  end

  defp auth_headers(claims, opts \\ []) do
    [{"authorization", "Bearer " <> sign(Map.put_new(claims, "sub", @uid), opts)}]
  end

  defp body_json(conn) do
    case Jason.decode(conn.resp_body) do
      {:ok, json} -> json
      :error -> conn.resp_body
    end
  end

  # ------------------------------------------------- auth: no/bad/expired token

  test "no Authorization header → 401 UNAUTHORIZED 'Not authenticated' + envelope + X-Request-Id" do
    conn = request(:get, "/api/chat/channels", [{"origin", @origin}])

    assert conn.status == 401
    assert get_resp_header(conn, "content-type") == ["application/json"]

    json = body_json(conn)
    assert json["error"]["code"] == "UNAUTHORIZED"
    assert json["error"]["message"] == "Not authenticated"
    assert json["error"]["retryable"] == false

    [id] = get_resp_header(conn, "x-request-id")
    assert id =~ ~r/^req_[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
    assert json["request_id"] == id
  end

  test "garbage Bearer token → 401 UNAUTHORIZED 'Invalid or expired token'" do
    conn =
      request(:get, "/api/chat/channels", [
        {"origin", @origin},
        {"authorization", "Bearer not-a-valid-jwt"}
      ])

    assert conn.status == 401
    json = body_json(conn)
    assert json["error"]["code"] == "UNAUTHORIZED"
    assert json["error"]["message"] == "Invalid or expired token"
    assert get_resp_header(conn, "x-request-id") != []
  end

  test "wrong-secret token → 401 UNAUTHORIZED" do
    conn = request(:get, "/api/chat/channels", auth_headers(%{}, secret: "wrong-secret"))
    assert conn.status == 401
    assert body_json(conn)["error"]["code"] == "UNAUTHORIZED"
  end

  test "expired token → 401 UNAUTHORIZED" do
    exp = System.system_time(:second) - 60
    conn = request(:get, "/api/chat/channels", auth_headers(%{}, exp: exp))
    assert conn.status == 401
    json = body_json(conn)
    assert json["error"]["code"] == "UNAUTHORIZED"
    assert json["error"]["message"] == "Invalid or expired token"
  end

  # ------------------------------------------------------------- JWT boundaries

  test "valid user token → 200 with the empty-state channel list shape" do
    conn = request(:get, "/api/chat/channels", auth_headers(%{}))
    assert conn.status == 200
    assert body_json(conn) == %{"items" => [], "next_cursor" => nil}
    assert get_resp_header(conn, "x-request-id") != []
  end

  test "admin claim token → accepted (is_admin boundary, A6)" do
    conn = request(:get, "/api/chat/channels", auth_headers(%{"admin" => true}))
    assert conn.status == 200
    assert body_json(conn) == %{"items" => [], "next_cursor" => nil}
  end

  test "machine token (client_id) → 401 MACHINE_TOKEN_NOT_ALLOWED (A6)" do
    conn =
      request(:get, "/api/chat/channels", auth_headers(%{"client_id" => "conformance-client"}))

    assert conn.status == 401
    json = body_json(conn)
    assert json["error"]["code"] == "MACHINE_TOKEN_NOT_ALLOWED"
    assert json["error"]["message"] == "Machine tokens are not allowed"
    assert json["error"]["retryable"] == false
    assert get_resp_header(conn, "x-request-id") != []
  end

  test "managed_session=true → 403 SESSION_NOT_ALLOWED (A6)" do
    conn = request(:get, "/api/chat/channels", auth_headers(%{"managed_session" => true}))

    assert conn.status == 403
    json = body_json(conn)
    assert json["error"]["code"] == "SESSION_NOT_ALLOWED"
    assert json["error"]["message"] == "Chat requires a direct user session"
  end

  test "delegated session (owner_user_id != sub) → 403 SESSION_NOT_ALLOWED (A6)" do
    conn = request(:get, "/api/chat/channels", auth_headers(%{"owner_user_id" => "some-owner"}))

    assert conn.status == 403
    assert body_json(conn)["error"]["code"] == "SESSION_NOT_ALLOWED"
  end

  # ------------------------------------------------------------- CORS behavior

  test "allowed Origin → mirrored allow-origin + expose-headers + vary (old Worker parity)" do
    conn = request(:get, "/api/chat/channels", [{"origin", @origin}])

    assert get_resp_header(conn, "access-control-allow-origin") == [@origin]
    assert get_resp_header(conn, "access-control-expose-headers") == ["X-Request-Id"]
    assert get_resp_header(conn, "vary") == ["Origin"]
  end

  test "disallowed Origin → no allow-origin (browser blocks), expose + vary still sent" do
    conn = request(:get, "/api/chat/channels", [{"origin", "https://evil.example"}])

    assert get_resp_header(conn, "access-control-allow-origin") == []
    assert get_resp_header(conn, "access-control-expose-headers") == ["X-Request-Id"]
    assert get_resp_header(conn, "vary") == ["Origin"]
  end

  test "OPTIONS preflight → 204 with the exact production preflight header set" do
    conn =
      request(:options, "/api/chat/channels", [
        {"origin", @origin},
        {"access-control-request-method", "POST"},
        {"access-control-request-headers", "authorization,content-type"}
      ])

    assert conn.status == 204
    assert conn.resp_body == ""
    assert get_resp_header(conn, "access-control-allow-origin") == [@origin]
    assert get_resp_header(conn, "access-control-expose-headers") == ["X-Request-Id"]
    assert get_resp_header(conn, "vary") == ["Origin, Access-Control-Request-Headers"]
    assert get_resp_header(conn, "access-control-max-age") == ["86400"]
    assert get_resp_header(conn, "access-control-allow-methods") == ["GET,POST,PATCH,PUT,DELETE"]

    assert get_resp_header(conn, "access-control-allow-headers") == [
             "Authorization,Content-Type,Idempotency-Key"
           ]
  end

  # ------------------------------------------------------- X-Request-Id echo

  test "inbound X-Request-Id is echoed in header and error envelope (old Worker parity)" do
    conn =
      request(:get, "/api/chat/channels", [
        {"origin", @origin},
        {"x-request-id", "req_client-trace-id"}
      ])

    assert get_resp_header(conn, "x-request-id") == ["req_client-trace-id"]
    assert body_json(conn)["request_id"] == "req_client-trace-id"
  end

  # ------------------------------------------------- notFound + error fallback

  test "unknown /api/chat/* path → 404 text/plain '404 Not Found' (Hono notFound parity, no auth)" do
    conn = request(:get, "/api/chat/nope", [{"origin", @origin}])

    assert conn.status == 404
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=UTF-8"]
    assert conn.resp_body == "404 Not Found"
    # request-id + CORS middlewares still apply (production order: middleware before routing)
    assert get_resp_header(conn, "x-request-id") != []
    assert get_resp_header(conn, "access-control-allow-origin") == [@origin]
  end

  test "unknown non-/api/chat path → 404 text/plain '404 Not Found'" do
    conn = request(:get, "/", [])
    assert conn.status == 404
    assert conn.resp_body == "404 Not Found"
  end

  test "handler exception → 503 CHAT_WORKER_UNAVAILABLE envelope (appOnError parity)" do
    conn = request(:get, "/api/chat/__test/boom", auth_headers(%{}))

    assert conn.status == 503
    json = body_json(conn)
    assert json["error"]["code"] == "CHAT_WORKER_UNAVAILABLE"
    assert json["error"]["retryable"] == true
    [id] = get_resp_header(conn, "x-request-id")
    assert json["request_id"] == id
  end

  test "GET /health → 200 liveness + DB check, unauthenticated (ops probe outside the API scope)" do
    conn = request(:get, "/health", [{"origin", @origin}])

    assert conn.status == 200
    json = body_json(conn)
    assert json["status"] == "ok"
    assert json["db"] == true

    # Non-API path: outside the /api/chat/* middleware scope (old Worker parity —
    # those middlewares only run on /api/chat/*).
    assert get_resp_header(conn, "x-request-id") == []
    assert get_resp_header(conn, "access-control-allow-origin") == []
  end
end
