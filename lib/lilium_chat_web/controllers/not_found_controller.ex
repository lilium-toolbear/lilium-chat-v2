defmodule LiliumChatWeb.NotFoundController do
  @moduledoc """
  Unmatched-route parity with the old Worker (issue #2).

  Hono's default notFound handler answers every unmatched path — including
  `/api/chat/*` — with `404` + `text/plain; charset=UTF-8` + body
  `"404 Not Found"`, **without** running JWT auth (the reference handlers
  call `getIdentity`, the notFound handler does not). This controller
  reproduces that exactly, so unknown routes under `/api/chat/*` diff clean
  against the old Worker during conformance runs.
  """

  use LiliumChatWeb, :controller

  def show(conn, _params) do
    # Hono parity: exactly "text/plain; charset=UTF-8" (note the case).
    conn
    |> put_resp_header("content-type", "text/plain; charset=UTF-8")
    |> send_resp(404, "404 Not Found")
  end
end
