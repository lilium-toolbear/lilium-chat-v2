defmodule LiliumChat.ChannelEvents do
  @moduledoc """
  Channel event write + frame projection helpers shared by the per-channel
  writer operations (issue #13).

  The write-path modules (`LiliumChat.MemberCommands`,
  `LiliumChat.ChannelLifecycle`, `LiliumChat.ChannelJoin`,
  `LiliumChat.InviteCommands`) each own a per-channel event stream: business
  event rows in `chat_v2.events` plus the §10.4 `system.notice`
  bookkeeping rows, and the matching WS broadcast frames.

  * **stored payloads** carry stable refs only (`actor_kind` / `actor_id` /
    `actor_user_id` / `target_user_id` / `user_id` / `inviter_user_id` — no
    UserSummaries) so archive replay can re-project offline;
  * **wire payloads** re-project the refs to UserSummaries at output time
    (`Projections.resolve_actor/2`; notices use `notice_wire/2`).
  """

  alias LiliumChat.{Projections, Query, Repo}

  @doc "The §10.4 stored notice payload (stable refs only)."
  def notice_payload(kind, actor_user_id, target_user_id) do
    %{
      "notice_kind" => kind,
      "actor_user_id" => actor_user_id,
      "target_user_id" => target_user_id,
      "message_id" => nil,
      "channel_changes" => nil
    }
  end

  @doc "Insert a business event row (must run inside the command's PG txn)."
  def insert_event(event_id, event_type, channel_id, payload, mv, now) do
    Repo.query!(
      """
      INSERT INTO chat_v2.events (
        event_id, event_type, channel_id, actor_kind, actor_id, payload,
        membership_version_at_event, occurred_at
      ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
      """,
      [
        event_id,
        event_type,
        channel_id,
        payload["actor_kind"],
        payload["actor_id"],
        payload,
        mv,
        now
      ],
      type: true
    )
  end

  @doc "Insert a §10.4 `system.notice` row (must run inside the command's PG txn)."
  def insert_notice_event(event_id, channel_id, user_id, payload, mv, now) do
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

  @doc "Project a stored business-event row to its WS broadcast frame."
  def event_frame(event_id, event_type, channel_id, now, stored_payload, mv, profiles) do
    Projections.build_event_frame(
      event_id,
      event_type,
      channel_id,
      now,
      Projections.resolve_actor(stored_payload, profiles)
    )
    |> Map.put("membership_version_at_event", mv)
  end

  @doc "Project a stored `system.notice` row to its WS broadcast frame."
  def notice_frame(event_id, channel_id, now, stored_payload, mv, profiles) do
    Projections.build_event_frame(
      event_id,
      "system.notice",
      channel_id,
      now,
      notice_wire(stored_payload, profiles)
    )
    |> Map.put("membership_version_at_event", mv)
  end

  @doc "The wire payload for a stored `system.notice` payload."
  def notice_wire(payload, profiles) do
    %{
      "notice_kind" => payload["notice_kind"],
      "actor" => Projections.user_summary(payload["actor_user_id"], profiles),
      "target_user" =>
        payload["target_user_id"] && Projections.user_summary(payload["target_user_id"], profiles),
      "message_id" => payload["message_id"],
      "channel_changes" => payload["channel_changes"]
    }
  end

  @doc """
  Insert (or reactivate) the participant's ACTIVE member row, resetting the
  role to `member` with a fresh `joined_at` (old Worker join/accept parity:
  a rejoin is always a plain member). Returns `true` when the row was
  (re)written — a membership change — `false` when already active (no-op).
  Must run inside the command's PG txn.
  """
  def upsert_active_member(channel_id, user_id, now) do
    case member_row(channel_id, user_id) do
      %{"status" => "active"} ->
        false

      nil ->
        Repo.query!(
          "INSERT INTO chat_v2.channel_members (channel_id, user_id, role, joined_at, left_at, status) " <>
            "VALUES ($1, $2, 'member', $3, NULL, 'active')",
          [channel_id, user_id, now],
          type: true
        )

        true

      _ ->
        Repo.query!(
          "UPDATE chat_v2.channel_members " <>
            "SET role = 'member', joined_at = $3, left_at = NULL, status = 'active' " <>
            "WHERE channel_id = $1 AND user_id = $2",
          [channel_id, user_id, now],
          type: true
        )

        true
    end
  end

  defp member_row(channel_id, user_id) do
    Query.rows(
      Repo.query(
        "SELECT role, joined_at, status FROM chat_v2.channel_members " <>
          "WHERE channel_id = $1 AND user_id = $2",
        [channel_id, user_id],
        type: true
      )
    )
    |> List.first()
  end
end
