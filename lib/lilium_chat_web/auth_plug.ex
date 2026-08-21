defmodule LiliumChatWeb.AuthPlug do
  @moduledoc """
  Browser JWT authentication for `/api/chat/*` API routes (issue #2).

  Mirrors the old Worker's per-handler `getIdentity` (`src/routes/auth.ts`) +
  `verifyBrowserJwt` (`src/auth/jwt.ts`):

    * missing/empty `Authorization: Bearer <token>` → `401 UNAUTHORIZED
      "Not authenticated"`;
    * invalid / expired / wrong-secret token → `401 UNAUTHORIZED
      "Invalid or expired token"`;
    * machine token (`client_id`) → `401 MACHINE_TOKEN_NOT_ALLOWED`;
    * delegated/managed session → `403 SESSION_NOT_ALLOWED`;
    * success → `%LiliumChat.Auth.Identity{user_id, is_admin}` in
      `conn.assigns.identity`.

  The Bearer prefix match is case-sensitive (`"Bearer "`) exactly like the
  reference implementation. Bot routes (bot tokens) and WS upgrades
  (subprotocol bearer) use their own auth paths in later phases.
  """

  import Plug.Conn

  @behaviour Plug

  alias LiliumChat.Auth
  alias LiliumChat.Errors
  alias LiliumChatWeb.ErrorHandler

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    secret = Application.get_env(:lilium_chat, :jwt)[:secret]

    case extract_bearer(get_req_header(conn, "authorization") |> List.first()) do
      "" ->
        conn |> ErrorHandler.render(Errors.new("UNAUTHORIZED", "Not authenticated"))

      token ->
        case Auth.verify(token, secret) do
          {:ok, identity} -> assign(conn, :identity, identity)
          {:error, api_error} -> conn |> ErrorHandler.render(api_error)
        end
    end
  end

  # `src/routes/auth.ts`: auth.startsWith("Bearer ") ? auth.slice(7) : ""
  defp extract_bearer(nil), do: ""

  defp extract_bearer(auth) do
    if String.starts_with?(auth, "Bearer ") do
      binary_part(auth, 7, byte_size(auth) - 7)
    else
      ""
    end
  end
end
