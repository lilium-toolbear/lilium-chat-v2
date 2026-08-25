defmodule LiliumChat.Invites do
  @moduledoc """
  Invite preview read path (contract §5.10, issue #7).

  `GET /api/chat/invites/{invite_code}` previews an invite before joining:
  invite meta, channel summary, inviter, up to 3 sample members, and the
  caller's own membership state. **Read-only — no join side effects** (the
  preview must stay separable from `accept`, which increments `used_count`
  and writes a member row).

  Semantics mirror the old Worker (`previewInviteHandler` +
  `ChatChannel.getInvite`):

  * invite row missing / revoked / expired / channel missing → 404
    `INVITE_NOT_FOUND`;
  * `sample_members` = up to 3 active members, `ORDER BY user_id ASC`;
  * `my_membership.status` ∈ `not_joined` | `active` | `left` (the `channel_id`
    is set only when `active`);
  * the invite-code route index of the old Worker was an outbox-fed
    projection with a lag window (`409 ROUTE_INDEX_PENDING`); in v2 the
    `invites.channel_id` link is primary data, so no lag window exists.
  """

  alias LiliumChat.Errors
  alias LiliumChat.Profiles
  alias LiliumChat.Projections
  alias LiliumChat.Query
  alias LiliumChat.Repo

  @max_sample_members 3

  @doc """
  Preview the invite `invite_code` for `user_id`.

  Returns the `InvitePreviewApiResponse` map
  (`%{invite, channel, inviter, sample_members, my_membership}`).
  Raises `Errors.ApiError` (INVITE_NOT_FOUND).
  """
  def preview(user_id, invite_code) do
    row = invite_row(invite_code) || raise(Errors.new("INVITE_NOT_FOUND"))

    now = DateTime.utc_now()

    unless invite_active?(row, now) do
      raise Errors.new("INVITE_NOT_FOUND", "invite expired or revoked")
    end

    channel =
      row["channel"] || raise(Errors.new("INVITE_NOT_FOUND"))

    channel_id = channel["channel_id"]
    sample_ids = sample_member_ids(channel_id)
    my_status = my_membership_status(channel_id, user_id)

    profiles =
      Profiles.resolve([row["created_by"]] ++ sample_ids)

    %{
      "invite" => %{
        "invite_code" => row["invite_code"],
        "expires_at" => Projections.format_ts(row["expires_at"]),
        "max_uses" => row["max_uses"]
      },
      "channel" => %{
        "channel_id" => channel_id,
        "kind" => channel["kind"],
        "visibility" => channel["visibility"],
        "title" => channel["title"],
        "avatar_url" => channel["avatar_url"],
        "member_count" => channel["member_count"],
        "status" => channel["status"]
      },
      "inviter" => Projections.user_summary(row["created_by"], profiles),
      "sample_members" =>
        Enum.map(sample_ids, fn id -> Projections.user_summary(id, profiles) end),
      "my_membership" => %{
        "status" => my_status,
        "channel_id" => if(my_status == "active", do: channel_id, else: nil)
      }
    }
  end

  # ---------------------------------------------------------------- queries

  # Invite row + channel meta in one statement (LEFT JOIN; a missing channel
  # surfaces as `channel == nil` → INVITE_NOT_FOUND, as in the old Worker).
  defp invite_row(invite_code) do
    Repo.query(
      """
      SELECT i.invite_code,
             i.created_by,
             i.expires_at,
             i.max_uses,
             i.revoked_at,
             c.channel_id,
             c.kind,
             c.visibility,
             c.title,
             c.avatar_url,
             c.member_count,
             c.status
      FROM chat_v2.invites i
      LEFT JOIN chat_v2.channels c ON c.channel_id = i.channel_id
      WHERE i.invite_code = $1
      """,
      [invite_code],
      type: true
    )
    |> Query.rows()
    |> List.first()
    |> case do
      nil ->
        nil

      row ->
        channel =
          if row["channel_id"] do
            %{
              "channel_id" => row["channel_id"],
              "kind" => row["kind"],
              "visibility" => row["visibility"],
              "title" => row["title"],
              "avatar_url" => row["avatar_url"],
              "member_count" => row["member_count"],
              "status" => row["status"]
            }
          else
            nil
          end

        Map.put(row, "channel", channel)
    end
  end

  @doc """
  Invite-row liveness (shared by the read path `preview/2` and the write
  path `LiliumChat.InviteCommands`): the row is live when it is not revoked
  and its `expires_at` is still in the future.

  The old Worker rejects the invite when it is revoked or its expires_at is
  at or before now (`Date.parse(expires_at) <= Date.now()`).

  NOTE: `expires_at` decodes as %NaiveDateTime{} (`:utc_datetime_usec`);
  Elixir's cross-type `>` between NaiveDateTime and DateTime is NOT an
  instant comparison, so compare like types (the stored wall time is UTC).
  And `>` on two structs is a STRUCTURAL (key-ordered) comparison, not a
  chronological one — it would compare `day` before `month`/`year`, so an
  invite expiring on the 1st of a later month could be judged "expired"
  while the 25th of the current month is still live. Use the semantic
  `NaiveDateTime.compare/2` instead.
  """
  def invite_active?(row, now) do
    is_nil(row["revoked_at"]) and
      is_struct(row["expires_at"], NaiveDateTime) and
      NaiveDateTime.compare(row["expires_at"], DateTime.to_naive(now)) == :gt
  end

  defp sample_member_ids(channel_id) do
    Repo.query(
      """
      SELECT user_id
      FROM chat_v2.channel_members
      WHERE channel_id = $1 AND status = 'active'
      ORDER BY user_id ASC
      LIMIT #{@max_sample_members}
      """,
      [channel_id],
      type: true
    )
    |> Query.rows()
    |> Enum.map(& &1["user_id"])
  end

  defp my_membership_status(channel_id, user_id) do
    Repo.query(
      "SELECT status FROM chat_v2.channel_members WHERE channel_id = $1 AND user_id = $2",
      [channel_id, user_id],
      type: true
    )
    |> Query.rows()
    |> List.first()
    |> case do
      nil -> "not_joined"
      %{"status" => status} -> status
    end
  end
end
