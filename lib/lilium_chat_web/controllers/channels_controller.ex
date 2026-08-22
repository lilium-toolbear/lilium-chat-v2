defmodule LiliumChatWeb.ChannelsController do
  @moduledoc """
  Channel routes (contract §5, issue #6 read path).

  * `GET /api/chat/channels` — list the viewer's active channels (§5.1);
  * `GET /api/chat/channels/{channel_id}` — channel detail + pins (§5.2).

  Both are pure reads (A12). The controller is thin: read the authenticated
  `user_id`, delegate to `LiliumChat.Channels`, JSON-encode the result.
  """

  use LiliumChatWeb, :controller

  alias LiliumChat.Channels
  alias LiliumChatWeb.ErrorHandler

  def index(conn, _params) do
    items = Channels.list_for_user(conn.assigns.identity.user_id)

    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(200, Jason.encode!(%{items: items, next_cursor: nil}))
  rescue
    e -> ErrorHandler.render_exception(conn, e)
  end

  def show(conn, %{"channel_id" => channel_id}) do
    bundle = Channels.detail(conn.assigns.identity.user_id, channel_id)

    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(200, Jason.encode!(bundle))
  rescue
    e -> ErrorHandler.render_exception(conn, e)
  end
end
