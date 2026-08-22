defmodule LiliumChatWeb.MessageContextController do
  @moduledoc """
  `GET /api/chat/channels/{channel_id}/messages/{message_id}/context` — timeline
  window around an anchor message (contract §6.6, issue #6). Pure read (A12).
  Returns `{ anchor_message_id, items: [EventFrame] }`.
  """

  use LiliumChatWeb, :controller

  alias LiliumChat.Timeline
  alias LiliumChatWeb.ErrorHandler

  def show(conn, %{"channel_id" => channel_id, "message_id" => message_id} = params) do
    user_id = conn.assigns.identity.user_id

    page =
      Timeline.message_context(user_id, channel_id, message_id, %{
        "before" => params["before"],
        "after" => params["after"]
      })

    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(200, Jason.encode!(page))
  rescue
    e -> ErrorHandler.render_exception(conn, e)
  end
end
