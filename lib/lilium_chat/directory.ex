defmodule LiliumChat.Directory do
  @moduledoc """
  Public channel directory read path (contract §5.6, issue #7).

  `GET /api/chat/channels/directory` lists `visibility=public_listed` and
  `status=active` channels with keyset pagination. Pure read (A12): one page
  query + one membership/read_state query, zero per-channel fan-out.

  Semantics mirror the old Worker (`listPublicDirectoryHandler` +
  `ChannelDirectory.listPublicChannels`):

  * ordering = `COALESCE(last_message_at, updated_at) DESC, channel_id DESC`;
  * cursor = base64url JSON `{last_activity, channel_id}` of the last row of
    the page (an invalid cursor is swallowed, i.e. treated as "no cursor");
  * `last_message_at` = created_at of the latest non-deleted/non-recalled
    message (`ORDER BY message_id DESC`), null when the channel has none;
  * `q` filters `title` with a case-insensitive `ILIKE '%q%'` (SQLite `LIKE`
    is case-insensitive for ASCII; PG `ILIKE` keeps that parity);
  * `role` is the caller's role when the caller is an active member of that
    channel, else null; `last_read_event_id` comes from `read_state` for the
    caller's active channels; `unread_count` is always 0 and
    `last_message_preview` always null (contract §5.6 implementation note).
  """

  alias LiliumChat.Projections
  alias LiliumChat.Query
  alias LiliumChat.Repo

  @doc """
  List the public directory page for `user_id`.

  `opts`: `:q` (title substring, default `""`), `:limit` (already clamped
  1..100 by the controller; default 50), `:cursor` (opaque string or nil).
  Returns `%{items: [...], next_cursor: string | nil}`.
  """
  def list_public(user_id, opts \\ []) do
    q = Keyword.get(opts, :q, "") || ""
    limit = Keyword.get(opts, :limit, 50)
    cursor = decode_cursor(Keyword.get(opts, :cursor))

    {page, next_cursor} = page_rows(q, limit, cursor)
    membership = membership_map(user_id, Enum.map(page, & &1["channel_id"]))

    %{
      items: Enum.map(page, &project_directory_row(&1, membership)),
      next_cursor: next_cursor
    }
  end

  # ---------------------------------------------------------------- queries

  defp page_rows(q, limit, cursor) do
    {clause, params} =
      case cursor do
        nil ->
          {"TRUE", []}

        {activity, channel_id} ->
          {
            "COALESCE(last_message_at, updated_at) < $2 OR " <>
              "(COALESCE(last_message_at, updated_at) = $2 AND channel_id < $3)",
            [activity, channel_id]
          }
      end

    query = """
    SELECT channel_id, title, avatar_url, member_count, status, last_message_at,
           COALESCE(last_message_at, updated_at) AS last_activity
    FROM (
      SELECT
        c.channel_id,
        c.title,
        c.avatar_url,
        c.member_count,
        c.status,
        c.updated_at,
        (
          SELECT m.created_at
          FROM chat_v2.messages m
          WHERE m.channel_id = c.channel_id
            AND m.status NOT IN ('deleted', 'recalled')
          ORDER BY m.message_id DESC
          LIMIT 1
        ) AS last_message_at
      FROM chat_v2.channels c
      WHERE c.visibility = 'public_listed'
        AND c.status = 'active'
    ) base
    WHERE ($1::text = '' OR title ILIKE '%' || $1 || '%')
      AND (#{clause})
    ORDER BY last_activity DESC, channel_id DESC
    LIMIT #{limit + 1}
    """

    rows = Repo.query(query, [q] ++ params, type: true) |> Query.rows()

    has_more = length(rows) > limit
    page = Enum.slice(rows, 0, limit)

    next_cursor =
      if has_more and page != [] do
        last = List.last(page)
        encode_cursor(last["last_activity"], last["channel_id"])
      else
        nil
      end

    {page, next_cursor}
  end

  # The caller's active memberships among the listed rows:
  # `channel_id => {role, last_read_event_id}`.
  defp membership_map(user_id, channel_ids) do
    if channel_ids == [] do
      %{}
    else
      Repo.query(
        """
        SELECT cm.channel_id, cm.role, rs.last_read_event_id
        FROM chat_v2.channel_members cm
        LEFT JOIN chat_v2.read_state rs
          ON rs.user_id = cm.user_id AND rs.channel_id = cm.channel_id
        WHERE cm.user_id = $1
          AND cm.status = 'active'
          AND cm.channel_id = ANY($2)
        """,
        [user_id, channel_ids],
        type: true
      )
      |> Query.rows()
      |> Map.new(fn row -> {row["channel_id"], {row["role"], row["last_read_event_id"]}} end)
    end
  end

  defp project_directory_row(row, membership) do
    {role, last_read_event_id} = Map.get(membership, row["channel_id"], {nil, nil})

    %{
      "channel_id" => row["channel_id"],
      "kind" => "channel",
      "visibility" => "public_listed",
      "title" => row["title"],
      "avatar_url" => row["avatar_url"],
      "member_count" => row["member_count"],
      "role" => role,
      "status" => row["status"],
      "unread_count" => 0,
      "last_read_event_id" => last_read_event_id,
      "last_message_preview" => nil,
      "last_message_at" => Projections.format_ts(row["last_message_at"])
    }
  end

  # -------------------------------------------------------------- cursors

  # Cursor = base64url JSON `{last_activity: <ISO timestamp>, channel_id}` —
  # the old Worker's exact encoding. An invalid cursor is swallowed (treated
  # as no cursor), matching the old Worker's `logSwallowedError` behaviour.
  defp decode_cursor(nil), do: nil

  defp decode_cursor(""), do: nil

  defp decode_cursor(cursor) do
    normalized = cursor |> String.replace("-", "+") |> String.replace("_", "/")
    padded = normalized <> String.duplicate("=", rem(4 - rem(byte_size(normalized), 4), 4))

    with {:ok, json} <- Base.decode64(padded),
         {:ok, %{"last_activity" => activity, "channel_id" => channel_id}} <-
           Jason.decode(json),
         # The old Worker's `typeof … === "string"` guard: a non-string
         # `last_activity` (e.g. a JSON number) swallows the cursor instead
         # of raising inside `from_iso8601/1` (which would be a 500).
         true <- is_binary(activity) and activity != "",
         {:ok, activity_ndt} <- NaiveDateTime.from_iso8601(activity),
         true <- is_binary(channel_id) and channel_id != "" do
      {activity_ndt, channel_id}
    else
      _ -> nil
    end
  end

  # Full-precision ISO (microseconds preserved) so the keyset predicate
  # round-trips exactly; `NaiveDateTime.from_iso8601/1` parses it back.
  defp encode_cursor(activity, channel_id) do
    activity
    |> NaiveDateTime.to_iso8601()
    |> then(fn activity_iso ->
      %{"last_activity" => activity_iso, "channel_id" => channel_id}
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)
    end)
  end
end
