defmodule LiliumChat.InviteCommandsTest do
  @moduledoc """
  Invite write-path tests (issue #13, contract §5.8 / §5.9):
  `channel.invite_create` + `channel.invite_accept` driven through
  `LiliumChat.Channel` (the per-channel writer, D13).

  Covers: response shapes, invites-row effects (personal stable code,
  upsert refresh / un-revoke), used_count, member.joined + system.notice
  events, the ROUTE_INDEX_PENDING routing split, idempotency (replay /
  conflict), gates, and the D8 `channel_joined` user hint.
  """

  use LiliumChat.DataCase, async: false

  import LiliumChat.BroadcastTest
  import LiliumChat.InviteFixtures
  import LiliumChatWeb.ReadFixtures

  alias LiliumChat.{Channel, InviteCommands, Query, Repo}

  @uid "6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e6f"
  @other "7a2f3d4e-5b6c-8d9e-0f1a-2b3c4d5e6f70"
  @third "8b3e4e5f-6c7d-9e0f-1a2b-3c4d5e6f7081"

  # ----------------------------------------------------------------- helpers

  defp invite_row(code) do
    Query.rows(
      Repo.query(
        "SELECT invite_code, created_by, channel_id, expires_at, max_uses, used_count, revoked_at " <>
          "FROM chat_v2.invites WHERE invite_code = $1",
        [code],
        type: true
      )
    )
    |> List.first()
  end

  defp channel_row(channel_id) do
    Query.rows(
      Repo.query(
        "SELECT channel_id, kind, visibility, title, status, member_count, membership_version " <>
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
        "SELECT event_id, event_type, actor_kind, actor_id, payload, membership_version_at_event " <>
          "FROM chat_v2.events WHERE channel_id = $1 ORDER BY event_id",
        [channel_id],
        type: true
      )
    )
  end

  defp seed_member_channel(user_id, opts \\ []) do
    cid = "ch-inv-" <> Ecto.UUID.generate()

    seed_channel(cid,
      visibility: Keyword.get(opts, :visibility, "public_listed"),
      created_by: user_id
    )

    seed_membership(cid, user_id, "owner")
    seed_profile(user_id, "Invite Owner", nil)
    cid
  end

  # --------------------------------------------------------------- create

  test "create → personal stable code, expires_at, max_uses; row written" do
    seed_profile(@uid, "Owner", nil)
    cid = seed_member_channel(@uid)

    {:ok, response} = Channel.create_invite(@uid, "key-ic1", cid, %{})

    code = personal_code(cid, @uid)
    assert response["invite_code"] == code
    assert response["max_uses"] == nil
    assert is_binary(response["expires_at"])

    row = invite_row(code)
    assert row["created_by"] == @uid
    assert row["channel_id"] == cid
    assert row["used_count"] == 0
    assert row["revoked_at"] == nil
    # Default 7-day TTL.
    assert response["expires_at"] =~ ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/

    # No timeline events (old Worker: the row went to the invite outbox).
    assert events(cid) == []
  end

  test "create honors expires_in_seconds / max_uses" do
    cid = seed_member_channel(@uid)

    {:ok, response} =
      Channel.create_invite(@uid, "key-ic2", cid, %{"expires_in_seconds" => 3600, "max_uses" => 5})

    row = invite_row(response["invite_code"])
    assert row["max_uses"] == 5
  end

  test "create validation: expires / max_uses value types → 422 INVALID_MESSAGE" do
    cid = seed_member_channel(@uid)

    assert {:error, %{code: "INVALID_MESSAGE"}} =
             Channel.create_invite(@uid, "k1", cid, %{"expires_in_seconds" => 0})

    assert {:error, %{code: "INVALID_MESSAGE"}} =
             Channel.create_invite(@uid, "k2", cid, %{"expires_in_seconds" => -1})

    assert {:error, %{code: "INVALID_MESSAGE"}} =
             Channel.create_invite(@uid, "k3", cid, %{"max_uses" => -1})

    assert {:error, %{code: "INVALID_MESSAGE"}} =
             Channel.create_invite(@uid, "k4", cid, %{"max_uses" => 1.5})

    assert {:error, %{code: "INVALID_MESSAGE"}} =
             Channel.create_invite(@uid, "k5", cid, %{"expires_in_seconds" => "seven"})
  end

  test "create gates: non-member FORBIDDEN, dissolved, missing channel" do
    cid = seed_member_channel(@uid)

    seed_profile(@third, "Stranger", nil)
    assert {:error, %{code: "FORBIDDEN"}} = Channel.create_invite(@third, "k", cid, %{})

    dissolved = "ch-inv-" <> Ecto.UUID.generate()
    seed_channel(dissolved, status: "dissolved", created_by: @uid)
    seed_membership(dissolved, @uid, "owner")

    assert {:error, %{code: "CHANNEL_DISSOLVED"}} =
             Channel.create_invite(@uid, "k2", dissolved, %{})

    missing = "ch-inv-" <> Ecto.UUID.generate()

    assert {:error, %{code: "CHANNEL_NOT_FOUND"}} =
             Channel.create_invite(@uid, "k3", missing, %{})
  end

  test "create replay (same key + body) → identical response, no second row" do
    cid = seed_member_channel(@uid)

    {:ok, first} = Channel.create_invite(@uid, "key-replay", cid, %{"max_uses" => 3})
    {:ok, second} = Channel.create_invite(@uid, "key-replay", cid, %{"max_uses" => 3})

    assert first == second

    code = first["invite_code"]

    rows =
      Query.rows(
        Repo.query("SELECT invite_code FROM chat_v2.invites WHERE invite_code = $1", [code])
      )

    assert length(rows) == 1
  end

  test "create conflict: same key, different body → 409 IDEMPOTENCY_CONFLICT" do
    cid = seed_member_channel(@uid)

    {:ok, _} = Channel.create_invite(@uid, "key-conflict", cid, %{})

    assert {:error, %{code: "IDEMPOTENCY_CONFLICT"}} =
             Channel.create_invite(@uid, "key-conflict", cid, %{"max_uses" => 9})
  end

  test "create re-create refreshes TTL + un-revokes the SAME personal code" do
    cid = seed_member_channel(@uid)
    code = personal_code(cid, @uid)

    # Seed a pre-existing revoked invite for the SAME personal code.
    seed_invite(code, cid,
      created_by: @uid,
      expires_at: DateTime.utc_now() |> DateTime.add(1, :day),
      max_uses: 2,
      used_count: 1,
      revoked_at: DateTime.utc_now()
    )

    {:ok, response} =
      Channel.create_invite(@uid, "key-refresh", cid, %{"expires_in_seconds" => 60})

    assert response["invite_code"] == code
    row = invite_row(code)
    assert row["revoked_at"] == nil
    assert row["max_uses"] == nil
    # A one-minute TTL, not the seeded one-day one.
    {:ok, _expires, 0} = DateTime.from_iso8601(response["expires_at"])
  end

  # -------------------------------------------------------------- routing

  test "route_for: mapped / pending (NULL channel_id) / missing" do
    cid = seed_member_channel(@uid)
    mapped = "code-mapped"
    seed_invite(mapped, cid, created_by: @uid)
    assert InviteCommands.route_for(mapped) == {:ok, cid}

    # Backfill window: the row exists, channel_id is NULL.
    Repo.query!(
      "INSERT INTO chat_v2.invites (invite_code, created_by, channel_id, expires_at, max_uses, " <>
        "used_count, revoked_at, created_at) " <>
        "VALUES ($1, $2, NULL, $3, NULL, 0, NULL, $4)",
      ["code-pending", @uid, DateTime.utc_now() |> DateTime.add(7, :day), DateTime.utc_now()],
      type: true
    )

    assert InviteCommands.route_for("code-pending") == :route_index_pending
    assert InviteCommands.route_for("code-missing") == :invite_not_found
  end

  # --------------------------------------------------------------- accept

  test "accept → member row, count/mv/used_count, member.joined(invite) + system.notice" do
    cid = seed_member_channel(@uid)
    code = personal_code(cid, @uid)
    seed_invite(code, cid, created_by: @uid)

    seed_profile(@other, "New Joiner", nil)

    {:ok, response} = Channel.accept_invite(@other, "key-acc1", cid, code)

    ch = response["channel"]
    assert ch["channel_id"] == cid
    assert ch["kind"] == "channel"
    assert ch["visibility"] == "public_listed"
    assert ch["member_count"] == 2
    assert ch["status"] == "active"
    # §5.9 channel field: the seven meta fields only.
    refute Map.has_key?(ch, "topic")
    refute Map.has_key?(ch, "created_at")
    refute Map.has_key?(ch, "role")

    assert response["membership"]["role"] == "member"
    assert response["membership"]["status"] == "active"
    assert is_binary(response["membership"]["joined_at"])

    member = member_row(cid, @other)
    assert member["role"] == "member"
    assert member["status"] == "active"

    row = invite_row(code)
    assert row["used_count"] == 1

    meta = channel_row(cid)
    assert meta["member_count"] == 2
    assert meta["membership_version"] == 2

    evts = events(cid)
    assert Enum.map(evts, & &1["event_type"]) == ["member.joined", "system.notice"]

    [joined, notice] = evts
    payload = joined["payload"]
    assert payload["user_id"] == @other
    assert payload["role"] == "member"
    assert payload["membership_version"] == 2
    assert payload["actor_kind"] == "user"
    assert payload["actor_id"] == @other
    assert payload["join_source"] == "invite"
    assert payload["inviter_user_id"] == @uid
    assert joined["membership_version_at_event"] == 2

    assert notice["payload"]["notice_kind"] == "member.joined"
    assert notice["payload"]["actor_user_id"] == @other
    assert notice["payload"]["target_user_id"] == @other
  end

  test "accept by an already-active member → no-op with existing membership" do
    cid = seed_member_channel(@uid)
    code = personal_code(cid, @uid)
    seed_invite(code, cid, created_by: @uid)

    seed_profile(@other, "Joiner", nil)
    seed_membership(cid, @other, "admin", status: "active")

    # Pre-bump the row state so a fresh (wrong) join would look different.
    joined_at = DateTime.utc_now()

    Repo.query!(
      "UPDATE chat_v2.channels SET member_count = 3, membership_version = 5 WHERE channel_id = $1",
      [cid],
      type: true
    )

    Repo.query!(
      "UPDATE chat_v2.channel_members SET joined_at = $2 WHERE channel_id = $1 AND user_id = $3",
      [cid, joined_at, @other],
      type: true
    )

    {:ok, response} = Channel.accept_invite(@other, "key-acc-noop", cid, code)

    assert response["membership"]["role"] == "admin"
    assert response["membership"]["joined_at"] == LiliumChat.Projections.format_ts(joined_at)
    assert response["channel"]["member_count"] == 3

    # The invite is NOT consumed by a no-op.
    assert invite_row(code)["used_count"] == 0
    # No events for a no-op.
    assert events(cid) == []
  end

  test "accept max_uses exhausted → INVITE_NOT_AVAILABLE" do
    cid = seed_member_channel(@uid)
    code = personal_code(cid, @uid)
    seed_invite(code, cid, created_by: @uid, max_uses: 1, used_count: 1)

    seed_profile(@other, "Joiner", nil)

    assert {:error, %{code: "INVITE_NOT_AVAILABLE"}} =
             Channel.accept_invite(@other, "key-acc-max", cid, code)
  end

  test "accept expired / revoked invite → INVITE_NOT_FOUND" do
    cid = seed_member_channel(@uid)

    expired = "code-expired"

    seed_invite(expired, cid,
      created_by: @uid,
      expires_at: DateTime.utc_now() |> DateTime.add(-1, :day)
    )

    assert {:error, %{code: "INVITE_NOT_FOUND"}} =
             Channel.accept_invite(@other, "k1", cid, expired)

    revoked = "code-revoked"
    seed_invite(revoked, cid, created_by: @uid, revoked_at: DateTime.utc_now())

    assert {:error, %{code: "INVITE_NOT_FOUND"}} =
             Channel.accept_invite(@other, "k2", cid, revoked)
  end

  test "accept replay (same key) → identical response, no second member write" do
    cid = seed_member_channel(@uid)
    code = personal_code(cid, @uid)
    seed_invite(code, cid, created_by: @uid)
    seed_profile(@other, "Joiner", nil)

    {:ok, first} = Channel.accept_invite(@other, "key-acc-replay", cid, code)
    {:ok, second} = Channel.accept_invite(@other, "key-acc-replay", cid, code)

    assert first == second
    assert length(events(cid)) == 2
    assert invite_row(code)["used_count"] == 1
  end

  test "accept conflict: same key, different invite code → 409" do
    cid = seed_member_channel(@uid)
    code = personal_code(cid, @uid)
    seed_invite(code, cid, created_by: @uid)
    other_code = "code-other-#{Ecto.UUID.generate() |> String.slice(-6..-1)}"
    seed_invite(other_code, cid, created_by: @uid)
    seed_profile(@other, "Joiner", nil)

    {:ok, _} = Channel.accept_invite(@other, "key-acc-conflict", cid, code)

    assert {:error, %{code: "IDEMPOTENCY_CONFLICT"}} =
             Channel.accept_invite(@other, "key-acc-conflict", cid, other_code)
  end

  # ------------------------------------------------------------ user hints

  test "accept broadcasts member.joined + system.notice frames and the channel_joined hint" do
    cid = seed_member_channel(@uid)
    code = personal_code(cid, @uid)
    seed_invite(code, cid, created_by: @uid)
    seed_profile(@other, "Joiner", nil)

    channel_topic = subscribe("channel:#{cid}")
    user_topic = subscribe("user:#{@other}")
    assert_receive {:sub_ready, _}, 2_000
    assert_receive {:sub_ready, _}, 2_000

    send(channel_topic.pid, :go)
    send(user_topic.pid, :go)

    {:ok, _} = Channel.accept_invite(@other, "key-hint", cid, code)

    frames = Task.await(channel_topic)
    assert Enum.map(frames, & &1["type"]) == ["member.joined", "system.notice"]
    joined = hd(frames)
    assert joined["payload"]["join_source"] == "invite"
    assert joined["payload"]["inviter"]["user_id"] == @uid
    assert joined["membership_version_at_event"] == 2
    assert hd(frames)["payload"]["user"] == nil or is_map(hd(frames)["payload"]["user"])

    hints = Task.await(user_topic)
    assert length(hints) == 1
    hint = hd(hints)
    assert hint["frame_type"] == "user_event"
    assert hint["event"] == "my_channels_changed"
    assert hint["reason"] == "channel_joined"
    assert hint["changed_channel_id"] == cid
  end
end
