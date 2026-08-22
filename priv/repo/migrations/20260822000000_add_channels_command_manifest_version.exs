defmodule LiliumChat.Repo.Migrations.AddChannelsCommandManifestVersion do
  @moduledoc """
  `channels.command_manifest_version` (contract §9.4, issue #16).

  The per-channel monotonic manifest version carried by `GET .../commands`
  and the bootstrap `command_manifest`. The old Worker kept it in
  `channel_meta.command_manifest_version` (default 0); binding updates
  increment it by 1 in the same transaction as the `command.binding_updated`
  event. `command.invoke` (issue #20) compares the client-supplied version
  against it (`COMMAND_MANIFEST_VERSION_STALE`).
  """
  use Ecto.Migration

  def change do
    alter table(:channels) do
      add :command_manifest_version, :integer, null: false, default: 0
    end
  end
end
