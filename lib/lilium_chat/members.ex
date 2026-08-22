defmodule LiliumChat.Members do
  @moduledoc """
  Channel member read path (contract §7.1 / §7.1b, issue #7).

  * `list/4` — `GET /api/chat/channels/{channel_id}/members?query=&limit=&cursor=`:
    the active-member list. `query` is a typeahead filter (prefix match on
    display name or user id, case-insensitive); without `query` the list is
    keyset-paged.
  * `detail/3` — `GET /api/chat/channels/{channel_id}/members/{user_id}`:
    exact single-member read for the profile sheet (any membership status).

  Semantics mirror the old Worker (`listMembersHandler` / `getMemberHandler` +
  `ChatChannel.listMembers` / `getMember` + `member-list-order.ts`):

  * ordering = role rank (`owner` 0, `admin` 1, other 2), `joined_at` ASC,
    `user_id` ASC;
  * the DO always over-fetches up to 101 rows; without `query` a stable
    keyset cursor (`rank|joined_at|user_id`) is emitted when the over-fetch
    is full, and WITH `query` the fetched page is filtered in memory and
    `next_cursor` is always null;
  * both routes require the caller to be an active member (403 FORBIDDEN),
    and 404 CHANNEL_NOT_FOUND when the channel row is missing.
  """

  alias LiliumChat.Errors
  alias LiliumChat.Profiles
  alias LiliumChat.Projections
  alias LiliumChat.Query
  alias LiliumChat.Repo

  @overfetch 101

  @doc """
  List the channel's active members (contract §7.1).

  `query`/`limit`/`cursor` as documented in the module. Returns
  `%{items: [{user, role, joined_at}], next_cursor: string | nil}`.
  Raises `Errors.ApiError` (CHANNEL_NOT_FOUND / FORBIDDEN).
  """
  def list(user_id, channel_id, opts \\ []) do
    query = (Keyword.get(opts, :query, "") || "") |> String.downcase()
    limit = Keyword.get(opts, :limit, 50)
    cursor = Keyword.get(opts, :cursor)

    gate!(channel_id, user_id)
    rows = member_rows(channel_id, decode_cursor(cursor))
    profiles = Profiles.resolve(Enum.map(rows, & &1["user_id"]))

    if query == "" do
      has_more = length(rows) > limit
      page = Enum.slice(rows, 0, limit)
      projected = Enum.map(page, &project_member_row(&1, profiles))

      next_cursor =
        if has_more and page != [] do
          last = List.last(page)
          encode_cursor(last["role"], last["joined_at"], last["user_id"])
        else
          nil
        end

      %{items: projected, next_cursor: next_cursor}
    else
      # Old Worker order: filter the whole over-fetch, re-sort by
      # compareMemberListRows, THEN slice.
      filtered =
        rows
        |> Enum.filter(fn row -> matches?(row, profiles, query) end)
        # joined_at stays a NaiveDateTime so sub-second ties keep order.
        |> Enum.sort_by(fn row ->
          {role_rank(row["role"]), row["joined_at"], row["user_id"]}
        end)
        |> Enum.slice(0, limit)
        |> Enum.map(&project_member_row(&1, profiles))

      %{items: filtered, next_cursor: nil}
    end
  end

  @doc """
  Read one member's record (contract §7.1b).

  Returns `%{user: UserSummary, role, joined_at, status}` where status is the
  `channel_members.status` SoT value (`active` | `left`). Raises
  `Errors.ApiError` (CHANNEL_NOT_FOUND / FORBIDDEN / MEMBER_NOT_FOUND).
  """
  def detail(user_id, channel_id, member_user_id) do
    gate!(channel_id, user_id)

    row =
      Repo.query(
        """
        SELECT user_id, role, joined_at, status
        FROM chat_v2.channel_members
        WHERE channel_id = $1 AND user_id = $2
        """,
        [channel_id, member_user_id],
        type: true
      )
      |> Query.rows()
      |> List.first()

    row = row || raise(Errors.new("MEMBER_NOT_FOUND"))
    profiles = Profiles.resolve([member_user_id])

    %{
      "user" => Projections.user_summary(member_user_id, profiles),
      "role" => row["role"],
      "joined_at" => Projections.format_ts(row["joined_at"]),
      "status" => row["status"]
    }
  end

  # --------------------------------------------------------------- queries

  # Channel-exists + viewer-active in one statement (two subqueries, one
  # round trip): missing channel → CHANNEL_NOT_FOUND (checked first, as in
  # the old Worker), otherwise non-active viewer → FORBIDDEN.
  defp gate!(channel_id, user_id) do
    row =
      Repo.query(
        """
        SELECT (SELECT 1 FROM chat_v2.channels WHERE channel_id = $1) IS NOT NULL
               AS channel_exists,
               EXISTS (SELECT 1 FROM chat_v2.channel_members
                       WHERE channel_id = $1 AND user_id = $2 AND status = 'active')
               AS viewer_active
        """,
        [channel_id, user_id],
        type: true
      )
      |> Query.rows()
      |> List.first()

    unless row["channel_exists"] do
      raise Errors.new("CHANNEL_NOT_FOUND")
    end

    unless row["viewer_active"] do
      raise Errors.new("FORBIDDEN")
    end
  end

  # Over-fetch (LIMIT 101, the old Worker's fixed page size) in the stable
  # member-list order, optionally after a keyset cursor.
  defp member_rows(channel_id, cursor) do
    cursor_clause =
      case cursor do
        nil ->
          "TRUE"

        {_rank, _joined_at, _user_id} ->
          """
          (#{role_case()} > $2
            OR (#{role_case()} = $2 AND joined_at > $3)
            OR (#{role_case()} = $2 AND joined_at = $3 AND user_id > $4))
          """
      end

    query = """
    SELECT user_id, role, joined_at
    FROM chat_v2.channel_members
    WHERE channel_id = $1
      AND status = 'active'
      AND (#{cursor_clause})
    ORDER BY #{role_case()} ASC, joined_at ASC, user_id ASC
    LIMIT #{@overfetch}
    """

    params =
      case cursor do
        nil -> [channel_id]
        {rank, joined_at, user_id} -> [channel_id, rank, joined_at, user_id]
      end

    Repo.query(query, params, type: true) |> Query.rows()
  end

  defp role_case, do: "CASE role WHEN 'owner' THEN 0 WHEN 'admin' THEN 1 ELSE 2 END"

  defp project_member_row(row, profiles) do
    %{
      "user" => Projections.user_summary(row["user_id"], profiles),
      "role" => row["role"],
      "joined_at" => Projections.format_ts(row["joined_at"])
    }
  end

  # Typeahead: prefix match on display name or user id (both lowercased),
  # exactly as the old Worker's in-handler filter (display_name is the
  # profile-resolved name, with the old Worker's fallback when absent).
  defp matches?(row, profiles, query) do
    display_name =
      row["user_id"]
      |> Projections.user_summary(profiles)
      |> Map.get("display_name")
      |> Kernel.||("")

    String.starts_with?(String.downcase(display_name), query) or
      String.starts_with?(String.downcase(row["user_id"]), query)
  end

  # ------------------------------------------------------------ cursors

  # Cursor = `roleRank|joined_at|user_id` — the old Worker's exact encoding
  # (member-list-order.ts). An invalid cursor is treated as "no cursor".
  defp decode_cursor(nil), do: nil

  defp decode_cursor(""), do: nil

  defp decode_cursor(cursor) do
    # Exactly 3 pipe-separated parts (a 4-part cursor is invalid, as in the
    # old Worker's decodeMemberListCursor).
    case String.split(cursor, "|") do
      [rank_raw, joined_at_raw, user_id] when byte_size(user_id) > 0 ->
        with {rank, ""} <- Integer.parse(rank_raw),
             true <- rank >= 0 and rank <= 2,
             {:ok, joined_at} <- NaiveDateTime.from_iso8601(joined_at_raw) do
          {rank, joined_at, user_id}
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp encode_cursor(role, joined_at, user_id) do
    "#{role_rank(role)}|#{NaiveDateTime.to_iso8601(joined_at)}|#{user_id}"
  end

  defp role_rank("owner"), do: 0
  defp role_rank("admin"), do: 1
  defp role_rank(_), do: 2
end
