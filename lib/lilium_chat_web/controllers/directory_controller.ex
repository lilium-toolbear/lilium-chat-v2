defmodule LiliumChatWeb.DirectoryController do
  @moduledoc """
  Public channel directory (contract §5.6, issue #7).

  * `GET /api/chat/channels/directory?q=&limit=&cursor=` — keyset-paged list
    of `public_listed` + `active` channels. Pure read (A12).

  The controller is thin: parse the query params the way the old Worker did
  (`Limits`), delegate to `LiliumChat.Directory`, JSON-encode the result.
  """

  use LiliumChatWeb, :controller

  alias LiliumChat.Directory
  alias LiliumChatWeb.ErrorHandler
  alias LiliumChatWeb.Limits

  def index(conn, params) do
    user_id = conn.assigns.identity.user_id
    q = params["q"] || ""
    limit = Limits.parse_int_limit(params["limit"])
    cursor = params["cursor"]

    body = Directory.list_public(user_id, q: q, limit: limit, cursor: cursor)

    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(200, Jason.encode!(body))
  rescue
    e -> ErrorHandler.render_exception(conn, e)
  end
end
