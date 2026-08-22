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
    plug Plug.Parsers, parsers: [:json], pass: ["*/*"], json_decoder: Jason
    plug LiliumChatWeb.AuthPlug
  end

  # Ops probes (non-API paths): liveness + DB check, and the Prometheus
  # scrape endpoint (spec §10 / D18). Unauthenticated and outside the
  # /api/chat/* middleware scope (no JWT, no X-Request-Id/CORS headers) —
  # ops probes are not part of the Browser/Bot API contract.
  get "/health", LiliumChatWeb.HealthController, :show
  get "/metrics", LiliumChatWeb.MetricsController, :index

  # Contract routes under /api/chat/* (issue #2: common layer + tracer bullet).
  scope "/api/chat", LiliumChatWeb do
    pipe_through :browser_api

    get "/bootstrap", BootstrapController, :show

    # Read path (contract §5 / §6 / §10.3, issue #6): channels, messages,
    # events, context — all pure reads (A12).
    get "/channels", ChannelsController, :index
    get "/channels/:channel_id", ChannelsController, :show
    get "/channels/:channel_id/messages", MessagesController, :index
    get "/channels/:channel_id/messages/:message_id/context", MessageContextController, :show
    get "/channels/:channel_id/events", EventsController, :channel_index
    get "/events", EventsController, :index

    # Attachment upload (contract §8.1–§8.2, spec §6.2, issue #14 / C7)
    post "/uploads/images/presign", UploadsController, :presign
    post "/uploads/images/:attachment_id/finalize", UploadsController, :finalize
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
