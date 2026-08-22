defmodule LiliumChat.CommandManifest do
  @moduledoc """
  Channel command manifest — projection, merge and platform items
  (contract §9.4, issue #16).

  Port of the old Worker's `src/chat/command-manifest.ts` +
  `official-command-manifest.ts` + `platform-commands.ts` +
  `command-snapshot.ts`. The manifest for a channel is:

  1. explicit `allowed` binding rows (snapshot must parse);
  2. official-bot active catalog commands, auto-allowed unless a `blocked`
     binding row exists (`permission_override` of an `allowed` binding, if
     any, still applies);
  3. platform `/help` (always) and `/permission` (owner/admin callers).

  Items are sorted by `name` (code-point order — the Elixir equivalent of
  the Worker's `localeCompare`) then `bot_command_id`. The wire shape is
  `{"version" => int, "items" => [...]}`.
  """

  alias LiliumChat.{Errors, Query, Repo}

  # -- platform command identity (contract §9.2 / platform-commands.ts) -------

  @platform_bot_id "00000000-0000-7000-8000-000000000600"
  @platform_help_id "00000000-0000-7000-8000-000000000700"
  @platform_permission_id "00000000-0000-7000-8000-000000000708"

  @doc "The platform bot summary used for `/help` and `/permission`."
  def platform_bot do
    %{
      "bot_id" => @platform_bot_id,
      "display_name" => "system",
      "avatar_url" =>
        "https://s3.kuma.homes/chat/avatars/019f134b-4324-7300-9023-b092c06ac4b2.png"
    }
  end

  def platform_help_item do
    %{
      "bot_command_id" => @platform_help_id,
      "name" => "help",
      "aliases" => [],
      "description" => "查看可用命令",
      "help_text" => "",
      "bot" => platform_bot(),
      "options" => [
        %{"name" => "command", "type" => "string", "required" => false, "description" => "命令名"}
      ],
      "execution" => %{"mode" => "stateless"},
      "effective_member_permission" => "member"
    }
  end

  def platform_permission_item do
    %{
      "bot_command_id" => @platform_permission_id,
      "name" => "permission",
      "aliases" => [],
      "description" => "管理频道命令开关",
      "help_text" => "",
      "bot" => platform_bot(),
      "options" => [
        %{"name" => "command", "type" => "string", "required" => false, "description" => "命令名"},
        %{
          "name" => "action",
          "type" => "string",
          "required" => false,
          "description" => "on 或 off"
        }
      ],
      "execution" => %{"mode" => "stateless"},
      "effective_member_permission" => "admin"
    }
  end

  # --------------------------------------------------------------------------
  # Snapshot parsing (command-snapshot.ts, over already-decoded JSONB maps)
  # --------------------------------------------------------------------------

  @doc """
  Parse + normalize a binding snapshot (already-decoded map). Returns
  `{:ok, snapshot}` or `:invalid`.
  """
  def parse_snapshot(raw) when is_map(raw) do
    with :ok <- snapshot_shape_ok?(raw),
         {:ok, options} <- normalize_options(raw["options"] || []),
         {:ok, execution} <- normalize_execution(raw["execution"]) do
      {:ok,
       %{
         "bot_command_id" => raw["bot_command_id"],
         "name" => raw["name"],
         "aliases" => Enum.filter(raw["aliases"] || [], &is_binary/1),
         "description" => raw["description"],
         "help_text" => raw["help_text"] || "",
         "bot" => %{
           "bot_id" => raw["bot"]["bot_id"],
           "display_name" => raw["bot"]["display_name"],
           "avatar_url" => raw["bot"]["avatar_url"]
         },
         "options" => options,
         "default_member_permission" => raw["default_member_permission"],
         "execution" => execution
       }}
    else
      _ -> :invalid
    end
  end

  def parse_snapshot(_), do: :invalid

  defp snapshot_shape_ok?(raw) do
    bot = raw["bot"]

    bot_ok? =
      is_map(bot) and
        is_binary(bot["bot_id"]) and
        is_binary(bot["display_name"]) and
        (bot["avatar_url"] == nil or is_binary(bot["avatar_url"]))

    cond do
      not is_binary(raw["bot_command_id"]) ->
        :fail

      not is_binary(raw["name"]) ->
        :fail

      not is_list(raw["aliases"]) ->
        :fail

      not is_binary(raw["description"]) ->
        :fail

      Map.has_key?(raw, "help_text") and not is_binary(raw["help_text"]) ->
        :fail

      not bot_ok? ->
        :fail

      raw["default_member_permission"] not in ["member", "admin", "owner"] ->
        :fail

      not is_map(raw["execution"]) or
          raw["execution"]["mode"] not in ["stateless", "stateful"] ->
        :fail

      true ->
        :ok
    end
  end

  defp normalize_options(options) do
    normalize_options(options, [])
  end

  defp normalize_options([option | rest], acc) when is_map(option) do
    name = option["name"]
    type = option["type"]

    if is_binary(name) and is_binary(type) do
      option_map =
        %{
          "name" => name,
          "type" => type
        }
        |> maybe_put("required", option, &is_boolean/1)
        |> maybe_put("description", option, &is_binary/1)
        |> maybe_put("min", option, &is_number/1)
        |> maybe_put("max", option, &is_number/1)

      normalize_options(rest, [option_map | acc])
    else
      :fail
    end
  end

  defp normalize_options([_option | _rest], _acc), do: :fail
  defp normalize_options([], acc), do: {:ok, Enum.reverse(acc)}

  defp maybe_put(map, key, source, checker) do
    value = Map.get(source, key)
    if checker.(value), do: Map.put(map, key, value), else: map
  end

  # The manifest item's execution is `{mode, stateful?}` only (contract §9.4)
  # — `schema_version` / `definition_hash` are catalog columns, not wire
  # fields, so they are dropped here (and kept out of the stored snapshot).
  defp normalize_execution(execution) do
    case execution["mode"] do
      "stateful" ->
        case parse_stateful_config(execution) do
          {:ok, config} -> {:ok, %{"mode" => "stateful", "stateful" => config}}
          :invalid -> :invalid
        end

      mode ->
        {:ok, %{"mode" => mode}}
    end
  end

  # stateful-session.ts parseStatefulConfigFromSnapshot
  defp parse_stateful_config(execution) do
    stateful = execution["stateful"]

    if is_map(stateful) do
      listen = stateful["listen_capability"]

      if stateful["mutex_scope"] == "channel" and
           is_number(stateful["default_ttl_seconds"]) and
           is_number(stateful["max_ttl_seconds"]) and
           is_map(listen) and
           is_list(listen["message_types"]) and
           Enum.all?(listen["message_types"], &is_binary/1) and
           is_boolean(listen["include_bot_messages"]) and
           is_boolean(listen["include_own_messages"]) do
        {:ok,
         %{
           "mutex_scope" => "channel",
           "default_ttl_seconds" => stateful["default_ttl_seconds"],
           "max_ttl_seconds" => stateful["max_ttl_seconds"],
           "listen_capability" => %{
             "message_types" => listen["message_types"],
             "include_bot_messages" => listen["include_bot_messages"],
             "include_own_messages" => listen["include_own_messages"]
           }
         }}
      else
        :invalid
      end
    else
      :invalid
    end
  end

  # --------------------------------------------------------------------------
  # Official catalog
  # --------------------------------------------------------------------------

  @doc """
  Official-bot active commands (BotRegistry `officialCommands`).
  """
  @spec official_catalog() :: [map()]
  def official_catalog do
    rows =
      Query.rows(
        Repo.query("""
        SELECT c.bot_command_id, c.name, c.description, c.help_text,
               c.options_json, c.default_member_permission,
               c.execution_mode, c.stateful_config_json,
               c.schema_version, c.definition_hash,
               a.bot_id, a.display_name, a.avatar_url
        FROM chat_v2.bot_commands c
        JOIN chat_v2.bot_apps a ON a.bot_id = c.bot_id
        WHERE a.visibility = 'official'
          AND a.status = 'active'
          AND c.status = 'active'
          AND c.deleted_at IS NULL
        ORDER BY c.name ASC, c.bot_command_id ASC
        """)
      )

    alias_map = aliases_by_command(Enum.map(rows, & &1["bot_command_id"]))

    Enum.map(rows, fn row ->
      %{
        "bot_command_id" => row["bot_command_id"],
        "name" => row["name"],
        "aliases" => alias_map[row["bot_command_id"]] || [],
        "description" => row["description"] || "",
        "help_text" => row["help_text"] || "",
        "bot" => %{
          "bot_id" => row["bot_id"],
          "display_name" => row["display_name"],
          "avatar_url" => row["avatar_url"]
        },
        "options" => row["options_json"] || [],
        "default_member_permission" => row["default_member_permission"],
        "execution" => execution_from_catalog(row)
      }
    end)
  end

  # Wire execution shape: `{mode, stateful?}` only (no schema_version /
  # definition_hash — those are catalog columns, not wire fields).
  defp execution_from_catalog(row) do
    base = %{"mode" => row["execution_mode"]}

    if row["execution_mode"] == "stateful" and row["stateful_config_json"] != nil do
      Map.put(base, "stateful", row["stateful_config_json"])
    else
      base
    end
  end

  @doc "Alias lists for a set of command ids, `ORDER BY alias ASC`."
  def aliases_by_command(command_ids) do
    if command_ids == [] do
      %{}
    else
      n = length(command_ids)
      placeholders = 1..n |> Enum.map(fn i -> "$" <> Integer.to_string(i) end) |> Enum.join(", ")

      rows =
        Query.rows(
          Repo.query(
            """
            SELECT bot_command_id, alias
            FROM chat_v2.bot_command_aliases
            WHERE bot_command_id IN (#{placeholders})
            ORDER BY alias ASC
            """,
            command_ids
          )
        )

      Enum.reduce(rows, %{}, fn row, acc ->
        Map.update(acc, row["bot_command_id"], [row["alias"]], fn list ->
          list ++ [row["alias"]]
        end)
      end)
    end
  end

  # --------------------------------------------------------------------------
  # Merge (official-command-manifest.ts)
  # --------------------------------------------------------------------------

  @doc """
  Read all binding rows for a channel (allowed and blocked).
  """
  def binding_rows(channel_id) do
    Query.rows(
      Repo.query(
        """
        SELECT bot_command_id, bot_id, status, command_snapshot_json, permission_override
        FROM chat_v2.channel_command_bindings
        WHERE channel_id = $1
        """,
        [channel_id]
      )
    )
  end

  @doc """
  `mergeOfficialIntoBindingRows` — explicit allowed rows (non-official bots)
  plus official catalog rows (skipping blocked ones; an existing `allowed`
  binding's permission_override applies). Returns list of
  `%{status: "allowed", snapshot: map, permission_override: nil | string}`.
  """
  def merge_official(binding_rows, official_catalog) do
    official_bot_ids = MapSet.new(Enum.map(official_catalog, & &1["bot"]["bot_id"]))

    blocked_official_ids =
      binding_rows
      |> Enum.filter(
        &(&1["status"] == "blocked" and MapSet.member?(official_bot_ids, &1["bot_id"]))
      )
      |> MapSet.new(& &1["bot_command_id"])

    allowed_overrides =
      for row <- binding_rows, row["status"] == "allowed" do
        {row["bot_command_id"], row}
      end
      |> Map.new()

    explicit =
      for row <- binding_rows,
          not MapSet.member?(official_bot_ids, row["bot_id"]),
          row["status"] == "allowed" do
        %{
          status: "allowed",
          snapshot: row["command_snapshot_json"],
          permission_override: row["permission_override"]
        }
      end

    official =
      for item <- official_catalog,
          not MapSet.member?(blocked_official_ids, item["bot_command_id"]) do
        override_row = Map.get(allowed_overrides, item["bot_command_id"])

        %{
          status: "allowed",
          snapshot: official_command_to_snapshot(item),
          permission_override: (override_row && override_row["permission_override"]) || nil
        }
      end

    explicit ++ official
  end

  @doc """
  Look up an official catalog item by id. Returns `{:ok, item}` or
  `{:error, :not_found}`.
  """
  @spec find_official_item(binary()) :: {:ok, map()} | {:error, :not_found}
  def find_official_item(bot_command_id) do
    case Enum.find(official_catalog(), &(&1["bot_command_id"] == bot_command_id)) do
      nil -> {:error, :not_found}
      item -> {:ok, item}
    end
  end

  # official-command-manifest.ts officialCommandToSnapshot
  @spec official_command_to_snapshot(map()) :: map()
  def official_command_to_snapshot(item) do
    %{
      "bot_command_id" => item["bot_command_id"],
      "name" => item["name"],
      "aliases" => item["aliases"],
      "description" => item["description"],
      "help_text" => item["help_text"],
      "bot" => item["bot"],
      "options" => item["options"],
      "default_member_permission" => item["default_member_permission"],
      "execution" => item["execution"]
    }
  end

  # --------------------------------------------------------------------------
  # Projection (command-manifest.ts)
  # --------------------------------------------------------------------------

  @doc """
  `projectCommandManifest` — project merged rows into the manifest wire
  shape. Rows are `%{status, snapshot, permission_override}`.
  """
  def project(version, rows) do
    items =
      for row <- rows, row.status == "allowed" do
        case parse_snapshot(row.snapshot) do
          {:ok, snapshot} ->
            %{
              "bot_command_id" => snapshot["bot_command_id"],
              "name" => snapshot["name"],
              "aliases" => snapshot["aliases"],
              "description" => snapshot["description"],
              "help_text" => snapshot["help_text"] || "",
              "bot" => snapshot["bot"],
              "options" => snapshot["options"],
              "execution" => snapshot["execution"],
              "effective_member_permission" =>
                normalize_permission(
                  row.permission_override,
                  snapshot["default_member_permission"]
                )
            }

          :invalid ->
            nil
        end
      end
      |> Enum.reject(&is_nil/1)

    %{"version" => version, "items" => sort_items(items)}
  end

  @doc "Append platform items (`/help` always; `/permission` for owner/admin)."
  def append_platform_items(manifest, caller_role) do
    items =
      if Enum.any?(manifest["items"], &(&1["bot_command_id"] == @platform_help_id)) do
        manifest["items"]
      else
        sort_items(manifest["items"] ++ [platform_help_item()])
      end

    if caller_role in ["owner", "admin"] do
      items =
        if Enum.any?(items, &(&1["bot_command_id"] == @platform_permission_id)) do
          items
        else
          sort_items(items ++ [platform_permission_item()])
        end

      Map.put(manifest, "items", items)
    else
      Map.put(manifest, "items", items)
    end
  end

  @doc """
  `buildMergedManifest` — binding rows + official merge + platform items.
  """
  def build_merged(channel_id, version, caller_role) do
    merged = merge_official(binding_rows(channel_id), official_catalog())
    manifest = project(version, merged)
    append_platform_items(manifest, caller_role)
  end

  @doc """
  Role filter for `GET /channels/{id}/commands`: keep items whose effective
  permission the caller's role satisfies.
  """
  def visible_to_role(manifest, caller_role) do
    items =
      Enum.filter(manifest["items"], fn item ->
        has_role_permission(caller_role, item["effective_member_permission"])
      end)

    Map.put(manifest, "items", items)
  end

  def has_role_permission(caller_role, required) do
    role_rank(caller_role) >= role_rank(required)
  end

  def role_rank("owner"), do: 3
  def role_rank("admin"), do: 2
  def role_rank("member"), do: 1
  def role_rank(_), do: 0

  defp normalize_permission(value, fallback) do
    if value in ["member", "admin", "owner"], do: value, else: fallback
  end

  # Sort by name (code-point) then bot_command_id — Elixir's `localeCompare`
  # equivalent.
  defp sort_items(items) do
    Enum.sort_by(items, fn item -> {item["name"], item["bot_command_id"]} end)
  end

  # --------------------------------------------------------------------------
  # Channel gates
  # --------------------------------------------------------------------------

  @doc """
  Manifest gate for a channel: returns `{:ok, %{version, role}}` or
  `{:error, %ApiError{}}`. Handles CHANNEL_NOT_FOUND / CHANNEL_DISSOLVED /
  non-member FORBIDDEN. DM channels resolve to `{:dm, nil}` (manifest
  `{version: 0, items: []}`).
  """
  def manifest_gate(channel_id, user_id) do
    rows =
      Query.rows(
        Repo.query(
          """
          SELECT c.status, c.kind, c.command_manifest_version,
                 cm.role
          FROM chat_v2.channels c
          LEFT JOIN chat_v2.channel_members cm
            ON cm.channel_id = c.channel_id AND cm.user_id = $2 AND cm.status = 'active'
          WHERE c.channel_id = $1
          """,
          [channel_id, user_id]
        )
      )

    case List.first(rows) do
      nil ->
        {:error, Errors.new("CHANNEL_NOT_FOUND", "channel not found")}

      row ->
        cond do
          row["status"] == "dissolved" ->
            {:error, Errors.new("CHANNEL_DISSOLVED", "channel is dissolved")}

          # Membership is checked before the DM short-circuit: a DM the caller
          # is not a member of is FORBIDDEN, not an empty manifest (parity with
          # the old Worker's getSummary → getChannelCommands gate order).
          is_nil(row["role"]) ->
            {:error, Errors.new("FORBIDDEN", "not a channel member")}

          row["kind"] == "dm" ->
            {:dm, nil}

          true ->
            {:ok, %{version: row["command_manifest_version"], role: row["role"]}}
        end
    end
  end
end
