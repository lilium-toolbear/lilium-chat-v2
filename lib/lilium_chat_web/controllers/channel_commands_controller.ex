defmodule LiliumChatWeb.ChannelCommandsController do
  @moduledoc """
  Channel command manifest + binding endpoints (contract §9.4/§9.9, issue #16).

  - `GET /channels/:channel_id/commands` — role-filtered manifest
    (old `getChannelCommands`),
  - `PATCH /channels/:channel_id/commands/:bot_command_id` — allow/block a
    command in the channel (old `commandBindingUpdate`),
  - `GET /commands/directory` — search active commands across active bots
    (old `searchCommands`).

  All browser JWT; the caller's role in the channel drives role filtering and
  binding-update authorization.
  """

  use LiliumChatWeb, :controller

  alias LiliumChat.{BotCommands, ChannelCommands, Errors}
  alias LiliumChatWeb.ErrorHandler

  # -- GET /channels/:channel_id/commands ---------------------------------------

  def list(conn, %{"channel_id" => channel_id}) do
    result = ChannelCommands.list(conn.assigns.identity.user_id, channel_id)
    respond(conn, result)
  end

  # -- PATCH /channels/:channel_id/commands/:bot_command_id ----------------------

  def update_binding(conn, %{"channel_id" => channel_id, "bot_command_id" => bot_command_id}) do
    identity = conn.assigns.identity
    body = conn.body_params

    result =
      with :ok <- require_idempotency_key(conn),
           :ok <- status_present?(body) do
        ChannelCommands.update_binding(identity.user_id, channel_id, bot_command_id, %{
          idempotency_key: idempotency_key(conn),
          status: body["status"],
          permission_override: body["permission_override"],
          stateful_max_ttl_seconds: body["stateful_max_ttl_seconds"]
        })
      end

    respond(conn, result)
  end

  # -- GET /commands/directory ---------------------------------------------------

  def directory(conn, query) do
    result = BotCommands.directory(query["query"], query["limit"], query["cursor"])
    respond(conn, result)
  end

  # -- helpers -------------------------------------------------------------------

  defp status_present?(body) do
    if body["status"] in ["allowed", "blocked"] do
      :ok
    else
      {:error, Errors.new("INVALID_MESSAGE", "status required")}
    end
  end

  defp require_idempotency_key(conn) do
    case idempotency_key(conn) do
      nil -> {:error, Errors.new("INVALID_MESSAGE", "Idempotency-Key required")}
      "" -> {:error, Errors.new("INVALID_MESSAGE", "Idempotency-Key required")}
      _key -> :ok
    end
  end

  defp idempotency_key(conn) do
    Plug.Conn.get_req_header(conn, "idempotency-key") |> List.first()
  end

  defp respond(conn, result) do
    case result do
      {:ok, body} ->
        conn
        |> put_resp_header("content-type", "application/json")
        |> send_resp(200, Jason.encode!(body))

      {:error, %Errors.ApiError{} = api_error} ->
        ErrorHandler.render(conn, api_error)

      other ->
        raise "unexpected channel commands result: #{inspect(other)}"
    end
  end
end
