defmodule LiliumChatWeb.MembersController do
  @moduledoc """
  Channel member routes (contract §7).

  Read path (issue #7):

  * `GET /api/chat/channels/{channel_id}/members?query=&limit=&cursor=` —
    active-member list (fuzzy typeahead or keyset-paged);
  * `GET /api/chat/channels/{channel_id}/members/{user_id}` — exact
    single-member read (profile sheet cache-miss source).

  Both are pure reads (A12).

  Write path (issue #12, routed through the per-channel writer, D13):

  * `POST /api/chat/channels/{channel_id}/members` — add a member (§7.2);
  * `PATCH /api/chat/channels/{channel_id}/members/{user_id}` — change role (§7.3);
  * `DELETE /api/chat/channels/{channel_id}/members/{user_id}` — remove / self-leave (§7.4);
  * `POST /api/chat/channels/{channel_id}/owner-transfer` — atomic owner
    transfer (§7.5) — the frontend must NOT compose it from role PATCHes.

  The controller is thin: parse the params the way the old Worker did, read
  the authenticated `user_id`, the `Idempotency-Key` header and the JSON body,
  delegate to `LiliumChat.Channel`, JSON-encode.
  """

  use LiliumChatWeb, :controller

  alias LiliumChat.{Channel, Errors, Members}
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

  # -- POST /channels/{channel_id}/members (§7.2, issue #12) -----------------

  def create(conn, %{"channel_id" => channel_id}) do
    key = idempotency_key!(conn)
    user_id = conn.assigns.identity.user_id

    with_result(Channel.add_member(user_id, key, channel_id, conn.body_params), conn, 200)
  rescue
    e -> ErrorHandler.render_exception(conn, e)
  end

  # -- PATCH /channels/{channel_id}/members/{user_id} (§7.3, issue #12) ------

  def update(conn, %{"channel_id" => channel_id, "user_id" => target_user_id}) do
    key = idempotency_key!(conn)
    user_id = conn.assigns.identity.user_id

    with_result(
      Channel.update_member_role(user_id, key, channel_id, target_user_id, conn.body_params),
      conn,
      200
    )
  rescue
    e -> ErrorHandler.render_exception(conn, e)
  end

  # -- DELETE /channels/{channel_id}/members/{user_id} (§7.4, issue #12) -----

  def delete(conn, %{"channel_id" => channel_id, "user_id" => target_user_id}) do
    key = idempotency_key!(conn)
    user_id = conn.assigns.identity.user_id

    with_result(Channel.remove_member(user_id, key, channel_id, target_user_id), conn, 200)
  rescue
    e -> ErrorHandler.render_exception(conn, e)
  end

  # -- POST /channels/{channel_id}/owner-transfer (§7.5, issue #12) ----------

  def transfer_owner(conn, %{"channel_id" => channel_id}) do
    key = idempotency_key!(conn)
    user_id = conn.assigns.identity.user_id

    with_result(Channel.transfer_owner(user_id, key, channel_id, conn.body_params), conn, 200)
  rescue
    e -> ErrorHandler.render_exception(conn, e)
  end

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
