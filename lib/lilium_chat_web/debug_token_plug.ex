defmodule LiliumChatWeb.DebugTokenPlug do
  @moduledoc """
  `DEBUG_TOKEN` gate for `/internal/debug/*` (spec §10, issue #21).

  Parity with the old Worker's `assertDebugToken` (`src/do/shared/debug-sql.ts`):
  the `Authorization: Bearer <token>` header must match the configured
  `DEBUG_TOKEN` (`config :lilium_chat, :debug_token`), otherwise the
  contract envelope `FORBIDDEN` (403) is rendered. Unconfigured (empty)
  token ⇒ every request is denied — the debug surface is off by default.
  """

  import Plug.Conn

  alias LiliumChat.Errors
  alias LiliumChatWeb.ErrorHandler

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if authorized?(conn) do
      conn
    else
      conn
      |> ErrorHandler.render(Errors.new("FORBIDDEN", "debug endpoint requires valid DEBUG_TOKEN"))
    end
  end

  defp authorized?(conn) do
    case configured_token() do
      token when is_binary(token) and token != "" ->
        conn
        |> get_req_header("authorization")
        |> bearer_token() == token

      _ ->
        false
    end
  end

  defp configured_token do
    Application.get_env(:lilium_chat, :debug_token)
  end

  defp bearer_token([]), do: nil

  defp bearer_token([header | _]) do
    case Regex.run(~r/^Bearer\s+(.+)$/i, String.trim(header)) do
      [_, token] -> token
      _ -> nil
    end
  end
end
