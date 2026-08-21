defmodule LiliumChat.Observability.QueryCounter do
  @moduledoc """
  Per-process PostgreSQL statement counter (spec §4 / A12 / §7.5, issue #3).

  Counts the PG statements a process executes, classified as reads or
  writes, so that "reads are strictly read-only" and "read queries are
  bounded" can be *measured* instead of assumed:

    * HTTP requests — `LiliumChat.Observability` opens a counting window
      for every router dispatch (telemetry `[:phoenix, :router_dispatch,
      :start]`) and emits `[:lilium_chat, :request, :query_count]` with the
      per-request totals when the dispatch ends. The Prometheus metric
      `lilium_chat_request_query_count_reads/writes` is fed from that event.

    * Anything else — wrap a function in `with_counting/1` (or use
      `LiliumChat.Observability.ReadPath`) to get the same counts back:

          {result, %{reads: 3, writes: 0}} =
            QueryCounter.with_counting(fn -> Channels.list(user) end)

  ## Semantics

  Windows are **stacked per process** (process dictionary). A window opened
  while another is open accumulates its own statements; when the inner
  window closes, its totals merge into the outer one, so an outer
  `with_counting/1` that spans a nested dispatch still sees every statement.
  Statements executed with no window open are ignored.

  Classification inspects the SQL text (the telemetry event's `:query`
  metadata): any top-level DML/DDL keyword (`INSERT`, `UPDATE`, `DELETE`,
  `TRUNCATE`, `COPY`, `CREATE`, `DROP`, `ALTER`, `GRANT`, `REVOKE`) marks
  the statement as a write, everything else (SELECT / VALUES / CTE-SELECT)
  as a read. Keyword matching is word-boundary based, so column or table
  names like `updated_at` / `updates` do not trigger a false write; a
  string literal containing a bare keyword (e.g. `WHERE note = 'delete'`)
  would — an accepted edge case for an assertion tool.

  Counting is process-local: statements issued from *other* processes
  during the window (e.g. a spawned `Task` touching Repo) are not counted.
  The read path is designed to be synchronous in-request queries (spec §4),
  which this covers exactly.
  """

  @process_key :lilium_chat_query_stats
  @zero %{reads: 0, writes: 0}

  @doc "Open a counting window in the current process (stackable)."
  def start do
    Process.put(@process_key, [@zero | Process.get(@process_key) || []])
  end

  @doc """
  Close the innermost counting window and return its totals.

  The closed totals are merged into the window below it (if any), so an
  outer window still sees every statement executed inside the inner one.
  Returns `nil` when no window is open.
  """
  def stop do
    case Process.get(@process_key) do
      [top] ->
        Process.delete(@process_key)
        top

      [top | rest] ->
        [below | tail] = rest
        Process.put(@process_key, [merge(top, below) | tail])
        top

      nil ->
        nil
    end
  end

  @doc "True when at least one counting window is open in this process."
  def active?, do: Process.get(@process_key) != nil

  @doc """
  Run `fun` with a counting window open; returns `{result, stats}` where
  `stats` is `%{reads: non_neg_integer(), writes: non_neg_integer()}`.
  The window is always closed, even if `fun` raises.
  """
  def with_counting(fun) when is_function(fun, 0) do
    start()
    stats_ref = make_ref()

    result =
      try do
        fun.()
      after
        Process.put(stats_ref, stop() || @zero)
      end

    {result, get_and_delete(stats_ref)}
  end

  defp get_and_delete(key) do
    value = Process.get(key)
    Process.delete(key)
    value
  end

  @doc """
  Record one statement in the innermost open window (no-op when none is
  open). Called by the `[:lilium_chat, :repo, :query]` telemetry handler.
  """
  def record(:read), do: bump(:reads)
  def record(:write), do: bump(:writes)

  @doc "Classify a SQL statement as `:read` or `:write` (see module docs)."
  def classify(sql) when is_binary(sql),
    do: if(Regex.match?(write_regex(), sql), do: :write, else: :read)

  # A function (not a module attribute) so the type checker sees a %Regex{}.
  defp write_regex do
    ~r/\b(INSERT|UPDATE|DELETE|TRUNCATE|COPY|CREATE|DROP|ALTER|GRANT|REVOKE)\b/i
  end

  defp bump(key) do
    case Process.get(@process_key) do
      [top | rest] ->
        value = Map.get(top, key, 0) + 1
        Process.put(@process_key, [Map.put(top, key, value) | rest])

      nil ->
        :ok
    end
  end

  defp merge(a, b), do: %{reads: a.reads + b.reads, writes: a.writes + b.writes}
end
