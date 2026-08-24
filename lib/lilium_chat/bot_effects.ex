defmodule LiliumChat.BotEffects do
  @moduledoc """
  Bot effect validation, idempotency, and application (contract §9.7.3 /
  §9.14, issue #17).

  A `delivery_result` carries up to 20 effects. Each effect is validated
  (shape + main-gateway type list), then made idempotent on the
  `(channel_id, bot_id, client_effect_id)` key via the `bot_effect`
  namespace of `chat_v2.idempotency` (spec D10): same key + same request
  body replays the stored result; same key + different body is
  `BOT_EFFECT_CONFLICT`.

  The appliers are the **minimal** real implementations this ticket needs
  (issue #17 tracer bullet): they persist the minimum state the effect
  implies (a `messages` row, a `channel_pins` row) and return the
  `effect_result` the `delivery_ack` carries. Deep application (component
  storage, stream registry, pin projection merge, attachment linking,
  browser event emission) is the seam for issue #19.
  """

  alias LiliumChat.{BotGateway, CanonicalJSON, Errors, Ids, Query, Repo, Stream}

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
      Enum.each(effects, fn effect -> validate_one(effect, is_official) end)

      {:ok, effects}
    rescue
      e in [ValidationError] ->
        {:error, Errors.new("BOT_EFFECT_INVALID", e.message)}
    end
  end

  defp invalid!(message), do: raise(ValidationError, message: message)

  defp validate_one(effect, is_official) do
    unless is_map(effect) do
      invalid!("effect must be an object")
    end

    unless is_binary(effect["client_effect_id"]) and effect["client_effect_id"] != "" do
      invalid!("client_effect_id required")
    end

    case effect["type"] do
      type when is_binary(type) ->
        # The main-gateway allowlist (contract §9.14) is the single source
        # of truth — `validate_type/3` clauses and `apply_one/3` dispatch
        # follow it (a missing clause fails loudly in both).
        if type in BotGateway.main_gateway_effect_types() do
          validate_type(type, effect, is_official)
        else
          invalid!("unsupported effect type: #{type}")
        end

      _ ->
        invalid!("effect.type required")
    end
  end

  defp validate_type("send_message", effect, is_official) do
    message = require_message(effect)

    unless message["type"] in ["text", "image"] do
      invalid!("send_message.message.type must be text or image")
    end

    validate_message_fields(message, is_official, allow_attachments: true)

    if message["type"] == "text" and non_empty_list?(message["attachment_ids"]) do
      invalid!("attachment_ids not allowed for text messages")
    end

    if message["type"] == "image" and not non_empty_list?(message["attachment_ids"]) do
      invalid!("image message requires attachment_ids")
    end

    :ok
  end

  defp validate_type("update_message", effect, is_official) do
    unless non_empty_binary?(effect["message_id"]) do
      invalid!("update_message.message_id required")
    end

    message = require_message(effect)
    validate_message_fields(message, is_official, allow_attachments: true)

    unless has_patch?(message) do
      invalid!("update_message requires text, components, and/or attachment_ids")
    end
  end

  defp validate_type("disable_components", effect, _is_official) do
    unless non_empty_binary?(effect["message_id"]) do
      invalid!("disable_components.message_id required")
    end

    unless is_list(effect["component_ids"]) and Enum.all?(effect["component_ids"], &is_binary/1) do
      invalid!("disable_components.component_ids must be an array of strings")
    end

    :ok
  end

  defp validate_type("start_stream", effect, is_official) do
    message = require_message(effect)
    validate_message_fields(message, is_official, allow_attachments: false)

    unless is_nil(message["components"]) or message["components"] == [] do
      invalid!("components not allowed for start_stream")
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

  # Safety net: `validate_one/2` already gates on the allowlist, so only
  # an allowlist member can reach a `validate_type/3` clause here.
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

    unless format in @allowed_formats do
      invalid!("invalid message format: #{inspect(format)}")
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

    components = message["components"]

    unless is_nil(components) or (is_list(components) and Enum.all?(components, &is_map/1)) do
      invalid!("message.components must be an array of objects")
    end

    :ok
  end

  defp has_patch?(message) do
    Enum.any?(
      [message["text"], message["format"], message["attachment_ids"], message["components"]],
      &(&1 != nil)
    )
  end

  defp non_empty_binary?(value), do: is_binary(value) and value != ""
  defp non_empty_list?(value) when is_list(value), do: length(value) > 0
  defp non_empty_list?(_), do: false

  # ----------------------------------------------------------- request hash

  @doc """
  SHA-256 (lowercase hex) over the canonical JSON form of the effect body
  **minus `client_effect_id`** (old Worker `computeEffectRequestHash` parity).

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

  defp to_canonical(value) when is_map(value) do
    value
    |> Map.to_list()
    |> Enum.sort_by(fn {key, _} -> key end)
    |> Enum.map(fn {key, value} -> {to_string(key), to_canonical(value)} end)
  end

  defp to_canonical(value) when is_list(value), do: Enum.map(value, &to_canonical/1)
  defp to_canonical(value), do: value

  # ----------------------------------------------------------------- apply

  @doc """
  Apply one validated effect with `(channel_id, bot_id, client_effect_id)`
  idempotency.

  Returns:

    * `{:cached, effect_result}` — same key + same body; stored result
      replayed (no re-apply);
    * `{:applied, effect_result}` — fresh apply;
    * `{:error, %Errors.ApiError{}}` — `BOT_EFFECT_CONFLICT` (key reused
      with a different body) or an applier error.
  """
  def apply(channel_id, bot_id, %{} = effect) do
    client_effect_id = effect["client_effect_id"]
    hash = request_hash(effect)

    case lookup(channel_id, bot_id, client_effect_id) do
      {:hit, %{"request_hash" => ^hash, "response_json" => response}} ->
        maybe_rehydrate_stream(channel_id, bot_id, effect, response)
        {:cached, response}

      {:hit, _row} ->
        {:error,
         Errors.new("BOT_EFFECT_CONFLICT", "client_effect_id reused with different effect body")}

      :miss ->
        with {:ok, effect_result, message_id} <- apply_one(channel_id, bot_id, effect) do
          write_row(
            channel_id,
            bot_id,
            client_effect_id,
            effect["type"],
            hash,
            effect_result,
            message_id
          )

          {:applied, effect_result}
        end
    end
  end

  # ------------------------------------------------------------ idempotency
  #
  # This is the `bot_effect` namespace view of the unified
  # `chat_v2.idempotency` table (spec D10) — the structural sibling of
  # `LiliumChat.Idempotency` (the `user_command` namespace). The two look
  # alike on purpose: the table is a per-namespace column superset, each
  # namespace keys on its own column set, and the shared invariants are the
  # 24h TTL, the bingenerate id, and the `expires_at > now()` predicate.

  defp lookup(channel_id, bot_id, client_effect_id) do
    rows =
      Query.rows(
        Repo.query(
          """
          SELECT request_hash, response_json
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

  defp write_row(channel_id, bot_id, client_effect_id, effect_type, hash, response, message_id) do
    now = DateTime.utc_now()
    expires = DateTime.add(now, @idem_ttl_ms, :millisecond)

    Repo.query!(
      """
      INSERT INTO chat_v2.idempotency
        (id, namespace, channel_id, bot_id, client_effect_id, effect_type,
         message_id, request_hash, response_json, created_at, updated_at, expires_at)
      VALUES ($1, 'bot_effect', $2, $3, $4, $5, $6, $7, $8, $9, $9, $10)
      """,
      [
        Ecto.UUID.bingenerate(),
        channel_id,
        bot_id,
        client_effect_id,
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

  # --------------------------------------------------------------- appliers

  # Dispatch must cover every type in `BotGateway.main_gateway_effect_types/0`
  # (contract §9.14) — the bot_effects_test suite proves the coverage.
  defp apply_one(channel_id, bot_id, effect) do
    case effect["type"] do
      "send_message" -> applier_send_message(channel_id, bot_id, effect)
      "update_message" -> applier_update_message(channel_id, bot_id, effect)
      "disable_components" -> applier_disable_components(channel_id, bot_id, effect)
      "start_stream" -> applier_start_stream(channel_id, bot_id, effect)
      "set_channel_pin" -> applier_set_channel_pin(channel_id, bot_id, effect)
      "update_channel_pin" -> applier_update_channel_pin(channel_id, bot_id, effect)
      "clear_channel_pin" -> applier_clear_channel_pin(channel_id, bot_id, effect)
    end
  end

  defp applier_send_message(channel_id, bot_id, effect) do
    message = effect["message"]
    message_id = Ids.uuidv7()

    insert_bot_message(channel_id, bot_id, effect, message, "none", message_id)

    {:ok, effect_result(effect, %{"message_id" => message_id}), message_id}
  end

  defp applier_start_stream(channel_id, bot_id, effect) do
    # Contract §9.14: create the in-memory stream registry; do NOT insert a
    # canonical messages row. The bot connects to Stream WS before expires_at.
    message = effect["message"] || %{}
    message_id = Ids.uuidv7()

    {:ok, stream} = Stream.start_stream(channel_id, message_id, bot_id, message)
    Stream.broadcast_started(channel_id, message_id)

    {:ok, effect_result(effect, %{"message_id" => message_id, "stream" => stream}), message_id}
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

  defp insert_bot_message(channel_id, bot_id, effect, message, stream_state, message_id) do
    now = DateTime.utc_now()

    Repo.query!(
      """
      INSERT INTO chat_v2.messages
        (message_id, command_id, dedupe_principal_key, channel_id,
         sender_kind, sender_bot_id, type, format, status, text,
         reply_to, stream_state, created_at, updated_at)
      VALUES ($1, $2, $3, $4, 'bot', $5, $6, $7, 'normal', $8, $9, $10, $11, $11)
      """,
      [
        message_id,
        Ids.uuidv7(),
        "bot:#{bot_id}:#{effect["client_effect_id"]}",
        channel_id,
        bot_id,
        message["type"] || "text",
        message["format"] || "plain",
        message["text"],
        message["reply_to_message_id"],
        stream_state,
        now
      ],
      type: true
    )

    :ok
  end

  defp applier_update_message(channel_id, bot_id, effect) do
    message_id = effect["message_id"]

    case load_owned_message(channel_id, bot_id, message_id) do
      nil ->
        {:error, Errors.new("BOT_EFFECT_INVALID", "message not found for update")}

      _row ->
        message = effect["message"]
        now = DateTime.utc_now()

        # Params are laid out as [now, message_id, channel_id, ...patch values]
        # so the base trio keeps $1/$2/$3; patch columns get $4, $5, … in
        # enumeration order.
        {set_clauses, params} =
          Enum.reduce(
            [
              {"text", message["text"]},
              {"format", message["format"]}
            ],
            {["updated_at = $1"], [now, message_id, channel_id]},
            fn {column, value}, {clauses, acc} ->
              if is_binary(value) and (column == "text" or value in @allowed_formats) do
                n = length(acc) + 1
                {["#{column} = $" <> Integer.to_string(n) | clauses], acc ++ [value]}
              else
                {clauses, acc}
              end
            end
          )

        set_sql = set_clauses |> Enum.reverse() |> Enum.join(", ")

        Repo.query!(
          "UPDATE chat_v2.messages SET " <>
            set_sql <> " WHERE message_id = $2 AND channel_id = $3",
          params,
          type: true
        )

        {:ok, effect_result(effect, %{"message_id" => message_id}), message_id}
    end
  end

  defp applier_disable_components(channel_id, bot_id, effect) do
    case load_owned_message(channel_id, bot_id, effect["message_id"]) do
      nil ->
        {:error, Errors.new("BOT_EFFECT_INVALID", "message not found")}

      _row ->
        # Minimal (#17): the target must be a bot message; component state
        # itself is persisted when message component storage lands (#19).
        {:ok, effect_result(effect, %{"message_id" => effect["message_id"]}),
         effect["message_id"]}
    end
  end

  defp applier_set_channel_pin(channel_id, bot_id, effect) do
    pin_id = Ids.uuidv7()
    now = DateTime.utc_now()

    Repo.query!(
      """
      INSERT INTO chat_v2.channel_pins
        (pin_id, channel_id, pin_kind, pin_owner_kind, pin_owner_id, priority,
         pinned_at, last_pin_event_id, message_projection_json, created_at, updated_at)
      VALUES ($1, $2, $3, 'bot', $4, $5, $6, $7, $8, $6, $6)
      """,
      [
        pin_id,
        channel_id,
        effect["pin_kind"],
        bot_id,
        pin_priority(effect["pin_kind"]),
        now,
        Ids.uuidv7(),
        effect["message"]
      ],
      type: true
    )

    {:ok, effect_result(effect, %{"pin_id" => pin_id}), nil}
  end

  defp applier_update_channel_pin(channel_id, bot_id, effect) do
    pin_check(effect, channel_id, bot_id, effect["pin_id"])
  end

  defp applier_clear_channel_pin(channel_id, bot_id, effect) do
    pin_check(effect, channel_id, bot_id, effect["pin_id"])
  end

  defp pin_check(effect, channel_id, bot_id, pin_id) do
    case owned_pin?(channel_id, bot_id, pin_id) do
      :found ->
        {:ok, effect_result(effect, %{"pin_id" => pin_id}), nil}

      :not_found ->
        {:error, Errors.new("BOT_EFFECT_INVALID", "pin not found")}

      :not_owned ->
        {:error, Errors.new("BOT_EFFECT_INVALID", "cannot modify another bot pin")}
    end
  end

  # -------------------------------------------------------------- appliers

  # Wire shape per contract §9.7.3 / §9.14: `{ client_effect_id, type,
  # status, ... }` (old Worker `toEffectResult` parity — note `type`, not
  # `effect_type`).
  defp effect_result(effect, extra) do
    %{
      "client_effect_id" => effect["client_effect_id"],
      "type" => effect["type"],
      "status" => "applied"
    }
    |> Map.merge(extra)
  end

  defp pin_priority("announcement"), do: 20
  defp pin_priority(_), do: 15

  # Load a bot-owned, non-streaming, non-deleted message in the channel.
  defp load_owned_message(channel_id, bot_id, message_id) do
    rows =
      Query.rows(
        Repo.query(
          """
          SELECT message_id
          FROM chat_v2.messages
          WHERE message_id = $1
            AND channel_id = $2
            AND sender_kind = 'bot'
            AND sender_bot_id = $3
            AND stream_state = 'none'
            AND status = 'normal'
            AND deleted_at IS NULL
          """,
          [message_id, channel_id, bot_id],
          type: true
        )
      )

    List.first(rows)
  end

  defp owned_pin?(channel_id, bot_id, pin_id) do
    rows =
      Query.rows(
        Repo.query(
          """
          SELECT pin_owner_kind, pin_owner_id
          FROM chat_v2.channel_pins
          WHERE pin_id = $1 AND channel_id = $2
          """,
          [pin_id, channel_id],
          type: true
        )
      )

    case List.first(rows) do
      nil ->
        :not_found

      %{"pin_owner_kind" => "bot", "pin_owner_id" => ^bot_id} ->
        :found

      _row ->
        :not_owned
    end
  end

  # ----------------------------------------------------------------- helpers

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
end
