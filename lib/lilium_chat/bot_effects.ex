defmodule LiliumChat.BotEffects do
  @moduledoc """
  Bot effect validation, idempotency, and application (contract §9.7.3 /
  §9.14, issues #17 → #19).

  A `delivery_result` carries up to 20 effects. `validate/2` checks the
  wire shape (types, fields, components, duplicates); `apply_effects/5`
  applies a whole batch **in one PG transaction** (old Worker
  `applyValidatedEffects` parity): per effect, idempotency on the
  `(channel_id, bot_id, client_effect_id)` key via the `bot_effect`
  namespace of `chat_v2.idempotency` (spec D10) — same key + same body
  replays the stored `effect_result`, same key + different body is
  `BOT_EFFECT_CONFLICT` (the whole batch rolls back) — otherwise the
  applier runs (messages + `components_json`, attachment links, pin
  rows, streams, `message.created` / `message.updated` events).

  After the batch commits, `finalizeAppliedEffects` parity: listen inputs
  are enqueued for the channel's active stateful session and
  `message.stream_started` live frames are broadcast. The caller is the
  per-channel writer (`LiliumChat.Channel`), which broadcasts the
  returned `event_frames` and owns the `seq` the batch advanced.
  """

  alias LiliumChat.{
    BotGateway,
    CanonicalJSON,
    ChannelPins,
    Components,
    Errors,
    Ids,
    Projections,
    Query,
    Repo,
    StatefulSessions,
    Stream
  }

  # Idempotency rows expire after 24h (housekeeping GCs them, spec D10).
  @idem_ttl_ms 86_400_000

  @allowed_formats ["plain", "markdown", "unsafe-markdown"]
  @pin_kinds ["bot_control", "announcement"]

  # ------------------------------------------------------------- validation

  defmodule ValidationError do
    @moduledoc false
    defexception [:message]
  end

  @doc """
  Validate a `delivery_result` effect list.

  `opts`: `:is_official` (bool) — the `unsafe-markdown` format is
  official-bots-only (contract §9.7.3).

  Returns `{:ok, effects}` (the same maps) or
  `{:error, %Errors.ApiError{}}` (`BOT_EFFECT_INVALID`).
  """
  def validate(effects, opts \\ []) when is_list(effects) do
    is_official = Keyword.get(opts, :is_official, false)

    try do
      Enum.reduce(effects, %{}, fn effect, seen ->
        unless is_map(effect) do
          invalid!("effect must be an object")
        end

        client_effect_id =
          case effect["client_effect_id"] do
            value when is_binary(value) and value != "" -> value
            _ -> invalid!("client_effect_id required")
          end

        if Map.get(seen, client_effect_id) do
          invalid!("duplicate client_effect_id in batch")
        end

        case effect["type"] do
          type when is_binary(type) ->
            cond do
              # Old Worker `validateGatewayEffects` rejects the stream
              # effects BEFORE the allowlist with the dedicated message.
              type in BotGateway.rejected_effect_types() ->
                invalid!("#{type} must use Stream WS")

              type in BotGateway.main_gateway_effect_types() ->
                validate_type(type, effect, is_official)

              true ->
                invalid!("unsupported effect type: #{type}")
            end

          _ ->
            invalid!("effect.type required")
        end

        Map.put(seen, client_effect_id, true)
      end)

      {:ok, effects}
    rescue
      e in [ValidationError] ->
        {:error, Errors.new("BOT_EFFECT_INVALID", e.message)}
    end
  end

  defp invalid!(message), do: raise(ValidationError, message: message)

  defp validate_type("send_message", effect, is_official) do
    message = require_message(effect)

    unless message["type"] in ["text", "image"] do
      invalid!("only text and image messages are supported")
    end

    unless is_binary(message["text"]) do
      invalid!("send_message.message.text required")
    end

    validate_message_fields(message, is_official, allow_attachments: true)

    if message["type"] == "text" and non_empty_list?(message["attachment_ids"]) do
      invalid!("attachment_ids not allowed for text messages")
    end

    if message["type"] == "image" and not non_empty_list?(message["attachment_ids"]) do
      invalid!("image message requires attachment_ids")
    end
  end

  defp validate_type("update_message", effect, _is_official) do
    unless non_empty_binary?(effect["message_id"]) do
      invalid!("update_message.message_id required")
    end

    message =
      case effect["message"] do
        %{} = message -> message
        _ -> invalid!("update_message.message must be an object")
      end

    if Map.has_key?(message, "text") and not is_binary(message["text"]) do
      invalid!("update_message.message.text must be a string")
    end

    if Map.has_key?(message, "components") do
      unless is_list(message["components"]) do
        invalid!("update_message.message.components must be an array")
      end

      validate_components(message["components"])
    end

    if Map.has_key?(message, "attachment_ids") and
         not (is_list(message["attachment_ids"]) and
                Enum.all?(message["attachment_ids"], &is_binary/1)) do
      invalid!("update_message.message.attachment_ids must be an array of strings")
    end

    unless patch_present?(message) do
      invalid!("update_message requires text, components, and/or attachment_ids")
    end

    :ok
  end

  defp validate_type("disable_components", effect, _is_official) do
    unless non_empty_binary?(effect["message_id"]) do
      invalid!("disable_components.message_id required")
    end

    ids = effect["component_ids"]

    unless is_list(ids) and ids != [] and Enum.all?(ids, &is_binary/1) do
      invalid!("disable_components.component_ids required")
    end

    :ok
  end

  defp validate_type("start_stream", effect, is_official) do
    message = require_message(effect)

    unless message["type"] == "text" do
      invalid!("only text messages are supported")
    end

    validate_message_fields(message, is_official, allow_attachments: false)

    unless is_nil(message["components"]) or message["components"] == [] do
      invalid!("stream messages must not include components")
    end

    unless is_nil(message["attachment_ids"]) or message["attachment_ids"] == [] do
      invalid!("attachment_ids not supported for start_stream")
    end

    :ok
  end

  defp validate_type("set_channel_pin", effect, _is_official) do
    unless effect["pin_kind"] in @pin_kinds do
      invalid!("invalid pin_kind for set_channel_pin")
    end

    unless is_map(effect["message"]) do
      invalid!("set_channel_pin.message required")
    end

    :ok
  end

  defp validate_type("update_channel_pin", effect, _is_official) do
    unless non_empty_binary?(effect["pin_id"]) do
      invalid!("update_channel_pin.pin_id required")
    end

    unless is_map(effect["message"]) do
      invalid!("update_channel_pin.message required")
    end

    :ok
  end

  defp validate_type("clear_channel_pin", effect, _is_official) do
    unless non_empty_binary?(effect["pin_id"]) do
      invalid!("clear_channel_pin.pin_id required")
    end

    :ok
  end

  # Safety net: `validate_one` gates on the allowlist, so only an
  # allowlist member can reach a `validate_type/3` clause here.
  defp validate_type(type, _effect, _is_official) do
    invalid!("unsupported effect type: #{type}")
  end

  defp require_message(effect) do
    case effect["message"] do
      %{} = message -> message
      _ -> invalid!("message required")
    end
  end

  defp validate_message_fields(message, is_official, opts) do
    format = message["format"] || "plain"

    unless is_binary(format) and format in @allowed_formats do
      invalid!("message format must be plain, markdown, or unsafe-markdown")
    end

    if format == "unsafe-markdown" and not is_official do
      invalid!("unsafe-markdown format is official bots only")
    end

    unless is_nil(message["text"]) or is_binary(message["text"]) do
      invalid!("message.text must be a string")
    end

    unless is_nil(message["reply_to_message_id"]) or is_binary(message["reply_to_message_id"]) do
      invalid!("message.reply_to_message_id must be a string")
    end

    if opts[:allow_attachments] do
      ids = message["attachment_ids"]

      unless is_nil(ids) or (is_list(ids) and Enum.all?(ids, &is_binary/1)) do
        invalid!("message.attachment_ids must be an array of strings")
      end
    end

    if not is_nil(message["components"]) do
      validate_components(message["components"])
    end

    :ok
  end

  # Deep component validation (contract §3.8). `nil` is a valid absence;
  # anything not a list is invalid.
  defp validate_components(nil), do: :ok

  defp validate_components(list) when is_list(list) do
    case Components.validate(list) do
      {:ok, components} ->
        case Components.reject_platform_custom_ids(components) do
          :ok -> :ok
          {:error, reason} -> invalid!(reason)
        end

      {:error, reason} ->
        invalid!(reason)
    end
  end

  defp validate_components(_), do: invalid!("message.components must be an array")

  # The old Worker counts `undefined` fields: `text` / `components` /
  # `attachment_ids` must all be absent for a no-op update.
  defp patch_present?(message) do
    Enum.any?(
      [
        Map.fetch(message, "text"),
        Map.fetch(message, "components"),
        Map.fetch(message, "attachment_ids")
      ],
      fn
        {:ok, value} when value != nil -> true
        {:ok, nil} -> false
        :error -> false
      end
    )
  end

  defp non_empty_binary?(value), do: is_binary(value) and value != ""
  defp non_empty_list?(value) when is_list(value), do: length(value) > 0
  defp non_empty_list?(_), do: false

  # ----------------------------------------------------------- request hash

  @doc """
  SHA-256 (lowercase hex) over the canonical JSON form of the effect body
  **minus `client_effect_id`** (spec D10 self-consistent variant of the old
  Worker's `computeEffectRequestHash`).

  Elixir maps are unordered, so the canonical form sorts object keys — the
  hash is stable per-deployment for the same logical body (idempotency only
  requires self-consistency, not cross-implementation equality).
  """
  def request_hash(%{} = effect) do
    effect
    |> Map.delete("client_effect_id")
    |> to_canonical()
    |> CanonicalJSON.encode_and_sha256()
  end

  @doc """
  Hash for a `session.effects` body (old Worker
  `computeSessionEffectsRequestHash` parity): the effect list with each
  effect's `client_effect_id` stripped.
  """
  def session_request_hash(effects) when is_list(effects) do
    effects
    |> Enum.map(&Map.delete(&1, "client_effect_id"))
    |> to_canonical()
    |> CanonicalJSON.encode_and_sha256()
  end

  defp to_canonical(value) when is_map(value) do
    value
    |> Map.to_list()
    |> Enum.sort_by(fn {key, _} -> to_string(key) end)
    |> Enum.map(fn {key, value} -> {to_string(key), to_canonical(value)} end)
  end

  defp to_canonical(value) when is_list(value), do: Enum.map(value, &to_canonical/1)
  defp to_canonical(value), do: value

  # ------------------------------------------------------------------- bots

  @doc """
  The bot's Browser-visible summary (`display_name` / `avatar_url`), or nil
  when the bot row is missing (old Worker `fetchBotSummary` null path).
  """
  def bot_summary(bot_id) do
    Query.rows(
      Repo.query(
        "SELECT display_name, avatar_url FROM chat_v2.bot_apps WHERE bot_id = $1",
        [bot_id],
        type: true
      )
    )
    |> List.first()
    |> case do
      %{"display_name" => display_name, "avatar_url" => avatar_url} ->
        %{"display_name" => display_name, "avatar_url" => avatar_url}

      _ ->
        nil
    end
  end

  @doc "Whether the bot's `bot_apps.visibility` is `official`."
  def bot_official?(bot_id) do
    Query.rows(
      Repo.query(
        "SELECT 1 FROM chat_v2.bot_apps WHERE bot_id = $1 AND visibility = 'official'",
        [bot_id],
        type: true
      )
    )
    |> Enum.count()
    |> then(&(&1 > 0))
  end

  # ------------------------------------------------------------ batch apply

  @doc """
  Apply a whole validated `delivery_result` effect batch (old Worker
  `applyValidatedEffects` + `finalizeAppliedEffects` parity). Runs on the
  per-channel writer:

  * ONE PG transaction for the batch (per-effect idempotency rows inside);
  * per effect, allocates at most one per-channel `event_id` from `seq`;
  * after commit: enqueues listen inputs (`session.input` frames) and
    broadcasts the live `message.stream_started` frames.

  Returns `{%{effect_results, event_frames}, new_seq}`. Raises
  `Errors.ApiError` on `BOT_EFFECT_CONFLICT` / applier errors — the
  caller's `run_command` rescue turns that into a `failed` ack.

  `opts`: `:is_official` (unsafe-markdown gate), `:allow_session_control`
  (+ `:session_id`) — the `session.effects` path (contract §9.7.3).
  """
  def apply_effects(channel_id, seq, bot_id, effects, opts \\ []) when is_list(effects) do
    is_official = Keyword.get(opts, :is_official, false)

    # Every applier that re-projects a bot-sender message needs the resolved
    # bot summary (`project_sender` falls back to `display_name = bot_id`
    # otherwise — old Worker resolves the live bot profile on every
    # message.created / message.updated / interaction.completed projection).
    needs_summary? =
      Enum.any?(effects, fn effect ->
        effect["type"] in [
          "send_message",
          "update_message",
          "disable_components",
          "start_stream",
          "set_channel_pin"
        ]
      end)

    summary = if needs_summary?, do: bot_summary(bot_id), else: nil

    if needs_summary? and is_nil(summary) and not is_official do
      raise Errors.new("BOT_NOT_FOUND", "bot not found")
    end

    now = DateTime.utc_now()
    now_ms = DateTime.to_unix(now, :millisecond)

    ctx = %{
      summary: summary,
      now: now,
      now_ms: now_ms,
      mv: membership_version(channel_id),
      allow_session_control: Keyword.get(opts, :allow_session_control, false),
      session_id: Keyword.get(opts, :session_id)
    }

    # Standalone calls (`apply/3`) pass the `0` sentinel instead of writer
    # state: seed a fresh monotonic state from the current time so the
    # scratch event ids are strictly increasing within the call.
    initial_seq = if is_integer(seq), do: %{last_ms: now_ms, counter: 0}, else: seq

    initial = %{
      seq: initial_seq,
      effect_results: [],
      event_frames: [],
      stream_emits: [],
      input_enqueues: []
    }

    {:ok, applied} =
      Repo.transaction(fn ->
        Enum.reduce(effects, initial, fn effect, st ->
          apply_effect(channel_id, bot_id, effect, st, ctx)
        end)
      end)

    # finalizeAppliedEffects parity — side effects AFTER the batch commit.
    {final, new_seq} =
      Enum.reduce(applied.input_enqueues, {applied, applied.seq}, fn enqueue, {st, s} ->
        case StatefulSessions.enqueue_input(channel_id, s, %{
               event_id: enqueue["event_id"],
               occurred_at: enqueue["occurred_at"],
               message: enqueue["message"],
               type: enqueue["type"],
               sender_kind: "bot",
               sender_user_id: nil,
               sender_bot_id: bot_id
             }) do
          {:ok, s2, extra} ->
            {Map.put(st, :event_frames, st.event_frames ++ (extra[:event_frames] || [])), s2}
        end
      end)

    Enum.each(final.stream_emits, fn emit ->
      Stream.broadcast_started(emit["channel_id"], emit["message_id"], emit["message"])
    end)

    {
      %{
        effect_results: final.effect_results,
        event_frames: final.event_frames
      },
      new_seq
    }
  end

  # Single-effect convenience (tests + the old #17 surface). `seq` starts at
  # 0: standalone calls are not writer-scoped, so the allocated event ids
  # only need to be monotonic within the call.
  def apply(channel_id, bot_id, %{} = effect) do
    hash = request_hash(effect)

    case lookup(channel_id, bot_id, effect["client_effect_id"]) do
      {:hit, row} ->
        if row["request_hash"] == hash do
          response = Projections.json_map(row["response_json"]) || %{}
          maybe_rehydrate_stream(channel_id, bot_id, effect, response)
          {:cached, response}
        else
          {:error,
           Errors.new(
             "BOT_EFFECT_CONFLICT",
             "client_effect_id reused with different body"
           )}
        end

      :miss ->
        try do
          {%{effect_results: [result]}, _seq} =
            apply_effects(channel_id, 0, bot_id, [effect])

          {:applied, result}
        rescue
          e in Errors.ApiError -> {:error, e}
        end
    end
  end

  # ------------------------------------------------------------ idempotency
  #
  # This is the `bot_effect` namespace view of the unified
  # `chat_v2.idempotency` table (spec D10). The shared invariants are the
  # 24h TTL, the bingenerate id, and the `expires_at > now()` predicate.

  defp lookup(channel_id, bot_id, client_effect_id) do
    rows =
      Query.rows(
        Repo.query(
          """
          SELECT request_hash, response_json, effect_type
          FROM chat_v2.idempotency
          WHERE namespace = 'bot_effect'
            AND channel_id = $1
            AND bot_id = $2
            AND client_effect_id = $3
            AND (expires_at IS NULL OR expires_at > now())
          """,
          [channel_id, bot_id, client_effect_id],
          type: true
        )
      )

    case List.first(rows) do
      nil -> :miss
      row -> {:hit, row}
    end
  end

  defp write_idem(channel_id, bot_id, effect, effect_type, hash, message_id, response) do
    now = DateTime.utc_now()
    expires = DateTime.add(now, @idem_ttl_ms, :millisecond)

    Repo.query!(
      """
      INSERT INTO chat_v2.idempotency
        (id, namespace, channel_id, bot_id, client_effect_id, effect_type,
         message_id, request_hash, response_json, created_at, updated_at,
         expires_at)
      VALUES ($1, 'bot_effect', $2, $3, $4, $5, $6, $7, $8, $9, $9, $10)
      """,
      [
        Ecto.UUID.bingenerate(),
        channel_id,
        bot_id,
        effect["client_effect_id"],
        effect_type,
        message_id,
        hash,
        response,
        now,
        expires
      ],
      type: true
    )

    :ok
  end

  # --------------------------------------------------------------- dispatch

  defp apply_effect(channel_id, bot_id, effect, st, ctx) do
    hash = request_hash(effect)
    type = effect["type"]

    case lookup(channel_id, bot_id, effect["client_effect_id"]) do
      {:hit, row} ->
        unless row["request_hash"] == hash do
          raise Errors.new(
                  "BOT_EFFECT_CONFLICT",
                  "client_effect_id reused with different body"
                )
        end

        response = Projections.json_map(row["response_json"]) || %{}
        st = Map.put(st, :effect_results, st.effect_results ++ [response])

        if type == "start_stream" do
          maybe_rehydrate_stream(channel_id, bot_id, effect, response)
        end

        st

      :miss ->
        {st_after, _scratch} =
          case type do
            "send_message" ->
              applier_send_message(channel_id, bot_id, effect, st, ctx)

            "update_message" ->
              applier_update_message(channel_id, bot_id, effect, st, ctx)

            "disable_components" ->
              applier_disable_components(channel_id, bot_id, effect, st, ctx)

            "start_stream" ->
              applier_start_stream(channel_id, bot_id, effect, st, ctx)

            "set_channel_pin" ->
              applier_set_channel_pin(channel_id, bot_id, effect, st, ctx)

            "update_channel_pin" ->
              applier_update_channel_pin(channel_id, bot_id, effect, st, ctx)

            "clear_channel_pin" ->
              applier_clear_channel_pin(channel_id, bot_id, effect, st, ctx)
          end

        # The freshly appended result is the batch's last one.
        [result | _rest] = st_after.effect_results

        write_idem(
          channel_id,
          bot_id,
          effect,
          type,
          hash,
          result["message_id"],
          result
        )

        st_after
    end
  end

  # --------------------------------------------------------------- appliers

  # send_message: messages row + attachment links + message.created event.
  defp applier_send_message(channel_id, bot_id, effect, st, ctx) do
    message = effect["message"]
    type = message["type"] || "text"
    format = message["format"] || "plain"
    text = message["text"]
    reply_to = message["reply_to_message_id"]
    components = validated_components(message["components"])

    attachments =
      if type == "image",
        do: resolve_attachments(channel_id, bot_id, message["attachment_ids"] || []),
        else: []

    now = ctx.now
    now_ms = ctx.now_ms
    summary = bot_sender_summary(ctx, bot_id)

    message_id = Ids.uuidv7(now_ms)
    {event_id, new_seq} = Ids.monotonic_uuidv7(st.seq, now_ms)

    Repo.query!(
      """
      INSERT INTO chat_v2.messages
        (message_id, command_id, dedupe_principal_key, channel_id,
         sender_kind, sender_user_id, sender_bot_id, type, format, status,
         text, reply_to, components_json, stream_state, created_at, updated_at)
      VALUES ($1, $2, $3, $4, 'bot', NULL, $5, $6, $7, 'normal', $8, $9, $10, 'none', $11, $11)
      """,
      [
        message_id,
        effect["client_effect_id"],
        "bot:#{bot_id}",
        channel_id,
        bot_id,
        type,
        format,
        text,
        reply_to,
        components,
        now
      ],
      type: true
    )

    if type == "image" do
      link_attachments(message_id, attachments)
    end

    row =
      synthetic_row(
        message_id,
        effect["client_effect_id"],
        channel_id,
        bot_id,
        type,
        format,
        "normal",
        text,
        reply_to,
        now
      )

    live_message =
      Projections.project_message(row, %{}, %{
        attachments: attachments,
        components: components,
        bot_summary: summary
      })

    insert_bot_event(
      event_id,
      "message.created",
      channel_id,
      bot_id,
      bot_persisted_payload(row),
      ctx.mv,
      now
    )

    frame =
      Projections.build_event_frame(event_id, "message.created", channel_id, now, %{
        "message" => live_message
      })
      |> Map.put("membership_version_at_event", ctx.mv)

    result = effect_result(effect, %{"message_id" => message_id, "event_id" => event_id})

    {
      st
      |> Map.put(:seq, new_seq)
      |> put_result(result)
      |> Map.put(:event_frames, st.event_frames ++ [frame])
      |> Map.put(
        :input_enqueues,
        st.input_enqueues ++
          [
            %{
              "event_id" => event_id,
              "occurred_at" => now,
              "message" => live_message,
              "type" => type
            }
          ]
      ),
      nil
    }
  end

  # update_message: merge semantics per contract §9.14.2 (text / components /
  # attachment_ids; status normal→edited; type follows the attachment relink).
  defp applier_update_message(channel_id, bot_id, effect, st, ctx) do
    message_id = effect["message_id"]
    row = load_full_message(channel_id, message_id)

    if is_nil(row) do
      raise Errors.new("BOT_EFFECT_INVALID", "message not found")
    end

    assert_mutable(row, bot_id)

    message = effect["message"]
    now = ctx.now

    has_text? = Map.has_key?(message, "text")
    next_text = if has_text?, do: message["text"], else: row["text"]

    has_components? = Map.has_key?(message, "components")

    next_components =
      if has_components? do
        validated_components(message["components"])
      else
        Projections.json_list(row["components_json"])
      end

    next_status =
      if has_text? and row["status"] == "normal" do
        "edited"
      else
        row["status"]
      end

    next_edited_at = if has_text?, do: now, else: row["edited_at"]

    {next_type, attachments} =
      case Map.fetch(message, "attachment_ids") do
        {:ok, ids} when ids != [] ->
          resolved = resolve_attachments(channel_id, bot_id, ids)
          replace_attachments(message_id, resolved)
          {"image", resolved}

        {:ok, []} ->
          clear_attachments(message_id)
          {"text", []}

        :error ->
          {row["type"], load_attachment_projections(message_id)}
      end

    Repo.query!(
      """
      UPDATE chat_v2.messages
      SET text = $2, type = $3, components_json = $4, status = $5,
          updated_at = $6, edited_at = $7
      WHERE message_id = $1 AND channel_id = $8
      """,
      [
        message_id,
        next_text,
        next_type,
        next_components,
        next_status,
        now,
        next_edited_at,
        channel_id
      ],
      type: true
    )

    updated_row =
      row
      |> Map.put("text", next_text)
      |> Map.put("type", next_type)
      |> Map.put("status", next_status)
      |> Map.put("updated_at", now)
      |> Map.put("edited_at", next_edited_at)

    live_message =
      Projections.project_message(updated_row, %{}, %{
        attachments: attachments,
        components: next_components,
        bot_summary: bot_sender_summary(ctx, bot_id)
      })

    {event_id, new_seq} = Ids.monotonic_uuidv7(st.seq, ctx.now_ms)

    insert_bot_event(
      event_id,
      "message.updated",
      channel_id,
      bot_id,
      bot_persisted_payload(updated_row),
      ctx.mv,
      now
    )

    frame =
      Projections.build_event_frame(event_id, "message.updated", channel_id, now, %{
        "message" => live_message
      })
      |> Map.put("membership_version_at_event", ctx.mv)

    result = effect_result(effect, %{"message_id" => message_id, "event_id" => event_id})

    {
      st
      |> Map.put(:seq, new_seq)
      |> put_result(result)
      |> Map.put(:event_frames, st.event_frames ++ [frame]),
      nil
    }
  end

  # disable_components: mark the given component ids disabled (contract
  # §9.14.3); unknown ids are `component not found: <id>`.
  defp applier_disable_components(channel_id, bot_id, effect, st, ctx) do
    message_id = effect["message_id"]
    row = load_full_message(channel_id, message_id)

    if is_nil(row) do
      raise Errors.new("BOT_EFFECT_INVALID", "message not found")
    end

    assert_mutable(row, bot_id)

    stored = Projections.json_list(row["components_json"])
    ids = effect["component_ids"]

    for id <- ids do
      unless Enum.any?(stored, fn component ->
               is_map(component) and component["component_id"] == id
             end) do
        raise Errors.new("BOT_EFFECT_INVALID", "component not found: #{id}")
      end
    end

    next_components = Components.disable(stored, ids)

    Repo.query!(
      """
      UPDATE chat_v2.messages
      SET components_json = $2, updated_at = $3
      WHERE message_id = $1 AND channel_id = $4
      """,
      [message_id, next_components, ctx.now, channel_id],
      type: true
    )

    updated_row = row |> Map.put("updated_at", ctx.now)

    live_message =
      Projections.project_message(updated_row, %{}, %{
        attachments: load_attachment_projections(message_id),
        components: next_components,
        bot_summary: bot_sender_summary(ctx, bot_id)
      })

    {event_id, new_seq} = Ids.monotonic_uuidv7(st.seq, ctx.now_ms)

    insert_bot_event(
      event_id,
      "message.updated",
      channel_id,
      bot_id,
      bot_persisted_payload(updated_row),
      ctx.mv,
      ctx.now
    )

    frame =
      Projections.build_event_frame(event_id, "message.updated", channel_id, ctx.now, %{
        "message" => live_message
      })
      |> Map.put("membership_version_at_event", ctx.mv)

    result = effect_result(effect, %{"message_id" => message_id, "event_id" => event_id})

    {
      st
      |> Map.put(:seq, new_seq)
      |> put_result(result)
      |> Map.put(:event_frames, st.event_frames ++ [frame]),
      nil
    }
  end

  # start_stream: ephemeral stream process + handle (no messages row, no
  # event row). The Stream process is registered inline — the handle is part
  # of the effect response (stored in the idem row and returned to the bot),
  # matching the old Worker, where the stream DO is started synchronously by
  # the effect handler (its storage is not covered by the channel txn either).
  # A later effect's rollback can orphan the registered process (its buffer
  # simply never gets a connection). The live `message.stream_started` frame
  # is still broadcast after the batch commits (finalize parity).
  defp applier_start_stream(channel_id, bot_id, effect, st, ctx) do
    message = effect["message"]
    now_ms = ctx.now_ms

    message_id = Ids.uuidv7(now_ms)
    {:ok, stream} = Stream.start_stream(channel_id, message_id, bot_id, message)

    row =
      synthetic_row(
        message_id,
        effect["client_effect_id"],
        channel_id,
        bot_id,
        message["type"] || "text",
        message["format"] || "plain",
        "normal",
        "",
        message["reply_to_message_id"],
        ctx.now
      )
      |> Map.put("stream_state", "streaming")

    live_message =
      Projections.project_message(row, %{}, %{
        attachments: [],
        components: [],
        bot_summary: bot_sender_summary(ctx, bot_id)
      })

    result = effect_result(effect, %{"message_id" => message_id, "stream" => stream})

    {
      st
      |> put_result(result)
      |> Map.put(
        :stream_emits,
        st.stream_emits ++
          [
            %{
              "channel_id" => channel_id,
              "message_id" => message_id,
              "message" => live_message
            }
          ]
      ),
      nil
    }
  end

  # set_channel_pin: create/replace the bot pin of `pin_kind` (old Worker
  # getBotPinRowByKind global replace key).
  defp applier_set_channel_pin(channel_id, bot_id, effect, st, ctx) do
    {pin_id, event_id, frame, new_seq} =
      ChannelPins.bot_set(
        channel_id,
        st.seq,
        bot_id,
        effect["pin_kind"],
        effect["message"],
        bot_sender_summary(ctx, bot_id)
      )

    result = effect_result(effect, %{"pin_id" => pin_id, "event_id" => event_id})

    {
      st
      |> Map.put(:seq, new_seq)
      |> put_result(result)
      |> Map.put(:event_frames, st.event_frames ++ [frame]),
      nil
    }
  end

  defp applier_update_channel_pin(channel_id, bot_id, effect, st, ctx) do
    {pin_id, event_id, frame, new_seq} =
      ChannelPins.bot_update(
        channel_id,
        st.seq,
        bot_id,
        effect["pin_id"],
        effect["message"],
        allow_session_control: ctx.allow_session_control,
        session_id: ctx.session_id
      )

    result = effect_result(effect, %{"pin_id" => pin_id, "event_id" => event_id})

    {
      st
      |> Map.put(:seq, new_seq)
      |> put_result(result)
      |> Map.put(:event_frames, st.event_frames ++ [frame]),
      nil
    }
  end

  defp applier_clear_channel_pin(channel_id, bot_id, effect, st, _ctx) do
    {pin_id, event_id, frame, new_seq} =
      ChannelPins.bot_clear(channel_id, st.seq, bot_id, effect["pin_id"])

    result = effect_result(effect, %{"pin_id" => pin_id, "event_id" => event_id})

    {
      st
      |> Map.put(:seq, new_seq)
      |> put_result(result)
      |> Map.put(:event_frames, st.event_frames ++ [frame]),
      nil
    }
  end

  # -------------------------------------------------------------- internals

  defp put_result(st, result), do: Map.put(st, :effect_results, st.effect_results ++ [result])

  # Old Worker null-summary fallback (official platform bot without a
  # bot_apps row): the raw bot id stands in for the display name.
  defp bot_sender_summary(ctx, bot_id) do
    ctx.summary || %{"display_name" => bot_id, "avatar_url" => nil}
  end

  # The synthetic row `Projections.project_message/3` reads (bot sender).
  defp synthetic_row(
         message_id,
         command_id,
         channel_id,
         bot_id,
         type,
         format,
         status,
         text,
         reply_to,
         now
       ) do
    %{
      "message_id" => message_id,
      "command_id" => command_id,
      "channel_id" => channel_id,
      "sender_kind" => "bot",
      "sender_user_id" => nil,
      "sender_bot_id" => bot_id,
      "type" => type,
      "format" => format,
      "status" => status,
      "stream_state" => "none",
      "text" => text,
      "reply_to" => reply_to,
      "reply_snapshot_json" => nil,
      "created_at" => now,
      "updated_at" => now,
      "edited_at" => nil,
      "deleted_at" => nil,
      "deleted_by" => nil,
      "recalled_at" => nil
    }
  end

  # Slim stored event payload (mirror of MessageSend's user-side shape;
  # actor is the bot).
  defp bot_persisted_payload(row) do
    %{
      "message" => %{
        "message_id" => row["message_id"],
        "command_id" => row["command_id"],
        "channel_id" => row["channel_id"],
        "sender" => %{"kind" => "bot", "user_id" => nil, "bot_id" => row["sender_bot_id"]},
        "text" => row["text"],
        "type" => row["type"],
        "format" => row["format"],
        "status" => row["status"],
        "stream_state" => row["stream_state"],
        "reply_to" => row["reply_to"],
        "reply_snapshot" => nil,
        "attachments" => [],
        "components" => [],
        "mentions" => [],
        "created_at" => Projections.format_ts(row["created_at"]),
        "updated_at" => Projections.format_ts(row["updated_at"]),
        "edited_at" => Projections.format_ts(row["edited_at"]),
        "deleted_at" => nil,
        "deleted_by" => nil,
        "recalled_at" => nil
      }
    }
  end

  defp insert_bot_event(event_id, event_type, channel_id, bot_id, payload, mv, now) do
    Repo.query!(
      """
      INSERT INTO chat_v2.events
        (event_id, event_type, channel_id, actor_kind, actor_id, payload,
         membership_version_at_event, occurred_at)
      VALUES ($1, $2, $3, 'bot', $4, $5, $6, $7)
      """,
      [event_id, event_type, channel_id, bot_id, payload, mv, now],
      type: true
    )
  end

  # Old Worker `resolveBotAttachmentIds`: finalized, bot-owned, same-channel
  # image attachments, else `attachment not available`.
  defp resolve_attachments(channel_id, bot_id, ids) do
    Enum.map(ids, fn id ->
      row =
        Query.rows(
          Repo.query(
            """
            SELECT attachment_id, url, mime_type, size_bytes, width, height, blurhash
            FROM chat_v2.attachments
            WHERE attachment_id = $1 AND owner_bot_id = $2 AND channel_id = $3
              AND status = 'finalized' AND kind = 'image'
            """,
            [id, bot_id, channel_id],
            type: true
          )
        )
        |> List.first()

      if is_nil(row) do
        raise Errors.new("BOT_EFFECT_INVALID", "attachment not available")
      end

      %{
        "attachment_id" => row["attachment_id"],
        "url" => row["url"],
        "mime_type" => row["mime_type"],
        "size_bytes" => row["size_bytes"],
        # NULL dimensions project as 0 (old Worker `projectAttachmentForBrowser`
        # `?? 0`) — issue #26 B2.
        "width" => row["width"] || 0,
        "height" => row["height"] || 0,
        "blurhash" => row["blurhash"]
      }
    end)
  end

  defp load_attachment_projections(message_id) do
    Query.rows(
      Repo.query(
        """
        SELECT a.attachment_id, a.url, a.mime_type, a.size_bytes, a.width, a.height,
               a.blurhash
        FROM chat_v2.message_attachments ma
        JOIN chat_v2.attachments a ON a.attachment_id = ma.attachment_id
        WHERE ma.message_id = $1
        """,
        [message_id],
        type: true
      )
    )
    |> Enum.map(fn row ->
      # NULL dimensions project as 0 (old Worker `projectAttachmentForBrowser`
      # `?? 0`) — issue #26 B2.
      row
      |> Map.put("width", row["width"] || 0)
      |> Map.put("height", row["height"] || 0)
    end)
  end

  defp link_attachments(message_id, attachments) do
    for attachment <- attachments do
      Repo.query!(
        "INSERT INTO chat_v2.message_attachments (message_id, attachment_id) " <>
          "VALUES ($1, $2) ON CONFLICT DO NOTHING",
        [message_id, attachment["attachment_id"]]
      )
    end
  end

  defp replace_attachments(message_id, attachments) do
    Repo.query!("DELETE FROM chat_v2.message_attachments WHERE message_id = $1", [message_id])
    link_attachments(message_id, attachments)
  end

  defp clear_attachments(message_id), do: replace_attachments(message_id, [])

  # Old Worker `assertBotOwnsMessage` + mutability gates (update/disable).
  defp assert_mutable(row, bot_id) do
    unless row["sender_kind"] == "bot" and row["sender_bot_id"] == bot_id do
      raise Errors.new("BOT_EFFECT_INVALID", "bot may only mutate its own messages")
    end

    unless row["status"] in ["normal", "edited"] do
      raise Errors.new("BOT_EFFECT_INVALID", "message is not mutable")
    end

    unless row["stream_state"] == "none" do
      raise Errors.new("BOT_EFFECT_INVALID", "message is not mutable")
    end
  end

  defp load_full_message(channel_id, message_id) do
    Query.rows(
      Repo.query(
        """
        SELECT message_id, command_id, channel_id, sender_kind, sender_user_id,
               sender_bot_id, type, format, status, text, reply_to,
               reply_snapshot_json, components_json, stream_state, created_at,
               updated_at, edited_at, deleted_at, deleted_by, recalled_at
        FROM chat_v2.messages
        WHERE message_id = $1 AND channel_id = $2
        """,
        [message_id, channel_id],
        type: true
      )
    )
    |> List.first()
  end

  defp validated_components(nil), do: []

  defp validated_components(list) when is_list(list) do
    components =
      case Components.validate(list) do
        {:ok, components} -> components
        {:error, reason} -> raise Errors.new("BOT_EFFECT_INVALID", reason)
      end

    case Components.reject_platform_custom_ids(components) do
      :ok -> components
      {:error, reason} -> raise Errors.new("BOT_EFFECT_INVALID", reason)
    end
  end

  defp membership_version(channel_id) do
    Query.rows(
      Repo.query(
        "SELECT membership_version FROM chat_v2.channels WHERE channel_id = $1",
        [channel_id],
        type: true
      )
    )
    |> List.first()
    |> case do
      %{"membership_version" => mv} -> mv
      _ -> 0
    end
  end

  # Idempotent start_stream replay: the Stream process is ephemeral, so a
  # cached effect must revive it (same message_id / expires_at) or the
  # bot's reconnect lands on BOT_STREAM_NOT_FOUND.
  defp maybe_rehydrate_stream(channel_id, bot_id, %{"type" => "start_stream"} = effect, response) do
    message_id = response["message_id"]
    stream = response["stream"] || %{}

    if is_binary(message_id) do
      case Stream.owner(channel_id, message_id) do
        {:ok, ^bot_id} ->
          :ok

        _ ->
          meta = Map.put(effect["message"] || %{}, "expires_at", stream["expires_at"])
          {:ok, _} = Stream.start_stream(channel_id, message_id, bot_id, meta)
          :ok
      end
    else
      :ok
    end
  end

  defp maybe_rehydrate_stream(_channel_id, _bot_id, _effect, _response), do: :ok

  # Wire shape per contract §9.7.3 / §9.14: `{ client_effect_id, type,
  # status, ... }` (old Worker `toGenericEffectResult` parity — note `type`,
  # not `effect_type`).
  defp effect_result(effect, extra) do
    %{
      "client_effect_id" => effect["client_effect_id"],
      "type" => effect["type"],
      "status" => "applied"
    }
    |> Map.merge(extra)
  end
end
