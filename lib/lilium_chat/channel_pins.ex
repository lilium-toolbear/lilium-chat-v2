defmodule LiliumChat.ChannelPins do
  @moduledoc """
  Channel pin storage + Browser projection (contract §3.10 / §6.7, issue #10).

  Pins live in `chat_v2.channel_pins` — **not** in `messages`: the Browser
  top bar is driven by the `bootstrap.channel_pins` / channel-detail snapshot
  (same read snapshot as the event_state cursor, §4.1) plus the
  `channel.pin.set` / `channel.pin.updated` / `channel.pin.cleared` events
  (§6.7, §10.6). Pins never enter the `messages` pagination (§3.10).

  This module owns:

  * the `channel.pin_message` / `channel.unpin_message` write paths (owner /
    admin pin of a timeline text message, `pin_kind = pinned_message`);
  * the pin row → `ChannelPin` wire projection shared by the ack/event
    payloads and the read snapshots (bootstrap §4.1 / detail §5.2);
  * the `PinMessageProjection` built from a pinned source message (§3.10).

  All row writes run inside the caller's (the per-channel writer process's,
  `LiliumChat.Channel`) PG transaction. `pin_message/3` and `unpin_message/3`
  return `{result, new_seq}` with the same tagged-result convention as
  `LiliumChat.MessageSend.send/3`; `created` results carry `event_frames`
  (a list, in event_id order) for the process to broadcast on `channel:<id>`.
  """

  alias LiliumChat.{
    BotGateway,
    CanonicalJSON,
    CommandManifest,
    Components,
    Errors,
    Idempotency,
    Ids,
    Profiles,
    Projections,
    Query,
    Repo
  }

  alias LiliumChat.WebSockets.Frames

  @op_pin "channel.pin_message"
  @op_unpin "channel.unpin_message"

  # Contract §3.10 suggested maximum for `pinned_message` pins (old Worker
  # MAX_CHANNEL_PINS).
  @max_pins 8

  # Message formats accepted by the bot pin draft / patch parsers.
  @allowed_message_formats ["plain", "markdown", "unsafe-markdown"]

  # ------------------------------------------------------------------ writes

  @doc """
  `channel.pin_message` (contract §6.7.1). `input` is
  `%{user_id: binary, command_id: binary, payload: map}` with
  `payload.source_message_id`. Returns `{result, new_seq}`.
  """
  def pin_message(channel_id, seq, input) do
    user_id = input.user_id
    command_id = input.command_id
    payload = input.payload || %{}

    case validate_payload(payload, "source_message_id") do
      {:error, api_error} ->
        {%{kind: :error, error: api_error}, seq}

      {:ok, source_message_id} ->
        request_hash =
          CanonicalJSON.encode_and_sha256([
            {"channel_id", channel_id},
            {"source_message_id", source_message_id}
          ])

        case Idempotency.check("user", user_id, @op_pin, command_id, request_hash) do
          {:cached, response} ->
            {%{kind: :cached, ack_frame: response}, seq}

          _ ->
            do_pin(channel_id, seq, user_id, command_id, source_message_id, request_hash)
        end
    end
  end

  # Shared payload gate (old Worker: `isRecord(frame.payload)` + the required
  # field, both INVALID_MESSAGE).
  defp validate_payload(payload, key) when is_map(payload) do
    value = payload[key]

    if is_binary(value) and value != "" do
      {:ok, value}
    else
      {:error, Errors.new("INVALID_MESSAGE", "#{key} required")}
    end
  end

  defp validate_payload(_payload, _key) do
    {:error, Errors.new("INVALID_MESSAGE", "invalid payload")}
  end

  @doc """
  `channel.unpin_message` (contract §6.7.2). `input` payload carries either
  `pin_id` **or** `source_message_id`. Returns `{result, new_seq}`.
  """
  def unpin_message(channel_id, seq, input) do
    user_id = input.user_id
    command_id = input.command_id

    case parse_unpin_locators(input.payload) do
      {:error, api_error} ->
        {%{kind: :error, error: api_error}, seq}

      {:ok, pin_id, source_message_id} ->
        request_hash =
          CanonicalJSON.encode_and_sha256([
            {"channel_id", channel_id},
            {"pin_id", pin_id},
            {"source_message_id", source_message_id}
          ])

        case Idempotency.check("user", user_id, @op_unpin, command_id, request_hash) do
          {:cached, response} ->
            {%{kind: :cached, ack_frame: response}, seq}

          _ ->
            do_unpin(
              channel_id,
              seq,
              user_id,
              command_id,
              pin_id,
              source_message_id,
              request_hash
            )
        end
    end
  end

  # The payload must carry EXACTLY ONE of pin_id / source_message_id
  # (an empty string counts as absent); both → INVALID_MESSAGE.
  defp parse_unpin_locators(payload) when is_map(payload) do
    pin_id = normalize_id(payload["pin_id"])
    source_message_id = normalize_id(payload["source_message_id"])

    cond do
      pin_id != nil and source_message_id != nil ->
        {:error,
         Errors.new(
           "INVALID_MESSAGE",
           "exactly one of pin_id or source_message_id required"
         )}

      pin_id == nil and source_message_id == nil ->
        {:error,
         Errors.new(
           "INVALID_MESSAGE",
           "exactly one of pin_id or source_message_id required"
         )}

      true ->
        {:ok, pin_id, source_message_id}
    end
  end

  defp parse_unpin_locators(_payload) do
    {:error, Errors.new("INVALID_MESSAGE", "invalid payload")}
  end

  defp normalize_id(value), do: if(is_binary(value) and value != "", do: value, else: nil)

  # ------------------------------------------------- pin_message internals

  defp do_pin(channel_id, seq, user_id, command_id, source_message_id, request_hash) do
    # Gate order mirrors the old Worker (channel-pin-message.ts): channel-kind
    # gate, dissolved, then the owner/admin role gate — BEFORE the source
    # message load.
    meta =
      Query.rows(
        Repo.query(
          "SELECT channel_id, kind, status, membership_version FROM chat_v2.channels WHERE channel_id = $1",
          [channel_id]
        )
      )

    meta =
      case meta do
        [] ->
          raise Errors.new("CHANNEL_NOT_FOUND", "channel not found")

        [meta] ->
          meta
      end

    if meta["kind"] == "dm" do
      raise Errors.new("UNSUPPORTED_CHANNEL_KIND", "operation not supported for DM channels")
    end

    if meta["status"] == "dissolved" do
      raise Errors.new("CHANNEL_DISSOLVED", "channel is dissolved")
    end

    role = active_role(channel_id, user_id)

    unless role do
      raise Errors.new("FORBIDDEN", "not a channel member")
    end

    unless role in ["owner", "admin"] do
      raise Errors.new("PIN_FORBIDDEN", "only owner or admin can pin messages")
    end

    message_row = load_pin_source_message(channel_id, source_message_id)

    now = DateTime.utc_now()
    now_ms = DateTime.to_unix(now, :millisecond)
    mv = meta["membership_version"]
    profiles = Profiles.resolve(Enum.uniq([user_id, message_row["sender_user_id"]]))
    pinned_by = Projections.user_summary(user_id, profiles)

    # Keep the projection id stable across re-pins (old Worker newPinIds/0 —
    # a new id is minted only for a brand-new pin row).
    existing = pinned_message_row(channel_id, source_message_id)

    projection_id =
      case existing do
        nil ->
          Ids.uuidv7(now_ms + 1)

        row ->
          Projections.json_map(row["message_projection_json"])["projection_id"] ||
            Ids.uuidv7(now_ms + 1)
      end

    projection = build_message_projection(message_row, projection_id, now, profiles)

    # ONE txn: idempotency re-check, no-op detection / pin-limit, pin row +
    # `channel.pin.*` event + idempotency row (spec D10).
    result =
      Repo.transaction(fn ->
        case Idempotency.check("user", user_id, @op_pin, command_id, request_hash) do
          {:conflict, api_error} ->
            Repo.rollback(%{kind: :error, error: api_error})

          {:cached, response} ->
            %{kind: :cached, ack_frame: response}

          :missing ->
            case existing do
              nil ->
                # First pin for this source: the suggested max (8) applies.
                if count(channel_id) >= @max_pins do
                  Repo.rollback(%{
                    kind: :error,
                    error: Errors.new("PIN_SOURCE_INVALID", "channel pin limit reached")
                  })
                else
                  commit_pin(
                    channel_id,
                    seq,
                    user_id,
                    command_id,
                    request_hash,
                    source_message_id,
                    projection,
                    mv,
                    now,
                    now_ms,
                    profiles,
                    pinned_by,
                    nil
                  )
                end

              existing when is_map(existing) ->
                # No-op re-pin (contract §6.7.1): same source message
                # unchanged → NO new event; the ack carries the existing pin's
                # `last_pin_event_id` (old Worker parity, different command_id).
                if projection_equal?(existing, projection) do
                  pin_wire = project_wire(existing, profiles, pinned_by)

                  response =
                    Frames.command_ack(
                      @op_pin,
                      command_id,
                      %{
                        "channel_id" => channel_id,
                        "event_id" => existing["last_pin_event_id"],
                        "pin" => pin_wire
                      }
                    )

                  write_idem(user_id, command_id, request_hash, response)
                  %{kind: :cached, ack_frame: response}
                else
                  commit_pin(
                    channel_id,
                    seq,
                    user_id,
                    command_id,
                    request_hash,
                    source_message_id,
                    projection,
                    mv,
                    now,
                    now_ms,
                    profiles,
                    pinned_by,
                    existing
                  )
                end
            end
        end
      end)

    case result do
      {:ok, %{kind: :created, ack_frame: ack, event_frames: frames, seq: new_seq}} ->
        {%{kind: :created, ack_frame: ack, event_frames: frames}, new_seq}

      {:ok, %{kind: :cached, ack_frame: response}} ->
        {%{kind: :cached, ack_frame: response}, seq}

      {:error, %{kind: :error, error: api_error}} ->
        {%{kind: :error, error: api_error}, seq}
    end
  end

  # Shared fresh/replace commit (runs inside the caller's txn): upsert the pin
  # row, emit `channel.pin.set` (new) or `channel.pin.updated` (replace),
  # build the ack, and write the idempotency row.
  defp commit_pin(
         channel_id,
         seq,
         user_id,
         command_id,
         request_hash,
         source_message_id,
         projection,
         mv,
         now,
         now_ms,
         profiles,
         pinned_by,
         existing
       ) do
    pin_id = if existing, do: existing["pin_id"], else: Ids.uuidv7(now_ms)
    {event_id, new_seq} = Ids.monotonic_uuidv7(seq, now_ms)
    event_type = if existing, do: "channel.pin.updated", else: "channel.pin.set"

    upsert_row(%{
      "pin_id" => pin_id,
      "channel_id" => channel_id,
      "pin_kind" => "pinned_message",
      "pin_owner_kind" => "user",
      "pin_owner_id" => user_id,
      "priority" => 10,
      "session_id" => nil,
      "source_message_id" => source_message_id,
      "pinned_by_user_id" => user_id,
      "pinned_at" => now,
      "expires_at" => nil,
      "last_pin_event_id" => event_id,
      "message_projection_json" => projection,
      "now" => now
    })

    # Re-read the row so the ack/event project what is actually committed
    # (the upsert is an insert-or-update by pin_id).
    pin_row = get_row(pin_id)
    pin_wire = project_wire(pin_row, profiles, pinned_by)
    wire_payload = %{"pin" => pin_wire}

    insert_pin_event(event_id, event_type, channel_id, wire_payload, mv, now)

    ack =
      Frames.command_ack(
        @op_pin,
        command_id,
        %{
          "channel_id" => channel_id,
          "event_id" => event_id,
          "pin" => pin_wire
        }
      )

    write_idem(user_id, command_id, request_hash, ack)

    frame =
      Projections.build_event_frame(event_id, event_type, channel_id, now, wire_payload)
      |> Map.put("membership_version_at_event", mv)

    %{
      kind: :created,
      ack_frame: ack,
      event_frames: [frame],
      seq: new_seq
    }
  end

  # -------------------------------------------- bot pin effects (#19, §9.7.3)
  #
  # Bot-owned pins (`bot_control` priority 15, `announcement` priority 20)
  # created from `delivery_result` / `session.effects`. All functions run
  # inside the caller's (per-channel writer) PG transaction and raise
  # `Errors.ApiError` (`BOT_EFFECT_INVALID`) on failure. `seq` is the
  # per-channel event sequence state; each op allocates at most one
  # `event_id` and returns the advanced seq.

  @bot_control_priority 15
  @announcement_priority 20
  @session_control_priority 0

  @doc "Bot pin priorities (contract §3.10.3). `session_control` is 0 (platform)."
  def bot_pin_priority("announcement"), do: @announcement_priority
  def bot_pin_priority("bot_control"), do: @bot_control_priority
  def bot_pin_priority("session_control"), do: @session_control_priority

  @doc "The bot's existing pin of `pin_kind`, ANY channel (old Worker `getBotPinRowByKind` — the replace key is `(bot_id, pin_kind)`, global)."
  def get_bot_pin_by_kind(bot_id, pin_kind),
    do:
      first_pin_row(
        {"WHERE pin_owner_kind = 'bot' AND pin_owner_id = $1 AND pin_kind = $2 LIMIT 1",
         [bot_id, pin_kind]}
      )

  @doc "The channel's `session_control` pin (nil when absent)."
  def get_session_control_pin(channel_id),
    do:
      first_pin_row(
        {"WHERE channel_id = $1 AND pin_kind = 'session_control' LIMIT 1", [channel_id]}
      )

  @doc """
  `set_channel_pin` effect (contract §9.7.3): create or **replace** the
  bot's pin of `pin_kind`. Replaces by `(bot_id, pin_kind)` — the existing
  row (if any) keeps its `pin_id` and the event is `channel.pin.updated`;
  a brand-new pin is subject to the channel pin limit (`@max_pins`) and
  emits `channel.pin.set`.

  `bot_summary` is `%{"display_name" => ..., "avatar_url" => ...}` (nil
  values allowed). Returns `{pin_id, event_id, event_frame, new_seq}`.
  """
  def bot_set(channel_id, seq, bot_id, pin_kind, draft_raw, bot_summary)
      when pin_kind in ["bot_control", "announcement"] do
    {:ok, draft} = parse_pin_message_draft(draft_raw)
    now = DateTime.utc_now()
    now_ms = DateTime.to_unix(now, :millisecond)
    existing = get_bot_pin_by_kind(bot_id, pin_kind)

    if is_nil(existing) and count(channel_id) >= @max_pins do
      raise Errors.new("BOT_EFFECT_INVALID", "channel pin limit reached")
    end

    pin_id = if existing, do: existing["pin_id"], else: Ids.uuidv7(now_ms)

    # Old Worker `applySetChannelPinEffect`: a replacement reuses the
    # existing projection id (pin identity is stable; only contents change).
    projection_id =
      if existing do
        existing_projection_id(existing) || Ids.uuidv7(now_ms + 1)
      else
        Ids.uuidv7(now_ms + 1)
      end

    projection = %{
      "projection_id" => projection_id,
      "channel_id" => channel_id,
      "sender" => bot_sender(bot_id, bot_summary),
      "type" => "text",
      "format" => draft["format"],
      "text" => draft["text"],
      "components" => draft["components"],
      "created_at" => Projections.format_ts(now),
      "updated_at" => Projections.format_ts(now)
    }

    event_type = if existing, do: "channel.pin.updated", else: "channel.pin.set"
    {event_id, new_seq} = Ids.monotonic_uuidv7(seq, now_ms)

    # Bot pins carry no `pinned_at` / `expires_at` (old Worker
    # `applySetChannelPinEffect`: both null on create AND replace).
    upsert_bot_pin_row(
      pin_id,
      channel_id,
      pin_kind,
      bot_id,
      projection,
      event_id,
      now,
      pinned_at: nil,
      expires_at: nil
    )

    pin_row = get_row(pin_id)
    pin_wire = project_wire(pin_row, %{})
    wire_payload = %{"pin" => pin_wire}
    insert_pin_event(event_id, event_type, channel_id, wire_payload, meta_mv(channel_id), now)

    frame = Projections.build_event_frame(event_id, event_type, channel_id, now, wire_payload)
    {pin_id, event_id, frame, new_seq}
  end

  @doc """
  `update_channel_pin` effect (contract §9.7.3). `opts`:
    * `:allow_session_control` — `true` on the `session.effects` path: the
      bot may patch the platform session pin (display fields only).
    * `:session_id` — the session the frame was addressed to; a
      session-control pin only updates when its `session_id` matches.

  Returns `{pin_id, event_id, event_frame, new_seq}`.
  """
  def bot_update(channel_id, seq, bot_id, pin_id, patch_raw, opts \\ []) do
    {:ok, patch} = parse_pin_message_patch(patch_raw)
    row = get_row(pin_id)

    if is_nil(row) or row["channel_id"] != channel_id do
      raise Errors.new("BOT_EFFECT_INVALID", "pin not found")
    end

    {owner_kind, owner_id} = {row["pin_owner_kind"], row["pin_owner_id"]}

    cond do
      owner_kind == "bot" and owner_id == bot_id ->
        :ok

      owner_kind == "platform" and row["pin_kind"] == "session_control" ->
        unless Keyword.get(opts, :allow_session_control) do
          raise Errors.new(
                  "BOT_EFFECT_INVALID",
                  "cannot update session_control pin from delivery_result"
                )
        end

        if Map.has_key?(patch, "components") do
          raise Errors.new("BOT_EFFECT_INVALID", "cannot patch components on session_control pin")
        end

        session_id = Keyword.get(opts, :session_id)

        if is_binary(session_id) and row["session_id"] != session_id do
          raise Errors.new("BOT_EFFECT_INVALID", "session pin not found")
        end

        :ok

      owner_kind == "bot" ->
        raise Errors.new("BOT_EFFECT_INVALID", "cannot update another bot pin")

      true ->
        raise Errors.new("BOT_EFFECT_INVALID", "cannot update this pin")
    end

    now = DateTime.utc_now()
    now_ms = DateTime.to_unix(now, :millisecond)
    existing_projection = Projections.json_map(row["message_projection_json"])
    merged = merge_pin_projection(existing_projection, patch, now)

    {event_id, new_seq} = Ids.monotonic_uuidv7(seq, now_ms)

    upsert_bot_pin_row(
      row["pin_id"],
      channel_id,
      row["pin_kind"],
      row["pin_owner_id"],
      merged,
      event_id,
      now,
      session_id: row["session_id"],
      pinned_by_user_id: row["pinned_by_user_id"],
      priority: row["priority"],
      pinned_at: row["pinned_at"],
      expires_at: row["expires_at"]
    )

    pin_row = get_row(row["pin_id"])
    pin_wire = project_wire(pin_row, %{})
    wire_payload = %{"pin" => pin_wire}

    insert_pin_event(
      event_id,
      "channel.pin.updated",
      channel_id,
      wire_payload,
      meta_mv(channel_id),
      now
    )

    frame =
      Projections.build_event_frame(
        event_id,
        "channel.pin.updated",
        channel_id,
        now,
        wire_payload
      )

    {row["pin_id"], event_id, frame, new_seq}
  end

  @doc """
  `clear_channel_pin` effect (contract §9.7.3): the bot may clear only its
  own `bot_control` / `announcement` pins — never `session_control` or
  `pinned_message`. Returns `{pin_id, event_id, event_frame, new_seq}`.
  """
  def bot_clear(channel_id, seq, bot_id, pin_id) do
    row = get_row(pin_id)

    if is_nil(row) or row["channel_id"] != channel_id do
      raise Errors.new("BOT_EFFECT_INVALID", "pin not found")
    end

    unless row["pin_owner_kind"] == "bot" and row["pin_owner_id"] == bot_id do
      raise Errors.new("BOT_EFFECT_INVALID", "cannot clear this pin")
    end

    if row["pin_kind"] in ["session_control", "pinned_message"] do
      raise Errors.new("BOT_EFFECT_INVALID", "cannot clear this pin kind")
    end

    now = DateTime.utc_now()
    now_ms = DateTime.to_unix(now, :millisecond)
    {event_id, new_seq} = Ids.monotonic_uuidv7(seq, now_ms)

    Repo.query!("DELETE FROM chat_v2.channel_pins WHERE pin_id = $1", [row["pin_id"]])

    wire_payload = %{
      "pin_id" => row["pin_id"],
      "channel_id" => channel_id,
      "pin_kind" => row["pin_kind"],
      "source_message_id" => row["source_message_id"]
    }

    insert_pin_event(
      event_id,
      "channel.pin.cleared",
      channel_id,
      wire_payload,
      meta_mv(channel_id),
      now
    )

    frame =
      Projections.build_event_frame(
        event_id,
        "channel.pin.cleared",
        channel_id,
        now,
        wire_payload
      )

    {row["pin_id"], event_id, frame, new_seq}
  end

  @doc """
  Delete the channel's session-control pin for a session (close path).
  Returns the deleted row or nil (runs inside the caller's txn).
  """
  def clear_by_session(channel_id, session_id) do
    case Query.rows(
           Repo.query(
             """
             SELECT pin_id, channel_id, pin_kind, pin_owner_kind, pin_owner_id, priority,
                    session_id, source_message_id, pinned_by_user_id, pinned_at, expires_at,
                    last_pin_event_id, message_projection_json
             FROM chat_v2.channel_pins
             WHERE channel_id = $1 AND pin_kind = 'session_control' AND session_id = $2
             LIMIT 1
             """,
             [channel_id, session_id],
             type: true
           )
         ) do
      [row] ->
        Repo.query!("DELETE FROM chat_v2.channel_pins WHERE pin_id = $1", [row["pin_id"]])
        row

      _ ->
        nil
    end
  end

  # ------------------------------------------------ session-control pin (#19)

  @doc """
  Build a platform `session_control` pin projection (contract §9.12.2,
  old Worker `buildSessionControlPinProjection`). `component_id` is the
  Stop button id; `opts`: `:projection_id`, `:stop_disabled`, `:stop_label`,
  `:status_text`, `:pinned_at` (defaults: the Stop button enabled, label
  "停止", default status text).
  """
  def session_control_projection(
        channel_id,
        component_id,
        command_name,
        started_by_display_name,
        now,
        opts \\ []
      ) do
    status_text =
      Keyword.get(
        opts,
        :status_text,
        "**/#{command_name}** 进行中 · 由 @#{started_by_display_name} 发起"
      )

    %{
      "projection_id" => Keyword.get(opts, :projection_id) || Ids.uuidv7(),
      "channel_id" => channel_id,
      "sender" => %{
        "kind" => "bot",
        "bot" => CommandManifest.platform_bot()
      },
      "type" => "text",
      "format" => "markdown",
      "text" => status_text,
      "components" => [
        %{
          "component_id" => component_id,
          "kind" => "button",
          "custom_id" => BotGateway.platform_stop_session_custom_id(),
          "label" => Keyword.get(opts, :stop_label, "停止"),
          "style" => "danger",
          "disabled" => Keyword.get(opts, :stop_disabled, false),
          "interaction_policy" => "per_user_once"
        }
      ],
      "created_at" => Keyword.get(opts, :created_at, Projections.format_ts(now)),
      "updated_at" => Projections.format_ts(now)
    }
  end

  @doc """
  Rebuild a session-control projection with the Stop button disabled +
  relabeled (graceful-stop `channel.pin.updated` step). Keeps the existing
  `component_id`, text, and projection id.
  """
  def disable_stop_component(projection) when is_map(projection) do
    components =
      for component <- projection["components"] || [] do
        if is_map(component) and
             component["custom_id"] == BotGateway.platform_stop_session_custom_id() do
          Map.merge(component, %{"disabled" => true, "label" => "正在停止…"})
        else
          component
        end
      end

    now = DateTime.utc_now()

    Map.put(projection, "components", components)
    |> Map.put("updated_at", Projections.format_ts(now))
  end

  @doc """
  Persist (upsert) a platform `session_control` pin row for a session
  (session start seam, issue #20 consumes this). Runs inside the caller's
  txn. Returns the pin row.
  """
  def upsert_session_control(
        channel_id,
        session_id,
        command_name,
        started_by_display_name,
        opts \\ []
      ) do
    now = DateTime.utc_now()
    now_ms = DateTime.to_unix(now, :millisecond)

    pin_id = Keyword.get(opts, :pin_id) || Ids.uuidv7(now_ms)
    component_id = Keyword.get(opts, :component_id) || Ids.uuidv7(now_ms + 2)

    projection =
      session_control_projection(
        channel_id,
        component_id,
        command_name,
        started_by_display_name,
        now,
        projection_id: Keyword.get(opts, :projection_id) || Ids.uuidv7(now_ms + 1),
        stop_disabled: Keyword.get(opts, :stop_disabled, false),
        stop_label: Keyword.get(opts, :stop_label),
        status_text: Keyword.get(opts, :status_text)
      )

    # Old Worker session-pin creation: `pinned_at` stays null; `expires_at`
    # follows the session TTL (pass `:expires_at`).
    upsert_bot_pin_row(
      pin_id,
      channel_id,
      "session_control",
      CommandManifest.platform_bot()["bot_id"],
      projection,
      Keyword.get(opts, :last_pin_event_id) || Ids.uuidv7(now_ms + 3),
      now,
      session_id: session_id,
      pinned_by_user_id: nil,
      priority: @session_control_priority,
      pinned_at: Keyword.get(opts, :pinned_at),
      expires_at: Keyword.get(opts, :expires_at),
      owner_kind: "platform"
    )

    get_row(pin_id)
  end

  # pin draft / patch parse (old Worker `parsePinMessageDraft` /
  # `parsePinMessagePatch`) — always `BOT_EFFECT_INVALID` on failure.
  def parse_pin_message_draft(raw) when is_map(raw) do
    format =
      case raw["format"] do
        value when is_binary(value) and value in @allowed_message_formats ->
          value

        _ ->
          raise Errors.new("BOT_EFFECT_INVALID", "invalid pin message format")
      end

    text =
      case raw["text"] do
        nil ->
          nil

        value when is_binary(value) ->
          value

        _ ->
          raise Errors.new("BOT_EFFECT_INVALID", "pin message text must be string or null")
      end

    components_raw =
      case raw["components"] do
        list when is_list(list) -> list
        _ -> raise Errors.new("BOT_EFFECT_INVALID", "pin message components must be an array")
      end

    components =
      case Components.validate(components_raw) do
        {:ok, components} ->
          components

        {:error, reason} ->
          raise Errors.new("BOT_EFFECT_INVALID", reason)
      end

    case Components.reject_platform_custom_ids(components) do
      :ok -> :ok
      {:error, reason} -> raise Errors.new("BOT_EFFECT_INVALID", reason)
    end

    if (is_nil(text) or text == "") and components == [] do
      raise Errors.new("BOT_EFFECT_INVALID", "pin message requires text or components")
    end

    {:ok, %{"format" => format, "text" => text, "components" => components}}
  end

  def parse_pin_message_draft(_),
    do: raise(Errors.new("BOT_EFFECT_INVALID", "pin message draft must be an object"))

  def parse_pin_message_patch(raw) when is_map(raw) do
    # Presence, not value, is the patch contract: an explicit `text: null`
    # CLEARS the text on merge (old Worker `mergePinMessageProjection`).
    has_format? = Map.has_key?(raw, "format")
    has_text? = Map.has_key?(raw, "text")
    has_components? = Map.has_key?(raw, "components")

    format =
      case Map.fetch(raw, "format") do
        {:ok, value} when is_binary(value) and value in @allowed_message_formats ->
          value

        {:ok, _} ->
          raise Errors.new("BOT_EFFECT_INVALID", "invalid pin message format")

        :error ->
          nil
      end

    text =
      case Map.fetch(raw, "text") do
        {:ok, nil} ->
          nil

        {:ok, value} when is_binary(value) ->
          value

        {:ok, _} ->
          raise Errors.new("BOT_EFFECT_INVALID", "pin message text must be string or null")

        :error ->
          nil
      end

    components =
      case Map.fetch(raw, "components") do
        {:ok, list} when is_list(list) ->
          case Components.validate(list) do
            {:ok, components} ->
              case Components.reject_platform_custom_ids(components) do
                :ok -> components
                {:error, reason} -> raise Errors.new("BOT_EFFECT_INVALID", reason)
              end

            {:error, reason} ->
              raise Errors.new("BOT_EFFECT_INVALID", reason)
          end

        {:ok, _} ->
          raise Errors.new("BOT_EFFECT_INVALID", "pin message components must be an array")

        :error ->
          nil
      end

    unless has_format? or has_text? or has_components? do
      raise Errors.new("BOT_EFFECT_INVALID", "pin message patch requires at least one field")
    end

    patch =
      %{}
      |> then(&if(has_format?, do: Map.put(&1, "format", format), else: &1))
      |> then(&if(has_text?, do: Map.put(&1, "text", text), else: &1))
      |> then(&if(has_components?, do: Map.put(&1, "components", components), else: &1))

    {:ok, patch}
  end

  def parse_pin_message_patch(_),
    do: raise(Errors.new("BOT_EFFECT_INVALID", "pin message patch must be an object"))

  @doc """
  Merge a patch into an existing projection (old Worker
  `mergePinMessageProjection`). A patch `text: null` clears the text.
  """
  def merge_pin_projection(existing, patch, now) do
    %{
      existing
      | "format" => Map.get(patch, "format", existing["format"]),
        "text" => if(Map.has_key?(patch, "text"), do: patch["text"], else: existing["text"]),
        "components" => Map.get(patch, "components", existing["components"]),
        "updated_at" => Projections.format_ts(now)
    }
  end

  defp bot_sender(bot_id, summary) do
    %{
      "kind" => "bot",
      "bot" => %{
        "bot_id" => bot_id,
        "display_name" => (summary && summary["display_name"]) || bot_id,
        "avatar_url" => summary && summary["avatar_url"]
      }
    }
  end

  # Bot/platform pins: full mutable-column upsert (the user-pin `upsert_row`
  # helper only touches user-pin columns; a bot pin replacement may move
  # channels, so `channel_id` is updated on conflict too).
  defp upsert_bot_pin_row(
         pin_id,
         channel_id,
         pin_kind,
         pin_owner_id,
         projection,
         last_pin_event_id,
         now,
         opts
       ) do
    priority = Keyword.get(opts, :priority) || bot_pin_priority(pin_kind)
    pinned_at = Keyword.get(opts, :pinned_at)
    expires_at = Keyword.get(opts, :expires_at)
    session_id = Keyword.get(opts, :session_id)
    pinned_by_user_id = Keyword.get(opts, :pinned_by_user_id)
    owner_kind = Keyword.get(opts, :owner_kind, "bot")

    Repo.query!(
      """
      INSERT INTO chat_v2.channel_pins (
        pin_id, channel_id, pin_kind, pin_owner_kind, pin_owner_id, priority,
        session_id, source_message_id, pinned_by_user_id, pinned_at, expires_at,
        last_pin_event_id, message_projection_json, created_at, updated_at
      ) VALUES ($1, $2, $3, $12, $4, $5, $6, NULL, $7, $8, $9, $10, $11, $13, $13)
      ON CONFLICT (pin_id) DO UPDATE SET
        channel_id = EXCLUDED.channel_id,
        priority = EXCLUDED.priority,
        session_id = EXCLUDED.session_id,
        pinned_by_user_id = EXCLUDED.pinned_by_user_id,
        pinned_at = EXCLUDED.pinned_at,
        expires_at = EXCLUDED.expires_at,
        last_pin_event_id = EXCLUDED.last_pin_event_id,
        message_projection_json = EXCLUDED.message_projection_json,
        updated_at = EXCLUDED.updated_at
      """,
      [
        pin_id,
        channel_id,
        pin_kind,
        pin_owner_id,
        priority,
        session_id,
        pinned_by_user_id,
        pinned_at,
        expires_at,
        last_pin_event_id,
        projection,
        owner_kind,
        now
      ],
      type: true
    )
  end

  defp existing_projection_id(row) do
    (Projections.json_map(row["message_projection_json"]) || %{})["projection_id"]
  end

  # Bot/platform pin events carry the channel's current membership version
  # (old Worker `persistChannelPinEvent` writes `mv` too).
  defp meta_mv(channel_id) do
    case Query.rows(
           Repo.query(
             "SELECT membership_version FROM chat_v2.channels WHERE channel_id = $1",
             [channel_id]
           )
         ) do
      [%{"membership_version" => mv}] -> mv
      _ -> 0
    end
  end

  # ------------------------------------------------ unpin_message internals

  defp do_unpin(channel_id, seq, user_id, command_id, pin_id, source_message_id, request_hash) do
    meta =
      Query.rows(
        Repo.query(
          "SELECT channel_id, kind, status, membership_version FROM chat_v2.channels WHERE channel_id = $1",
          [channel_id]
        )
      )

    meta =
      case meta do
        [] ->
          raise Errors.new("CHANNEL_NOT_FOUND", "channel not found")

        [meta] ->
          meta
      end

    if meta["kind"] == "dm" do
      raise Errors.new("UNSUPPORTED_CHANNEL_KIND", "operation not supported for DM channels")
    end

    if meta["status"] == "dissolved" do
      raise Errors.new("CHANNEL_DISSOLVED", "channel is dissolved")
    end

    role = active_role(channel_id, user_id)

    unless role do
      raise Errors.new("FORBIDDEN", "not a channel member")
    end

    unless role in ["owner", "admin"] do
      raise Errors.new("PIN_FORBIDDEN", "only owner or admin can pin messages")
    end

    now = DateTime.utc_now()
    now_ms = DateTime.to_unix(now, :millisecond)
    mv = meta["membership_version"]

    result =
      Repo.transaction(fn ->
        case Idempotency.check("user", user_id, @op_unpin, command_id, request_hash) do
          {:conflict, api_error} ->
            Repo.rollback(%{kind: :error, error: api_error})

          {:cached, response} ->
            %{kind: :cached, ack_frame: response}

          :missing ->
            row =
              case pin_id do
                nil -> pinned_message_row(channel_id, source_message_id)
                id -> get_row(id)
              end

            cond do
              is_nil(row) or row["channel_id"] != channel_id ->
                Repo.rollback(%{
                  kind: :error,
                  error: Errors.new("PIN_NOT_FOUND", "pin not found")
                })

              row["pin_kind"] != "pinned_message" ->
                Repo.rollback(%{
                  kind: :error,
                  error: Errors.new("PIN_FORBIDDEN", "cannot unpin this pin kind")
                })

              true ->
                Repo.query!(
                  "DELETE FROM chat_v2.channel_pins WHERE pin_id = $1",
                  [row["pin_id"]]
                )

                {event_id, new_seq} = Ids.monotonic_uuidv7(seq, now_ms)

                wire_payload = %{
                  "pin_id" => row["pin_id"],
                  "channel_id" => channel_id,
                  "pin_kind" => row["pin_kind"],
                  "source_message_id" => row["source_message_id"]
                }

                insert_pin_event(
                  event_id,
                  "channel.pin.cleared",
                  channel_id,
                  wire_payload,
                  mv,
                  now
                )

                ack =
                  Frames.command_ack(
                    @op_unpin,
                    command_id,
                    %{
                      "channel_id" => channel_id,
                      "event_id" => event_id
                    }
                  )

                write_idem(user_id, command_id, request_hash, ack)

                frame =
                  Projections.build_event_frame(
                    event_id,
                    "channel.pin.cleared",
                    channel_id,
                    now,
                    wire_payload
                  )
                  |> Map.put("membership_version_at_event", mv)

                %{
                  kind: :created,
                  ack_frame: ack,
                  event_frames: [frame],
                  seq: new_seq
                }
            end
        end
      end)

    case result do
      {:ok, %{kind: :created, ack_frame: ack, event_frames: frames, seq: new_seq}} ->
        {%{kind: :created, ack_frame: ack, event_frames: frames}, new_seq}

      {:ok, %{kind: :cached, ack_frame: response}} ->
        {%{kind: :cached, ack_frame: response}, seq}

      {:error, %{kind: :error, error: api_error}} ->
        {%{kind: :error, error: api_error}, seq}
    end
  end

  # ----------------------------------------------------------------- rows

  # A `channel_pins` row as decoded by `Repo.query(..., type: true)`.
  @type pin_row :: map()

  @doc "All active pin rows of a channel in render order (priority ASC, pin_id ASC)."
  @spec list_rows(binary) :: [pin_row]
  def list_rows(channel_id) do
    Query.rows(
      Repo.query(
        """
        SELECT pin_id, channel_id, pin_kind, pin_owner_kind, pin_owner_id, priority,
               session_id, source_message_id, pinned_by_user_id, pinned_at, expires_at,
               last_pin_event_id, message_projection_json
        FROM chat_v2.channel_pins
        WHERE channel_id = $1
        ORDER BY priority ASC, pin_id ASC
        """,
        [channel_id],
        type: true
      )
    )
  end

  @doc "One pin row by `pin_id` (nil when absent)."
  @spec get_row(binary) :: pin_row | nil
  def get_row(pin_id), do: first_pin_row({"WHERE pin_id = $1", [pin_id]})

  @doc "The `pinned_message` pin row for a source message (nil when absent)."
  @spec pinned_message_row(binary, binary) :: pin_row | nil
  def pinned_message_row(channel_id, source_message_id),
    do:
      first_pin_row(
        {"WHERE channel_id = $1 AND source_message_id = $2 LIMIT 1",
         [channel_id, source_message_id]}
      )

  @spec first_pin_row({binary, [term]}) :: pin_row | nil
  defp first_pin_row({where, params}) do
    case Query.rows(
           Repo.query(
             """
             SELECT pin_id, channel_id, pin_kind, pin_owner_kind, pin_owner_id, priority,
                    session_id, source_message_id, pinned_by_user_id, pinned_at, expires_at,
                    last_pin_event_id, message_projection_json
             FROM chat_v2.channel_pins
             """ <> where,
             params,
             type: true
           )
         ) do
      [row] when is_map(row) -> row
      _ -> nil
    end
  end

  defp count(channel_id) do
    Repo.query(
      "SELECT COUNT(*) AS n FROM chat_v2.channel_pins WHERE channel_id = $1",
      [channel_id]
    )
    |> case do
      {:ok, %{num_rows: 1, rows: [[n]]}} -> n
      _ -> 0
    end
  end

  defp upsert_row(fields) do
    Repo.query!(
      """
      INSERT INTO chat_v2.channel_pins (
        pin_id, channel_id, pin_kind, pin_owner_kind, pin_owner_id, priority,
        session_id, source_message_id, pinned_by_user_id, pinned_at, expires_at,
        last_pin_event_id, message_projection_json, created_at, updated_at
      ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $14)
      ON CONFLICT (pin_id) DO UPDATE SET
        pinned_by_user_id = EXCLUDED.pinned_by_user_id,
        pinned_at = EXCLUDED.pinned_at,
        last_pin_event_id = EXCLUDED.last_pin_event_id,
        message_projection_json = EXCLUDED.message_projection_json,
        updated_at = EXCLUDED.updated_at
      """,
      [
        fields["pin_id"],
        fields["channel_id"],
        fields["pin_kind"],
        fields["pin_owner_kind"],
        fields["pin_owner_id"],
        fields["priority"],
        fields["session_id"],
        fields["source_message_id"],
        fields["pinned_by_user_id"],
        fields["pinned_at"],
        fields["expires_at"],
        fields["last_pin_event_id"],
        fields["message_projection_json"],
        fields["now"]
      ],
      type: true
    )
  end

  @doc """
  Lifecycle sync (called from `LiliumChat.MessageMutate` inside its txn):
  refresh the projection + `last_pin_event_id` of an existing pin after the
  source message was edited (contract §6.3 — `channel.pin.updated`; old Worker
  `syncPinnedMessageForSourceMessageMutation`). `pinned_at` / owner / priority
  are preserved.
  """
  def upsert_for_lifecycle(row, projection, last_pin_event_id, now) do
    Repo.query!(
      """
      UPDATE chat_v2.channel_pins SET
        message_projection_json = $2,
        last_pin_event_id = $3,
        updated_at = $4
      WHERE pin_id = $1
      """,
      [row["pin_id"], projection, last_pin_event_id, now],
      type: true
    )
  end

  defp insert_pin_event(event_id, event_type, channel_id, payload, mv, now) do
    Repo.query!(
      """
      INSERT INTO chat_v2.events (
        event_id, event_type, channel_id, actor_kind, actor_id, payload,
        membership_version_at_event, occurred_at
      ) VALUES ($1, $2, $3, 'system', NULL, $4, $5, $6)
      """,
      [event_id, event_type, channel_id, payload, mv, now],
      type: true
    )
  end

  # ------------------------------------------------------- source loading

  # old Worker `loadPinSourceMessage`: the pinned source must be a settled text
  # message of the same channel (type text, status normal/edited, stream_state
  # none/final).
  defp load_pin_source_message(channel_id, source_message_id) do
    row =
      Query.rows(
        Repo.query(
          """
          SELECT message_id, channel_id, sender_kind, sender_user_id, sender_bot_id,
                 type, format, status, stream_state, text, created_at, updated_at
          FROM chat_v2.messages
          WHERE channel_id = $1 AND message_id = $2
          """,
          [channel_id, source_message_id],
          type: true
        )
      )
      |> List.first()

    cond do
      is_nil(row) ->
        raise Errors.new("MESSAGE_NOT_FOUND", "message not found")

      row["type"] != "text" ->
        raise Errors.new("PIN_SOURCE_INVALID", "only text messages can be pinned")

      row["status"] not in ["normal", "edited"] ->
        raise Errors.new("PIN_SOURCE_INVALID", "message status cannot be pinned")

      row["stream_state"] not in ["none", "final"] ->
        raise Errors.new("PIN_SOURCE_INVALID", "streaming message cannot be pinned")

      true ->
        row
    end
  end

  defp active_role(channel_id, user_id) do
    Query.rows(
      Repo.query(
        "SELECT role FROM chat_v2.channel_members WHERE channel_id = $1 AND user_id = $2 AND status = 'active'",
        [channel_id, user_id]
      )
    )
    |> List.first()
    |> case do
      %{"role" => role} -> role
      _ -> nil
    end
  end

  # ---------------------------------------------------------- projections

  @doc """
  Project a `channel_pins` row into the `ChannelPin` wire shape
  (contract §3.10.3). `pinned_by` may be passed pre-resolved (the pin/unpin
  acks pass the *current* actor's summary, old Worker parity); otherwise it is
  resolved from `pinned_by_user_id`.
  """
  def project_wire(row, profiles, pinned_by \\ nil) do
    pinned_by =
      pinned_by ||
        (row["pinned_by_user_id"] && Projections.user_summary(row["pinned_by_user_id"], profiles))

    %{
      "pin_id" => row["pin_id"],
      "channel_id" => row["channel_id"],
      "pin_kind" => row["pin_kind"],
      "pin_owner_kind" => row["pin_owner_kind"],
      "pin_owner_id" => row["pin_owner_id"],
      "priority" => row["priority"],
      "session_id" => row["session_id"],
      "source_message_id" => row["source_message_id"],
      "pinned_by" => pinned_by,
      "pinned_at" => Projections.format_ts(row["pinned_at"]),
      "expires_at" => Projections.format_ts(row["expires_at"]),
      "last_pin_event_id" => row["last_pin_event_id"],
      "message" => Projections.json_map(row["message_projection_json"])
    }
  end

  @doc """
  Build a `PinMessageProjection` (contract §3.10) for a pinned source message.
  `created_at` is the source message's; `updated_at` is the pin time.
  """
  def build_message_projection(message_row, projection_id, now, profiles) do
    %{
      "projection_id" => projection_id,
      "channel_id" => message_row["channel_id"],
      "sender" => Projections.project_sender(message_row, profiles),
      "type" => "text",
      "format" => message_row["format"] || "plain",
      "text" => message_row["text"],
      "components" => [],
      "created_at" => Projections.format_ts(message_row["created_at"]),
      "updated_at" => Projections.format_ts(now)
    }
  end

  # old Worker `pinProjectionsEqual`: only format / text / components decide a
  # re-pin no-op.
  defp projection_equal?(existing_row, projection) do
    stored = Projections.json_map(existing_row["message_projection_json"]) || %{}

    stored["format"] == projection["format"] and
      stored["text"] == projection["text"] and
      stored["components"] == projection["components"]
  end

  # --------------------------------------------------------------- helpers

  defp write_idem(user_id, command_id, request_hash, response) do
    op = Map.get(response, "command")
    Idempotency.write_completed("user", user_id, op, command_id, request_hash, response)
  end
end
