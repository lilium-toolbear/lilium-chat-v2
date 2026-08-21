defmodule Mix.Tasks.LiliumChat.CreateSchema do
  @moduledoc """
  Ensure the `chat_v2` schema exists in the configured database.

  Ecto 3.14's migrator does not auto-create a prefixed schema, and
  `schema_migrations` (created under `--prefix chat_v2`) requires it to
  exist first. Run this before `mix ecto.migrate --prefix chat_v2` on a
  fresh database.

  Idempotent: `CREATE SCHEMA IF NOT EXISTS`.
  """
  use Mix.Task

  @shortdoc "Create the chat_v2 schema if missing (idempotent)"

  @impl true
  def run(args) do
    Mix.Task.run("app.start", args)

    alias LiliumChat.Repo

    Repo.query!("CREATE SCHEMA IF NOT EXISTS chat_v2")
    :ok
  end
end
