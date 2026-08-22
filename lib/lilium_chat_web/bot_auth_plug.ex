defmodule LiliumChatWeb.BotAuthPlug do
  @moduledoc """
  Bot-token authentication for bot-API routes (contract §9, issue #16).

  Mirrors the old Worker's `getBotIdentity` (`src/auth/bot.ts`):
  `Authorization: Bearer <bot_token>` → SHA-256 → `bot_tokens.token_hash`
  join. Missing/empty bearer → `401 UNAUTHORIZED "Not authenticated"`;
  unknown/revoked/expired token or non-active bot → `401 UNAUTHORIZED
  "Invalid bot token"` (single message for all cases). On success assigns
  `:bot_id` and `:bot_scopes` to `conn.assigns`.
  """

  import Plug.Conn

  @behaviour Plug

  alias LiliumChat.{BotTokens, Errors}
  alias LiliumChatWeb.ErrorHandler

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case extract_bearer(get_req_header(conn, "authorization") |> List.first()) do
      "" ->
        conn |> ErrorHandler.render(Errors.new("UNAUTHORIZED", "Not authenticated"))

      token ->
        case BotTokens.verify(token) do
          {:ok, %{bot_id: bot_id, scopes: scopes}} ->
            conn
            |> assign(:bot_id, bot_id)
            |> assign(:bot_scopes, scopes)

          {:error, api_error} ->
            conn |> ErrorHandler.render(api_error)
        end
    end
  end

  # Case-sensitive "Bearer " prefix, exactly like the reference implementation.
  defp extract_bearer(nil), do: ""

  defp extract_bearer(auth) do
    if String.starts_with?(auth, "Bearer ") do
      binary_part(auth, 7, byte_size(auth) - 7)
    else
      ""
    end
  end

  @doc "Scope gate: `{:ok, conn}` or `{:error, %ApiError{}}` (FORBIDDEN Missing scope)."
  def require_scope(conn, scope) do
    if scope in conn.assigns.bot_scopes do
      {:ok, conn}
    else
      {:error, Errors.new("FORBIDDEN", "Missing scope: #{scope}")}
    end
  end
end
