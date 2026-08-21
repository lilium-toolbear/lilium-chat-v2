defmodule LiliumChat.Repo.Migrations.CreateChatV2Tables do
  @moduledoc """
  `chat_v2` storage baseline (spec §3.2, §3.4; issue #4).

  Creates all 27 business tables in schema `chat_v2`:

  * **Core domain (18)** — near-1:1 copy of the verified `chat.*` archive
    tables (live column set), plus spec-driven additions:
    - `channel_members.status` (SoT membership state; derived from
      `left_at` at import time)
    - `invites.channel_id` (replaces the vanished `invite_index`
      projection — computed on the fly, spec §3.2/§8)
    - `messages.event_id` (per-channel monotonic UUIDv7 cursor for
      timeline pagination; backfilled from `message.created` events at
      import time)
  * **Bot domain (6)** — `bot_apps`, `bot_tokens`, `bot_commands`,
    `bot_command_aliases`, `bot_command_names`, `channel_command_bindings`.
  * **New runtime tables (3)** — `read_state` (from DO SQLite
    `my_channels.last_read_event_id`, spec D12), `idempotency` (3 old dedup
    tables merged, spec D10), `bot_deliveries` (crash recovery, spec D14).

  Vanished tables are intentionally NOT created (spec §3.2): `my_channels`,
  `rate_buckets`, `idempotency_keys`, `bot_effects_applied`,
  `stateful_session_effects_applied`, all outbox/lease/alarm/seq/stream
  runtime tables, and the `public_channels` / `invite_index` projections.

  Hot-read indexes follow spec §3.4 exactly:

  - `channel_members(user_id, status)` — bootstrap "my channels"
  - `channel_members(channel_id, status)` — member list / gate re-check
  - `messages(channel_id, event_id DESC)` — timeline pagination
  - `events(channel_id, event_id)` — gap recovery / replay
  - `read_state(user_id, channel_id)` — PK
  - `idempotency` per-namespace unique keys + `expires_at` GC index
  - `bot_deliveries(bot_id, status)` — crash recovery
  """
  use Ecto.Migration

  def change do
    # ------------------------------------------------------------------
    # Core domain (baseline: chat.*)
    # ------------------------------------------------------------------

    create table(:channels, primary_key: false) do
      add :channel_id, :string, null: false, primary_key: true
      add :kind, :string, null: false
      add :visibility, :string, null: false
      add :title, :string, null: false
      add :topic, :string
      add :avatar_url, :string
      add :status, :string, null: false
      add :created_by, :string, null: false
      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
      add :member_count, :integer, null: false, default: 0
      # Single source of truth for membership versioning (spec D8 / §3.3.1)
      add :membership_version, :integer, null: false, default: 0
      add :archived_source_kind, :string
      add :archived_source_key, :string
      add :archived_source_seq, :bigint
      add :archived_at, :utc_datetime_usec
    end

    create table(:channel_members, primary_key: false) do
      add :channel_id, :string, null: false, primary_key: true
      add :user_id, :string, null: false, primary_key: true
      add :role, :string, null: false
      add :joined_at, :utc_datetime_usec, null: false
      add :left_at, :utc_datetime_usec
      # v2 addition (spec §3.2): SoT membership state ('active' | 'left').
      # Derived at import time from left_at; dissolved-ness lives on the
      # channel (channels.status), not on the member row.
      add :status, :string, null: false
      add :archived_source_kind, :string
      add :archived_source_key, :string
      add :archived_source_seq, :bigint
      add :archived_at, :utc_datetime_usec
    end

    create index(:channel_members, [:user_id, :status], name: :idx_chat_v2_cm_user_status)
    create index(:channel_members, [:channel_id, :status], name: :idx_chat_v2_cm_channel_status)

    create table(:messages, primary_key: false) do
      add :message_id, :string, null: false, primary_key: true
      add :command_id, :string, null: false
      add :dedupe_principal_key, :string, null: false
      add :channel_id, :string, null: false
      add :sender_kind, :string, null: false
      add :sender_user_id, :string
      add :sender_bot_id, :string
      add :type, :string, null: false
      add :format, :string, null: false, default: "plain"
      add :status, :string, null: false, default: "normal"
      add :text, :text
      add :reply_to, :string
      add :reply_snapshot_json, :map
      add :stream_state, :string, null: false, default: "none"
      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
      add :edited_at, :utc_datetime_usec
      add :deleted_at, :utc_datetime_usec
      add :deleted_by, :string
      add :recalled_at, :utc_datetime_usec
      # v2 addition (spec §3.4): per-channel monotonic UUIDv7 cursor of the
      # message.created event that created this message; backfilled at import.
      add :event_id, :string
      add :invocation_json, :map
      add :archived_source_kind, :string
      add :archived_source_key, :string
      add :archived_source_seq, :bigint
      add :archived_at, :utc_datetime_usec
    end

    # Timeline pagination (spec §3.4): event_id DESC for keyset "before" cursors
    create index(:messages, [:channel_id, "event_id DESC"],
             name: :idx_chat_v2_messages_channel_event
           )

    create table(:message_edits, primary_key: false) do
      add :edit_id, :string, primary_key: true
      add :message_id, :string, null: false
      add :old_text, :text
      add :new_text, :text
      add :editor_user_id, :string, null: false
      add :request_id, :string
      add :edited_at, :utc_datetime_usec, null: false
      add :archived_source_kind, :string
      add :archived_source_key, :string
      add :archived_source_seq, :bigint
      add :archived_at, :utc_datetime_usec
    end

    create table(:events, primary_key: false) do
      add :event_id, :string, primary_key: true
      add :event_type, :string, null: false
      add :channel_id, :string, null: false
      add :actor_kind, :string
      add :actor_id, :string
      add :actor_session_id, :string
      add :payload, :map, null: false
      # Snapshot of channels.membership_version at event time (spec D8)
      add :membership_version_at_event, :integer, null: false, default: 0
      add :occurred_at, :utc_datetime_usec, null: false
      add :archived_source_kind, :string
      add :archived_source_key, :string
      add :archived_source_seq, :bigint
      add :archived_at, :utc_datetime_usec
    end

    create index(:events, [:channel_id, :event_id], name: :idx_chat_v2_events_channel_event)

    create table(:attachments, primary_key: false) do
      add :attachment_id, :string, primary_key: true
      add :owner_user_id, :string, null: false
      add :kind, :string, null: false
      add :filename, :string
      add :mime_type, :string, null: false
      add :size_bytes, :integer, null: false
      add :width, :integer
      add :height, :integer
      add :blurhash, :string
      add :storage_key, :string, null: false
      add :url, :string, null: false
      add :status, :string, null: false
      add :created_at, :utc_datetime_usec, null: false
      add :archived_source_kind, :string
      add :archived_source_key, :string
      add :archived_source_seq, :bigint
      add :archived_at, :utc_datetime_usec
    end

    create table(:message_attachments, primary_key: false) do
      add :message_id, :string, primary_key: true
      add :attachment_id, :string, null: false, primary_key: true
      add :deleted_at, :utc_datetime_usec
      add :archived_source_kind, :string
      add :archived_source_key, :string
      add :archived_source_seq, :bigint
      add :archived_at, :utc_datetime_usec
    end

    create table(:message_stickers, primary_key: false) do
      add :message_id, :string, primary_key: true
      add :sticker_id, :string, null: false
      add :attachment_id, :string, null: false
      add :url, :string, null: false
      add :mime_type, :string, null: false
      add :width, :integer
      add :height, :integer
      add :size_bytes, :integer, null: false
      add :blurhash, :string
      add :deleted_at, :utc_datetime_usec
      add :archived_source_kind, :string
      add :archived_source_key, :string
      add :archived_source_seq, :bigint
      add :archived_at, :utc_datetime_usec
    end

    create table(:mentions, primary_key: false) do
      add :message_id, :string, primary_key: true
      add :user_id, :string, null: false
      add :start_index, :integer, null: false, primary_key: true
      add :end_index, :integer, null: false, primary_key: true
      add :deleted_at, :utc_datetime_usec
      add :archived_source_kind, :string
      add :archived_source_key, :string
      add :archived_source_seq, :bigint
      add :archived_at, :utc_datetime_usec
    end

    create table(:invites, primary_key: false) do
      add :invite_code, :string, primary_key: true
      add :created_by, :string, null: false
      # v2 addition (spec §3.2): invite code -> channel. Replaces the
      # vanished InviteDirectory `invite_index` projection; backfilled from
      # the per-ChatChannel DO export at import time (nullable until then).
      add :channel_id, :string
      add :expires_at, :utc_datetime_usec
      add :max_uses, :integer
      add :used_count, :integer, null: false, default: 0
      add :revoked_at, :utc_datetime_usec
      add :created_at, :utc_datetime_usec, null: false
      add :archived_source_kind, :string
      add :archived_source_key, :string
      add :archived_source_seq, :bigint
      add :archived_at, :utc_datetime_usec
    end

    create index(:invites, [:channel_id], name: :idx_chat_v2_invites_channel)

    create table(:dm_pairs, primary_key: false) do
      add :pair_key, :string, primary_key: true
      add :user_low, :string, null: false
      add :user_high, :string, null: false
      add :channel_id, :string, null: false
      add :created_by, :string, null: false
      add :status, :string, null: false
      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
      add :archived_source_kind, :string
      add :archived_source_key, :string
      add :archived_source_seq, :bigint
      add :archived_at, :utc_datetime_usec
    end

    create table(:personal_stickers, primary_key: false) do
      add :sticker_id, :string, primary_key: true
      add :user_id, :string, null: false
      add :attachment_id, :string, null: false
      add :url, :string, null: false
      add :mime_type, :string, null: false
      add :width, :integer
      add :height, :integer
      add :size_bytes, :integer, null: false
      add :blurhash, :string
      add :created_at, :utc_datetime_usec, null: false
      add :deleted_at, :utc_datetime_usec
      add :archived_source_kind, :string
      add :archived_source_key, :string
      add :archived_source_seq, :bigint
      add :archived_at, :utc_datetime_usec
    end

    create unique_index(:personal_stickers, [:user_id, :attachment_id],
             name: :uniq_chat_v2_personal_stickers_user_att
           )

    create table(:audit_logs, primary_key: false) do
      add :audit_id, :string, primary_key: true
      add :actor_kind, :string, null: false
      add :actor_id, :string, null: false
      add :action, :string, null: false
      add :target_type, :string, null: false
      add :target_id, :string, null: false
      add :before_json, :map
      add :after_json, :map
      add :reason, :string
      add :request_id, :string
      add :created_at, :utc_datetime_usec, null: false
      add :archived_source_kind, :string
      add :archived_source_key, :string
      add :archived_source_seq, :bigint
      add :archived_at, :utc_datetime_usec
    end

    create table(:channel_pins, primary_key: false) do
      add :pin_id, :string, primary_key: true
      add :channel_id, :string, null: false
      add :pin_kind, :string, null: false
      add :pin_owner_kind, :string, null: false
      add :pin_owner_id, :string, null: false
      add :priority, :integer, null: false, default: 0
      add :session_id, :string
      add :source_message_id, :string
      add :pinned_by_user_id, :string
      add :pinned_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec
      add :last_pin_event_id, :string, null: false
      add :message_projection_json, :map, null: false
      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
      add :archived_source_kind, :string
      add :archived_source_key, :string
      add :archived_source_seq, :bigint
      add :archived_at, :utc_datetime_usec
    end

    create index(:channel_pins, [:channel_id, :priority, :pin_id],
             name: :idx_chat_v2_channel_pins_channel
           )

    create table(:command_invocations, primary_key: false) do
      add :invocation_id, :string, primary_key: true
      add :channel_id, :string, null: false
      add :command_id, :string, null: false
      add :invoker_user_id, :string, null: false
      add :bot_id, :string, null: false
      add :bot_command_id, :string, null: false
      add :command_name, :string, null: false
      add :invoked_name, :string, null: false
      add :command_schema_version, :integer, null: false
      add :command_definition_hash, :string
      add :options_json, :map
      add :status, :string, null: false
      add :error_code, :string
      add :error_message, :string
      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
      add :completed_at, :utc_datetime_usec
      add :archived_source_kind, :string
      add :archived_source_key, :string
      add :archived_source_seq, :bigint
      add :archived_at, :utc_datetime_usec
    end

    create unique_index(:command_invocations, [:channel_id, :invoker_user_id, :command_id],
             name: :uniq_chat_v2_invocations_dedupe
           )

    create table(:interactions, primary_key: false) do
      add :interaction_id, :string, primary_key: true
      add :message_id, :string, null: false
      add :component_id, :string, null: false
      add :custom_id, :string, null: false
      add :actor_user_id, :string, null: false
      add :dedupe_principal_key, :string, null: false
      add :command_id, :string, null: false
      add :value_json, :map
      add :status, :string, null: false
      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
      add :completed_at, :utc_datetime_usec
      add :error_code, :string
      add :archived_source_kind, :string
      add :archived_source_key, :string
      add :archived_source_seq, :bigint
      add :archived_at, :utc_datetime_usec
    end

    create unique_index(:interactions, [:message_id, :dedupe_principal_key, :command_id],
             name: :uniq_chat_v2_interactions_dedupe
           )

    create table(:stateful_command_sessions, primary_key: false) do
      add :session_id, :string, primary_key: true
      add :channel_id, :string, null: false
      add :bot_id, :string, null: false
      add :bot_command_id, :string, null: false
      add :invocation_id, :string, null: false
      add :started_by_user_id, :string, null: false
      add :status, :string, null: false
      add :listen_rules_json, :map, null: false
      add :input_next_seq, :integer, null: false, default: 1
      add :input_last_acked_seq, :integer, null: false, default: 0
      add :effect_last_acked_seq, :integer, null: false, default: 0
      add :started_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :closed_at, :utc_datetime_usec
      add :close_reason, :string
      add :summary_json, :map
      add :archived_source_kind, :string
      add :archived_source_key, :string
      add :archived_source_seq, :bigint
      add :archived_at, :utc_datetime_usec
    end

    create table(:stateful_session_inputs, primary_key: false) do
      add :session_id, :string, primary_key: true
      add :seq, :integer, null: false, primary_key: true
      add :channel_id, :string, null: false
      add :event_id, :string, null: false
      add :message_id, :string, null: false
      add :message_projection_json, :map, null: false
      add :status, :string, null: false
      add :created_at, :utc_datetime_usec, null: false
      add :sent_at, :utc_datetime_usec
      add :acked_at, :utc_datetime_usec
      add :archived_source_kind, :string
      add :archived_source_key, :string
      add :archived_source_seq, :bigint
      add :archived_at, :utc_datetime_usec
    end

    # ------------------------------------------------------------------
    # Bot domain (baseline: chat.*)
    # ------------------------------------------------------------------

    create table(:bot_apps, primary_key: false) do
      add :bot_id, :string, primary_key: true
      add :owner_user_id, :string, null: false
      add :display_name, :string, null: false
      add :avatar_url, :string
      add :status, :string, null: false
      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
      add :description, :string
      add :visibility, :string, null: false, default: "private"
      add :archived_source_kind, :string
      add :archived_source_key, :string
      add :archived_source_seq, :bigint
      add :archived_at, :utc_datetime_usec
    end

    create table(:bot_tokens, primary_key: false) do
      add :token_id, :string, primary_key: true
      add :bot_id, :string, null: false
      # SHA-256 hash of the token; plaintext returned once (spec §6.1)
      add :token_hash, :string, null: false
      add :scopes, :string, null: false
      add :created_at, :utc_datetime_usec, null: false
      add :revoked_at, :utc_datetime_usec
      add :name, :string, null: false, default: "default"
      add :expires_at, :utc_datetime_usec
      add :last_used_at, :utc_datetime_usec
      add :archived_source_kind, :string
      add :archived_source_key, :string
      add :archived_source_seq, :bigint
      add :archived_at, :utc_datetime_usec
    end

    create unique_index(:bot_tokens, [:token_hash], name: :uniq_chat_v2_bot_tokens_hash)

    create table(:bot_commands, primary_key: false) do
      add :bot_command_id, :string, primary_key: true
      add :bot_id, :string, null: false
      add :name, :string, null: false
      add :description, :string
      add :options_json, :map
      add :default_member_permission, :string
      add :schema_version, :integer, null: false, default: 1
      add :definition_hash, :string
      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
      add :deleted_at, :utc_datetime_usec
      add :execution_mode, :string, null: false, default: "stateless"
      add :stateful_config_json, :map
      add :status, :string, null: false, default: "active"
      # TEXT (not varchar(255)): live help_text values reach 335 chars.
      add :help_text, :text, null: false, default: ""
      add :archived_source_kind, :string
      add :archived_source_key, :string
      add :archived_source_seq, :bigint
      add :archived_at, :utc_datetime_usec
    end

    create unique_index(:bot_commands, [:bot_id, :name], name: :uniq_chat_v2_bot_commands_name)

    create table(:bot_command_aliases, primary_key: false) do
      add :bot_command_id, :string, primary_key: true
      add :bot_id, :string, null: false
      add :alias, :string, null: false, primary_key: true
      add :created_at, :utc_datetime_usec, null: false
      add :deleted_at, :utc_datetime_usec
      add :archived_source_kind, :string
      add :archived_source_key, :string
      add :archived_source_seq, :bigint
      add :archived_at, :utc_datetime_usec
    end

    create table(:bot_command_names, primary_key: false) do
      add :slash_token, :string, primary_key: true
      add :bot_command_id, :string, null: false
      add :bot_id, :string, null: false
      add :kind, :string, null: false
      add :created_at, :utc_datetime_usec, null: false
      add :deleted_at, :utc_datetime_usec
      add :archived_source_kind, :string
      add :archived_source_key, :string
      add :archived_source_seq, :bigint
      add :archived_at, :utc_datetime_usec
    end

    create table(:channel_command_bindings, primary_key: false) do
      add :channel_id, :string, primary_key: true
      add :bot_command_id, :string, null: false, primary_key: true
      add :bot_id, :string, null: false
      add :status, :string, null: false
      add :permission_override, :string
      add :command_snapshot_json, :map, null: false
      add :stateful_max_ttl_seconds, :integer
      add :updated_by_user_id, :string, null: false
      add :updated_at, :utc_datetime_usec, null: false
      add :archived_source_kind, :string
      add :archived_source_key, :string
      add :archived_source_seq, :bigint
      add :archived_at, :utc_datetime_usec
    end

    # ------------------------------------------------------------------
    # New runtime tables (spec §3.2 / D10 / D12 / D14)
    # ------------------------------------------------------------------

    # Per-user per-channel read cursor (spec D12: my_channels decomposed).
    # Sourced from DO SQLite `my_channels.last_read_event_id` via the debug
    # API export at cutover (spec §8). last_read_event_id is a per-channel
    # monotonic UUIDv7; contract requires it to advance monotonically.
    create table(:read_state, primary_key: false) do
      add :user_id, :string, null: false, primary_key: true
      add :channel_id, :string, null: false, primary_key: true
      add :last_read_event_id, :string, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    # 3 old dedup tables merged (spec D10): idempotency_keys +
    # bot_effects_applied + stateful_session_effects_applied. `namespace`
    # selects the key column set; each namespace keeps its original key
    # semantics via a partial unique index. Housekeeping GCs by expires_at.
    create table(:idempotency, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :namespace, :string, null: false
      # user_command namespace (was idempotency_keys / bot_idempotency_keys)
      add :principal_kind, :string
      add :principal_id, :string
      add :operation, :string
      add :operation_id, :string
      add :status, :string
      # bot_effect namespace (was bot_effects_applied)
      add :channel_id, :string
      add :bot_id, :string
      add :client_effect_id, :string
      add :effect_type, :string
      add :message_id, :string
      # session_effect namespace (was stateful_session_effects_applied)
      add :session_id, :string
      add :effect_seq, :bigint
      add :finalize_completed_at, :utc_datetime_usec
      # shared
      add :request_hash, :string, null: false
      add :response_json, :map
      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec
    end

    create constraint(:idempotency, :chk_chat_v2_idem_namespace,
             check: "namespace IN ('user_command', 'bot_effect', 'session_effect')"
           )

    create unique_index(
             :idempotency,
             [:principal_kind, :principal_id, :operation, :operation_id],
             where: "namespace = 'user_command'",
             name: :uniq_chat_v2_idem_user_command
           )

    create unique_index(
             :idempotency,
             [:channel_id, :bot_id, :client_effect_id],
             where: "namespace = 'bot_effect'",
             name: :uniq_chat_v2_idem_bot_effect
           )

    create unique_index(
             :idempotency,
             [:session_id, :effect_seq],
             where: "namespace = 'session_effect'",
             name: :uniq_chat_v2_idem_session_effect
           )

    # GC scan (Housekeeping, spec §3.3.2) + idempotency lookup by namespace
    create index(:idempotency, [:expires_at], name: :idx_chat_v2_idem_expires)

    # Bot delivery crash recovery (spec D14 / §5.3): committed-but-undelivered
    # invocations; bot reconnect resumes by delivery_id (UUIDv7 ordered).
    create table(:bot_deliveries, primary_key: false) do
      add :delivery_id, :string, primary_key: true
      add :channel_id, :string, null: false
      add :bot_id, :string, null: false
      # 'message' | 'invocation' | 'interaction' (contract delivery kinds)
      add :kind, :string, null: false
      add :invocation_id, :string
      add :interaction_id, :string
      add :event_id, :string
      add :request_json, :map, null: false
      # 'pending' | 'delivered' | 'dropped'
      add :status, :string, null: false, default: "pending"
      add :attempts, :integer, null: false, default: 0
      add :max_attempts, :integer, null: false, default: 5
      add :last_error, :string
      add :failed_at, :utc_datetime_usec
      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
      add :delivered_at, :utc_datetime_usec
    end

    create index(:bot_deliveries, [:bot_id, :status],
             name: :idx_chat_v2_bot_deliveries_bot_status
           )
  end
end
