defmodule LiliumChatWeb.BotSocket do
  @moduledoc """
  Bot Gateway WebSocket socket (contract §9.7 / §9.1, issue #17).

  Served at `/api/chat/bot/ws` via the Phoenix endpoint. The bot connects
  with the `lilium.chat.bot.v1` subprotocol and authenticates with a bot
  token (`Authorization: Bearer <token>` per the contract).

  Handshake validation (split between transport + this socket):

  * **Subprotocol** — the transport validates `lilium.chat.bot.v1` is
    present in `Sec-WebSocket-Protocol` (via the `subprotocols` option)
    and echoes it back.
  * **Origin** — checked by the transport via `check_origin` (CORS
    whitelist). Non-browser bot runtimes send no `Origin` header, which
    the transport accepts.
  * **Token + scope** — this socket's `connect/3` extracts the bot token
    and verifies it with `LiliumChat.BotTokens.verify/1` (same rules as
    the HTTP Bot AuthPlug, spec §6.1), then requires the
    `chat:runtime:connect` scope.

  Token transport: the contract's primary carrier is the `Authorization`
  header, which Phoenix's `connect_info` does not surface. This socket
  therefore accepts the token through the same subprotocol convention the
  Browser socket uses for JWTs (`bearer.<token>` entry in
  `Sec-WebSocket-Protocol`) and, as a fallback, the `?token=` query
  parameter. Both are equivalent transports for the same bearer token.

  Connect failures render the contract error envelope with the exact
  HTTP status (401 `UNAUTHORIZED` missing/invalid token, 403 `FORBIDDEN`
  missing scope) via the endpoint `error_handler` option
  (`handle_connect_error/2`).
  """

  use Phoenix.Socket

  channel "bot:*", LiliumChatWeb.BotChannel

  alias LiliumChat.{BotTokens, Errors}
  alias LiliumChatWeb.ErrorHandler

  @connect_scope "chat:runtime:connect"

  @impl true
  def connect(params, socket, connect_info) do
    sec_headers = connect_info[:sec_websocket_headers] || []

    with {:ok, token} <- extract_token(params, sec_headers),
         {:ok, identity} <- BotTokens.verify(token) do
      if @connect_scope in identity.scopes do
        {:ok, assign(socket, :bot_identity, identity)}
      else
        {:error, Errors.new("FORBIDDEN", "Missing scope: #{@connect_scope}")}
      end
    else
      {:error, %Errors.ApiError{} = api_error} ->
        {:error, api_error}

      {:error, reason} ->
        {:error, Errors.new("UNAUTHORIZED", to_string(reason))}
    end
  end

  @impl true
  def id(_socket), do: nil

  @doc """
  Transport `error_handler`: render a failed `connect/3` as the contract
  error envelope with the ApiError's HTTP status (401/403).
  """
  def handle_connect_error(conn, %Errors.ApiError{} = api_error) do
    conn |> ErrorHandler.render(api_error)
  end

  def handle_connect_error(conn, reason) do
    conn
    |> ErrorHandler.render(Errors.new("UNAUTHORIZED", to_string(reason)))
  end

  # ------------------------------------------------------------- internals

  defp extract_token(params, sec_headers) do
    case subprotocol_token(sec_headers) || query_token(params) do
      nil ->
        {:error, "Not authenticated"}

      token ->
        {:ok, token}
    end
  end

  # `bearer.<token>` entry in Sec-WebSocket-Protocol (Browser-WS convention).
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
