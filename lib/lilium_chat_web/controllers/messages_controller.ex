defmodule LiliumChatWeb.MessagesController do
  @moduledoc """
  `GET /api/chat/channels/{channel_id}/messages` — timeline history (contract
  §6.1, issue #6). Pure read (A12). Returns `{ items: [EventFrame], next_cursor }`
  (Browser-visible timeline events, §10.4 / §6.1b replay rules).
  """

  use LiliumChatWeb, :controller

  alias LiliumChat.Timeline
  alias LiliumChatWeb.ErrorHandler

  def index(conn, %{"channel_id" => channel_id} = params) do
    user_id = conn.assigns.identity.user_id

    page =
      Timeline.messages_page(user_id, channel_id, %{
        "before" => params["before"],
        "after" => params["after"],
        "limit" => params["limit"]
      })

    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(200, Jason.encode!(page))
  rescue
    e -> ErrorHandler.render_exception(conn, e)
  end
end
