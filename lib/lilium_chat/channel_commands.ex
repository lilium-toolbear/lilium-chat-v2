defmodule LiliumChat.ChannelCommands do
  @moduledoc """
  Channel command manifest read + binding update (contract §9.4/§9.9,
  issue #16).

  Port of the old Worker's `ChatChannel` DO methods `getChannelCommands` /
  `getCommandManifest` / `commandBindingUpdate`. The binding update persists a
  `command.binding_updated` event, bumps `channels.command_manifest_version`
  (and `updated_at`) and records the mutation in the `user_command`
  idempotency namespace.
  """

  alias LiliumChat.{
    BotCommands,
    CanonicalJSON,
    CommandManifest,
    Errors,
    Idempotency,
    Ids,
    Profiles,
    Projections,
    Query,
    Repo
  }

  @operation "bot.command_binding_update"

  # --------------------------------------------------------------------------
  # manifest reads
  # --------------------------------------------------------------------------

  @doc "`GET /channels/{id}/commands` — role-filtered manifest."
  def list(user_id, channel_id) do
    case CommandManifest.manifest_gate(channel_id, user_id) do
      {:dm, _} ->
        {:ok, %{"version" => 0, "items" => []}}

      {:error, api_error} ->
        {:error, api_error}

      {:ok, %{version: version, role: role}} ->
        manifest = CommandManifest.build_merged(channel_id, version, role)
        {:ok, CommandManifest.visible_to_role(manifest, role)}
    end
  end

  @doc "Bootstrap manifest — full (unfiltered) manifest with the same gates."
  def full(user_id, channel_id) do
    case CommandManifest.manifest_gate(channel_id, user_id) do
      {:dm, _} ->
        {:ok, %{"version" => 0, "items" => []}}

      {:error, api_error} ->
        {:error, api_error}

      {:ok, %{version: version, role: role}} ->
        {:ok, CommandManifest.build_merged(channel_id, version, role)}
    end
  end

  # --------------------------------------------------------------------------
  # binding update
  # --------------------------------------------------------------------------

  @doc """
  `PATCH /channels/{id}/commands/{bot_command_id}`.

  `attrs` keys: `:idempotency_key`, `:status` ("allowed"|"blocked"),
  `:permission_override` (nil|string), `:stateful_max_ttl_seconds` (nil|int).
  """
  def update_binding(user_id, channel_id, bot_command_id, attrs) do
    idempotency_key = Map.fetch!(attrs, :idempotency_key)
    status = Map.fetch!(attrs, :status)
    permission_override = Map.get(attrs, :permission_override)
    stateful_max_ttl = Map.get(attrs, :stateful_max_ttl_seconds)

    with :ok <- channel_kind_gate(channel_id),
         {:ok, command_snapshot} <- snapshot_for(status, bot_command_id),
         :ok <-
           official_auto_allowed?(
             status,
             bot_command_id,
             read_binding(channel_id, bot_command_id)
           ) do
      run_binding_update(
        user_id,
        channel_id,
        bot_command_id,
        status,
        permission_override,
        stateful_max_ttl,
        command_snapshot,
        idempotency_key
      )
    end
  end

  defp snapshot_for("allowed", bot_command_id) do
    case BotCommands.get_current(bot_command_id) do
      {:ok, snapshot} ->
        case CommandManifest.parse_snapshot(snapshot) do
          {:ok, parsed} ->
            {:ok, parsed}

          :invalid ->
            {:error,
             Errors.new("INVALID_MESSAGE", "command_snapshot required for allowed status")}
        end

      {:error, _} ->
        {:error, Errors.new("COMMAND_NOT_FOUND", "command not found")}
    end
  end

  defp snapshot_for(_status, _bot_command_id), do: {:ok, nil}

  defp official_auto_allowed?("allowed", bot_command_id, existing_binding) do
    case CommandManifest.find_official_item(bot_command_id) do
      {:ok, _item} ->
        if is_nil(existing_binding) or existing_binding["status"] != "blocked" do
          {:error,
           Errors.new(
             "OFFICIAL_COMMAND_AUTO_ALLOWED",
             "official commands are auto-allowed in every channel"
           )}
        else
          :ok
        end

      {:error, _} ->
        :ok
    end
  end

  defp official_auto_allowed?(_status, _id, _binding), do: :ok

  defp run_binding_update(
         user_id,
         channel_id,
         bot_command_id,
         status,
         permission_override,
         stateful_max_ttl,
         command_snapshot,
         idempotency_key
       ) do
    request_hash =
      [
        {"bot_command_id", bot_command_id},
        {"status", status},
        {"permission_override", permission_override},
        {"stateful_max_ttl_seconds", stateful_max_ttl},
        {"command_snapshot", snapshot_to_fields(command_snapshot)}
      ]
      |> CanonicalJSON.encode_and_sha256()

    case Idempotency.check("user", user_id, @operation, idempotency_key, request_hash) do
      {:cached, response} ->
        {:ok, response}

      {:conflict, api_error} ->
        {:error, api_error}

      :missing ->
        do_update_binding(
          user_id,
          channel_id,
          bot_command_id,
          status,
          permission_override,
          stateful_max_ttl,
          command_snapshot,
          idempotency_key,
          request_hash
        )
    end
  end

  defp do_update_binding(
         user_id,
         channel_id,
         bot_command_id,
         status,
         permission_override,
         stateful_max_ttl,
         command_snapshot,
         idempotency_key,
         request_hash
       ) do
    now = DateTime.utc_now()

    result =
      Repo.transaction(fn ->
        case Idempotency.check("user", user_id, @operation, idempotency_key, request_hash) do
          {:conflict, api_error} ->
            Repo.rollback({:gate, api_error})

          {:cached, response} ->
            # Idempotent replay: no re-fanout (old Worker parity).
            {response, nil}

          :missing ->
            meta =
              Query.rows(
                Repo.query(
                  "SELECT status, membership_version, command_manifest_version FROM chat_v2.channels WHERE channel_id = $1",
                  [channel_id]
                )
              )
              |> List.first()

            if is_nil(meta) do
              Repo.rollback({:gate, Errors.new("CHANNEL_NOT_FOUND", "channel not found")})
            end

            if meta["status"] == "dissolved" do
              Repo.rollback({:gate, Errors.new("CHANNEL_DISSOLVED", "channel is dissolved")})
            end

            caller_role = active_role(channel_id, user_id)

            unless caller_role in ["owner", "admin"] do
              Repo.rollback(
                {:gate, Errors.new("FORBIDDEN", "only owner/admin may update command bindings")}
              )
            end

            binding = read_binding(channel_id, bot_command_id)
            before_status = (binding && binding["status"]) || "blocked"
            before_permission = (binding && binding["permission_override"]) || nil
            before_snapshot = parse_stored_snapshot(binding && binding["command_snapshot_json"])
            next_manifest_version = meta["command_manifest_version"] + 1

            {binding_bot_id, after_snapshot, manifest_delta} =
              mutate_binding(
                channel_id,
                bot_command_id,
                status,
                permission_override,
                stateful_max_ttl,
                command_snapshot,
                before_status,
                binding,
                next_manifest_version,
                user_id,
                now
              )

            Repo.query!(
              "UPDATE chat_v2.channels SET command_manifest_version = $1, updated_at = $2 WHERE channel_id = $3",
              [next_manifest_version, now, channel_id]
            )

            binding_changes =
              build_binding_changes(
                before_status,
                status,
                before_permission,
                permission_override,
                before_snapshot,
                after_snapshot
              )

            event_id = Ids.uuidv7()

            Repo.query!(
              """
              INSERT INTO chat_v2.events (
                event_id, event_type, channel_id, actor_kind, actor_id,
                payload, membership_version_at_event, occurred_at
              ) VALUES ($1, 'command.binding_updated', $2, 'user', $3, $4, $5, $6)
              """,
              [
                event_id,
                channel_id,
                user_id,
                %{
                  "channel_id" => channel_id,
                  "bot_id" => binding_bot_id,
                  "bot_command_id" => bot_command_id,
                  "binding_changes" => binding_changes,
                  "actor_kind" => "user",
                  "actor_id" => user_id,
                  "command_manifest_delta" => manifest_delta
                },
                meta["membership_version"],
                now
              ]
            )

            response = %{
              "bot_command_id" => bot_command_id,
              "status" => status,
              "permission_override" => permission_override
            }

            Idempotency.write_completed(
              "user",
              user_id,
              @operation,
              idempotency_key,
              request_hash,
              response
            )

            # Live `command.binding_updated` fanout (contract §9.4, old
            # Worker `commandBindingUpdate`): the wire payload carries the
            # resolved `actor` and omits `channel_id` (a frame-level field).
            frame =
              Projections.build_event_frame(
                event_id,
                "command.binding_updated",
                channel_id,
                now,
                %{
                  "bot_id" => binding_bot_id,
                  "bot_command_id" => bot_command_id,
                  "binding_changes" => binding_changes,
                  "command_manifest_delta" => manifest_delta,
                  "actor" =>
                    Projections.user_summary(
                      user_id,
                      Profiles.resolve([user_id])
                    )
                }
              )
              |> Map.put("membership_version_at_event", meta["membership_version"])

            {response, frame}
        end
      end)

    case result do
      {:ok, {response, frame}} ->
        if frame do
          broadcast_binding_updated(channel_id, frame)
        end

        {:ok, response}

      {:error, {:gate, %Errors.ApiError{} = api_error}} ->
        {:error, api_error}
    end
  end

  # Fan the `command.binding_updated` frame out to live browser sockets
  # (contract §9.4 / old Worker `commandBindingUpdate` live fanout).
  defp broadcast_binding_updated(channel_id, frame) do
    topic = "channel:" <> channel_id
    LiliumChat.Observability.broadcast(LiliumChat.PubSub, topic, {:broadcast, topic, frame})
  end

  # Performs the binding row mutation; returns {binding_bot_id, after_snapshot,
  # manifest_delta}. Rolls back the transaction (`Repo.rollback/1`) on gate
  # failures.
  defp mutate_binding(
         channel_id,
         bot_command_id,
         status,
         permission_override,
         stateful_max_ttl,
         command_snapshot,
         before_status,
         binding,
         next_manifest_version,
         user_id,
         now
       ) do
    if status == "allowed" do
      case before_official_state(bot_command_id, before_status) do
        :official_blocked ->
          # Re-allow a blocked official command: drop the row so the official
          # auto-allowed state (with the requested override) applies.
          Repo.query!(
            "DELETE FROM chat_v2.channel_command_bindings WHERE channel_id = $1 AND bot_command_id = $2",
            [channel_id, bot_command_id]
          )

          {:ok, official_item} = CommandManifest.find_official_item(bot_command_id)
          snapshot = CommandManifest.official_command_to_snapshot(official_item)
          item = project_single_item(next_manifest_version, snapshot, permission_override)

          if is_nil(item) do
            Repo.rollback(
              {:gate, Errors.new("INVALID_COMMAND_OPTIONS", "invalid command snapshot")}
            )
          end

          {
            official_item["bot"]["bot_id"],
            snapshot,
            %{"op" => "upsert", "manifest_version" => next_manifest_version, "item" => item}
          }

        :not_official ->
          if is_nil(command_snapshot) do
            Repo.rollback(
              {:gate,
               Errors.new("INVALID_MESSAGE", "command_snapshot required for allowed status")}
            )
          end

          Repo.query!(
            """
            INSERT INTO chat_v2.channel_command_bindings (
              channel_id, bot_command_id, bot_id, status, permission_override,
              command_snapshot_json, stateful_max_ttl_seconds, updated_by_user_id, updated_at
            ) VALUES ($1, $2, $3, 'allowed', $4, $5, $6, $7, $8)
            ON CONFLICT (channel_id, bot_command_id) DO UPDATE SET
              bot_id = EXCLUDED.bot_id,
              status = 'allowed',
              permission_override = EXCLUDED.permission_override,
              command_snapshot_json = EXCLUDED.command_snapshot_json,
              stateful_max_ttl_seconds = EXCLUDED.stateful_max_ttl_seconds,
              updated_by_user_id = EXCLUDED.updated_by_user_id,
              updated_at = EXCLUDED.updated_at
            """,
            [
              channel_id,
              bot_command_id,
              command_snapshot["bot"]["bot_id"],
              permission_override,
              command_snapshot,
              stateful_max_ttl,
              user_id,
              now
            ]
          )

          item = project_single_item(next_manifest_version, command_snapshot, permission_override)

          if is_nil(item) do
            Repo.rollback(
              {:gate, Errors.new("INVALID_COMMAND_OPTIONS", "invalid command snapshot")}
            )
          end

          {
            command_snapshot["bot"]["bot_id"],
            command_snapshot,
            %{"op" => "upsert", "manifest_version" => next_manifest_version, "item" => item}
          }
      end
    else
      # blocked
      if is_nil(binding) do
        case CommandManifest.find_official_item(bot_command_id) do
          {:error, _} ->
            Repo.rollback({:gate, Errors.new("COMMAND_NOT_FOUND", "command binding not found")})

          {:ok, official_item} ->
            snapshot = CommandManifest.official_command_to_snapshot(official_item)

            Repo.query!(
              """
              INSERT INTO chat_v2.channel_command_bindings (
                channel_id, bot_command_id, bot_id, status, permission_override,
                command_snapshot_json, stateful_max_ttl_seconds, updated_by_user_id, updated_at
              ) VALUES ($1, $2, $3, 'blocked', $4, $5, $6, $7, $8)
              """,
              [
                channel_id,
                bot_command_id,
                official_item["bot"]["bot_id"],
                permission_override,
                snapshot,
                stateful_max_ttl,
                user_id,
                now
              ]
            )

            {official_item["bot"]["bot_id"], snapshot,
             %{"op" => "remove", "manifest_version" => next_manifest_version}}
        end
      else
        Repo.query!(
          """
          UPDATE chat_v2.channel_command_bindings
          SET status = 'blocked', permission_override = $1,
              updated_by_user_id = $2, updated_at = $3
          WHERE channel_id = $4 AND bot_command_id = $5
          """,
          [permission_override, user_id, now, channel_id, bot_command_id]
        )

        {
          binding["bot_id"],
          parse_stored_snapshot(binding["command_snapshot_json"]),
          %{"op" => "remove", "manifest_version" => next_manifest_version}
        }
      end
    end
  end

  # `:official_blocked` when the command is official and currently blocked,
  # `:not_official` otherwise (official-but-allowed is handled by the
  # auto-allow pre-check and never reaches here).
  defp before_official_state(bot_command_id, before_status) do
    if before_status == "blocked" do
      case CommandManifest.find_official_item(bot_command_id) do
        {:ok, _item} -> :official_blocked
        {:error, _} -> :not_official
      end
    else
      :not_official
    end
  end

  # The delta item for an upsert is projected from the single snapshot row
  # (the same projection the full manifest uses).
  defp project_single_item(version, snapshot, permission_override) do
    manifest =
      CommandManifest.project(version, [
        %{
          status: "allowed",
          snapshot: snapshot,
          permission_override: permission_override
        }
      ])

    List.first(manifest["items"])
  end

  defp build_binding_changes(
         before_status,
         after_status,
         before_permission,
         after_permission,
         before_snapshot,
         after_snapshot
       ) do
    changes = %{"status" => %{"before" => before_status, "after" => after_status}}

    changes =
      if before_permission != after_permission do
        Map.put(changes, "permission_override", %{
          "before" => before_permission,
          "after" => after_permission
        })
      else
        changes
      end

    if after_status == "allowed" and before_snapshot != after_snapshot do
      Map.put(changes, "command_snapshot_json", %{
        "before" => before_snapshot,
        "after" => after_snapshot
      })
    else
      changes
    end
  end

  # --------------------------------------------------------------------------
  # helpers
  # --------------------------------------------------------------------------

  defp channel_kind_gate(channel_id) do
    rows =
      Query.rows(
        Repo.query("SELECT kind FROM chat_v2.channels WHERE channel_id = $1", [channel_id])
      )

    case List.first(rows) do
      nil ->
        {:error, Errors.new("CHANNEL_NOT_FOUND", "channel not found")}

      row ->
        if row["kind"] == "dm" do
          {:error,
           Errors.new("UNSUPPORTED_CHANNEL_KIND", "operation not supported for DM channels")}
        else
          :ok
        end
    end
  end

  defp active_role(channel_id, user_id) do
    Query.rows(
      Repo.query(
        """
        SELECT role FROM chat_v2.channel_members
        WHERE channel_id = $1 AND user_id = $2 AND status = 'active'
        """,
        [channel_id, user_id]
      )
    )
    |> List.first()
    |> case do
      nil -> nil
      row -> row["role"]
    end
  end

  defp read_binding(channel_id, bot_command_id) do
    Query.rows(
      Repo.query(
        """
        SELECT bot_id, status, permission_override, command_snapshot_json
        FROM chat_v2.channel_command_bindings
        WHERE channel_id = $1 AND bot_command_id = $2
        """,
        [channel_id, bot_command_id]
      )
    )
    |> List.first()
  end

  defp parse_stored_snapshot(nil), do: nil

  defp parse_stored_snapshot(raw) do
    case CommandManifest.parse_snapshot(raw) do
      {:ok, snapshot} -> snapshot
      :invalid -> nil
    end
  end

  # Snapshot map → canonical field list in the exact key order the old
  # Worker's `parseCommandBindingSnapshot` emits (a fixed object-literal
  # order, unlike Elixir map iteration) so the request hash matches the
  # old Worker's JSON.stringify byte-for-byte.
  @snapshot_keys [
    "bot_command_id",
    "name",
    "aliases",
    "description",
    "help_text",
    "bot",
    "options",
    "default_member_permission",
    "execution"
  ]
  @bot_keys ["bot_id", "display_name", "avatar_url"]
  @option_keys ["name", "type", "required", "description", "min", "max"]
  @listen_keys ["message_types", "include_bot_messages", "include_own_messages"]

  defp snapshot_to_fields(nil), do: nil

  defp snapshot_to_fields(snapshot) do
    for key <- @snapshot_keys, Map.has_key?(snapshot, key), into: [] do
      {key, snapshot_field(snapshot, key)}
    end
  end

  defp snapshot_field(snapshot, "bot"), do: ordered_fields(snapshot["bot"], @bot_keys)

  defp snapshot_field(snapshot, "options"),
    do: Enum.map(snapshot["options"] || [], &ordered_fields(&1, @option_keys))

  defp snapshot_field(snapshot, "execution"), do: execution_to_fields(snapshot["execution"])

  defp snapshot_field(snapshot, "aliases"),
    do: Enum.filter(snapshot["aliases"] || [], &is_binary/1)

  defp snapshot_field(snapshot, key), do: snapshot[key]

  defp execution_to_fields(execution) do
    fields = ordered_fields(execution, ["mode"])

    fields =
      if execution["mode"] == "stateful" and is_map(execution["stateful"]) do
        stateful = execution["stateful"]
        fields ++ [{"stateful", stateful_to_fields(stateful)}]
      else
        fields
      end

    fields =
      if is_number(execution["schema_version"]) do
        fields ++ [{"schema_version", execution["schema_version"]}]
      else
        fields
      end

    if is_binary(execution["definition_hash"]) do
      fields ++ [{"definition_hash", execution["definition_hash"]}]
    else
      fields
    end
  end

  defp stateful_to_fields(stateful) do
    ordered_fields(stateful, ["mutex_scope", "default_ttl_seconds", "max_ttl_seconds"]) ++
      listen_patch(stateful)
  end

  defp listen_patch(stateful) do
    listen = stateful["listen_capability"]

    if is_map(listen) do
      [
        {"listen_capability", ordered_fields(listen, @listen_keys)}
      ]
    else
      []
    end
  end

  defp ordered_fields(map, keys) do
    for key <- keys, Map.has_key?(map, key), into: [] do
      {key, map[key]}
    end
  end
end
