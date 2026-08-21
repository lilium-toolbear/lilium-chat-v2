defmodule LiliumChat.MixProject do
  use Mix.Project

  def project do
    [
      app: :lilium_chat,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {LiliumChat.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.11"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.10"},
      # lock to 0.22.x (1.0.0-rc.1 is pre-release)
      {:postgrex, "~> 0.22"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      # Spec §2.1 / §6: auth, observability
      # JWT (HS256) — rules copied from old src/auth/jwt.ts
      {:joken, "~> 2.6"},
      # Sentry (spec §10)
      {:sentry, "~> 13.0"},
      # HTTP client required by Sentry 13.x (Sentry.FinchClient)
      {:finch, "~> 0.23"},
      # Telemetry → Prometheus (spec §10)
      {:prometheus, "~> 6.1"},
      # telemetry collection (Phoenix events) + /metrics plug
      {:prometheus_ex, "~> 5.1"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end
