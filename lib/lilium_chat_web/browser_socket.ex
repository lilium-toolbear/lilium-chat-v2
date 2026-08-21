defmodule LiliumChatWeb.BrowserSocket do
  @moduledoc """
  Browser WebSocket socket (contract §2.1 / §10.1, issue #8).

  Served at `/api/chat/ws` via the Phoenix endpoint. The client connects with:

      new WebSocket("wss://chat.kuma.homes/api/chat/ws", [
        "lilium.chat.v2",
        "bearer.<toolbear_browser_jwt>"
      ])

  Handshake validation (split between transport + this socket):

  * **Origin** — checked by the Phoenix transport via the `check_origin`
    websocket option (CORS whitelist from config `:lilium_chat, :cors, :origins`).
  * **Subprotocol** — the transport validates that `lilium.chat.v2` is present
    in the `Sec-WebSocket-Protocol` header (via the `subprotocols` option) and
    echoes it back in the response.
  * **JWT** — this socket's `connect/3` extracts the `bearer.<jwt>` entry
    from the `Sec-WebSocket-Protocol` header and verifies it with the same
    rules as the HTTP `AuthPlug` (spec §6.1).

  Connect only creates the session (no replay, no `?cursors=` parsing,
  no implicit subscribe — contract §10.1). Live fanout is started
  explicitly by the client's `session.live_start` command (§5.11).
  """

  use Phoenix.Socket

  channel "browser:*", LiliumChatWeb.BrowserChannel

  alias LiliumChat.Auth

  @impl true
  def connect(_params, socket, connect_info) do
    sec_headers = connect_info[:sec_websocket_headers] || []

    with {:ok, token} <- extract_bearer_token(sec_headers),
         {:ok, identity} <- Auth.verify(token, jwt_secret()) do
      {:ok, assign(socket, :identity, identity)}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def id(_socket), do: nil

  # ------------------------------------------------------------- internals

  defp extract_bearer_token(headers) do
    case find_header(headers, "sec-websocket-protocol") do
      nil ->
        {:error, "missing Sec-WebSocket-Protocol"}

      header ->
        protocols = header |> String.split(",") |> Enum.map(&String.trim/1)

        case Enum.find(protocols, &String.starts_with?(&1, "bearer.")) do
          nil ->
            {:error, "missing bearer subprotocol"}

          "bearer." <> token ->
            if token == "" do
              {:error, "empty bearer token"}
            else
              {:ok, token}
            end
        end
    end
  end

  defp find_header(headers, name) do
    case List.keyfind(headers, name, 0) do
      {^name, value} -> value
      _ -> nil
    end
  end

  defp jwt_secret do
    Application.get_env(:lilium_chat, :jwt)[:secret]
  end
end
