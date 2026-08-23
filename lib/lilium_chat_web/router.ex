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

  # Bot-token API (contract §9.3): `Authorization: Bearer <bot_token>` instead
  # of the browser JWT; scopes enforced per route (BotAuthPlug).
  pipeline :bot_api do
    plug Plug.Parsers, parsers: [:json], pass: ["*/*"], json_decoder: Jason
    plug LiliumChatWeb.BotAuthPlug
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
    # Channel lifecycle (contract §5.2b / §5.3 / §5.4, issue #11).
    post "/channels", ChannelsController, :create
    # §5.6 public directory — literal segment must precede "/channels/:channel_id".
    get "/channels/directory", DirectoryController, :index
    get "/channels/:channel_id", ChannelsController, :show
    patch "/channels/:channel_id", ChannelsController, :update
    post "/channels/:channel_id/dissolve", ChannelsController, :dissolve
    get "/channels/:channel_id/messages", MessagesController, :index
    get "/channels/:channel_id/messages/:message_id/context", MessageContextController, :show
    get "/channels/:channel_id/events", EventsController, :channel_index
    get "/events", EventsController, :index

    # Attachment upload (contract §8.1–§8.2, spec §6.2, issue #14 / C7)
    post "/uploads/images/presign", UploadsController, :presign
    post "/uploads/images/:attachment_id/finalize", UploadsController, :finalize

    # Bot domain (contract §9.3/§9.10/§9.11, issue #16): developer + admin
    # Bots API (browser JWT), channel command manifest/binding, directory.
    post "/bots", BotsController, :create
    get "/bots", BotsController, :index
    get "/bots/:bot_id", BotsController, :show
    patch "/bots/:bot_id", BotsController, :update
    get "/bots/:bot_id/tokens", BotsController, :list_tokens
    post "/bots/:bot_id/tokens", BotsController, :create_token
    delete "/bots/:bot_id/tokens/:token_id", BotsController, :revoke_token

    get "/admin/bots", AdminBotsController, :index
    get "/admin/bots/:bot_id", AdminBotsController, :show
    patch "/admin/bots/:bot_id", AdminBotsController, :update
    get "/admin/bots/:bot_id/tokens", AdminBotsController, :list_tokens
    delete "/admin/bots/:bot_id/tokens/:token_id", AdminBotsController, :revoke_token

    # Read path (contract §5.10 / §7.1 / §7.1b / §8.3, issue #7): members,
    # invite preview, personal stickers — all pure reads (A12).
    get "/channels/:channel_id/members", MembersController, :list
    get "/channels/:channel_id/members/:user_id", MembersController, :show
    # Member management (contract §7.2–§7.5, issue #12).
    post "/channels/:channel_id/members", MembersController, :create
    patch "/channels/:channel_id/members/:user_id", MembersController, :update
    delete "/channels/:channel_id/members/:user_id", MembersController, :delete
    post "/channels/:channel_id/owner-transfer", MembersController, :transfer_owner
    get "/invites/:invite_code", InvitesController, :preview
    # Personal sticker library (contract §8.3): list (issue #7) + save/delete
    # (issue #15, Idempotency-Key required).
    get "/stickers", StickersController, :index
    post "/stickers", StickersController, :create
    delete "/stickers/:sticker_id", StickersController, :delete

    get "/channels/:channel_id/commands", ChannelCommandsController, :list

    patch "/channels/:channel_id/commands/:bot_command_id",
          ChannelCommandsController,
          :update_binding

    get "/commands/directory", ChannelCommandsController, :directory
  end

  # Bot-token scope (contract §9.3): `PUT /bot/commands` authenticates with a
  # bot token (BotAuthPlug), not the browser JWT.
  scope "/api/chat", LiliumChatWeb do
    pipe_through :bot_api

    put "/bot/commands", BotCommandsController, :sync
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
