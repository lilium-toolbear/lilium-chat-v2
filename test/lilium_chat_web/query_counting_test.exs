defmodule LiliumChatWeb.QueryCountingTest do
  @moduledoc """
  Per-request PG statement counting over the full endpoint pipeline
  (spec §4 / A12 / §7.5, issue #3).

  The acceptance criteria under test:

    * **PG query count of a read request is measurable via telemetry** —
      every router dispatch ends with a `[:lilium_chat, :request,
      :query_count]` event carrying the per-request read/write statement
      totals and the route label;
    * **a read request executes no hidden writes** — asserted on real
      routes, plus cross-checked against PostgreSQL's own statement log
      (`pg_stat_statements`, preloaded in docker-compose for exactly this
      probe) as an independent oracle.

  Note: `GET /api/chat/channels` is a real read path (issue #6). Its query
  count is bounded and independent of the channel count: one `channel_members
  ⋈ channels` join + one profile batch, so the bound here is a small constant.
  """

  use LiliumChatWeb.ConnCase, async: true

  import Plug.Conn
  import LiliumChat.TestJWT

  alias LiliumChat.Observability.QueryCounter
  alias LiliumChat.Repo

  @uid "6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e6f"

  setup do
    # Capture the per-request query-count events (emitted by
    # LiliumChat.Observability at dispatch end, in this same process).
    :telemetry.attach(
      "test.query_counting.capture",
      [:lilium_chat, :request, :query_count],
      fn event, measurements, metadata, config ->
        send(self(), {:query_count_event, event, measurements, metadata})
        config
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("test.query_counting.capture") end)
  end

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

  defp expect_query_count_event(route) do
    receive do
      {:query_count_event, [:lilium_chat, :request, :query_count], measurements, metadata} ->
        assert metadata[:route] == route
        {measurements, metadata}
    after
      500 -> flunk("no [:lilium_chat, :request, :query_count] event for route #{inspect(route)}")
    end
  end

  test "GET /api/chat/channels (read route) → query-count event with zero writes" do
    conn = request(:get, "/api/chat/channels", auth_headers())
    assert conn.status == 200

    # Route label is the compiled route pattern (scope prefix included).
    {measurements, metadata} = expect_query_count_event("/api/chat/channels")
    assert measurements.writes == 0
    # Issue #6 read path: bounded reads (1 channel join + 1 profile batch),
    # independent of the number of channels (A12).
    assert measurements.reads <= 2
    # Request id correlation for JSON logs (issue #2 handoff).
    [id] = get_resp_header(conn, "x-request-id")
    assert metadata[:request_id] == id
  end

  test "GET /health → query-count event with exactly one read, zero writes" do
    conn = request(:get, "/health", [])
    assert conn.status == 200

    {measurements, _metadata} = expect_query_count_event("/health")
    assert measurements.reads == 1
    assert measurements.writes == 0
  end

  test "unmatched /api/chat path → event tagged with the catch-all route" do
    conn = request(:get, "/api/chat/nope", auth_headers())
    assert conn.status == 404

    {measurements, _metadata} = expect_query_count_event("/*_catchall")
    assert measurements.writes == 0
  end

  # Skip only the tagged oracle test when the server lacks the extension
  # (a setup callback returning :skip skips the test — Elixir 1.20 has no
  # tag-conditional setup syntax, so check the tag in the context).
  setup context do
    tagged = Map.get(context, :pg_stat_statements) == true

    if tagged and not extension_available?() do
      :skip
    else
      :ok
    end
  end

  @tag :pg_stat_statements
  test "GET /api/chat/channels executes zero write statements (pg_stat_statements oracle)" do
    # Small cross-test window: other async tests sharing this database could
    # in principle execute a statement between reset and read. Tagged so the
    # test can be excluded (--exclude pg_stat_statements) if that ever flakes.
    Ecto.Adapters.SQL.query!(Repo, "SELECT pg_stat_statements_reset()", [])

    conn = request(:get, "/api/chat/channels", auth_headers())
    assert conn.status == 200

    # PG 18 dropped the `database` column from pg_stat_statements — each
    # database only ever lists its own statements.
    {:ok, %{rows: rows}} =
      Ecto.Adapters.SQL.query(Repo, "SELECT query FROM pg_stat_statements", [])

    writes =
      for [query_text] <- rows,
          not String.contains?(query_text, "pg_stat_statements"),
          QueryCounter.classify(query_text) == :write do
        query_text
      end

    assert writes == []
  end

  defp extension_available? do
    case Ecto.Adapters.SQL.query(
           Repo,
           "SELECT 1 FROM pg_available_extensions WHERE name = 'pg_stat_statements' AND installed_version IS NOT NULL",
           []
         ) do
      {:ok, %{rows: [[_]]}} -> true
      _ -> false
    end
  end
end
