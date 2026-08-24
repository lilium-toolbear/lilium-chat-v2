defmodule LiliumChatWeb.InvitesController do
  @moduledoc """
  Invite routes (contract §5.8 / §5.9 / §5.10, issues #7 + #13).

  * `GET /api/chat/invites/{invite_code}` — read-only invite preview
    (§5.10, issue #7; no join side effects, pure read A12);
  * `POST /api/chat/channels/{channel_id}/invites` — create (or refresh)
    the caller's personal invite (§5.8, issue #13);
  * `POST /api/chat/invites/{invite_code}/accept` — accept an invite
    (§5.9, issue #13; routed to the channel writer via the invite's
    `channel_id` — `ROUTE_INDEX_PENDING` while the import backfill has not
    filled it).

  The controller is thin: read the authenticated `user_id`, the
  `Idempotency-Key` header and the JSON body, delegate to
  `LiliumChat.Channel` / `LiliumChat.InviteCommands`, JSON-encode the
  result.
  """

  use LiliumChatWeb, :controller

  alias LiliumChat.{Channel, Errors, InviteCommands, Invites}
  alias LiliumChatWeb.ErrorHandler

  # -- GET /invites/{invite_code} (§5.10, issue #7) -------------------------

  def preview(conn, %{"invite_code" => invite_code}) do
    user_id = conn.assigns.identity.user_id
    body = Invites.preview(user_id, invite_code)

    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(200, Jason.encode!(body))
  rescue
    e -> ErrorHandler.render_exception(conn, e)
  end

  # -- POST /channels/{channel_id}/invites (§5.8, issue #13) -----------------

  def create(conn, %{"channel_id" => channel_id}) do
    key = idempotency_key!(conn)
    user_id = conn.assigns.identity.user_id

    with_result(Channel.create_invite(user_id, key, channel_id, conn.body_params), conn, 200)
  rescue
    e -> ErrorHandler.render_exception(conn, e)
  end

  # -- POST /invites/{invite_code}/accept (§5.9, issue #13) ------------------

  def accept(conn, %{"invite_code" => invite_code}) do
    key = idempotency_key!(conn)
    user_id = conn.assigns.identity.user_id

    # Old Worker: `if (!inviteCode) throw INVALID_MESSAGE`.
    if invite_code == "" do
      raise Errors.new("INVALID_MESSAGE", "invite_code is required")
    end

    # The URL has no channel id: resolve the routing channel pre-txn.
    # (The in-txn re-check is authoritative — this is the same split as
    # the old Worker's InviteDirectory preview + ChatChannel acceptInvite.)
    case InviteCommands.route_for(invite_code) do
      :invite_not_found ->
        raise Errors.new("INVITE_NOT_FOUND", "invite not found")

      :route_index_pending ->
        raise Errors.new("ROUTE_INDEX_PENDING", "invite route index pending")

      {:ok, channel_id} ->
        with_result(Channel.accept_invite(user_id, key, channel_id, invite_code), conn, 200)
    end
  rescue
    e -> ErrorHandler.render_exception(conn, e)
  end

  # ------------------------------------------------------------------ helpers

  # Hono parity: c.json sends exactly "application/json" (no charset).
  defp with_result({:ok, response}, conn, status) do
    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(status, Jason.encode!(invite_url!(response)))
  end

  defp with_result({:error, %Errors.ApiError{} = api_error}, _conn, _status) do
    raise api_error
  end

  # §5.8: the create response carries `invite_url` = the SPA origin
  # (`API_BASE_URL`, contract v2.15 correction) + `/chat/invites/{code}`.
  # Only the create action returns `invite_code` — accept replies pass
  # through untouched.
  defp invite_url!(%{"invite_code" => code} = response) do
    base = Application.get_env(:lilium_chat, :api_base_url, "") |> String.trim_trailing("/")

    Map.put(response, "invite_url", base <> "/chat/invites/" <> code)
  end

  defp invite_url!(response), do: response

  # Old Worker `requireIdempotencyKey` (422 INVALID_MESSAGE when absent).
  defp idempotency_key!(conn) do
    case Plug.Conn.get_req_header(conn, "idempotency-key") |> List.first() do
      nil -> raise Errors.new("INVALID_MESSAGE", "Idempotency-Key required")
      "" -> raise Errors.new("INVALID_MESSAGE", "Idempotency-Key required")
      key -> key
    end
  end
end
