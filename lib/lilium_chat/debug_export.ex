defmodule LiliumChat.DebugExport do
  @moduledoc """
  Exports DO SQLite runtime state from the **old Worker** via its
  `/internal/debug/sql-all` endpoint (gated by `DEBUG_TOKEN`, see old repo
  `src/routes/debug-sql.ts`).

  This is the "debug API path" of spec §8 step 2: at cutover the old Worker
  is still live and read-only, so its DO state (`my_channels.last_read_event_id`
  in UserDirectory, per-channel `invites` in ChatChannel) is pulled over HTTP
  and imported into `chat_v2` by `LiliumChat.Import`.

  Wire format (old Worker, verified against production):

      POST /internal/debug/sql-all
      Authorization: Bearer <DEBUG_TOKEN>
      {"class": "...", "query": "SELECT ...", "names": ["..."]}   # names for non-channel-keyed classes

      -> 200 {"class": "...", "instance_count": N,
              "results": [{"name": "...", "ok": true,
                           "result": {"columns": [...], "rows": [{...}, ...],
                                      "rows_read": n, "truncated": bool}}, ...]}

  Rows are objects keyed by column name. Results are capped at 5000 rows per
  instance (`MAX_LIMIT` in the old repo) — a `truncated: true` flag is
  surfaced as a warning so the operator can re-run with a narrower query.
  """

  # :httpc.request/3 has no @spec — silence the undefined-function warning.
  @compile {:no_warn_undefined, :httpc}

  @user_directory_names_chunk 200

  @doc """
  Exports `my_channels.last_read_event_id` for every given user from their
  UserDirectory DO.

  `user_ids` should cover every UserDirectory instance that may hold a
  read cursor (e.g. distinct users from `chat.channel_members` +
  `chat.dm_pairs`). Requests are chunked to keep payloads small.

  Returns `{:ok, %{rows: [...], truncated_instances: n}}` or
  `{error, term}`.
  """
  def export_read_state(base_url, token, user_ids) do
    chunks = Enum.chunk_every(user_ids, @user_directory_names_chunk)

    results =
      for chunk <- chunks do
        body = %{
          "class" => "UserDirectory",
          "query" =>
            "SELECT channel_id, last_read_event_id FROM my_channels WHERE last_read_event_id IS NOT NULL",
          "names" => chunk
        }

        case sql_all(base_url, token, body) do
          {:ok, payload} -> {:ok, payload}
          {:error, reason} -> {:error, reason}
        end
      end

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil ->
        rows =
          for {:ok, payload} <- results,
              %{"name" => name, "ok" => true, "result" => result} <- payload["results"],
              row <- result["rows"] || [] do
            %{
              user_id: name,
              channel_id: row["channel_id"],
              last_read_event_id: row["last_read_event_id"]
            }
          end

        truncated =
          results
          |> Enum.flat_map(fn {:ok, payload} -> payload["results"] || [] end)
          |> Enum.count(fn %{"ok" => true, "result" => %{"truncated" => t}} -> t == true end)

        if truncated > 0 do
          require Logger

          Logger.warning(
            "debug export: #{truncated} instance(s) truncated at the 5000-row cap — re-run with a narrower query"
          )
        end

        {:ok, %{rows: rows, truncated_instances: truncated}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Exports the per-ChatChannel `invites` tables (auto-enumerated via
  ChannelDirectory in the old Worker). Each row is tagged with its
  `channel_id` (the DO instance name) — this replaces the vanished
  `invite_index` projection.

  Returns `{:ok, %{rows: [...], truncated_instances: n}}` or `{:error, term}`.
  """
  def export_invite_index(base_url, token) do
    body = %{
      "class" => "ChatChannel",
      "query" =>
        "SELECT invite_code, created_by, expires_at, max_uses, used_count, revoked_at, created_at FROM invites"
    }

    case sql_all(base_url, token, body) do
      {:ok, payload} ->
        rows =
          for %{"name" => channel_id, "ok" => true, "result" => result} <-
                payload["results"] || [],
              row <- result["rows"] || [] do
            # String keys: rows come from Jason (string-keyed) and stay uniform.
            Map.merge(%{"channel_id" => channel_id}, row)
          end

        truncated =
          (payload["results"] || [])
          |> Enum.count(fn %{"ok" => true, "result" => %{"truncated" => t}} -> t == true end)

        {:ok, %{rows: rows, truncated_instances: truncated}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ----------------------------------------------------------------------
  # HTTP plumbing (:httpc — no extra deps for an ops tool)
  # ----------------------------------------------------------------------

  # In this OTP build the inets app starts with its ebin directory missing from
  # the code path, so lazily loaded modules (e.g. http_util) fail with :nofile
  # at request time. Start the apps and pin the ebin back on the path if needed.
  defp ensure_httpc_ready do
    :application.ensure_all_started(:inets)
    :application.ensure_all_started(:ssl)

    if :code.ensure_loaded(:http_util) == {:module, :http_util} do
      :ok
    else
      root = to_string(:code.root_dir())

      for dir <- Path.wildcard(Path.join(root, "lib/inets-*/ebin")) do
        # code:add_patha/2 requires a charlist (Erlang string()).
        :code.add_patha(String.to_charlist(dir))
      end

      case :code.ensure_loaded(:http_util) do
        {:module, _} -> :ok
        {:error, reason} -> raise "failed to load http_util: #{inspect(reason)}"
      end
    end
  end

  defp sql_all(base_url, token, body) do
    ensure_httpc_ready()

    url = String.trim_trailing(base_url, "/") <> "/internal/debug/sql-all"

    headers = [
      {~c"authorization", "Bearer #{token}"},
      {~c"content-type", ~c"application/json"},
      {~c"accept", ~c"application/json"}
    ]

    # OTP 29 httpc API (see httpc.erl): request(Method, Request, HttpOptions, Options)
    # with Method an atom and Request = {Url, Headers, ContentType, Body}.
    payload = body |> Jason.encode!() |> to_charlist()

    case :httpc.request(
           :post,
           {String.to_charlist(url), headers, ~c"application/json", payload},
           [timeout: 120_000],
           []
         ) do
      {:ok, {{_, status, _}, _, resp_body}} when status in 200..299 ->
        payload = Jason.decode!(resp_body)

        case Enum.find(payload["results"] || [], &(&1["ok"] == false)) do
          nil -> {:ok, payload}
          bad -> {:error, "instance failed: #{bad["name"]} — #{bad["error"]}"}
        end

      {:ok, {{_, status, _}, _, resp_body}} ->
        {:error, %{status: status, body: to_string(resp_body)}}

      {:error, reason} ->
        {:error, {:http, reason}}
    end
  end
end
