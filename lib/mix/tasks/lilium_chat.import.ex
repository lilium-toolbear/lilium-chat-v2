defmodule Mix.Tasks.LiliumChat.Import do
  @moduledoc """
  Import data into the `chat_v2` storage baseline (spec §3/§8, issue #4).

  ## Subcommands

      mix lilium_chat.import copy [--strict]
          Copy chat.* -> chat_v2.* (single transaction, idempotent).
          --strict fails on unapplied archive records instead of warning.

      mix lilium_chat.import verify
          Watermark verification: per-table row counts + MAX() of monotonic
          columns must match between chat.* and chat_v2.*; reports archive lag.

      mix lilium_chat.import read-state --file <export.json>
          Import read_state rows exported from the old Worker (UserDirectory
          my_channels.last_read_event_id). Monotonic upsert per (user, channel).

      mix lilium_chat.import invites --file <export.json>
          Upsert invite rows + channel_id mapping exported from the
          per-ChatChannel DOs; reports unmapped invites afterwards.

      mix lilium_chat.import backfill-events
          Backfill chat_v2.messages.event_id from message.created events.

      mix lilium_chat.import all [--strict] [--read-state <file>] [--invites <file>]
          Full cutover sequence: copy -> backfill-events -> read-state? ->
          invites? -> verify. Fails fast on any step.

  Export files are produced by `mix lilium_chat.export` (old Worker debug API).
  """
  use Mix.Task

  @shortdoc "Import chat.* / DO SQLite state into chat_v2 (cutover tool)"

  @switches [
    strict: :boolean,
    file: :string,
    read_state: :string,
    invites: :string
  ]

  def run(args) do
    {opts, rest} = OptionParser.parse!(args, strict: @switches)
    subcommand = List.first(rest) || "help"

    Mix.Task.run("app.start")

    case subcommand do
      "copy" ->
        run_copy(opts)

      "verify" ->
        run_verify()

      "read-state" ->
        run_read_state(opts)

      "invites" ->
        run_invites(opts)

      "backfill-events" ->
        run_backfill_events()

      "all" ->
        run_all(opts)

      _ ->
        Mix.shell().info(@moduledoc)
    end
  end

  # ----------------------------------------------------------------------

  defp run_copy(opts) do
    case LiliumChat.Import.copy(strict: opts[:strict] || false) do
      {:ok, report} ->
        for {table, n} <- report.tables do
          Mix.shell().info("  #{table}: #{n}")
        end

        Mix.shell().info(
          "COPIED #{report.total_rows} rows across #{map_size(report.tables)} tables"
        )

      {:error, reason} ->
        Mix.shell().error("COPY FAILED: #{reason}")
        System.halt(1)
    end
  end

  defp run_verify do
    case LiliumChat.Import.verify() do
      {:ok, report} ->
        for {table, %{source_count: s}} <- report.tables do
          Mix.shell().info("  #{table}: #{s} rows (match)")
        end

        if lag = report.archive_lag do
          Mix.shell().info(
            "archive lag: #{lag.pending_records} unapplied records (max received_at=#{inspect(lag.max_received_at)})"
          )
        end

        Mix.shell().info("VERIFY OK")

      {:error, report} ->
        for failure <- report.failures do
          Mix.shell().error("  MISMATCH: #{failure}")
        end

        System.halt(1)
    end
  end

  defp run_read_state(opts) do
    file = require_file!(opts[:file])
    rows = read_rows!(file, "lilium_chat.read_state_export.v1")

    {:ok, %{imported: n, skipped: s}} = LiliumChat.Import.import_read_state(rows)
    Mix.shell().info("READ_STATE imported=#{n} skipped=#{s}")
  end

  defp run_invites(opts) do
    file = require_file!(opts[:file])
    rows = read_rows!(file, "lilium_chat.invite_index_export.v1")

    {:ok, %{upserted: n}} = LiliumChat.Import.upsert_invites(rows)
    unmapped = LiliumChat.Import.invites_unmapped_count()
    Mix.shell().info("INVITES upserted=#{n} unmapped_channel_id=#{unmapped}")
  end

  defp run_backfill_events do
    {:ok, %{backfilled: n, unmatched: u}} = LiliumChat.Import.backfill_message_events()
    Mix.shell().info("EVENTS backfilled=#{n} unmatched=#{u}")
  end

  defp run_all(opts) do
    run_copy(opts)
    run_backfill_events()

    if file = opts[:read_state] do
      Mix.Task.run("lilium_chat.import", ["read-state", "--file", file])
    end

    if file = opts[:invites] do
      Mix.Task.run("lilium_chat.import", ["invites", "--file", file])
    end

    run_verify()
  end

  # ----------------------------------------------------------------------

  defp require_file!(nil) do
    Mix.shell().error("--file <export.json> is required")
    System.halt(1)
  end

  defp require_file!(path), do: path

  defp read_rows!(path, expected_format) do
    unless File.exists?(path) do
      Mix.shell().error("file not found: #{path}")
      System.halt(1)
    end

    {:ok, raw} = File.read(path)
    decoded = Jason.decode!(raw)

    rows =
      case decoded do
        %{"format" => format, "rows" => list} when is_list(list) ->
          if format != expected_format do
            Mix.shell().warning("expected format #{expected_format}, got #{format}")
          end

          list

        list when is_list(list) ->
          list

        other ->
          Mix.shell().error("unsupported export file shape: #{inspect(other)}")
          System.halt(1)
      end

    rows
  end
end
