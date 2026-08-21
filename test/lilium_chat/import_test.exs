defmodule LiliumChat.ImportTest do
  @moduledoc """
  Import tool behavior (issue #4): copy chat.* -> chat_v2.*, watermark
  verification, idempotency, read_state monotonic upsert, invite channel_id
  backfill, message event_id backfill.

  Fixtures: the `chat` schema is created per test with one TEXT column per
  mapped source column (PG assignment-casts on INSERT...SELECT), then
  dropped on exit.
  """
  use LiliumChat.DataCase, async: false

  alias LiliumChat.{Import, Repo}

  @ts1 "2026-08-01T10:00:00Z"
  @ts2 "2026-08-02T10:00:00Z"

  setup do
    create_chat_fixtures!()
    on_exit(fn -> Repo.query!("DROP SCHEMA IF EXISTS chat CASCADE") end)
    :ok
  end

  # ----------------------------------------------------------------------
  # copy
  # ----------------------------------------------------------------------

  test "copy copies all tables with correct row counts" do
    assert {:ok, report} = Import.copy()

    expected = %{
      channels: 2,
      channel_members: 2,
      messages: 2,
      events: 3,
      invites: 2,
      dm_pairs: 1,
      bot_apps: 1,
      personal_stickers: 1,
      audit_logs: 1,
      attachments: 1,
      message_edits: 1,
      message_attachments: 1,
      message_stickers: 1,
      mentions: 1,
      channel_pins: 1,
      command_invocations: 1,
      interactions: 1,
      stateful_command_sessions: 1,
      stateful_session_inputs: 1,
      bot_tokens: 1,
      bot_commands: 1,
      bot_command_aliases: 1,
      bot_command_names: 1,
      channel_command_bindings: 1
    }

    assert report.tables == expected
    assert report.total_rows == Enum.sum(Map.values(expected))
  end

  test "copy derives channel_members.status from left_at" do
    assert {:ok, _} = Import.copy()

    %{rows: rows} =
      Repo.query!("SELECT user_id, status FROM chat_v2.channel_members ORDER BY user_id")

    assert rows == [["u1", "active"], ["u2", "left"]]
  end

  test "copy leaves invites.channel_id and messages.event_id NULL until backfill" do
    assert {:ok, _} = Import.copy()

    assert [[0]] = sql_rows("SELECT COUNT(*) FROM chat_v2.invites WHERE channel_id IS NOT NULL")
    assert [[0]] = sql_rows("SELECT COUNT(*) FROM chat_v2.messages WHERE event_id IS NOT NULL")
  end

  test "copy is idempotent (re-run converges, no duplicates)" do
    assert {:ok, report1} = Import.copy()
    assert {:ok, report2} = Import.copy()

    assert report2.tables == report1.tables
  end

  test "copy fails with a clear error when source tables are missing" do
    Repo.query!("DROP TABLE chat.bot_apps")

    assert {:error, reason} = Import.copy()
    assert reason =~ "source tables missing"
    assert reason =~ "bot_apps"
  end

  # ----------------------------------------------------------------------
  # verify (watermark verification)
  # ----------------------------------------------------------------------

  test "verify passes after a clean copy" do
    assert {:ok, _} = Import.copy()
    assert {:ok, report} = Import.verify()
    assert report.failures == []
    assert report.tables[:messages] == %{source_count: 2, target_count: 2}
  end

  test "verify detects row count mismatch" do
    assert {:ok, _} = Import.copy()
    Repo.query!("DELETE FROM chat_v2.messages WHERE message_id = 'm1'")

    assert {:error, report} = Import.verify()
    assert Enum.any?(report.failures, &(&1 =~ "messages"))
  end

  test "verify detects watermark (MAX) drift" do
    assert {:ok, _} = Import.copy()
    # Drift the newest message timestamp backwards in the target only.
    Repo.query!(
      "UPDATE chat_v2.messages SET created_at = '2026-07-01T00:00:00Z' WHERE message_id = 'm2'"
    )

    assert {:error, report} = Import.verify()
    assert Enum.any?(report.failures, &(&1 =~ "MAX(created_at)"))
  end

  test "verify reports archive lag when archive_records has pending rows" do
    Repo.query!(
      "CREATE TABLE chat.archive_records (archive_id TEXT, applied_at TIMESTAMPTZ, received_at TIMESTAMPTZ)"
    )

    Repo.query!("INSERT INTO chat.archive_records VALUES ('a1', NULL, '2026-08-03T00:00:00Z')")
    assert {:ok, _} = Import.copy()

    assert {:ok, report} = Import.verify()

    assert report.archive_lag.pending_records == 1

    assert report.archive_lag.max_received_at |> DateTime.to_unix() ==
             ~U[2026-08-03 00:00:00Z] |> DateTime.to_unix()
  end

  test "copy --strict fails on unapplied archive records" do
    Repo.query!(
      "CREATE TABLE chat.archive_records (archive_id TEXT, applied_at TIMESTAMPTZ, received_at TIMESTAMPTZ)"
    )

    Repo.query!("INSERT INTO chat.archive_records VALUES ('a1', NULL, '2026-08-03T00:00:00Z')")

    assert {:error, reason} = Import.copy(strict: true)
    assert reason =~ "archive lag"
  end

  # ----------------------------------------------------------------------
  # read_state (DO SQLite export import, spec D12 / §8)
  # ----------------------------------------------------------------------

  test "import_read_state upserts and keeps last_read_event_id monotonic" do
    old = "019f0000-0000-7000-8000-000000000001"
    newer = "019f0000-0000-7000-8000-000000000002"

    assert {:ok, %{imported: 1}} =
             Import.import_read_state([
               %{user_id: "u1", channel_id: "ch_active", last_read_event_id: old}
             ])

    # A later snapshot advances the cursor…
    assert {:ok, %{imported: 1}} =
             Import.import_read_state([
               %{user_id: "u1", channel_id: "ch_active", last_read_event_id: newer}
             ])

    # …but re-importing the older one must not move it backwards.
    assert {:ok, _} =
             Import.import_read_state([
               %{user_id: "u1", channel_id: "ch_active", last_read_event_id: old}
             ])

    assert [[^newer]] =
             sql_rows("SELECT last_read_event_id FROM chat_v2.read_state WHERE user_id = 'u1'")
  end

  test "import_read_state skips rows without a cursor" do
    assert {:ok, %{imported: 1, skipped: 1}} =
             Import.import_read_state([
               %{user_id: "u1", channel_id: "ch_active", last_read_event_id: nil},
               %{
                 user_id: "u2",
                 channel_id: "ch_active",
                 last_read_event_id: "019f0000-0000-7000-8000-000000000003"
               }
             ])

    assert [[1]] = sql_rows("SELECT COUNT(*) FROM chat_v2.read_state")
  end

  # ----------------------------------------------------------------------
  # invites (invite_index replacement, spec §3.2/§8)
  # ----------------------------------------------------------------------

  test "upsert_invites sets channel_id and reports unmapped" do
    assert {:ok, _} = Import.copy()

    # Both seeded invites lack a channel mapping until the DO export is applied.
    assert 2 = Import.invites_unmapped_count()

    assert {:ok, %{upserted: 2}} =
             Import.upsert_invites([
               %{
                 invite_code: "inv1",
                 created_by: "u1",
                 channel_id: "ch_dissolved",
                 expires_at: nil,
                 max_uses: nil,
                 used_count: 0,
                 revoked_at: nil,
                 created_at: @ts1
               },
               %{
                 invite_code: "inv2",
                 created_by: "u1",
                 channel_id: "ch_active",
                 expires_at: @ts2,
                 max_uses: nil,
                 used_count: 0,
                 revoked_at: nil,
                 created_at: @ts1
               }
             ])

    assert 0 = Import.invites_unmapped_count()

    assert [["ch_active"]] =
             sql_rows("SELECT channel_id FROM chat_v2.invites WHERE invite_code = 'inv2'")
  end

  test "upsert_invites inserts DO-only invites" do
    assert {:ok, _} = Import.copy()

    assert {:ok, %{upserted: 1}} =
             Import.upsert_invites([
               %{
                 invite_code: "inv3",
                 created_by: "u2",
                 channel_id: "ch_dissolved",
                 expires_at: nil,
                 max_uses: 5,
                 used_count: 0,
                 revoked_at: nil,
                 created_at: @ts1
               }
             ])

    assert [[3]] = sql_rows("SELECT COUNT(*) FROM chat_v2.invites")
  end

  # ----------------------------------------------------------------------
  # message event_id backfill (spec §3.4 timeline index)
  # ----------------------------------------------------------------------

  test "backfill_message_events links messages to their message.created events" do
    assert {:ok, _} = Import.copy()

    assert {:ok, %{backfilled: 2, unmatched: 0}} = Import.backfill_message_events()

    assert [["e1"], ["e2"]] =
             sql_rows("SELECT event_id FROM chat_v2.messages ORDER BY message_id")

    # Idempotent second run.
    assert {:ok, %{backfilled: 0, unmatched: 0}} = Import.backfill_message_events()
  end

  test "backfill_message_events reports unmatched messages" do
    Repo.query!(
      "INSERT INTO chat.messages (message_id, command_id, dedupe_principal_key, channel_id, sender_kind, type, format, status, stream_state, created_at, updated_at) VALUES ('m3', 'c3', 'u1', 'ch_active', 'user', 'text', 'plain', 'normal', '{}', '2026-08-03T00:00:00Z', '2026-08-03T00:00:00Z')"
    )

    assert {:ok, _} = Import.copy()
    assert {:ok, %{backfilled: 2, unmatched: 1}} = Import.backfill_message_events()
  end

  # ----------------------------------------------------------------------
  # helpers
  # ----------------------------------------------------------------------

  defp sql_rows(sql) do
    %{rows: rows} = Repo.query!(sql)
    rows
  end

  defp create_chat_fixtures! do
    Repo.query!("CREATE SCHEMA IF NOT EXISTS chat")

    # Create each source fixture with the SAME column types as the chat_v2
    # target (introspected from pg_attribute), so INSERT...SELECT type-checks
    # exactly as it will in production. This also cross-checks that every
    # mapped column exists in the target table.
    for spec <- Import.tables() do
      %{rows: rows} =
        Repo.query!(
          """
          SELECT a.attname AS col, format_type(a.atttypid, a.atttypmod) AS coltype
          FROM pg_attribute a
          JOIN pg_class c ON c.oid = a.attrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE n.nspname = 'chat_v2' AND c.relname = $1
            AND a.attnum > 0 AND NOT a.attisdropped
          ORDER BY a.attnum
          """,
          [to_string(spec.name)]
        )

      coldefs = for [col, type] <- rows, do: "\"#{col}\" #{type}"
      Repo.query!("DROP TABLE IF EXISTS chat.#{spec.name}")
      Repo.query!("CREATE TABLE chat.#{spec.name} (#{Enum.join(coldefs, ", ")})")
    end

    seed([
      """
      INSERT INTO chat.channels (channel_id, kind, visibility, title, status, created_by, created_at, updated_at, member_count, membership_version)
      VALUES ('ch_active', 'channel', 'private', 'Active', 'active', 'u1', '#{@ts1}', '#{@ts2}', 1, 1)
      """,
      """
      INSERT INTO chat.channels (channel_id, kind, visibility, title, status, created_by, created_at, updated_at, member_count, membership_version)
      VALUES ('ch_dissolved', 'dm', 'private', 'Dissolved', 'dissolved', 'u1', '#{@ts1}', '#{@ts2}', 0, 0)
      """,
      """
      INSERT INTO chat.channel_members (channel_id, user_id, role, joined_at)
      VALUES ('ch_active', 'u1', 'admin', '#{@ts1}')
      """,
      """
      INSERT INTO chat.channel_members (channel_id, user_id, role, joined_at, left_at)
      VALUES ('ch_active', 'u2', 'member', '#{@ts1}', '#{@ts2}')
      """,
      """
      INSERT INTO chat.messages (message_id, command_id, dedupe_principal_key, channel_id, sender_kind, type, format, status, text, stream_state, created_at, updated_at)
      VALUES ('m1', 'c1', 'u1', 'ch_active', 'user', 'text', 'plain', 'normal', 'hello', '{}', '#{@ts1}', '#{@ts1}')
      """,
      """
      INSERT INTO chat.messages (message_id, command_id, dedupe_principal_key, channel_id, sender_kind, type, format, status, text, stream_state, created_at, updated_at)
      VALUES ('m2', 'c2', 'u1', 'ch_active', 'user', 'text', 'plain', 'normal', 'world', '{}', '#{@ts2}', '#{@ts2}')
      """,
      """
      INSERT INTO chat.events (event_id, event_type, channel_id, actor_kind, actor_id, payload, membership_version_at_event, occurred_at)
      VALUES ('e1', 'message.created', 'ch_active', 'user', 'u1', '{"message":{"message_id":"m1"}}', 1, '#{@ts1}')
      """,
      """
      INSERT INTO chat.events (event_id, event_type, channel_id, actor_kind, actor_id, payload, membership_version_at_event, occurred_at)
      VALUES ('e2', 'message.created', 'ch_active', 'user', 'u1', '{"message":{"message_id":"m2"}}', 1, '#{@ts2}')
      """,
      """
      INSERT INTO chat.events (event_id, event_type, channel_id, actor_kind, actor_id, payload, membership_version_at_event, occurred_at)
      VALUES ('e3', 'channel.updated', 'ch_active', 'user', 'u1', '{"title":"x"}', 1, '#{@ts2}')
      """,
      """
      INSERT INTO chat.invites (invite_code, created_by, used_count, created_at)
      VALUES ('inv1', 'u1', 0, '#{@ts1}')
      """,
      """
      INSERT INTO chat.invites (invite_code, created_by, used_count, created_at)
      VALUES ('inv2', 'u1', 0, '#{@ts1}')
      """,
      """
      INSERT INTO chat.dm_pairs (pair_key, user_low, user_high, channel_id, created_by, status, created_at, updated_at)
      VALUES ('p1', 'u1', 'u2', 'ch_dissolved', 'u1', 'active', '#{@ts1}', '#{@ts1}')
      """,
      """
      INSERT INTO chat.personal_stickers (sticker_id, user_id, attachment_id, url, mime_type, size_bytes, created_at)
      VALUES ('st1', 'u1', 'att1', 'https://x/st1.png', 'image/png', 100, '#{@ts1}')
      """,
      """
      INSERT INTO chat.audit_logs (audit_id, actor_kind, actor_id, action, target_type, target_id, created_at)
      VALUES ('al1', 'user', 'u1', 'channel.create', 'channel', 'ch_active', '#{@ts1}')
      """,
      """
      INSERT INTO chat.attachments (attachment_id, owner_user_id, kind, mime_type, size_bytes, storage_key, url, status, created_at)
      VALUES ('att1', 'u1', 'image', 'image/png', 100, 'k1', 'https://x/att1', 'final', '#{@ts1}')
      """,
      """
      INSERT INTO chat.message_edits (edit_id, message_id, old_text, new_text, editor_user_id, edited_at)
      VALUES ('ed1', 'm1', 'old', 'new', 'u1', '#{@ts2}')
      """,
      """
      INSERT INTO chat.message_attachments (message_id, attachment_id)
      VALUES ('m1', 'att1')
      """,
      """
      INSERT INTO chat.message_stickers (message_id, sticker_id, attachment_id, url, mime_type, size_bytes)
      VALUES ('m1', 'st1', 'att1', 'https://x/st1.png', 'image/png', 100)
      """,
      """
      INSERT INTO chat.mentions (message_id, user_id, start_index, end_index)
      VALUES ('m1', 'u2', 0, 2)
      """,
      """
      INSERT INTO chat.channel_pins (pin_id, channel_id, pin_kind, pin_owner_kind, pin_owner_id, priority, last_pin_event_id, message_projection_json, created_at, updated_at)
      VALUES ('pin1', 'ch_active', 'message', 'user', 'u1', 0, 'e2', '{"m":true}', '#{@ts1}', '#{@ts1}')
      """,
      """
      INSERT INTO chat.command_invocations (invocation_id, channel_id, command_id, invoker_user_id, bot_id, bot_command_id, command_name, invoked_name, command_schema_version, status, created_at, updated_at)
      VALUES ('ci1', 'ch_active', 'cmd1', 'u1', 'bot1', 'bc1', 'help', '/help', 1, 'completed', '#{@ts1}', '#{@ts1}')
      """,
      """
      INSERT INTO chat.interactions (interaction_id, message_id, component_id, custom_id, actor_user_id, dedupe_principal_key, command_id, status, created_at, updated_at)
      VALUES ('ix1', 'm1', 'cmp1', 'cust1', 'u1', 'u1', 'cmd1', 'completed', '#{@ts1}', '#{@ts1}')
      """,
      """
      INSERT INTO chat.stateful_command_sessions (session_id, channel_id, bot_id, bot_command_id, invocation_id, started_by_user_id, status, listen_rules_json, input_next_seq, input_last_acked_seq, effect_last_acked_seq, started_at, expires_at)
      VALUES ('ss1', 'ch_active', 'bot1', 'bc1', 'ci1', 'u1', 'active', '{"rules":[]}', 1, 0, 0, '#{@ts1}', '#{@ts2}')
      """,
      """
      INSERT INTO chat.stateful_session_inputs (session_id, seq, channel_id, event_id, message_id, message_projection_json, status, created_at)
      VALUES ('ss1', 1, 'ch_active', 'e2', 'm2', '{"m":true}', 'acked', '#{@ts1}')
      """,
      """
      INSERT INTO chat.bot_apps (bot_id, owner_user_id, display_name, status, visibility, created_at, updated_at)
      VALUES ('bot1', 'u1', 'Helper Bot', 'active', 'private', '#{@ts1}', '#{@ts1}')
      """,
      """
      INSERT INTO chat.bot_tokens (token_id, bot_id, token_hash, scopes, name, created_at)
      VALUES ('bt1', 'bot1', 'hash1', 'chat:send', 'default', '#{@ts1}')
      """,
      """
      INSERT INTO chat.bot_commands (bot_command_id, bot_id, name, schema_version, execution_mode, status, help_text, created_at, updated_at)
      VALUES ('bc1', 'bot1', 'help', 1, 'stateless', 'active', 'help text', '#{@ts1}', '#{@ts1}')
      """,
      """
      INSERT INTO chat.bot_command_aliases (bot_command_id, bot_id, alias, created_at)
      VALUES ('bc1', 'bot1', 'h', '#{@ts1}')
      """,
      """
      INSERT INTO chat.bot_command_names (slash_token, bot_command_id, bot_id, kind, created_at)
      VALUES ('/help', 'bc1', 'bot1', 'command', '#{@ts1}')
      """,
      """
      INSERT INTO chat.channel_command_bindings (channel_id, bot_command_id, bot_id, status, command_snapshot_json, updated_by_user_id, updated_at)
      VALUES ('ch_active', 'bc1', 'bot1', 'enabled', '{"name":"help"}', 'u1', '#{@ts1}')
      """
    ])
  end

  defp seed(statements) do
    for sql <- statements, do: Repo.query!(sql)
  end
end
