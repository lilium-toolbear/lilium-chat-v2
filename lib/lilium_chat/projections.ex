defmodule LiliumChat.Projections do
  @moduledoc """
  Pure Browser-visible projection helpers shared by the read path (issue #6).

  Mirrors the old Worker's `projectMessageForBrowser` (src/chat/message-projection.ts),
  `buildWireEventFrame` (src/contract/wire-frames.ts) and `sanitizeReplySnapshotForBrowser`
  (src/chat/reply-snapshot.ts). All functions are pure: they take a DB row map (string
  keys, as returned by `Repo.query(..., type: true)`) plus a resolved profile map and
  return the Browser wire shape.

  The safe-projection rules (contract §3.4 / §10.3, spec A9) live here:

  * a `deleted` / `recalled` message has `text`, `attachments`, `sticker`,
    `components`, `mentions`, `command_invocation` all cleared (no content leak);
  * a reply snapshot pointing at a deleted/recalled message gets `text_preview`
    cleared and `media_preview` nulled.
  """

  @api_version "lilium.chat.v1"

  # `message.*` lifecycle events (and the content-bearing `interaction.completed`)
  # carry `{ channel_id, event_id, message }` in the PAYLOAD as well as the
  # envelope (contract §6.2 / §10.4). Stored payloads stay `{ message }` — the
  # ids are injected on projection (live + replay share this builder).
  @message_payload_types ~w(
    message.created
    message.updated
    message.recalled
    message.deleted
    message.stream_finalized
    message.stream_abandoned
    interaction.completed
  )

  @doc """
  Build a Browser-visible EventEnvelope frame (contract §10.4).
  """
  def build_event_frame(event_id, type, channel_id, occurred_at, payload) do
    %{
      "frame_type" => "event",
      "api_version" => @api_version,
      "event_id" => event_id,
      "type" => type,
      "channel_id" => channel_id,
      "occurred_at" => format_ts(occurred_at),
      "payload" => message_payload(type, channel_id, event_id, payload)
    }
  end

  defp message_payload(type, channel_id, event_id, payload) do
    if type in @message_payload_types do
      payload
      |> Map.put("channel_id", channel_id)
      |> Map.put("event_id", event_id)
    else
      payload
    end
  end

  @doc """
  Project a `messages` row into the Browser-visible Message wire shape
  (contract §3.4). `extras` carries the per-message relation data that was
  batch-fetched by the caller:

    * `:attachments` — list of projected attachments (`MessageImageAttachment`);
    * `:sticker` — sticker snapshot map or nil;
    * `:components` — list of components (usually `[]` for archive data);
    * `:mentions` — list of `{user_id, start, end}` maps;
    * `:command_invocation` — parsed invocation map or nil;
    * `:reply_target_status` — the *current* status of the replied-to message
      (used to sanitize the reply snapshot), or nil.

  `profiles` is `%{user_id => %{display_name: ..., avatar_url: ...}}`.
  """
  def project_message(row, profiles, extras \\ %{}) do
    hidden? = row["status"] in ["deleted", "recalled"]

    %{
      "message_id" => row["message_id"],
      "command_id" => row["command_id"],
      "channel_id" => row["channel_id"],
      "sender" => project_sender(row, profiles, extras),
      "type" => row["type"],
      "format" => row["format"] || "plain",
      "status" => row["status"],
      "stream_state" => row["stream_state"] || "none",
      "text" => if(hidden?, do: nil, else: row["text"]),
      "reply_to" => row["reply_to"],
      "reply_snapshot" =>
        project_reply_snapshot(
          json_map(row["reply_snapshot_json"]),
          Map.get(extras, :reply_target_status)
        ),
      "attachments" => if(hidden?, do: [], else: Map.get(extras, :attachments) || []),
      "sticker" => if(hidden?, do: nil, else: Map.get(extras, :sticker)),
      "components" =>
        if(hidden? or (row["stream_state"] || "none") != "none",
          do: [],
          else: Map.get(extras, :components) || []
        ),
      "mentions" => if(hidden?, do: [], else: Map.get(extras, :mentions) || []),
      "command_invocation" => if(hidden?, do: nil, else: Map.get(extras, :command_invocation)),
      "created_at" => format_ts(row["created_at"]),
      "updated_at" => format_ts(row["updated_at"]),
      "edited_at" => format_ts(row["edited_at"]),
      "deleted_at" => format_ts(row["deleted_at"]),
      "recalled_at" => format_ts(row["recalled_at"])
    }
  end

  @doc """
  Project a message sender (user with resolved profile, or bot fallback).
  `extras[:bot_summary]` (`%{"display_name" => ..., "avatar_url" => ...}`)
  carries the bot summary for live effect payloads (issue #19); the
  read path resolves bot summaries from `bot_apps` (Timeline).
  """
  def project_sender(row, profiles, extras \\ %{}) do
    case row["sender_kind"] do
      "user" ->
        %{
          "kind" => "user",
          "user" => user_summary(row["sender_user_id"], profiles)
        }

      "bot" ->
        bot_id = row["sender_bot_id"]
        summary = Map.get(extras, :bot_summary)

        %{
          "kind" => "bot",
          "bot" => %{
            "bot_id" => bot_id,
            "display_name" => (summary && summary["display_name"]) || bot_id,
            "avatar_url" => summary && summary["avatar_url"]
          }
        }

      other ->
        %{"kind" => other}
    end
  end

  @doc """
  Resolve a UserSummary (contract §3.1) from the profile map, falling back to
  `user-<first 8 hex chars>` when the profile is missing (no bare user_id shown).
  """
  def user_summary(nil, _profiles), do: nil

  def user_summary(user_id, profiles) when is_binary(user_id) do
    case Map.get(profiles, user_id) do
      %{display_name: name, avatar_url: avatar} when is_binary(name) ->
        %{
          "user_id" => user_id,
          "display_name" => name,
          "avatar_url" => avatar
        }

      _ ->
        %{
          "user_id" => user_id,
          "display_name" => fallback_display_name(user_id),
          "avatar_url" => nil
        }
    end
  end

  @doc "Fallback display name matching the old Worker: `user-<first 8 lowercase hex>`, truncated."
  def fallback_display_name(user_id) do
    "user-" <> String.slice(String.downcase(to_string(user_id)), 0, 8)
  end

  @doc """
  Sanitize a stored reply snapshot for Browser output (contract §3.5 / §10.3).
  When the replied-to message is currently deleted/recalled, clear `text_preview`
  and `media_preview`; otherwise keep the stored snapshot, updating `status` if it
  moved.
  """
  def project_reply_snapshot(nil, _target_status), do: nil

  def project_reply_snapshot(snapshot, target_status) when is_map(snapshot) do
    cond do
      target_status in ["deleted", "recalled"] ->
        snapshot
        |> Map.put("status", target_status)
        |> Map.put("text_preview", "")
        |> Map.put("media_preview", nil)

      target_status && target_status != Map.get(snapshot, "status") ->
        Map.put(snapshot, "status", target_status)

      true ->
        snapshot
    end
  end

  @doc """
  Resolve the actor/target_user/user/inviter refs in a management or bot-lifecycle
  event payload to UserSummaries (old Worker `resolveActorWithMap`). The raw
  `actor_kind`/`actor_id`/`user_id`/`target_user_id`/`inviter_user_id` keys are
  stripped and replaced by the resolved `actor`/`user`/`target_user`/`inviter`.
  """
  def resolve_actor(payload, profiles) when is_map(payload) do
    actor =
      cond do
        payload["actor_kind"] == "user" and is_binary(payload["actor_id"]) ->
          user_summary(payload["actor_id"], profiles)

        is_binary(payload["actor_user_id"]) ->
          user_summary(payload["actor_user_id"], profiles)

        true ->
          nil
      end

    target_user = payload["target_user_id"] && user_summary(payload["target_user_id"], profiles)
    user = payload["user_id"] && user_summary(payload["user_id"], profiles)
    inviter = payload["inviter_user_id"] && user_summary(payload["inviter_user_id"], profiles)

    payload
    |> Map.delete("actor_kind")
    |> Map.delete("actor_id")
    |> Map.delete("actor_user_id")
    |> Map.delete("target_user_id")
    |> Map.delete("user_id")
    |> Map.delete("inviter_user_id")
    |> Map.put("actor", actor)
    |> put_present("target_user", target_user)
    |> put_present("user", user)
    |> put_present("inviter", inviter)
  end

  # Add a resolved ref key only when a value is present (mirrors the old
  # Worker, which omits `user`/`target_user`/`inviter` when the raw ref was absent).
  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  @doc "Parse a JSONB column value into a map (handles already-decoded maps, JSON strings, and nil)."
  def json_map(nil), do: nil

  def json_map(value) when is_map(value), do: value

  def json_map(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      _ -> nil
    end
  end

  def json_map(_other), do: nil

  @doc "Coerce a JSONB column into a list (decoded lists pass through; JSON-array strings are decoded; anything else → `[]`)."
  def json_list(nil), do: []

  def json_list(value) when is_list(value), do: value

  def json_list(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  def json_list(_other), do: []

  @doc "Format a timestamp column (DateTime / NaiveDateTime / ISO string / nil)."
  def format_ts(nil), do: nil
  def format_ts(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  # Naive `timestamp` columns (this schema stores UTC without a zone) decode as
  # %NaiveDateTime{}. The wall time IS UTC, so suffix `Z` — matching the
  # `%DateTime{}` clause and the old Worker's ISO-8601 wire format.
  def format_ts(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt) <> "Z"

  def format_ts(value), do: value

  @doc """
  Build a channel `last_message_preview` (`"DisplayName: text"`, contract §3.2).
  Returns nil when there is no message text.
  """
  def build_preview(nil, _sender_id, _profiles), do: nil

  def build_preview(text, sender_id, profiles) do
    name =
      case {sender_id, Map.get(profiles, sender_id)} do
        {_id, %{display_name: name}} when is_binary(name) ->
          name

        {id, _} when is_binary(id) ->
          fallback_display_name(id)

        _ ->
          nil
      end

    if name do
      "#{name}: #{text}"
    else
      text
    end
  end
end
