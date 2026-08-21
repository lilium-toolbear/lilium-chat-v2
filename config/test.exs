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

# ToolBear JWT secret for tests (spec §6.1).
config :lilium_chat, :jwt, secret: System.get_env("JWT_SECRET") || "test-only-jwt-secret"

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
