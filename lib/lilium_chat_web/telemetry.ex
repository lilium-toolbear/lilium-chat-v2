defmodule LiliumChatWeb.Telemetry do
  @moduledoc """
  Telemetry pipeline for the observability foundation (spec D18 / §10, issue #3).

  Supervises:

    * `telemetry_poller` — periodic VM measurements (see
      `LiliumChat.Observability.vm_stats/0`).
    * `TelemetryMetricsPrometheus.Core` — the Prometheus reporter for the
      metrics defined in `metrics/0`. It attaches telemetry handlers and
      aggregates events; `LiliumChatWeb.MetricsController` serves the scrape
      (`GET /metrics`) via `TelemetryMetricsPrometheus.Core.scrape/1`, so no
      second HTTP listener is needed.

  Note: the Prometheus reporter supports counter/distribution/sum/last_value
  but **not** summary — durations are therefore distributions (histograms)
  with explicit buckets, per its requirements.
  """
  use Supervisor
  import Telemetry.Metrics

  @reporter_name :lilium_chat_metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://hexdocs.pm/telemetry_metrics
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000},
      # Prometheus reporter (spec §10): start_async: false so the telemetry
      # handlers are attached before Repo/Endpoint can emit events.
      {TelemetryMetricsPrometheus.Core,
       metrics: metrics(), name: @reporter_name, start_async: false}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix endpoint / router (spec §10 key metrics: PG 事务 p99 etc. are
      # covered by the repo distributions below)
      last_value("phoenix.endpoint.start.system_time", unit: {:native, :millisecond}),
      distribution(
        "phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond},
        reporter_options: [buckets: duration_buckets()]
      ),
      # Absolute system time (not a duration) → gauge, like the endpoint one.
      last_value("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      distribution(
        "phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond},
        reporter_options: [buckets: duration_buckets()]
      ),
      distribution(
        "phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond},
        reporter_options: [buckets: duration_buckets()]
      ),

      # Phoenix Channels (3 WS protocols land here — spec §2.1)
      distribution(
        "phoenix.socket_connected.duration",
        unit: {:native, :millisecond},
        reporter_options: [buckets: duration_buckets()]
      ),
      sum("phoenix.socket_drain.count"),
      distribution(
        "phoenix.channel_joined.duration",
        unit: {:native, :millisecond},
        reporter_options: [buckets: duration_buckets()]
      ),
      distribution(
        "phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond},
        reporter_options: [buckets: duration_buckets()]
      ),

      # Database (spec §10: PG 事务 p99)
      distribution(
        "lilium_chat.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements",
        reporter_options: [buckets: query_buckets()]
      ),
      distribution(
        "lilium_chat.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database",
        reporter_options: [buckets: query_buckets()]
      ),
      distribution(
        "lilium_chat.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query",
        reporter_options: [buckets: query_buckets()]
      ),
      distribution(
        "lilium_chat.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection",
        reporter_options: [buckets: query_buckets()]
      ),
      distribution(
        "lilium_chat.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query",
        reporter_options: [buckets: query_buckets()]
      ),

      # VM (periodic — LiliumChat.Observability.vm_stats/0)
      last_value("vm.memory.total", unit: {:byte, :kilobyte}),

      # Read-path observability (spec §4 / A12 / issue #3): per-request PG
      # statement counts from the [:lilium_chat, :request, :query_count]
      # event. Reads should stay bounded; writes should stay 0 on read routes.
      distribution(
        "lilium_chat.request.query_count.reads",
        tags: [:route],
        description: "PG read statements executed per HTTP request (spec §4 bound)",
        reporter_options: [buckets: [1, 2, 3, 5, 10, 20, 50]]
      ),
      sum(
        "lilium_chat.request.query_count.writes",
        tags: [:route],
        description:
          "Total PG write statements executed by HTTP requests (should stay 0 on read routes)"
      )
    ]
  end

  @doc "The Prometheus reporter instance name (used by the /metrics scrape)."
  def reporter_name, do: @reporter_name

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      {LiliumChat.Observability, :vm_stats, []}
    ]
  end

  defp duration_buckets, do: [5, 20, 50, 100, 250, 500, 1_000, 2_500]
  defp query_buckets, do: [1, 5, 10, 50, 100, 250, 500, 1_000]
end
