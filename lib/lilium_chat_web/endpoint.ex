defmodule LiliumChatWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :lilium_chat

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  @session_options [
    store: :cookie,
    key: "_lilium_chat_key",
    signing_salt: "av6ew7vc",
    same_site: "Lax"
  ]

  # socket "/live", Phoenix.LiveView.Socket,
  #   websocket: [connect_info: [session: @session_options]],
  #   longpoll: [connect_info: [session: @session_options]]

  # Serve at "/" the static files from "priv/static" directory.
  #
  # You should set gzip to true if you are running phx.digest
  # when deploying your static files in production.
  plug Plug.Static,
    at: "/",
    from: :lilium_chat,
    gzip: false,
    only: LiliumChatWeb.static_paths()

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :lilium_chat
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  # CORS — origin whitelist from config :lilium_chat, :cors, origins
  # (copied from the old repo src/allowed-origins.ts, spec §6.3).
  plug Corsica,
    origins: Application.compile_env(:lilium_chat, :cors)[:origins],
    methods: [:get, :post, :put, :patch, :delete, :options],
    headers: [:authorization, :content_type, :idempotency_key, :x_request_id],
    expose_headers: [:x_request_id],
    max_age: 86_400

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug LiliumChatWeb.Router
end
