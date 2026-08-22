defmodule LiliumChatWeb.BotCommandsController do
  @moduledoc """
  Bot catalog sync (contract §9.3, issue #16): `PUT /api/chat/bot/commands`
  with bot-token auth + `chat:commands:manage` scope.

  The only non-standard error envelope: `COMMAND_NAME_CONFLICT` (409) carries
  an extra `conflict` object inside `error` (old `putBotCommandsHandler`
  route-level shape).
  """

  use LiliumChatWeb, :controller

  alias LiliumChat.{BotCommands, Errors}
  alias LiliumChatWeb.BotAuthPlug
  alias LiliumChatWeb.ErrorHandler

  @scope "chat:commands:manage"

  def sync(conn, _params) do
    commands = conn.body_params["commands"]

    result =
      with {:ok, conn} <- BotAuthPlug.require_scope(conn, @scope),
           :ok <- require_idempotency_key(conn) do
        if is_list(commands) do
          BotCommands.sync(conn.assigns.bot_id, idempotency_key(conn), commands)
        else
          {:error, Errors.new("INVALID_COMMAND_OPTIONS", "commands array required")}
        end
      end

    respond(conn, result)
  end

  defp idempotency_key(conn) do
    Plug.Conn.get_req_header(conn, "idempotency-key") |> List.first()
  end

  defp require_idempotency_key(conn) do
    case idempotency_key(conn) do
      nil -> {:error, Errors.new("INVALID_COMMAND_OPTIONS", "Idempotency-Key required")}
      "" -> {:error, Errors.new("INVALID_COMMAND_OPTIONS", "Idempotency-Key required")}
      _key -> :ok
    end
  end

  defp respond(conn, result) do
    case result do
      {:ok, response} ->
        conn
        |> put_resp_header("content-type", "application/json")
        |> send_resp(200, Jason.encode!(response))

      {:conflict, %Errors.ApiError{} = api_error, conflict} ->
        # Route-level shape (old `putBotCommandsHandler`): the standard
        # envelope with an extra `conflict` object inside `error`.
        envelope = Errors.envelope(api_error, request_id_of(conn))

        body = %{
          error: Map.put(envelope.error, :conflict, conflict),
          request_id: envelope.request_id
        }

        conn
        |> put_resp_header("content-type", "application/json")
        |> send_resp(api_error.http_status, Jason.encode!(body))

      {:error, %Errors.ApiError{} = api_error} ->
        ErrorHandler.render(conn, api_error)

      other ->
        raise "unexpected bot commands result: #{inspect(other)}"
    end
  end

  defp request_id_of(conn) do
    conn.private[:lilium_chat_request_id] || LiliumChatWeb.RequestId.current()
  end
end
