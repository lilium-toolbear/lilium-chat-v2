defmodule LiliumChatWeb.BootstrapController do
  @moduledoc """
  `GET /api/chat/bootstrap` — first-screen aggregate (contract §4.1, issue #5).

  Wire shape is defined by contract §4.1. The controller is thin: it reads
  the authenticated `user_id` from the conn (set by `AuthPlug`), extracts the
  optional `?channel_id=` query param, delegates to `LiliumChat.Bootstrap.fetch/2`,
  and JSON-encodes the result.

  Read-path invariants (spec §4 / A12):
  * strictly read-only (asserted by telemetry in tests);
  * same PG instance (`chat_v2.*` + `public.users`);
  * bounded query count (≤ 6 round-trips);
  * zero per-channel backend fan-out.
  """

  use LiliumChatWeb, :controller

  alias LiliumChat.Bootstrap
  alias LiliumChatWeb.ErrorHandler

  def show(conn, params) do
    user_id = conn.assigns.identity.user_id
    requested_channel_id = params["channel_id"]

    response = Bootstrap.fetch(user_id, requested_channel_id)

    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(200, Jason.encode!(response))
  rescue
    e -> ErrorHandler.render_exception(conn, e)
  end
end
