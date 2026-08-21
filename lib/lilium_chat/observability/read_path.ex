defmodule LiliumChat.Observability.ReadPath do
  @moduledoc """
  Assertion surface for "reads are strictly read-only" (spec §4 / A12 / §7.5).

  The spec's read-path acceptance criteria are verified by conformance
  differentials *and* by this observability assertion, for use in tests and
  code review beyond conformance:

    1. reads execute **zero write statements**;
    2. reads hit the **same PG instance** with a **bounded** statement count;
    3. zero per-channel backend fan-out (single Repo pool — assertable as
       "all statements counted in one process-local window").

  Wrap any function that performs PG reads and inspect the counts:

      {result, %{reads: 3, writes: 0}} =
        LiliumChat.Observability.ReadPath.run(fn -> Channels.list(user) end)

  Or fail fast when a write sneaks into a read path:

      ReadPath.assert_read_only!(fn -> Channels.list(user) end, "GET /api/chat/channels")
      # ** (LiliumChat.Observability.ReadPath.WriteError)
      #    read path executed 1 write statement(s) (2 read(s)): GET /api/chat/channels

  HTTP requests are counted automatically by the router-dispatch telemetry
  handlers (see `LiliumChat.Observability`); use this module to assert on
  domain functions directly, or in tests around a full endpoint call:

      ReadPath.assert_read_only!(fn ->
        conn = Plug.Test.conn(:get, "/api/chat/channels") |> auth()
        LiliumChatWeb.Endpoint.call(conn, LiliumChatWeb.Endpoint.init([]))
      end)
  """

  alias LiliumChat.Observability.QueryCounter

  defmodule WriteError do
    @moduledoc """
    Raised by `LiliumChat.Observability.ReadPath.assert_read_only!/2` when a
    supposedly read-only function executed one or more PG write statements.
    """
    defexception [:reads, :writes, :context]

    @impl true
    def message(%{reads: reads, writes: writes} = exc) do
      base = "read path executed #{writes} write statement(s) (#{reads} read(s))"

      case exc.context do
        ctx when is_binary(ctx) and ctx != "" -> base <> ": " <> ctx
        _ -> base
      end
    end
  end

  @doc """
  Run `fun` with query counting; returns `{result, %{reads: n, writes: m}}`.
  """
  def run(fun) when is_function(fun, 0) do
    {result, stats} = QueryCounter.with_counting(fun)
    {result, stats}
  end

  @doc """
  Run `fun` with query counting and raise `WriteError` if any write
  statement was observed. Returns `{:ok, stats}` on success.

  `context` is a free-form label (route name, scenario id) included in the
  exception message for code-review readability.
  """
  def assert_read_only!(fun, context \\ "") when is_function(fun, 0) do
    {_result, stats} = run(fun)

    if stats.writes > 0 do
      raise __MODULE__.WriteError,
        reads: stats.reads,
        writes: stats.writes,
        context: to_string(context)
    end

    {:ok, stats}
  end
end
