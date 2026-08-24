defmodule LiliumChatWeb.DebugControllerTest do
  @moduledoc """
  `/internal/debug/*` tests (spec §10, issue #21): DEBUG_TOKEN gating and
  the read-only SQL surface (old-Worker parity: `classes` / `sql` /
  `sql-all`).
  """

  use LiliumChatWeb.ConnCase, async: true

  import Plug.Conn

  @token "test-debug-token"

  defp request(method, path, headers, body \\ nil) do
    conn =
      if body do
        Plug.Test.conn(method, path, body)
        |> put_req_header("content-type", "application/json")
      else
        Plug.Test.conn(method, path)
      end

    conn =
      Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)

    opts = LiliumChatWeb.Endpoint.init([])
    LiliumChatWeb.Endpoint.call(conn, opts)
  end

  defp auth(token \\ @token), do: [{"authorization", "Bearer " <> token}]

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  describe "DEBUG_TOKEN gate" do
    test "no token → 403 FORBIDDEN envelope" do
      conn = request(:get, "/internal/debug/classes", [])

      assert conn.status == 403
      assert %{"error" => %{"code" => "FORBIDDEN", "retryable" => false}} = decode(conn)
      assert get_resp_header(conn, "content-type") == ["application/json"]
    end

    test "wrong token → 403 FORBIDDEN" do
      conn = request(:get, "/internal/debug/classes", auth("wrong-token"))
      assert conn.status == 403
      assert %{"error" => %{"code" => "FORBIDDEN"}} = decode(conn)
    end

    test "debug surface disabled when no token is configured" do
      previous = Application.get_env(:lilium_chat, :debug_token)
      Application.put_env(:lilium_chat, :debug_token, nil)
      on_exit(fn -> Application.put_env(:lilium_chat, :debug_token, previous) end)

      conn = request(:get, "/internal/debug/classes", auth())
      assert conn.status == 403
      assert %{"error" => %{"code" => "FORBIDDEN"}} = decode(conn)
    end
  end

  describe "GET /internal/debug/classes" do
    test "lists the supported PG schemas" do
      conn = request(:get, "/internal/debug/classes", auth())
      assert conn.status == 200

      body = decode(conn)
      classes = body["classes"]

      assert Enum.map(classes, & &1["class"]) == ["chat_v2", "public"]
      assert Enum.all?(classes, &(&1["enumeration"] == "single PG instance"))
    end
  end

  describe "POST /internal/debug/sql" do
    test "runs a SELECT against the chat_v2 schema" do
      body = Jason.encode!(%{"class" => "chat_v2", "query" => "SELECT 1 AS one"})
      conn = request(:post, "/internal/debug/sql", auth(), body)

      assert conn.status == 200
      result = decode(conn)

      assert result["class"] == "chat_v2"
      assert result["name"] == "shared"
      assert result["columns"] == ["one"]
      assert result["rows"] == [%{"one" => 1}]
      assert result["rows_read"] == 1
      assert result["truncated"] == false
      assert is_integer(result["now_ms"])
    end

    test "class selects the search_path (public.users)" do
      body = Jason.encode!(%{"class" => "public", "query" => "SELECT count(*) AS n FROM users"})
      conn = request(:post, "/internal/debug/sql", auth(), body)

      assert conn.status == 200
      assert %{"columns" => ["n"], "rows" => [%{"n" => n}]} = decode(conn)
      assert is_integer(n)
    end

    test "caps rows and flags truncation" do
      body =
        Jason.encode!(%{
          "class" => "chat_v2",
          "query" => "SELECT * FROM (VALUES (1), (2), (3)) AS t(n)",
          "limit" => 2
        })

      conn = request(:post, "/internal/debug/sql", auth(), body)

      assert conn.status == 200
      result = decode(conn)
      assert result["rows_read"] == 2
      assert result["truncated"] == true
      assert length(result["rows"]) == 2
    end

    test "clamps an oversized limit to 5000" do
      body =
        Jason.encode!(%{"class" => "chat_v2", "query" => "SELECT 1 AS one", "limit" => 99_999})

      conn = request(:post, "/internal/debug/sql", auth(), body)
      assert conn.status == 200
      assert %{"truncated" => false} = decode(conn)
    end

    test "non-SELECT query → 403 FORBIDDEN" do
      for query <- [
            "DELETE FROM chat_v2.idempotency",
            "UPDATE chat_v2.idempotency SET status = 'x'"
          ] do
        body = Jason.encode!(%{"class" => "chat_v2", "query" => query})
        conn = request(:post, "/internal/debug/sql", auth(), body)

        assert conn.status == 403
        assert %{"error" => %{"code" => "FORBIDDEN"}} = decode(conn)
      end
    end

    test "statement chaining → 403 FORBIDDEN" do
      body = Jason.encode!(%{"class" => "chat_v2", "query" => "SELECT 1; SELECT 2"})
      conn = request(:post, "/internal/debug/sql", auth(), body)
      assert conn.status == 403
    end

    test "data-modifying WITH CTE → 403 FORBIDDEN" do
      query = "WITH x AS (INSERT INTO chat_v2.idempotency (id) VALUES (1)) SELECT * FROM x"
      body = Jason.encode!(%{"class" => "chat_v2", "query" => query})
      conn = request(:post, "/internal/debug/sql", auth(), body)
      assert conn.status == 403
    end

    test "SELECT INTO → 403 FORBIDDEN" do
      body = Jason.encode!(%{"class" => "chat_v2", "query" => "SELECT 1 INTO new_table"})
      conn = request(:post, "/internal/debug/sql", auth(), body)
      assert conn.status == 403
    end

    test "unsupported class → 422 INVALID_MESSAGE" do
      body = Jason.encode!(%{"class" => "ChatChannel", "query" => "SELECT 1"})
      conn = request(:post, "/internal/debug/sql", auth(), body)
      assert conn.status == 422
      assert %{"error" => %{"code" => "INVALID_MESSAGE"}} = decode(conn)
    end

    test "missing query → 422 INVALID_MESSAGE" do
      body = Jason.encode!(%{"class" => "chat_v2"})
      conn = request(:post, "/internal/debug/sql", auth(), body)
      assert conn.status == 422
    end

    test "SQL error surfaces with the PG message" do
      body = Jason.encode!(%{"class" => "chat_v2", "query" => "SELECT nope FROM missing_table"})
      conn = request(:post, "/internal/debug/sql", auth(), body)

      assert conn.status == 422
      body = decode(conn)
      assert body["error"]["code"] == "INVALID_MESSAGE"
      assert body["error"]["message"] =~ "debugSql failed"
    end

    test "timestamps render as ISO-8601 (Jason-safe)" do
      query = "SELECT now() AS ts"
      body = Jason.encode!(%{"class" => "chat_v2", "query" => query})
      conn = request(:post, "/internal/debug/sql", auth(), body)

      assert conn.status == 200
      assert %{"rows" => [%{"ts" => ts}]} = decode(conn)
      assert is_binary(ts)
    end
  end

  describe "POST /internal/debug/sql-all" do
    test "old-Worker fan-out shape over the single PG instance" do
      body = Jason.encode!(%{"class" => "chat_v2", "query" => "SELECT 1 AS one"})
      conn = request(:post, "/internal/debug/sql-all", auth(), body)

      assert conn.status == 200
      result = decode(conn)

      assert result["class"] == "chat_v2"
      assert result["instance_count"] == 1
      assert [%{"name" => "shared", "ok" => true, "result" => inner}] = result["results"]
      assert inner["columns"] == ["one"]
      assert inner["rows"] == [%{"one" => 1}]
    end

    test "honours the DEBUG_TOKEN gate like sql" do
      body = Jason.encode!(%{"class" => "chat_v2", "query" => "SELECT 1"})
      conn = request(:post, "/internal/debug/sql-all", [], body)
      assert conn.status == 403
    end
  end
end
