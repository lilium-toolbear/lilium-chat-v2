defmodule LiliumChatWeb.BotStreamSocket do
  @moduledoc """
  Bot Stream WebSocket socket (contract §9.15 / issue #18).

  Served at `/api/chat/bot/channels/:channel_id/streams/:message_id/ws`.
  Subprotocol `lilium.chat.bot.stream.v1`. Auth is the same Chat Bot
  Token as the main gateway (no dedicated stream token) and requires
  both `chat:runtime:connect` and `chat:messages:write`.
  """

  use Phoenix.Socket

  channel "stream:*", LiliumChatWeb.BotStreamChannel

  alias LiliumChat.{BotStream, BotTokens, Errors}
  alias LiliumChatWeb.ErrorHandler

  @impl true
  def connect(params, socket, connect_info) do
    sec_headers = connect_info[:sec_websocket_headers] || []

    with {:ok, token} <- extract_token(params, sec_headers),
         {:ok, identity} <- BotTokens.verify(token),
         :ok <- require_scopes(identity),
         {:ok, channel_id, message_id} <- path_ids(params) do
      # Spec §10 WS 连接数 gauge (issue #21): SocketTracker monitors this
      # process and decrements when it terminates.
      LiliumChat.Observability.track_socket(:bot_stream)

      {:ok,
       socket
       |> assign(:bot_identity, identity)
       |> assign(:channel_id, channel_id)
       |> assign(:message_id, message_id)}
    else
      {:error, %Errors.ApiError{} = api_error} ->
        {:error, api_error}

      {:error, reason} ->
        {:error, Errors.new("UNAUTHORIZED", to_string(reason))}
    end
  end

  @impl true
  def id(_socket), do: nil

  def handle_connect_error(conn, %Errors.ApiError{} = api_error) do
    conn |> ErrorHandler.render(api_error)
  end

  def handle_connect_error(conn, reason) do
    conn
    |> ErrorHandler.render(Errors.new("UNAUTHORIZED", to_string(reason)))
  end

  # ------------------------------------------------------------- internals

  defp require_scopes(identity) do
    missing =
      Enum.reject(BotStream.connect_scopes(), fn scope -> scope in identity.scopes end)

    case missing do
      [] ->
        :ok

      [scope | _] ->
        {:error, Errors.new("BOT_SCOPE_DENIED", "Missing required bot scope: #{scope}")}
    end
  end

  defp path_ids(params) do
    case {params["channel_id"], params["message_id"]} do
      {cid, mid} when is_binary(cid) and cid != "" and is_binary(mid) and mid != "" ->
        {:ok, cid, mid}

      _ ->
        {:error, Errors.new("BOT_STREAM_NOT_FOUND", "stream registry not found")}
    end
  end

  defp extract_token(params, sec_headers) do
    case subprotocol_token(sec_headers) || query_token(params) do
      nil -> {:error, "Not authenticated"}
      token -> {:ok, token}
    end
  end

  defp subprotocol_token(sec_headers) do
    case List.keyfind(sec_headers, "sec-websocket-protocol", 0) do
      {"sec-websocket-protocol", header} ->
        header
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.find_value(fn
          "bearer." <> token when token != "" -> token
          _ -> nil
        end)

      _ ->
        nil
    end
  end

  defp query_token(params) do
    case params do
      %{"token" => token} when is_binary(token) and token != "" -> token
      _ -> nil
    end
  end
end
