defmodule LiliumChat.Repo.Migrations.CreateChatV2Schema do
  use Ecto.Migration

  @moduledoc """
  Baseline: create the `chat_v2` schema (spec §3).

  All business tables live here; `public.users` (ToolBear profiles) is
  queried on the same instance with an explicit `prefix: "public"`.
  """

  def change do
    execute "CREATE SCHEMA IF NOT EXISTS chat_v2"
  end
end
