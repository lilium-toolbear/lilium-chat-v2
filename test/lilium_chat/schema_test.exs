defmodule LiliumChat.SchemaTest do
  @moduledoc """
  Storage baseline conformance (issue #4, spec §3.2/§3.4):

  * all 27 `chat_v2` tables exist (18 core + 6 bot + 3 new runtime);
  * the vanished-table list (§3.2) is NOT created;
  * hot-read indexes per §3.4 exist with the right shape.
  """
  use LiliumChat.DataCase, async: false

  alias LiliumChat.Repo

  @expected_tables ~w(
    channels channel_members messages message_edits events attachments
    message_attachments message_stickers mentions invites dm_pairs
    personal_stickers audit_logs channel_pins command_invocations interactions
    stateful_command_sessions stateful_session_inputs
    bot_apps bot_tokens bot_commands bot_command_aliases bot_command_names
    channel_command_bindings
    read_state idempotency bot_deliveries
  )a

  # Spec §3.2 "消失表" — must NOT exist in chat_v2.
  @vanished_tables ~w(
    my_channels rate_buckets idempotency_keys bot_effects_applied
    stateful_session_effects_applied projection_outbox archive_outbox
    bot_delivery_outbox fanout_queue fanout_leases fanout_events online_sessions
    live_sessions live_user_channel_leases alarm_jobs archive_seq event_seq
    bot_connection_state active_stateful_session_refs stream_state
    stream_due_jobs message_stream_registry bot_idempotency_keys
    pending_attachments public_channels invite_index
  )a

  defp table_names do
    %{rows: rows} =
      Repo.query!(
        "SELECT table_name FROM information_schema.tables WHERE table_schema = 'chat_v2'"
      )

    rows |> List.flatten() |> MapSet.new()
  end

  test "all 27 chat_v2 business tables exist" do
    names = table_names()
    expected = @expected_tables |> Enum.map(&to_string/1)
    missing = expected -- MapSet.to_list(names)
    assert missing == [], "missing tables: #{Enum.join(missing, ", ")}"
  end

  test "vanished tables are not created (spec §3.2)" do
    names = table_names() |> MapSet.new()
    present = @vanished_tables |> MapSet.new() |> MapSet.intersection(names) |> MapSet.to_list()
    assert present == [], "vanished tables unexpectedly present: #{Enum.join(present, ", ")}"
  end

  test "hot-read indexes exist per spec §3.4" do
    sql =
      """
      SELECT indexname FROM pg_indexes
      WHERE schemaname = 'chat_v2' AND indexname IN (
        'idx_chat_v2_cm_user_status',
        'idx_chat_v2_cm_channel_status',
        'idx_chat_v2_messages_channel_event',
        'idx_chat_v2_events_channel_event',
        'uniq_chat_v2_idem_user_command',
        'uniq_chat_v2_idem_bot_effect',
        'uniq_chat_v2_idem_session_effect',
        'idx_chat_v2_idem_expires',
        'idx_chat_v2_bot_deliveries_bot_status'
      )
      """

    %{rows: rows} = Repo.query!(sql)
    assert length(rows) == 9, "expected all 9 §3.4 indexes, got: #{inspect(rows)}"
  end

  test "messages timeline index is (channel_id, event_id DESC)" do
    sql =
      "SELECT indexdef FROM pg_indexes WHERE schemaname = 'chat_v2' AND indexname = 'idx_chat_v2_messages_channel_event'"

    %{rows: [[indexdef]]} = Repo.query!(sql)
    assert indexdef =~ "channel_id"
    assert indexdef =~ "event_id DESC"
  end

  test "read_state PK is (user_id, channel_id)" do
    sql =
      "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE connamespace = 'chat_v2'::regnamespace AND conrelid = 'chat_v2.read_state'::regclass AND contype = 'p'"

    %{rows: [[pkdef]]} = Repo.query!(sql)
    assert pkdef =~ "user_id"
    assert pkdef =~ "channel_id"
  end

  test "idempotency has namespace check constraint + per-namespace unique keys" do
    sql =
      "SELECT conname FROM pg_constraint WHERE connamespace = 'chat_v2'::regnamespace AND conrelid = 'chat_v2.idempotency'::regclass AND contype = 'c'"

    %{rows: rows} = Repo.query!(sql)
    assert Enum.any?(rows, fn [name] -> name == "chk_chat_v2_idem_namespace" end)
  end

  test "channel_members has the v2 status column (SoT membership)" do
    sql =
      "SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'chat_v2' AND table_name = 'channel_members' AND column_name = 'status' AND is_nullable = 'NO')"

    %{rows: [[true]]} = Repo.query!(sql)
  end

  test "invites has the v2 channel_id column (replaces invite_index)" do
    sql =
      "SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'chat_v2' AND table_name = 'invites' AND column_name = 'channel_id')"

    %{rows: [[true]]} = Repo.query!(sql)
  end

  test "messages has the v2 event_id column (timeline cursor)" do
    sql =
      "SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'chat_v2' AND table_name = 'messages' AND column_name = 'event_id')"

    %{rows: [[true]]} = Repo.query!(sql)
  end
end
