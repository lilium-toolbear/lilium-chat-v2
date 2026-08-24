defmodule LiliumChat.HousekeepingTest do
  @moduledoc """
  Housekeeping GC tests (spec §2.2 / issue #21).

  The periodic timer is disabled under test (`config/test.exs`); each test
  drives the sweep functions directly inside its own sandbox so the SQL
  runs on the test connection. TTLs are shrunk per-test so rows written
  "now" are already stale.
  """

  use LiliumChat.DataCase, async: false

  alias LiliumChat.{Housekeeping, Query, Repo}

  setup do
    Application.put_env(:lilium_chat, :housekeeping,
      enabled: false,
      pending_attachment_ttl_ms: 1,
      stream_ttl_ms: 1,
      delivery_retention_ms: 1,
      sweep_batch: 2
    )

    on_exit(fn ->
      Application.put_env(:lilium_chat, :housekeeping, enabled: false)
    end)

    :ok
  end

  describe "gc_idempotency/0" do
    test "deletes expired rows, keeps live and never-expiring rows, batches" do
      expired_id = insert_idem!(hours_ago(2))
      live_id = insert_idem!(hours_from_now(2))
      never_id = insert_idem!(nil)

      assert Housekeeping.gc_idempotency() == 1

      assert idem_count(expired_id) == 0
      assert idem_count(live_id) == 1
      assert idem_count(never_id) == 1
    end

    test "deletes more than one batch when the batch size is exceeded" do
      # sweep_batch is 2 — three expired rows need two delete passes.
      for _ <- 1..3, do: insert_idem!(hours_ago(2))

      assert Housekeeping.gc_idempotency() == 3
    end
  end

  describe "expire_pending_attachments/0" do
    test "deletes stale pending rows, keeps fresh pending and finalized rows" do
      stale = insert_attachment!("pending", hours_ago(2))
      fresh = insert_attachment!("pending", DateTime.utc_now())
      finalized = insert_attachment!("finalized", hours_ago(2))

      assert Housekeeping.expire_pending_attachments() == 1

      assert attachment_count(stale) == 0
      assert attachment_count(fresh) == 1
      assert attachment_count(finalized) == 1
    end
  end

  describe "expire_streams/0" do
    test "empty stale stream row: deleted, no canonical write (live-only branch)" do
      stale = insert_streaming_message!("ch-stale", "msg-stale", hours_ago(2))

      assert Housekeeping.expire_streams() == 1

      # Contract §9.15.5 empty branch: the stale projection row is removed
      # and a live-only cleanup frame is broadcast — nothing canonical is
      # written (no history row, no event).
      assert stream_count(stale.channel_id, stale.message_id) == 0
      assert event_count(stale.channel_id) == 0
    end

    test "non-empty stale stream row: canonical abandon via the channel writer" do
      insert_channel!("ch-abandon")

      stale =
        insert_streaming_message!(
          "ch-abandon",
          "msg-abandon",
          hours_ago(2),
          "streaming",
          "partial text",
          "bot-abandon"
        )

      assert Housekeeping.expire_streams() == 1

      # The stale projection row is replaced by the canonical abandoned row…
      row = stream_row(stale.channel_id, stale.message_id)
      assert row["stream_state"] == "abandoned"
      assert row["status"] == "failed"
      assert row["text"] == "partial text"

      # …and the `message.stream_abandoned` event is on the channel.
      assert event_type(stale.channel_id) == "message.stream_abandoned"
    end

    test "does not touch a row with a live stream process" do
      {:ok, _} =
        Registry.register(LiliumChat.Streams.Registry, {"ch-live", "msg-live"}, nil)

      insert_streaming_message!("ch-live", "msg-live", hours_ago(2))

      assert Housekeeping.expire_streams() == 0

      row = stream_row("ch-live", "msg-live")
      assert row["stream_state"] == "streaming"
    end

    test "does not touch fresh rows" do
      # Future `updated_at` — the 1ms test TTL would otherwise race with
      # the sweep's `now()`.
      insert_streaming_message!("ch-fresh", "msg-fresh", hours_from_now(1))

      assert Housekeeping.expire_streams() == 0

      row = stream_row("ch-fresh", "msg-fresh")
      assert row["stream_state"] == "streaming"
    end

    test "is a no-op when no non-terminal rows exist" do
      insert_streaming_message!("ch-final", "msg-final", hours_ago(2), "final")

      assert Housekeeping.expire_streams() == 0
    end
  end

  describe "cleanup_bot_deliveries/0" do
    test "deletes terminal rows past retention, keeps pending and fresh rows" do
      delivered = insert_delivery!("delivered", hours_ago(2))
      dropped = insert_delivery!("dropped", hours_ago(2))
      pending = insert_delivery!("pending", hours_ago(2))
      fresh = insert_delivery!("delivered", DateTime.utc_now())

      assert Housekeeping.cleanup_bot_deliveries() == 2

      assert delivery_count(delivered) == 0
      assert delivery_count(dropped) == 0
      # Pending rows are the crash-recovery queue — always kept.
      assert delivery_count(pending) == 1
      assert delivery_count(fresh) == 1
    end
  end

  describe "run_now/0" do
    test "returns a per-task summary" do
      insert_idem!(hours_ago(2))
      insert_delivery!("delivered", hours_ago(2))

      assert Housekeeping.run_now() == %{
               idempotency: 1,
               pending_attachments: 0,
               streams: 0,
               bot_deliveries: 1
             }
    end
  end

  # ---------------------------------------------------------------- fixtures

  defp insert_idem!(expires_at) do
    id = LiliumChat.Ids.uuid_bytes(LiliumChat.Ids.uuidv7())

    now = DateTime.utc_now()

    Repo.query!(
      """
      INSERT INTO chat_v2.idempotency
        (id, namespace, principal_kind, principal_id, operation, operation_id,
         request_hash, status, created_at, updated_at, expires_at)
      VALUES ($1, 'user_command', 'user', $2, 'op', $3, 'hash', 'completed', $4, $4, $5)
      """,
      [id, "p-" <> LiliumChat.Ids.uuidv7(), LiliumChat.Ids.uuidv7(), now, expires_at],
      type: true
    )

    id
  end

  defp idem_count(id) do
    rows =
      Query.rows(
        Repo.query("SELECT count(*) AS n FROM chat_v2.idempotency WHERE id = $1", [id],
          type: true
        )
      )

    rows |> List.first() |> Map.get("n")
  end

  defp insert_attachment!(status, created_at) do
    attachment_id = "att-" <> LiliumChat.Ids.uuidv7()

    Repo.query!(
      """
      INSERT INTO chat_v2.attachments
        (attachment_id, owner_user_id, kind, mime_type, size_bytes, storage_key,
         url, status, created_at)
      VALUES ($1, $2, 'image', 'image/png', 100, $3, $4, $5, $6)
      """,
      [
        attachment_id,
        "user-1",
        "chat/#{attachment_id}",
        "https://s3.example/#{attachment_id}",
        status,
        created_at
      ],
      type: true
    )

    attachment_id
  end

  defp attachment_count(attachment_id) do
    rows =
      Query.rows(
        Repo.query(
          "SELECT count(*) AS n FROM chat_v2.attachments WHERE attachment_id = $1",
          [attachment_id],
          type: true
        )
      )

    rows |> List.first() |> Map.get("n")
  end

  defp insert_streaming_message!(
         channel_id,
         message_id,
         updated_at,
         stream_state \\ "streaming",
         text \\ "",
         bot_id \\ nil
       ) do
    now = DateTime.utc_now()

    Repo.query!(
      """
      INSERT INTO chat_v2.messages
        (message_id, command_id, dedupe_principal_key, channel_id, sender_kind,
         sender_bot_id, type, format, status, text, stream_state, created_at, updated_at)
      VALUES ($1, $2, $3, $4, 'bot', $5, 'text', 'plain', 'normal', $6, $7, $8, $9)
      """,
      [
        message_id,
        "cmd-" <> LiliumChat.Ids.uuidv7(),
        "bot:test",
        channel_id,
        bot_id,
        text,
        stream_state,
        now,
        updated_at
      ],
      type: true
    )

    %{channel_id: channel_id, message_id: message_id}
  end

  defp insert_channel!(channel_id) do
    now = DateTime.utc_now()

    Repo.query!(
      """
      INSERT INTO chat_v2.channels
        (channel_id, kind, visibility, title, status, created_by, created_at, updated_at)
      VALUES ($1, 'group', 'private', 'test channel', 'active', 'user-1', $2, $2)
      """,
      [channel_id, now],
      type: true
    )

    channel_id
  end

  defp stream_row(channel_id, message_id) do
    rows =
      Query.rows(
        Repo.query(
          """
          SELECT stream_state, status, text FROM chat_v2.messages
          WHERE channel_id = $1 AND message_id = $2
          """,
          [channel_id, message_id],
          type: true
        )
      )

    List.first(rows)
  end

  defp stream_count(channel_id, message_id) do
    rows =
      Query.rows(
        Repo.query(
          "SELECT count(*) AS n FROM chat_v2.messages WHERE channel_id = $1 AND message_id = $2",
          [channel_id, message_id],
          type: true
        )
      )

    rows |> List.first() |> Map.get("n")
  end

  defp event_count(channel_id) do
    rows =
      Query.rows(
        Repo.query("SELECT count(*) AS n FROM chat_v2.events WHERE channel_id = $1", [channel_id],
          type: true
        )
      )

    rows |> List.first() |> Map.get("n")
  end

  defp event_type(channel_id) do
    rows =
      Query.rows(
        Repo.query(
          """
          SELECT event_type FROM chat_v2.events
          WHERE channel_id = $1 ORDER BY event_id DESC LIMIT 1
          """,
          [channel_id],
          type: true
        )
      )

    rows |> List.first() |> Map.get("event_type")
  end

  defp insert_delivery!(status, updated_at) do
    delivery_id = "del-" <> LiliumChat.Ids.uuidv7()
    now = DateTime.utc_now()

    Repo.query!(
      """
      INSERT INTO chat_v2.bot_deliveries
        (delivery_id, channel_id, bot_id, kind, request_json, status, attempts,
         max_attempts, created_at, updated_at, delivered_at)
      VALUES ($1, $2, $3, 'message_event', $4, $5, 0, 5, $6, $7, $8)
      """,
      [
        delivery_id,
        "ch-1",
        "bot-1",
        %{"event" => %{}},
        status,
        now,
        updated_at,
        if(status == "delivered", do: updated_at, else: nil)
      ],
      type: true
    )

    delivery_id
  end

  defp delivery_count(delivery_id) do
    rows =
      Query.rows(
        Repo.query(
          "SELECT count(*) AS n FROM chat_v2.bot_deliveries WHERE delivery_id = $1",
          [delivery_id],
          type: true
        )
      )

    rows |> List.first() |> Map.get("n")
  end

  defp hours_ago(n), do: DateTime.add(DateTime.utc_now(), -n * 3600, :second)
  defp hours_from_now(n), do: DateTime.add(DateTime.utc_now(), n * 3600, :second)
end
