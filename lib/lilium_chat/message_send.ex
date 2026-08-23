defmodule LiliumChat.MessageSend do
  @moduledoc """
  `message.send` write path (contract §6.2, spec §5.1 / §2.2, issue #9).

  The core, testable half of the tracer-bullet slice: given a channel id, the
  per-channel `event_id` sequence state (`seq`), and the caller's command, it

    * gates the channel (exists / not dissolved / active member);
    * parses + validates the payload (old `parseMessageSendCommand`);
    * runs the `command_id` idempotency pre-check, then — in ONE PG
      transaction — re-checks idempotency and writes `messages` (+ mentions /
      attachments / sticker snapshot) + `events` + the `user_command`
      `idempotency` row (spec: single in-txn idempotency write, D10);
    * builds the Browser-visible message projection with the **shared**
      `Projections.project_message` builder (so ack == event == history shape);
    * allocates the next per-channel monotonic UUIDv7 `event_id` from `seq`
      (spec §5.1, D13) and returns the advanced `seq` (the per-channel writer
      process owns + persists it implicitly via `events.event_id`).

  The caller (the per-channel writer process, `LiliumChat.Channel`) is
  responsible for broadcasting the returned event frame on `channel:<id>`.
  """

  alias LiliumChat.{CanonicalJSON, Errors, Idempotency, Ids, Profiles, Projections, Query, Repo}

  @operation "message.send"

  # --------------------------------------------------------------------------
  # entry point
  # --------------------------------------------------------------------------

  @doc """
  Send one message. `input` is `%{user_id: binary, command_id: binary, payload: map}`.

  Returns `{result, new_seq}` where `result` is a tagged map:

    * `%{kind: :created, ack_frame: map, event_frame: map}` — committed; the
      caller must broadcast `event_frame` (and `new_seq` is advanced);
    * `%{kind: :cached, ack_frame: map}` — idempotent replay of a committed
      `command_id` (identical body); no new event, `new_seq == seq`;
    * `%{kind: :error, error: %Errors.ApiError{}}` — validation / gate /
      idempotency conflict, `new_seq == seq`.
  """
  def send(channel_id, seq, input) do
    user_id = input.user_id
    command_id = input.command_id
    payload = input.payload || %{}

    # Gate + validation order mirrors the old Worker WS path (AC1 conformance):
    # payload validation (INVALID_MESSAGE) runs FIRST, then channel-exists and
    # membership (both CHANNEL_NOT_FOUND over WS). Resolution (reply /
    # attachments / sticker) and — inside the txn — the dissolved gate and the
    # idempotency re-check live in do_create.
    with {:ok, parsed} <- parse_and_validate(payload),
         {:ok, meta} <- load_meta(channel_id),
         :ok <- membership_gate(channel_id, user_id) do
      request_hash = request_hash(parsed)

      # v4.0 cheap pre-check (old Worker parity): ONLY the cached path
      # short-circuits here (no profile resolution / no txn). Conflict + missing
      # fall through to do_create, where the dissolved gate runs before the
      # in-txn idempotency re-check (so a fresh send to a dissolved channel is
      # rejected, while an already-committed duplicate still replays its ack).
      case Idempotency.check("user", user_id, @operation, command_id, request_hash) do
        {:cached, response} ->
          {%{kind: :cached, ack_frame: response}, seq}

        _ ->
          do_create(channel_id, seq, user_id, command_id, parsed, meta, request_hash)
      end
    else
      {:error, %Errors.ApiError{} = api_error} ->
        {%{kind: :error, error: api_error}, seq}
    end
  end

  # --------------------------------------------------------------------------
  # create path
  # --------------------------------------------------------------------------

  defp do_create(channel_id, seq, user_id, command_id, parsed, meta, request_hash) do
    now = DateTime.utc_now()
    now_ms = DateTime.to_unix(now, :millisecond)
    message_id = Ids.uuidv7(now_ms)
    mv = meta["membership_version"]

    {reply_snapshot, reply_sender_id} = reply_snapshot_for(channel_id, parsed)

    # Resolve sender + reply-target profiles BEFORE the txn (bounded read,
    # old Worker P0-2). A missing profile falls back to user-<shortid>.
    profiles =
      Profiles.resolve(Enum.uniq(([user_id] ++ [reply_sender_id]) |> Enum.reject(&is_nil/1)))

    {attachments, attachment_projections} = resolve_attachments(parsed, user_id)
    sticker = resolve_sticker(parsed, user_id)

    row = %{
      "message_id" => message_id,
      "command_id" => command_id,
      "channel_id" => channel_id,
      "sender_kind" => "user",
      "sender_user_id" => user_id,
      "sender_bot_id" => nil,
      "type" => parsed.type,
      "format" => "plain",
      "status" => "normal",
      "stream_state" => "none",
      "text" => parsed.text,
      "reply_to" => parsed.reply_to,
      "reply_snapshot_json" => reply_snapshot,
      "created_at" => now,
      "updated_at" => now,
      "edited_at" => nil,
      "deleted_at" => nil,
      "deleted_by" => nil,
      "recalled_at" => nil
    }

    extras = %{
      attachments: attachment_projections,
      mentions: parsed.mentions,
      sticker: sticker,
      components: [],
      command_invocation: nil,
      reply_target_status: reply_snapshot && reply_snapshot["status"]
    }

    # ONE shared projection builder feeds both the committed ack and the
    # broadcast event frame (old Worker addendum I: ack == event projection).
    live_message = Projections.project_message(row, profiles, extras)

    {event_id, new_seq} = Ids.monotonic_uuidv7(seq, now_ms)

    event_frame =
      Projections.build_event_frame(event_id, "message.created", channel_id, now, %{
        "message" => live_message
      })
      # The socket-side membership gate (issue #8) reads the mv from the
      # broadcast frame; carry it top-level (the #8 baseline convention).
      |> Map.put("membership_version_at_event", mv)

    ack_frame = %{
      "frame_type" => "command_ack",
      "command" => "message.send",
      "command_id" => command_id,
      "status" => "committed",
      "payload" => %{
        "channel_id" => channel_id,
        "event_id" => event_id,
        "message" => live_message
      }
    }

    persisted_payload = build_persisted_payload(row)

    # NOTE: the transaction fn returns the *bare* result map (or `Repo.rollback/1`
    # it); `Repo.transaction/1` wraps the value in `{:ok, value}` on commit.
    result =
      Repo.transaction(fn ->
        # Dissolved gate runs inside the txn, BEFORE the idempotency re-check
        # (old Worker parity): a fresh send to a dissolved channel →
        # CHANNEL_DISSOLVED, while an already-committed duplicate already
        # returned its cached ack in the pre-check above (never reaches here).
        case dissolved_gate(meta) do
          {:error, api_error} ->
            Repo.rollback(%{kind: :error, error: api_error})

          :ok ->
            case Idempotency.check("user", user_id, @operation, command_id, request_hash) do
              {:conflict, api_error} ->
                Repo.rollback(%{kind: :error, error: api_error})

              {:cached, response} ->
                %{kind: :cached, ack_frame: response}

              :missing ->
                insert_message(row, parsed, attachments, sticker)

                insert_event(event_id, channel_id, user_id, persisted_payload, mv, now)

                Idempotency.write_completed(
                  "user",
                  user_id,
                  @operation,
                  command_id,
                  request_hash,
                  ack_frame
                )

                %{kind: :created, ack_frame: ack_frame, event_frame: event_frame}
            end
        end
      end)

    case result do
      {:ok, %{kind: :created, ack_frame: ack_frame, event_frame: event_frame}} ->
        {%{kind: :created, ack_frame: ack_frame, event_frame: event_frame}, new_seq}

      {:ok, %{kind: :cached, ack_frame: response}} ->
        # Cached inside the txn (concurrent duplicate) — no new event, seq held.
        {%{kind: :cached, ack_frame: response}, seq}

      {:error, %{kind: :error, error: api_error}} ->
        {%{kind: :error, error: api_error}, seq}
    end
  end

  # --------------------------------------------------------------------------
  # gates + validation
  # --------------------------------------------------------------------------

  defp load_meta(channel_id) do
    case Query.rows(
           Repo.query(
             "SELECT channel_id, status, membership_version FROM chat_v2.channels WHERE channel_id = $1",
             [channel_id]
           )
         ) do
      [meta] -> {:ok, meta}
      # Old Worker WS path (ensureActiveMember) does not distinguish a missing
      # channel from a non-member — both surface the same CHANNEL_NOT_FOUND
      # message, so a missing channel and a non-member are wire-identical (AC1).
      [] -> {:error, Errors.new("CHANNEL_NOT_FOUND", "channel not found or not a member")}
    end
  end

  defp dissolved_gate(%{"status" => "dissolved"}),
    do: {:error, Errors.new("CHANNEL_DISSOLVED", "channel is dissolved")}

  defp dissolved_gate(_meta), do: :ok

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
      # Over the WS path the old Worker returns CHANNEL_NOT_FOUND (not FORBIDDEN)
      # for a non-member — "channel not found or not a member" (AC1 conformance).
      {:error, Errors.new("CHANNEL_NOT_FOUND", "channel not found or not a member")}
    else
      :ok
    end
  end

  # --------------------------------------------------------------------------
  # payload parse + validate (old `parseMessageSendCommand`)
  # --------------------------------------------------------------------------

  defp parse_and_validate(payload) when is_map(payload) do
    type = payload_value(payload, "type", "text")
    text = payload_value(payload, "text", "")
    reply_to = normalize_reply_to(payload["reply_to_message_id"])
    attachment_ids = normalize_attachment_ids(payload["attachment_ids"])
    sticker_id = normalize_sticker_id(payload["sticker_id"])
    mentions = parse_mentions(payload["mentions"])

    cond do
      type not in ["text", "image", "sticker"] ->
        {:error, Errors.new("INVALID_MESSAGE", "unsupported type: #{type}")}

      type == "text" and String.trim(text) == "" ->
        {:error, Errors.new("INVALID_MESSAGE", "message text is empty")}

      type == "sticker" and text != "" ->
        {:error, Errors.new("INVALID_MESSAGE", "sticker message text must be empty")}

      type == "image" and attachment_ids == [] ->
        {:error, Errors.new("INVALID_MESSAGE", "image message requires attachment_ids")}

      type == "sticker" and is_nil(sticker_id) ->
        {:error, Errors.new("INVALID_MESSAGE", "sticker message requires sticker_id")}

      type == "sticker" and attachment_ids != [] ->
        {:error, Errors.new("INVALID_MESSAGE", "attachment_ids not allowed for sticker messages")}

      type == "text" and attachment_ids != [] ->
        {:error, Errors.new("INVALID_MESSAGE", "attachment_ids not allowed for text messages")}

      type == "sticker" and mentions != [] ->
        {:error, Errors.new("INVALID_MESSAGE", "mentions not allowed for sticker messages")}

      true ->
        {:ok,
         %{
           type: type,
           text: text,
           reply_to: reply_to,
           attachment_ids: attachment_ids,
           sticker_id: sticker_id,
           mentions: mentions
         }}
    end
  end

  defp parse_and_validate(_),
    do: {:error, Errors.new("INVALID_MESSAGE", "payload must be an object")}

  defp payload_value(payload, key, default) do
    case Map.get(payload, key) do
      value when is_binary(value) -> value
      _ -> default
    end
  end

  defp normalize_reply_to(value), do: if(is_binary(value) and value != "", do: value, else: nil)

  # A missing/blank sticker_id is `nil` (matches the old Worker's `sticker_id || null`),
  # so the "sticker requires sticker_id" validation and the sticker query agree.
  defp normalize_sticker_id(value), do: if(is_binary(value) and value != "", do: value, else: nil)

  defp normalize_attachment_ids(value) do
    case value do
      list when is_list(list) -> Enum.filter(list, &is_binary/1)
      _ -> []
    end
  end

  defp parse_mentions(value) do
    case value do
      list when is_list(list) ->
        for item <- list,
            is_map(item),
            user_id = item["user_id"],
            is_binary(user_id),
            user_id != "" do
          %{
            "user_id" => user_id,
            "start" => mention_index(item["start"]),
            "end" => mention_index(item["end"])
          }
        end

      _ ->
        []
    end
  end

  defp mention_index(value) when is_integer(value), do: value
  defp mention_index(value) when is_float(value), do: trunc(value)
  defp mention_index(_), do: 0

  # --------------------------------------------------------------------------
  # request hash (old Worker: JSON.stringify over the fixed key order; the
  # Elixir idempotency namespace stores SHA-256 over the canonical bytes)
  # --------------------------------------------------------------------------

  defp request_hash(parsed) do
    [
      {"type", parsed.type},
      {"text", parsed.text},
      {"reply_to", parsed.reply_to},
      {"attachment_ids", parsed.attachment_ids},
      {"sticker_id", parsed.sticker_id},
      {"mentions", canonical_mentions(parsed.mentions)}
    ]
    |> CanonicalJSON.encode_and_sha256()
  end

  # CanonicalJSON represents objects as ordered `{key, value}` lists (not maps);
  # encode each mention in a fixed key order so the hash is deterministic.
  defp canonical_mentions(mentions) do
    Enum.map(mentions, fn mention ->
      [
        {"user_id", mention["user_id"]},
        {"start", mention["start"]},
        {"end", mention["end"]}
      ]
    end)
  end

  # --------------------------------------------------------------------------
  # reply snapshot
  # --------------------------------------------------------------------------

  # Returns `{snapshot_map_or_nil, reply_target_sender_id_or_nil}`. The id is
  # only resolved to a display name (for `sender_display_name`); it is not
  # re-resolved in the message projection (the snapshot is a stable ref).
  defp reply_snapshot_for(channel_id, parsed) do
    case parsed.reply_to do
      nil ->
        {nil, nil}

      reply_to ->
        target = load_message(reply_to, channel_id)

        unless target && target["status"] in ["normal", "edited"] do
          raise Errors.new("MESSAGE_NOT_FOUND", "reply target not found")
        end

        snapshot = %{
          "message_id" => target["message_id"],
          "sender_display_name" => reply_sender_display(target),
          "text_preview" => reply_text_preview(target),
          "status" => target["status"]
        }

        {snapshot, reply_target_sender_id(target)}
    end
  end

  defp reply_target_sender_id(target) do
    if target["sender_kind"] == "user" and is_binary(target["sender_user_id"]) do
      target["sender_user_id"]
    else
      nil
    end
  end

  defp load_message(message_id, channel_id) do
    Query.rows(
      Repo.query(
        "SELECT message_id, status, type, text, sender_kind, sender_user_id, sender_bot_id " <>
          "FROM chat_v2.messages WHERE message_id = $1 AND channel_id = $2",
        [message_id, channel_id]
      )
    )
    |> List.first()
  end

  defp reply_sender_display(target) do
    case target["sender_kind"] do
      "user" ->
        profiles = Profiles.resolve([target["sender_user_id"]])

        (profiles[target["sender_user_id"]] && profiles[target["sender_user_id"]][:display_name]) ||
          Projections.fallback_display_name(target["sender_user_id"])

      _ ->
        target["sender_bot_id"] || "系统"
    end
  end

  defp reply_text_preview(target) do
    cond do
      target["status"] in ["deleted", "recalled"] ->
        ""

      target["type"] == "image" ->
        "[图片]"

      target["type"] == "sticker" ->
        "[表情]"

      true ->
        text = to_string(target["text"] || "") |> String.trim()

        if text == "" do
          ""
        else
          if String.length(text) <= 120 do
            text
          else
            String.slice(text, 0, 120) <> "…"
          end
        end
    end
  end

  # --------------------------------------------------------------------------
  # attachment / sticker resolution
  # --------------------------------------------------------------------------

  defp resolve_attachments(%{type: "image", attachment_ids: ids}, user_id) when ids != [] do
    rows =
      Query.rows(
        Repo.query(
          "SELECT attachment_id, owner_user_id, kind, filename, mime_type, size_bytes, " <>
            "width, height, blurhash, storage_key, url, status " <>
            "FROM chat_v2.attachments WHERE attachment_id = ANY($1)",
          [ids]
        )
      )

    by_id = Enum.into(rows, %{}, &{&1["attachment_id"], &1})

    Enum.reduce(ids, {[], []}, fn id, {atts, projections} ->
      row =
        by_id[id] ||
          raise(Errors.new("UNSUPPORTED_ATTACHMENT_TYPE", "attachment not available"))

      unless row["status"] == "finalized" and row["owner_user_id"] == user_id do
        raise(Errors.new("UNSUPPORTED_ATTACHMENT_TYPE", "attachment not available"))
      end

      unless row["kind"] == "image" do
        raise(
          Errors.new(
            "UNSUPPORTED_ATTACHMENT_TYPE",
            "only message image attachments can be sent in chat"
          )
        )
      end

      {atts ++ [row], projections ++ [attachment_projection(row)]}
    end)
  end

  defp resolve_attachments(_parsed, _user_id), do: {[], []}

  defp attachment_projection(row) do
    # Contract MessageImageAttachment wants `width`/`height` as numbers; the old
    # Worker coerces a NULL dimension to 0 (attachment-projection.ts).
    %{
      "attachment_id" => row["attachment_id"],
      "url" => row["url"],
      "mime_type" => row["mime_type"],
      "size_bytes" => row["size_bytes"],
      "width" => row["width"] || 0,
      "height" => row["height"] || 0,
      "blurhash" => row["blurhash"]
    }
  end

  defp resolve_sticker(
         %{type: "sticker", sticker_id: sticker_id},
         user_id
       )
       when not is_nil(sticker_id) do
    row =
      Query.rows(
        Repo.query(
          "SELECT sticker_id, attachment_id, url, mime_type, width, height, size_bytes, blurhash " <>
            "FROM chat_v2.personal_stickers " <>
            "WHERE sticker_id = $1 AND user_id = $2 AND deleted_at IS NULL",
          [sticker_id, user_id]
        )
      )
      |> List.first()

    # Contract §6.2: a sticker removed from the sender's library before send →
    # STICKER_NOT_FOUND (404), matching the old Worker's resolveSticker.
    row || raise(Errors.new("STICKER_NOT_FOUND", "sticker not found"))

    %{
      "sticker_id" => row["sticker_id"],
      "attachment_id" => row["attachment_id"],
      "url" => row["url"],
      "mime_type" => row["mime_type"],
      "width" => row["width"],
      "height" => row["height"],
      "size_bytes" => row["size_bytes"],
      "blurhash" => row["blurhash"]
    }
  end

  defp resolve_sticker(_parsed, _user_id), do: nil

  # --------------------------------------------------------------------------
  # projection helpers
  # --------------------------------------------------------------------------

  defp build_persisted_payload(row) do
    %{
      "message" => %{
        "message_id" => row["message_id"],
        "command_id" => row["command_id"],
        "channel_id" => row["channel_id"],
        "sender" => %{"kind" => "user", "user_id" => row["sender_user_id"], "bot_id" => nil},
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
        "edited_at" => nil,
        "deleted_at" => nil,
        "deleted_by" => nil,
        "recalled_at" => nil
      }
    }
  end

  # --------------------------------------------------------------------------
  # INSERTs (each runs inside the caller's Repo.transaction)
  # --------------------------------------------------------------------------

  defp insert_message(row, parsed, attachments, sticker) do
    message_id = row["message_id"]
    user_id = row["sender_user_id"]

    Repo.query!(
      "INSERT INTO chat_v2.messages (" <>
        "message_id, command_id, dedupe_principal_key, channel_id, sender_kind, sender_user_id," <>
        " sender_bot_id, type, format, status, text, reply_to, reply_snapshot_json," <>
        " stream_state, created_at, updated_at" <>
        ") VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $15)",
      [
        row["message_id"],
        row["command_id"],
        "user:" <> user_id,
        row["channel_id"],
        row["sender_kind"],
        user_id,
        row["sender_bot_id"],
        row["type"],
        row["format"],
        row["status"],
        row["text"],
        row["reply_to"],
        row["reply_snapshot_json"],
        row["stream_state"],
        # created_at and updated_at are the same value (`now`); $15 fills both.
        row["created_at"]
      ]
    )

    for mention <- parsed.mentions do
      Repo.query!(
        "INSERT INTO chat_v2.mentions (message_id, user_id, start_index, end_index) " <>
          "VALUES ($1, $2, $3, $4)",
        [message_id, mention["user_id"], mention["start"], mention["end"]]
      )
    end

    # Attachments already exist in `attachments` (uploaded separately); only the
    # message ↔ attachment link is new here.
    for attachment <- attachments do
      Repo.query!(
        "INSERT INTO chat_v2.message_attachments (message_id, attachment_id) " <>
          "VALUES ($1, $2) ON CONFLICT DO NOTHING",
        [message_id, attachment["attachment_id"]]
      )
    end

    if not is_nil(sticker) do
      Repo.query!(
        "INSERT INTO chat_v2.message_stickers (" <>
          "message_id, sticker_id, attachment_id, url, mime_type, width, height, size_bytes, blurhash" <>
          ") VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)",
        [
          message_id,
          sticker["sticker_id"],
          sticker["attachment_id"],
          sticker["url"],
          sticker["mime_type"],
          sticker["width"],
          sticker["height"],
          sticker["size_bytes"],
          sticker["blurhash"]
        ]
      )
    end
  end

  defp insert_event(event_id, channel_id, user_id, payload, mv, now) do
    Repo.query!(
      "INSERT INTO chat_v2.events (" <>
        "event_id, event_type, channel_id, actor_kind, actor_id, payload," <>
        " membership_version_at_event, occurred_at" <>
        ") VALUES ($1, 'message.created', $2, 'user', $3, $4, $5, $6)",
      [event_id, channel_id, user_id, payload, mv, now]
    )
  end
end
