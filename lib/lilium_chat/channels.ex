defmodule LiliumChat.Channels do
  @moduledoc """
  Channel read path (contract §5, issue #6).

  `GET /api/chat/channels` (list) and `GET /api/chat/channels/{id}` (detail)
  are pure reads against `chat_v2` + `public.users` (spec §4 / A12). Both
  project to the full `ChannelSummaryApi` wire shape (contract §3.2 + the old
  Worker `inflateChannelSummaryForViewer` superset: `topic`, `created_at`,
  `updated_at`, `dm_peer`).

  The list is a single join query (`channel_members` ⋈ `channels` ⋈ `read_state`
  with per-channel aggregate subqueries) + one profile batch — bounded, zero
  per-channel backend fan-out (A12).

  Errors (contract §11):

  * list — none (empty `items` for a user with no channels);
  * detail — `CHANNEL_NOT_FOUND` (404) when the channel row is missing,
    `FORBIDDEN` (403) when a private channel is viewed by a non-member.
  """

  alias LiliumChat.{ChannelPins, Errors, Profiles, Projections, Query, Repo}

  # ------------------------------------------------------------------ public

  @doc """
  List the user's active channels as full `ChannelSummaryApi` rows
  (`GET /api/chat/channels`, contract §5.1). Read-only.
  """
  def list_for_user(user_id) do
    rows = query_my_channels(user_id)
    profiles = Profiles.resolve(collect_profile_ids(user_id, rows))
    Enum.map(rows, fn row -> project_channel_summary(row, profiles) end)
  end

  @doc "The viewer's active channel ids (drives the global `GET /events` cursor map, §10.3)."
  def my_channel_ids(user_id) do
    Repo.query(
      "SELECT channel_id FROM chat_v2.channel_members WHERE user_id = $1 AND status = 'active' ORDER BY channel_id",
      [user_id],
      type: true
    )
    |> Query.rows()
    |> Enum.map(& &1["channel_id"])
  end

  @doc """
  Read the channel detail bundle (`GET /api/chat/channels/{id}`, contract §5.2).
  Returns `%{channel: ChannelSummaryApi, channel_pins: [ChannelPin]}`.

  Raises `Errors.ApiError` for `CHANNEL_NOT_FOUND` / `FORBIDDEN`.
  """
  def detail(user_id, channel_id) do
    meta =
      Repo.query(
        """
        SELECT channel_id, kind, visibility, title, topic, avatar_url, status,
               created_at, updated_at, member_count
        FROM chat_v2.channels
        WHERE channel_id = $1
        """,
        [channel_id],
        type: true
      )
      |> Query.rows()
      |> List.first()

    meta = meta || raise(Errors.new("CHANNEL_NOT_FOUND"))

    role = member_role(user_id, channel_id)

    if meta["visibility"] == "private" and role == nil do
      # Contract §2.6 error-envelope example wording for FORBIDDEN.
      raise Errors.new("FORBIDDEN", "not a channel member")
    end

    last_event_id = last_event_id(channel_id)

    {last_message_at, last_message_text, last_message_sender_id} =
      last_visible_message(channel_id)

    dm_peer = if meta["kind"] == "dm", do: dm_peer(user_id, channel_id), else: nil

    # DM channels always project an empty pin set (contract §3.10); group pins
    # are only visible to members, so a non-member also sees none.
    pins_raw =
      if meta["kind"] == "dm" or role == nil do
        []
      else
        ChannelPins.list_rows(channel_id)
      end

    pin_owner_ids = pins_raw |> Enum.map(& &1["pinned_by_user_id"]) |> Enum.reject(&is_nil/1)

    profiles =
      Profiles.resolve(Enum.uniq([user_id, last_message_sender_id, dm_peer] ++ pin_owner_ids))

    summary =
      %{
        "channel_id" => meta["channel_id"],
        "kind" => meta["kind"],
        "visibility" => meta["visibility"],
        "title" => meta["title"],
        "topic" => meta["topic"],
        "avatar_url" => meta["avatar_url"],
        "member_count" => meta["member_count"],
        "status" => meta["status"],
        "created_at" => Projections.format_ts(meta["created_at"]),
        "updated_at" => Projections.format_ts(meta["updated_at"]),
        "unread_count" => 0,
        "last_read_event_id" => nil,
        "last_message_preview" =>
          Projections.build_preview(last_message_text, last_message_sender_id, profiles),
        "last_message_at" => Projections.format_ts(last_message_at),
        "last_event_id" => last_event_id,
        "role" => role
      }
      |> with_dm_peer(dm_peer, profiles)

    %{
      channel: summary,
      channel_pins: Enum.map(pins_raw, &ChannelPins.project_wire(&1, profiles))
    }
  end

  # ---------------------------------------------------------------- queries

  defp query_my_channels(user_id) do
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
          AND m.status NOT IN ('deleted', 'recalled')
        ORDER BY m.created_at DESC, m.message_id DESC
        LIMIT 1
      ) AS last_message_text,
      (
        SELECT m.created_at
        FROM chat_v2.messages m
        WHERE m.channel_id = cm.channel_id
          AND m.status NOT IN ('deleted', 'recalled')
        ORDER BY m.created_at DESC, m.message_id DESC
        LIMIT 1
      ) AS last_message_at,
      (
        SELECT m.sender_user_id
        FROM chat_v2.messages m
        WHERE m.channel_id = cm.channel_id
          AND m.status NOT IN ('deleted', 'recalled')
        ORDER BY m.created_at DESC, m.message_id DESC
        LIMIT 1
      ) AS last_message_sender_id,
      CASE
        WHEN rs.last_read_event_id IS NULL THEN 0
        ELSE (
          SELECT COUNT(*)
          FROM chat_v2.events e2
          WHERE e2.channel_id = cm.channel_id
            AND e2.event_type = 'message.created'
            AND e2.event_id > rs.last_read_event_id
        )
      END AS unread_count,
      (
        SELECT cm2.user_id
        FROM chat_v2.channel_members cm2
        WHERE cm2.channel_id = cm.channel_id
          AND cm2.user_id <> cm.user_id
          AND cm2.status = 'active'
        LIMIT 1
      ) AS dm_peer_user_id
    FROM chat_v2.channel_members cm
    JOIN chat_v2.channels c ON c.channel_id = cm.channel_id
    LEFT JOIN chat_v2.read_state rs
      ON rs.user_id = cm.user_id AND rs.channel_id = cm.channel_id
    WHERE cm.user_id = $1
      AND cm.status = 'active'
    ORDER BY c.updated_at DESC, c.channel_id DESC
    """

    Repo.query(query, [user_id], type: true) |> Query.rows()
  end

  defp project_channel_summary(row, profiles) do
    base = %{
      "channel_id" => row["channel_id"],
      "kind" => row["kind"],
      "visibility" => row["visibility"],
      "title" => row["title"],
      "topic" => row["topic"],
      "avatar_url" => row["avatar_url"],
      "member_count" => row["member_count"],
      "status" => row["status"],
      "created_at" => Projections.format_ts(row["created_at"]),
      "updated_at" => Projections.format_ts(row["updated_at"]),
      "unread_count" => row["unread_count"] || 0,
      "last_read_event_id" => row["last_read_event_id"],
      "last_message_preview" =>
        Projections.build_preview(
          row["last_message_text"],
          row["last_message_sender_id"],
          profiles
        ),
      "last_message_at" => Projections.format_ts(row["last_message_at"]),
      "last_event_id" => row["last_event_id"],
      "role" => row["role"]
    }

    if row["kind"] == "dm" do
      with_dm_peer(base, row["dm_peer_user_id"], profiles)
    else
      base
    end
  end

  # DM channels: summary title/avatar resolve to the peer (contract §3.2).
  # Non-DM channels omit the `dm_peer` key entirely (contract §5.2 ChannelDetail
  # example has no dm_peer field — the key exists only for kind="dm").
  defp with_dm_peer(summary, dm_peer, profiles) do
    case dm_peer do
      nil ->
        summary

      peer_id ->
        profile = Map.get(profiles, peer_id)

        display_name =
          (profile && profile[:display_name]) || Projections.fallback_display_name(peer_id)

        avatar = profile && profile[:avatar_url]

        summary
        |> Map.put("dm_peer", %{
          "user_id" => peer_id,
          "display_name" => display_name,
          "avatar_url" => avatar
        })
        |> Map.put("title", display_name)
        |> Map.put("avatar_url", avatar)
    end
  end

  defp dm_peer(viewer_id, channel_id) do
    Repo.query(
      "SELECT user_id FROM chat_v2.channel_members WHERE channel_id = $1 AND user_id <> $2 AND status = 'active' LIMIT 1",
      [channel_id, viewer_id],
      type: true
    )
    |> Query.rows()
    |> List.first()
    |> case do
      %{"user_id" => id} -> id
      _ -> nil
    end
  end

  defp member_role(user_id, channel_id) do
    Repo.query(
      "SELECT role FROM chat_v2.channel_members WHERE channel_id = $1 AND user_id = $2 AND status = 'active'",
      [channel_id, user_id],
      type: true
    )
    |> Query.rows()
    |> List.first()
    |> case do
      %{"role" => role} -> role
      _ -> nil
    end
  end

  defp last_event_id(channel_id) do
    Repo.query(
      "SELECT event_id FROM chat_v2.events WHERE channel_id = $1 ORDER BY event_id DESC LIMIT 1",
      [channel_id],
      type: true
    )
    |> Query.rows()
    |> List.first()
    |> case do
      %{"event_id" => id} -> id
      _ -> nil
    end
  end

  defp last_visible_message(channel_id) do
    Repo.query(
      """
      SELECT text, created_at, sender_user_id
      FROM chat_v2.messages
      WHERE channel_id = $1
        AND status NOT IN ('deleted', 'recalled')
      ORDER BY created_at DESC, message_id DESC
      LIMIT 1
      """,
      [channel_id],
      type: true
    )
    |> Query.rows()
    |> List.first()
    |> case do
      nil -> {nil, nil, nil}
      row -> {row["created_at"], row["text"], row["sender_user_id"]}
    end
  end

  # ---------------------------------------------------------------- helpers

  defp collect_profile_ids(user_id, rows) do
    [user_id] ++
      Enum.flat_map(rows, fn row ->
        [row["last_message_sender_id"], row["dm_peer_user_id"]]
      end)
  end
end
