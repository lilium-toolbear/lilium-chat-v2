defmodule LiliumChat.Housekeeping do
  @moduledoc """
  Periodic housekeeping GC (spec §2.2 process model, issue #21).

  Runs four sweep tasks on a configurable cadence:

    * `gc_idempotency/0` — delete `chat_v2.idempotency` rows whose
      `expires_at` has passed (spec D10: the 3 merged dedup namespaces all
      carry `expires_at`; the `idx_chat_v2_idem_expires` index serves the
      scan). Batched (`sweep_batch`) to bound each statement.
    * `expire_pending_attachments/0` — delete `chat_v2.attachments` rows
      stuck at `status = 'pending'` past the presign window (spec §6.2 /
      contract §8.1: the presigned PUT URL itself expires after
      `PRESIGN_TTL_SECONDS`). The default TTL is 2× the 5-min presign TTL
      so an in-flight finalize keeps its grace window. The SeaweedFS object
      itself is left alone (spec §10: 附件在 SeaweedFS 不变).
    * `expire_streams/0` — defensive sweep of `chat_v2.messages` rows stuck
      in a non-terminal `stream_state` past the stream TTL with no live
      `Stream.<cid>#<mid>` process, handled per contract §9.15.5's two
      abandon branches (empty `text` → live-only cleanup frame, no
      canonical write; non-empty `text` → canonical abandon through the
      per-channel writer). Live streams self-expire in-memory
      (`LiliumChat.Stream` arms an `:expire` timer and runs the full
      protocol), so this only catches crash orphans / imported rows that
      were never live-broadcast here.
    * `cleanup_bot_deliveries/0` — delete terminal `chat_v2.bot_deliveries`
      rows (`delivered` / `dropped`) past the retention window (spec D14).
      `pending` rows always survive — they are the crash-recovery queue.

  Config (`config :lilium_chat, :housekeeping`):

    * `enabled` (default `true`) — whether the periodic timer runs. Tests
      set `false` and drive `run_now/0` directly inside the sandbox.
    * `interval_ms` (default 60_000) — sweep cadence.
    * `sweep_batch` (default 500) — rows per delete/scan statement, all
      sweeps.
    * `pending_attachment_ttl_ms` (default 600_000).
    * `delivery_retention_ms` (default 60_000).
    * `stream_ttl_ms` (optional override) — the stream-expiry TTL. Not set
      in `config.exs`: `expire_streams/0` derives it from the live stream
      TTL (`:bot_stream` `ttl_seconds`) so the two cannot drift apart.

  Every sweep is idempotent and reports its row count; `run_now/0` returns
  a per-task summary for logs and tests.
  """

  use GenServer

  require Logger

  alias LiliumChat.{Channel, Observability, Query, Repo}
  alias LiliumChat.WebSockets.Frames

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    if enabled?(), do: schedule_next()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    if enabled?() do
      Logger.info("housekeeping sweep", summary: run_now())
      schedule_next()
    end

    {:noreply, state}
  end

  # ------------------------------------------------------------------ API

  @doc """
  Run one full sweep synchronously in the calling process (tests call this
  inside the sandbox; the GenServer timer path runs it in the housekeeping
  process). Returns `%{idempotency: n, pending_attachments: n, streams: n,
  bot_deliveries: n}` — rows deleted / handled per task.
  """
  def run_now do
    %{
      idempotency: gc_idempotency(),
      pending_attachments: expire_pending_attachments(),
      streams: expire_streams(),
      bot_deliveries: cleanup_bot_deliveries()
    }
  end

  @doc """
  Idempotency GC (spec D10 / §3.3.2): delete rows whose `expires_at` has
  passed. Returns the number of rows deleted.
  """
  def gc_idempotency do
    batch = cfg(:sweep_batch, 500)

    delete_batches(
      """
      DELETE FROM chat_v2.idempotency
      WHERE id IN (
        SELECT id FROM chat_v2.idempotency
        WHERE expires_at IS NOT NULL AND expires_at < now()
        LIMIT #{batch}
      )
      """,
      batch
    )
  end

  @doc """
  Pending-attachment expiry (spec §6.2 / contract §8.1): delete `pending`
  attachment rows older than the presign window + grace. Returns the number
  of rows deleted.
  """
  def expire_pending_attachments do
    cutoff = ago_ms(cfg(:pending_attachment_ttl_ms, 600_000))

    Repo.query!(
      """
      DELETE FROM chat_v2.attachments
      WHERE status = 'pending' AND created_at < $1
      """,
      [cutoff],
      type: true
    )
    |> num_rows()
  end

  @doc """
  Stream expiry (contract §9.15.5 semantics): sweep non-terminal
  `stream_state` message rows whose `updated_at` is past the TTL and which
  have no live `Stream.<cid>#<mid>` process, handling each row per the
  contract's two abandon branches:

    * **empty `text`** (or no sender bot) — the live-only
      `message.stream_abandon_cleanup` frame on `channel:<id>`; no
      canonical write.
    * **non-empty `text`** — the canonical abandon through the per-channel
      writer (`Channel.abandon_stream/2`): a fresh `messages` row with
      `stream_state = 'abandoned'` / `status = 'failed'` + the
      `message.stream_abandoned` event + the fanout frame.

  The stale projection row (imported in-flight stream, cutover #22) makes
  way for the canonical row in either case (`StreamWrite` INSERTs, it does
  not UPSERT). If the writer cannot commit (e.g. the channel is dissolved),
  the row is restored in a terminal state so nothing is silently lost.
  Returns the number of rows handled.
  """
  def expire_streams do
    batch = cfg(:sweep_batch, 500)
    cutoff = ago_ms(stream_ttl_ms())

    rows =
      Query.rows(
        Repo.query(
          """
          SELECT message_id, command_id, dedupe_principal_key, channel_id,
                 sender_bot_id, type, format, text, reply_to, created_at,
                 event_id, invocation_json
          FROM chat_v2.messages
          WHERE stream_state NOT IN ('none', 'final', 'abandoned')
            AND updated_at < $1
          LIMIT #{batch}
          """,
          [cutoff],
          type: true
        )
      )

    rows
    |> Enum.filter(fn row -> not stream_live?(row["channel_id"], row["message_id"]) end)
    |> Enum.map(fn row -> handle_stale_stream(row) end)
    |> Enum.count(&(&1 == :ok))
  end

  @doc """
  Bot-deliveries cleanup (spec D14): delete `delivered` / `dropped` rows
  past the retention window. `pending` rows are never touched (crash
  recovery). Returns the number of rows deleted.
  """
  def cleanup_bot_deliveries do
    cutoff = ago_ms(cfg(:delivery_retention_ms, 60_000))
    batch = cfg(:sweep_batch, 500)

    delete_batches(
      """
      DELETE FROM chat_v2.bot_deliveries
      WHERE delivery_id IN (
        SELECT delivery_id FROM chat_v2.bot_deliveries
        WHERE status IN ('delivered', 'dropped') AND updated_at < $1
        LIMIT #{batch}
      )
      """,
      batch,
      [cutoff]
    )
  end

  # ---------------------------------------------------------------- helpers

  # Loop a bounded DELETE until a batch returns fewer rows than the batch
  # size (exhaustion). Idempotent by construction (each batch deletes rows
  # that no longer match the next scan).
  defp delete_batches(sql, batch, params \\ []) do
    delete_batches_loop(sql, batch, params, 0)
  end

  defp delete_batches_loop(sql, batch, params, acc) do
    case Repo.query!(sql, params, type: true) |> num_rows() do
      n when n < batch -> acc + n
      n -> delete_batches_loop(sql, batch, params, acc + n)
    end
  end

  # The `Stream.<cid>#<mid>` process holds the ephemeral buffer; a live
  # process means the stream is being actively appended to, so housekeeping
  # must not touch its row.
  defp stream_live?(channel_id, message_id) do
    Registry.lookup(LiliumChat.Streams.Registry, {channel_id, message_id}) != []
  end

  # Per-row abandon per contract §9.15.5. Returns `:ok` once the row is
  # handled (either branch); per-row errors are logged and swallowed so a
  # single bad row cannot stall the sweep.
  defp handle_stale_stream(row) do
    channel_id = row["channel_id"]
    message_id = row["message_id"]
    text = row["text"] || ""

    try do
      if text == "" or is_nil(row["sender_bot_id"]) do
        # Empty branch: live-only cleanup frame, no canonical write.
        delete_streaming_row(channel_id, message_id)
        broadcast_cleanup(channel_id, message_id)
      else
        # Non-empty branch: the writer creates the canonical row, so the
        # stale projection row makes way for it first.
        delete_streaming_row(channel_id, message_id)

        input = %{
          bot_id: row["sender_bot_id"],
          message_id: message_id,
          resolved_text: text,
          created_at: row["created_at"],
          format: row["format"] || "plain",
          type: row["type"] || "text",
          reply_to: row["reply_to"]
        }

        case Channel.abandon_stream(channel_id, input) do
          {:ok, _} ->
            :ok

          # The writer could not commit (e.g. the channel is dissolved) —
          # restore the row in a terminal state so nothing is lost.
          {:error, reason} ->
            Logger.warning(
              "housekeeping: canonical stream abandon failed (#{reason.code}), " <>
                "restoring row"
            )

            restore_abandoned_row(row)
        end
      end

      :ok
    rescue
      e ->
        Logger.warning(
          "housekeeping: stream sweep failed for #{channel_id}##{message_id}: " <>
            Exception.message(e)
        )

        :ok
    end
  end

  defp delete_streaming_row(channel_id, message_id) do
    Repo.query!(
      """
      DELETE FROM chat_v2.messages
      WHERE channel_id = $1 AND message_id = $2
        AND stream_state NOT IN ('none', 'final', 'abandoned')
      """,
      [channel_id, message_id],
      type: true
    )
  end

  # The writer's canonical row could not be inserted — put the captured row
  # back in a terminal state. `ON CONFLICT DO NOTHING` keeps this safe if a
  # concurrent finalize/abandon won the race.
  defp restore_abandoned_row(row) do
    Repo.query!(
      """
      INSERT INTO chat_v2.messages (
        message_id, command_id, dedupe_principal_key, channel_id,
        sender_kind, sender_bot_id, type, format, status, text, reply_to,
        stream_state, created_at, updated_at, event_id, invocation_json
      ) VALUES ($1, $2, $3, $4, 'bot', $5, $6, $7, 'failed', $8, $9,
                'abandoned', $10, $11, $12, $13)
      ON CONFLICT (message_id) DO NOTHING
      """,
      [
        row["message_id"],
        row["command_id"],
        row["dedupe_principal_key"],
        row["channel_id"],
        row["sender_bot_id"],
        row["type"],
        row["format"],
        row["text"],
        row["reply_to"],
        row["created_at"],
        DateTime.utc_now(),
        row["event_id"],
        row["invocation_json"]
      ],
      type: true
    )
  end

  # Live-only frame (contract §9.15.5 empty branch) — the same shape the
  # in-memory `LiliumChat.Stream` broadcasts.
  defp broadcast_cleanup(channel_id, message_id) do
    frame =
      Frames.stream_event("message.stream_abandon_cleanup", channel_id, %{
        "channel_id" => channel_id,
        "message_id" => message_id
      })

    topic = "channel:" <> channel_id
    Observability.broadcast(LiliumChat.PubSub, topic, {:broadcast, topic, frame})
  end

  # The live stream TTL (`:bot_stream` `ttl_seconds` — the in-memory
  # self-expiry the bot must connect before, contract §9.15) is the single
  # source of truth; `stream_ttl_ms` in the `:housekeeping` config remains
  # a valid override (tests shrink it to 1ms).
  defp stream_ttl_ms do
    cfg(:stream_ttl_ms, stream_ttl_default_ms())
  end

  defp stream_ttl_default_ms do
    Application.get_env(:lilium_chat, :bot_stream, [])
    |> Keyword.get(:ttl_seconds, 300)
    |> Kernel.*(1000)
  end

  defp ago_ms(ms) do
    DateTime.utc_now() |> DateTime.add(-ms, :millisecond)
  end

  defp num_rows(%Postgrex.Result{num_rows: n}), do: n

  defp schedule_next do
    Process.send_after(self(), :sweep, cfg(:interval_ms, 60_000))
    :ok
  end

  defp enabled?, do: cfg(:enabled, true) == true

  defp cfg(key, default) do
    Application.get_env(:lilium_chat, :housekeeping, [])
    |> Keyword.get(key, default)
  end
end
