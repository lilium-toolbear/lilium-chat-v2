defmodule LiliumChatWeb.DebugController do
  @moduledoc """
  `/internal/debug/*` ops surface (spec §10, issue #21) — the Elixir
  equivalent of the old Worker's debug routes (`src/routes/debug-sql.ts`),
  gated by `DEBUG_TOKEN` (`LiliumChatWeb.DebugTokenPlug`).

  The old Worker fanned a read-only query out across Durable Object
  instances; a single-machine PG deployment has exactly one instance, so:

    * `GET /internal/debug/classes` — the supported "classes" (PG schemas
      `chat_v2` / `public`) with their enumeration mode.
    * `POST /internal/debug/sql` — run a read-only `SELECT` / `WITH`
      statement on PG, capped and truncation-flagged, inside a
      `statement_timeout` + schema-scoped transaction.
    * `POST /internal/debug/sql-all` — same query, old-Worker response
      shape (`instance_count: 1`, `results: [{name, ok, result}]`) so
      tooling written against the old endpoint keeps working.

  Query guards (old-Worker parity + PG hardening):

    * only `SELECT` / `WITH` prefixes, no statement chaining (`;`),
    * `WITH`-queries additionally reject data-modifying CTEs and
      `SELECT INTO` is rejected, so no statement can write,
    * results capped at 5000 rows (default 1000) via `LIMIT n+1` with a
      `truncated` flag,
    * `statement_timeout` (5s) so a runaway query cannot pin the pool.

  Not implemented (spec §10 "不再需要的运维动作"): the old outbox
  dead-letter and channel-directory backfill endpoints have no equivalent
  in this architecture.
  """

  use LiliumChatWeb, :controller

  alias LiliumChat.Errors
  alias LiliumChat.Repo
  alias LiliumChatWeb.ErrorHandler

  @supported_classes ~w(chat_v2 public)
  @default_limit 1000
  @max_limit 5000
  @statement_timeout_ms 5_000
  @read_only_prefix ~r/^\s*(SELECT|WITH)\b/i
  # `\bUPDATE\b` does not match `updated_at` (no word boundary after
  # "update"), so common column names do not false-positive.
  @dml_cte ~r/\b(INSERT|UPDATE|DELETE|MERGE)\b/i
  @select_into ~r/\bINTO\s/i

  @doc "GET /internal/debug/classes — supported classes + enumeration mode."
  def classes(conn, _params) do
    json(conn, %{
      "classes" =>
        Enum.map(@supported_classes, fn class ->
          %{"class" => class, "enumeration" => "single PG instance"}
        end)
    })
  rescue
    e -> ErrorHandler.render_exception(conn, e)
  end

  @doc "POST /internal/debug/sql — read-only query on one PG schema."
  def sql(conn, params), do: respond(conn, params, :single)

  @doc "POST /internal/debug/sql-all — same query, old-Worker fan-out shape."
  def sql_all(conn, params), do: respond(conn, params, :all)

  defp respond(conn, params, shape) do
    %{class: class, query: query, limit: limit, name: name} = parse_body(params)

    result = run_debug_sql(class, query, limit)

    json(conn, envelope(shape, class, name, result))
  rescue
    e -> ErrorHandler.render_exception(conn, e)
  end

  defp envelope(:single, class, name, result) do
    Map.merge(%{"class" => class, "name" => name || "shared"}, result)
  end

  defp envelope(:all, class, name, result) do
    %{
      "class" => class,
      "instance_count" => 1,
      "results" => [%{"name" => name || "shared", "ok" => true, "result" => result}]
    }
  end

  # ---------------------------------------------------------------- parsing

  defp parse_body(body) when is_map(body) do
    %{
      class: parse_class(body["class"]),
      query: parse_query(body["query"]),
      limit: parse_limit(body["limit"]),
      name: parse_name(body["name"])
    }
  end

  defp parse_body(_), do: raise_api("INVALID_MESSAGE", "json body required")

  defp parse_class(class) when class in @supported_classes, do: class

  defp parse_class(_) do
    raise_api(
      "INVALID_MESSAGE",
      "unsupported class (allowed: #{Enum.join(@supported_classes, ", ")})"
    )
  end

  defp parse_query(query) when is_binary(query) do
    # Old-Worker normalization: strip trailing semicolons, then reject any
    # remaining ';' (statement chaining).
    raw = String.trim(query) |> String.trim_trailing(";")

    cond do
      raw == "" ->
        raise_api("INVALID_MESSAGE", "empty query")

      not Regex.match?(@read_only_prefix, raw) ->
        raise_api("FORBIDDEN", "debugSql only allows SELECT/WITH")

      String.contains?(raw, ";") ->
        raise_api("FORBIDDEN", "debugSql does not allow multiple statements")

      Regex.match?(@select_into, raw) ->
        raise_api("FORBIDDEN", "debugSql does not allow SELECT INTO")

      Regex.match?(@dml_cte, raw) ->
        raise_api("FORBIDDEN", "debugSql does not allow data-modifying statements")

      true ->
        raw
    end
  end

  defp parse_query(_), do: raise_api("INVALID_MESSAGE", "query required")

  defp parse_limit(limit) when is_integer(limit) and limit >= 1, do: min(limit, @max_limit)
  defp parse_limit(nil), do: @default_limit
  defp parse_limit(_), do: raise_api("INVALID_MESSAGE", "limit must be a positive integer")

  defp parse_name(name) when is_binary(name) and name != "", do: name
  defp parse_name(_), do: nil

  # ------------------------------------------------------------------ query

  defp run_debug_sql(class, query, limit) do
    # The query runs in its own transaction so `SET LOCAL` scoping is
    # transaction-bounded: search_path picks the requested schema, and
    # statement_timeout caps a runaway scan (client-side timeout too).
    wrapped = "SELECT * FROM ( #{query} ) _debug LIMIT #{limit + 1}"

    {columns, rows, truncated} =
      case Repo.transaction(
             fn ->
               Repo.query!("SET LOCAL search_path TO #{class}")
               Repo.query!("SET LOCAL statement_timeout = '#{@statement_timeout_ms}'")

               %Postgrex.Result{columns: cols, rows: rs} =
                 Repo.query!(wrapped, [], timeout: @statement_timeout_ms + 1_000)

               {cols, rs, length(rs) > limit}
             end,
             timeout: @statement_timeout_ms + 2_000
           ) do
        {:ok, result} -> result
        {:error, reason} -> raise reason
      end

    %{
      "columns" => columns,
      "rows" => rows |> Enum.take(limit) |> Enum.map(&row_map(columns, &1)),
      "rows_read" => min(length(rows), limit),
      "truncated" => truncated,
      "now_ms" => DateTime.to_unix(DateTime.utc_now(), :millisecond)
    }
  rescue
    e in Postgrex.Error ->
      # Render the PG error message in a contract-shaped envelope so ops can
      # fix the query (the old Worker surfaced these as 503; keeping the
      # message is the useful behaviour for an internal tool).
      raise_api("INVALID_MESSAGE", "debugSql failed: #{Exception.message(e)}")
  end

  # Old-Worker parity: rows are objects keyed by column name. PG types that
  # Jason cannot encode (Date/Time structs) are rendered as ISO-8601.
  defp row_map(columns, row) do
    columns
    |> Enum.zip(row)
    |> Map.new(fn {col, value} -> {col, jsonable(value)} end)
  end

  defp jsonable(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp jsonable(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp jsonable(%Date{} = d), do: Date.to_iso8601(d)
  defp jsonable(%Time{} = t), do: Time.to_iso8601(t)
  defp jsonable(value), do: value

  defp raise_api(code, message), do: raise(Errors.new(code, message))
end
