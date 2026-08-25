defmodule LiliumChatWeb.BotUploadsController do
  @moduledoc """
  Bot attachment upload routes (contract §9.17.1):

  * `POST /api/chat/bot/channels/:channel_id/uploads/images/presign`
  * `POST /api/chat/bot/channels/:channel_id/uploads/images/:attachment_id/finalize`

  Both authenticate with a Chat Bot Token — the `:bot_api` pipeline already
  ran `BotAuthPlug` — and require the `chat:messages:write` scope (old Worker
  `getBotIdentity` gate, same as the Bot Gateway write path). The controller
  is thin: scope gate + delegate to `LiliumChat.BotUploads`; typed
  `ApiError`s are rendered via `ErrorHandler` with the contract's exact
  status + envelope.
  """

  use LiliumChatWeb, :controller

  alias LiliumChat.{BotUploads, Errors}
  alias LiliumChatWeb.BotAuthPlug
  alias LiliumChatWeb.ErrorHandler

  @scope "chat:messages:write"

  def presign(conn, params) do
    channel_id = params["channel_id"]

    with_ok_scope(conn, fn bot_id ->
      idempotency_key = get_req_header(conn, "idempotency-key") |> List.first()
      BotUploads.presign(bot_id, channel_id, idempotency_key, params)
    end)
  rescue
    e -> ErrorHandler.render_exception(conn, e)
  end

  def finalize(conn, params) do
    channel_id = params["channel_id"]
    attachment_id = params["attachment_id"]
    etag = params["etag"]

    with_ok_scope(conn, fn bot_id ->
      BotUploads.finalize(bot_id, channel_id, attachment_id, etag)
    end)
  rescue
    e -> ErrorHandler.render_exception(conn, e)
  end

  # Scope gate (old `getBotIdentity` scope check) then the domain call; the
  # `{:error, %ApiError{}}` branch renders the FORBIDDEN envelope.
  defp with_ok_scope(conn, fun) do
    case BotAuthPlug.require_scope(conn, @scope) do
      {:ok, conn} ->
        response = fun.(conn.assigns.bot_id)

        conn
        |> put_resp_header("content-type", "application/json")
        |> send_resp(200, Jason.encode!(response))

      {:error, %Errors.ApiError{} = api_error} ->
        ErrorHandler.render(conn, api_error)
    end
  end
end
