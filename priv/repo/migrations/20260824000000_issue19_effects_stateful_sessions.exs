defmodule LiliumChat.Repo.Migrations.Issue19EffectsStatefulSessions do
  @moduledoc """
  Issue #19 — effects + stateful sessions + pin effects + graceful stop.

  Schema deltas (old Worker parity, spec §3.8 / §9.14 / §9.17 / §10.4):

  * `messages.components_json` — bot effect component state (old DO `messages`
    column; v2 read path projects it for Browser messages, contract §3.8).
  * `attachments.owner_bot_id` + `attachments.channel_id` (and
    `owner_user_id` made nullable) — bot effect attachment resolution
    (contract §9.17.1: an effect may reference only finalized bot-owned
    attachments of the same channel).
  * `stateful_command_sessions.stop_grace_at` — persisted stop-grace target
    (old Worker alarm `stateful_session_stop_grace`; the per-channel writer
    re-arms the timer from it on restart).
  * Partial unique index: at most ONE active stateful session per channel
    (old Worker `uniq_active_stateful_session_per_channel`, spec §9.12.1).
  * Partial unique index: at most ONE `session_control` pin per channel
    (old Worker `getSessionControlPinRow` single-row invariant, contract
    §3.10 / §9.12.2).
  """
  use Ecto.Migration

  def up do
    alter table(:messages) do
      add :components_json, :jsonb, null: false, default: "[]"
    end

    alter table(:attachments) do
      # Bot presign rows have no user owner (contract §9.17.1).
      modify :owner_user_id, :string, null: true
      add :owner_bot_id, :string
      add :channel_id, :string
    end

    execute(
      "CREATE INDEX IF NOT EXISTS idx_chat_v2_attachments_channel " <>
        "ON chat_v2.attachments (channel_id)"
    )

    alter table(:stateful_command_sessions) do
      add :stop_grace_at, :utc_datetime_usec
    end

    # One active (non-terminal) stateful session per channel — the mutex
    # (spec §9.12.1). Terminal: closed / expired / failed.
    execute(
      "CREATE UNIQUE INDEX IF NOT EXISTS uniq_chat_v2_one_active_stateful_session_per_channel " <>
        "ON chat_v2.stateful_command_sessions (channel_id) " <>
        "WHERE status IN ('starting', 'active', 'suspended', 'closing')"
    )

    # One platform session-control pin per channel (contract §3.10 / §9.12.2).
    execute(
      "CREATE UNIQUE INDEX IF NOT EXISTS uniq_chat_v2_one_session_control_pin_per_channel " <>
        "ON chat_v2.channel_pins (channel_id) " <>
        "WHERE pin_kind = 'session_control'"
    )
  end

  def down do
    execute("DROP INDEX IF EXISTS uniq_chat_v2_one_session_control_pin_per_channel")
    execute("DROP INDEX IF EXISTS uniq_chat_v2_one_active_stateful_session_per_channel")

    alter table(:stateful_command_sessions) do
      remove :stop_grace_at
    end

    execute("DROP INDEX IF EXISTS idx_chat_v2_attachments_channel")

    alter table(:attachments) do
      remove :owner_bot_id
      remove :channel_id
      modify :owner_user_id, :string, null: false
    end

    alter table(:messages) do
      remove :components_json
    end
  end
end
