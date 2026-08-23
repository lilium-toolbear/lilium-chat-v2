defmodule LiliumChat.MemberCommandsTest do
  @moduledoc """
  Channel member-management write-path tests (issue #12, contract
  §7.2 / §7.3 / §7.4 / §7.5): `members.add` / `members.role` /
  `members.remove` / `channel.owner_transfer` driven through
  `LiliumChat.Channel` (the per-channel writer, D13).

  Covers: response shapes, row effects (channel_members + channels
  membership_version / member_count / created_by), event plans + mv schedule
  (add +1, role +1, remove +1, transfer +2 in ONE txn), stored payload
  shapes (old Worker persisted reference fields), live frame wire shapes
  (resolved actor/user), the `my_channels_changed` trigger set (D8: add →
  `channel_joined`, remove → `channel_left`, NOT role change / transfer),
  gates (404 / 409 / 403 / 422 in the old Worker's exact order), idempotency
  (replay / conflict), and replay re-projection of the member event types.
  """

  use LiliumChat.DataCase, async: false

  import LiliumChatWeb.ReadFixtures

  alias LiliumChat.{Channel, Errors, Query, Repo, Timeline}

  @owner "1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d"
  @admin "2b3c4d5e-6f7a-8b9c-0d1e-2f3a4b5c6d7e"
  @member "3c4d5e6f-7a8b-9c0d-1e2f-3a4b5c6d7e8f"
  @stranger "4d5e6f7a-8b9c-0d1e-2f3a-4b5c6d7e8f9a"
  @spare "5e6f7a8b-9c0d-1e2f-3a4b-5c6d7e8f9a0b"

  # ----------------------------------------------------------------- helpers

  defp channel_row(channel_id) do
    Query.rows(
      Repo.query(
        "SELECT channel_id, kind, status, created_by, member_count, membership_version " <>
          "FROM chat_v2.channels WHERE channel_id = $1",
        [channel_id]
      )
    )
    |> List.first()
  end

  defp members(channel_id) do
    Query.rows(
      Repo.query(
        "SELECT user_id, role, status, joined_at, left_at FROM chat_v2.channel_members " <>
          "WHERE channel_id = $1 ORDER BY user_id",
        [channel_id]
      )
    )
  end

  defp member_row(channel_id, user_id) do
    Query.rows(
      Repo.query(
        "SELECT user_id, role, status, joined_at, left_at FROM chat_v2.channel_members " <>
          "WHERE channel_id = $1 AND user_id = $2",
        [channel_id, user_id]
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

  defp idem_rows(operation) do
    Query.rows(
      Repo.query(
        "SELECT operation, operation_id, principal_id, request_hash, response_json, expires_at " <>
          "FROM chat_v2.idempotency WHERE operation = $1 ORDER BY operation_id",
        [operation]
      )
    )
  end

  # A private channel with a fixed membership layout (owner/admin/member) for
  # the gate + wire tests. `member_count` tracks the THREE active members.
  defp seeded_channel() do
    cid = "ch-mm-" <> Ecto.UUID.generate()

    seed_channel(cid, title: "Members", created_by: @owner, member_count: 3)
    seed_membership(cid, @owner, "owner")
    seed_membership(cid, @admin, "admin")
    seed_membership(cid, @member, "member")
    seed_profile(@owner, "The Owner", nil)
    seed_profile(@admin, "The Admin", nil)
    seed_profile(@member, "The Member", nil)
    seed_profile(@stranger, "Stranger", nil)

    cid
  end

  # Subscribes a helper task to a PubSub topic. The task reports readiness
  # (`{:sub_ready, topic}`), then starts collecting on `:go` and resolves to
  # the list of broadcast frames received (quiescence-based).
  defp subscribe(topic) do
    parent = self()

    Task.async(fn ->
      Phoenix.PubSub.subscribe(LiliumChat.PubSub, topic)
      send(parent, {:sub_ready, topic})

      receive do
        :go -> :going
      end

      collect_frames([])
    end)
  end

  defp collect_frames(acc) do
    receive do
      {:broadcast, _topic, frame} -> collect_frames(acc ++ [frame])
    after
      500 -> acc
    end
  end

  # --------------------------------------------------------------- add (§7.2)

  test "add → row, mv+1, count+1, member.joined + notice, channel_joined hint to the target only" do
    cid = seeded_channel()

    channel_topic = subscribe("channel:" <> cid)
    target_topic = subscribe("user:" <> @stranger)
    caller_topic = subscribe("user:" <> @admin)
    assert_receive {:sub_ready, _}, 2_000
    assert_receive {:sub_ready, _}, 2_000
    assert_receive {:sub_ready, _}, 2_000
    Enum.each([channel_topic, target_topic, caller_topic], fn task -> send(task.pid, :go) end)

    {:ok, response} =
      Channel.add_member(@admin, "key-a1", cid, %{"user_id" => @stranger, "role" => "member"})

    # response (§7.2 MemberProjection + channel_id)
    assert %{
             "member" => %{
               "channel_id" => ^cid,
               "user_id" => @stranger,
               "role" => "member",
               "joined_at" => joined_at
             }
           } = response

    assert is_binary(joined_at) and String.ends_with?(joined_at, "Z")

    # stored rows: the new active member, mv +1, member_count +1
    row = member_row(cid, @stranger)
    assert row["status"] == "active"
    assert row["role"] == "member"
    assert row["left_at"] == nil
    assert row["joined_at"] != nil

    meta = channel_row(cid)
    assert meta["membership_version"] == 2
    assert meta["member_count"] == 4

    # event plan: member.joined + system.notice, both at mv 2
    [joined, notice] = events(cid)

    assert joined["event_type"] == "member.joined"
    assert joined["actor_kind"] == "user"
    assert joined["actor_id"] == @admin
    assert joined["membership_version_at_event"] == 2

    jp = joined["payload"]
    assert jp["channel_id"] == cid
    assert jp["user_id"] == @stranger
    assert jp["role"] == "member"
    assert jp["membership_version"] == 2
    assert jp["actor_kind"] == "user"
    assert jp["actor_id"] == @admin
    assert jp["join_source"] == "admin_add"
    assert jp["inviter_user_id"] == nil

    assert notice["event_type"] == "system.notice"
    assert notice["actor_kind"] == "user"
    assert notice["actor_id"] == @admin
    assert notice["membership_version_at_event"] == 2
    assert notice["payload"]["notice_kind"] == "member.joined"
    assert notice["payload"]["actor_user_id"] == @admin
    assert notice["payload"]["target_user_id"] == @stranger
    assert notice["payload"]["message_id"] == nil
    assert notice["payload"]["channel_changes"] == nil

    # live frames (in event_id order) with resolved actor / user
    [joined_frame, notice_frame] = Task.await(channel_topic, 5_000)

    assert joined_frame["frame_type"] == "event"
    assert joined_frame["type"] == "member.joined"
    assert joined_frame["event_id"] == joined["event_id"]
    assert joined_frame["membership_version_at_event"] == 2
    assert joined_frame["payload"]["channel_id"] == cid

    assert joined_frame["payload"]["user"] == %{
             "user_id" => @stranger,
             "display_name" => "Stranger",
             "avatar_url" => nil
           }

    assert joined_frame["payload"]["actor"] == %{
             "user_id" => @admin,
             "display_name" => "The Admin",
             "avatar_url" => nil
           }

    assert joined_frame["payload"]["role"] == "member"
    assert joined_frame["payload"]["join_source"] == "admin_add"
    refute Map.has_key?(joined_frame["payload"], "inviter")

    assert notice_frame["type"] == "system.notice"
    assert notice_frame["event_id"] == notice["event_id"]
    assert notice_frame["payload"]["notice_kind"] == "member.joined"
    assert notice_frame["payload"]["actor"]["user_id"] == @admin
    assert notice_frame["payload"]["target_user"]["user_id"] == @stranger
    assert notice_frame["payload"]["message_id"] == nil
    assert notice_frame["payload"]["channel_changes"] == nil

    # D8: channel_joined hint to the ADDED user only — never the caller
    hint = %{
      "frame_type" => "user_event",
      "event" => "my_channels_changed",
      "reason" => "channel_joined",
      "changed_channel_id" => cid
    }

    assert Task.await(target_topic, 5_000) == [hint]
    assert Task.await(caller_topic, 5_000) == []

    # idempotency row recorded in the same txn
    [idem] = idem_rows("members.add") |> Enum.filter(&(&1["operation_id"] == "key-a1"))
    assert idem["principal_id"] == @admin
    assert idem["response_json"]["member"]["user_id"] == @stranger
  end

  test "add → missing role defaults to member; same-role re-add is a no-op; different role 422" do
    cid = seeded_channel()

    # route-layer parity: missing role → "member" (old Worker `?? "member"`)
    {:ok, response} =
      Channel.add_member(@admin, "key-a2", cid, %{"user_id" => @spare})

    assert response["member"]["role"] == "member"
    assert member_row(cid, @spare)["role"] == "member"
    assert events(cid) |> length() == 2

    # idempotent re-add (NEW key, same body): response WITHOUT joined_at,
    # no new events, no state change
    before_meta = channel_row(cid)

    {:ok, r2} = Channel.add_member(@admin, "key-a2b", cid, %{"user_id" => @spare})
    assert r2["member"]["channel_id"] == cid
    assert r2["member"]["user_id"] == @spare
    assert r2["member"]["role"] == "member"
    refute Map.has_key?(r2["member"], "joined_at")
    assert events(cid) |> length() == 2
    assert channel_row(cid) == before_meta

    # the re-add response is recorded for THIS key and replays
    {:ok, r3} = Channel.add_member(@admin, "key-a2b", cid, %{"user_id" => @spare})
    assert r3 == r2

    # adding an active member with a DIFFERENT role must not mutate the role
    assert {:error, %Errors.ApiError{code: "INVALID_MESSAGE", http_status: 422}} =
             Channel.add_member(@admin, "key-a2c", cid, %{"user_id" => @spare, "role" => "admin"})

    assert member_row(cid, @spare)["role"] == "member"
  end

  test "add of a left member reactivates (role reset, left_at cleared, count +1, event + hint)" do
    cid = seeded_channel()
    left = DateTime.utc_now()

    seed_membership(cid, @stranger, "member", left_at: left, status: "left")
    assert channel_row(cid)["member_count"] == 3
    assert channel_row(cid)["membership_version"] == 1

    target_topic = subscribe("user:" <> @stranger)
    assert_receive {:sub_ready, _}, 2_000
    send(target_topic.pid, :go)

    {:ok, response} =
      Channel.add_member(@owner, "key-a3", cid, %{"user_id" => @stranger, "role" => "admin"})

    assert response["member"]["role"] == "admin"
    assert is_binary(response["member"]["joined_at"])

    row = member_row(cid, @stranger)
    assert row["status"] == "active"
    assert row["role"] == "admin"
    assert row["left_at"] == nil
    assert row["joined_at"] != left

    meta = channel_row(cid)
    assert meta["membership_version"] == 2
    assert meta["member_count"] == 4

    [joined, notice] = events(cid)
    assert joined["event_type"] == "member.joined"
    assert joined["payload"]["role"] == "admin"
    assert joined["payload"]["membership_version"] == 2
    assert notice["payload"]["notice_kind"] == "member.joined"

    hint = %{
      "frame_type" => "user_event",
      "event" => "my_channels_changed",
      "reason" => "channel_joined",
      "changed_channel_id" => cid
    }

    assert Task.await(target_topic, 5_000) == [hint]
  end

  test "add gates: 404 / DM / dissolved / non-owner-admin / bad role / self / owner fixed" do
    missing = "ch-none-" <> Ecto.UUID.generate()

    assert {:error, %Errors.ApiError{code: "CHANNEL_NOT_FOUND", http_status: 404}} =
             Channel.add_member(@owner, "key-g1", missing, %{"user_id" => @member})

    dm = "ch-dm-" <> Ecto.UUID.generate()
    seed_channel(dm, kind: "dm", created_by: @owner)
    seed_membership(dm, @owner, "owner")

    assert {:error, %Errors.ApiError{code: "UNSUPPORTED_CHANNEL_KIND", http_status: 409}} =
             Channel.add_member(@owner, "key-g2", dm, %{"user_id" => @member})

    dissolved = "ch-dis-" <> Ecto.UUID.generate()
    seed_channel(dissolved, status: "dissolved", created_by: @owner)
    seed_membership(dissolved, @owner, "owner")

    assert {:error, %Errors.ApiError{code: "CHANNEL_DISSOLVED", http_status: 409}} =
             Channel.add_member(@owner, "key-g3", dissolved, %{"user_id" => @member})

    cid = seeded_channel()

    # a plain member (neither owner nor admin) cannot add
    assert {:error, %Errors.ApiError{code: "FORBIDDEN", http_status: 403}} =
             Channel.add_member(@member, "key-g4", cid, %{"user_id" => @stranger})

    # a non-member caller cannot add either
    assert {:error, %Errors.ApiError{code: "FORBIDDEN", http_status: 403}} =
             Channel.add_member(@stranger, "key-g4b", cid, %{"user_id" => @spare})

    # owner role is not add-able (only member/admin)
    assert {:error, %Errors.ApiError{code: "INVALID_MESSAGE", http_status: 422}} =
             Channel.add_member(@owner, "key-g5", cid, %{
               "user_id" => @stranger,
               "role" => "owner"
             })

    assert {:error, %Errors.ApiError{code: "INVALID_MESSAGE", http_status: 422}} =
             Channel.add_member(@owner, "key-g6", cid, %{"user_id" => @owner})

    # the owner is fixed: the creator cannot be re-added
    assert {:error, %Errors.ApiError{code: "INVALID_MESSAGE", http_status: 422}} =
             Channel.add_member(@owner, "key-g7", cid, %{"user_id" => @owner, "role" => "member"})
  end

  test "add idempotency: same key replays; different body conflicts" do
    cid = seeded_channel()

    body = %{"user_id" => @stranger, "role" => "member"}
    {:ok, r1} = Channel.add_member(@admin, "key-idem-a", cid, body)
    {:ok, r2} = Channel.add_member(@admin, "key-idem-a", cid, body)
    assert r1 == r2
    assert length(members(cid)) == 4

    [idem] = idem_rows("members.add") |> Enum.filter(&(&1["operation_id"] == "key-idem-a"))
    assert idem["principal_id"] == @admin

    {:error, %Errors.ApiError{code: "IDEMPOTENCY_CONFLICT"}} =
      Channel.add_member(@admin, "key-idem-a", cid, %{"user_id" => @spare, "role" => "member"})
  end

  # ------------------------------------------------------------- role (§7.3)

  test "role update → member.role_updated + notice, mv+1, count unchanged, NO hint (D8)" do
    cid = seeded_channel()

    channel_topic = subscribe("channel:" <> cid)
    target_topic = subscribe("user:" <> @member)
    assert_receive {:sub_ready, _}, 2_000
    assert_receive {:sub_ready, _}, 2_000
    Enum.each([channel_topic, target_topic], fn task -> send(task.pid, :go) end)

    {:ok, response} =
      Channel.update_member_role(@owner, "key-r1", cid, @member, %{"role" => "admin"})

    assert response == %{
             "member" => %{"channel_id" => cid, "user_id" => @member, "role" => "admin"}
           }

    assert member_row(cid, @member)["role"] == "admin"

    meta = channel_row(cid)
    assert meta["membership_version"] == 2
    assert meta["member_count"] == 3

    [updated, notice] = events(cid)

    assert updated["event_type"] == "member.role_updated"
    assert updated["actor_kind"] == "user"
    assert updated["actor_id"] == @owner
    assert updated["membership_version_at_event"] == 2

    assert updated["payload"] == %{
             "channel_id" => cid,
             "user_id" => @member,
             "before_role" => "member",
             "after_role" => "admin",
             "membership_version" => 2,
             "actor_kind" => "user",
             "actor_id" => @owner
           }

    assert notice["event_type"] == "system.notice"
    assert notice["payload"]["notice_kind"] == "member.role_updated"
    assert notice["payload"]["actor_user_id"] == @owner
    assert notice["payload"]["target_user_id"] == @member

    [updated_frame, notice_frame] = Task.await(channel_topic, 5_000)

    assert updated_frame["type"] == "member.role_updated"
    assert updated_frame["event_id"] == updated["event_id"]
    assert updated_frame["payload"]["before_role"] == "member"
    assert updated_frame["payload"]["after_role"] == "admin"
    assert updated_frame["payload"]["user"]["display_name"] == "The Member"
    assert updated_frame["payload"]["actor"]["display_name"] == "The Owner"

    assert notice_frame["type"] == "system.notice"
    assert notice_frame["payload"]["target_user"]["user_id"] == @member

    # D8: role change is NOT in the my_channels_changed trigger set
    assert Task.await(target_topic, 5_000) == []

    [idem] = idem_rows("members.role") |> Enum.filter(&(&1["operation_id"] == "key-r1"))
    assert idem["principal_id"] == @owner
  end

  test "role gates: non-owner / bad role / missing role / not active / owner fixed / self" do
    cid = seeded_channel()

    # only the owner may change roles (an admin cannot)
    assert {:error, %Errors.ApiError{code: "FORBIDDEN", http_status: 403}} =
             Channel.update_member_role(@admin, "key-r2", cid, @member, %{"role" => "admin"})

    assert {:error, %Errors.ApiError{code: "INVALID_MESSAGE", http_status: 422}} =
             Channel.update_member_role(@owner, "key-r3", cid, @member, %{"role" => "owner"})

    # route parity: a missing role normalizes to "" and 422s
    assert {:error, %Errors.ApiError{code: "INVALID_MESSAGE", http_status: 422}} =
             Channel.update_member_role(@owner, "key-r4", cid, @member, %{})

    # never-joined and left members are not active targets
    assert {:error, %Errors.ApiError{code: "MEMBER_NOT_FOUND", http_status: 404}} =
             Channel.update_member_role(@owner, "key-r5", cid, @stranger, %{"role" => "admin"})

    left = DateTime.utc_now()
    seed_membership(cid, @spare, "member", left_at: left, status: "left")

    assert {:error, %Errors.ApiError{code: "MEMBER_NOT_FOUND", http_status: 404}} =
             Channel.update_member_role(@owner, "key-r6", cid, @spare, %{"role" => "admin"})

    # the owner's role is fixed; the owner cannot change own role
    assert {:error, %Errors.ApiError{code: "INVALID_MESSAGE", http_status: 422}} =
             Channel.update_member_role(@owner, "key-r7", cid, @owner, %{"role" => "admin"})

    assert {:error, %Errors.ApiError{code: "INVALID_MESSAGE", http_status: 422}} =
             Channel.update_member_role(@owner, "key-r8", cid, @owner, %{"role" => "member"})

    # no state changed by the failed gates
    assert member_row(cid, @member)["role"] == "member"
    assert channel_row(cid)["membership_version"] == 1
    assert events(cid) == []
  end

  test "role idempotency: same key replays; different body conflicts" do
    cid = seeded_channel()

    {:ok, r1} =
      Channel.update_member_role(@owner, "key-idem-r", cid, @member, %{"role" => "admin"})

    {:ok, r2} =
      Channel.update_member_role(@owner, "key-idem-r", cid, @member, %{"role" => "admin"})

    assert r1 == r2
    assert member_row(cid, @member)["role"] == "admin"

    {:error, %Errors.ApiError{code: "IDEMPOTENCY_CONFLICT"}} =
      Channel.update_member_role(@owner, "key-idem-r", cid, @member, %{"role" => "member"})
  end

  # ---------------------------------------------------------- remove (§7.4)

  test "owner remove → member.left (removed), mv+1, count-1, channel_left hint to the target" do
    cid = seeded_channel()

    channel_topic = subscribe("channel:" <> cid)
    target_topic = subscribe("user:" <> @member)
    assert_receive {:sub_ready, _}, 2_000
    assert_receive {:sub_ready, _}, 2_000
    Enum.each([channel_topic, target_topic], fn task -> send(task.pid, :go) end)

    {:ok, response} = Channel.remove_member(@owner, "key-m1", cid, @member)

    assert response == %{"channel_id" => cid, "user_id" => @member, "removed" => true}

    row = member_row(cid, @member)
    assert row["status"] == "left"
    assert row["left_at"] != nil
    assert row["role"] == "member"

    meta = channel_row(cid)
    assert meta["membership_version"] == 2
    assert meta["member_count"] == 2

    [left, notice] = events(cid)

    assert left["event_type"] == "member.left"
    assert left["actor_kind"] == "user"
    assert left["actor_id"] == @owner
    assert left["membership_version_at_event"] == 2

    assert left["payload"]["channel_id"] == cid
    assert left["payload"]["user_id"] == @member
    assert left["payload"]["role"] == "member"
    assert left["payload"]["membership_version"] == 2
    assert left["payload"]["leave_source"] == "removed"
    assert left["payload"]["actor_kind"] == "user"
    assert left["payload"]["actor_id"] == @owner

    assert notice["event_type"] == "system.notice"
    assert notice["payload"]["notice_kind"] == "member.left"
    assert notice["payload"]["target_user_id"] == @member

    [left_frame, notice_frame] = Task.await(channel_topic, 5_000)

    assert left_frame["type"] == "member.left"
    assert left_frame["event_id"] == left["event_id"]
    assert left_frame["payload"]["leave_source"] == "removed"
    assert left_frame["payload"]["user"]["user_id"] == @member
    assert left_frame["payload"]["actor"]["user_id"] == @owner

    assert notice_frame["type"] == "system.notice"
    assert notice_frame["payload"]["target_user"]["user_id"] == @member

    hint = %{
      "frame_type" => "user_event",
      "event" => "my_channels_changed",
      "reason" => "channel_left",
      "changed_channel_id" => cid
    }

    assert Task.await(target_topic, 5_000) == [hint]
  end

  test "self-leave → member.left (self); owner self-leave 422; dissolved self-leave allowed" do
    cid = seeded_channel()

    # a plain member can leave by themselves
    {:ok, response} = Channel.remove_member(@member, "key-m2", cid, @member)
    assert response["removed"] == true
    assert member_row(cid, @member)["status"] == "left"

    [left, _notice] = events(cid)
    assert left["payload"]["leave_source"] == "self"
    assert left["actor_id"] == @member

    # the owner may NOT leave (dissolve or transfer first)
    assert {:error, %Errors.ApiError{code: "INVALID_MESSAGE", http_status: 422}} =
             Channel.remove_member(@owner, "key-m3", cid, @owner)

    assert member_row(cid, @owner)["status"] == "active"

    # a self-leave is still allowed on a DISSOLVED channel
    dissolved = "ch-dis2-" <> Ecto.UUID.generate()
    seed_channel(dissolved, status: "dissolved", created_by: @owner)
    seed_membership(dissolved, @owner, "owner")
    seed_membership(dissolved, @member, "member")

    {:ok, r2} = Channel.remove_member(@member, "key-m4", dissolved, @member)
    assert r2["removed"] == true
    assert member_row(dissolved, @member)["status"] == "left"

    # old Worker parity (P1-6): the owner-must-dissolve-or-transfer rule
    # applies to ACTIVE channels only — the OWNER may self-leave a
    # DISSOLVED one.
    dissolved2 = "ch-dis5-" <> Ecto.UUID.generate()
    seed_channel(dissolved2, status: "dissolved", created_by: @owner)
    seed_membership(dissolved2, @owner, "owner")
    seed_profile(@owner, "The Owner", nil)

    {:ok, r3} = Channel.remove_member(@owner, "key-m5", dissolved2, @owner)
    assert r3["removed"] == true
    assert member_row(dissolved2, @owner)["status"] == "left"

    [left_evt] =
      events(dissolved2)
      |> Enum.reject(&(&1["event_type"] == "system.notice"))

    assert left_evt["event_type"] == "member.left"
    assert left_evt["payload"]["leave_source"] == "self"
    assert left_evt["membership_version_at_event"] == 2
  end

  test "remove gates: dissolved other / non-owner other / not active / 404" do
    dissolved = "ch-dis3-" <> Ecto.UUID.generate()
    seed_channel(dissolved, status: "dissolved", created_by: @owner)
    seed_membership(dissolved, @owner, "owner")
    seed_membership(dissolved, @member, "member")

    # removing ANOTHER user on a dissolved channel → 409 (self-leave is OK)
    assert {:error, %Errors.ApiError{code: "CHANNEL_DISSOLVED", http_status: 409}} =
             Channel.remove_member(@owner, "key-g9", dissolved, @member)

    cid = seeded_channel()

    # on an active channel only the owner may remove others
    assert {:error, %Errors.ApiError{code: "FORBIDDEN", http_status: 403}} =
             Channel.remove_member(@admin, "key-g10", cid, @member)

    # a non-member cannot remove others either
    assert {:error, %Errors.ApiError{code: "FORBIDDEN", http_status: 403}} =
             Channel.remove_member(@stranger, "key-g11", cid, @member)

    # never-joined target
    assert {:error, %Errors.ApiError{code: "MEMBER_NOT_FOUND", http_status: 404}} =
             Channel.remove_member(@owner, "key-g12", cid, @stranger)

    # an already-left target is not active
    left = DateTime.utc_now()
    seed_membership(cid, @spare, "member", left_at: left, status: "left")

    assert {:error, %Errors.ApiError{code: "MEMBER_NOT_FOUND", http_status: 404}} =
             Channel.remove_member(@owner, "key-g13", cid, @spare)

    # a second remove of the same (now left) member → 404
    Channel.remove_member(@owner, "key-g14", cid, @member)

    assert {:error, %Errors.ApiError{code: "MEMBER_NOT_FOUND", http_status: 404}} =
             Channel.remove_member(@owner, "key-g15", cid, @member)
  end

  test "remove idempotency: same key replays; different body conflicts" do
    cid = seeded_channel()

    {:ok, r1} = Channel.remove_member(@owner, "key-idem-m", cid, @member)
    {:ok, r2} = Channel.remove_member(@owner, "key-idem-m", cid, @member)
    assert r1 == r2
    assert member_row(cid, @member)["status"] == "left"

    {:error, %Errors.ApiError{code: "IDEMPOTENCY_CONFLICT"}} =
      Channel.remove_member(@owner, "key-idem-m", cid, @admin)
  end

  # -------------------------------------------------------- transfer (§7.5)

  test "owner transfer → single txn: single-owner invariant, mv+2, four events, no hints" do
    cid = seeded_channel()

    channel_topic = subscribe("channel:" <> cid)
    assert_receive {:sub_ready, _}, 2_000
    send(channel_topic.pid, :go)

    {:ok, response} =
      Channel.transfer_owner(@owner, "key-t1", cid, %{
        "target_user_id" => @member,
        "previous_owner_role" => "admin"
      })

    assert response == %{
             "channel_id" => cid,
             "previous_owner" => %{"user_id" => @owner, "role" => "admin"},
             "new_owner" => %{"user_id" => @member, "role" => "owner"}
           }

    # row effects: created_by handed over, mv +2
    meta = channel_row(cid)
    assert meta["created_by"] == @member
    assert meta["membership_version"] == 3
    assert meta["member_count"] == 3

    assert member_row(cid, @owner)["role"] == "admin"
    assert member_row(cid, @member)["role"] == "owner"

    # exactly ONE active owner after the transfer (single-owner invariant)
    owners =
      members(cid)
      |> Enum.filter(&(&1["status"] == "active" and &1["role"] == "owner"))

    assert [owner_row] = owners
    assert owner_row["user_id"] == @member

    # event plan: role_updated(old owner, mv 2) + notice, role_updated(new owner, mv 3) + notice
    [old_updated, old_notice, new_updated, new_notice] = events(cid)

    assert Enum.map(events(cid), & &1["event_type"]) ==
             ["member.role_updated", "system.notice", "member.role_updated", "system.notice"]

    assert old_updated["payload"] == %{
             "channel_id" => cid,
             "user_id" => @owner,
             "before_role" => "owner",
             "after_role" => "admin",
             "membership_version" => 2,
             "actor_kind" => "user",
             "actor_id" => @owner
           }

    assert old_updated["membership_version_at_event"] == 2
    assert old_notice["payload"]["notice_kind"] == "member.role_updated"
    assert old_notice["payload"]["target_user_id"] == @owner
    assert old_notice["membership_version_at_event"] == 2

    assert new_updated["payload"] == %{
             "channel_id" => cid,
             "user_id" => @member,
             "before_role" => "member",
             "after_role" => "owner",
             "membership_version" => 3,
             "actor_kind" => "user",
             "actor_id" => @owner
           }

    assert new_updated["membership_version_at_event"] == 3
    assert new_notice["payload"]["target_user_id"] == @member
    assert new_notice["membership_version_at_event"] == 3

    # live frames: four, in event order, actor resolved on all
    frames = Task.await(channel_topic, 5_000)
    assert length(frames) == 4

    assert Enum.map(frames, & &1["type"]) ==
             ["member.role_updated", "system.notice", "member.role_updated", "system.notice"]

    Enum.each(frames, fn frame ->
      payload = frame["payload"]

      assert payload["actor"] == %{
               "user_id" => @owner,
               "display_name" => "The Owner",
               "avatar_url" => nil
             }
    end)

    assert frames |> Enum.at(0) |> then(& &1["payload"]["user"]["user_id"]) == @owner
    assert frames |> Enum.at(2) |> then(& &1["payload"]["user"]["user_id"]) == @member
    assert frames |> Enum.at(1) |> then(& &1["payload"]["target_user"]["user_id"]) == @owner
    assert frames |> Enum.at(3) |> then(& &1["payload"]["target_user"]["user_id"]) == @member

    # D8: the transfer is two role changes → no my_channels_changed anywhere
    owner_topic = subscribe("user:" <> @owner)
    member_topic = subscribe("user:" <> @member)
    assert_receive {:sub_ready, _}, 2_000
    assert_receive {:sub_ready, _}, 2_000
    Enum.each([owner_topic, member_topic], fn task -> send(task.pid, :go) end)

    {:ok, r2} =
      Channel.transfer_owner(@member, "key-t2", cid, %{
        "target_user_id" => @admin,
        "previous_owner_role" => "member"
      })

    assert r2["new_owner"]["user_id"] == @admin
    assert Task.await(owner_topic, 5_000) == []
    assert Task.await(member_topic, 5_000) == []

    [idem] = idem_rows("channel.owner_transfer") |> Enum.filter(&(&1["operation_id"] == "key-t1"))
    assert idem["principal_id"] == @owner
  end

  test "transfer gates: non-owner / created_by mismatch / dissolved / bad prev / target" do
    missing = "ch-none3-" <> Ecto.UUID.generate()

    assert {:error, %Errors.ApiError{code: "CHANNEL_NOT_FOUND", http_status: 404}} =
             Channel.transfer_owner(@owner, "key-t3", missing, %{
               "target_user_id" => @member,
               "previous_owner_role" => "admin"
             })

    dm = "ch-dm3-" <> Ecto.UUID.generate()
    seed_channel(dm, kind: "dm", created_by: @owner)
    seed_membership(dm, @owner, "owner")

    assert {:error, %Errors.ApiError{code: "UNSUPPORTED_CHANNEL_KIND", http_status: 409}} =
             Channel.transfer_owner(@owner, "key-t4", dm, %{
               "target_user_id" => @member,
               "previous_owner_role" => "admin"
             })

    dissolved = "ch-dis4-" <> Ecto.UUID.generate()
    seed_channel(dissolved, status: "dissolved", created_by: @owner)
    seed_membership(dissolved, @owner, "owner")

    assert {:error, %Errors.ApiError{code: "CHANNEL_DISSOLVED", http_status: 409}} =
             Channel.transfer_owner(@owner, "key-t5", dissolved, %{
               "target_user_id" => @member,
               "previous_owner_role" => "admin"
             })

    cid = seeded_channel()
    body = %{"target_user_id" => @member, "previous_owner_role" => "admin"}

    # an admin caller is not the owner
    assert {:error, %Errors.ApiError{code: "FORBIDDEN", http_status: 403}} =
             Channel.transfer_owner(@admin, "key-t6", cid, body)

    # role alone is not enough: created_by must match the caller
    odd = "ch-odd-" <> Ecto.UUID.generate()
    seed_channel(odd, created_by: @admin)
    seed_membership(odd, @owner, "owner")
    seed_membership(odd, @admin, "owner")
    seed_membership(odd, @member, "member")

    assert {:error, %Errors.ApiError{code: "FORBIDDEN", http_status: 403}} =
             Channel.transfer_owner(@owner, "key-t7", odd, body)

    # previous_owner_role must be admin|member (route parity: missing → "")
    assert {:error, %Errors.ApiError{code: "INVALID_MESSAGE", http_status: 422}} =
             Channel.transfer_owner(@owner, "key-t8", cid, %{
               "target_user_id" => @member,
               "previous_owner_role" => "owner"
             })

    assert {:error, %Errors.ApiError{code: "INVALID_MESSAGE", http_status: 422}} =
             Channel.transfer_owner(@owner, "key-t9", cid, %{"target_user_id" => @member})

    # target must be an active member
    assert {:error, %Errors.ApiError{code: "MEMBER_NOT_FOUND", http_status: 404}} =
             Channel.transfer_owner(@owner, "key-t10", cid, %{
               "target_user_id" => @stranger,
               "previous_owner_role" => "admin"
             })

    # transferring to the current owner (creator) is redundant
    assert {:error, %Errors.ApiError{code: "INVALID_MEMBER_ROLE", http_status: 422}} =
             Channel.transfer_owner(@owner, "key-t11", cid, %{
               "target_user_id" => @owner,
               "previous_owner_role" => "admin"
             })

    # state untouched by the failed gates
    assert channel_row(cid)["membership_version"] == 1
    assert events(cid) == []
  end

  test "transfer idempotency: same key replays; different body conflicts" do
    cid = seeded_channel()

    body = %{"target_user_id" => @member, "previous_owner_role" => "admin"}
    {:ok, r1} = Channel.transfer_owner(@owner, "key-idem-t", cid, body)
    {:ok, r2} = Channel.transfer_owner(@owner, "key-idem-t", cid, body)
    assert r1 == r2
    assert channel_row(cid)["created_by"] == @member

    # a new transfer from the NEW owner with a DIFFERENT body under the same
    # key (principal @owner) conflicts on the request hash
    {:error, %Errors.ApiError{code: "IDEMPOTENCY_CONFLICT"}} =
      Channel.transfer_owner(@owner, "key-idem-t", cid, %{
        "target_user_id" => @admin,
        "previous_owner_role" => "member"
      })
  end

  # ------------------------------------------------------------ replay parity

  test "timeline replay re-projects member events (live == replay builders)" do
    cid = "ch-replay-" <> Ecto.UUID.generate()
    seed_channel(cid, title: "Replay", visibility: "public_unlisted", created_by: @owner)
    seed_membership(cid, @owner, "owner")
    seed_membership(cid, @admin, "admin")
    seed_membership(cid, @member, "member")
    seed_profile(@owner, "The Owner", nil)
    seed_profile(@admin, "The Admin", nil)
    seed_profile(@member, "The Member", nil)
    seed_profile(@stranger, "Stranger", nil)

    {:ok, _} =
      Channel.add_member(@owner, "key-replay-1", cid, %{
        "user_id" => @stranger,
        "role" => "member"
      })

    {:ok, _} =
      Channel.update_member_role(@owner, "key-replay-2", cid, @stranger, %{"role" => "admin"})

    {:ok, _} = Channel.remove_member(@owner, "key-replay-3", cid, @stranger)

    {:ok, _} =
      Channel.transfer_owner(@owner, "key-replay-4", cid, %{
        "target_user_id" => @admin,
        "previous_owner_role" => "member"
      })

    # Gap-recovery replay (`GET .../events`, §6.1b) re-projects every member
    # event type + the §10.4 notices, mirroring the live broadcast builders.
    %{events: items} = Timeline.channel_events(@owner, cid, nil, 100)

    by_type = Enum.group_by(items, &Map.fetch!(&1, "type"))

    [joined] = by_type["member.joined"]
    assert joined["payload"]["user"]["user_id"] == @stranger
    assert joined["payload"]["user"]["display_name"] == "Stranger"
    assert joined["payload"]["actor"]["user_id"] == @owner
    assert joined["payload"]["join_source"] == "admin_add"
    refute Map.has_key?(joined["payload"], "inviter")

    [left] = by_type["member.left"]
    assert left["payload"]["user"]["user_id"] == @stranger
    assert left["payload"]["leave_source"] == "removed"
    assert left["payload"]["actor"]["display_name"] == "The Owner"
    assert left["payload"]["role"] == "admin"

    role_updated = by_type["member.role_updated"]
    assert length(role_updated) == 3

    # the first is the plain role change; the last two belong to the transfer
    [role_change | _] = role_updated
    assert role_change["payload"]["before_role"] == "member"
    assert role_change["payload"]["after_role"] == "admin"
    assert role_change["payload"]["user"]["user_id"] == @stranger

    [second_last, last] = Enum.take(role_updated, -2)
    assert second_last["payload"]["user"]["user_id"] == @owner
    assert second_last["payload"]["before_role"] == "owner"
    assert second_last["payload"]["after_role"] == "member"
    assert last["payload"]["user"]["user_id"] == @admin
    assert last["payload"]["before_role"] == "admin"
    assert last["payload"]["after_role"] == "owner"

    notices = by_type["system.notice"]
    assert length(notices) == 5

    kinds = notices |> Enum.map(& &1["payload"]["notice_kind"])

    assert kinds ==
             [
               "member.joined",
               "member.role_updated",
               "member.left",
               "member.role_updated",
               "member.role_updated"
             ]

    Enum.each(notices, fn frame ->
      payload = frame["payload"]
      assert payload["actor"]["user_id"] == @owner
      assert payload["target_user"] != nil
      assert payload["message_id"] == nil
      assert payload["channel_changes"] == nil
    end)
  end
end
