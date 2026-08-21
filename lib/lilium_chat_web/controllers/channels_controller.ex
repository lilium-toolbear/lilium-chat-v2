defmodule LiliumChatWeb.ChannelsController do
  @moduledoc """
  Channel routes (contract §4).

  `GET /api/chat/channels` is the tracer-bullet route for the HTTP common
  layer (issue #2): it exercises JWT auth + error contract + CORS +
  X-Request-Id end-to-end and returns the deterministic empty-state shape
  (`{items: [], next_cursor: null}`) that the old Worker produces for a user
  with no channels. Phase 1 (read path) replaces the body with the real
  query over `chat_v2.channel_members` + `chat_v2.read_state` +
  `chat_v2.channels` (spec §4 / D15).
  """

  use LiliumChatWeb, :controller

  alias LiliumChatWeb.ErrorHandler

  def index(conn, _params) do
    # Tracer bullet (issue #2): empty-state shape only — no DB access yet.
    # Hono parity: c.json sends exactly "application/json" (no charset).
    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(200, Jason.encode!(%{items: [], next_cursor: nil}))
  rescue
    e -> ErrorHandler.render_exception(conn, e)
  end
end
