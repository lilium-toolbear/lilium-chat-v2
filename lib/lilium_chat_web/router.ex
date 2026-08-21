defmodule LiliumChatWeb.Router do
  @moduledoc """
  Routes for the lilium-chat API (contract v2.31, `docs/api-contract.md`).

  All `/api/chat/*` browser-API routes go through the `:browser_api`
  pipeline (JWT auth per spec §6.1). Unmatched paths answer with the old
  Worker's default notFound shape (404 text/plain), which intentionally does
  NOT run JWT auth — parity with Hono's notFound handler.

  CORS and X-Request-Id are endpoint-level plugs (they apply to every
  `/api/chat/*` request, including preflight OPTIONS and unknown paths,
  exactly like the production middlewares in old `src/index.ts`).
  """

  use LiliumChatWeb, :router

  pipeline :browser_api do
    plug LiliumChatWeb.AuthPlug
  end

  # Ops probe (non-API path): liveness + DB check. Unauthenticated and outside
  # the /api/chat/* middleware scope (no JWT, no X-Request-Id/CORS headers) —
  # health checks are not part of the Browser/Bot API contract.
  get "/health", LiliumChatWeb.HealthController, :show

  # Contract routes under /api/chat/* (issue #2: common layer + tracer bullet).
  scope "/api/chat", LiliumChatWeb do
    pipe_through :browser_api

    get "/channels", ChannelsController, :index
  end

  if Mix.env() == :test do
    # Test-only: a route that raises, to exercise the CHAT_WORKER_UNAVAILABLE
    # fallback (old Worker appOnError parity) over the full endpoint pipeline.
    scope "/api/chat", LiliumChatWeb do
      pipe_through :browser_api

      get "/__test/boom", TestBoomController, :boom
    end
  end

  # Hono parity: unmatched routes → 404 text/plain "404 Not Found" (no auth),
  # for every HTTP method.
  match(:*, "/", LiliumChatWeb.NotFoundController, :show)
  match(:*, "/*_catchall", LiliumChatWeb.NotFoundController, :show)
end
