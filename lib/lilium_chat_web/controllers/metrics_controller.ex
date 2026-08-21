defmodule LiliumChatWeb.MetricsController do
  @moduledoc """
  Prometheus scrape endpoint (spec §10 / D18, issue #3).

  Ops probe on the main app port — like `/health`, it is intentionally NOT
  part of the Browser/Bot API contract (`/api/chat/*`), so no JWT auth and
  no X-Request-Id/CORS middleware apply. In production it sits behind the
  front proxy (Caddy/nginx) for Prometheus scraping.

  The scrape is served from `TelemetryMetricsPrometheus.Core` (started in
  `LiliumChatWeb.Telemetry`) — one port, no second HTTP listener.
  """
  use LiliumChatWeb, :controller

  def index(conn, _params) do
    conn
    |> put_resp_content_type("text/plain; charset=utf-8")
    |> send_resp(
      200,
      TelemetryMetricsPrometheus.Core.scrape(LiliumChatWeb.Telemetry.reporter_name())
    )
  end
end
