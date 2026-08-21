ExUnit.start()

# Enable the pg_stat_statements oracle (spec §7.5, issue #3) when the server
# supports it — docker-compose preloads the library for exactly this probe.
# Idempotent; on servers without the shared_preload_libraries entry the
# extension simply cannot be created and the tagged oracle test skips itself.
Ecto.Adapters.SQL.Sandbox.mode(LiliumChat.Repo, :auto)

case Ecto.Adapters.SQL.query(
       LiliumChat.Repo,
       "CREATE EXTENSION IF NOT EXISTS pg_stat_statements",
       []
     ) do
  {:ok, _} ->
    :ok

  {:error, %Postgrex.Error{postgres: %{code: :invalid_authorization_specification}}} ->
    :ok

  {:error, error} ->
    IO.puts("pg_stat_statements setup failed (oracle test will skip): #{inspect(error)}")
end

Ecto.Adapters.SQL.Sandbox.mode(LiliumChat.Repo, :manual)
