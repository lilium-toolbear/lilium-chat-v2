defmodule LiliumChat.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Observability telemetry handlers (per-request PG statement counting,
    # spec §4/A12/issue #3) must be attached before any child can emit
    # events. Idempotent across app restarts in the same VM (tests).
    LiliumChat.Observability.attach()

    children = [
      LiliumChatWeb.Telemetry,
      # Live WS connection counter (spec §10 / issue #21): monitors socket
      # processes, decrements on disconnect.
      LiliumChat.Observability.SocketTracker,
      LiliumChat.Repo,
      {DNSCluster, query: Application.get_env(:lilium_chat, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: LiliumChat.PubSub},
      # ETS membership-version cache (spec D8 / §5.2, issue #8)
      LiliumChat.MembershipCache,
      # Bot Gateway (spec §2.2 / D14, issue #17): registry + dynamic
      # supervisor for the per-bot `Bot.<bot_id>` processes (lazy start).
      # The supervisor is named `LiliumChat.BotConnections` (not
      # `LiliumChat.Bots`, which is the bot domain module from issue #16).
      {Registry, keys: :unique, name: LiliumChat.Bots.Registry},
      {DynamicSupervisor, name: LiliumChat.BotConnections, strategy: :one_for_one},
      # Per-channel writer processes (spec §2.2 / D13, issue #9): registry +
      # dynamic supervisor for the lazy-started `Channel.<channel_id>` GenServer
      # that owns the per-channel monotonic event_id counter + serial write.
      {Registry, keys: :unique, name: LiliumChat.Channels.Registry},
      {DynamicSupervisor, name: LiliumChat.ChannelConnections, strategy: :one_for_one},
      # Per-stream processes (spec §2.2 / issue #18): registry + dynamic
      # supervisor for the lazy-started `Stream.<cid>#<mid>` GenServer that
      # owns seq/ack + finalize idempotency.
      {Registry, keys: :unique, name: LiliumChat.Streams.Registry},
      {DynamicSupervisor, name: LiliumChat.StreamConnections, strategy: :one_for_one},
      # Periodic housekeeping GC (spec §2.2 / issue #21): idempotency,
      # pending attachments, stream expiry, bot_deliveries cleanup.
      LiliumChat.Housekeeping,
      # Start a worker by calling: LiliumChat.Worker.start_link(arg)
      # {LiliumChat.Worker, arg},
      # Start to serve requests, typically the last entry
      LiliumChatWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: LiliumChat.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    LiliumChatWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
