defmodule LiliumChat.CommandInvoke do
  @moduledoc """
  `command.invoke` write path (contract §9.5 / §9.12, issue #20).

  Port of the old Worker's `handlers/command.ts` `handleCommandInvoke` +
  `statefulCommandInvoke`, revised to the v2.31 contract deltas:

  * **correctness source is the current BotRegistry catalog** (contract
    §9.5): the current `bot_commands` row is fetched and validated
    (disabled/deleted → `BOT_COMMAND_DISABLED`), and the *current*
    definition validates `options` — not the channel binding snapshot. A
    definition drift refreshes the binding snapshot inside the commit txn.
  * `invoked_name` that is not this command's canonical name or alias **as
    the channel sees it** (the binding snapshot / official item names,
    contract §9.5) → `COMMAND_NOT_FOUND` (the old Worker's
    `COMMAND_OPTIONS_INVALID` is superseded by the v2.31 contract).
  * options-validation failures → `INVALID_COMMAND_OPTIONS` (contract §11;
    the old Worker's `COMMAND_OPTIONS_INVALID` was removed from the v2.31
    normative table).
  * blocked binding / not bound + not official → `COMMAND_NOT_FOUND`
    (contract §11; the old Worker's 403 `COMMAND_NOT_ALLOWED` was removed
    from the v2.31 normative table).
  * `command_manifest_version` is optional on the wire (the contract §9.5
    example payload omits it): when present (a number ≥ 0) it is checked
    against `channels.command_manifest_version` and a mismatch →
    `COMMAND_MANIFEST_VERSION_STALE`; when absent the staleness check is
    skipped (the catalog is always the correctness source).
  * bot offline precheck → `BOT_OFFLINE` (`retryable=true`), nothing is
    persisted (contract §9.5).
  * stateful commands bootstrap a `stateful_command_sessions` row
    (`status='starting'`) and push a `session.start` frame to the bot;
    `session.start_ack` activates it (`StatefulSessions.handle_start_ack/3`).
    The start frame is pushed best-effort through the live Bot connection
    (the `BOT_OFFLINE` precheck guarantees the bot is connected at commit
    time); a bot that never acks is force-closed by the 30 s start timeout
    (`start_timeout`). The old Worker's durable session-start outbox is not
    ported (session frames are live-pushed in v2, issue #19 convention).
  * platform `/help` and `/permission` are platform shortcuts handled
    inline (no Bot Gateway delivery): a sync bot message +
    `status='completed'` invocation.

  Platform command ids (old Worker `platform-commands.ts`):
  `/help` = `00000000-0000-7000-8000-000000000700`,
  `/permission` = `00000000-0000-7000-8000-000000000708`.
  """

  alias LiliumChat.{
    BotConnection,
    BotDelivery,
    BotGateway,
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

  @operation "command.invoke"

  # Old Worker `SESSION_START_TIMEOUT_MS`.
  @start_timeout_ms 30_000

  # Platform command identity (contract §9.2 / platform-commands.ts).
  @platform_bot_id "00000000-0000-7000-8000-000000000600"
  @platform_help_id "00000000-0000-7000-8000-000000000700"
  @platform_permission_id "00000000-0000-7000-8000-000000000708"
  @platform_help_name "help"
  @platform_permission_name "permission"

  @doc "The session start timeout (ms) — old Worker `SESSION_START_TIMEOUT_MS`."
  def start_timeout_ms(), do: @start_timeout_ms

  @doc "The platform `/help` bot_command_id."
  def platform_help_id(), do: @platform_help_id

  @doc "The platform `/permission` bot_command_id."
  def platform_permission_id(), do: @platform_permission_id

  # --------------------------------------------------------------------------
  # entry
  # --------------------------------------------------------------------------

  @doc """
  Handle one `command.invoke` (contract §9.5). `input`:
  `%{user_id, command_id, payload}` where `payload` carries
  `bot_command_id`, optional `invoked_name` / `command_manifest_version` /
  `reply_to_message_id`, and `options` (map of name → `{type, value}`).

  Returns `{result, new_seq}` following the writer convention: `result` is
  `%{kind: :invoked, response: ..., event_frames: [...], ...}` (or
  `%{kind: :cached, response: ...}` for an idempotent replay, or
  `%{kind: :error, error: ...}`). Gate failures raise `%Errors.ApiError{}`
  before any event id is allocated.
  """
  def invoke(channel_id, seq, input) do
    user_id = input[:user_id]
    command_id = input[:command_id]
    payload = input[:payload] || %{}

    parsed = parse_payload(payload)
    request_hash = request_hash(channel_id, parsed)

    # Cached replay short-circuit (old Worker `readUserCompletedIdempotency`):
    # same `command_id` + same body → replay the stored ack without touching
    # the catalog or the bot.
    case Idempotency.check("user", user_id, @operation, command_id, request_hash) do
      {:cached, response} ->
        {%{kind: :cached, response: response}, seq}

      _ ->
        do_invoke(channel_id, seq, user_id, command_id, parsed, request_hash)
    end
  end

  defp do_invoke(channel_id, seq, user_id, command_id, parsed, request_hash) do
    meta = channel_meta!(channel_id)
    role = active_role!(channel_id, user_id)
    check_manifest_version(meta, parsed)

    cond do
      parsed.bot_command_id == @platform_help_id ->
        handle_help(channel_id, seq, user_id, command_id, parsed, meta, role, request_hash)

      parsed.bot_command_id == @platform_permission_id ->
        handle_permission(channel_id, seq, user_id, command_id, parsed, meta, role, request_hash)

      true ->
        handle_command_invoke(
          channel_id,
          seq,
          user_id,
          command_id,
          parsed,
          meta,
          role,
          request_hash
        )
    end
  end

  # ------------------------------------------------------------------ gates

  defp parse_payload(payload) when is_map(payload) do
    bot_command_id = payload["bot_command_id"]

    unless is_binary(bot_command_id) and bot_command_id != "" do
      fail("bot_command_id is required")
    end

    invoked_name =
      case payload["invoked_name"] do
        value when is_binary(value) -> value
        _ -> ""
      end

    manifest_version =
      case payload["command_manifest_version"] do
        value when is_number(value) and value >= 0 -> trunc(value)
        _ -> nil
      end

    options = payload["options"]

    unless is_map(options) do
      fail("options must be an object")
    end

    options =
      Map.new(options, fn {name, raw} ->
        unless is_map(raw) do
          fail("option #{name} must be an object")
        end

        type = raw["type"]

        unless is_binary(type) and type != "" do
          fail("option #{name}.type is required")
        end

        {name, %{"type" => type, "value" => raw["value"]}}
      end)

    reply_to =
      case payload["reply_to_message_id"] do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end

    %{
      bot_command_id: bot_command_id,
      invoked_name: invoked_name,
      command_manifest_version: manifest_version,
      options: options,
      reply_to_message_id: reply_to
    }
  end

  defp parse_payload(_), do: fail("invalid payload")

  defp fail(message) do
    raise Errors.new("INVALID_MESSAGE", message)
  end

  # Old Worker `JSON.stringify({channel_id, bot_command_id, invoked_name,
  # command_manifest_version, options, reply_to_message_id})`. The options
  # object is canonicalized with sorted keys (v2-internal consistency; the
  # old Worker's wire-insertion order is not preserved through the Elixir
  # JSON decoder).
  defp request_hash(channel_id, parsed) do
    [
      {"channel_id", channel_id},
      {"bot_command_id", parsed.bot_command_id},
      {"invoked_name", parsed.invoked_name},
      {"command_manifest_version", parsed.command_manifest_version},
      {"options", sorted_options(parsed.options)},
      {"reply_to_message_id", parsed.reply_to_message_id}
    ]
    |> CanonicalJSON.encode_and_sha256()
  end

  defp sorted_options(options) do
    for {name, raw} <- Enum.sort_by(options, &elem(&1, 0)) do
      {name, [{"type", raw["type"]}, {"value", raw["value"]}]}
    end
  end

  defp channel_meta!(channel_id) do
    meta =
      Query.rows(
        Repo.query(
          """
          SELECT channel_id, kind, status, membership_version, command_manifest_version
          FROM chat_v2.channels WHERE channel_id = $1
          """,
          [channel_id],
          type: true
        )
      )
      |> List.first()

    if is_nil(meta) do
      raise Errors.new("CHANNEL_NOT_FOUND", "channel not found")
    end

    if meta["kind"] == "dm" do
      raise Errors.new("UNSUPPORTED_CHANNEL_KIND", "operation not supported for DM channels")
    end

    if meta["status"] == "dissolved" do
      raise Errors.new("CHANNEL_DISSOLVED", "channel is dissolved")
    end

    meta
  end

  defp active_role!(channel_id, user_id) do
    role =
      Query.rows(
        Repo.query(
          """
          SELECT role FROM chat_v2.channel_members
          WHERE channel_id = $1 AND user_id = $2 AND status = 'active'
          """,
          [channel_id, user_id],
          type: true
        )
      )
      |> List.first()
      |> case do
        nil -> nil
        row -> row["role"]
      end

    unless is_binary(role) do
      raise Errors.new("FORBIDDEN", "not a channel member")
    end

    role
  end

  # Optional `command_manifest_version` staleness check (contract §9.5
  # example payload omits the field → the check is skipped).
  defp check_manifest_version(meta, parsed) do
    case parsed.command_manifest_version do
      nil ->
        :ok

      version ->
        current = meta["command_manifest_version"] || 0

        if version != current do
          raise Errors.new(
                  "COMMAND_MANIFEST_VERSION_STALE",
                  "command manifest version is stale (current #{current})"
                )
        end

        :ok
    end
  end

  # ------------------------------------------------------------------ target
  #
  # Channel visibility (blocked / absent) + the current-catalog correctness
  # source. Returns the target map:
  #
  #     %{
  #       bot_id,                # the bot that owns the command in this channel
  #       snapshot,              # parsed binding snapshot or official snapshot
  #       permission_override,   # binding permission_override (nil when official)
  #       stateful_max_ttl,      # binding stateful_max_ttl_seconds (nil when official)
  #       current                # current bot_commands row (correctness source)
  #     }

  defp resolve_target(channel_id, bot_command_id) do
    binding =
      Query.rows(
        Repo.query(
          """
          SELECT bot_id, status, permission_override, command_snapshot_json,
                 stateful_max_ttl_seconds
          FROM chat_v2.channel_command_bindings
          WHERE channel_id = $1 AND bot_command_id = $2
          """,
          [channel_id, bot_command_id],
          type: true
        )
      )
      |> List.first()

    cond do
      is_map(binding) and binding["status"] == "blocked" ->
        not_allowed()

      is_map(binding) and binding["status"] == "allowed" ->
        snapshot =
          case CommandManifest.parse_snapshot(binding["command_snapshot_json"]) do
            {:ok, snapshot} -> snapshot
            :invalid -> not_allowed()
          end

        current = current_catalog!(bot_command_id)

        %{
          bot_id: binding["bot_id"],
          snapshot: snapshot,
          permission_override: binding["permission_override"],
          stateful_max_ttl: binding["stateful_max_ttl_seconds"],
          current: current
        }

      true ->
        case CommandManifest.find_official_item(bot_command_id) do
          {:ok, item} ->
            %{
              bot_id: item["bot"]["bot_id"],
              snapshot: CommandManifest.official_command_to_snapshot(item),
              permission_override: nil,
              stateful_max_ttl: nil,
              current: current_catalog!(bot_command_id)
            }

          {:error, :not_found} ->
            not_allowed()
        end
    end
  end

  defp not_allowed() do
    raise Errors.new("COMMAND_NOT_FOUND", "This slash command is not allowed in this channel.")
  end

  # The v2.31 correctness source: the current `bot_commands` row (with
  # `schema_version` / `definition_hash` / current `options`), disabled or
  # deleted → `BOT_COMMAND_DISABLED`.
  defp current_catalog!(bot_command_id) do
    rows =
      Query.rows(
        Repo.query(
          """
          SELECT c.bot_command_id, c.name, c.description, c.help_text,
                 c.options_json, c.default_member_permission,
                 c.execution_mode, c.stateful_config_json,
                 c.schema_version, c.definition_hash, c.deleted_at, c.status
          FROM chat_v2.bot_commands c
          WHERE c.bot_command_id = $1
          """,
          [bot_command_id],
          type: true
        )
      )

    case List.first(rows) do
      nil ->
        raise Errors.new("BOT_COMMAND_DISABLED", "command disabled or deleted")

      row ->
        if is_nil(row["deleted_at"]) and row["status"] == "active" do
          aliases =
            Query.rows(
              Repo.query(
                "SELECT alias FROM chat_v2.bot_command_aliases WHERE bot_command_id = $1 ORDER BY alias ASC",
                [bot_command_id],
                type: true
              )
            )
            |> Enum.map(& &1["alias"])

          %{
            "bot_command_id" => row["bot_command_id"],
            "name" => row["name"],
            "aliases" => aliases,
            "description" => row["description"] || "",
            "help_text" => row["help_text"] || "",
            "options" => row["options_json"] || [],
            "default_member_permission" => row["default_member_permission"],
            "execution_mode" => row["execution_mode"],
            "stateful_config" => row["stateful_config_json"],
            "schema_version" => row["schema_version"],
            "definition_hash" => row["definition_hash"]
          }
        else
          raise Errors.new("BOT_COMMAND_DISABLED", "command disabled or deleted")
        end
    end
  end

  # Options validation against the CURRENT definition (old Worker
  # `validateInvokeOptions`, contract §9.5 "用当前定义校验 options").
  defp validate_options!(provided, schema_options) do
    schema_by_name = Map.new(schema_options, &{&1["name"], &1})

    for option <- schema_options do
      if option["required"] == true and not Map.has_key?(provided, option["name"]) do
        raise Errors.new("INVALID_COMMAND_OPTIONS", "missing required option: #{option["name"]}")
      end
    end

    Enum.each(provided, fn {name, given} ->
      schema = Map.get(schema_by_name, name)

      if is_nil(schema) do
        raise Errors.new("INVALID_COMMAND_OPTIONS", "unknown option: #{name}")
      end

      if schema["type"] != given["type"] do
        raise Errors.new("INVALID_COMMAND_OPTIONS", "option #{name} type mismatch")
      end

      validate_option_value!(name, schema, given["value"])
    end)

    :ok
  end

  defp validate_option_value!(name, schema, value) do
    case schema["type"] do
      "string" ->
        unless is_binary(value) do
          raise Errors.new("INVALID_COMMAND_OPTIONS", "option #{name} must be string")
        end

      "integer" ->
        # JS `Number.isInteger`: integral floats (3.0) count as integers.
        unless is_integer(value) or (is_float(value) and value == trunc(value)) do
          raise Errors.new("INVALID_COMMAND_OPTIONS", "option #{name} must be integer")
        end

        if is_number(schema["min"]) and value < schema["min"] do
          raise Errors.new("INVALID_COMMAND_OPTIONS", "option #{name} below min")
        end

        if is_number(schema["max"]) and value > schema["max"] do
          raise Errors.new("INVALID_COMMAND_OPTIONS", "option #{name} above max")
        end

      "number" ->
        unless is_number(value) do
          raise Errors.new("INVALID_COMMAND_OPTIONS", "option #{name} must be number")
        end

        if is_number(schema["min"]) and value < schema["min"] do
          raise Errors.new("INVALID_COMMAND_OPTIONS", "option #{name} below min")
        end

        if is_number(schema["max"]) and value > schema["max"] do
          raise Errors.new("INVALID_COMMAND_OPTIONS", "option #{name} above max")
        end

      "boolean" ->
        unless is_boolean(value) do
          raise Errors.new("INVALID_COMMAND_OPTIONS", "option #{name} must be boolean")
        end

      _ ->
        # user / channel / role — a non-empty string reference
        unless is_binary(value) and value != "" do
          raise Errors.new("INVALID_COMMAND_OPTIONS", "option #{name} must be non-empty string")
        end
    end
  end

  # `invoked_name` must be this command's canonical name or alias in the
  # channel (contract §9.5 → `COMMAND_NOT_FOUND`).
  defp validate_invoked_name!(invoked_name, name, aliases) do
    if invoked_name != "" and invoked_name not in [name | aliases] do
      raise Errors.new(
              "COMMAND_NOT_FOUND",
              "invoked_name does not match the command canonical name or aliases"
            )
    end

    :ok
  end

  defp role_rank("owner"), do: 3
  defp role_rank("admin"), do: 2
  defp role_rank("member"), do: 1
  defp role_rank(_), do: 0

  defp check_permission!(role, required) do
    unless role_rank(role) >= role_rank(required) do
      raise Errors.new(
              "COMMAND_PERMISSION_DENIED",
              "You do not have permission to use this command."
            )
    end

    :ok
  end

  defp precheck_online!(bot_id) do
    unless BotConnection.online?(bot_id) do
      raise Errors.new("BOT_OFFLINE", "The bot is currently offline.")
    end

    :ok
  end

  # ------------------------------------------------------------- reply ctx

  defp resolve_reply_context(_channel_id, nil), do: %{reply_to: nil, reply_snapshot: nil}

  defp resolve_reply_context(channel_id, reply_to_message_id) do
    row =
      Query.rows(
        Repo.query(
          """
          SELECT message_id, sender_kind, sender_user_id, status
          FROM chat_v2.messages
          WHERE message_id = $1 AND channel_id = $2
          """,
          [reply_to_message_id, channel_id],
          type: true
        )
      )
      |> List.first()

    if is_nil(row) or row["status"] not in ["normal", "edited"] do
      raise Errors.new("MESSAGE_NOT_FOUND", "reply target not found")
    end

    reply_snapshot = reply_snapshot_for(channel_id, reply_to_message_id)
    %{reply_to: reply_to_message_id, reply_snapshot: reply_snapshot}
  end

  # Reply snapshot in the established v2 shape (same as `message.send`'s
  # `reply_snapshot_for`, contract §3.5): `{message_id, sender_display_name,
  # text_preview, status}` — the Browser reply chip reads these keys.
  defp reply_snapshot_for(channel_id, reply_to_message_id) do
    rows =
      Query.rows(
        Repo.query(
          """
          SELECT message_id, status, type, text, sender_kind, sender_user_id, sender_bot_id
          FROM chat_v2.messages
          WHERE message_id = $1 AND channel_id = $2
          """,
          [reply_to_message_id, channel_id],
          type: true
        )
      )

    case List.first(rows) do
      nil ->
        nil

      row ->
        %{
          "message_id" => row["message_id"],
          "sender_display_name" => reply_sender_display(row),
          "text_preview" => reply_text_preview(row),
          "status" => row["status"]
        }
    end
  end

  defp reply_sender_display(row) do
    case row["sender_kind"] do
      "user" ->
        profiles = Profiles.resolve([row["sender_user_id"]])

        (profiles[row["sender_user_id"]] && profiles[row["sender_user_id"]][:display_name]) ||
          Projections.fallback_display_name(row["sender_user_id"])

      _ ->
        row["sender_bot_id"] || "系统"
    end
  end

  defp reply_text_preview(row) do
    cond do
      row["status"] in ["deleted", "recalled"] ->
        ""

      # Contract §3.5 (v2.31): image/sticker reply targets clear `text_preview`
      # (no `[图片]`/`[表情]` placeholder; v2.31 emits no `media_preview`).
      row["type"] in ["image", "sticker"] ->
        ""

      true ->
        (row["text"] || "") |> String.slice(0, 80)
    end
  end

  # ------------------------------------------------------------- invocation

  # The user-visible slash-command invocation message (old Worker
  # `insertUserCommandInvocationMessage`): a `sender_kind=user` text message
  # whose projection carries `command_invocation`. Returns the live message
  # + the `message.created` event frame.
  defp insert_invocation_message(
         channel_id,
         seq,
         user_id,
         command_id,
         parsed,
         invoked_name,
         actor,
         meta,
         reply_context
       ) do
    now = DateTime.utc_now()
    now_ms = DateTime.to_unix(now, :millisecond)
    message_id = Ids.uuidv7(now_ms)
    {event_id, new_seq} = Ids.monotonic_uuidv7(seq, now_ms)

    invocation_json = %{
      "bot_command_id" => parsed.bot_command_id,
      "invoked_name" => invoked_name,
      "options" => parsed.options
    }

    row = %{
      "message_id" => message_id,
      "command_id" => command_id,
      "channel_id" => channel_id,
      "sender_kind" => "user",
      "sender_user_id" => user_id,
      "sender_bot_id" => nil,
      "type" => "text",
      "format" => "plain",
      "status" => "normal",
      "text" => display_text(invoked_name, parsed.options),
      "reply_to" => reply_context.reply_to,
      "reply_snapshot_json" => reply_context.reply_snapshot,
      "invocation_json" => invocation_json,
      "components_json" => [],
      "stream_state" => "none",
      "created_at" => now,
      "updated_at" => now,
      "edited_at" => nil,
      "deleted_at" => nil,
      "deleted_by" => nil,
      "recalled_at" => nil
    }

    live_message =
      Projections.project_message(row, %{user_id => actor}, %{
        attachments: [],
        mentions: [],
        sticker: nil,
        components: [],
        command_invocation: invocation_json,
        reply_target_status:
          reply_context.reply_snapshot && reply_context.reply_snapshot["status"]
      })

    event_frame =
      Projections.build_event_frame(event_id, "message.created", channel_id, now, %{
        "message" => live_message
      })
      |> Map.put("membership_version_at_event", meta["membership_version"])

    persisted_payload = build_message_persisted_payload(row)

    Repo.query!(
      """
      INSERT INTO chat_v2.messages (
        message_id, command_id, dedupe_principal_key, channel_id, sender_kind,
        sender_user_id, sender_bot_id, type, format, status, text, reply_to,
        reply_snapshot_json, invocation_json, components_json, stream_state,
        created_at, updated_at
      ) VALUES ($1, $2, $3, $4, 'user', $5, NULL, 'text', 'plain', 'normal',
                $6, $7, $8, $9, $10, 'none', $11, $11)
      """,
      [
        message_id,
        command_id,
        "user:" <> user_id,
        channel_id,
        user_id,
        row["text"],
        row["reply_to"],
        row["reply_snapshot_json"],
        invocation_json,
        [],
        now
      ],
      type: true
    )

    insert_event(event_id, "message.created", channel_id, persisted_payload, meta, now)

    %{
      message_id: message_id,
      event_id: event_id,
      live_message: live_message,
      event_frame: event_frame,
      new_seq: new_seq
    }
  end

  # Discord-like display: `/name` plus non-empty option values in stable key
  # order (old Worker `buildInvocationDisplayText`).
  defp display_text(invoked_name, options) do
    base = "/" <> invoked_name

    parts =
      for {_key, raw} <- Enum.sort_by(options, &elem(&1, 0)) do
        format_option_value(raw["value"])
      end
      |> Enum.reject(&(&1 == ""))

    if parts == [] do
      base
    else
      base <> " " <> Enum.join(parts, " ")
    end
  end

  defp format_option_value(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed != "", do: trimmed, else: ""
  end

  defp format_option_value(value) when is_number(value) or is_boolean(value),
    do: to_string(value)

  defp format_option_value(_), do: ""

  # Persisted `message.*` event shape (old Worker `buildMessageLifecyclePayload`):
  # the message object is wrapped under `"message"` (stable refs only — no
  # UserSummary; the read path re-projects from the current row).
  defp build_message_persisted_payload(row) do
    %{
      "message" => %{
        "message_id" => row["message_id"],
        "command_id" => row["command_id"],
        "channel_id" => row["channel_id"],
        "sender_kind" => row["sender_kind"],
        "sender_user_id" => row["sender_user_id"],
        "sender_bot_id" => row["sender_bot_id"],
        "status" => row["status"],
        "created_at" => Projections.format_ts(row["created_at"]),
        "updated_at" => Projections.format_ts(row["updated_at"]),
        "edited_at" => nil,
        "deleted_at" => nil,
        "deleted_by" => nil,
        "recalled_at" => nil,
        "stream_state" => "none",
        "reply_to" => row["reply_to"],
        "reply_snapshot_json" => row["reply_snapshot_json"],
        "type" => row["type"],
        "format" => row["format"],
        "text" => row["text"],
        "invocation_json" => row["invocation_json"]
      }
    }
  end

  # ---------------------------------------------------------- stateless flow

  defp handle_command_invoke(
         channel_id,
         seq,
         user_id,
         command_id,
         parsed,
         meta,
         role,
         request_hash
       ) do
    target = resolve_target(channel_id, parsed.bot_command_id)
    current = target.current

    check_permission!(role, target.permission_override || current["default_member_permission"])
    validate_options!(parsed.options, current["options"])

    # `invoked_name` must be the command's canonical name or alias **as the
    # channel sees it** (contract §9.5: "该 channel `channel_command_names`
    # 中此 bot_command_id 的 canonical name 或 alias") — the binding
    # snapshot / official item names, not the current catalog (an alias
    # still visible in the channel remains invocable even if the catalog
    # renamed it).
    validate_invoked_name!(
      parsed.invoked_name,
      target.snapshot["name"],
      target.snapshot["aliases"] || []
    )

    if current["execution_mode"] == "stateful" do
      precheck_online!(target.bot_id)
      start_session(channel_id, seq, user_id, command_id, parsed, meta, target, request_hash)
    else
      precheck_online!(target.bot_id)

      reply_context = resolve_reply_context(channel_id, parsed.reply_to_message_id)

      invoke_stateless(
        channel_id,
        seq,
        user_id,
        command_id,
        parsed,
        meta,
        target,
        reply_context,
        request_hash
      )
    end
  end

  defp invoke_stateless(
         channel_id,
         seq,
         user_id,
         command_id,
         parsed,
         meta,
         target,
         reply_context,
         request_hash
       ) do
    current = target.current
    invoked_name = if parsed.invoked_name != "", do: parsed.invoked_name, else: current["name"]

    actor = actor_for(user_id)
    now = DateTime.utc_now()
    now_ms = DateTime.to_unix(now, :millisecond)
    invocation_id = Ids.uuidv7(now_ms)

    result =
      Repo.transaction(fn ->
        case Idempotency.check("user", user_id, @operation, command_id, request_hash) do
          {:conflict, api_error} ->
            Repo.rollback(%{kind: :error, error: api_error})

          {:cached, response} ->
            %{kind: :cached, response: response}

          :missing ->
            # The invocation message (message.created) is allocated first,
            # then the `command.invoked` event (old Worker id order:
            # nowMs, nowMs+2) — all inside the txn so a conflict leaves no
            # orphan artifacts.
            invocation_message =
              insert_invocation_message(
                channel_id,
                seq,
                user_id,
                command_id,
                parsed,
                invoked_name,
                actor,
                meta,
                reply_context
              )

            {event_id, new_seq} =
              Ids.monotonic_uuidv7(invocation_message.new_seq, now_ms + 2)

            persisted = %{
              "invocation" => %{
                "invocation_id" => invocation_id,
                "status" => "pending",
                "created_at" => Projections.format_ts(now)
              },
              "command_id" => command_id,
              "actor_user_id" => user_id,
              "command_name" => current["name"],
              "invoked_name" => invoked_name
            }

            # Definition drift: refresh the binding snapshot from the current
            # catalog (contract §9.5). Only an `allowed` non-official binding
            # stores a snapshot; official items derive from the catalog live.
            refresh_binding_snapshot(channel_id, parsed.bot_command_id, target, current)

            insert_event(event_id, "command.invoked", channel_id, persisted, meta, now)

            {:ok, _} =
              BotDelivery.commit_invocation(%{
                channel_id: channel_id,
                bot_id: target.bot_id,
                invoker_user_id: user_id,
                command_id: command_id,
                bot_command_id: parsed.bot_command_id,
                command_name: current["name"],
                invoked_name: invoked_name,
                schema_version: current["schema_version"] || 1,
                definition_hash:
                  current["definition_hash"] || "snapshot:#{parsed.bot_command_id}",
                options: parsed.options,
                invocation_id: invocation_id
              })

            response = %{
              "channel_id" => channel_id,
              "invocation_id" => invocation_id,
              "event_id" => event_id
            }

            Idempotency.write_completed(
              "user",
              user_id,
              @operation,
              command_id,
              request_hash,
              response
            )

            %{
              kind: :invoked,
              response: response,
              event_frames: [
                invocation_message.event_frame,
                Projections.build_event_frame(event_id, "command.invoked", channel_id, now, %{
                  "invocation" => persisted["invocation"],
                  "command_id" => command_id,
                  "command_name" => invoked_name,
                  "actor" => actor
                })
                |> Map.put("membership_version_at_event", meta["membership_version"])
              ],
              new_seq: new_seq
            }
        end
      end)

    case result do
      {:ok, %{kind: :cached, response: response}} ->
        {%{kind: :cached, response: response}, seq}

      {:ok, payload} ->
        {Map.delete(payload, :new_seq), payload[:new_seq]}

      {:error, %{kind: :error, error: api_error}} ->
        raise api_error
    end
  end

  # Refresh an `allowed` binding's stored snapshot when the current catalog
  # definition drifted (contract §9.5 "definition_hash drift 用当前定义校验
  # options 并刷新 binding snapshot"). The stored v2 snapshot carries no
  # hash, so drift = the parsed snapshot's name/options/execution differ
  # from the current catalog row. Official items have no stored row (they
  # derive live from the catalog) and are never rewritten.
  defp refresh_binding_snapshot(channel_id, bot_command_id, target, current) do
    snapshot = target.snapshot

    binding =
      Query.rows(
        Repo.query(
          "SELECT 1 AS x FROM chat_v2.channel_command_bindings WHERE channel_id = $1 AND bot_command_id = $2 AND status = 'allowed'",
          [channel_id, bot_command_id],
          type: true
        )
      )

    if is_map(snapshot) and binding != [] do
      drifted? =
        snapshot["name"] != current["name"] or
          snapshot["options"] != current["options"] or
          snapshot["execution"] != execution_from_current(current)

      if drifted? do
        fresh = binding_snapshot_from_current(current, target.bot_id, snapshot)

        Repo.query!(
          """
          UPDATE chat_v2.channel_command_bindings
          SET command_snapshot_json = $3, updated_at = $4
          WHERE channel_id = $1 AND bot_command_id = $2
          """,
          [channel_id, bot_command_id, fresh, DateTime.utc_now()],
          type: true
        )
      end
    end

    :ok
  end

  defp execution_from_current(current) do
    base = %{"mode" => current["execution_mode"]}

    if current["execution_mode"] == "stateful" and is_map(current["stateful_config"]) do
      Map.put(base, "stateful", current["stateful_config"])
    else
      base
    end
  end

  # Fresh binding snapshot built from the current catalog row. The bot
  # summary is carried over from the existing snapshot (the catalog query
  # deliberately does not join `bot_apps` here).
  defp binding_snapshot_from_current(current, bot_id, existing_snapshot) do
    %{
      "bot_command_id" => current["bot_command_id"],
      "name" => current["name"],
      "aliases" => current["aliases"],
      "description" => current["description"],
      "help_text" => current["help_text"],
      "bot" => existing_snapshot["bot"] || %{"bot_id" => bot_id},
      "options" => current["options"],
      "default_member_permission" => current["default_member_permission"],
      "execution" => execution_from_current(current)
    }
  end

  defp actor_for(user_id) do
    profiles = Profiles.resolve([user_id])
    Projections.user_summary(user_id, profiles)
  end

  defp insert_event(event_id, event_type, channel_id, payload, meta, now) do
    Repo.query!(
      """
      INSERT INTO chat_v2.events (
        event_id, event_type, channel_id, actor_kind, actor_id,
        payload, membership_version_at_event, occurred_at
      ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
      """,
      [
        event_id,
        event_type,
        channel_id,
        "user",
        payload["actor_user_id"] || "system",
        payload,
        meta["membership_version"],
        now
      ],
      type: true
    )
  end

  # ---------------------------------------------------------- platform /help

  # Platform `/help` shortcut (contract §9.5): no Bot Gateway delivery; a
  # sync bot message (markdown, platform bot identity) + a `completed`
  # invocation. The ack payload carries `message_id` + the full Browser
  # message projection (message.send ack shape).
  defp handle_help(channel_id, seq, user_id, command_id, parsed, meta, role, request_hash) do
    manifest = CommandManifest.build_merged(channel_id, meta["command_manifest_version"], role)
    command_option = option_string(parsed.options, "command")
    help_text = build_help_text(manifest["items"], command_option)
    actor = actor_for(user_id)
    now = DateTime.utc_now()
    now_ms = DateTime.to_unix(now, :millisecond)
    invocation_id = Ids.uuidv7(now_ms)

    result =
      Repo.transaction(fn ->
        case Idempotency.check("user", user_id, @operation, command_id, request_hash) do
          {:conflict, api_error} ->
            Repo.rollback(%{kind: :error, error: api_error})

          {:cached, response} ->
            %{kind: :cached, response: response}

          :missing ->
            invocation_message =
              insert_invocation_message(
                channel_id,
                seq,
                user_id,
                command_id,
                parsed,
                @platform_help_name,
                actor,
                meta,
                %{reply_to: nil, reply_snapshot: nil}
              )

            {message_id, event_id, live_message, reply_frame, new_seq} =
              insert_platform_reply(
                channel_id,
                invocation_message.new_seq,
                command_id,
                user_id,
                now,
                now_ms,
                meta,
                help_text,
                "markdown",
                invocation_message.message_id,
                @platform_help_name
              )

            insert_completed_invocation(
              channel_id,
              invocation_id,
              command_id,
              user_id,
              @platform_help_id,
              @platform_help_name,
              parsed,
              now
            )

            response = %{
              "channel_id" => channel_id,
              "invocation_id" => invocation_id,
              "event_id" => event_id,
              "message_id" => message_id,
              "message" => live_message
            }

            Idempotency.write_completed(
              "user",
              user_id,
              @operation,
              command_id,
              request_hash,
              response
            )

            %{
              kind: :invoked,
              response: response,
              event_frames: [invocation_message.event_frame, reply_frame],
              new_seq: new_seq
            }
        end
      end)

    case result do
      {:ok, %{kind: :cached, response: response}} ->
        {%{kind: :cached, response: response}, seq}

      {:ok, payload} ->
        {Map.delete(payload, :new_seq), payload[:new_seq]}

      {:error, %{kind: :error, error: api_error}} ->
        raise api_error
    end
  end

  # The sync platform reply bot message (`message.created`), shared by
  # `/help` (markdown) and `/permission` (unsafe-markdown). Returns
  # `{message_id, event_id, live_message, event_frame, new_seq}`.
  defp insert_platform_reply(
         channel_id,
         seq,
         command_id,
         user_id,
         now,
         now_ms,
         meta,
         text,
         format,
         reply_to_message_id,
         invoked_name
       ) do
    message_id = Ids.uuidv7(now_ms + 1)
    {event_id, new_seq} = Ids.monotonic_uuidv7(seq, now_ms + 2)
    bot = CommandManifest.platform_bot()

    reply_snapshot =
      if reply_to_message_id do
        %{
          "message_id" => reply_to_message_id,
          "sender" => %{"kind" => "user", "user" => actor_for(user_id)},
          "type" => "text",
          "format" => "plain",
          "status" => "normal",
          "text" => "/" <> invoked_name,
          "stream_state" => "none"
        }
      end

    row = %{
      "message_id" => message_id,
      "command_id" => command_id,
      "channel_id" => channel_id,
      "sender_kind" => "bot",
      "sender_user_id" => nil,
      "sender_bot_id" => bot["bot_id"],
      "type" => "text",
      "format" => format,
      "status" => "normal",
      "text" => text,
      "reply_to" => reply_to_message_id,
      "reply_snapshot_json" => reply_snapshot,
      "invocation_json" => nil,
      "components_json" => [],
      "stream_state" => "none",
      "created_at" => now,
      "updated_at" => now,
      "edited_at" => nil,
      "deleted_at" => nil,
      "deleted_by" => nil,
      "recalled_at" => nil
    }

    live_message =
      Projections.project_message(row, %{}, %{
        attachments: [],
        mentions: [],
        sticker: nil,
        components: [],
        command_invocation: nil,
        reply_target_status: nil,
        bot_summary: bot
      })

    event_frame =
      Projections.build_event_frame(event_id, "message.created", channel_id, now, %{
        "message" => live_message
      })
      |> Map.put("membership_version_at_event", meta["membership_version"])

    Repo.query!(
      """
      INSERT INTO chat_v2.messages (
        message_id, command_id, dedupe_principal_key, channel_id, sender_kind,
        sender_user_id, sender_bot_id, type, format, status, text, reply_to,
        reply_snapshot_json, components_json, stream_state, created_at, updated_at
      ) VALUES ($1, $2, $3, $4, 'bot', NULL, $5, 'text', $6, 'normal',
                $7, $8, $9, $10, 'none', $11, $11)
      """,
      [
        message_id,
        command_id,
        "bot:" <> bot["bot_id"],
        channel_id,
        bot["bot_id"],
        format,
        text,
        row["reply_to"],
        row["reply_snapshot_json"],
        [],
        now
      ],
      type: true
    )

    insert_event(
      event_id,
      "message.created",
      channel_id,
      build_message_persisted_payload(row),
      meta,
      now
    )

    {message_id, event_id, live_message, event_frame, new_seq}
  end

  defp insert_completed_invocation(
         channel_id,
         invocation_id,
         command_id,
         user_id,
         bot_command_id,
         command_name,
         parsed,
         now
       ) do
    Repo.query!(
      """
      INSERT INTO chat_v2.command_invocations (
        invocation_id, channel_id, command_id, invoker_user_id, bot_id,
        bot_command_id, command_name, invoked_name, command_schema_version,
        command_definition_hash, options_json, status, created_at, updated_at, completed_at
      ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 1, $9, $10, 'completed', $11, $11, $11)
      """,
      [
        invocation_id,
        channel_id,
        command_id,
        user_id,
        @platform_bot_id,
        bot_command_id,
        command_name,
        command_name,
        "platform:" <> bot_command_id,
        parsed.options,
        now
      ],
      type: true
    )
  end

  defp option_string(options, name) do
    case options[name] do
      %{"value" => value} when is_binary(value) -> value
      _ -> ""
    end
  end

  # Old Worker `buildPlatformHelpText` — grouped by bot display_name, chips
  # `` [`/name`](/command:name) — description ``.
  defp build_help_text(items, command_option) do
    if command_option != "" do
      needle = command_option |> String.trim() |> String.downcase()

      match =
        Enum.find(items, fn item ->
          String.downcase(item["name"]) == needle or
            Enum.any?(item["aliases"] || [], &(String.downcase(&1) == needle))
        end)

      case match do
        nil ->
          "未知命令: " <> command_option

        item ->
          if is_binary(item["help_text"]) and item["help_text"] != "" do
            item["help_text"]
          else
            item["description"] || ""
          end
      end
    else
      groups =
        items
        |> Enum.group_by(& &1["bot"]["display_name"])
        |> Enum.sort_by(&elem(&1, 0))

      lines =
        for {bot_name, commands} <- groups do
          command_lines =
            commands
            |> Enum.sort_by(& &1["name"])
            |> Enum.map(fn command ->
              "- " <> chip(command["name"]) <> " — " <> (command["description"] || "")
            end)

          ["**" <> bot_name <> "**"] ++ command_lines ++ [""]
        end
        |> List.flatten()
        |> Enum.join("\n")
        |> String.trim()

      if lines == "" do
        "当前频道没有可用命令。"
      else
        lines
      end
    end
  end

  defp chip(command_name) do
    "[" <> "`/" <> command_name <> "`" <> "](/command:" <> command_name <> ")"
  end

  # ------------------------------------------------------ platform /permission

  # Platform `/permission` shortcut (contract §9.4 / old Worker
  # `handlePlatformPermissionInvoke`): owner/admin inline binding mutation.
  defp handle_permission(
         channel_id,
         seq,
         user_id,
         command_id,
         parsed,
         meta,
         role,
         request_hash
       ) do
    if role not in ["owner", "admin"] do
      raise Errors.new(
              "COMMAND_PERMISSION_DENIED",
              "You do not have permission to use this command."
            )
    end

    binding_rows = CommandManifest.binding_rows(channel_id)
    official_catalog = CommandManifest.official_catalog()
    manageable = manageable_commands(binding_rows, official_catalog)

    command_option = option_string(parsed.options, "command") |> String.trim()
    action_option = option_string(parsed.options, "action") |> String.trim() |> String.downcase()

    {reply_text, mutation} =
      if command_option == "" do
        {permission_list_text(manageable), nil}
      else
        if action_option not in ["on", "off"] do
          {"用法: /permission <命令> on|off", nil}
        else
          case resolve_manageable(manageable, command_option) do
            nil ->
              {"未知命令: " <> command_option, nil}

            resolved ->
              if action_option == "on" and
                   Enum.any?(official_catalog, &(&1["bot_command_id"] == resolved.bot_command_id)) and
                   not Enum.any?(
                     binding_rows,
                     &(&1["bot_command_id"] == resolved.bot_command_id and
                         &1["status"] == "blocked")
                   ) do
                raise Errors.new(
                        "OFFICIAL_COMMAND_AUTO_ALLOWED",
                        "official commands are auto-allowed in every channel"
                      )
              end

              status = if action_option == "on", do: "allowed", else: "blocked"
              {permission_mutation_text(resolved.name, status == "allowed"), {resolved, status}}
          end
        end
      end

    actor = actor_for(user_id)
    now = DateTime.utc_now()
    now_ms = DateTime.to_unix(now, :millisecond)
    invocation_id = Ids.uuidv7(now_ms)

    result =
      Repo.transaction(fn ->
        case Idempotency.check("user", user_id, @operation, command_id, request_hash) do
          {:conflict, api_error} ->
            Repo.rollback(%{kind: :error, error: api_error})

          {:cached, response} ->
            %{kind: :cached, response: response}

          :missing ->
            binding_event =
              case mutation do
                nil ->
                  {[], seq}

                {resolved, status} ->
                  apply_permission_mutation(
                    channel_id,
                    user_id,
                    resolved,
                    status,
                    binding_rows,
                    official_catalog,
                    meta,
                    now,
                    now_ms,
                    seq
                  )
              end

            {binding_frames, seq_after_binding} = binding_event

            invocation_message =
              insert_invocation_message(
                channel_id,
                seq_after_binding,
                user_id,
                command_id,
                parsed,
                @platform_permission_name,
                actor,
                meta,
                %{reply_to: nil, reply_snapshot: nil}
              )

            {message_id, event_id, live_message, reply_frame, new_seq} =
              insert_platform_reply(
                channel_id,
                invocation_message.new_seq,
                command_id,
                user_id,
                now,
                now_ms,
                meta,
                reply_text,
                "unsafe-markdown",
                invocation_message.message_id,
                @platform_permission_name
              )

            insert_completed_invocation(
              channel_id,
              invocation_id,
              command_id,
              user_id,
              @platform_permission_id,
              @platform_permission_name,
              parsed,
              now
            )

            response = %{
              "channel_id" => channel_id,
              "invocation_id" => invocation_id,
              "event_id" => event_id,
              "message_id" => message_id,
              "message" => live_message
            }

            Idempotency.write_completed(
              "user",
              user_id,
              @operation,
              command_id,
              request_hash,
              response
            )

            %{
              kind: :invoked,
              response: response,
              event_frames: binding_frames ++ [invocation_message.event_frame, reply_frame],
              new_seq: new_seq
            }
        end
      end)

    case result do
      {:ok, %{kind: :cached, response: response}} ->
        {%{kind: :cached, response: response}, seq}

      {:ok, payload} ->
        {Map.delete(payload, :new_seq), payload[:new_seq]}
    end
  end

  defp manageable_commands(binding_rows, official_catalog) do
    official_bot_ids = MapSet.new(Enum.map(official_catalog, & &1["bot"]["bot_id"]))

    blocked_official_ids =
      binding_rows
      |> Enum.filter(
        &(&1["status"] == "blocked" and MapSet.member?(official_bot_ids, &1["bot_id"]))
      )
      |> MapSet.new(& &1["bot_command_id"])

    from_official =
      for item <- official_catalog do
        %{
          bot_command_id: item["bot_command_id"],
          name: item["name"],
          aliases: item["aliases"] || [],
          enabled: not MapSet.member?(blocked_official_ids, item["bot_command_id"])
        }
      end

    from_bindings =
      for row <- binding_rows, not MapSet.member?(official_bot_ids, row["bot_id"]) do
        case CommandManifest.parse_snapshot(row["command_snapshot_json"]) do
          {:ok, snapshot} ->
            %{
              bot_command_id: snapshot["bot_command_id"],
              name: snapshot["name"],
              aliases: snapshot["aliases"] || [],
              enabled: row["status"] == "allowed"
            }

          :invalid ->
            nil
        end
      end
      |> Enum.reject(&is_nil/1)

    (from_official ++ from_bindings)
    |> Enum.sort_by(& &1.name)
  end

  defp resolve_manageable(commands, command_spec) do
    needle = command_spec |> String.trim() |> String.trim_leading("/") |> String.downcase()

    if needle == "" do
      nil
    else
      Enum.find(commands, fn item ->
        String.downcase(item.name) == needle or
          Enum.any?(item.aliases, &(String.downcase(&1) == needle))
      end)
    end
  end

  defp permission_list_text(commands) do
    enabled = Enum.filter(commands, & &1.enabled)
    disabled = Enum.filter(commands, &(not &1.enabled))

    format_lines = fn items ->
      if items == [] do
        "- 无"
      else
        Enum.map_join(items, "\n", &("- " <> chip(&1.name)))
      end
    end

    [
      "## 当前频道命令权限",
      "",
      "**当前可用（#{length(enabled)}）**",
      format_lines.(enabled),
      "",
      "**当前已关闭（#{length(disabled)}）**",
      format_lines.(disabled)
    ]
    |> Enum.join("\n")
  end

  defp permission_mutation_text(command_name, enabled) do
    status = if enabled, do: "开启", else: "关闭"
    "当前频道已将 " <> chip(command_name) <> " #{status}。"
  end

  # Port of the old Worker `/permission` binding mutation: returns
  # `{event_frames, new_seq}` — the `command.binding_updated` frame(s)
  # (empty when no mutation).
  defp apply_permission_mutation(
         channel_id,
         user_id,
         resolved,
         status,
         binding_rows,
         official_catalog,
         meta,
         now,
         now_ms,
         seq
       ) do
    bot_command_id = resolved.bot_command_id
    binding = Enum.find(binding_rows, &(&1["bot_command_id"] == bot_command_id))
    before_status = (binding && binding["status"]) || "blocked"
    before_permission = (binding && binding["permission_override"]) || nil
    before_snapshot = (binding && binding["command_snapshot_json"]) || nil
    next_version = meta["command_manifest_version"] + 1

    official_item =
      Enum.find(official_catalog, &(&1["bot_command_id"] == bot_command_id))

    {binding_bot_id, manifest_delta, snapshot_after} =
      cond do
        status == "allowed" and is_map(official_item) and before_status == "blocked" ->
          # Re-allow a blocked official command: drop the row so the
          # official auto-allowed state (with the requested override) applies.
          Repo.query!(
            "DELETE FROM chat_v2.channel_command_bindings WHERE channel_id = $1 AND bot_command_id = $2",
            [channel_id, bot_command_id]
          )

          snapshot = CommandManifest.official_command_to_snapshot(official_item)
          item = project_delta_item(next_version, snapshot, before_permission)

          {
            official_item["bot"]["bot_id"],
            %{"op" => "upsert", "manifest_version" => next_version, "item" => item},
            snapshot
          }

        status == "allowed" ->
          snapshot =
            case binding && binding["command_snapshot_json"] do
              raw when is_map(raw) -> raw
              _ -> CommandManifest.official_command_to_snapshot(official_item)
            end

          bot_id = (binding && binding["bot_id"]) || snapshot["bot"]["bot_id"]

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
              bot_id,
              before_permission,
              snapshot,
              nil,
              user_id,
              now
            ],
            type: true
          )

          item = project_delta_item(next_version, snapshot, before_permission)

          {bot_id, %{"op" => "upsert", "manifest_version" => next_version, "item" => item},
           snapshot}

        status == "blocked" and is_nil(binding) ->
          if is_nil(official_item) do
            raise Errors.new("COMMAND_NOT_FOUND", "command binding not found")
          end

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
              before_permission,
              snapshot,
              nil,
              user_id,
              now
            ],
            type: true
          )

          {official_item["bot"]["bot_id"],
           %{"op" => "remove", "manifest_version" => next_version}, snapshot}

        true ->
          Repo.query!(
            """
            UPDATE chat_v2.channel_command_bindings
            SET status = 'blocked', permission_override = $1,
                updated_by_user_id = $2, updated_at = $3
            WHERE channel_id = $4 AND bot_command_id = $5
            """,
            [before_permission, user_id, now, channel_id, bot_command_id],
            type: true
          )

          {
            binding["bot_id"],
            %{"op" => "remove", "manifest_version" => next_version},
            before_snapshot
          }
      end

    Repo.query!(
      "UPDATE chat_v2.channels SET command_manifest_version = $1, updated_at = $2 WHERE channel_id = $3",
      [next_version, now, channel_id],
      type: true
    )

    binding_changes = %{"status" => %{"before" => before_status, "after" => status}}

    binding_changes =
      if status == "allowed" and before_snapshot != snapshot_after do
        Map.put(binding_changes, "command_snapshot_json", %{
          "before" => before_snapshot,
          "after" => snapshot_after
        })
      else
        binding_changes
      end

    {event_id, new_seq} = Ids.monotonic_uuidv7(seq, now_ms)

    payload = %{
      "channel_id" => channel_id,
      "bot_id" => binding_bot_id,
      "bot_command_id" => bot_command_id,
      "binding_changes" => binding_changes,
      "actor_kind" => "user",
      "actor_id" => user_id,
      "command_manifest_delta" => manifest_delta
    }

    Repo.query!(
      """
      INSERT INTO chat_v2.events (
        event_id, event_type, channel_id, actor_kind, actor_id,
        payload, membership_version_at_event, occurred_at
      ) VALUES ($1, 'command.binding_updated', $2, 'user', $3, $4, $5, $6)
      """,
      [event_id, channel_id, user_id, payload, meta["membership_version"], now],
      type: true
    )

    {[
       Projections.build_event_frame(
         event_id,
         "command.binding_updated",
         channel_id,
         now,
         Projections.resolve_actor(payload, Profiles.resolve([user_id]))
       )
     ], new_seq}
  end

  defp project_delta_item(version, snapshot, permission_override) do
    manifest =
      CommandManifest.project(version, [
        %{status: "allowed", snapshot: snapshot, permission_override: permission_override}
      ])

    List.first(manifest["items"])
  end

  # ------------------------------------------------------------- stateful

  # Port of the old Worker `statefulCommandInvoke`: insert the session row
  # (`status='starting'`), arm the start timeout, push `session.start`, and
  # return the invoke ack (`{channel_id, invocation_id, session_id, event_id}`).
  defp start_session(channel_id, seq, user_id, command_id, parsed, meta, target, request_hash) do
    current = target.current

    stateful_config =
      case parse_stateful_config(current) do
        nil -> raise Errors.new("INVALID_COMMAND_OPTIONS", "invalid stateful command snapshot")
        config -> config
      end

    listen_rules = %{
      "message_types" => stateful_config.listen_capability.message_types,
      "include_bot_messages" => stateful_config.listen_capability.include_bot_messages,
      "include_own_messages" => stateful_config.listen_capability.include_own_messages
    }

    ttl_seconds = resolve_ttl_seconds(stateful_config, target.stateful_max_ttl)
    now = DateTime.utc_now()
    now_ms = DateTime.to_unix(now, :millisecond)
    expires_at = DateTime.add(now, ttl_seconds, :second)
    session_id = Ids.uuidv7(now_ms)
    invocation_id = Ids.uuidv7(now_ms + 1)
    invoked_name = if parsed.invoked_name != "", do: parsed.invoked_name, else: current["name"]
    actor = actor_for(user_id)

    start_frame = %{
      "type" => "session.start",
      "api_version" => BotGateway.api_version(),
      "session_id" => session_id,
      "channel_id" => channel_id,
      "bot_command" => %{
        "bot_command_id" => parsed.bot_command_id,
        "name" => current["name"],
        "invoked_name" => invoked_name,
        "schema_version" => current["schema_version"] || 1,
        "definition_hash" => current["definition_hash"] || "snapshot:#{parsed.bot_command_id}"
      },
      "invoker" => actor,
      "options" => parsed.options,
      "listen_rules" => listen_rules,
      "input_seq_start" => 1,
      "expires_at" => Projections.format_ts(expires_at)
    }

    reply_context = resolve_reply_context(channel_id, parsed.reply_to_message_id)

    # Idempotency conflict first (old Worker: the in-txn idempotency check
    # runs before the busy check; a cached replay already short-circuited in
    # `invoke/3`).
    case Idempotency.check("user", user_id, @operation, command_id, request_hash) do
      {:conflict, api_error} ->
        raise api_error

      _ ->
        # Close an active session whose session_control pin is missing
        # (old Worker `closeOrphanStatefulSessionWithoutControlPin`).
        seq = close_orphan_without_control_pin(channel_id, seq)

        # Busy pre-check (the per-channel writer serializes commands, so the
        # check outside the txn is race-free). Old Worker
        # `persistStatefulInvokeFailureArtifacts`: a busy channel still
        # records the invocation message + a `command.failed` event, then
        # surfaces `STATEFUL_SESSION_BUSY` (the artifacts are committed +
        # broadcast).
        case active_session_row(channel_id) do
          busy when is_map(busy) ->
            persist_busy_artifacts(
              channel_id,
              seq,
              user_id,
              command_id,
              parsed,
              invoked_name,
              actor,
              meta,
              reply_context
            )

          nil ->
            start_timeout_at = DateTime.add(now, @start_timeout_ms, :millisecond)

            result =
              Repo.transaction(fn ->
                case Idempotency.check("user", user_id, @operation, command_id, request_hash) do
                  {:conflict, api_error} ->
                    Repo.rollback(%{kind: :error, error: api_error})

                  {:cached, response} ->
                    %{kind: :cached, response: response}

                  :missing ->
                    invocation_message =
                      insert_invocation_message(
                        channel_id,
                        seq,
                        user_id,
                        command_id,
                        parsed,
                        invoked_name,
                        actor,
                        meta,
                        reply_context
                      )

                    Repo.query!(
                      """
                      INSERT INTO chat_v2.stateful_command_sessions (
                        session_id, channel_id, bot_id, bot_command_id, invocation_id,
                        started_by_user_id, status, listen_rules_json, input_next_seq,
                        input_last_acked_seq, effect_last_acked_seq, started_at,
                        expires_at, summary_json
                      ) VALUES ($1, $2, $3, $4, $5, $6, 'starting', $7, 1, 0, 0,
                                $8, $9, $10)
                      """,
                      [
                        session_id,
                        channel_id,
                        target.bot_id,
                        parsed.bot_command_id,
                        invocation_id,
                        user_id,
                        listen_rules,
                        now,
                        expires_at,
                        %{"command_name" => current["name"]}
                      ],
                      type: true
                    )

                    response = %{
                      "channel_id" => channel_id,
                      "invocation_id" => invocation_id,
                      "session_id" => session_id,
                      "event_id" => invocation_message.event_id
                    }

                    Idempotency.write_completed(
                      "user",
                      user_id,
                      @operation,
                      command_id,
                      request_hash,
                      response
                    )

                    %{
                      kind: :session_started,
                      response: response,
                      event_frames: [invocation_message.event_frame],
                      push_frames: [start_frame],
                      push_bot_id: target.bot_id,
                      arm_start_timeout: %{session_id: session_id, at: start_timeout_at},
                      new_seq: invocation_message.new_seq
                    }
                end
              end)

            case result do
              {:ok, %{kind: :cached, response: response}} ->
                {%{kind: :cached, response: response}, seq}

              {:ok, payload} ->
                {Map.delete(payload, :new_seq), payload[:new_seq]}

              {:error, %{kind: :error, error: api_error}} ->
                raise api_error
            end
        end
    end
  end

  # Busy-channel failure artifacts (old Worker
  # `persistStatefulInvokeFailureArtifacts`): the invocation message + a
  # `command.failed` event are committed and broadcast, then the caller
  # surfaces `STATEFUL_SESSION_BUSY`. Both are deduped on retry (old Worker
  # `userCommandInvocationMessageExists` / `commandFailedEventExists`).
  defp persist_busy_artifacts(
         channel_id,
         seq,
         user_id,
         command_id,
         parsed,
         invoked_name,
         actor,
         meta,
         reply_context
       ) do
    now = DateTime.utc_now()
    now_ms = DateTime.to_unix(now, :millisecond)

    # The invocation message + the `command.failed` event commit as ONE unit
    # (old Worker `persistStatefulInvokeFailureArtifacts` — both artifacts or
    # neither).
    Repo.transaction(fn ->
      invocation_message =
        if invocation_message_exists?(channel_id, user_id, command_id) do
          nil
        else
          insert_invocation_message(
            channel_id,
            seq,
            user_id,
            command_id,
            parsed,
            invoked_name,
            actor,
            meta,
            reply_context
          )
        end

      frames =
        if invocation_message do
          [invocation_message.event_frame]
        else
          []
        end

      {seq2, failed_frame} =
        if command_failed_exists?(channel_id, command_id) do
          {seq, nil}
        else
          {failed_event_id, seq1} =
            Ids.monotonic_uuidv7(
              if(invocation_message, do: invocation_message.new_seq, else: seq),
              now_ms + 2
            )

          failed_payload = %{
            "command_id" => command_id,
            "error_code" => "STATEFUL_SESSION_BUSY",
            "error_message" => "Another stateful command session is active in this channel.",
            "retryable" => false
          }

          insert_event(failed_event_id, "command.failed", channel_id, failed_payload, meta, now)

          failed_frame =
            Projections.build_event_frame(
              failed_event_id,
              "command.failed",
              channel_id,
              now,
              failed_payload
            )
            |> Map.put("membership_version_at_event", meta["membership_version"])

          {seq1, failed_frame}
        end

      {frames ++ List.wrap(failed_frame), seq2}
    end)
    |> case do
      {:ok, {frames, seq2}} ->
        error =
          Errors.new(
            "STATEFUL_SESSION_BUSY",
            "Another stateful command session is active in this channel."
          )

        {%{kind: :session_busy, error: error, event_frames: frames}, seq2}
    end
  end

  defp invocation_message_exists?(channel_id, user_id, command_id) do
    Query.rows(
      Repo.query(
        """
        SELECT 1 AS x FROM chat_v2.messages
        WHERE channel_id = $1 AND command_id = $2 AND dedupe_principal_key = $3
        LIMIT 1
        """,
        [channel_id, command_id, "user:" <> user_id],
        type: true
      )
    ) != []
  end

  defp command_failed_exists?(channel_id, command_id) do
    Query.rows(
      Repo.query(
        """
        SELECT 1 AS x FROM chat_v2.events
        WHERE channel_id = $1 AND event_type = 'command.failed'
          AND payload ->> 'command_id' = $2
        LIMIT 1
        """,
        [channel_id, command_id],
        type: true
      )
    ) != []
  end

  # Old Worker `parseStatefulConfigFromSnapshot` — validates the shape before
  # indexing (a malformed catalog row must yield `nil`, never a KeyError that
  # would crash the writer).
  defp parse_stateful_config(current) do
    case current["stateful_config"] do
      stateful when is_map(stateful) ->
        listen = stateful["listen_capability"]

        with true <- stateful["mutex_scope"] == "channel",
             true <- is_number(stateful["default_ttl_seconds"]),
             true <- is_number(stateful["max_ttl_seconds"]),
             true <- is_map(listen),
             true <-
               is_list(listen["message_types"]) and
                 Enum.all?(listen["message_types"], &is_binary/1),
             true <- is_boolean(listen["include_bot_messages"]),
             true <- is_boolean(listen["include_own_messages"]) do
          %{
            mutex_scope: "channel",
            default_ttl_seconds: stateful["default_ttl_seconds"],
            max_ttl_seconds: stateful["max_ttl_seconds"],
            listen_capability: %{
              message_types: listen["message_types"],
              include_bot_messages: listen["include_bot_messages"],
              include_own_messages: listen["include_own_messages"]
            }
          }
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # Old Worker `resolveSessionTtlSeconds`:
  # `Math.min(default_ttl, bindingMaxTtl ?? max_ttl, max_ttl)`.
  defp resolve_ttl_seconds(config, binding_max_ttl) do
    cap = binding_max_ttl || config.max_ttl_seconds
    Enum.min([config.default_ttl_seconds, cap, config.max_ttl_seconds])
  end

  defp active_session_row(channel_id) do
    Query.rows(
      Repo.query(
        """
        SELECT session_id, bot_command_id, status, started_by_user_id, started_at,
               expires_at, summary_json
        FROM chat_v2.stateful_command_sessions
        WHERE channel_id = $1 AND status IN ('starting', 'active', 'suspended', 'closing')
        LIMIT 1
        """,
        [channel_id],
        type: true
      )
    )
    |> List.first()
  end

  # Old Worker `closeOrphanStatefulSessionWithoutControlPin`: an active
  # (non-starting) session whose session_control pin is missing is closed
  # (`orphaned`) before the busy check. Returns the advanced seq.
  defp close_orphan_without_control_pin(channel_id, seq) do
    case active_session_row(channel_id) do
      %{"status" => status, "session_id" => session_id} when status != "starting" ->
        pin =
          Query.rows(
            Repo.query(
              """
              SELECT 1 AS x FROM chat_v2.channel_pins
              WHERE channel_id = $1 AND pin_kind = 'session_control' AND session_id = $2
              """,
              [channel_id, session_id],
              type: true
            )
          )

        if pin == [] do
          case LiliumChat.StatefulSessions.close(channel_id, seq, session_id, "orphaned") do
            {_result, new_seq} -> new_seq
          end
        else
          seq
        end

      _ ->
        seq
    end
  end
end
