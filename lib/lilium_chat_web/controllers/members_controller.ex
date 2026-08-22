defmodule LiliumChatWeb.MembersController do
  @moduledoc """
  Channel member read routes (contract §7.1 / §7.1b, issue #7).

  * `GET /api/chat/channels/{channel_id}/members?query=&limit=&cursor=` —
    active-member list (fuzzy typeahead or keyset-paged);
  * `GET /api/chat/channels/{channel_id}/members/{user_id}` — exact
    single-member read (profile sheet cache-miss source).

  Both are pure reads (A12). The controller is thin: parse the params the
  way the old Worker did, delegate to `LiliumChat.Members`, JSON-encode.
  """

  use LiliumChatWeb, :controller

  alias LiliumChat.Members
  alias LiliumChatWeb.ErrorHandler
  alias LiliumChatWeb.Limits

  def list(conn, %{"channel_id" => channel_id} = params) do
    user_id = conn.assigns.identity.user_id
    query = params["query"] || ""
    limit = Limits.parse_num_limit(params["limit"])
    cursor = params["cursor"]

    body = Members.list(user_id, channel_id, query: query, limit: limit, cursor: cursor)

    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(200, Jason.encode!(body))
  rescue
    e -> ErrorHandler.render_exception(conn, e)
  end

  def show(conn, %{"channel_id" => channel_id, "user_id" => user_id}) do
    viewer_id = conn.assigns.identity.user_id
    body = Members.detail(viewer_id, channel_id, user_id)

    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(200, Jason.encode!(body))
  rescue
    e -> ErrorHandler.render_exception(conn, e)
  end
end
