# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :lilium_chat,
  ecto_repos: [LiliumChat.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configures the endpoint
config :lilium_chat, LiliumChatWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: LiliumChatWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: LiliumChat.PubSub,
  live_view: [signing_salt: "DRxIluGE"]

# Structured JSON logging (spec D18 / §10): one JSON object per line with
# time / severity / message / metadata. `request_id` is included so log
# lines correlate with the X-Request-Id response header (issue #2 handoff).
config :logger, :default_handler,
  formatter: {LoggerJSON.Formatters.Basic, metadata: [:request_id]}

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# CORS / Origin whitelist — copied verbatim from the old repo
# (lilium-chat/src/allowed-origins.ts, spec §6.3).
config :lilium_chat, :cors,
  origins: [
    "https://lilium.kuma.homes",
    "http://localhost:5174",
    "http://127.0.0.1:5174",
    "http://localhost:3334",
    "http://127.0.0.1:3334"
  ]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
