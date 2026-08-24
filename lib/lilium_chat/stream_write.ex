defmodule LiliumChat.StreamWrite do
  @moduledoc """
  Canonical persist for stream finalize / abandon (contract §9.15.4–§9.15.5,
  issue #18).

  Runs inside the per-channel writer (`LiliumChat.Channel`) so the
  `message.stream_finalized` / `message.stream_abandoned` event_id stays
  on the channel's monotonic sequence. Live-only frames never enter this
  module.
  """

  alias LiliumChat.{
    BotStream,
    ChannelEvents,
    Errors,
    Ids,
    Projections,
    Query,
    Repo
  }

  @doc """
  Insert the final message + `message.stream_finalized` event.

  `input` is `%{bot_id, message_id, resolved_text, finalize_request_hash,
  final_seq, created_at, format, type, reply_to}`.
  """
  def finalize(channel_id, seq, input) do
    persist(channel_id, seq, input, :final)
  end

  @doc """
  Insert the abandoned/failed message + `message.stream_abandoned` event.

  `input` is `%{bot_id, message_id, resolved_text, created_at, format,
  type, reply_to}`.
  """
  def abandon(channel_id, seq, input) do
    persist(channel_id, seq, input, :abandoned)
  end

  defp persist(channel_id, seq, input, mode) do
    now = DateTime.utc_now()
    now_ms = DateTime.to_unix(now, :millisecond)
    mv = load_mv!(channel_id)

    {event_type, stream_state, status} =
      case mode do
        :final -> {"message.stream_finalized", "final", "normal"}
        :abandoned -> {"message.stream_abandoned", "abandoned", "failed"}
      end

    created_at = input.created_at || now
    {event_id, new_seq} = Ids.monotonic_uuidv7(seq, now_ms)

    invocation = invocation_json(mode, input, event_id)

    row = %{
      "message_id" => input.message_id,
      "command_id" => Ids.uuidv7(now_ms),
      "channel_id" => channel_id,
      "sender_kind" => "bot",
      "sender_user_id" => nil,
      "sender_bot_id" => input.bot_id,
      "type" => input.type || "text",
      "format" => input.format || "plain",
      "status" => status,
      "stream_state" => stream_state,
      "text" => input.resolved_text,
      "reply_to" => input.reply_to,
      "reply_snapshot_json" => nil,
      "created_at" => created_at,
      "updated_at" => now,
      "edited_at" => nil,
      "deleted_at" => nil,
      "deleted_by" => nil,
      "recalled_at" => nil,
      "event_id" => event_id,
      "invocation_json" => invocation
    }

    live_message = Projections.project_message(row, %{}, %{components: []})

    event_frame =
      Projections.build_event_frame(event_id, event_type, channel_id, now, %{
        "message" => live_message
      })
      |> Map.put("membership_version_at_event", mv)

    stored_payload = %{
      "actor_kind" => "bot",
      "actor_id" => input.bot_id,
      "message" => %{
        "message_id" => row["message_id"],
        "command_id" => row["command_id"],
        "channel_id" => channel_id,
        "sender" => %{"kind" => "bot", "bot_id" => input.bot_id},
        "text" => row["text"],
        "type" => row["type"],
        "format" => row["format"],
        "status" => row["status"],
        "stream_state" => row["stream_state"],
        "reply_to" => row["reply_to"],
        "components" => [],
        "attachments" => [],
        "mentions" => [],
        "created_at" => Projections.format_ts(created_at),
        "updated_at" => Projections.format_ts(now)
      }
    }

    response = %{"message_id" => input.message_id, "event_id" => event_id}

    kind =
      case mode do
        :final -> :finalized
        :abandoned -> :abandoned
      end

    result =
      Repo.transaction(fn ->
        insert_message(row, input.bot_id)
        ChannelEvents.insert_event(event_id, event_type, channel_id, stored_payload, mv, now)
        %{kind: kind, response: response, event_frames: [event_frame]}
      end)

    case result do
      {:ok, tagged} -> {tagged, new_seq}
      {:error, reason} -> raise reason
    end
  end

  defp invocation_json(:final, input, event_id) do
    %{
      "stream" => %{
        "finalize_request_hash" => input.finalize_request_hash,
        "final_seq" => input.final_seq,
        "event_id" => event_id
      }
    }
  end

  defp invocation_json(:abandoned, input, event_id) do
    %{
      "stream" => %{
        "abandoned_text_hash" => BotStream.text_hash(input.resolved_text),
        "event_id" => event_id
      }
    }
  end

  defp insert_message(row, bot_id) do
    Repo.query!(
      """
      INSERT INTO chat_v2.messages (
        message_id, command_id, dedupe_principal_key, channel_id,
        sender_kind, sender_bot_id, type, format, status, text, reply_to,
        stream_state, created_at, updated_at, event_id, invocation_json
      ) VALUES ($1, $2, $3, $4, 'bot', $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15)
      """,
      [
        row["message_id"],
        row["command_id"],
        "bot:#{bot_id}",
        row["channel_id"],
        bot_id,
        row["type"],
        row["format"],
        row["status"],
        row["text"],
        row["reply_to"],
        row["stream_state"],
        row["created_at"],
        row["updated_at"],
        row["event_id"],
        row["invocation_json"]
      ],
      type: true
    )
  end

  defp load_mv!(channel_id) do
    case Query.rows(
           Repo.query(
             "SELECT membership_version, status FROM chat_v2.channels WHERE channel_id = $1",
             [channel_id],
             type: true
           )
         ) do
      [%{"membership_version" => mv, "status" => "dissolved"}] ->
        _ = mv
        raise Errors.new("CHANNEL_DISSOLVED", "channel is dissolved")

      [%{"membership_version" => mv}] ->
        mv

      _ ->
        raise Errors.new("CHANNEL_NOT_FOUND", "channel not found")
    end
  end
end
