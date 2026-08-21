defmodule LiliumChat.Repo.Migrations.CreatePublicUsers do
  @moduledoc """
  Ensure `public.users` exists (spec §3 / D16).

  In **production** this table is the ToolBear users table (owned by the main
  backend, many columns). Our `CREATE TABLE IF NOT EXISTS` is a **no-op** there.

  In **test/dev** the table may not exist, so we create a minimal version with
  only the columns the chat backend reads (`user_id`, `full_name`,
  `avatar_url`). The real production table is a superset.

  The `down` is intentionally a no-op: rolling back this migration in
  production must NOT drop the real `public.users` table.
  """
  use Ecto.Migration

  def change do
    execute """
    CREATE TABLE IF NOT EXISTS public.users (
      user_id   VARCHAR(255) PRIMARY KEY,
      full_name VARCHAR(255),
      avatar_url TEXT
    )
    """
  end

  def down do
    # Intentionally no-op: in production the real ToolBear `users` table
    # lives here and must not be dropped by a chat-v2 migration rollback.
    execute "SELECT 1"
  end
end
