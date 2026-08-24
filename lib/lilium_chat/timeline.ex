defmodule LiliumChat.Timeline do
  @moduledoc """
  Channel timeline read path (contract §6.1, §6.1b, §6.6, §10.3, issue #6).

  Five pure reads, all against `chat_v2` (spec §4 / A12, bounded query count):

  * `messages_page/3` — `GET /channels/{id}/messages` (timeline history, §6.1);
  * `channel_events/4` — `GET /channels/{id}/events` (gap recovery, §6.1b);
  * `global_events/2` — `GET /events` (per-channel cursor map, §10.3);
  * `message_context/5` — `GET /channels/{id}/messages/{mid}/context` (§6.6).

  The core is the **replay re-projection** (spec A9 / §10.3): stored events keep
  only stable references; at read time the current `messages` row is re-read and
  projected, applying the deleted/recalled safe projection (no content leak), and
  actor/UserSummary refs are resolved live from `public.users`.
  """

  alias LiliumChat.Errors
  alias LiliumChat.Profiles
  alias LiliumChat.Projections
  alias LiliumChat.Query
  alias LiliumChat.Repo

  # Event-type sets (contract / old Worker `src/contract/events.ts`).
  @timeline_types [
    "message.created",
    "message.stream_finalized",
    "message.stream_abandoned",
    "channel.created",
    "channel.updated",
    "channel.archived",
    "channel.dissolved",
    "member.joined",
    "member.left",
    "member.role_updated",
    "bot.installed",
    "bot.updated",
    "command.binding_updated",
    "stateful_session.started",
    "stateful_session.updated",
    "stateful_session.closed"
  ]

  @replay_message_types [
    "message.created",
    "message.updated",
    "message.recalled",
    "message.deleted",
    "message.stream_finalized",
    "message.stream_abandoned",
    "interaction.completed",
    "command.completed"
  ]

  @management_or_bot_types [
    "channel.created",
    "channel.updated",
    "channel.dissolved",
    "member.joined",
    "member.left",
    "member.removed",
    "member.role_updated",
    "bot.installed",
    "bot.updated",
    "command.binding_updated",
    "stateful_session.started",
    "stateful_session.updated",
    "stateful_session.closed",
    "command.invoked",
    "interaction.created"
  ]

  # Browser wire event set (old Worker `CHAT_EVENT_TYPES`, 31 types) +
  # v2's `system.notice` (contract §10.4 delta). The gap-recovery (§6.1b)
  # and global (§10.3) replay paths apply NO SQL type filter — they drop
  # every other stored type at projection time, matching the old Worker's
  # `isChatEventType` guard (replay-projection.ts): the bookkeeping
  # `this.created` row (DM create / archive import) never reaches the wire.
  # The history / context paths are already SQL-filtered to
  # `@timeline_types`, a subset of this set.
  @wire_event_types [
    "message.created",
    "message.updated",
    "message.deleted",
    "message.recalled",
    "message.stream_started",
    "message.stream_delta",
    "message.stream_finalized",
    "message.stream_abandoned",
    "member.joined",
    "member.left",
    "member.removed",
    "member.role_updated",
    "channel.created",
    "channel.updated",
    "channel.archived",
    "channel.dissolved",
    "bot.installed",
    "bot.updated",
    "command.binding_updated",
    "command.invoked",
    "command.completed",
    "command.failed",
    "stateful_session.started",
    "stateful_session.updated",
    "stateful_session.closed",
    "channel.pin.set",
    "channel.pin.updated",
    "channel.pin.cleared",
    "interaction.created",
    "interaction.completed",
    "interaction.failed",
    "system.notice"
  ]

  # ------------------------------------------------------------------ public

  @doc "Timeline history page (`GET /channels/{id}/messages`, §6.1)."
  def messages_page(user_id, channel_id, params) do
    channel_meta!(user_id, channel_id)
    limit = clamp_limit(params["limit"], 50)

    {rows, next_cursor} =
      fetch_page(
        channel_id,
        nonblank(params["after"]),
        nonblank(params["before"]),
        limit,
        @timeline_types
      )

    %{items: project_event_frames(channel_id, rows), next_cursor: next_cursor}
  end

  @doc "Channel event gap-recovery page (`GET /channels/{id}/events`, §6.1b)."
  def channel_events(user_id, channel_id, after_event_id, limit) do
    channel_meta!(user_id, channel_id)
    limit = clamp_limit(limit, 100)

    # Gap recovery pages *forward* from the cursor (or the channel's earliest
    # event when no cursor), ascending — §6.1b. This is distinct from the
    # newest-first history page served by `messages_page/3`.
    {rows, next_cursor} = fetch_forward(channel_id, nonblank(after_event_id), limit)

    frames = project_event_frames(channel_id, rows)

    latest_event_id =
      case frames do
        [_ | _] -> List.last(frames)["event_id"]
        [] -> last_event_id(channel_id)
      end

    %{events: frames, latest_event_id: latest_event_id, next_cursor: next_cursor}
  end

  @doc """
  Global event replay across channels (`GET /events`, §10.3). `targets` is a list
  of `{channel_id, after_event_id}` tuples. Read-only; per-channel reads merge into
  one flattened `items` list + `last_event_id_per_channel` map.
  """
  def global_events(user_id, targets) do
    visible = visible_channel_ids(user_id, Enum.map(targets, &elem(&1, 0)) |> Enum.uniq())

    per_channel =
      for {channel_id, after_cursor} <- targets, MapSet.member?(visible, channel_id) do
        rows = query_all_after(channel_id, nonblank(after_cursor), nil)
        frames = project_event_frames(channel_id, rows)

        last_event_id =
          case frames do
            [_ | _] -> List.last(frames)["event_id"]
            [] -> nonblank(after_cursor)
          end

        {channel_id, frames, last_event_id}
      end

    items = Enum.flat_map(per_channel, fn {_cid, frames, _last} -> frames end)

    last_event_id_per_channel =
      for {channel_id, _frames, last} <- per_channel, last != nil, into: %{} do
        {channel_id, last}
      end

    %{items: items, next_cursor: nil, last_event_id_per_channel: last_event_id_per_channel}
  end

  @doc "Timeline window around an anchor message (`GET /channels/{id}/messages/{mid}/context`, §6.6)."
  def message_context(user_id, channel_id, message_id, params, default \\ 30) do
    channel_meta!(user_id, channel_id)
    before_count = parse_int(params["before"], default) |> max(0) |> min(50)
    after_count = parse_int(params["after"], default) |> max(0) |> min(50)

    anchor = anchor_event_id!(channel_id, message_id)

    before_rows =
      if before_count > 0 do
        query_window(channel_id, {:before, anchor}, before_count, @timeline_types)
        |> Enum.reverse()
      else
        []
      end

    after_rows =
      if after_count > 0 do
        query_window(channel_id, {:after, anchor}, after_count, @timeline_types)
      else
        []
      end

    raw_rows = before_rows ++ [single_event(anchor)] ++ after_rows
    frames = project_event_frames(channel_id, raw_rows)

    %{anchor_message_id: message_id, items: frames}
  end

  # ---------------------------------------------------- event frame projection

  @doc """
  Project raw event rows into Browser-visible EventFrames, batch-fetching the
  referenced messages + relations and resolving profiles. Read-only and bounded
  (one batch per relation + one profile batch) regardless of page size.
  """
  def project_event_frames(channel_id, raw_rows) do
    ids = collect_message_ids(raw_rows)
    extras = fetch_message_extras(ids)
    profiles = Profiles.resolve(collect_user_ids(raw_rows, extras))

    raw_rows
    |> Enum.map(fn row ->
      project_event_frame(channel_id, row, profiles, extras)
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp project_event_frame(channel_id, row, profiles, extras) do
    # Wire-set guard (old Worker `isChatEventType` parity, issue #13):
    # non-wire stored types (e.g. the DM `this.created` bookkeeping row)
    # are dropped from the replay page.
    unless row["event_type"] in @wire_event_types do
      nil
    else
      do_project_event_frame(channel_id, row, profiles, extras)
    end
  end

  defp do_project_event_frame(channel_id, row, profiles, extras) do
    payload = Projections.json_map(row["payload"]) || %{}

    wire_payload =
      cond do
        row["event_type"] in @replay_message_types ->
          project_message_event(row, payload, profiles, extras)

        row["event_type"] in @management_or_bot_types ->
          Projections.resolve_actor(payload, profiles)

        # system.notice stores stable refs (contract §10.4) and re-projects
        # the resolved actor / target_user on replay — all five payload keys
        # are always present on the wire.
        row["event_type"] == "system.notice" ->
          project_notice(payload, profiles)

        true ->
          payload
      end

    case wire_payload do
      nil ->
        nil

      payload ->
        Projections.build_event_frame(
          row["event_id"],
          row["event_type"],
          channel_id,
          row["occurred_at"],
          payload
        )
    end
  end

  defp project_notice(payload, profiles) do
    %{
      "notice_kind" => payload["notice_kind"],
      "actor" =>
        payload["actor_user_id"] &&
          Projections.user_summary(payload["actor_user_id"], profiles),
      "target_user" =>
        payload["target_user_id"] &&
          Projections.user_summary(payload["target_user_id"], profiles),
      "message_id" => payload["message_id"],
      "channel_changes" => payload["channel_changes"]
    }
  end

  # Returns the wire *payload* for a message-lifecycle event (nil suppresses the
  # frame). `project_event_frame/5` wraps the result in a single EventFrame.
  defp project_message_event(event_row, payload, profiles, extras) do
    message_id = payload["message"] && payload["message"]["message_id"]
    message_row = message_id && extras.messages[message_id]

    case message_row do
      nil ->
        # No current message row (deleted from the table): keep the stored payload.
        payload

      message_row ->
        hidden? = message_row["status"] in ["deleted", "recalled"]

        # A message.created for a now-deleted/recalled message is suppressed —
        # the client learns of it from the message.deleted/recalled event.
        if event_row["event_type"] == "message.created" and hidden? do
          nil
        else
          per_message = %{
            attachments: extras.attachments[message_row["message_id"]] || [],
            mentions: extras.mentions[message_row["message_id"]] || [],
            sticker: sticker_snapshot(extras.stickers[message_row["message_id"]]),
            components: Projections.json_list(message_row["components_json"]),
            command_invocation: command_invocation(message_row),
            reply_target_status:
              message_row["reply_to"] && extras.reply_status[message_row["reply_to"]],
            bot_summary:
              message_row["sender_bot_id"] &&
                extras.bot_summaries[message_row["sender_bot_id"]]
          }

          %{"message" => Projections.project_message(message_row, profiles, per_message)}
        end
    end
  end

  # ------------------------------------------------------------ batch fetchers

  # Page fetch for the pagination endpoints. Returns `{ordered_ascending, next_cursor}`
  # where `next_cursor` is the edge event_id of the raw (pre-projection) slice,
  # matching the old Worker's cursor semantics.
  defp fetch_page(channel_id, after_cursor, before_cursor, page_size, types) do
    fetch_count = page_size + 1

    {rows, forward?} =
      cond do
        after_cursor != nil ->
          {query_cursor(channel_id, {:after, after_cursor}, fetch_count, types), true}

        before_cursor != nil ->
          {query_cursor(channel_id, {:before, before_cursor}, fetch_count, types), false}

        true ->
          {query_cursor(channel_id, nil, fetch_count, types), false}
      end

    has_more? = length(rows) > page_size
    page = if has_more?, do: Enum.take(rows, page_size), else: rows
    ordered = if forward?, do: page, else: Enum.reverse(page)

    # next_cursor is the edge event_id of the returned (ascending) slice: newest
    # for a forward page, oldest for a backward/latest page (matches old Worker).
    next_cursor =
      if has_more? and ordered != [] do
        if(forward?, do: List.last(ordered), else: hd(ordered))["event_id"]
      else
        nil
      end

    {ordered, next_cursor}
  end

  defp query_cursor(channel_id, cursor, count, types) do
    {order, conditions, params} =
      case cursor do
        {:after, v} -> {"event_id ASC", ["channel_id = $1", "event_id > $2"], [channel_id, v]}
        {:before, v} -> {"event_id DESC", ["channel_id = $1", "event_id < $2"], [channel_id, v]}
        nil -> {"event_id DESC", ["channel_id = $1"], [channel_id]}
      end

    {conditions, params} = append_type_filter(conditions, params, types)
    limit_ph = length(params) + 1

    query =
      "SELECT event_id, event_type, payload, occurred_at FROM chat_v2.events WHERE " <>
        Enum.join(conditions, " AND ") <>
        " ORDER BY #{order} LIMIT $#{limit_ph}"

    Repo.query(query, params ++ [count], type: true) |> Query.rows()
  end

  # Fixed-count window (context) — no +1, exact count.
  defp query_window(channel_id, cursor, count, types) do
    {order, conditions, params} =
      case cursor do
        {:after, v} -> {"event_id ASC", ["channel_id = $1", "event_id > $2"], [channel_id, v]}
        {:before, v} -> {"event_id DESC", ["channel_id = $1", "event_id < $2"], [channel_id, v]}
      end

    {conditions, params} = append_type_filter(conditions, params, types)
    limit_ph = length(params) + 1

    query =
      "SELECT event_id, event_type, payload, occurred_at FROM chat_v2.events WHERE " <>
        Enum.join(conditions, " AND ") <>
        " ORDER BY #{order} LIMIT $#{limit_ph}"

    Repo.query(query, params ++ [count], type: true) |> Query.rows()
  end

  defp query_all_after(channel_id, after_cursor, types) do
    {order, conditions, params} =
      if after_cursor do
        {"event_id ASC", ["channel_id = $1", "event_id > $2"], [channel_id, after_cursor]}
      else
        {"event_id ASC", ["channel_id = $1"], [channel_id]}
      end

    {conditions, params} = append_type_filter(conditions, params, types)

    query =
      "SELECT event_id, event_type, payload, occurred_at FROM chat_v2.events WHERE " <>
        Enum.join(conditions, " AND ") <> " ORDER BY " <> order

    Repo.query(query, params, type: true) |> Query.rows()
  end

  # Forward (gap-recovery) fetch for `GET /channels/{id}/events` (§6.1b):
  # ascending from the cursor, or from the channel's earliest event when no
  # cursor. `next_cursor` is the newest event_id of the returned page when a
  # further page may exist.
  defp fetch_forward(channel_id, after_cursor, limit) do
    fetch_count = limit + 1

    {conditions, params} =
      if after_cursor do
        {["channel_id = $1", "event_id > $2"], [channel_id, after_cursor]}
      else
        {["channel_id = $1"], [channel_id]}
      end

    query =
      "SELECT event_id, event_type, payload, occurred_at FROM chat_v2.events WHERE " <>
        Enum.join(conditions, " AND ") <>
        " ORDER BY event_id ASC LIMIT $" <> Integer.to_string(length(params) + 1)

    rows = Repo.query(query, params ++ [fetch_count], type: true) |> Query.rows()
    has_more? = length(rows) > limit
    page = if has_more?, do: Enum.take(rows, limit), else: rows
    next_cursor = if has_more? and page != [], do: List.last(page)["event_id"], else: nil

    {page, next_cursor}
  end

  # Membership/visibility gate for the global `GET /events` (§10.3): a channel
  # is visible when it exists and is either public or the user is an active
  # member. Bounded (two batch queries regardless of channel count).
  defp visible_channel_ids(_user_id, channel_ids) when channel_ids == [], do: MapSet.new()

  defp visible_channel_ids(user_id, channel_ids) do
    {ch_ph, _} = list_placeholders(channel_ids, 1)

    channels =
      Repo.query(
        "SELECT channel_id, visibility FROM chat_v2.channels WHERE channel_id IN (#{ch_ph})",
        channel_ids,
        type: true
      )
      |> Query.rows()

    {mem_ph, _} = list_placeholders(channel_ids, 2)

    members =
      Repo.query(
        "SELECT DISTINCT channel_id FROM chat_v2.channel_members " <>
          "WHERE user_id = $1 AND channel_id IN (#{mem_ph}) AND status = 'active'",
        [user_id] ++ channel_ids,
        type: true
      )
      |> Query.rows()
      |> Enum.map(& &1["channel_id"])
      |> MapSet.new()

    for row <- channels,
        row["visibility"] != "private" or MapSet.member?(members, row["channel_id"]),
        into: MapSet.new() do
      row["channel_id"]
    end
  end

  defp append_type_filter(conditions, params, nil), do: {conditions, params}

  defp append_type_filter(conditions, params, types) do
    ph = list_placeholders(types, length(params) + 1) |> elem(0)
    {conditions ++ ["event_type IN (#{ph})"], params ++ types}
  end

  defp single_event(event_id) do
    Repo.query(
      "SELECT event_id, event_type, payload, occurred_at FROM chat_v2.events WHERE event_id = $1",
      [event_id],
      type: true
    )
    |> Query.rows()
    |> List.first()
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

  defp anchor_event_id!(channel_id, message_id) do
    status =
      Repo.query(
        "SELECT status FROM chat_v2.messages WHERE message_id = $1 AND channel_id = $2",
        [message_id, channel_id],
        type: true
      )
      |> Query.rows()
      |> List.first()

    unless status, do: raise(Errors.new("MESSAGE_NOT_FOUND"))
    if status["status"] in ["deleted", "recalled"], do: raise(Errors.new("MESSAGE_NOT_FOUND"))

    anchor =
      Repo.query(
        """
        SELECT e.event_id
        FROM chat_v2.events e
        WHERE e.channel_id = $1
          AND e.event_type = 'message.created'
          AND e.payload -> 'message' ->> 'message_id' = $2
        LIMIT 1
        """,
        [channel_id, message_id],
        type: true
      )
      |> Query.rows()
      |> List.first()

    anchor = anchor && anchor["event_id"]
    unless anchor, do: raise(Errors.new("MESSAGE_NOT_FOUND"))
    anchor
  end

  # ------------------------------------------------------------ relation batch

  defp fetch_message_extras(message_ids) do
    messages =
      batch(
        "SELECT message_id, command_id, channel_id, sender_kind, sender_user_id, sender_bot_id, " <>
          "type, format, status, text, reply_to, reply_snapshot_json, stream_state, " <>
          "invocation_json, components_json, created_at, updated_at, edited_at, deleted_at, " <>
          "deleted_by, recalled_at " <>
          "FROM chat_v2.messages WHERE message_id IN (?)",
        message_ids
      )

    messages_by_id = Enum.into(messages, %{}, fn r -> {r["message_id"], r} end)

    mention_rows =
      batch(
        "SELECT message_id, user_id, start_index, end_index FROM chat_v2.mentions WHERE message_id IN (?)",
        message_ids
      )

    mentions_by_id =
      Enum.group_by(mention_rows, & &1["message_id"], fn r ->
        %{"user_id" => r["user_id"], "start" => r["start_index"], "end" => r["end_index"]}
      end)

    attachment_rows =
      batch(
        "SELECT ma.message_id, a.attachment_id, a.mime_type, a.size_bytes, a.width, a.height, a.blurhash, a.url " <>
          "FROM chat_v2.message_attachments ma " <>
          "JOIN chat_v2.attachments a ON a.attachment_id = ma.attachment_id " <>
          "WHERE ma.message_id IN (?)",
        message_ids
      )

    attachments_by_id =
      Enum.group_by(attachment_rows, & &1["message_id"], fn r ->
        %{
          "attachment_id" => r["attachment_id"],
          "url" => r["url"],
          "mime_type" => r["mime_type"],
          "size_bytes" => r["size_bytes"],
          "width" => r["width"],
          "height" => r["height"],
          "blurhash" => r["blurhash"]
        }
      end)

    sticker_rows =
      batch(
        "SELECT message_id, sticker_id, attachment_id, url, mime_type, width, height, size_bytes, blurhash " <>
          "FROM chat_v2.message_stickers WHERE message_id IN (?)",
        message_ids
      )

    stickers_by_id = Enum.into(sticker_rows, %{}, fn r -> {r["message_id"], r} end)

    reply_ids =
      messages
      |> Enum.map(& &1["reply_to"])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    reply_rows =
      if reply_ids == [] do
        []
      else
        batch(
          "SELECT message_id, status FROM chat_v2.messages WHERE message_id IN (?)",
          reply_ids
        )
      end

    reply_status = Enum.into(reply_rows, %{}, fn r -> {r["message_id"], r["status"]} end)

    # Bot sender summaries for replay (contract §3.4: `sender.bot.display_name`
    # / `avatar_url`) — resolved live from `bot_apps` (issue #19; the v2
    # `messages` table does not denormalize bot names).
    bot_ids =
      messages
      |> Enum.map(& &1["sender_bot_id"])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    bot_summaries =
      if bot_ids == [] do
        %{}
      else
        batch(
          "SELECT bot_id, display_name, avatar_url FROM chat_v2.bot_apps WHERE bot_id IN (?)",
          bot_ids
        )
        |> Enum.into(%{}, fn r ->
          {r["bot_id"], %{"display_name" => r["display_name"], "avatar_url" => r["avatar_url"]}}
        end)
      end

    %{
      messages: messages_by_id,
      mentions: mentions_by_id,
      attachments: attachments_by_id,
      stickers: stickers_by_id,
      reply_status: reply_status,
      bot_summaries: bot_summaries
    }
  end

  # Run a batch query: replace the literal `IN (?)` marker with a real
  # `$1, $2, ...` placeholder list. Short-circuits for an empty id list.
  defp batch(_query_template, ids) when ids == [], do: []

  defp batch(query_template, ids) do
    {ph, _vals} = list_placeholders(ids, 1)
    query = String.replace(query_template, "IN (?)", "IN (#{ph})")
    Repo.query(query, ids, type: true) |> Query.rows()
  end

  defp collect_message_ids(raw_rows) do
    raw_rows
    |> Enum.map(fn row ->
      payload = Projections.json_map(row["payload"]) || %{}
      payload["message"] && payload["message"]["message_id"]
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp collect_user_ids(raw_rows, extras) do
    sender_ids =
      extras.messages
      |> Map.values()
      |> Enum.map(& &1["sender_user_id"])
      |> Enum.reject(&is_nil/1)

    actor_ids =
      raw_rows
      |> Enum.reject(fn row -> row["event_type"] in @replay_message_types end)
      |> Enum.map(fn row ->
        payload = Projections.json_map(row["payload"]) || %{}

        [
          payload["actor_kind"] == "user" && payload["actor_id"],
          payload["actor_user_id"],
          payload["target_user_id"],
          payload["user_id"],
          payload["inviter_user_id"]
        ]
        |> Enum.reject(&is_nil/1)
      end)
      |> List.flatten()
      # `actor_kind == "user" && actor_id` yields `false` for system actors —
      # keep only real user ids before the profile batch.
      |> Enum.filter(&is_binary/1)

    (sender_ids ++ actor_ids) |> Enum.uniq()
  end

  # ------------------------------------------------------------ small helpers

  defp sticker_snapshot(nil), do: nil

  defp sticker_snapshot(row) do
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

  defp command_invocation(row) do
    case Projections.json_map(row["invocation_json"]) do
      map when is_map(map) and map != %{} -> map
      _ -> nil
    end
  end

  defp channel_meta!(user_id, channel_id) do
    meta =
      Repo.query(
        "SELECT channel_id, kind, visibility FROM chat_v2.channels WHERE channel_id = $1",
        [channel_id],
        type: true
      )
      |> Query.rows()
      |> List.first()

    meta = meta || raise(Errors.new("CHANNEL_NOT_FOUND"))

    member =
      Repo.query(
        "SELECT 1 AS x FROM chat_v2.channel_members WHERE channel_id = $1 AND user_id = $2 AND status = 'active'",
        [channel_id, user_id],
        type: true
      )
      |> Query.rows()
      |> List.first()

    if member == nil and meta["visibility"] == "private" do
      raise Errors.new("FORBIDDEN")
    end

    meta
  end

  defp nonblank(nil), do: nil
  defp nonblank(""), do: nil
  defp nonblank(value), do: value

  defp parse_int(nil, default), do: default

  defp parse_int(value, default) do
    case Integer.parse(to_string(value)) do
      {n, _} -> n
      _ -> default
    end
  end

  # Parse + clamp a page size to the contract range (1..100); a missing/invalid
  # value falls back to `default`, and an out-of-range value is clamped so a
  # negative `limit` never becomes a `LIMIT -n` (unbounded).
  defp clamp_limit(value, default) do
    value = parse_int(value, default)
    value |> max(1) |> min(100)
  end

  # Expand a list into "$start, $(start+1), ..." (returns `{placeholder_csv, items}`).
  defp list_placeholders(items, start) do
    ph = Enum.map_join(Enum.with_index(items), ",", fn {_, i} -> "$#{start + i}" end)
    {ph, items}
  end
end
