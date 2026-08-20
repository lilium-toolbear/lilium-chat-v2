defmodule LiliumChatWeb.Router do
  use LiliumChatWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Contract routes live under /api/chat/* (docs/api-contract.md v2.31).
  scope "/api/chat", LiliumChatWeb do
    pipe_through :api

    get "/health", HealthController, :show
  end
end
