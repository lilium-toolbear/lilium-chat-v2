defmodule LiliumChat.MessageMutate do
  @moduledoc """
  `message.edit` / `message.recall` / `message.delete` write path
  (contract §6.3–§6.5, spec §5.1, issue #10).

  The shared mutation core (old Worker `applyMessageMutation`): given a
  channel id, the per-channel `event_id` sequence state, and the caller's
  command, it

    * gates the channel (exists / active member / not dissolved) and the
      message (exists / editable / deletable) in the old Worker's order;
    * runs the `command_id` idempotency pre-check, then — in ONE PG
      transaction — re-checks idempotency, mutates the `messages` row, writes
      the paired `message.updated` / `message.recalled` / `message.deleted`
      event, the `message_edits` / `audit_logs` history row, the pin-lifecycle
      event (`channel.pin.updated` / `channel.pin.cleared`, §6.3 / §6.4), the
      optional `system.notice` (§10.4) and the `user_command` idempotency row
      (spec D10);
    * builds the Browser-visible message projection with the **shared**
      `Projections.project_message` builder (ack == event == history shape;
      deleted/recalled project the safe tombstone, spec A9).

  The caller (the per-channel writer process, `LiliumChat.Channel`)
  broadcasts the returned `event_frames` (in event_id order) on
  `channel:<id>` after the txn commits.
  """

  alias LiliumChat.{
    CanonicalJSON,
    ChannelGates,
    ChannelPins,
    Errors,
    Idempotency,
    Ids,
    Profiles,
    Projections,
    Query,
    Repo
  }

  alias LiliumChat.WebSockets.Frames

  @doc """
  Apply one message mutation. `input` is
  `%{user_id: binary, command_id: binary, operation: "message.edit" |
  "message.recall" | "message.delete", payload: map}`.

  Returns `{result, new_seq}` (same tagged-result convention as
  `LiliumChat.MessageSend.send/3`; `created` results carry `event_frames`).
  """
  def mutate(channel_id, seq, input) do
    user_id = input.user_id
    command_id = input.command_id
    operation = input.operation
    payload = input.payload

    unless is_map(payload) do
      {%{kind: :error, error: Errors.new("INVALID_MESSAGE", "invalid payload")}, seq}
    else
      with {:ok, parsed} <- parse_payload(operation, payload),
           {:ok, meta} <- load_meta(channel_id),
           :ok <- membership_gate(channel_id, user_id) do
        request_hash = request_hash(operation, parsed)

        # Cheap pre-check (old Worker parity): only the cached path
        # short-circuits before the txn.
        case Idempotency.check("user", user_id, operation, command_id, request_hash) do
          {:cached, response} ->
            {%{kind: :cached, ack_frame: response}, seq}

          _ ->
            do_mutate(channel_id, seq, user_id, command_id, operation, parsed, meta, request_hash)
        end
      else
        {:error, %Errors.ApiError{} = api_error} ->
          {%{kind: :error, error: api_error}, seq}
      end
    end
  end

  # --------------------------------------------------------------------------
  # mutation path
  # --------------------------------------------------------------------------

  defp do_mutate(channel_id, seq, user_id, command_id, operation, parsed, meta, request_hash) do
    now = DateTime.utc_now()
    now_ms = DateTime.to_unix(now, :millisecond)
    mv = meta["membership_version"]
    message_id = parsed.message_id
    channel_kind = meta["kind"]

    # Bounded preflight read: resolves the actor + sender profiles for the
    # live projection (old Worker P0-2 preflight). The authoritative row is
    # re-read inside the txn.
    preflight_row = load_message(channel_id, message_id)
    profiles = resolve_profiles(user_id, preflight_row)

    result =
      Repo.transaction(fn ->
        # Dissolved gate first (old Worker order), then the in-txn
        # idempotency re-check, then the message row + role gates.
        #
        # #26: the gate re-reads `channels.status` FRESH inside the txn (old
        # Worker `channelMetaStatusVisibility` in-txn) rather than trusting the
        # pre-txn `meta` snapshot.
        case ChannelGates.dissolved(channel_id) do
          {:error, api_error} ->
            Repo.rollback(%{kind: :error, error: api_error})

          :ok ->
            case Idempotency.check("user", user_id, operation, command_id, request_hash) do
              {:conflict, api_error} ->
                Repo.rollback(%{kind: :error, error: api_error})

              {:cached, response} ->
                %{kind: :cached, ack_frame: response}

              :missing ->
                # Gate failures raise ApiError before the event_id is
                # allocated; rolling back here keeps the txn atomic.
                try do
                  do_mutate_inner(
                    channel_id,
                    seq,
                    user_id,
                    command_id,
                    operation,
                    parsed,
                    channel_kind,
                    mv,
                    profiles,
                    now,
                    now_ms,
                    request_hash
                  )
                rescue
                  api_error in [Errors.ApiError] ->
                    Repo.rollback(%{kind: :error, error: api_error})
                end
            end
        end
      end)

    case result do
      {:ok, %{kind: :created, ack_frame: ack, event_frames: frames, seq: new_seq}} ->
        {%{kind: :created, ack_frame: ack, event_frames: frames}, new_seq}

      {:ok, %{kind: :cached, ack_frame: response}} ->
        # Cached inside the txn (concurrent duplicate) — no new events, seq held.
        {%{kind: :cached, ack_frame: response}, seq}

      {:error, %{kind: :error, error: api_error}} ->
        {%{kind: :error, error: api_error}, seq}
    end
  end

  defp do_mutate_inner(
         channel_id,
         seq,
         user_id,
         command_id,
         operation,
         parsed,
         channel_kind,
         mv,
         profiles,
         now,
         now_ms,
         request_hash
       ) do
    message_id = parsed.message_id

    row =
      load_message(channel_id, message_id) ||
        raise(Errors.new("MESSAGE_NOT_FOUND", "message not found"))

    role = active_role(channel_id, user_id)
    is_sender = row["sender_kind"] == "user" and row["sender_user_id"] == user_id

    unless gate_pass?(operation, channel_kind, is_sender, role, row) do
      raise mutation_gate_error(operation, channel_kind, is_sender, role, row)
    end

    # ---------------------------------------------------------------- mutate
    updated_row =
      case operation do
        "message.edit" ->
          Map.merge(row, %{
            "text" => parsed.text,
            "status" => "edited",
            "edited_at" => now,
            "updated_at" => now
          })

        "message.recall" ->
          Map.merge(row, %{"status" => "recalled", "recalled_at" => now, "updated_at" => now})

        "message.delete" ->
          Map.merge(row, %{
            "status" => "deleted",
            "deleted_at" => now,
            "deleted_by" => user_id,
            "updated_at" => now
          })
      end

    update_message(updated_row)

    # ------------------------------------------------------- main lifecycle
    # event (old Worker: `nextEventId(nowMs)` inside the same txn)
    {event_id, seq1} = Ids.monotonic_uuidv7(seq, now_ms)
    event_type = lifecycle_event_type(operation)
    persisted_payload = build_persisted_payload(updated_row)
    insert_event(event_id, event_type, channel_id, user_id, persisted_payload, mv, now)

    # Live projection for the ack + event frame (shared builder; the
    # deleted/recalled row projects the safe tombstone, A9).
    live_message =
      Projections.project_message(updated_row, profiles, %{mentions: current_mentions(message_id)})

    # ------------------------------------------------- pin lifecycle sync
    # (old Worker syncPinnedMessageForSourceMessageMutation, same txn)
    pin_row = ChannelPins.pinned_message_row(channel_id, message_id)

    {pin_frames, seq2} =
      case pin_row do
        nil ->
          {[], seq1}

        %{"pin_id" => pin_id, "pin_kind" => pin_kind, "source_message_id" => source_id} ->
          if operation == "message.edit" do
            # source edit → the pin keeps its pin_id + projection_id, gets a
            # new projection, and its last_pin_event_id advances (§6.3).
            stored =
              ChannelPins.build_message_projection(
                updated_row,
                projection_id_of(pin_row),
                now,
                profiles
              )

            {pin_event_id, seq3} = Ids.monotonic_uuidv7(seq1, now_ms)
            ChannelPins.upsert_for_lifecycle(pin_row, stored, pin_event_id, now)

            pin_wire = ChannelPins.project_wire(ChannelPins.get_row(pin_id), profiles)
            wire_payload = %{"pin" => pin_wire}

            insert_pin_event(
              pin_event_id,
              "channel.pin.updated",
              channel_id,
              wire_payload,
              mv,
              now
            )

            {
              [pin_frame(pin_event_id, "channel.pin.updated", channel_id, now, wire_payload, mv)],
              seq3
            }
          else
            # source recall/delete → the pin row is deleted + cleared (§6.4/§6.5)
            Repo.query!("DELETE FROM chat_v2.channel_pins WHERE pin_id = $1", [pin_id])

            {pin_event_id, seq3} = Ids.monotonic_uuidv7(seq1, now_ms)

            wire_payload = %{
              "pin_id" => pin_id,
              "channel_id" => channel_id,
              "pin_kind" => pin_kind,
              "source_message_id" => source_id
            }

            insert_pin_event(
              pin_event_id,
              "channel.pin.cleared",
              channel_id,
              wire_payload,
              mv,
              now
            )

            {
              [pin_frame(pin_event_id, "channel.pin.cleared", channel_id, now, wire_payload, mv)],
              seq3
            }
          end
      end

    # --------------------------------------------------------- history rows
    case operation do
      "message.edit" ->
        insert_message_edit(
          event_id,
          message_id,
          row["text"],
          parsed.text,
          user_id,
          command_id,
          now
        )

      "message.recall" ->
        insert_audit(
          event_id,
          operation,
          message_id,
          row,
          updated_row,
          nil,
          user_id,
          command_id,
          now
        )

      "message.delete" ->
        insert_audit(
          event_id,
          operation,
          message_id,
          row,
          updated_row,
          parsed.reason,
          user_id,
          command_id,
          now
        )
    end

    # ------------------------------------------------- system.notice (§10.4)
    # An owner/admin deleting ANOTHER user's message appends a `message.deleted`
    # notice (contract; the old Worker emits none — noted conformance delta).
    # A bot message has no `target_user` (§6.5 targets 他人/user messages), so
    # only user-sent messages produce a notice.
    {notice_frames, seq_final} =
      if operation == "message.delete" and not is_sender and row["sender_kind"] == "user" do
        {notice_event_id, seq3} = Ids.monotonic_uuidv7(seq2, now_ms)
        sender_id = row["sender_user_id"]

        persisted = %{
          "notice_kind" => "message.deleted",
          "actor_user_id" => user_id,
          "target_user_id" => sender_id,
          "message_id" => message_id,
          "channel_changes" => nil
        }

        insert_notice_event(notice_event_id, channel_id, user_id, persisted, mv, now)

        wire_payload = %{
          "notice_kind" => "message.deleted",
          "actor" => Projections.user_summary(user_id, profiles),
          "target_user" => Projections.user_summary(sender_id, profiles),
          "message_id" => message_id,
          "channel_changes" => nil
        }

        {
          [
            Projections.build_event_frame(
              notice_event_id,
              "system.notice",
              channel_id,
              now,
              wire_payload
            )
            |> Map.put("membership_version_at_event", mv)
          ],
          seq3
        }
      else
        {[], seq2}
      end

    # ------------------------------------------------------------------ ack
    ack_frame =
      Frames.command_ack(
        operation,
        command_id,
        %{
          "channel_id" => channel_id,
          "event_id" => event_id,
          "message" => live_message
        }
      )

    Idempotency.write_completed("user", user_id, operation, command_id, request_hash, ack_frame)

    main_frame =
      Projections.build_event_frame(event_id, event_type, channel_id, now, %{
        "message" => live_message
      })
      |> Map.put("membership_version_at_event", mv)

    %{
      kind: :created,
      ack_frame: ack_frame,
      event_frames: [main_frame] ++ pin_frames ++ notice_frames,
      seq: seq_final
    }
  end

  defp pin_frame(event_id, event_type, channel_id, now, payload, mv) do
    Projections.build_event_frame(event_id, event_type, channel_id, now, payload)
    |> Map.put("membership_version_at_event", mv)
  end

  defp projection_id_of(pin_row) do
    projection =
      case pin_row["message_projection_json"] do
        map when is_map(map) -> map
        binary when is_binary(binary) -> Jason.decode(binary) |> ok_map()
        _ -> nil
      end

    (projection || %{})["projection_id"]
  end

  defp ok_map({:ok, map}) when is_map(map), do: map
  defp ok_map(_), do: nil

  # --------------------------------------------------------------------------
  # gates + validation
  # --------------------------------------------------------------------------

  defp lifecycle_event_type("message.edit"), do: "message.updated"
  defp lifecycle_event_type("message.recall"), do: "message.recalled"
  defp lifecycle_event_type("message.delete"), do: "message.deleted"

  defp parse_payload("message.edit", payload) do
    message_id = payload["message_id"]
    text = payload["text"]

    cond do
      not (is_binary(message_id) and message_id != "") ->
        {:error, Errors.new("INVALID_MESSAGE", "message_id is required")}

      not (is_binary(text) and String.trim(text) != "") ->
        {:error, Errors.new("INVALID_MESSAGE", "message text is empty")}

      true ->
        {:ok, %{message_id: message_id, text: text, reason: nil}}
    end
  end

  defp parse_payload(operation, payload) when operation in ["message.recall", "message.delete"] do
    message_id = payload["message_id"]

    cond do
      not (is_binary(message_id) and message_id != "") ->
        {:error, Errors.new("INVALID_MESSAGE", "message_id is required")}

      true ->
        reason =
          if operation == "message.delete" and is_binary(payload["reason"]),
            do: payload["reason"],
            else: nil

        {:ok, %{message_id: message_id, text: nil, reason: reason}}
    end
  end

  # Old Worker order: role/ownership gate first (DM then group), then the
  # status gate.
  defp gate_pass?("message.edit", _kind, is_sender, _role, row),
    do: is_sender and row["type"] == "text" and row["status"] in ["normal", "edited"]

  defp gate_pass?("message.recall", _kind, is_sender, _role, row),
    do: is_sender and row["status"] in ["normal", "edited"]

  defp gate_pass?("message.delete", kind, is_sender, role, row) do
    role_ok =
      if kind == "dm" do
        is_sender
      else
        is_sender or role in ["owner", "admin"]
      end

    role_ok and row["status"] in ["normal", "edited", "recalled"]
  end

  defp mutation_gate_error("message.edit", _kind, _is_sender, _role, _row),
    do: Errors.new("MESSAGE_NOT_EDITABLE", "message is not editable")

  defp mutation_gate_error("message.recall", _kind, _is_sender, _role, _row),
    do: Errors.new("MESSAGE_NOT_EDITABLE", "message is not recallable")

  defp mutation_gate_error("message.delete", kind, is_sender, role, row) do
    cond do
      kind == "dm" and not is_sender ->
        Errors.new("FORBIDDEN", "only sender may delete in DM")

      kind != "dm" and not is_sender and role not in ["owner", "admin"] ->
        Errors.new("FORBIDDEN", "only sender or owner/admin may delete")

      row["status"] not in ["normal", "edited", "recalled"] ->
        Errors.new("MESSAGE_NOT_EDITABLE", "message is not deletable")

      true ->
        Errors.new("MESSAGE_NOT_EDITABLE", "message is not deletable")
    end
  end

  defp load_meta(channel_id) do
    case Query.rows(
           Repo.query(
             "SELECT channel_id, kind, status, membership_version FROM chat_v2.channels WHERE channel_id = $1",
             [channel_id]
           )
         ) do
      [meta] -> {:ok, meta}
      [] -> {:error, Errors.new("CHANNEL_NOT_FOUND", "channel not found or not a member")}
    end
  end

  # #26 (issue #26 B3): the dissolved gate lives in `ChannelGates.dissolved/1`
  # (shared with MessageSend) — it re-reads `channels.status` INSIDE the
  # caller's transaction (old Worker parity), so a dissolve committed after the
  # pre-txn `meta` snapshot is still caught under READ COMMITTED.
  # Over the WS path the old Worker returns CHANNEL_NOT_FOUND for a non-member
  # (not FORBIDDEN) — "channel not found or not a member".
  defp membership_gate(channel_id, user_id) do
    row =
      Query.rows(
        Repo.query(
          "SELECT 1 AS x FROM chat_v2.channel_members " <>
            "WHERE channel_id = $1 AND user_id = $2 AND status = 'active'",
          [channel_id, user_id]
        )
      )

    if row == [] do
      {:error, Errors.new("CHANNEL_NOT_FOUND", "channel not found or not a member")}
    else
      :ok
    end
  end

  defp load_message(channel_id, message_id) do
    Query.rows(
      Repo.query(
        """
        SELECT message_id, command_id, channel_id, sender_kind, sender_user_id, sender_bot_id,
               type, format, status, stream_state, text, reply_to, reply_snapshot_json,
               created_at, updated_at, edited_at, deleted_at, deleted_by, recalled_at
        FROM chat_v2.messages
        WHERE channel_id = $1 AND message_id = $2
        """,
        [channel_id, message_id],
        type: true
      )
    )
    |> List.first()
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

  defp current_mentions(message_id) do
    Query.rows(
      Repo.query(
        """
        SELECT user_id, start_index, end_index
        FROM chat_v2.mentions
        WHERE message_id = $1
        ORDER BY start_index ASC
        """,
        [message_id]
      )
    )
    |> Enum.map(fn row ->
      %{"user_id" => row["user_id"], "start" => row["start_index"], "end" => row["end_index"]}
    end)
  end

  defp resolve_profiles(user_id, preflight_row) do
    sender_id =
      case preflight_row do
        nil -> nil
        %{"sender_kind" => "user", "sender_user_id" => sender_id} -> sender_id
        _ -> nil
      end

    Profiles.resolve(Enum.uniq([user_id, sender_id] |> Enum.reject(&is_nil/1)))
  end

  # --------------------------------------------------------------------------
  # request hash (old Worker: JSON.stringify over the fixed key order)
  # --------------------------------------------------------------------------

  defp request_hash("message.edit", parsed) do
    [
      {"message_id", parsed.message_id},
      {"text", parsed.text}
    ]
    |> CanonicalJSON.encode_and_sha256()
  end

  defp request_hash("message.recall", parsed) do
    [{"message_id", parsed.message_id}]
    |> CanonicalJSON.encode_and_sha256()
  end

  defp request_hash("message.delete", parsed) do
    [
      {"message_id", parsed.message_id},
      {"reason", parsed.reason}
    ]
    |> CanonicalJSON.encode_and_sha256()
  end

  # --------------------------------------------------------------------------
  # INSERT / UPDATEs (each runs inside the caller's Repo.transaction)
  # --------------------------------------------------------------------------

  defp update_message(row) do
    Repo.query!(
      """
      UPDATE chat_v2.messages SET
        text = $3,
        status = $4,
        edited_at = $5,
        deleted_at = $6,
        deleted_by = $7,
        recalled_at = $8,
        updated_at = $9
      WHERE channel_id = $1 AND message_id = $2
      """,
      [
        row["channel_id"],
        row["message_id"],
        row["text"],
        row["status"],
        row["edited_at"],
        row["deleted_at"],
        row["deleted_by"],
        row["recalled_at"],
        row["updated_at"]
      ],
      type: true
    )
  end

  defp insert_event(event_id, event_type, channel_id, user_id, payload, mv, now) do
    Repo.query!(
      """
      INSERT INTO chat_v2.events (
        event_id, event_type, channel_id, actor_kind, actor_id, payload,
        membership_version_at_event, occurred_at
      ) VALUES ($1, $2, $3, 'user', $4, $5, $6, $7)
      """,
      [event_id, event_type, channel_id, user_id, payload, mv, now],
      type: true
    )
  end

  defp insert_notice_event(event_id, channel_id, user_id, payload, mv, now) do
    Repo.query!(
      """
      INSERT INTO chat_v2.events (
        event_id, event_type, channel_id, actor_kind, actor_id, payload,
        membership_version_at_event, occurred_at
      ) VALUES ($1, 'system.notice', $2, 'user', $3, $4, $5, $6)
      """,
      [event_id, channel_id, user_id, payload, mv, now],
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

  # §3.11 / spec A2: the edit history row is written in the SAME txn as the
  # message edit (audit_id = event_id, stable across re-projection).
  defp insert_message_edit(event_id, message_id, old_text, new_text, editor, request_id, now) do
    Repo.query!(
      """
      INSERT INTO chat_v2.message_edits (
        edit_id, message_id, old_text, new_text, editor_user_id, request_id, edited_at
      ) VALUES ($1, $2, $3, $4, $5, $6, $7)
      """,
      ["#{event_id}:edit", message_id, old_text, new_text, editor, request_id, now],
      type: true
    )
  end

  defp insert_audit(
         event_id,
         operation,
         message_id,
         before_row,
         after_row,
         reason,
         actor,
         request_id,
         now
       ) do
    Repo.query!(
      """
      INSERT INTO chat_v2.audit_logs (
        audit_id, actor_kind, actor_id, action, target_type, target_id,
        before_json, after_json, reason, request_id, created_at
      ) VALUES ($1, 'user', $2, $3, 'message', $4, $5, $6, $7, $8, $9)
      """,
      [
        "#{event_id}:audit",
        actor,
        operation,
        message_id,
        before_row,
        after_row,
        reason,
        request_id,
        now
      ],
      type: true
    )
  end

  # --------------------------------------------------------------------------
  # projection helpers
  # --------------------------------------------------------------------------

  # The persisted lifecycle payload mirrors `buildMessageLifecyclePayload`
  # (old Worker): the raw message fields, `sender` as a stable ref.
  defp build_persisted_payload(row) do
    %{
      "message" => %{
        "message_id" => row["message_id"],
        "command_id" => row["command_id"],
        "channel_id" => row["channel_id"],
        "sender" => %{
          "kind" => row["sender_kind"],
          "user_id" => row["sender_user_id"],
          "bot_id" => row["sender_bot_id"]
        },
        "text" => row["text"],
        "type" => row["type"],
        "format" => row["format"],
        "status" => row["status"],
        "stream_state" => row["stream_state"],
        "reply_to" => row["reply_to"],
        "reply_snapshot" => row["reply_snapshot_json"],
        "attachments" => [],
        "components" => [],
        "mentions" => [],
        "created_at" => Projections.format_ts(row["created_at"]),
        "updated_at" => Projections.format_ts(row["updated_at"]),
        "edited_at" => Projections.format_ts(row["edited_at"]),
        "deleted_at" => Projections.format_ts(row["deleted_at"]),
        "deleted_by" => row["deleted_by"],
        "recalled_at" => Projections.format_ts(row["recalled_at"])
      }
    }
  end
end
