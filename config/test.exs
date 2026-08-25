import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :lilium_chat, LiliumChat.Repo,
  username: "chat",
  password: "chat",
  hostname: System.get_env("DB_HOSTNAME") || "localhost",
  port: String.to_integer(System.get_env("DB_PORT") || "5432"),
  database: "lilium_chat_test#{System.get_env("MIX_TEST_PARTITION")}",
  prefix: "chat_v2",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Bot Gateway timing (issue #17) inherits the defaults from config.exs;
# individual tests override per-test via `Application.put_env`.

# ToolBear JWT secret for tests (spec §6.1).
config :lilium_chat, :jwt, secret: System.get_env("JWT_SECRET") || "test-only-jwt-secret"

# S3 / SeaweedFS (spec §6.2). Tests use a fake HEAD transport
# (`LiliumChat.S3.TestTransport`) whose behaviour is set per-test via
# `:s3_fake_head`, so no real object store is needed for `mix test`.
# Credentials are deliberate literals (issue #27 batch-1): tests assert these
# deterministic defaults regardless of container env — the app container
# permanently carries conformance fake-S3 `S3_*` vars, which would leak into
# `mix test`. The dev env still reads real env vars via config/dev.exs.
config :lilium_chat, :s3,
  access_key_id: "test-access-key",
  secret_access_key: "test-secret-key",
  region: "us-east-1",
  endpoint: "https://s3.kuma.homes",
  bucket: "lilium-chat-attachments",
  public_base: "https://s3.kuma.homes",
  presign_ttl_seconds: String.to_integer(System.get_env("PRESIGN_TTL_SECONDS") || "300")

config :lilium_chat, :s3_transport, LiliumChat.S3.TestTransport

# Housekeeping GC (issue #21): no periodic timer under test — the
# background process would fight the SQL sandbox. Tests drive
# `LiliumChat.Housekeeping.run_now/0` directly inside their own sandbox.
config :lilium_chat, :housekeeping, enabled: false

# /internal/debug/* gate (issue #21): a known test token; individual tests
# override per-test via `Application.put_env` to exercise 403s.
config :lilium_chat, :debug_token, "test-debug-token"

# Sentry test mode (issue #21): starts the per-test registry + ownership
# server used by `Sentry.Test` at boot. No DSN is configured, so
# `LiliumChat.Observability.capture_exception/2` is a no-op unless a test
# sets up its own collector via `Sentry.Test.setup_sentry/1`.
config :sentry, test_mode: true

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :lilium_chat, LiliumChatWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "xrL5dIYQ4PSwdUZ/tdP5N9cJQF1Xs0dZhWTiVNvJCZewMAXie9ICi9xFOTV6iCUi",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime
