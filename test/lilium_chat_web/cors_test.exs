defmodule LiliumChatWeb.CORSTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias LiliumChatWeb.CORS

  @allowed "https://lilium.kuma.homes"

  defp run(method, path, headers) do
    conn =
      conn(method, path)
      |> apply_headers(headers)

    opts = CORS.init([])
    CORS.call(conn, opts)
  end

  defp apply_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end)
  end

  describe "simple requests (hono/cors parity)" do
    test "allowed origin → mirrored allow-origin + expose-headers + vary" do
      conn = run(:get, "/api/chat/channels", [{"origin", @allowed}])

      assert get_resp_header(conn, "access-control-allow-origin") == [@allowed]
      assert get_resp_header(conn, "access-control-expose-headers") == ["X-Request-Id"]
      assert get_resp_header(conn, "vary") == ["Origin"]
    end

    test "each whitelisted origin is accepted" do
      for origin <- [
            "https://lilium.kuma.homes",
            "http://localhost:5174",
            "http://127.0.0.1:5174",
            "http://localhost:3334",
            "http://127.0.0.1:3334"
          ] do
        conn = run(:get, "/api/chat/channels", [{"origin", origin}])
        assert get_resp_header(conn, "access-control-allow-origin") == [origin]
      end
    end

    test "disallowed origin → no allow-origin, but expose-headers + vary still sent (hono parity)" do
      conn = run(:get, "/api/chat/channels", [{"origin", "https://evil.example"}])

      assert get_resp_header(conn, "access-control-allow-origin") == []
      assert get_resp_header(conn, "access-control-expose-headers") == ["X-Request-Id"]
      assert get_resp_header(conn, "vary") == ["Origin"]
    end

    test "no Origin header → no allow-origin, expose-headers + vary still sent (hono parity)" do
      conn = run(:get, "/api/chat/channels", [])

      assert get_resp_header(conn, "access-control-allow-origin") == []
      assert get_resp_header(conn, "access-control-expose-headers") == ["X-Request-Id"]
      assert get_resp_header(conn, "vary") == ["Origin"]
    end
  end

  describe "OPTIONS preflight (hono/cors parity)" do
    test "allowed origin → 204 + full preflight set with exact values" do
      conn =
        run(:options, "/api/chat/channels", [
          {"origin", @allowed},
          {"access-control-request-method", "POST"}
        ])

      assert conn.status == 204
      assert conn.halted
      assert conn.resp_body == ""
      assert get_resp_header(conn, "access-control-allow-origin") == [@allowed]
      assert get_resp_header(conn, "access-control-expose-headers") == ["X-Request-Id"]
      assert get_resp_header(conn, "vary") == ["Origin, Access-Control-Request-Headers"]
      assert get_resp_header(conn, "access-control-max-age") == ["86400"]

      assert get_resp_header(conn, "access-control-allow-methods") == [
               "GET,POST,PATCH,PUT,DELETE"
             ]

      assert get_resp_header(conn, "access-control-allow-headers") == [
               "Authorization,Content-Type,Idempotency-Key"
             ]

      assert get_resp_header(conn, "content-type") == []
      assert get_resp_header(conn, "content-length") == []
    end

    test "disallowed origin → 204 without allow-origin, rest of preflight set present (hono parity)" do
      conn =
        run(:options, "/api/chat/channels", [
          {"origin", "https://evil.example"},
          {"access-control-request-method", "POST"}
        ])

      assert conn.status == 204
      assert get_resp_header(conn, "access-control-allow-origin") == []

      assert get_resp_header(conn, "access-control-allow-methods") == [
               "GET,POST,PATCH,PUT,DELETE"
             ]

      assert get_resp_header(conn, "access-control-allow-headers") == [
               "Authorization,Content-Type,Idempotency-Key"
             ]

      assert get_resp_header(conn, "access-control-max-age") == ["86400"]
    end
  end

  describe "path scoping (production middleware is scoped to /api/chat/*)" do
    test "non-/api/chat paths are untouched" do
      conn = run(:get, "/favicon.ico", [{"origin", @allowed}])
      assert get_resp_header(conn, "access-control-allow-origin") == []
      assert get_resp_header(conn, "access-control-expose-headers") == []
      assert get_resp_header(conn, "vary") == []
    end
  end
end
