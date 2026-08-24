defmodule LiliumChat.Repo.Migrations.Issue20InteractionsPinId do
  @moduledoc """
  Issue #20 — `interactions.pin_id` (old Worker `interactions.pin_id` parity).

  v2's `interactions` table has no `pin_id` column; #19 stored the pin id in
  `message_id` (double-write). The interaction delivery-completion path
  (issue #20) needs to distinguish pin-locator interactions (whose
  `interaction.completed` event carries `pin_id`, not the content-bearing
  `message`) from message-locator ones — add the nullable column and keep
  the double-write convention (pin interactions store the pin id in both
  `message_id` and `pin_id`, old Worker parity).
  """
  use Ecto.Migration

  def up do
    alter table(:interactions) do
      add :pin_id, :string
    end
  end

  def down do
    alter table(:interactions) do
      remove :pin_id
    end
  end
end
