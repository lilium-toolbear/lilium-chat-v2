defmodule LiliumChatWeb.StickersController do
  @moduledoc """
  Personal sticker library (contract §8.3, issue #7).

  * `GET /api/chat/stickers?limit=&cursor=` — the caller's personal sticker
    library list (`created_at DESC`, keyset-paged). Pure read (A12).
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
end
