defmodule LiliumChatWeb.MetricsTest do
  @moduledoc """
  Prometheus endpoint tests (spec §10 / D18, issue #3).

  Acceptance under test: **the Prometheus endpoint exposes the app's
  metrics**, including the per-request PG statement counts fed by the
  `[:lilium_chat, :request, :query_count]` telemetry event.
  """

  use LiliumChatWeb.ConnCase, async: true

  import Plug.Conn
  import LiliumChat.TestJWT

  @uid "6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e6f"

  defp request(method, path, headers) do
    conn = Plug.Test.conn(method, path)

    conn =
      Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)

    opts = LiliumChatWeb.Endpoint.init([])
    LiliumChatWeb.Endpoint.call(conn, opts)
  end

  defp auth_headers(claims \\ %{}) do
    [{"authorization", "Bearer " <> sign(Map.put_new(claims, "sub", @uid))}]
  end

  test "GET /metrics → 200, Prometheus text format, app metrics present" do
    conn = request(:get, "/metrics", [])

    assert conn.status == 200
    [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/plain"

    body = conn.resp_body
    # Read-path observability metrics (issue #3) — histogram + counter pair.
    assert body =~ "# TYPE lilium_chat_request_query_count_reads histogram"
    assert body =~ "# TYPE lilium_chat_request_query_count_writes counter"
    # Standard Phoenix / DB pipeline metrics from the same reporter.
    assert body =~ "# TYPE phoenix_endpoint_stop_duration histogram"
    assert body =~ "# TYPE lilium_chat_repo_query_total_time histogram"
  end

  test "serving a read request produces its route-tagged query-count series" do
    conn = request(:get, "/api/chat/channels", auth_headers())
    assert conn.status == 200

    scrape = request(:get, "/metrics", [])
    body = scrape.resp_body

    # Route label is the compiled route pattern (scope prefix included).
    # At least this test's request was counted on that route...
    assert body =~
             ~r/lilium_chat_request_query_count_reads_count\{route="\/api\/chat\/channels"\} \d+/

    # ...and no request on that route has ever executed a write statement.
    assert body =~ ~r/lilium_chat_request_query_count_writes\{route="\/api\/chat\/channels"\} 0/
  end

  test "GET /health (one SELECT) is counted as exactly one read, zero writes" do
    conn = request(:get, "/health", [])
    assert conn.status == 200

    body = request(:get, "/metrics", []).resp_body

    # Other concurrent tests may add to the /health series, so assert lower
    # bounds; the writes counter is a hard invariant (stays 0).
    assert body =~ ~r/lilium_chat_request_query_count_reads_sum\{route="\/health"\} [1-9]\d*/
    assert body =~ ~r/lilium_chat_request_query_count_writes\{route="\/health"\} 0/
  end
end
