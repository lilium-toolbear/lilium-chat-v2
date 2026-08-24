defmodule LiliumChat.StatefulSessions do
  @moduledoc """
  Stateful command sessions (contract §9.12, spec v2.31, issue #19).

  Runtime operations on `chat_v2.stateful_command_sessions` + the
  platform `session_control` pin:

  * `request_stop/3` — the `platform:stop_session` platform shortcut
    (contract §9.12.2): `closing` + Stop disabled + `channel.pin.updated`
    + `session.stop_requested` + stop-grace timer;
  * `handle_session_effects/3` — `session.effects` (pin-only allowlist,
    `effect_seq` gating, `session_effect` idempotency);
  * `handle_session_close/3` — Bot `session.close`;
  * `close/4` — shared close: `stateful_session.closed` (+
    `channel.pin.cleared` when the session pin is removed) +
    `session.closed` frame to the bot;
  * `enqueue_input/3` — listen-rules input enqueue on `message.created`
    (`stateful_session_inputs` + `session.input` frame);
  * `handle_input_ack/2` — `session.input_ack` accounting;
  * `submit_interaction/3` — Browser `interaction.submit` (pin / message
    locator; the A5 `platform:stop_session` short-circuit);
  * `resume_input_frames/1` — unacked `session.input` frames for a bot
    reconnect (old Worker `resumeStatefulSessions`).

  Every op runs on the per-channel writer (`LiliumChat.Channel`): writers
  allocate the per-channel `event_id`s from the in-memory `seq` and run
  their PG writes in a single transaction, so the returned
  `{result, new_seq}` follows the repo's writer convention
  (`LiliumChat.MessageSend.send/3`).

  Session **start** (`session.start` / `start_ack`, the session-control pin
  create, TTL resolution) is issue #20's `command.invoke`; this module
  exposes `seed_active/1` + `ChannelPins.upsert_session_control/5` as the
  seam both for #20 and for tests.
  """

  alias LiliumChat.{
    BotEffects,
    BotConnection,
    BotDelivery,
    BotGateway,
    CanonicalJSON,
    ChannelPins,
    Errors,
    Idempotency,
    Ids,
    Profiles,
    Projections,
    Query,
    Repo
  }

  # Old Worker `SESSION_STOP_GRACE_MS` / `SESSION_START_TIMEOUT_MS`.
  @stop_grace_ms 30_000
  @max_pending_inputs 1_000
  @active_statuses ~w(starting active suspended closing)
  @terminal_statuses ~w(closed expired failed)

  @doc "Stop-grace window in ms (contract §9.7.4: `grace_timeout_ms`)."
  def stop_grace_ms(), do: @stop_grace_ms

  @doc "Session statuses that count as 'active' (mutex + stoppable set)."
  def active_statuses(), do: @active_statuses

  # ------------------------------------------------------------------ seeds

  @doc """
  Insert a stateful session row (issue #20 seam + tests). `attrs`:
  `:channel_id`, `:bot_id`, `:bot_command_id` (default `"command"`),
  `:invocation_id` (default a fresh id), `:started_by_user_id`
  (default `"starter"`), `:status` (default `"active"`), `:listen_rules`
  (map, default `%{"message_types" => ["text"],
  "include_bot_messages" => false, "include_own_messages" => false}`),
  `:expires_at` (default now + 300s), optional `:session_id`.

  Returns the row map.
  """
  def seed_active(attrs) do
    session_id = attrs[:session_id] || Ids.uuidv7()
    now = DateTime.utc_now()

    listen_rules =
      attrs[:listen_rules] ||
        %{
          "message_types" => ["text"],
          "include_bot_messages" => false,
          "include_own_messages" => false
        }

    summary =
      attrs[:summary] ||
        %{
          "command_name" => attrs[:command_name] || "stateful",
          "started_by_display_name" => attrs[:started_by_display_name] || "starter"
        }

    Repo.query!(
      """
      INSERT INTO chat_v2.stateful_command_sessions
        (session_id, channel_id, bot_id, bot_command_id, invocation_id,
         started_by_user_id, status, listen_rules_json, input_next_seq,
         input_last_acked_seq, effect_last_acked_seq, started_at, expires_at,
         summary_json, stop_grace_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 1, 0, 0, $9, $10, $11, NULL)
      """,
      [
        session_id,
        attrs[:channel_id],
        attrs[:bot_id],
        attrs[:bot_command_id] || "command",
        attrs[:invocation_id] || Ids.uuidv7(),
        attrs[:started_by_user_id] || "starter",
        attrs[:status] || "active",
        listen_rules,
        now,
        attrs[:expires_at] || DateTime.add(now, 300, :second),
        summary
      ],
      type: true
    )

    get(session_id)
  end

  # ------------------------------------------------------------------ loads

  @doc "One session row by id (nil when absent)."
  def get(session_id) do
    Query.rows(
      Repo.query(
        """
        SELECT session_id, channel_id, bot_id, bot_command_id, invocation_id,
               started_by_user_id, status, listen_rules_json, input_next_seq,
               input_last_acked_seq, effect_last_acked_seq, started_at,
               expires_at, closed_at, close_reason, summary_json, stop_grace_at
        FROM chat_v2.stateful_command_sessions
        WHERE session_id = $1
        """,
        [session_id],
        type: true
      )
    )
    |> List.first()
  end

  @doc "The channel's `active` session (input enqueue target), or nil."
  def active_in_channel(channel_id) do
    Query.rows(
      Repo.query(
        """
        SELECT session_id, channel_id, bot_id, started_by_user_id, status,
               listen_rules_json, input_next_seq
        FROM chat_v2.stateful_command_sessions
        WHERE channel_id = $1 AND status = 'active'
        LIMIT 1
        """,
        [channel_id],
        type: true
      )
    )
    |> List.first()
  end

  @doc "Non-terminal sessions of a channel (writer (re)start re-arm)."
  def active_rows(channel_id) do
    Query.rows(
      Repo.query(
        """
        SELECT session_id, status, started_at, expires_at, closed_at, close_reason,
               stop_grace_at
        FROM chat_v2.stateful_command_sessions
        WHERE channel_id = $1 AND status IN ('starting', 'active', 'suspended', 'closing')
        """,
        [channel_id],
        type: true
      )
    )
  end

  # ------------------------------------------------------------- request_stop

  @doc """
  The `platform:stop_session` platform shortcut (contract §9.12.2).
  `attrs`: `:pin_id`, `:user_id` (the clicker), `:admin` (bool — owner/admin
  already resolved by the caller).

  Gate order (old Worker `applyPlatformStopSessionInTxn`):
  pin in channel → `PIN_NOT_FOUND`; pin is `session_control` platform-owned
  with a `session_id` → `INVALID_MESSAGE`; session exists in channel →
  `STATEFUL_SESSION_NOT_FOUND`; `closing` → `SESSION_STOP_IN_PROGRESS`;
  status in `starting|active|suspended` → else `STATEFUL_SESSION_NOT_ACTIVE`;
  actor is starter or owner/admin → `FORBIDDEN`; the Stop component exists
  (`COMPONENT_NOT_FOUND`) and is enabled (`COMPONENT_DISABLED`).

  On success: ONE txn writes `status = 'closing'` + `stop_grace_at`, the
  Stop-disabled pin projection + `channel.pin.updated` event. Returns
  `{result, new_seq}` where `result` carries the committed-ack payload, the
  event frame, the `session.stop_requested` frame, and the grace target.
  """
  def request_stop(channel_id, seq, attrs) do
    pin = ChannelPins.get_row(attrs[:pin_id])

    if is_nil(pin) or pin["channel_id"] != channel_id do
      raise Errors.new("PIN_NOT_FOUND", "pin not found")
    end

    unless pin["pin_kind"] == "session_control" and pin["pin_owner_kind"] == "platform" do
      raise Errors.new("INVALID_MESSAGE", "pin is not a session control pin")
    end

    session_id = pin["session_id"]

    unless is_binary(session_id) and session_id != "" do
      raise Errors.new("PIN_NOT_FOUND", "pin not bound to a session")
    end

    session = get(session_id)

    if is_nil(session) or session["channel_id"] != channel_id do
      raise Errors.new("STATEFUL_SESSION_NOT_FOUND", "session not found")
    end

    cond do
      session["status"] == "closing" ->
        raise Errors.new("SESSION_STOP_IN_PROGRESS", "session stop in progress")

      session["status"] in ["starting", "active", "suspended"] ->
        :ok

      true ->
        raise Errors.new("STATEFUL_SESSION_NOT_ACTIVE", "session not active")
    end

    actor_ok? =
      attrs[:user_id] == session["started_by_user_id"] or attrs[:admin] == true

    unless actor_ok? do
      raise Errors.new("FORBIDDEN", "only the starter or an owner/admin can stop")
    end

    projection = Projections.json_map(pin["message_projection_json"]) || %{}

    stop_component =
      Enum.find(
        projection["components"] || [],
        fn component ->
          is_map(component) and
            component["custom_id"] == BotGateway.platform_stop_session_custom_id()
        end
      )

    unless is_map(stop_component) do
      raise Errors.new("COMPONENT_NOT_FOUND", "stop component not found")
    end

    if stop_component["disabled"] do
      raise Errors.new("COMPONENT_DISABLED", "stop component disabled")
    end

    now = DateTime.utc_now()
    now_ms = DateTime.to_unix(now, :millisecond)
    grace_at = DateTime.add(now, @stop_grace_ms, :millisecond)
    {event_id, new_seq} = Ids.monotonic_uuidv7(seq, now_ms)

    new_projection = ChannelPins.disable_stop_component(projection)

    {:ok, _} =
      Repo.transaction(fn ->
        Repo.query!(
          """
          UPDATE chat_v2.stateful_command_sessions
          SET status = 'closing', stop_grace_at = $2
          WHERE session_id = $1 AND status <> 'closed'
          """,
          [session_id, grace_at],
          type: true
        )

        Repo.query!(
          """
          UPDATE chat_v2.channel_pins
          SET message_projection_json = $2, last_pin_event_id = $3, updated_at = $4
          WHERE pin_id = $1
          """,
          [attrs[:pin_id], new_projection, event_id, now],
          type: true
        )

        pin_row = ChannelPins.get_row(attrs[:pin_id])
        pin_wire = ChannelPins.project_wire(pin_row, %{})
        wire_payload = %{"pin" => pin_wire}

        insert_event(event_id, "channel.pin.updated", channel_id, wire_payload, now)
      end)

    pin_row = ChannelPins.get_row(attrs[:pin_id])
    pin_wire = ChannelPins.project_wire(pin_row, %{})

    frame =
      Projections.build_event_frame(event_id, "channel.pin.updated", channel_id, now, %{
        "pin" => pin_wire
      })

    stop_frame =
      BotGateway.build_session_stop_requested(
        session_id,
        "user_stop",
        attrs[:user_id],
        @stop_grace_ms
      )

    committed_ack = %{
      "channel_id" => channel_id,
      "event_id" => event_id,
      "pin_id" => attrs[:pin_id],
      "session_id" => session_id,
      "custom_id" => BotGateway.platform_stop_session_custom_id()
    }

    {
      %{
        kind: :stopped,
        session_id: session_id,
        push_bot_id: session["bot_id"],
        reply: committed_ack,
        event_frames: [frame],
        push_frames: [stop_frame],
        arm_grace: %{session_id: session_id, at: grace_at}
      },
      new_seq
    }
  end

  # --------------------------------------------------------- session.effects

  @doc """
  Handle a `session.effects` frame (contract §9.7.3). `attrs`: `:bot_id`,
  `:session_id`, `:effect_seq`, `:effects`.

  Returns `{result, new_seq}` with `result.reply` a `session.effects_ack`
  frame. Gating mirrors the old Worker `botSessionEffects`: session exists
  → bot matches → status `active|closing` → channel meta (kind / dissolved)
  → `effect_seq` continuity (replay vs fresh) → pin allowlist → the
  channel's session pin belongs to this session. Fresh applies run through
  `BotEffects.apply_effects/5` with `allow_session_control: true`; the ack
  is persisted in the `session_effect` idempotency namespace keyed
  `(session_id, effect_seq)` (hash = effects minus `client_effect_id`).
  """
  def handle_session_effects(channel_id, seq, attrs) do
    session = get(attrs[:session_id])

    if is_nil(session) or session["channel_id"] != channel_id do
      raise Errors.new("STATEFUL_SESSION_NOT_FOUND", "session not found")
    end

    if session["bot_id"] != attrs[:bot_id] do
      raise Errors.new("BOT_EFFECT_INVALID", "session bot mismatch")
    end

    unless session["status"] in ["active", "closing"] do
      raise Errors.new("STATEFUL_SESSION_NOT_ACTIVE", "session not active")
    end

    meta =
      Query.rows(
        Repo.query(
          "SELECT kind, status FROM chat_v2.channels WHERE channel_id = $1",
          [channel_id]
        )
      )

    case meta do
      [] ->
        raise Errors.new("CHANNEL_NOT_FOUND", "channel not found")

      [%{"kind" => kind, "status" => status}] ->
        if kind == "dm" do
          raise Errors.new("UNSUPPORTED_CHANNEL_KIND", "DM channels are not supported")
        end

        if status == "dissolved" do
          raise Errors.new("CHANNEL_DISSOLVED", "channel is dissolved")
        end
    end

    effect_seq = attrs[:effect_seq]
    last_acked = session["effect_last_acked_seq"]
    is_replay? = effect_seq <= last_acked

    unless is_replay? or effect_seq == last_acked + 1 do
      raise Errors.new("BOT_EFFECT_INVALID", "effect sequence gap")
    end

    effects = attrs[:effects] || []

    for effect <- effects do
      # Non-map entries carry no `type` (old Worker: `String(raw.type)` →
      # "undefined") — reject, don't KeyError the writer.
      type = if is_map(effect), do: Map.get(effect, "type"), else: nil

      unless type in BotGateway.session_gateway_effect_types() do
        raise Errors.new(
                "BOT_EFFECT_INVALID",
                "unsupported effect type on session.effects: #{type_label(type)}"
              )
      end
    end

    session_pin = ChannelPins.get_session_control_pin(channel_id)

    if is_nil(session_pin) or session_pin["session_id"] != session["session_id"] do
      raise Errors.new("BOT_EFFECT_INVALID", "session pin not found")
    end

    hash = BotEffects.session_request_hash(effects)

    cond do
      is_replay? ->
        replay =
          idem_lookup(session["session_id"], effect_seq) ||
            raise(Errors.new("BOT_EFFECT_INVALID", "effect ack not found"))

        unless replay["request_hash"] == hash do
          raise Errors.new("BOT_EFFECT_CONFLICT", "effect_seq reused with different body")
        end

        results =
          case replay["response_json"] do
            list when is_list(list) -> list
            _ -> raise(Errors.new("BOT_EFFECT_INVALID", "stored effect ack invalid"))
          end

        {%{
           kind: :session_effects,
           reply:
             BotGateway.build_session_effects_ack(
               session["session_id"],
               effect_seq,
               "applied",
               %{"effect_results" => results}
             )
         }, seq}

      true ->
        {apply_result, new_seq} =
          BotEffects.apply_effects(channel_id, seq, attrs[:bot_id], effects,
            is_official: BotEffects.bot_official?(attrs[:bot_id]),
            allow_session_control: true,
            session_id: session["session_id"]
          )

        now = DateTime.utc_now()

        Repo.transaction(
          fn ->
            Repo.query!(
              """
              UPDATE chat_v2.stateful_command_sessions
              SET effect_last_acked_seq = $2
              WHERE session_id = $1 AND effect_last_acked_seq = $3
              """,
              [session["session_id"], effect_seq, last_acked],
              type: true
            )

            write_session_idem(
              session["session_id"],
              effect_seq,
              hash,
              apply_result.effect_results,
              now
            )
          end,
          timeout: 30_000
        )

        {%{
           kind: :session_effects,
           reply:
             BotGateway.build_session_effects_ack(
               session["session_id"],
               effect_seq,
               "applied",
               %{"effect_results" => apply_result.effect_results}
             ),
           event_frames: apply_result.event_frames || []
         }, new_seq}
    end
  end

  # ---------------------------------------------------------- session.close

  @doc """
  Handle a Bot `session.close` frame (contract §9.7.4). `attrs`: `:bot_id`,
  `:session_id`, optional `:reason` (defaults to `"bot_closed"`). Returns
  `{result, new_seq}`; `result` carries the close event frames.
  """
  def handle_session_close(channel_id, seq, attrs) do
    session = get(attrs[:session_id])

    if is_nil(session) or session["channel_id"] != channel_id do
      raise Errors.new("STATEFUL_SESSION_NOT_FOUND", "session not found")
    end

    if session["bot_id"] != attrs[:bot_id] do
      raise Errors.new("BOT_EFFECT_INVALID", "session bot mismatch")
    end

    unless session["status"] in ["active", "closing"] do
      raise Errors.new("STATEFUL_SESSION_NOT_ACTIVE", "session not active")
    end

    {result, new_seq} =
      close(channel_id, seq, session["session_id"], attrs[:reason] || "bot_closed")

    {Map.put(result, :kind, :session_closed), new_seq}
  end

  # --------------------------------------------------------------- input ack

  @doc """
  Handle a `session.input_ack` frame: advance `input_last_acked_seq` (monotonic
  guard) and mark inputs `acked`. `attrs`: `:session_id`, `:last_received_seq`.
  """
  def handle_input_ack(channel_id, attrs) do
    session = get(attrs[:session_id])

    if is_nil(session) or session["channel_id"] != channel_id do
      raise Errors.new("STATEFUL_SESSION_NOT_FOUND", "session not found")
    end

    now = DateTime.utc_now()

    {:ok, _} =
      Repo.transaction(fn ->
        # Old Worker parity: only `active` sessions advance the ack cursor
        # (a `closing` session's inputs are drained by the stop flow).
        Repo.query!(
          """
          UPDATE chat_v2.stateful_command_sessions
          SET input_last_acked_seq = GREATEST(input_last_acked_seq, $2)
          WHERE session_id = $1 AND status = 'active'
          """,
          [session["session_id"], attrs[:last_received_seq]],
          type: true
        )

        Repo.query!(
          """
          UPDATE chat_v2.stateful_session_inputs
          SET status = 'acked', acked_at = $3
          WHERE session_id = $1 AND seq <= $2 AND status IN ('pending', 'sent')
          """,
          [session["session_id"], attrs[:last_received_seq], now],
          type: true
        )
      end)

    {:ok, session}
  end

  # -------------------------------------------------------------------- close

  @doc """
  Shared close (old Worker `closeStatefulSession`). No-ops (returns
  `{:noop, seq}`) when the session is already terminal. Reason `"timeout"`
  lands in status `failed`; every other reason lands in `closed`
  (old Worker: TTL timeout → failed; stop_timeout / user_stop / bot_closed
  → closed).

  Emits `channel.pin.cleared` (when the session pin exists) then
  `stateful_session.closed`, and pushes `session.closed` to the bot.
  """
  def close(channel_id, seq, session_id, reason) do
    session = get(session_id)

    cond do
      is_nil(session) or session["channel_id"] != channel_id ->
        {:noop, seq}

      session["status"] in @terminal_statuses ->
        {:noop, seq}

      true ->
        do_close(channel_id, seq, session, reason)
    end
  end

  defp do_close(channel_id, seq, session, reason) do
    now = DateTime.utc_now()
    now_ms = DateTime.to_unix(now, :millisecond)
    new_status = if reason == "timeout", do: "failed", else: "closed"
    session_id = session["session_id"]
    summary = Projections.json_map(session["summary_json"]) || %{}

    # The pin row (checked before the txn) is deleted inside it; the
    # cleared/closed event ids are allocated from the writer seq up front.
    pin_row = pin_row_by_session(channel_id, session_id)

    # Event order = old Worker `closeStatefulSession`: `stateful_session.closed`
    # first (lower event id), then `channel.pin.cleared`.
    {close_event_id, seq1} = Ids.monotonic_uuidv7(seq, now_ms)
    {pin_event_id, seq2} = if pin_row, do: Ids.monotonic_uuidv7(seq1, now_ms), else: {nil, seq1}

    pin_payload =
      if pin_row do
        %{
          "pin_id" => pin_row["pin_id"],
          "channel_id" => channel_id,
          "pin_kind" => "session_control",
          "session_id" => session_id,
          "source_message_id" => pin_row["source_message_id"]
        }
      end

    closed_payload = %{
      "session_id" => session_id,
      "bot_command_id" => session["bot_command_id"],
      "command_name" => summary["command_name"] || session["bot_command_id"],
      "status" => new_status,
      "reason" => reason,
      "closed_at" => Projections.format_ts(now)
    }

    {:ok, _} =
      Repo.transaction(fn ->
        Repo.query!(
          """
          UPDATE chat_v2.stateful_command_sessions
          SET status = $2, close_reason = $3, closed_at = $4
          WHERE session_id = $1 AND status NOT IN ('closed', 'expired', 'failed')
          """,
          [session_id, new_status, reason, now],
          type: true
        )

        insert_event(close_event_id, "stateful_session.closed", channel_id, closed_payload, now)

        if pin_row do
          ChannelPins.clear_by_session(channel_id, session_id)
          insert_event(pin_event_id, "channel.pin.cleared", channel_id, pin_payload, now)
        end
      end)

    frames =
      [
        Projections.build_event_frame(
          close_event_id,
          "stateful_session.closed",
          channel_id,
          now,
          closed_payload
        )
      ] ++
        if pin_row do
          [
            Projections.build_event_frame(
              pin_event_id,
              "channel.pin.cleared",
              channel_id,
              now,
              pin_payload
            )
          ]
        else
          []
        end

    # The bot gets `session.closed` (best-effort push — the session is
    # terminal and the Browser reads state from the timeline events).
    BotConnection.push_nowait(
      session["bot_id"],
      BotGateway.build_session_closed(session_id, new_status, reason)
    )

    {
      %{
        kind: :closed,
        session_id: session_id,
        event_frames: frames
      },
      seq2
    }
  end

  # --------------------------------------------------------------- inputs

  @doc """
  Enqueue a `message.created` listen input for the channel's active session
  (old Worker `enqueueStatefulInputForMessageCreated`). Runs after the
  creating write committed (per-channel writer context). `attrs`:
  `:event_id`, `:occurred_at` (DateTime), `:message` (full Browser-visible
  projection), `:type`, `:sender_kind`, `:sender_user_id`, `:sender_bot_id`.

  Returns `{:ok, new_seq, extra}` — `extra` carries event frames when the
  backlog overflow closed the session.
  """
  def enqueue_input(channel_id, seq, attrs) do
    case active_in_channel(channel_id) do
      nil ->
        {:ok, seq, %{event_frames: []}}

      session ->
        rules = session["listen_rules_json"] || %{}

        unless matches_listen_rules?(attrs, rules, session) do
          {:ok, seq, %{event_frames: []}}
        else
          pending = pending_input_count(session["session_id"])

          if pending > @max_pending_inputs do
            case close(channel_id, seq, session["session_id"], "backlog_overflow") do
              {result, new_seq} when is_map(result) ->
                {:ok, new_seq, %{event_frames: result[:event_frames] || []}}

              {:noop, s} ->
                {:ok, s, %{event_frames: []}}
            end
          else
            do_enqueue_input(channel_id, seq, session, attrs)
          end
        end
    end
  end

  defp do_enqueue_input(channel_id, seq, session, attrs) do
    session_id = session["session_id"]
    now = DateTime.utc_now()
    input_seq = session["input_next_seq"]

    event = %{
      "event_id" => attrs[:event_id],
      "type" => "message.created",
      "occurred_at" => Projections.format_ts(attrs[:occurred_at] || now)
    }

    stored = %{"event" => event, "message" => attrs[:message]}

    # The Bot receives the input as a sequenced `session.input` frame —
    # NOT a `session.stop_requested`/delivery (old Worker parity).
    # Best-effort push AFTER the txn commits: a rollback must not fan out.
    frame =
      BotGateway.build_session_input(
        session_id,
        channel_id,
        input_seq,
        event,
        attrs[:message]
      )

    {:ok, _} =
      Repo.transaction(fn ->
        Repo.query!(
          """
          INSERT INTO chat_v2.stateful_session_inputs
            (session_id, seq, channel_id, event_id, message_id,
             message_projection_json, status, created_at)
          VALUES ($1, $2, $3, $4, $5, $6, 'pending', $7)
          """,
          [
            session_id,
            input_seq,
            channel_id,
            attrs[:event_id],
            message_id_of(attrs[:message]),
            stored,
            now
          ],
          type: true
        )

        Repo.query!(
          "UPDATE chat_v2.stateful_command_sessions SET input_next_seq = $2 WHERE session_id = $1",
          [session_id, input_seq + 1],
          type: true
        )
      end)

    BotConnection.push_nowait(session["bot_id"], frame)

    # No event id was allocated — the seq is unchanged.
    {:ok, seq, %{event_frames: []}}
  end

  defp pending_input_count(session_id) do
    Query.rows(
      Repo.query(
        "SELECT COUNT(*) AS n FROM chat_v2.stateful_session_inputs WHERE session_id = $1 AND status IN ('pending', 'sent')",
        [session_id],
        type: true
      )
    )
    |> List.first()
    |> Map.get("n", 0)
  end

  defp message_id_of(%{"message_id" => id}) when is_binary(id), do: id
  defp message_id_of(_), do: ""

  # Old Worker `matchesListenRules`.
  defp matches_listen_rules?(attrs, rules, session) do
    types = rules["message_types"] || []
    include_bot? = rules["include_bot_messages"] || false
    include_own? = rules["include_own_messages"] || false

    type = attrs[:type]

    sender_kind = attrs[:sender_kind]
    sender_user_id = attrs[:sender_user_id]

    type in types and
      (sender_kind != "bot" or include_bot?) and
      not (sender_kind == "user" and sender_user_id == session["started_by_user_id"] and
             not include_own?)
  end

  # ------------------------------------------------ interaction.submit (#19)

  @doc """
  Browser `interaction.submit` (contract §9.5, brief §5/§10): the pin /
  message locator entry for Bot interactions. `input`:
  `%{user_id, command_id, payload}`; payload = `message_id` XOR `pin_id` +
  `component_id` + `custom_id` + `value`.

  Gate order (old Worker `submitInteraction` + `submitPinInteraction`):
  locator / field parse → channel kind / dissolved → membership →
  pin / message resolution → component lookup → disabled → value → targeted
  → the `platform:stop_session` short-circuit (A5, pin locator only) or the
  bot interaction path (BOT_OFFLINE precheck, policy gates, interaction row
  + `interaction.created` + bot delivery). Idempotent on
  `(user, "interaction.submit", command_id)`; a cached replay returns the
  stored ack without touching the channel.

  Returns `{result, new_seq}`; `result.response` is the ack payload (the
  `PlatformPinInteractionAck` for the stop short-circuit,
  `%{channel_id, interaction_id, event_id}` for bot interactions);
  `result.event_frames` carries the committed frames for the writer
  broadcast.
  """
  def submit_interaction(channel_id, seq, input) do
    payload = input[:payload] || %{}
    user_id = input[:user_id]
    command_id = input[:command_id]

    pin_id = nonblank(payload["pin_id"])
    message_id = nonblank(payload["message_id"])
    component_id = nonblank(payload["component_id"])
    custom_id = nonblank(payload["custom_id"])

    if pin_id != nil == (message_id != nil) do
      raise Errors.new("INVALID_MESSAGE", "exactly one of message_id or pin_id is required")
    end

    unless is_binary(component_id) do
      raise Errors.new("INVALID_MESSAGE", "component_id is required")
    end

    unless is_binary(custom_id) do
      raise Errors.new("INVALID_MESSAGE", "custom_id is required")
    end

    unless Map.has_key?(payload, "value") do
      raise Errors.new("INVALID_MESSAGE", "value is required")
    end

    check_channel_meta(channel_id)

    # Membership gate (old Worker: `activeRole` before either branch).
    unless active_role(channel_id, user_id) do
      raise Errors.new("FORBIDDEN", "not a channel member")
    end

    request_hash =
      CanonicalJSON.encode_and_sha256(%{
        "channel_id" => channel_id,
        "message_id" => message_id,
        "pin_id" => pin_id,
        "component_id" => component_id,
        "custom_id" => custom_id,
        "value" => payload["value"]
      })

    if pin_id != nil do
      submit_pin_interaction(channel_id, seq, user_id, command_id, request_hash, %{
        pin_id: pin_id,
        component_id: component_id,
        custom_id: custom_id,
        value: payload["value"]
      })
    else
      submit_message_interaction(channel_id, seq, user_id, command_id, request_hash, %{
        message_id: message_id,
        component_id: component_id,
        custom_id: custom_id,
        value: payload["value"]
      })
    end
  end

  # Pin locator (brief §10): the A5 `platform:stop_session` short-circuit
  # and bot pin interactions.
  defp submit_pin_interaction(channel_id, seq, user_id, command_id, request_hash, attrs) do
    row = ChannelPins.get_row(attrs[:pin_id])

    if is_nil(row) or row["channel_id"] != channel_id do
      raise Errors.new("PIN_NOT_FOUND", "pin not found")
    end

    projection =
      case Projections.json_map(row["message_projection_json"]) do
        %{} = map -> map
        _ -> raise(Errors.new("PIN_NOT_FOUND", "pin projection invalid"))
      end

    component =
      lookup_component(projection["components"] || [], attrs[:component_id], attrs[:custom_id])

    check_component_submittable(component)
    check_component_value(component, attrs[:value])
    check_targeted_policy(component, user_id)

    if String.starts_with?(attrs[:custom_id], "platform:") do
      # The Stop button needs no online bot — the platform owns the pin
      # (old Worker `applyPlatformStopSessionInTxn` short-circuit). The
      # disabled gate lives in `request_stop` (both paths reject it).
      unless row["pin_owner_kind"] == "platform" do
        raise Errors.new("INVALID_MESSAGE", "platform interactions require platform-owned pin")
      end

      unless attrs[:custom_id] == BotGateway.platform_stop_session_custom_id() do
        raise Errors.new("INVALID_MESSAGE", "unsupported platform interaction")
      end

      case Idempotency.run_writer_operation(
             "user",
             user_id,
             "interaction.submit",
             command_id,
             request_hash,
             fn ->
               {result, new_seq} =
                 request_stop(channel_id, seq, %{
                   pin_id: attrs[:pin_id],
                   user_id: user_id,
                   admin: is_admin?(channel_id, user_id)
                 })

               Map.merge(result, %{response: result.reply, seq: new_seq})
             end
           ) do
        {:ok, %{kind: :cached, response: response}} ->
          # Cached replay: no event was allocated on this call.
          {%{kind: :stopped, reply: response}, seq}

        {:ok, payload} ->
          {Map.drop(payload, [:seq]), payload[:seq]}

        {:error, api_error} ->
          raise api_error
      end
    else
      unless row["pin_owner_kind"] == "bot" do
        raise Errors.new("INVALID_MESSAGE", "pin interaction requires bot-owned pin")
      end

      check_policy_gate("pin", row["pin_id"], attrs[:component_id], user_id, component)

      submit_bot_interaction(channel_id, seq, user_id, command_id, request_hash, %{
        bot_id: row["pin_owner_id"],
        locator_kind: "pin",
        locator_key: row["pin_id"],
        component_id: attrs[:component_id],
        custom_id: attrs[:custom_id],
        value: attrs[:value]
      })
    end
  end

  # Message locator: interactions on a bot message's own components.
  defp submit_message_interaction(channel_id, seq, user_id, command_id, request_hash, attrs) do
    row =
      Query.rows(
        Repo.query(
          """
          SELECT message_id, command_id, sender_kind, sender_bot_id, status,
                 components_json, text, type, format, reply_to,
                 reply_snapshot_json, invocation_json, stream_state,
                 created_at, updated_at
          FROM chat_v2.messages
          WHERE message_id = $1 AND channel_id = $2
          """,
          [attrs[:message_id], channel_id],
          type: true
        )
      )
      |> List.first()

    if is_nil(row) do
      raise Errors.new("MESSAGE_NOT_FOUND", "message not found")
    end

    unless row["sender_kind"] == "bot" and is_binary(row["sender_bot_id"]) do
      raise Errors.new("INVALID_MESSAGE", "message is not from a bot")
    end

    if row["status"] in ["deleted", "recalled"] do
      raise Errors.new("MESSAGE_NOT_FOUND", "message not found")
    end

    component =
      lookup_component(
        Projections.json_list(row["components_json"]),
        attrs[:component_id],
        attrs[:custom_id]
      )

    # Old Worker `resolveComponentForSubmit`: a disabled *exclusive*
    # component reports its used state instead of the plain disabled error.
    exclusive_used? =
      policy_of(component) == "exclusive" and
        count_active_interactions(attrs[:message_id], attrs[:component_id]) > 0

    check_component_submittable(component, exclusive_used?)
    check_component_value(component, attrs[:value])
    check_targeted_policy(component, user_id)
    check_policy_gate("message", row["message_id"], attrs[:component_id], user_id, component)

    submit_bot_interaction(channel_id, seq, user_id, command_id, request_hash, %{
      bot_id: row["sender_bot_id"],
      locator_kind: "message",
      locator_key: row["message_id"],
      component_id: attrs[:component_id],
      custom_id: attrs[:custom_id],
      value: attrs[:value],
      exclusive: policy_of(component) == "exclusive" and not exclusive_used?,
      message_row: row
    })
  end

  # Shared bot-interaction commit: BOT_OFFLINE precheck, then the idempotent
  # {interaction row + bot delivery + `interaction.created`} batch. Pin
  # interactions store the pin id in `interactions.message_id` AND
  # `interactions.pin_id` (old Worker double-write). An `exclusive`
  # message-locator submit additionally locks the component
  # (`components_json` disabled + `message.updated` event) in the SAME txn,
  # before the `interaction.created` event (old Worker
  # `emitExclusiveComponentLock`).
  defp submit_bot_interaction(channel_id, seq, user_id, command_id, request_hash, attrs) do
    unless BotConnection.online?(attrs[:bot_id]) do
      raise Errors.new("BOT_OFFLINE", "The bot is currently offline.")
    end

    now = DateTime.utc_now()
    now_ms = DateTime.to_unix(now, :millisecond)

    interaction_id = Ids.uuidv7(now_ms)

    # Event id order (old Worker): the exclusive-lock `message.updated`
    # first (nowMs+1), then `interaction.created` (nowMs+2).
    {lock_event_id, seq1} =
      if attrs[:exclusive] do
        Ids.monotonic_uuidv7(seq, now_ms + 1)
      else
        {nil, seq}
      end

    {event_id, new_seq} = Ids.monotonic_uuidv7(seq1, now_ms + 2)

    lock =
      if attrs[:exclusive] do
        build_exclusive_lock(
          channel_id,
          attrs[:message_row],
          attrs[:component_id],
          lock_event_id,
          now
        )
      end

    case Idempotency.run_writer_operation(
           "user",
           user_id,
           "interaction.submit",
           command_id,
           request_hash,
           fn ->
             if lock do
               Repo.query!(
                 """
                 UPDATE chat_v2.messages
                 SET components_json = $3, updated_at = $4
                 WHERE message_id = $1 AND channel_id = $2
                 """,
                 [attrs[:locator_key], channel_id, lock.components_json, now],
                 type: true
               )

               insert_event(
                 lock_event_id,
                 "message.updated",
                 channel_id,
                 lock.persisted_payload,
                 now,
                 actor_kind: "system",
                 actor_id: nil
               )
             end

             {:ok, _} =
               BotDelivery.commit_interaction(%{
                 channel_id: channel_id,
                 bot_id: attrs[:bot_id],
                 actor_user_id: user_id,
                 message_id: attrs[:locator_key],
                 component_id: attrs[:component_id],
                 custom_id: attrs[:custom_id],
                 value: attrs[:value],
                 command_id: command_id,
                 dedupe_principal_key: "user:#{user_id}",
                 interaction_id: interaction_id,
                 pin_id: if(attrs[:locator_kind] == "pin", do: attrs[:locator_key])
               })

             persisted = %{
               "interaction" => %{
                 "interaction_id" => interaction_id,
                 "status" => "pending",
                 "created_at" => Projections.format_ts(now)
               },
               "command_id" => command_id,
               "actor_user_id" => user_id,
               "component_id" => attrs[:component_id]
             }

             persisted =
               if attrs[:locator_kind] == "pin" do
                 Map.put(persisted, "pin_id", attrs[:locator_key])
               else
                 Map.put(persisted, "message_id", attrs[:locator_key])
               end

             insert_event(event_id, "interaction.created", channel_id, persisted, now,
               actor_kind: "user",
               actor_id: user_id
             )

             frames =
               if(lock, do: [lock.frame], else: []) ++
                 [
                   Projections.build_event_frame(
                     event_id,
                     "interaction.created",
                     channel_id,
                     now,
                     interaction_created_wire(persisted, user_id, attrs)
                   )
                 ]

             # Live payload = what the read path (`Projections.resolve_actor`)
             # re-projects on history/replay: stable refs + resolved actor.
             %{
               kind: :interaction_submitted,
               response: %{
                 "channel_id" => channel_id,
                 "interaction_id" => interaction_id,
                 "event_id" => event_id
               },
               event_frames: frames
             }
           end
         ) do
      {:ok, %{kind: :cached, response: response}} ->
        {%{kind: :interaction_submitted, response: response}, seq}

      {:ok, payload} ->
        {payload, new_seq}

      {:error, api_error} ->
        raise api_error
    end
  end

  # Live `interaction.created` wire payload (contract §9.6): resolved actor +
  # `component_label` from the target message's CURRENT components_json
  # (message locator only — pin-locator interactions have no message row),
  # matching what the read path re-projects on replay (§9.6.2).
  defp interaction_created_wire(persisted, user_id, attrs) do
    wire = Projections.resolve_actor(persisted, Profiles.resolve([user_id]))

    case attrs[:message_row] do
      %{"components_json" => components_json} ->
        component_id = attrs[:component_id]

        case components_json
             |> Projections.json_list()
             |> Enum.find(&(is_map(&1) and &1["component_id"] == component_id)) do
          %{"label" => label} when is_binary(label) and label != "" ->
            Map.put(wire, "component_label", label)

          _ ->
            wire
        end

      _ ->
        wire
    end
  end

  # The `exclusive` component lock (old Worker `emitExclusiveComponentLock`):
  # `components_json` with the component disabled + the persisted
  # `message.updated` payload + the live frame. The message projection
  # reflects the locked components.
  defp build_exclusive_lock(channel_id, message_row, component_id, lock_event_id, now) do
    components = Projections.json_list(message_row["components_json"])

    locked_components =
      Enum.map(components, fn component ->
        if is_map(component) and component["component_id"] == component_id do
          Map.put(component, "disabled", true)
        else
          component
        end
      end)

    updated_row = Map.put(message_row, "updated_at", now)

    live_message =
      Projections.project_message(updated_row, %{}, %{
        attachments: [],
        mentions: [],
        sticker: nil,
        components: locked_components,
        command_invocation: nil,
        reply_target_status: nil
      })

    persisted_payload = %{
      "message" => %{
        "message_id" => updated_row["message_id"],
        "command_id" => updated_row["command_id"],
        "channel_id" => updated_row["channel_id"],
        "sender_kind" => updated_row["sender_kind"],
        "sender_user_id" => updated_row["sender_user_id"],
        "sender_bot_id" => updated_row["sender_bot_id"],
        "status" => updated_row["status"],
        "created_at" => Projections.format_ts(updated_row["created_at"]),
        "updated_at" => Projections.format_ts(now),
        "edited_at" => nil,
        "deleted_at" => nil,
        "deleted_by" => nil,
        "recalled_at" => nil,
        "stream_state" => "none",
        "reply_to" => updated_row["reply_to"],
        "reply_snapshot_json" => updated_row["reply_snapshot_json"],
        "type" => updated_row["type"],
        "format" => updated_row["format"],
        "text" => updated_row["text"],
        "invocation_json" => updated_row["invocation_json"]
      }
    }

    frame =
      Projections.build_event_frame(lock_event_id, "message.updated", channel_id, now, %{
        "message" => live_message
      })

    %{components_json: locked_components, persisted_payload: persisted_payload, frame: frame}
  end

  # Old Worker `findMessageComponentIncludingDisabled`: disabled components
  # still resolve (the submit-side gates decide); only `component_id` +
  # `custom_id` are validated here.
  defp lookup_component(components, component_id, custom_id) do
    component =
      Enum.find(components, fn c -> is_map(c) and c["component_id"] == component_id end)

    case component do
      nil ->
        raise Errors.new("COMPONENT_NOT_FOUND", "component not found")

      found ->
        if found["custom_id"] != custom_id do
          raise Errors.new("INVALID_MESSAGE", "custom_id mismatch")
        end

        found
    end
  end

  # Old Worker `disabledComponentSubmitError`.
  defp check_component_submittable(component, exclusive_used? \\ false) do
    if component["disabled"] do
      if exclusive_used? do
        raise Errors.new("COMPONENT_ALREADY_USED", "This component has already been used.")
      else
        raise Errors.new("COMPONENT_DISABLED", "component is disabled")
      end
    end
  end

  # Old Worker `validateInteractionValue`.
  defp check_component_value(component, value) do
    case component["kind"] do
      "button" ->
        if value != true do
          raise Errors.new("INVALID_INTERACTION_VALUE", "button value must be true")
        end

      "checkbox" ->
        unless is_boolean(value) do
          raise Errors.new("INVALID_INTERACTION_VALUE", "checkbox value must be boolean")
        end

      "select" ->
        check_single_option(component, value)

      "radio" ->
        check_single_option(component, value)

      "checkbox_group" ->
        if not is_list(value) or not Enum.all?(value, &is_binary/1) do
          raise Errors.new("INVALID_INTERACTION_VALUE", "checkbox_group value must be string[]")
        end

        allowed = option_values(component["options"] || [])

        unless Enum.all?(value, &(&1 in allowed)) do
          raise Errors.new("INVALID_INTERACTION_VALUE", "value contains invalid option")
        end

        min_selected = component["min_selected"] || 0
        max_selected = component["max_selected"] || length(value)

        if length(value) < min_selected or length(value) > max_selected do
          raise Errors.new("INVALID_INTERACTION_VALUE", "selected count out of range")
        end

      "text_input" ->
        unless is_binary(value) do
          raise Errors.new("INVALID_INTERACTION_VALUE", "text_input value must be string")
        end

        min_length = component["min_length"] || 0
        max_length = component["max_length"] || String.length(value)

        if String.length(value) < min_length or String.length(value) > max_length do
          raise Errors.new("INVALID_INTERACTION_VALUE", "text length out of range")
        end

      _ ->
        raise Errors.new("INVALID_INTERACTION_VALUE", "unsupported component kind")
    end
  end

  defp option_values(options) do
    for opt <- options, is_map(opt), is_binary(opt["value"]) do
      opt["value"]
    end
  end

  defp check_single_option(component, value) do
    unless is_binary(value) do
      raise Errors.new("INVALID_INTERACTION_VALUE", "value must be a string option")
    end

    unless value in option_values(component["options"] || []) do
      raise Errors.new("INVALID_INTERACTION_VALUE", "value is not a valid option")
    end
  end

  # Old Worker `checkTargetedPolicy`.
  defp check_targeted_policy(component, user_id) do
    if policy_of(component) == "targeted" do
      target = component["target_user_id"]

      unless is_binary(target) and target != "" do
        raise Errors.new("INVALID_MESSAGE", "targeted component missing target_user_id")
      end

      if user_id != target do
        raise Errors.new("INTERACTION_FORBIDDEN_TARGET", "You cannot submit this interaction.")
      end
    end
  end

  defp policy_of(component) do
    case component["interaction_policy"] do
      "per_user_once" -> "per_user_once"
      "exclusive" -> "exclusive"
      "targeted" -> "targeted"
      _ -> "multi"
    end
  end

  # Old Worker `policyBlocksPerUserOnce` / `policyBlocksExclusive`.
  defp check_policy_gate(_locator_kind, locator_key, component_id, user_id, component) do
    case policy_of(component) do
      "per_user_once" ->
        if count_active_interactions(locator_key, component_id, user_id) > 0 do
          raise Errors.new(
                  "INTERACTION_ALREADY_SUBMITTED",
                  "You have already submitted this interaction."
                )
        end

      "exclusive" ->
        if count_active_interactions(locator_key, component_id) > 0 do
          raise Errors.new("COMPONENT_ALREADY_USED", "This component has already been used.")
        end

      _ ->
        :ok
    end
  end

  # `pending` / `completed` interactions block policy-gated resubmits
  # (old Worker `ACTIVE_INTERACTION_STATUSES`). Pin interactions are counted
  # under their pin id (stored in `interactions.message_id`).
  defp count_active_interactions(locator_key, component_id, actor_id \\ nil) do
    Query.rows(
      Repo.query(
        """
        SELECT COUNT(*) AS n
        FROM chat_v2.interactions
        WHERE message_id = $1 AND component_id = $2
          AND status IN ('pending', 'completed')
          AND ($3::text IS NULL OR actor_user_id = $3)
        """,
        [locator_key, component_id, actor_id],
        type: true
      )
    )
    |> List.first()
    |> Map.get("n", 0)
  end

  # --------------------------------------------------- session start (#20)

  @doc """
  Activate a `starting` session on the bot's `session.start_ack` (issue #20,
  old Worker `botSessionStarted`): `status='active'` + the
  `stateful_session.started` event + the platform `session_control` pin
  (`channel.pin.set`) in ONE txn. Returns `{result, new_seq}` with
  `result.event_frames` (started + pin.set, in event_id order) and
  `result.arm_expiry` (the TTL timer target for the writer).
  """
  def handle_start_ack(channel_id, seq, attrs) do
    session = get(attrs[:session_id])

    if is_nil(session) or session["channel_id"] != channel_id do
      raise Errors.new("STATEFUL_SESSION_NOT_FOUND", "session not found")
    end

    if session["status"] != "starting" do
      raise Errors.new("STATEFUL_SESSION_NOT_ACTIVE", "session is not in starting state")
    end

    now = DateTime.utc_now()
    now_ms = DateTime.to_unix(now, :millisecond)
    summary = Projections.json_map(session["summary_json"]) || %{}
    command_name = summary["command_name"] || session["bot_command_id"]
    started_by_display_name = summary["started_by_display_name"] || session["started_by_user_id"]

    {started_event_id, seq1} = Ids.monotonic_uuidv7(seq, now_ms)
    {pin_event_id, seq2} = Ids.monotonic_uuidv7(seq1, now_ms + 1)

    started_payload = %{
      "session_id" => session["session_id"],
      "bot_command_id" => session["bot_command_id"],
      "command_name" => command_name,
      "status" => "active",
      "started_by_user_id" => session["started_by_user_id"],
      "started_at" => Projections.format_ts(session["started_at"]),
      "expires_at" => Projections.format_ts(session["expires_at"])
    }

    {:ok, _} =
      Repo.transaction(fn ->
        Repo.query!(
          """
          UPDATE chat_v2.stateful_command_sessions
          SET status = 'active'
          WHERE session_id = $1
          """,
          [session["session_id"]],
          type: true
        )

        insert_event(
          started_event_id,
          "stateful_session.started",
          channel_id,
          started_payload,
          now
        )

        # The session_control pin is (re)created on activation (old Worker:
        # delete any existing control pin first, then upsert).
        case ChannelPins.get_session_control_pin(channel_id) do
          nil ->
            :ok

          existing ->
            Repo.query!("DELETE FROM chat_v2.channel_pins WHERE pin_id = $1", [
              existing["pin_id"]
            ])
        end

        pin_row =
          ChannelPins.upsert_session_control(
            channel_id,
            session["session_id"],
            command_name,
            started_by_display_name,
            expires_at: session["expires_at"],
            last_pin_event_id: pin_event_id
          )

        pin_wire = ChannelPins.project_wire(pin_row, %{})
        insert_event(pin_event_id, "channel.pin.set", channel_id, %{"pin" => pin_wire}, now)
      end)

    frames = [
      Projections.build_event_frame(
        started_event_id,
        "stateful_session.started",
        channel_id,
        now,
        started_payload
      ),
      Projections.build_event_frame(
        pin_event_id,
        "channel.pin.set",
        channel_id,
        now,
        %{"pin" => ChannelPins.project_wire(ChannelPins.get_session_control_pin(channel_id), %{})}
      )
    ]

    {
      %{
        kind: :session_started_ack,
        event_frames: frames,
        arm_expiry: %{session_id: session["session_id"], at: session["expires_at"]}
      },
      seq2
    }
  end

  # ------------------------------------------- interaction lifecycle (#20)

  @doc """
  Finalize a `message_interaction` delivery lifecycle (issue #20, old Worker
  `finalizeInteractionDelivery`): the interaction row status update + the
  `interaction.completed` / `interaction.failed` timeline event, on the
  channel writer (seq-owned). Idempotent: a terminal interaction replays
  with no new event.

  `attrs`: `:interaction_id`, `:bot_id`, `:success`, optional
  `:error_code` / `:error_message`. Returns `{result, new_seq}` with
  `result.event_frames` (empty for replays / unknown rows).
  """
  def finalize_interaction(channel_id, seq, attrs) do
    interaction_id = attrs[:interaction_id]

    row =
      Query.rows(
        Repo.query(
          """
          SELECT interaction_id, message_id, pin_id, component_id, command_id, status
          FROM chat_v2.interactions
          WHERE interaction_id = $1
          """,
          [interaction_id],
          type: true
        )
      )
      |> List.first()

    cond do
      is_nil(row) ->
        {%{kind: :interaction_finalized, event_frames: []}, seq}

      row["status"] in ["completed", "failed"] ->
        # Idempotent replay of a terminal interaction — no repeat event
        # (contract §9.6.1).
        {%{kind: :interaction_finalized, event_frames: []}, seq}

      true ->
        do_finalize_interaction(channel_id, seq, row, attrs)
    end
  end

  defp do_finalize_interaction(channel_id, seq, row, attrs) do
    now = DateTime.utc_now()
    now_ms = DateTime.to_unix(now, :millisecond)
    {event_id, new_seq} = Ids.monotonic_uuidv7(seq, now_ms)

    # The current message row (message-locator completions only) — loaded
    # for the content-bearing wire projection; the persisted payload stores
    # the lifecycle shape (contract §9.6.2, no UserSummary in storage).
    message_row =
      if attrs[:success] and not is_binary(row["pin_id"]) do
        Query.rows(
          Repo.query(
            """
            SELECT message_id, command_id, channel_id, sender_kind, sender_user_id,
                   sender_bot_id, type, format, status, text, reply_to,
                   reply_snapshot_json, components_json, invocation_json, stream_state,
                   created_at, updated_at, edited_at, deleted_at, deleted_by, recalled_at
            FROM chat_v2.messages
            WHERE message_id = $1 AND channel_id = $2
            """,
            [row["message_id"], channel_id],
            type: true
          )
        )
        |> List.first()
      end

    payload =
      Repo.transaction(fn ->
        if attrs[:success] do
          Repo.query!(
            """
            UPDATE chat_v2.interactions
            SET status = 'completed', completed_at = $2, updated_at = $2, error_code = NULL
            WHERE interaction_id = $1
            """,
            [row["interaction_id"], now],
            type: true
          )

          if is_binary(row["pin_id"]) do
            # Pin-locator completion (old Worker `insertPinInteractionCompletedEvent`):
            # `{command_id, channel_id, event_id, pin_id}` — no content-bearing message.
            payload = %{
              "command_id" => row["command_id"],
              "channel_id" => channel_id,
              "event_id" => event_id,
              "pin_id" => row["pin_id"]
            }

            insert_event(event_id, "interaction.completed", channel_id, payload, now,
              actor_kind: "bot",
              actor_id: attrs[:bot_id]
            )

            payload
          else
            # Message-locator completion: content-bearing — the CURRENT
            # message lifecycle payload (reflecting applied effects).
            message_payload = build_message_lifecycle_payload(message_row)

            payload = %{
              "command_id" => row["command_id"],
              "channel_id" => channel_id,
              "event_id" => event_id,
              "message" => message_payload
            }

            insert_event(event_id, "interaction.completed", channel_id, payload, now,
              actor_kind: "bot",
              actor_id: attrs[:bot_id]
            )

            payload
          end
        else
          Repo.query!(
            """
            UPDATE chat_v2.interactions
            SET status = 'failed', completed_at = $2, updated_at = $2, error_code = $3
            WHERE interaction_id = $1
            """,
            [
              row["interaction_id"],
              now,
              attrs[:error_code] || "BOT_EFFECT_INVALID"
            ],
            type: true
          )

          payload = %{
            "command_id" => row["command_id"],
            "error_code" => attrs[:error_code] || "BOT_EFFECT_INVALID",
            "error_message" => attrs[:error_message] || "interaction delivery failed",
            "retryable" => false
          }

          insert_event(event_id, "interaction.failed", channel_id, payload, now,
            actor_kind: "bot",
            actor_id: attrs[:bot_id]
          )

          payload
        end
      end)

    {:ok, stored_payload} = payload

    # Wire projection: message-locator completions carry the full Browser
    # message (components included); everything else matches the stored
    # payload (old Worker `insertInteractionCompletedEvent`).
    wire_payload =
      if attrs[:success] and not is_binary(row["pin_id"]) do
        Map.put(stored_payload, "message", project_message_full(message_row))
      else
        stored_payload
      end

    frame =
      Projections.build_event_frame(
        event_id,
        if(attrs[:success], do: "interaction.completed", else: "interaction.failed"),
        channel_id,
        now,
        wire_payload
      )

    {%{kind: :interaction_finalized, event_frames: [frame]}, new_seq}
  end

  defp project_message_full(nil), do: nil

  defp project_message_full(row) do
    bot_summary =
      if row["sender_bot_id"] do
        %{
          "bot_id" => row["sender_bot_id"],
          "display_name" => row["sender_bot_display_name"],
          "avatar_url" => row["sender_bot_avatar_url"]
        }
      end

    Projections.project_message(row, %{}, %{
      attachments: [],
      mentions: [],
      sticker: nil,
      components: Projections.json_list(row["components_json"]),
      command_invocation:
        case Projections.json_map(row["invocation_json"]) do
          map when is_map(map) and map != %{} -> map
          _ -> nil
        end,
      bot_summary: bot_summary
    })
  end

  # `message.*` persisted shape for content-bearing events (same builder the
  # read path re-projects from; §9.6.2 — no UserSummary in storage).
  defp build_message_lifecycle_payload(nil), do: nil

  defp build_message_lifecycle_payload(row) do
    %{
      "message_id" => row["message_id"],
      "command_id" => row["command_id"],
      "channel_id" => row["channel_id"],
      "sender_kind" => row["sender_kind"],
      "sender_user_id" => row["sender_user_id"],
      "sender_bot_id" => row["sender_bot_id"],
      "status" => row["status"],
      "created_at" => Projections.format_ts(row["created_at"]),
      "updated_at" => Projections.format_ts(row["updated_at"]),
      "edited_at" => Projections.format_ts(row["edited_at"]),
      "deleted_at" => Projections.format_ts(row["deleted_at"]),
      "deleted_by" => row["deleted_by"],
      "recalled_at" => Projections.format_ts(row["recalled_at"]),
      "stream_state" => row["stream_state"] || "none",
      "reply_to" => row["reply_to"],
      "reply_snapshot_json" => row["reply_snapshot_json"],
      "type" => row["type"],
      "format" => row["format"],
      "text" => row["text"],
      "invocation_json" => row["invocation_json"]
    }
  end

  # -------------------------------------------------- bot reconnect resume

  @doc """
  Re-push unacked session inputs for every resumable session of `bot_id`
  (old Worker `resumeStatefulSessions` + `statefulSessionInputs`):
  `pending` / `sent` rows with `seq > input_last_acked_seq`, ordered by
  session (start order) then `seq`. Returns `session.input` frames in
  resume order; the bot dedupes on `(session_id, seq)`.
  """
  def resume_input_frames(bot_id) do
    sessions =
      Query.rows(
        Repo.query(
          """
          SELECT session_id, channel_id, input_last_acked_seq
          FROM chat_v2.stateful_command_sessions
          WHERE bot_id = $1 AND status IN ('starting', 'active', 'suspended', 'closing')
          ORDER BY started_at ASC, session_id ASC
          """,
          [bot_id],
          type: true
        )
      )

    Enum.flat_map(sessions, fn session ->
      rows =
        Query.rows(
          Repo.query(
            """
            SELECT seq, event_id, message_projection_json, status, created_at
            FROM chat_v2.stateful_session_inputs
            WHERE session_id = $1 AND seq > $2 AND status IN ('pending', 'sent')
            ORDER BY seq ASC
            """,
            [session["session_id"], session["input_last_acked_seq"] || 0],
            type: true
          )
        )

      Enum.map(rows, fn row ->
        projection = Projections.json_map(row["message_projection_json"]) || %{}
        event = Projections.json_map(projection["event"]) || %{}
        message = projection["message"] || %{}

        BotGateway.build_session_input(
          session["session_id"],
          session["channel_id"],
          row["seq"],
          %{
            "event_id" => event["event_id"] || row["event_id"],
            "type" => event["type"] || "message.created",
            "occurred_at" => event["occurred_at"] || Projections.format_ts(row["created_at"])
          },
          message
        )
      end)
    end)
  end

  # ------------------------------------------------------------- idempotency

  defp idem_lookup(session_id, effect_seq) do
    Query.rows(
      Repo.query(
        """
        SELECT request_hash, response_json, finalize_completed_at
        FROM chat_v2.idempotency
        WHERE namespace = 'session_effect'
          AND session_id = $1 AND effect_seq = $2
          AND (expires_at IS NULL OR expires_at > now())
        """,
        [session_id, effect_seq],
        type: true
      )
    )
    |> List.first()
  end

  defp write_session_idem(session_id, effect_seq, hash, results, now) do
    expires = DateTime.add(now, 86_400, :second)

    # `finalize_completed_at` is set at write time, mirroring the old Worker
    # `botSessionEffects` insert: session effects are pin-only, so their
    # finalize (stream emits / listen enqueues) is empty in v2 and the ack
    # push itself is the durable delivery.
    Repo.query!(
      """
      INSERT INTO chat_v2.idempotency
        (id, namespace, session_id, effect_seq, request_hash, response_json,
         finalize_completed_at, created_at, updated_at, expires_at)
      VALUES ($1, 'session_effect', $2, $3, $4, $5, $6, $6, $6, $7)
      """,
      [
        Ecto.UUID.bingenerate(),
        session_id,
        effect_seq,
        hash,
        results,
        now,
        expires
      ],
      type: true
    )
  end

  # --------------------------------------------------------------- internals

  defp pin_row_by_session(channel_id, session_id) do
    Query.rows(
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
    )
    |> List.first()
  end

  defp insert_event(event_id, event_type, channel_id, payload, now, opts \\ []) do
    actor_kind = Keyword.get(opts, :actor_kind, "system")
    actor_id = Keyword.get(opts, :actor_id)

    mv =
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

    Repo.query!(
      """
      INSERT INTO chat_v2.events
        (event_id, event_type, channel_id, actor_kind, actor_id, payload,
         membership_version_at_event, occurred_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
      """,
      [event_id, event_type, channel_id, actor_kind, actor_id, payload, mv, now],
      type: true
    )
  end

  # Old Worker `String(raw.type)`: a missing (or non-string) type renders as
  # "undefined" in the allowlist rejection message.
  defp type_label(nil), do: "undefined"
  defp type_label(type), do: to_string(type)

  defp nonblank(value) when is_binary(value) and value != "", do: value
  defp nonblank(_), do: nil

  # Old Worker `channelMetaCommand` + kind/dissolved gates (shared shape with
  # the other writer modules).
  defp check_channel_meta(channel_id) do
    meta =
      Query.rows(
        Repo.query(
          "SELECT kind, status FROM chat_v2.channels WHERE channel_id = $1",
          [channel_id]
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

  defp is_admin?(channel_id, user_id) do
    active_role(channel_id, user_id) in ["owner", "admin"]
  end
end
