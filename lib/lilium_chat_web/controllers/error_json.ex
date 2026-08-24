defmodule LiliumChatWeb.ErrorJSON do
  @moduledoc """
  Endpoint-level error fallback (issue #2).

  Invoked by the Phoenix endpoint when an exception escapes the plug chain
  (e.g. a malformed request body raised by `Plug.Parsers`). Renders the
  contract envelope (contract §2.6):

    * `LiliumChat.Errors.ApiError` reasons → their own code/status/message;
    * anything else → `CHAT_WORKER_UNAVAILABLE` (old Worker `app.onError`
      fallback semantics).

  Handler-level exceptions are normally caught earlier by controller `rescue`
  clauses via `LiliumChatWeb.ErrorHandler.render_exception/2`; this module is
  the last-resort net so the wire shape never deviates from the contract.
  """

  alias LiliumChat.Errors

  def render(_template, assigns) do
    api_error =
      case Map.fetch(assigns, :reason) do
        {:ok, %Errors.ApiError{} = e} ->
          e

        {:ok, exception} ->
          # Endpoint-level last resort (no conn here): report to Sentry with
          # the process-keyed request id before degrading (spec §10 / A13).
          LiliumChat.Observability.capture_exception(exception, LiliumChatWeb.RequestId.current())
          Errors.new("CHAT_WORKER_UNAVAILABLE")

        :error ->
          Errors.new("CHAT_WORKER_UNAVAILABLE")
      end

    Errors.envelope(api_error, LiliumChatWeb.RequestId.current())
  end
end
