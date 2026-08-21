defmodule LiliumChatWeb.TestBoomController do
  @moduledoc """
  Test-only route (`GET /api/chat/__test/boom`, registered only when
  `Mix.env() == :test`).

  Raises a plain (non-ApiError) exception to prove the unknown-error path
  renders `503 CHAT_WORKER_UNAVAILABLE` with the contract envelope — parity
  with the old Worker's `app.onError` handler (old `src/index.ts`), which maps
  every non-ApiError thrown by a route handler to that code. Real controllers
  use the same `rescue → ErrorHandler.render_exception/2` pattern.
  """

  use LiliumChatWeb, :controller

  alias LiliumChatWeb.ErrorHandler

  def boom(conn, _params) do
    raise RuntimeError, "test boom"
  rescue
    e -> ErrorHandler.render_exception(conn, e)
  end
end
