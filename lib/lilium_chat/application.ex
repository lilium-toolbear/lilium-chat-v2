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
      LiliumChat.Repo,
      {DNSCluster, query: Application.get_env(:lilium_chat, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: LiliumChat.PubSub},
      # ETS membership-version cache (spec D8 / §5.2, issue #8)
      LiliumChat.MembershipCache,
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
