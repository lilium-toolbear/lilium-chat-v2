defmodule LiliumChatWeb.InvitesController do
  @moduledoc """
  Invite preview (contract §5.10, issue #7).

  * `GET /api/chat/invites/{invite_code}` — read-only invite preview (no
    join side effects). Pure read (A12).
  """

  use LiliumChatWeb, :controller

  alias LiliumChat.Invites
  alias LiliumChatWeb.ErrorHandler

  def preview(conn, %{"invite_code" => invite_code}) do
    user_id = conn.assigns.identity.user_id
    body = Invites.preview(user_id, invite_code)

    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(200, Jason.encode!(body))
  rescue
    e -> ErrorHandler.render_exception(conn, e)
  end
end
