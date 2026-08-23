defmodule LiliumChatWeb.StickersController do
  @moduledoc """
  Personal sticker library (contract §8.3, issues #7 / #15).

  * `GET /api/chat/stickers?limit=&cursor=` — the caller's personal sticker
    library list (`created_at DESC`, keyset-paged). Pure read (A12).
  * `POST /api/chat/stickers` — save (get-or-create) a library item from a
    `{channel_id, attachment_id}` source; `Idempotency-Key` required.
  * `DELETE /api/chat/stickers/:sticker_id` — soft-delete one library item;
    `Idempotency-Key` required, idempotent.

  The controller is thin: it reads the authenticated `user_id` (set by
  `AuthPlug`), the `Idempotency-Key` header and the JSON body, delegates to
  `LiliumChat.Stickers`, and JSON-encodes the result. Typed `ApiError`s
  raised by the domain are rendered via `ErrorHandler` with the contract's
  exact status + envelope.
  """

  use LiliumChatWeb, :controller

  alias LiliumChat.Stickers
  alias LiliumChatWeb.ErrorHandler
  alias LiliumChatWeb.Limits

  def index(conn, params) do
    user_id = conn.assigns.identity.user_id
    limit = Limits.parse_num_limit(params["limit"])
    cursor = params["cursor"]

    body = Stickers.list_for_user(user_id, limit: limit, cursor: cursor)

    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(200, Jason.encode!(body))
  rescue
    e -> ErrorHandler.render_exception(conn, e)
  end

  # -- POST /stickers (§8.3 保存, issue #15) ----------------------------------

  def create(conn, params) do
    user_id = conn.assigns.identity.user_id
    operation_id = idempotency_key(conn)

    body = %{"channel_id" => params["channel_id"], "attachment_id" => params["attachment_id"]}
    response = Stickers.save(user_id, operation_id, body)

    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(200, Jason.encode!(response))
  rescue
    e -> ErrorHandler.render_exception(conn, e)
  end

  # -- DELETE /stickers/:sticker_id (§8.3 删除, issue #15) ---------------------

  def delete(conn, %{"sticker_id" => sticker_id}) do
    user_id = conn.assigns.identity.user_id
    operation_id = idempotency_key(conn)

    response = Stickers.delete(user_id, operation_id, sticker_id)

    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(200, Jason.encode!(response))
  rescue
    e -> ErrorHandler.render_exception(conn, e)
  end

  defp idempotency_key(conn) do
    get_req_header(conn, "idempotency-key") |> List.first()
  end
end
