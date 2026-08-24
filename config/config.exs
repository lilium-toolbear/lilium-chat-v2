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

# Bot Gateway WS (contract §9.7 / issue #17): connection lease and the
# offline short-TTL for committed-but-undelivered deliveries. Values are
# milliseconds; defaults mirror the old Worker (CONNECTION_LEASE_TTL_MS /
# MESSAGE_EVENT_TTL_MS / STREAM_DEFAULT_TTL_SECONDS). Tests override these
# per-test via `Application.put_env`.
config :lilium_chat, :bot_gateway,
  lease_ttl_ms: 60_000,
  offline_ttl_ms: 30_000,
  message_event_ttl_ms: 30_000,
  stream_ttl_seconds: 300

# Bot Stream WS cadence (contract §9.15 / old stream-constants.ts).
config :lilium_chat, :bot_stream,
  ttl_seconds: 300,
  ack_flush_interval_ms: 250,
  fanout_interval_ms: 100,
  pending_flush_threshold_bytes: 8_192,
  fanout_max_pending_bytes: 4_096

# Housekeeping GC (spec §2.2 / issue #21): cadence + per-task TTLs. Tests
# set `enabled: false` and drive sweeps directly via
# `LiliumChat.Housekeeping.run_now/0` inside the sandbox.
#
# The stream-expiry TTL is NOT set here: `expire_streams/0` derives it from
# the live stream TTL (`:bot_stream` `ttl_seconds`) so the two cannot drift
# apart. `stream_ttl_ms` remains a valid (optional) override key, e.g. for
# tests.
config :lilium_chat, :housekeeping,
  enabled: true,
  interval_ms: 60_000,
  sweep_batch: 500,
  pending_attachment_ttl_ms: 600_000,
  delivery_retention_ms: 60_000

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

# SPA origin for user-facing URLs — the old Worker's `API_BASE_URL`
# (wrangler.jsonc: https://lilium.kuma.homes — the SPA origin, NOT the
# chat API host chat.kuma.homes; contract v2.15 correction). Used for
# the §5.8 invite create response `invite_url`.
config :lilium_chat, :api_base_url, "https://lilium.kuma.homes"

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
