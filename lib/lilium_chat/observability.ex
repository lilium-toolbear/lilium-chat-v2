defmodule LiliumChat.Observability do
  @moduledoc """
  Telemetry wiring for the observability foundation (spec D18 / §10,
  issues #3 + #21).

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

  `vm_stats/0` and `runtime_gauges/0` are the periodic measurement MFAs for
  `telemetry_poller`; they emit the VM metrics and the spec §10 runtime
  gauges (WS connections, PubSub subscribers, active streams) consumed by
  `LiliumChatWeb.Telemetry.metrics()`.

  Issue #21 additions (spec §10 key metrics):

    * **WS connection gauge** — `track_socket/1` registers the socket
      process with `LiliumChat.Observability.SocketTracker`, which monitors
      it and decrements on disconnect. `runtime_gauges/0` emits it as a
      last_value.
    * **PubSub subscribers** — `runtime_gauges/0` reads the PubSub registry
      (phoenix_pubsub stores subscriptions in a Registry named after the
      pubsub server) and emits total subscribers / distinct topics / a
      histogram of subscribers-per-topic.
    * **Active streams** — `runtime_gauges/0` counts the `Stream.<cid>#<mid>`
      processes via `LiliumChat.Streams.Registry`.
    * **PubSub broadcast latency** — `broadcast/3` times
      `Phoenix.PubSub.broadcast/3` (the local dispatch cost IS the fanout
      latency on a single machine) and emits a duration distribution.
    * **Sentry capture** — `capture_exception/2` reports unhandled
      exceptions with the `request_id` extra (A13), no-oping when no DSN is
      configured.
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

  # ------------------------------------------------------ runtime gauges (#21)

  @doc """
  Periodic runtime gauges (telemetry_poller MFA, spec §10 key metrics):
  WS connections, PubSub subscribers, active streams. The Poller runs this
  every 10s; the Prometheus reporter turns the events into last_value
  gauges / a subscribers-per-topic histogram. Defensive: a failing
  measurement (e.g. a registry briefly down) is logged, never fatal.
  """
  def runtime_gauges do
    ws_connections_gauge()
    pubsub_gauges()
    streams_gauge()
  rescue
    e ->
      # logger_json's Basic formatter drops non-request_id metadata, so the
      # error detail goes in the message itself.
      Logger.warning("runtime gauges failed: " <> Exception.message(e))
      :ok
  end

  # ------------------------------------------------------ WS connections (#21)

  @doc """
  Record a WS connection for the given transport (`:browser` / `:bot` /
  `:bot_stream`). Called by each socket's `connect/3` after a successful
  handshake; the SocketTracker monitors the process and decrements on
  disconnect.
  """
  def track_socket(transport) do
    LiliumChat.Observability.SocketTracker.track(transport)
  end

  # ------------------------------------------------------- timed broadcast (#21)

  @doc """
  Time `Phoenix.PubSub.broadcast/3` and emit a duration distribution
  (`[:lilium_chat, :pubsub, :broadcast, :stop]`). On a single machine the
  local dispatch cost IS the fanout latency (spec §10 PubSub 广播延迟), so
  the fanout call sites go through this wrapper. No topic tag — Prometheus
  label cardinality must stay bounded.

  The measured duration is the synchronous enqueue: `broadcast/3` returns
  once frames are queued for subscriber processes, not after they are
  rendered — the per-frame processing cost is not included.
  """
  def broadcast(pubsub, topic, message) do
    start = System.monotonic_time()
    result = Phoenix.PubSub.broadcast(pubsub, topic, message)

    :telemetry.execute(
      [:lilium_chat, :pubsub, :broadcast, :stop],
      %{duration: System.monotonic_time() - start},
      %{}
    )

    result
  end

  # ------------------------------------------------------- Sentry capture (#21)

  @doc """
  Capture an unhandled exception to Sentry with the `request_id` extra
  (spec §10 / A13: Sentry 事件 + request id 可查). No-ops when `SENTRY_DSN`
  is not configured (dev/test default), so the error path never depends on
  the SDK being enabled.
  """
  def capture_exception(exception, request_id) do
    if sentry_enabled?() do
      Sentry.capture_exception(exception,
        extra: %{request_id: request_id},
        event_source: :plug
      )
    end

    :ok
  end

  # ---------------------------------------------------------- gauge emission

  defp ws_connections_gauge do
    counts =
      try do
        LiliumChat.Observability.SocketTracker.counts()
      catch
        # Tracker briefly down during restart — emit zeros this cycle.
        :exit, _ -> %{}
      end

    for transport <- LiliumChat.Observability.SocketTracker.transports() do
      :telemetry.execute(
        [:lilium_chat, :websocket, :connections],
        %{count: Map.get(counts, transport, 0)},
        %{transport: to_string(transport)}
      )
    end

    :ok
  end

  defp pubsub_gauges do
    # The telemetry poller's first measurement can race app boot (PubSub
    # starts after the Telemetry supervisor), so skip until it is up.
    if Process.whereis(LiliumChat.PubSub) do
      # phoenix_pubsub stores subscriptions in a Registry named after the
      # pubsub server (Phoenix.PubSub.subscribe/3 → Registry.register/3).
      # Entries are {topic, pid}; Registry.select/2 aggregates partitions.
      entries =
        Registry.select(LiliumChat.PubSub, [
          {{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}
        ])

      per_topic = Enum.frequencies(Enum.map(entries, fn {topic, _pid} -> topic end))

      :telemetry.execute([:lilium_chat, :pubsub, :subscribers], %{count: length(entries)}, %{})

      :telemetry.execute(
        [:lilium_chat, :pubsub, :topics],
        %{count: map_size(per_topic)},
        %{}
      )

      for count <- Map.values(per_topic) do
        :telemetry.execute([:lilium_chat, :pubsub, :subscribers_per_topic], %{count: count}, %{})
      end
    end

    :ok
  end

  defp streams_gauge do
    count =
      if Process.whereis(LiliumChat.Streams.Registry) do
        Registry.count(LiliumChat.Streams.Registry)
      else
        0
      end

    :telemetry.execute([:lilium_chat, :streams, :active], %{count: count}, %{})
    :ok
  end

  # ---------------------------------------------------------------- helpers

  defp sentry_enabled? do
    # In test mode Sentry points at its default Bypass instance; elsewhere
    # the DSN comes from config (runtime.exs). nil ⇒ disabled ⇒ the capture
    # is a no-op. Read through Sentry.Config so Sentry.Test's per-test DSN
    # override is honoured.
    not is_nil(Sentry.Config.dsn())
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
