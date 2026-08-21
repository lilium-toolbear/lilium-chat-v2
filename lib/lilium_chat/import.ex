defmodule LiliumChat.Import do
  @moduledoc """
  Cutover import tools for the `chat_v2` storage baseline (spec §3, §8; issue #4).

  Three concerns:

  1. **Copy** — near-1:1 copy of the verified `chat.*` archive tables into
     `chat_v2.*` (same PG instance, single transaction, idempotent:
     TRUNCATE + INSERT...SELECT per table). Derived columns:
     - `channel_members.status` = 'active' | 'left' (from `left_at`;
       dissolved-ness lives on `channels.status`)
     - `invites.channel_id` — NULL until backfilled from the DO export
     - `messages.event_id` — backfilled from `message.created` events

  2. **Verify** — watermark verification after copy: per-table row counts
     and MAX() of monotonic columns must match between `chat.*` and
     `chat_v2.*`; plus an archive-lag report (`chat.archive_records`
     pending replay) so the operator can confirm the archive consumer has
     drained before cutover (spec §8 step 2: "校验 watermark 追平").

  3. **DO SQLite runtime export import** (spec D4/D10/§8):
     - `read_state` rows from `my_channels.last_read_event_id`
       (UserDirectory, exported via the old Worker's `/internal/debug/sql-all`)
     - `invites.channel_id` mapping + full invite rows (per-ChatChannel DO)

  The export side (calling the old Worker debug API) lives in
  `LiliumChat.DebugExport`; the mix tasks `lilium_chat.import` and
  `lilium_chat.export` wire both together.
  """

  alias LiliumChat.Repo

  require Logger

  @source_schema "chat"
  @target_schema "chat_v2"

  # ----------------------------------------------------------------------
  # Table map (single source of truth for copy + verify)
  #
  # Order = copy order (parents before children; no FKs, but readable).
  # `:columns` — target columns in INSERT order. The source expression is
  #   the same column name unless a derived expression appears (`:derived`).
  # `:watermarks` — monotonic columns compared via MAX() in verify/1.
  # ----------------------------------------------------------------------

  @archived_cols [
    :archived_source_kind,
    :archived_source_key,
    :archived_source_seq,
    :archived_at
  ]

  def tables do
    [
      table(:channels,
        columns:
          [
            :channel_id,
            :kind,
            :visibility,
            :title,
            :topic,
            :avatar_url,
            :status,
            :created_by,
            :created_at,
            :updated_at,
            :member_count,
            :membership_version
          ] ++
            @archived_cols,
        watermarks: [:updated_at]
      ),
      # Derived: status from left_at (spec §3.2 SoT membership)
      table(:channel_members,
        columns: [:channel_id, :user_id, :role, :joined_at, :left_at, :status] ++ @archived_cols,
        derived: [status: "CASE WHEN left_at IS NULL THEN 'active' ELSE 'left' END"],
        watermarks: [:joined_at]
      ),
      # Derived: event_id backfilled after copy (spec §3.4 timeline index)
      table(:messages,
        columns:
          [
            :message_id,
            :command_id,
            :dedupe_principal_key,
            :channel_id,
            :sender_kind,
            :sender_user_id,
            :sender_bot_id,
            :type,
            :format,
            :status,
            :text,
            :reply_to,
            :reply_snapshot_json,
            :stream_state,
            :created_at,
            :updated_at,
            :edited_at,
            :deleted_at,
            :deleted_by,
            :recalled_at,
            :event_id,
            :invocation_json
          ] ++
            @archived_cols,
        derived: [event_id: "NULL"],
        watermarks: [:created_at, :updated_at]
      ),
      table(:message_edits,
        columns:
          [:edit_id, :message_id, :old_text, :new_text, :editor_user_id, :request_id, :edited_at] ++
            @archived_cols,
        watermarks: [:edited_at]
      ),
      table(:events,
        columns:
          [
            :event_id,
            :event_type,
            :channel_id,
            :actor_kind,
            :actor_id,
            :actor_session_id,
            :payload,
            :membership_version_at_event,
            :occurred_at
          ] ++
            @archived_cols,
        watermarks: [:occurred_at]
      ),
      table(:attachments,
        columns:
          [
            :attachment_id,
            :owner_user_id,
            :kind,
            :filename,
            :mime_type,
            :size_bytes,
            :width,
            :height,
            :blurhash,
            :storage_key,
            :url,
            :status,
            :created_at
          ] ++
            @archived_cols,
        watermarks: [:created_at]
      ),
      table(:message_attachments,
        columns: [:message_id, :attachment_id, :deleted_at] ++ @archived_cols,
        watermarks: []
      ),
      table(:message_stickers,
        columns:
          [
            :message_id,
            :sticker_id,
            :attachment_id,
            :url,
            :mime_type,
            :width,
            :height,
            :size_bytes,
            :blurhash,
            :deleted_at
          ] ++
            @archived_cols,
        watermarks: []
      ),
      table(:mentions,
        columns: [:message_id, :user_id, :start_index, :end_index, :deleted_at] ++ @archived_cols,
        watermarks: []
      ),
      # Derived: channel_id backfilled from the per-ChatChannel DO export
      table(:invites,
        columns:
          [
            :invite_code,
            :created_by,
            :channel_id,
            :expires_at,
            :max_uses,
            :used_count,
            :revoked_at,
            :created_at
          ] ++
            @archived_cols,
        derived: [channel_id: "NULL"],
        watermarks: [:created_at]
      ),
      table(:dm_pairs,
        columns:
          [
            :pair_key,
            :user_low,
            :user_high,
            :channel_id,
            :created_by,
            :status,
            :created_at,
            :updated_at
          ] ++
            @archived_cols,
        watermarks: [:updated_at]
      ),
      table(:personal_stickers,
        columns:
          [
            :sticker_id,
            :user_id,
            :attachment_id,
            :url,
            :mime_type,
            :width,
            :height,
            :size_bytes,
            :blurhash,
            :created_at,
            :deleted_at
          ] ++
            @archived_cols,
        watermarks: [:created_at]
      ),
      table(:audit_logs,
        columns:
          [
            :audit_id,
            :actor_kind,
            :actor_id,
            :action,
            :target_type,
            :target_id,
            :before_json,
            :after_json,
            :reason,
            :request_id,
            :created_at
          ] ++
            @archived_cols,
        watermarks: [:created_at]
      ),
      table(:channel_pins,
        columns:
          [
            :pin_id,
            :channel_id,
            :pin_kind,
            :pin_owner_kind,
            :pin_owner_id,
            :priority,
            :session_id,
            :source_message_id,
            :pinned_by_user_id,
            :pinned_at,
            :expires_at,
            :last_pin_event_id,
            :message_projection_json,
            :created_at,
            :updated_at
          ] ++
            @archived_cols,
        watermarks: [:updated_at]
      ),
      table(:command_invocations,
        columns:
          [
            :invocation_id,
            :channel_id,
            :command_id,
            :invoker_user_id,
            :bot_id,
            :bot_command_id,
            :command_name,
            :invoked_name,
            :command_schema_version,
            :command_definition_hash,
            :options_json,
            :status,
            :error_code,
            :error_message,
            :created_at,
            :updated_at,
            :completed_at
          ] ++
            @archived_cols,
        watermarks: [:updated_at]
      ),
      table(:interactions,
        columns:
          [
            :interaction_id,
            :message_id,
            :component_id,
            :custom_id,
            :actor_user_id,
            :dedupe_principal_key,
            :command_id,
            :value_json,
            :status,
            :created_at,
            :updated_at,
            :completed_at,
            :error_code
          ] ++
            @archived_cols,
        watermarks: [:updated_at]
      ),
      table(:stateful_command_sessions,
        columns:
          [
            :session_id,
            :channel_id,
            :bot_id,
            :bot_command_id,
            :invocation_id,
            :started_by_user_id,
            :status,
            :listen_rules_json,
            :input_next_seq,
            :input_last_acked_seq,
            :effect_last_acked_seq,
            :started_at,
            :expires_at,
            :closed_at,
            :close_reason,
            :summary_json
          ] ++
            @archived_cols,
        watermarks: [:started_at]
      ),
      table(:stateful_session_inputs,
        columns:
          [
            :session_id,
            :seq,
            :channel_id,
            :event_id,
            :message_id,
            :message_projection_json,
            :status,
            :created_at,
            :sent_at,
            :acked_at
          ] ++
            @archived_cols,
        watermarks: [:created_at]
      ),
      # Bot domain
      table(:bot_apps,
        columns:
          [
            :bot_id,
            :owner_user_id,
            :display_name,
            :avatar_url,
            :status,
            :created_at,
            :updated_at,
            :description,
            :visibility
          ] ++
            @archived_cols,
        watermarks: [:updated_at]
      ),
      table(:bot_tokens,
        columns:
          [
            :token_id,
            :bot_id,
            :token_hash,
            :scopes,
            :created_at,
            :revoked_at,
            :name,
            :expires_at,
            :last_used_at
          ] ++
            @archived_cols,
        watermarks: [:created_at]
      ),
      table(:bot_commands,
        columns:
          [
            :bot_command_id,
            :bot_id,
            :name,
            :description,
            :options_json,
            :default_member_permission,
            :schema_version,
            :definition_hash,
            :created_at,
            :updated_at,
            :deleted_at,
            :execution_mode,
            :stateful_config_json,
            :status,
            :help_text
          ] ++
            @archived_cols,
        watermarks: [:updated_at]
      ),
      table(:bot_command_aliases,
        columns: [:bot_command_id, :bot_id, :alias, :created_at, :deleted_at] ++ @archived_cols,
        watermarks: [:created_at]
      ),
      table(:bot_command_names,
        columns:
          [:slash_token, :bot_command_id, :bot_id, :kind, :created_at, :deleted_at] ++
            @archived_cols,
        watermarks: [:created_at]
      ),
      table(:channel_command_bindings,
        columns:
          [
            :channel_id,
            :bot_command_id,
            :bot_id,
            :status,
            :permission_override,
            :command_snapshot_json,
            :stateful_max_ttl_seconds,
            :updated_by_user_id,
            :updated_at
          ] ++
            @archived_cols,
        watermarks: [:updated_at]
      )
    ]
  end

  defp table(name, opts) do
    Map.merge(%{name: name}, Map.new(opts))
  end

  # ----------------------------------------------------------------------
  # Copy chat.* -> chat_v2.*
  # ----------------------------------------------------------------------

  @doc """
  Copies all `chat.*` business tables into `chat_v2.*`.

  Runs in a single transaction (same PG instance). Idempotent: each target
  table is TRUNCATEd and re-populated, so re-running after source changes
  converges to the current source state.

  Options:

    * `:strict` — fail (instead of warn) when unapplied archive records
      exist (`chat.archive_records.applied_at IS NULL`).

  Returns `{:ok, report}` or `{:error, reason}`.
  """
  def copy(opts \\ []) do
    strict? = Keyword.get(opts, :strict, false)

    with :ok <- source_tables_present(), :ok <- check_archive_lag(strict?) do
      do_copy()
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_copy do
    case Repo.transaction(fn ->
           for spec <- tables() do
             Repo.query!("TRUNCATE #{@target_schema}.#{spec.name}")
             copy_table!(spec)
           end
         end) do
      {:ok, counts} ->
        tables = Map.new(counts)

        report = %{
          tables: tables,
          total_rows: tables |> Map.values() |> Enum.sum(),
          derived_columns: %{
            channel_members_status: "derived from left_at ('active' | 'left')",
            invites_channel_id: "NULL until upsert_invites/1 runs with the DO export",
            messages_event_id: "NULL until backfill_message_events/0 runs"
          }
        }

        Logger.info(
          "chat_v2 import: copied #{map_size(tables)} tables (#{report.total_rows} rows)"
        )

        {:ok, report}

      {:error, reason} ->
        {:error, Exception.message(reason)}
    end
  end

  defp source_tables_present do
    missing =
      for spec <- tables(),
          [] ==
            sql_rows(
              "SELECT table_name FROM information_schema.tables WHERE table_schema = 'chat' AND table_name = '" <>
                to_string(spec.name) <> "'"
            ) do
        spec.name
      end

    if missing == [] do
      :ok
    else
      {:error, "source tables missing in schema chat: #{Enum.join(missing, ", ")}"}
    end
  end

  defp check_archive_lag(strict?) do
    case sql_rows("SELECT to_regclass('chat.archive_records') IS NOT NULL") do
      [[false]] ->
        :ok

      [[true]] ->
        [[pending]] =
          sql_rows("SELECT COUNT(*) FROM chat.archive_records WHERE applied_at IS NULL")

        [[max_received]] = sql_rows("SELECT MAX(received_at) FROM chat.archive_records")

        if pending > 0 and strict? do
          {:error,
           "archive lag: #{pending} unapplied archive_records (latest received_at=#{inspect(max_received)}); drain the archive consumer before cutover"}
        else
          if pending > 0 do
            Logger.warning(
              "archive lag: #{pending} unapplied archive_records (latest received_at=#{inspect(max_received)}) — drain before cutover"
            )
          end

          :ok
        end
    end
  end

  defp copy_table!(spec) do
    columns = spec.columns
    # `derived` is written as a keyword list in the table specs.
    derived = Map.new(Map.get(spec, :derived, []))

    select_exprs =
      for col <- columns do
        case Map.fetch(derived, col) do
          {:ok, expr} -> expr
          :error -> quote_ident(col)
        end
      end

    sql =
      "INSERT INTO #{@target_schema}.#{spec.name} (#{Enum.map_join(columns, ", ", &quote_ident/1)}) " <>
        "SELECT #{Enum.join(select_exprs, ", ")} FROM #{@source_schema}.#{spec.name}"

    # INSERT...SELECT reports the copied row count in num_rows (rows is nil).
    %{num_rows: count} = Repo.query!(sql)
    {spec.name, count}
  end

  # ----------------------------------------------------------------------
  # Watermark verification (acceptance: "校验 watermark")
  # ----------------------------------------------------------------------

  @doc """
  Verifies that `chat_v2.*` matches the `chat.*` source:

  * per-table row counts must be equal;
  * MAX() of each monotonic watermark column must be equal.

  Also reports archive lag (`chat.archive_records` pending replay) when the
  table exists — informational, not a failure.

  Returns `{:ok, report}` (all checks passed) or `{:error, report}` with
  `report.failures` listing mismatches.
  """
  def verify do
    failures =
      for spec <- tables() do
        src_count = count!(@source_schema, spec.name)
        dst_count = count!(@target_schema, spec.name)

        watermark_failures =
          for col <- Map.get(spec, :watermarks, []) do
            # The source uses timestamptz (%DateTime{}), the target plain
            # timestamp (%NaiveDateTime{}, UTC by convention) — normalize both
            # to epoch microseconds before comparing.
            src_max = max_of!(@source_schema, spec.name, col) |> normalize_ts()
            dst_max = max_of!(@target_schema, spec.name, col) |> normalize_ts()

            if src_max == dst_max do
              nil
            else
              "MAX(#{col}) source=#{inspect(src_max)} target=#{inspect(dst_max)}"
            end
          end
          |> Enum.reject(&is_nil/1)

        count_failure =
          if src_count != dst_count do
            "row count source=#{src_count} target=#{dst_count}"
          else
            nil
          end

        parts = [count_failure | watermark_failures] |> Enum.reject(&is_nil/1)

        if parts == [] do
          nil
        else
          "#{spec.name}: " <> Enum.join(parts, "; ")
        end
      end
      |> Enum.reject(&is_nil/1)

    report = %{
      tables: table_counts(),
      failures: failures,
      archive_lag: archive_lag_report()
    }

    if failures == [] do
      {:ok, report}
    else
      {:error, report}
    end
  end

  defp table_counts do
    Map.new(tables(), fn spec ->
      {spec.name,
       %{
         source_count: count!(@source_schema, spec.name),
         target_count: count!(@target_schema, spec.name)
       }}
    end)
  end

  defp archive_lag_report do
    case sql_rows("SELECT to_regclass('chat.archive_records') IS NOT NULL") do
      [[false]] ->
        nil

      [[true]] ->
        [[pending]] =
          sql_rows("SELECT COUNT(*) FROM chat.archive_records WHERE applied_at IS NULL")

        [[max_received]] = sql_rows("SELECT MAX(received_at) FROM chat.archive_records")
        %{pending_records: pending, max_received_at: max_received}
    end
  end

  defp count!(schema, table) do
    [[n]] = sql_rows("SELECT COUNT(*) FROM #{quote_ident(schema)}.#{quote_ident(table)}")
    n
  end

  defp max_of!(schema, table, col) do
    [[v]] =
      sql_rows(
        "SELECT MAX(#{quote_ident(col)}) FROM #{quote_ident(schema)}.#{quote_ident(table)}"
      )

    v
  end

  # ----------------------------------------------------------------------
  # DO SQLite runtime state import (spec D4/D10/§8)
  # ----------------------------------------------------------------------

  @doc """
  Imports `read_state` rows exported from the old Worker's UserDirectory DOs
  (`my_channels.last_read_event_id`, via `/internal/debug/sql-all`).

  `rows` is a list of maps with string or atom keys:
  `%{user_id: ..., channel_id: ..., last_read_event_id: ...}`. Rows with an
  empty/nil `last_read_event_id` are skipped (the export query already
  filters them). The upsert keeps `last_read_event_id` monotonic per
  (user_id, channel_id): UUIDv7 strings compare lexicographically in time
  order, so a later snapshot wins on re-import.

  Returns `{:ok, %{imported: n, skipped: n}}`.
  """
  def import_read_state(rows) do
    {imported, skipped} =
      Enum.reduce(rows, {0, 0}, fn row, {imp, skip} ->
        user_id = row_value(row, :user_id)
        channel_id = row_value(row, :channel_id)
        last_read = row_value(row, :last_read_event_id)

        cond do
          is_nil(user_id) or is_nil(channel_id) or last_read in [nil, ""] ->
            {imp, skip + 1}

          true ->
            Repo.query!(
              """
              INSERT INTO chat_v2.read_state (user_id, channel_id, last_read_event_id, updated_at)
              VALUES ($1, $2, $3, now())
              ON CONFLICT (user_id, channel_id) DO UPDATE
              SET last_read_event_id = GREATEST(chat_v2.read_state.last_read_event_id, EXCLUDED.last_read_event_id),
                  updated_at = now()
              """,
              [user_id, channel_id, last_read]
            )

            {imp + 1, skip}
        end
      end)

    {:ok, %{imported: imported, skipped: skipped}}
  end

  @doc """
  Upserts invite rows exported from the per-ChatChannel DOs (which carry the
  authoritative `channel_id` mapping — the vanished `invite_index`
  projection). Rows present in both the archive copy and the DO export are
  updated to the DO state; DO-only invites are inserted.

  Each row map: invite_code, created_by, expires_at, max_uses, used_count,
  revoked_at, created_at (timestamps may be ISO-8601 strings) plus
  `channel_id`.

  Returns `{:ok, %{upserted: n}}`.
  """
  def upsert_invites(rows) do
    for row <- rows do
      Repo.query!(
        """
        INSERT INTO chat_v2.invites
          (invite_code, created_by, channel_id, expires_at, max_uses, used_count, revoked_at, created_at)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
        ON CONFLICT (invite_code) DO UPDATE SET
          created_by = EXCLUDED.created_by,
          channel_id = EXCLUDED.channel_id,
          expires_at = EXCLUDED.expires_at,
          max_uses   = EXCLUDED.max_uses,
          used_count = EXCLUDED.used_count,
          revoked_at = EXCLUDED.revoked_at,
          created_at = EXCLUDED.created_at
        """,
        [
          row_value(row, :invite_code),
          row_value(row, :created_by),
          row_value(row, :channel_id),
          bind_ts(row_value(row, :expires_at)),
          row_value(row, :max_uses),
          row_value(row, :used_count) || 0,
          bind_ts(row_value(row, :revoked_at)),
          bind_ts(row_value(row, :created_at))
        ]
      )
    end

    {:ok, %{upserted: length(rows)}}
  end

  @doc """
  Counts `chat_v2.invites` rows still lacking a `channel_id` mapping
  (invites present in the archive but not covered by the DO export).
  """
  def invites_unmapped_count do
    [[n]] = sql_rows("SELECT COUNT(*) FROM chat_v2.invites WHERE channel_id IS NULL")
    n
  end

  @doc """
  Backfills `chat_v2.messages.event_id` from the `message.created` events
  (event payload carries `payload.message.message_id`). Idempotent: only
  rows with NULL event_id are updated.

  Returns `{:ok, %{backfilled: n, unmatched: n}}`.
  """
  def backfill_message_events do
    # UPDATE reports the affected row count in num_rows.
    %{num_rows: updated} =
      Repo.query!("""
      UPDATE chat_v2.messages m
      SET event_id = e.event_id
      FROM chat_v2.events e
      WHERE m.channel_id = e.channel_id
        AND e.event_type = 'message.created'
        AND e.payload->'message'->>'message_id' = m.message_id
        AND m.event_id IS NULL
      """)

    [[unmatched]] = sql_rows("SELECT COUNT(*) FROM chat_v2.messages WHERE event_id IS NULL")
    {:ok, %{backfilled: updated, unmatched: unmatched}}
  end

  # ----------------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------------

  defp row_value(row, key) when is_map(row) do
    Map.get(row, key) || Map.get(row, to_string(key))
  end

  # DO exports carry timestamps as ISO-8601 strings; Postgrex needs %DateTime{}.
  defp bind_ts(nil), do: nil
  defp bind_ts(%DateTime{} = dt), do: dt

  defp bind_ts(value) when is_binary(value) do
    # from_iso8601/1 returns {:ok, datetime} or — in this Elixir build —
    # {:ok, datetime, utc_offset}; the %DateTime{} is always element 1.
    case DateTime.from_iso8601(value) do
      result when is_tuple(result) and elem(result, 0) == :ok -> elem(result, 1)
      _ -> value
    end
  end

  # Compares timestamptz (%DateTime{}) and plain timestamp (%NaiveDateTime{},
  # UTC by convention) values on a common scale: epoch microseconds.
  defp normalize_ts(%DateTime{} = dt), do: DateTime.to_unix(dt, :microsecond)

  defp normalize_ts(%NaiveDateTime{} = ndt) do
    ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:microsecond)
  end

  defp normalize_ts(value), do: value

  defp quote_ident(name) do
    "\"" <> String.replace(to_string(name), "\"", "\"\"") <> "\""
  end

  # Runs a parameterless query and returns the rows list (raises on error).
  # Ecto.Repo.query!/1 returns a bare %Postgrex.Result{}.
  defp sql_rows(sql) do
    %{rows: rows} = Repo.query!(sql)
    rows
  end
end
