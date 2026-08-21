defmodule Mix.Tasks.LiliumChat.Export do
  @moduledoc """
  Export DO SQLite runtime state from the **old Worker** (spec §8 step 2).

  Uses the old Worker's read-only debug API (`/internal/debug/sql-all`,
  gated by `DEBUG_TOKEN` — see old repo `src/routes/debug-sql.ts`). The old
  Worker must be live and reachable; this is a cutover-window tool.

  ## Subcommands

      mix lilium_chat.export users --out users.txt
          Distinct user ids from chat.channel_members + chat.dm_pairs —
          the UserDirectory instance names needed for read-state export.

      mix lilium_chat.export read-state --base-url <url> --token <DEBUG_TOKEN> \\
              --users-file users.txt --out read_state.json
          my_channels.last_read_event_id per user (UserDirectory DOs).

      mix lilium_chat.export invites --base-url <url> --token <DEBUG_TOKEN> \\
              --out invite_index.json
          Per-ChatChannel invites tables incl. the channel_id mapping
          (replaces the vanished invite_index projection).

  Output files are consumed by `mix lilium_chat.import`.
  """
  use Mix.Task

  @shortdoc "Export DO SQLite state from the old Worker debug API (cutover tool)"

  @switches [
    base_url: :string,
    token: :string,
    users_file: :string,
    out: :string
  ]

  def run(args) do
    {opts, rest} = OptionParser.parse!(args, strict: @switches)
    subcommand = List.first(rest) || "help"

    case subcommand do
      "users" ->
        run_users(opts)

      "read-state" ->
        Mix.Task.run("app.start")
        run_read_state(opts)

      "invites" ->
        Mix.Task.run("app.start")
        run_invites(opts)

      _ ->
        Mix.shell().info(@moduledoc)
    end
  end

  # ----------------------------------------------------------------------

  defp run_users(opts) do
    out = require_out!(opts[:out])

    Mix.Task.run("app.start")

    alias LiliumChat.Repo

    %{rows: rows} =
      Repo.query!("""
      SELECT DISTINCT u FROM (
        SELECT user_id AS u FROM chat.channel_members
        UNION SELECT user_low FROM chat.dm_pairs
        UNION SELECT user_high FROM chat.dm_pairs
      ) x ORDER BY 1
      """)

    File.write!(out, Enum.map_join(rows, "\n", fn [u] -> u end) <> "\n")
    Mix.shell().info("USERS wrote #{length(rows)} ids to #{out}")
  end

  defp run_read_state(opts) do
    base_url = require_opt!(opts, :base_url)
    token = require_opt!(opts, :token)
    users_file = opts[:users_file] || "users.txt"
    out = require_out!(opts[:out])

    unless File.exists?(users_file) do
      Mix.shell().error(
        "users file not found: #{users_file} (run: mix lilium_chat.export users --out #{users_file})"
      )

      System.halt(1)
    end

    user_ids =
      users_file
      |> File.read!()
      |> String.split(~r/\s+/, trim: true)

    case LiliumChat.DebugExport.export_read_state(base_url, token, user_ids) do
      {:ok, %{rows: rows, truncated_instances: t}} ->
        write_export!(out, "lilium_chat.read_state_export.v1", rows)

        Mix.shell().info(
          "READ_STATE exported #{length(rows)} rows (truncated instances: #{t}) -> #{out}"
        )

      {:error, reason} ->
        Mix.shell().error("EXPORT FAILED: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp run_invites(opts) do
    base_url = require_opt!(opts, :base_url)
    token = require_opt!(opts, :token)
    out = require_out!(opts[:out])

    case LiliumChat.DebugExport.export_invite_index(base_url, token) do
      {:ok, %{rows: rows, truncated_instances: t}} ->
        write_export!(out, "lilium_chat.invite_index_export.v1", rows)

        Mix.shell().info(
          "INVITES exported #{length(rows)} rows (truncated instances: #{t}) -> #{out}"
        )

      {:error, reason} ->
        Mix.shell().error("EXPORT FAILED: #{inspect(reason)}")
        System.halt(1)
    end
  end

  # ----------------------------------------------------------------------

  defp write_export!(path, format, rows) do
    payload = %{
      "format" => format,
      "exported_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "rows" => rows
    }

    File.write!(path, Jason.encode!(payload, pretty: true))
  end

  defp require_out!(nil) do
    Mix.shell().error("--out <file> is required")
    System.halt(1)
  end

  defp require_out!(path), do: path

  defp require_opt!(opts, key) do
    case opts[key] do
      nil ->
        Mix.shell().error("--#{String.replace(to_string(key), "_", "-")} is required")
        System.halt(1)

      value ->
        value
    end
  end
end
