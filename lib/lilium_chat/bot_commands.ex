defmodule LiliumChat.BotCommands do
  @moduledoc """
  Bot command catalog — `PUT /bot/commands` sync, current definition lookup,
  and `GET /commands/directory` search (contract §9.3/§9.12.1, issue #16).

  Port of the old Worker's `BotRegistry` DO `syncCommands` / `getCommand` /
  `searchCommands`. The upsert key is `(bot_id, normalized name)`; the global
  slash-token namespace lives in `bot_command_names` and a token owned by
  another command resolves to `409 COMMAND_NAME_CONFLICT` with a `conflict`
  detail object.
  """

  alias LiliumChat.{
    Bots,
    CanonicalJSON,
    CommandManifest,
    CommandOptions,
    Errors,
    Idempotency,
    Ids,
    Projections,
    Query,
    Repo,
    SlashTokens
  }

  @operation "bot.commands.sync"

  # --------------------------------------------------------------------------
  # PUT /bot/commands — catalog sync
  # --------------------------------------------------------------------------

  @doc """
  Sync a bot's command catalog. `commands_raw` is the decoded request array.

  Returns `{:ok, response_map}` | `{:error, %ApiError{}}` |
  `{:conflict, %ApiError{}, conflict_map}`.
  """
  def sync(bot_id, idempotency_key, commands_raw) when is_list(commands_raw) do
    case build_plans(commands_raw) do
      {:ok, plans} ->
        request_hash = plans |> Enum.map(& &1.cmd) |> CommandOptions.command_request_hash()

        case Idempotency.check("bot", bot_id, @operation, idempotency_key, request_hash) do
          :missing ->
            do_sync(bot_id, idempotency_key, plans, request_hash)

          {:cached, response} ->
            {:ok, response}

          {:conflict, api_error} ->
            {:error, api_error}
        end

      {:error, _} = err ->
        err
    end
  end

  def sync(_bot_id, _key, _commands_raw) do
    {:error, Errors.new("INVALID_COMMAND_OPTIONS", "commands must be an array")}
  end

  # Validate + slash-token collection, in request order. Duplicate tokens
  # (inside a command or across commands) fail the whole sync.
  defp build_plans(commands) do
    commands
    |> Enum.reduce_while({[], MapSet.new()}, fn raw_cmd, {acc_plans, seen_tokens} ->
      case validate_and_collect(raw_cmd) do
        {:ok, cmd, collected} ->
          case Enum.find(collected.all, &MapSet.member?(seen_tokens, &1)) do
            nil ->
              plan =
                %{
                  cmd:
                    cmd
                    |> Map.put(:name, collected.canonical)
                    |> Map.put(:aliases, collected.aliases),
                  canonical: collected.canonical,
                  aliases: collected.aliases,
                  all_tokens: collected.all,
                  def_hash:
                    cmd
                    |> Map.put(:name, collected.canonical)
                    |> Map.put(:aliases, collected.aliases)
                    |> CommandOptions.canonical_definition()
                    |> CanonicalJSON.encode_and_sha256()
                }

              seen = Enum.reduce(collected.all, seen_tokens, &MapSet.put(&2, &1))
              {:cont, {[plan | acc_plans], seen}}

            token ->
              {:halt,
               {:error, Errors.new("INVALID_COMMAND_OPTIONS", "duplicate slash token: #{token}")}}
          end

        {:error, msg} ->
          {:halt, {:error, Errors.new("INVALID_COMMAND_OPTIONS", msg)}}
      end
    end)
    |> case do
      # Enum.reduce_while returns the final accumulator on success.
      {plans, _seen} when is_list(plans) -> {:ok, Enum.reverse(plans)}
      {:error, _} = err -> err
      _other -> {:error, Errors.new("INVALID_COMMAND_OPTIONS", "invalid command")}
    end
  end

  defp validate_and_collect(raw) do
    case CommandOptions.validate_command(raw) do
      {:error, msg} ->
        {:error, msg}

      {:ok, cmd} ->
        case SlashTokens.collect(cmd.name, cmd.aliases) do
          {:ok, collected} -> {:ok, cmd, collected}
          {:error, reason} -> {:error, "invalid slash token: #{reason}"}
        end
    end
  end

  defp do_sync(bot_id, idempotency_key, plans, request_hash) do
    now = DateTime.utc_now()

    result =
      Repo.transaction(fn ->
        case Idempotency.check("bot", bot_id, @operation, idempotency_key, request_hash) do
          {:conflict, api_error} ->
            Repo.rollback({:gate, api_error})

          {:cached, response} ->
            response

          :missing ->
            case plans |> Enum.reduce_while([], &upsert_plan(&1, &2, bot_id, now)) do
              {:conflict, winner} ->
                Repo.rollback({:conflict, winner})

              list ->
                response = %{"commands" => Enum.reverse(list)}

                Idempotency.write_completed(
                  "bot",
                  bot_id,
                  @operation,
                  idempotency_key,
                  request_hash,
                  response
                )

                response
            end
        end
      end)

    case result do
      {:ok, response} ->
        {:ok, response}

      {:error, {:conflict, winner}} ->
        {:conflict,
         Errors.new(
           "COMMAND_NAME_CONFLICT",
           "slash token already in use: #{winner[:slash_token]}"
         ), winner}

      {:error, {:gate, %Errors.ApiError{} = api_error}} ->
        {:error, api_error}
    end
  end

  defp upsert_plan(plan, acc, bot_id, now) do
    case upsert_command(bot_id, plan, now) do
      {:conflict, winner} ->
        {:halt, {:conflict, winner}}

      {:ok, item} ->
        {:cont, [item | acc]}
    end
  end

  defp upsert_command(bot_id, plan, now) do
    existing =
      Query.rows(
        Repo.query(
          """
          SELECT bot_command_id, schema_version, definition_hash
          FROM chat_v2.bot_commands
          WHERE bot_id = $1 AND name = $2
          """,
          [bot_id, plan.canonical]
        )
      )
      |> List.first()

    {bot_command_id, schema_version} =
      if existing do
        version =
          if existing["definition_hash"] == plan.def_hash do
            existing["schema_version"]
          else
            existing["schema_version"] + 1
          end

        Repo.query!(
          """
          UPDATE chat_v2.bot_commands
          SET description = $1, help_text = $2, options_json = $3,
              default_member_permission = $4, execution_mode = $5,
              stateful_config_json = $6, definition_hash = $7,
              schema_version = $8, status = 'active', deleted_at = NULL,
              updated_at = $9
          WHERE bot_command_id = $10
          """,
          [
            plan.cmd.description,
            plan.cmd.help_text,
            options_to_maps(plan.cmd.options),
            plan.cmd.default_member_permission,
            plan.cmd.execution_mode,
            stateful_to_map(plan.cmd.stateful_config),
            plan.def_hash,
            version,
            now,
            existing["bot_command_id"]
          ]
        )

        {existing["bot_command_id"], version}
      else
        new_id = Ids.uuidv7()

        Repo.query!(
          """
          INSERT INTO chat_v2.bot_commands (
            bot_command_id, bot_id, name, description, help_text, options_json,
            default_member_permission, execution_mode, stateful_config_json,
            schema_version, definition_hash, status, created_at, updated_at, deleted_at
          ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, 'active', $12, $12, NULL)
          """,
          [
            new_id,
            bot_id,
            plan.canonical,
            plan.cmd.description,
            plan.cmd.help_text,
            options_to_maps(plan.cmd.options),
            plan.cmd.default_member_permission,
            plan.cmd.execution_mode,
            stateful_to_map(plan.cmd.stateful_config),
            1,
            plan.def_hash,
            now
          ]
        )

        {new_id, 1}
      end

    # Global slash-token namespace: any token owned by ANOTHER command is a
    # conflict. Our own stale rows pass (same bot_command_id) and are
    # replaced below.
    winner =
      Enum.find_value(plan.all_tokens, fn token ->
        rows =
          Query.rows(
            Repo.query(
              "SELECT bot_command_id, bot_id FROM chat_v2.bot_command_names WHERE slash_token = $1",
              [token]
            )
          )

        row = List.first(rows)

        if row != nil and row["bot_command_id"] != bot_command_id do
          %{slash_token: token, bot_command_id: row["bot_command_id"], bot_id: row["bot_id"]}
        end
      end)

    if winner do
      {:conflict, winner}
    else
      # full-replace aliases + names for this command
      Repo.query!("DELETE FROM chat_v2.bot_command_aliases WHERE bot_command_id = $1", [
        bot_command_id
      ])

      Repo.query!("DELETE FROM chat_v2.bot_command_names WHERE bot_command_id = $1", [
        bot_command_id
      ])

      for token <- plan.aliases do
        Repo.query!(
          "INSERT INTO chat_v2.bot_command_aliases (bot_command_id, bot_id, alias, created_at) VALUES ($1, $2, $3, $4)",
          [bot_command_id, bot_id, token, now]
        )

        Repo.query!(
          "INSERT INTO chat_v2.bot_command_names (slash_token, bot_command_id, bot_id, kind, created_at) VALUES ($1, $2, $3, 'alias', $4)",
          [token, bot_command_id, bot_id, now]
        )
      end

      Repo.query!(
        "INSERT INTO chat_v2.bot_command_names (slash_token, bot_command_id, bot_id, kind, created_at) VALUES ($1, $2, $3, 'canonical', $4)",
        [plan.canonical, bot_command_id, bot_id, now]
      )

      {:ok,
       %{
         "bot_command_id" => bot_command_id,
         "name" => plan.canonical,
         "aliases" => plan.aliases,
         "status" => "active",
         "execution_mode" => plan.cmd.execution_mode,
         "stateful_config" => stateful_to_map(plan.cmd.stateful_config),
         "definition_hash" => plan.def_hash,
         "schema_version" => schema_version,
         "updated_at" => Projections.format_ts(now)
       }}
    end
  end

  # --------------------------------------------------------------------------
  # get_command (the old Worker's BotRegistry.getCommand)
  # --------------------------------------------------------------------------

  @doc """
  Current definition of a single active command + aliases
  (`fetchCommandSnapshot` in the old Worker).
  """
  def get_current(bot_command_id) do
    rows =
      Query.rows(
        Repo.query(
          """
          SELECT c.bot_command_id, c.name, c.description, c.help_text,
                 c.options_json, c.default_member_permission,
                 c.execution_mode, c.stateful_config_json,
                 c.schema_version, c.definition_hash, c.deleted_at, c.status,
                 a.bot_id, a.display_name, a.avatar_url
          FROM chat_v2.bot_commands c
          JOIN chat_v2.bot_apps a ON a.bot_id = c.bot_id
          WHERE c.bot_command_id = $1
          """,
          [bot_command_id]
        )
      )

    case List.first(rows) do
      nil ->
        {:error, Errors.new("BOT_COMMAND_DISABLED", "command disabled or deleted")}

      row ->
        if is_nil(row["deleted_at"]) and row["status"] == "active" do
          aliases =
            Query.rows(
              Repo.query(
                "SELECT alias FROM chat_v2.bot_command_aliases WHERE bot_command_id = $1 ORDER BY alias ASC",
                [bot_command_id]
              )
            )
            |> Enum.map(& &1["alias"])

          {:ok,
           %{
             "bot_command_id" => row["bot_command_id"],
             "name" => row["name"],
             "aliases" => aliases,
             "description" => row["description"] || "",
             "help_text" => row["help_text"] || "",
             "bot" => %{
               "bot_id" => row["bot_id"],
               "display_name" => row["display_name"],
               "avatar_url" => row["avatar_url"]
             },
             "options" => row["options_json"] || [],
             "default_member_permission" => row["default_member_permission"],
             "execution" => command_execution(row)
           }}
        else
          {:error, Errors.new("BOT_COMMAND_DISABLED", "command disabled or deleted")}
        end
    end
  end

  # Wire execution shape: `{mode, stateful?}` only (no schema_version /
  # definition_hash — those are catalog columns, not wire fields).
  defp command_execution(row) do
    base = %{"mode" => row["execution_mode"]}

    if row["execution_mode"] == "stateful" and row["stateful_config_json"] != nil do
      Map.put(base, "stateful", row["stateful_config_json"])
    else
      base
    end
  end

  # --------------------------------------------------------------------------
  # directory
  # --------------------------------------------------------------------------

  @doc "`GET /commands/directory` — search active commands of active bots."
  def directory(query, limit, cursor) do
    # NFKC-normalize the search term (parity with the old Worker's
    # searchCommands) so full-width / compatibility forms match.
    query_raw = (query || "") |> String.normalize(:nfkc) |> String.trim() |> String.downcase()
    limit = Bots.parse_limit(limit, 20)
    offset = Bots.decode_offset_cursor(cursor)

    rows =
      Query.rows(
        Repo.query(
          """
          SELECT c.bot_command_id, c.name, c.description, c.help_text,
                 c.options_json, c.default_member_permission,
                 c.execution_mode, c.stateful_config_json,
                 a.bot_id, a.display_name, a.avatar_url
          FROM chat_v2.bot_commands c
          JOIN chat_v2.bot_apps a ON a.bot_id = c.bot_id
          WHERE c.status = 'active'
            AND c.deleted_at IS NULL
            AND a.status = 'active'
            AND ($1 = ''
                 OR lower(c.name) LIKE '%' || lower($1) || '%'
                 OR EXISTS (
                   SELECT 1 FROM chat_v2.bot_command_aliases ca
                   WHERE ca.bot_command_id = c.bot_command_id
                     AND lower(ca.alias) LIKE '%' || lower($1) || '%'
                 ))
          ORDER BY c.updated_at DESC, c.bot_command_id DESC
          LIMIT $2 OFFSET $3
          """,
          [query_raw, limit, offset]
        )
      )

    aliases_by_command =
      CommandManifest.aliases_by_command(Enum.map(rows, & &1["bot_command_id"]))

    items =
      Enum.map(rows, fn row ->
        %{
          "bot_command_id" => row["bot_command_id"],
          "name" => row["name"],
          "aliases" => aliases_by_command[row["bot_command_id"]] || [],
          "description" => row["description"] || "",
          "help_text" => row["help_text"] || "",
          "bot" => %{
            "bot_id" => row["bot_id"],
            "display_name" => row["display_name"],
            "avatar_url" => row["avatar_url"]
          },
          "options" => row["options_json"] || [],
          "default_member_permission" => row["default_member_permission"],
          "execution" => command_execution(row)
        }
      end)

    {:ok,
     %{
       items: items,
       next_cursor:
         if(length(rows) == limit) do
           Bots.encode_offset_cursor(offset + length(rows))
         else
           nil
         end
     }}
  end

  # --------------------------------------------------------------------------
  # field-list → map conversion (insertion-ordered JSONB storage / projection)
  # --------------------------------------------------------------------------

  defp options_to_maps(options) do
    Enum.map(options, &fields_to_flat_map/1)
  end

  defp fields_to_flat_map(fields) do
    for {key, value} <- fields, into: %{} do
      {key, value}
    end
  end

  defp stateful_to_map(nil), do: nil

  defp stateful_to_map(fields) do
    listen = fetch_field(fields, "listen_capability")

    %{
      "mutex_scope" => fetch_field(fields, "mutex_scope"),
      "default_ttl_seconds" => fetch_field(fields, "default_ttl_seconds"),
      "max_ttl_seconds" => fetch_field(fields, "max_ttl_seconds"),
      "listen_capability" => %{
        "message_types" => fetch_field(listen, "message_types"),
        "include_bot_messages" => fetch_field(listen, "include_bot_messages"),
        "include_own_messages" => fetch_field(listen, "include_own_messages")
      }
    }
  end

  defp fetch_field(fields, key) do
    case List.keyfind(fields, key, 0) do
      {^key, value} -> value
      nil -> nil
    end
  end
end
