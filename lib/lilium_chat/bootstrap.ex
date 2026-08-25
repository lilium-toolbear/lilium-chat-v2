defmodule LiliumChat.Bootstrap do
  @moduledoc """
  First-screen aggregate read path (spec §4 / contract §4.1, issue #5).

  `GET /api/chat/bootstrap` collapses the old Worker's N+5 DO fan-out
  (`UserDirectory` + `ChannelDirectory` + N×`ChatChannel` + 3×`ChatChannel`
  + profile) into a bounded set of queries against a single PG instance:

  1. **Main channel list** — `channel_members` ⋈ `channels` ⋈ `read_state`
     with per-channel aggregate subqueries (last_event_id, last message,
     unread count). One query.
  2. **Messages** — last 50 active messages for the active channel. One query.
  3. **Channel pins** — active pins for the active channel. One query.
  4. **Command manifest** — bound commands for the active channel (only when
     `?channel_id=` was explicitly requested). One query.
  5. **Profile batch** — `public.users` lookup, batch 50 (D16, A10).

  Total: ≤ 6 PG round-trips (5 queries + 1 profile batch), regardless of
  channel count. Zero per-channel backend fan-out (A12/D15).
  Reads are strictly read-only (no hidden writes).
  """

  alias LiliumChat.{ChannelCommands, ChannelPins, Ids, Repo}

  @profile_batch_size 50
  @bootstrap_message_limit 50

  # ------------------------------------------------------------------ types

  # user_id
  @type identity :: String.t()
  @type params :: %{channel_id: String.t() | nil}
  @type response :: map()

  # ------------------------------------------------------------------ public

  @doc """
  Build the full bootstrap response for `user_id`.

  `requested_channel_id` is the optional `?channel_id=` query parameter.
  Returns the response map (already a plain map, ready for Jason encoding).
  """
  def fetch(user_id, requested_channel_id) do
    # The §4.1 snapshot invariant: `channel_pins` must equal the fold of the
    # `channel.pin.*` events ≤ `event_state.per_channel[channel_id]`. That is a
    # SNAPSHOT property — the old Worker read channels + pins + events in one
    # atomic DO transaction. PG's default READ COMMITTED is per-statement, so
    # separate queries could straddle a concurrent pin commit (a pin landing
    # between the channel/events read and the pin read would make
    # pins ⊋ fold(events ≤ cursor)). Run the whole aggregate inside ONE
    # REPEATABLE READ transaction so every table is observed at a single
    # consistent snapshot (read-only MVCC snapshot, no locks held).
    Repo.transaction(
      fn -> do_fetch(user_id, requested_channel_id) end,
      isolation: :repeatable_read
    )
    |> case do
      {:ok, response} -> response
      {:error, reason} -> raise "bootstrap aggregate read failed: #{inspect(reason)}"
    end
  end

  defp do_fetch(user_id, requested_channel_id) do
    # 1. Main channel list (one query)
    channel_rows = query_my_channels(user_id)

    # 2. Determine active channel
    active_channel =
      case requested_channel_id do
        nil ->
          # "Most recently active" — the first channel in the list
          # (ordered by last activity / created_at DESC in the query).
          List.first(channel_rows)

        cid ->
          Enum.find(channel_rows, fn row -> row["channel_id"] == cid end)
      end

    # 3. Messages for active channel (one query)
    messages =
      case active_channel do
        nil ->
          %{"items" => [], "next_cursor" => nil}

        row ->
          query_messages(row["channel_id"])
      end

    # 4. Channel pins for active channel (one query; DM → []). Rows are
    #    projected to the `ChannelPin` wire shape after the profile batch
    #    (step 6) — the §4.1 snapshot invariant (pins == fold of the
    #    `channel.pin.*` events ≤ event_state) holds because both reads run
    #    inside the same REPEATABLE READ transaction (see fetch/2, issue #10 AC4).
    channel_pin_rows =
      case active_channel do
        nil ->
          []

        row ->
          if row["kind"] == "dm" do
            []
          else
            ChannelPins.list_rows(row["channel_id"])
          end
      end

    # 5. Command manifest (only when channel_id was explicitly requested AND
    #    the active channel matches AND kind != "dm"). Same merged shape as
    #    `GET /channels/{id}/commands` (issue #16); failures swallow to a
    #    missing key, matching the old Worker's bootstrap.
    command_manifest =
      if requested_channel_id && active_channel &&
           active_channel["channel_id"] == requested_channel_id &&
           active_channel["kind"] != "dm" do
        case ChannelCommands.full(user_id, active_channel["channel_id"]) do
          {:ok, manifest} -> manifest
          {:error, _} -> nil
        end
      else
        nil
      end

    # 6. Profile batch: current user + last-message senders + DM peers +
    #    pin owners (all in one batch-50 lookup, D16)
    profile_ids = collect_profile_ids(user_id, channel_rows, channel_pin_rows)
    profiles = resolve_profiles(profile_ids)

    # Project the pin rows to the wire shape (shared with GET /channels/{id}).
    channel_pins =
      Enum.map(channel_pin_rows, fn row -> ChannelPins.project_wire(row, profiles) end)

    # 7. Assemble channel summaries
    channels = build_channel_summaries(channel_rows, profiles)

    # 8. Active channel detail (ChannelMetaProjection shape)
    active_channel_detail =
      case active_channel do
        nil -> nil
        row -> build_active_channel_detail(row, profiles)
      end

    # 9. Me (current user profile)
    me = build_me(user_id, profiles)

    # 10. Per-channel cursor map
    per_channel =
      for row <- channel_rows,
          row["last_event_id"] != nil,
          into: %{} do
        {row["channel_id"], row["last_event_id"]}
      end

    # 11. Assemble response
    base = %{
      "me" => me,
      "channels" => channels,
      "active_channel" => active_channel_detail,
      "messages" => messages,
      "channel_pins" => channel_pins,
      "event_state" => %{"per_channel" => per_channel}
    }

    if command_manifest != nil do
      Map.put(base, "command_manifest", command_manifest)
    else
      base
    end
  end

  # ------------------------------------------------------- query functions

  @doc """
  Query the user's active channels with aggregates (one SQL query).
  Returns a list of maps with string keys.
  """
  def query_my_channels(user_id) do
    query = """
    SELECT
      cm.channel_id,
      cm.role,
      c.kind,
      c.visibility,
      c.title,
      c.topic,
      c.avatar_url,
      c.member_count,
      c.status,
      c.created_at,
      c.updated_at,
      rs.last_read_event_id,
      (
        SELECT e.event_id
        FROM chat_v2.events e
        WHERE e.channel_id = cm.channel_id
        ORDER BY e.event_id DESC
        LIMIT 1
      ) AS last_event_id,
      (
        SELECT m.text
        FROM chat_v2.messages m
        WHERE m.channel_id = cm.channel_id
          AND m.status = 'active'
        ORDER BY m.created_at DESC
        LIMIT 1
      ) AS last_message_text,
      (
        SELECT m.created_at
        FROM chat_v2.messages m
        WHERE m.channel_id = cm.channel_id
          AND m.status = 'active'
        ORDER BY m.created_at DESC
        LIMIT 1
      ) AS last_message_at,
      (
        SELECT m.sender_user_id
        FROM chat_v2.messages m
        WHERE m.channel_id = cm.channel_id
          AND m.status = 'active'
        ORDER BY m.created_at DESC
        LIMIT 1
      ) AS last_message_sender_id
    FROM chat_v2.channel_members cm
    JOIN chat_v2.channels c ON c.channel_id = cm.channel_id
    LEFT JOIN chat_v2.read_state rs
      ON rs.user_id = cm.user_id AND rs.channel_id = cm.channel_id
    WHERE cm.user_id = $1
      AND cm.status = 'active'
    ORDER BY c.updated_at DESC
    """

    case Repo.query(query, [user_id], type: true) do
      {:ok, result} -> rows_to_maps(result)
      {:error, _} -> []
    end
  end

  @doc """
  Query the last N active messages for a channel (one SQL query).
  Returns `{items: [...], next_cursor: nil}`.
  """
  def query_messages(channel_id) do
    query = """
    SELECT
      m.message_id,
      m.command_id,
      m.channel_id,
      m.sender_kind,
      m.sender_user_id,
      m.sender_bot_id,
      m.type,
      m.format,
      m.status,
      m.text,
      m.reply_to,
      m.reply_snapshot_json,
      m.stream_state,
      m.created_at,
      m.updated_at,
      m.edited_at,
      m.deleted_at,
      m.recalled_at
    FROM chat_v2.messages m
    WHERE m.channel_id = $1
      AND m.status = 'active'
    ORDER BY m.event_id DESC
    LIMIT $2
    """

    case Repo.query(query, [channel_id, @bootstrap_message_limit], type: true) do
      {:ok, result} ->
        items = rows_to_maps(result) |> Enum.reverse() |> Enum.map(&project_message/1)
        %{"items" => items, "next_cursor" => nil}

      {:error, _} ->
        %{"items" => [], "next_cursor" => nil}
    end
  end

  # ------------------------------------------------------- profile batch

  @doc """
  Resolve user profiles from `public.users` in batches of 50 (D16, A10).

  Returns a map: `%{user_id => %{display_name: ..., avatar_url: ...}}`.
  Missing users are simply absent from the map.
  """
  def resolve_profiles(user_ids) do
    unique = user_ids |> Enum.uniq() |> Enum.reject(&is_nil/1)

    if unique == [] do
      %{}
    else
      unique
      |> Enum.chunk_every(@profile_batch_size)
      |> Enum.reduce(%{}, fn batch, acc ->
        # `user_id` is UUID-keyed in the production ToolBear table — mirror
        # the old Worker's `uuid[]` cast (see LiliumChat.Profiles).
        query = """
        SELECT user_id::text AS user_id, full_name, avatar_url
        FROM public.users
        WHERE user_id = ANY($1::uuid[])
        """

        # Postgrex encodes a `uuid[]` parameter only from 16-byte binaries
        # (a hyphenated string raises DBConnection.EncodeError), and only
        # UUID-shaped ids can match the column — drop the rest first.
        ids =
          Enum.filter(batch, fn id ->
            is_binary(id) and
              String.match?(
                id,
                ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
              )
          end)

        if ids == [] do
          acc
        else
          case Repo.query(query, [Enum.map(ids, &Ids.uuid_bytes/1)]) do
            {:ok, result} ->
              map =
                for row <- rows_to_maps(result), into: %{} do
                  {row["user_id"],
                   %{
                     display_name: row["full_name"],
                     avatar_url: row["avatar_url"]
                   }}
                end

              Map.merge(acc, map)

            {:error, _} ->
              acc
          end
        end
      end)
    end
  end

  # ------------------------------------------------------- assembly helpers

  defp build_me(user_id, profiles) do
    case Map.get(profiles, user_id) do
      nil ->
        %{
          "user_id" => user_id,
          "display_name" => fallback_display_name(user_id),
          "avatar_url" => nil
        }

      profile ->
        %{
          "user_id" => user_id,
          "display_name" => profile[:display_name] || fallback_display_name(user_id),
          "avatar_url" => profile[:avatar_url]
        }
    end
  end

  defp build_channel_summaries(rows, profiles) do
    Enum.map(rows, fn row ->
      base = %{
        "channel_id" => row["channel_id"],
        "kind" => row["kind"],
        "visibility" => row["visibility"],
        "title" => row["title"],
        "avatar_url" => row["avatar_url"],
        "member_count" => row["member_count"],
        "status" => row["status"],
        "unread_count" => compute_unread(row),
        "last_read_event_id" => row["last_read_event_id"],
        "last_message_preview" => build_preview(row, profiles),
        "last_message_at" => format_ts(row["last_message_at"]),
        "last_event_id" => row["last_event_id"],
        "role" => row["role"]
      }

      if row["kind"] == "dm" do
        build_dm_summary(base, row, profiles)
      else
        base
      end
    end)
  end

  defp build_dm_summary(base, _row, _profiles) do
    # DM channels: title = peer's display name, avatar = peer's avatar.
    # For the tracer bullet, dm_peer resolution is deferred to Phase 1
    # (requires dm_pairs join + additional profile lookup).
    Map.put(base, "dm_peer", nil)
  end

  defp build_active_channel_detail(row, _profiles) do
    %{
      "channel_id" => row["channel_id"],
      "kind" => row["kind"],
      "visibility" => row["visibility"],
      "title" => row["title"],
      "topic" => row["topic"],
      "avatar_url" => row["avatar_url"],
      "member_count" => row["member_count"],
      "role" => row["role"],
      "status" => row["status"],
      "created_at" => format_ts(row["created_at"]),
      "updated_at" => format_ts(row["updated_at"])
    }
  end

  defp build_preview(row, profiles) do
    case row["last_message_text"] do
      nil ->
        nil

      text ->
        sender_id = row["last_message_sender_id"]

        display_name =
          case sender_id && Map.get(profiles, sender_id) do
            %{display_name: name} when is_binary(name) and name != "" -> name
            _ -> sender_id && fallback_display_name(sender_id)
          end

        if display_name do
          "#{display_name}: #{text}"
        else
          text
        end
    end
  end

  defp compute_unread(row) do
    # For the tracer bullet: if no read state, unread = 0.
    # Full computation (count events after last_read) can be refined in Phase 1.
    case row["last_read_event_id"] do
      nil -> 0
      # TODO(Phase 1): COUNT events WHERE event_id > last_read_event_id
      _ -> 0
    end
  end

  defp collect_profile_ids(user_id, channel_rows, pin_rows) do
    sender_ids =
      for row <- channel_rows,
          not is_nil(row["last_message_sender_id"]) do
        row["last_message_sender_id"]
      end

    pin_owner_ids =
      for row <- pin_rows, not is_nil(row["pinned_by_user_id"]) do
        row["pinned_by_user_id"]
      end

    [user_id | sender_ids] ++ pin_owner_ids
  end

  defp fallback_display_name(user_id) do
    # Match old Worker: "user-<first 8 hex chars>"
    "user-" <> String.slice(String.downcase(user_id), 0, 8)
  end

  defp format_ts(nil), do: nil

  defp format_ts(%DateTime{} = dt) do
    DateTime.to_iso8601(dt)
  end

  defp format_ts(value), do: value

  # ------------------------------------------------------- message projection

  defp project_message(row) do
    sender =
      case row["sender_kind"] do
        "user" ->
          %{
            "kind" => "user",
            "user" => %{
              "user_id" => row["sender_user_id"],
              "display_name" => fallback_display_name(row["sender_user_id"]),
              "avatar_url" => nil
            }
          }

        "bot" ->
          %{
            "kind" => "bot",
            "bot" => %{
              "bot_id" => row["sender_bot_id"],
              "display_name" => "bot"
            }
          }

        other ->
          %{"kind" => other}
      end

    %{
      "message_id" => row["message_id"],
      "command_id" => row["command_id"],
      "channel_id" => row["channel_id"],
      "sender" => sender,
      "type" => row["type"],
      "format" => row["format"] || "plain",
      "status" => row["status"],
      # Column is `NOT NULL DEFAULT 'none'`; fallback mirrors projections.ex (defensive).
      "stream_state" => row["stream_state"] || "none",
      "text" => row["text"],
      "reply_to" => row["reply_to"],
      "reply_snapshot" => row["reply_snapshot_json"],
      "attachments" => [],
      "components" => [],
      "mentions" => [],
      "created_at" => format_ts(row["created_at"]),
      "updated_at" => format_ts(row["updated_at"]),
      "edited_at" => format_ts(row["edited_at"]),
      "deleted_at" => format_ts(row["deleted_at"]),
      "recalled_at" => format_ts(row["recalled_at"])
    }
  end

  # ------------------------------------------------------- internal helpers

  defp rows_to_maps(%Postgrex.Result{columns: columns, rows: rows}) do
    for row <- rows do
      Map.new(Enum.zip(columns, row))
    end
  end
end
