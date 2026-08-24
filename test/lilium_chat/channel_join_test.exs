defmodule LiliumChat.ChannelJoinTest do
  @moduledoc """
  Join public channel tests (issue #13, contract §5.7): `channel.join`
  driven through `LiliumChat.Channel` (the per-channel writer, D13).

  Covers: response shape (old Worker `joinChannelHandler` parity), gates
  (not found / dissolved / DM kind / visibility), the already-active no-op
  (existing role + joined_at, no consumption side effects), rejoin after
  leave, idempotent replay, member.joined + system.notice events, and the
  D8 `channel_joined` hint.
  """

  use LiliumChat.DataCase, async: false

  import LiliumChat.BroadcastTest
  import LiliumChatWeb.ReadFixtures

  alias LiliumChat.{Channel, Query, Repo}

  @uid "6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e6f"
  @other "7a2f3d4e-5b6c-8d9e-0f1a-2b3c4d5e6f70"

  # ----------------------------------------------------------------- helpers

  defp channel_row(channel_id) do
    Query.rows(
      Repo.query(
        "SELECT channel_id, kind, visibility, title, topic, status, member_count, " <>
          "membership_version, created_at, updated_at " <>
          "FROM chat_v2.channels WHERE channel_id = $1",
        [channel_id],
        type: true
      )
    )
    |> List.first()
  end

  defp member_row(channel_id, user_id) do
    Query.rows(
      Repo.query(
        "SELECT user_id, role, status, joined_at FROM chat_v2.channel_members " <>
          "WHERE channel_id = $1 AND user_id = $2",
        [channel_id, user_id],
        type: true
      )
    )
    |> List.first()
  end

  defp events(channel_id) do
    Query.rows(
      Repo.query(
        "SELECT event_id, event_type, payload, membership_version_at_event " <>
          "FROM chat_v2.events WHERE channel_id = $1 ORDER BY event_id",
        [channel_id],
        type: true
      )
    )
  end

  defp seed_public_channel(visibility \\ "public_listed") do
    cid = "ch-join-" <> Ecto.UUID.generate()
    seed_channel(cid, visibility: visibility, created_by: @uid, title: "Joinable", topic: "t")
    seed_membership(cid, @uid, "owner")
    seed_profile(@uid, "Owner", nil)
    cid
  end

  # ------------------------------------------------------------------ join

  test "join public_listed → member row, count/mv, member.joined(public) + system.notice" do
    cid = seed_public_channel()
    seed_profile(@other, "Joiner", nil)

    {:ok, response} = Channel.join_channel(@other, "key-j1", cid)

    ch = response["channel"]
    assert ch["channel_id"] == cid
    assert ch["kind"] == "channel"
    assert ch["visibility"] == "public_listed"
    assert ch["title"] == "Joinable"
    assert ch["topic"] == "t"
    assert ch["member_count"] == 2
    assert ch["role"] == "member"
    assert ch["status"] == "active"
    assert is_binary(ch["created_at"])
    assert is_binary(ch["updated_at"])

    assert response["membership"]["role"] == "member"
    assert is_binary(response["membership"]["joined_at"])

    member = member_row(cid, @other)
    assert member["role"] == "member"
    assert member["status"] == "active"

    meta = channel_row(cid)
    assert meta["member_count"] == 2
    assert meta["membership_version"] == 2

    [joined, notice] = events(cid)
    assert joined["event_type"] == "member.joined"
    payload = joined["payload"]
    assert payload["user_id"] == @other
    assert payload["role"] == "member"
    assert payload["membership_version"] == 2
    assert payload["actor_kind"] == "user"
    assert payload["actor_id"] == @other
    assert payload["join_source"] == "public"
    assert payload["inviter_user_id"] == nil
    assert joined["membership_version_at_event"] == 2

    assert notice["event_type"] == "system.notice"
    assert notice["payload"]["notice_kind"] == "member.joined"
  end

  test "join visibility gates: private / public_unlisted → FORBIDDEN" do
    private = seed_public_channel("private")
    assert {:error, %{code: "FORBIDDEN"}} = Channel.join_channel(@other, "k1", private)

    unlisted = seed_public_channel("public_unlisted")
    assert {:error, %{code: "FORBIDDEN"}} = Channel.join_channel(@other, "k2", unlisted)
  end

  test "join gates: DM kind / dissolved / missing channel" do
    dm_cid = "ch-join-dm-" <> Ecto.UUID.generate()
    seed_channel(dm_cid, kind: "dm", created_by: @uid)
    seed_membership(dm_cid, @uid, "member")
    seed_membership(dm_cid, @other, "member")

    assert {:error, %{code: "UNSUPPORTED_CHANNEL_KIND"}} =
             Channel.join_channel(@other, "k1", dm_cid)

    dissolved = "ch-join-" <> Ecto.UUID.generate()
    seed_channel(dissolved, status: "dissolved", created_by: @uid)
    seed_membership(dissolved, @uid, "owner")
    assert {:error, %{code: "CHANNEL_DISSOLVED"}} = Channel.join_channel(@other, "k2", dissolved)

    missing = "ch-join-" <> Ecto.UUID.generate()
    assert {:error, %{code: "CHANNEL_NOT_FOUND"}} = Channel.join_channel(@other, "k3", missing)
  end

  test "join by an already-active member → no-op with existing role + joined_at" do
    cid = seed_public_channel()
    seed_profile(@other, "Admin", nil)
    seed_membership(cid, @other, "admin", status: "active")

    Repo.query!(
      "UPDATE chat_v2.channels SET member_count = 4, membership_version = 7 WHERE channel_id = $1",
      [cid],
      type: true
    )

    joined_at = DateTime.utc_now()

    Repo.query!(
      "UPDATE chat_v2.channel_members SET joined_at = $2 WHERE channel_id = $1 AND user_id = $3",
      [cid, joined_at, @other],
      type: true
    )

    {:ok, response} = Channel.join_channel(@other, "key-j-noop", cid)

    assert response["membership"]["role"] == "admin"
    assert response["membership"]["joined_at"] == LiliumChat.Projections.format_ts(joined_at)
    assert response["channel"]["member_count"] == 4
    assert response["channel"]["role"] == "admin"

    # No events, no counter movement.
    assert events(cid) == []
    meta = channel_row(cid)
    assert meta["member_count"] == 4
    assert meta["membership_version"] == 7
  end

  test "rejoin after leave → role reset to member, count/mv bump, new joined_at" do
    cid = seed_public_channel()
    seed_profile(@other, "Leaver", nil)

    seed_membership(cid, @other, "admin", status: "left", left_at: DateTime.utc_now())

    Repo.query!(
      "UPDATE chat_v2.channels SET member_count = 3, membership_version = 3 WHERE channel_id = $1",
      [cid],
      type: true
    )

    {:ok, response} = Channel.join_channel(@other, "key-j-rejoin", cid)

    assert response["membership"]["role"] == "member"

    member = member_row(cid, @other)
    assert member["role"] == "member"
    assert member["status"] == "active"

    meta = channel_row(cid)
    assert meta["member_count"] == 4
    assert meta["membership_version"] == 4

    [joined, notice] = events(cid)
    assert joined["event_type"] == "member.joined"
    assert joined["payload"]["join_source"] == "public"
    assert joined["membership_version_at_event"] == 4
    assert notice["event_type"] == "system.notice"
  end

  test "join replay (same key) → identical response, no second write" do
    cid = seed_public_channel()
    seed_profile(@other, "Joiner", nil)

    {:ok, first} = Channel.join_channel(@other, "key-j-replay", cid)
    {:ok, second} = Channel.join_channel(@other, "key-j-replay", cid)

    assert first == second
    assert length(events(cid)) == 2
    assert channel_row(cid)["member_count"] == 2
  end

  test "join broadcasts member.joined + system.notice frames and the channel_joined hint" do
    cid = seed_public_channel()
    seed_profile(@other, "Joiner", nil)

    channel_topic = subscribe("channel:#{cid}")
    user_topic = subscribe("user:#{@other}")
    assert_receive {:sub_ready, _}, 2_000
    assert_receive {:sub_ready, _}, 2_000

    send(channel_topic.pid, :go)
    send(user_topic.pid, :go)

    {:ok, _} = Channel.join_channel(@other, "key-j-hint", cid)

    frames = Task.await(channel_topic)
    assert Enum.map(frames, & &1["type"]) == ["member.joined", "system.notice"]
    assert hd(frames)["payload"]["join_source"] == "public"
    assert hd(frames)["membership_version_at_event"] == 2

    hints = Task.await(user_topic)

    assert [
             %{
               "frame_type" => "user_event",
               "event" => "my_channels_changed",
               "reason" => "channel_joined"
             }
           ] =
             Enum.map(hints, fn f ->
               %{"frame_type" => f["frame_type"], "event" => f["event"], "reason" => f["reason"]}
             end)
  end
end
