defmodule LiliumChatWeb.ErrorHandler do
  @moduledoc """
  Renders contract error responses (issue #2).

  Two entry points:

    * `render/2` — explicit API errors (`LiliumChat.Errors.ApiError`) from
      plugs/controllers: exact HTTP status from the code table, JSON envelope
      per contract §2.6, halts the connection.
    * `render_exception/2` — unknown exceptions escaping a controller action:
      rendered as `CHAT_WORKER_UNAVAILABLE` (503, retryable), mirroring the
      old Worker's `app.onError` fallback (`src/index.ts`).

  The `X-Request-Id` header is set by `LiliumChatWeb.RequestId` for every
  `/api/chat/*` response; the envelope's `request_id` field carries the same
  value.
  """

  import Plug.Conn

  alias LiliumChat.Errors

  @doc "Render an explicit ApiError and halt (status from the contract table)."
  @spec render(Plug.Conn.t(), %Errors.ApiError{}) :: Plug.Conn.t()
  def render(conn, %Errors.ApiError{} = api_error) do
    envelope = Errors.envelope(api_error, request_id_of(conn))

    # Hono parity: c.json sends exactly "application/json" (no charset).
    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(api_error.http_status, Jason.encode!(envelope))
    |> halt()
  end

  @doc "Render an unknown exception as CHAT_WORKER_UNAVAILABLE (old Worker onError parity)."
  @spec render_exception(Plug.Conn.t(), Exception.t()) :: Plug.Conn.t()
  def render_exception(conn, %Errors.ApiError{} = api_error), do: render(conn, api_error)

  def render_exception(conn, _exception) do
    render(conn, Errors.new("CHAT_WORKER_UNAVAILABLE"))
  end

  defp request_id_of(conn) do
    conn.private[:lilium_chat_request_id] || LiliumChatWeb.RequestId.current()
  end
end
