defmodule LiliumChatWeb.ChannelsController do
  @moduledoc """
  Channel routes (contract §5).

  Read path (issue #6):

  * `GET /api/chat/channels` — list the viewer's active channels (§5.1);
  * `GET /api/chat/channels/{channel_id}` — channel detail + pins (§5.2).

  Write path (issue #11, routed through the per-channel writer, D13):

  * `POST /api/chat/channels` — create (§5.2b, 201 + `membership`);
  * `PATCH /api/chat/channels/{channel_id}` — update metadata (§5.3);
  * `POST /api/chat/channels/{channel_id}/join` — join public channel (§5.7,
    issue #13);
  * `POST /api/chat/channels/{channel_id}/dissolve` — dissolve (§5.4).

  The controller is thin: read the authenticated `user_id`, the
  `Idempotency-Key` header and the JSON body, delegate to
  `LiliumChat.Channel`, JSON-encode the result.
  """

  use LiliumChatWeb, :controller

  alias LiliumChat.{Channels, Channel, Errors}
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

  # -- POST /channels (§5.2b, issue #11) ------------------------------------

  def create(conn, _params) do
    key = idempotency_key!(conn)
    user_id = conn.assigns.identity.user_id

    with_result(Channel.create(user_id, key, conn.body_params), conn, 201)
  rescue
    e -> ErrorHandler.render_exception(conn, e)
  end

  # -- PATCH /channels/{channel_id} (§5.3, issue #11) ------------------------

  def update(conn, %{"channel_id" => channel_id}) do
    key = idempotency_key!(conn)
    user_id = conn.assigns.identity.user_id

    with_result(Channel.update(user_id, key, channel_id, conn.body_params), conn, 200)
  rescue
    e -> ErrorHandler.render_exception(conn, e)
  end

  # -- POST /channels/{channel_id}/join (§5.7, issue #13) --------------------

  def join(conn, %{"channel_id" => channel_id}) do
    key = idempotency_key!(conn)
    user_id = conn.assigns.identity.user_id

    with_result(Channel.join_channel(user_id, key, channel_id), conn, 200)
  rescue
    e -> ErrorHandler.render_exception(conn, e)
  end

  # -- POST /channels/{channel_id}/dissolve (§5.4, issue #11) ----------------

  def dissolve(conn, %{"channel_id" => channel_id}) do
    key = idempotency_key!(conn)
    user_id = conn.assigns.identity.user_id

    with_result(Channel.dissolve(user_id, key, channel_id), conn, 200)
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
