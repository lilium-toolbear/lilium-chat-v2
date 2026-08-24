defmodule LiliumChatWeb.DmsController do
  @moduledoc """
  DM routes (contract §5.2c, issue #13).

  * `POST /api/chat/dms` — DM get-or-create (`dm.open`): open or return
    the 1:1 DM between the caller and `recipient_user_id`. 200 with
    `{channel: ChannelSummary, membership: {role, joined_at}}`.

  The controller is thin: read the authenticated `user_id`, the
  `Idempotency-Key` header and the JSON body, delegate to
  `LiliumChat.Dms`, JSON-encode the result.
  """

  use LiliumChatWeb, :controller

  alias LiliumChat.{Dms, Errors}
  alias LiliumChatWeb.ErrorHandler

  # -- POST /dms (§5.2c, issue #13) -----------------------------------------

  def create(conn, _params) do
    key = idempotency_key!(conn)
    user_id = conn.assigns.identity.user_id

    with_result(Dms.open(user_id, key, conn.body_params), conn, 200)
  rescue
    e -> ErrorHandler.render_exception(conn, e)
  end

  # ------------------------------------------------------------------ helpers

  # Hono parity: c.json sends exactly "application/json" (no charset).
  defp with_result({:ok, response}, conn, status) do
    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(status, Jason.encode!(response))
  end

  defp with_result({:error, %Errors.ApiError{} = api_error}, _conn, _status) do
    raise api_error
  end

  # Old Worker `requireIdempotencyKey` (422 INVALID_MESSAGE when absent).
  defp idempotency_key!(conn) do
    case Plug.Conn.get_req_header(conn, "idempotency-key") |> List.first() do
      nil -> raise Errors.new("INVALID_MESSAGE", "Idempotency-Key required")
      "" -> raise Errors.new("INVALID_MESSAGE", "Idempotency-Key required")
      key -> key
    end
  end
end
