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

  alias LiliumChat.{CanonicalJSON, Errors, Idempotency, Ids, Profiles, Projections, Query, Repo}
  alias LiliumChat.WebSockets.Frames

  @op_pin "channel.pin_message"
  @op_unpin "channel.unpin_message"

  # Contract §3.10 suggested maximum for `pinned_message` pins (old Worker
  # MAX_CHANNEL_PINS).
  @max_pins 8

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
