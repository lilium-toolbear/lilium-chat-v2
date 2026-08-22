defmodule LiliumChatWeb.UploadsController do
  @moduledoc """
  Attachment upload routes (contract §8.1–§8.2, spec §6.2, issue #14).

  * `POST /api/chat/uploads/images/presign` — create a pending attachment +
    return a SigV4 presigned PUT (C7: signed with the bucket, returned without
    it; `Content-Type` + `Cache-Control` signed; 5-min TTL).
  * `POST /api/chat/uploads/images/:attachment_id/finalize` — verify the
    object via an S3 `HEAD` and return the finalized-attachment projection.

  The controller is thin: it reads the authenticated `user_id` (set by
  `AuthPlug`), extracts the `Idempotency-Key` header and the JSON body,
  delegates to `LiliumChat.Uploads`, and JSON-encodes the result. Typed
  `ApiError`s raised by the domain are rendered via `ErrorHandler` with the
  contract's exact status + envelope.
  """

  use LiliumChatWeb, :controller

  alias LiliumChat.Uploads
  alias LiliumChatWeb.ErrorHandler

  def presign(conn, params) do
    user_id = conn.assigns.identity.user_id
    idempotency_key = idempotency_key(conn)

    response = Uploads.presign(user_id, idempotency_key, params)

    render_json(conn, response)
  rescue
    e -> ErrorHandler.render_exception(conn, e)
  end

  def finalize(conn, params) do
    user_id = conn.assigns.identity.user_id
    idempotency_key = idempotency_key(conn)
    etag = params["etag"]

    response = Uploads.finalize(user_id, params["attachment_id"], etag, idempotency_key)

    render_json(conn, response)
  rescue
    e -> ErrorHandler.render_exception(conn, e)
  end

  # Hono parity: c.json sends exactly "application/json" (no charset).
  defp render_json(conn, body) do
    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(200, Jason.encode!(body))
  end

  defp idempotency_key(conn) do
    get_req_header(conn, "idempotency-key") |> List.first()
  end
end
