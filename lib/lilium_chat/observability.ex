defmodule LiliumChat.Observability do
  @moduledoc """
  Telemetry wiring for the observability foundation (spec D18 / §10, issue #3).

  `attach/0` installs process-local telemetry handlers (idempotent — safe to
  call on every app start, including repeated test boots):

    * **Per-request PG statement counting** — opens a
      `LiliumChat.Observability.QueryCounter` window when a router dispatch
      starts and closes it when the dispatch stops or raises. The totals are
      emitted as the `[:lilium_chat, :request, :query_count]` telemetry
      event (measurements `:reads` / `:writes`, metadata `:route` +
      `:request_id`) and logged at debug level with the request id so JSON
      log lines correlate with the `X-Request-Id` header.

    * **Repo query recording** — every `[:lilium_chat, :repo, :query]`
      event (including errors) is classified read/write from the SQL text
      and recorded in the current process's open window, if any.

  The route label comes from Phoenix's own dispatch metadata (the compiled
  route pattern including any scope prefix, e.g. `"/api/chat/channels"`,
  `"/*_catchall"`), keeping Prometheus label cardinality bounded to the set
  of defined routes.

  `vm_stats/0` is the periodic measurement MFA for `telemetry_poller`; it
  emits the VM metrics consumed by `LiliumChatWeb.Telemetry.metrics()`.
  """

  require Logger
  alias LiliumChat.Observability.QueryCounter

  @attach_id "lilium_chat.observability"

  @doc """
  Attach the observability telemetry handlers. Idempotent: re-attaching
  with the same handler ids replaces the previous handlers.
  """
  def attach do
    for {suffix, event, handler} <- handlers() do
      :telemetry.attach("#{@attach_id}.#{suffix}", event, handler, nil)
    end

    :ok
  end

  # Remote captures (&Mod.fun/4) — telemetry's recommended handler form
  # (local captures log a performance warning on every attach).
  defp handlers do
    [
      {:dispatch_start, [:phoenix, :router_dispatch, :start],
       &LiliumChat.Observability.on_dispatch_start/4},
      {:dispatch_stop, [:phoenix, :router_dispatch, :stop],
       &LiliumChat.Observability.on_dispatch_end/4},
      {:dispatch_exception, [:phoenix, :router_dispatch, :exception],
       &LiliumChat.Observability.on_dispatch_end/4},
      {:repo_query, [:lilium_chat, :repo, :query], &LiliumChat.Observability.on_repo_query/4},
      {:repo_query_error, [:lilium_chat, :repo, :query, :error],
       &LiliumChat.Observability.on_repo_query/4}
    ]
  end

  @doc """
  Periodic VM measurements (telemetry_poller MFA). Emits the events behind
  the `vm.*` gauges in `LiliumChatWeb.Telemetry.metrics()`.
  """
  def vm_stats do
    :telemetry.execute([:vm, :memory], %{total: :erlang.memory(:total)}, %{})
  end

  # ---------------------------------------------------------------- handlers
  #
  # Public so they can be attached as remote captures (&Mod.fun/4), which
  # telemetry recommends over local captures (performance).

  @doc false
  def on_dispatch_start(_event, _measurements, _metadata, config) do
    QueryCounter.start()
    config
  end

  @doc false
  def on_dispatch_end(_event, _measurements, metadata, config) do
    if stats = QueryCounter.stop() do
      route = to_string(metadata[:route] || "unmatched")
      request_id = Process.get(:lilium_chat_request_id)

      :telemetry.execute(
        [:lilium_chat, :request, :query_count],
        %{reads: stats.reads, writes: stats.writes},
        %{route: route, request_id: request_id}
      )

      Logger.debug("request query count",
        request_id: request_id,
        route: route,
        pg_reads: stats.reads,
        pg_writes: stats.writes
      )
    end

    config
  end

  @doc false
  def on_repo_query(_event, _measurements, metadata, config) do
    case Map.get(metadata, :query) do
      sql when is_binary(sql) -> QueryCounter.record(QueryCounter.classify(sql))
      _ -> :ok
    end

    config
  end
end
