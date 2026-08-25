defmodule LiliumChat.ChannelLifecycleTest do
  @moduledoc """
  Channel lifecycle write-path tests (issue #11, contract §5.2b / §5.3 /
  §5.4): `channel.create` / `channel.update` / `channel.dissolve` driven
  through `LiliumChat.Channel` (the per-channel writer, D13).

  Covers: response shapes, row effects, event payloads + membership_version
  schedule, idempotency (replay / conflict), gates, the
  `my_channels_changed` trigger set (D8: join / leave / dissolve — NOT role
  change, NOT update), the v2 `system.notice` additions, and replay
  re-projection of the new event types.

  Issue #25 adds the dissolve lifecycle decisions: the role-based owner
  gate (contract §5.4 SoT, supersedes the old Worker's `created_by` gate,
  interacts with #12 owner transfer) and the pins / read_state retention
  (tombstone stays readable).
  """

  use LiliumChat.DataCase, async: false

  import LiliumChatWeb.ReadFixtures

  alias LiliumChat.{Bootstrap, Channel, ChannelPins, Errors, Query, Repo, Timeline}

  @uid "6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e6f"
  @other "7a2f3d4e-5b6c-8d9e-0f1a-2b3c4d5e6f70"
  @third "8b3e4e5f-6c7d-9e0f-1a2b-3c4d5e6f7081"

  # ----------------------------------------------------------------- helpers

  defp channel_row(channel_id) do
    Query.rows(
      Repo.query(
        "SELECT channel_id, kind, visibility, title, topic, avatar_url, status, created_by, " <>
          "created_at, updated_at, member_count, membership_version " <>
          "FROM chat_v2.channels WHERE channel_id = $1",
        [channel_id],
        type: true
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

  # Subscribes a helper task to a PubSub topic. The task reports readiness
  # (`{:sub_ready, topic}`), then starts collecting on `:go` and resolves to
  # the list of broadcast frames received (quiescence-based: collects until a
  # 500ms quiet window — broadcasts of one command arrive in a tight cluster).
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

  defp iso(value), do: LiliumChat.Projections.format_ts(value)

  # --------------------------------------------------------------- create

  test "create → 201 body, rows, mv/member_count, event payloads" do
    seed_profile(@uid, "Creator", nil)

    {:ok, response} =
      Channel.create(@uid, "key-c1", %{
        "title" => "  General ",
        "topic" => "chit-chat",
        "visibility" => "public_unlisted"
      })

    # response shape (§5.2b)
    ch = response["channel"]
    assert ch["kind"] == "channel"
    assert ch["visibility"] == "public_unlisted"
    assert ch["title"] == "General"
    assert ch["topic"] == "chit-chat"
    assert ch["avatar_url"] == nil
    assert ch["member_count"] == 1
    assert ch["status"] == "active"
    assert ch["created_at"] == ch["updated_at"]
    assert response["membership"] == %{"role" => "owner", "joined_at" => ch["created_at"]}

    cid = ch["channel_id"]

    # stored rows
    meta = channel_row(cid)
    assert meta["kind"] == "channel"
    assert meta["created_by"] == @uid
    assert meta["status"] == "active"
    assert meta["member_count"] == 1
    assert meta["membership_version"] == 1

    [owner] = members(cid)
    assert owner["user_id"] == @uid
    assert owner["role"] == "owner"
    assert owner["status"] == "active"
    assert owner["left_at"] == nil

    # event plan: created → member.joined (owner) → system.notice
    [created, joined, notice] = events(cid)
    assert created["event_type"] == "channel.created"
    assert created["actor_kind"] == "user"
    assert created["actor_id"] == @uid
    assert created["membership_version_at_event"] == 1

    assert joined["event_type"] == "member.joined"
    assert joined["actor_kind"] == "system"
    assert joined["actor_id"] == "system"
    assert joined["membership_version_at_event"] == 1

    assert notice["event_type"] == "system.notice"
    assert notice["actor_kind"] == "user"
    assert notice["actor_id"] == @uid
    assert notice["membership_version_at_event"] == 1

    # stored payloads keep reference fields (replay re-projects the actor)
    p = created["payload"]
    assert p["channel"]["channel_id"] == cid
    assert p["channel"]["kind"] == "channel"
    assert p["channel"]["visibility"] == "public_unlisted"
    assert p["channel"]["title"] == "General"
    assert p["actor_kind"] == "user"
    assert p["actor_id"] == @uid

    jp = joined["payload"]
    assert jp["user_id"] == @uid
    assert jp["role"] == "owner"
    assert jp["membership_version"] == 1
    assert jp["actor_kind"] == "system"
    assert jp["actor_id"] == "system"
    assert jp["join_source"] == nil
    assert jp["inviter_user_id"] == nil

    np = notice["payload"]
    assert np["notice_kind"] == "channel.created"
    assert np["actor_user_id"] == @uid
    assert np["target_user_id"] == nil
    assert np["message_id"] == nil
    assert np["channel_changes"] == nil

    # idempotency row recorded in the same txn (response_json is JSONB → map)
    [idem] = idem_rows("channel.create") |> Enum.filter(&(&1["operation_id"] == "key-c1"))
    assert idem["principal_id"] == @uid
    body = idem["response_json"]
    assert body["channel"]["channel_id"] == cid
    assert body["membership"]["role"] == "owner"
  end

  test "create with initial_members → roles, mv schedule, member_count, user hints" do
    seed_profile(@other, "Other Person", nil)
    seed_profile(@third, "Third Person", nil)

    other_topic = subscribe("user:" <> @other)
    third_topic = subscribe("user:" <> @third)
    creator_topic = subscribe("user:" <> @uid)
    assert_receive {:sub_ready, _}, 2_000
    assert_receive {:sub_ready, _}, 2_000
    assert_receive {:sub_ready, _}, 2_000

    Enum.each([other_topic, third_topic, creator_topic], fn task -> send(task.pid, :go) end)

    body = %{
      "title" => "Launch",
      "initial_members" => [
        %{"user_id" => @other, "role" => "admin"},
        %{"user_id" => @third, "role" => "member"}
      ]
    }

    {:ok, response} = Channel.create(@uid, "key-c2", body)
    cid = response["channel"]["channel_id"]

    assert response["channel"]["member_count"] == 3

    meta = channel_row(cid)
    assert meta["membership_version"] == 3
    assert meta["member_count"] == 3

    by_user = members(cid) |> Enum.into(%{}, &{&1["user_id"], &1["role"]})
    assert by_user == %{@uid => "owner", @other => "admin", @third => "member"}

    # mv schedule: 1 (owner) → 2 (im[0]) → 3 (im[1]); notice at final mv
    [created, owner_joined, other_joined, third_joined, notice] = events(cid)

    assert [created, owner_joined, other_joined, third_joined, notice]
           |> Enum.map(& &1["event_type"]) ==
             [
               "channel.created",
               "member.joined",
               "member.joined",
               "member.joined",
               "system.notice"
             ]

    assert owner_joined["membership_version_at_event"] == 1
    assert other_joined["membership_version_at_event"] == 2
    assert third_joined["membership_version_at_event"] == 3
    assert notice["membership_version_at_event"] == 3

    assert other_joined["payload"]["user_id"] == @other
    assert other_joined["payload"]["role"] == "admin"
    assert other_joined["payload"]["membership_version"] == 2

    # my_channels_changed to creator + every initial member (reason: joined)
    hint = fn id ->
      %{
        "frame_type" => "user_event",
        "event" => "my_channels_changed",
        "reason" => "channel_joined",
        "changed_channel_id" => id
      }
    end

    assert Task.await(other_topic, 5_000) == [hint.(cid)]
    assert Task.await(third_topic, 5_000) == [hint.(cid)]
    assert Task.await(creator_topic, 5_000) == [hint.(cid)]
  end

  test "create idempotency: same key + same body replays; different body → conflict" do
    body = %{
      "title" => "Dup",
      "initial_members" => [%{"user_id" => @other, "role" => "member"}]
    }

    {:ok, r1} = Channel.create(@uid, "key-idem", body)
    {:ok, r2} = Channel.create(@uid, "key-idem", body)

    assert r1 == r2
    cid = r1["channel"]["channel_id"]

    # exactly one channel + the expected member set was created
    assert channel_row(cid) != nil
    assert length(members(cid)) == 2

    # only ONE idempotency row for this key
    [idem] = idem_rows("channel.create") |> Enum.filter(&(&1["operation_id"] == "key-idem"))
    assert idem["principal_id"] == @uid

    {:error, %Errors.ApiError{code: "IDEMPOTENCY_CONFLICT"}} =
      Channel.create(@uid, "key-idem", %{"title" => "Other"})
  end

  test "create validation → 422 INVALID_MESSAGE for each invalid body" do
    cases = %{
      "missing title" => %{"topic" => "no title"},
      "blank title" => %{"title" => "   "},
      "non-string title" => %{"title" => 42},
      "non-null avatar" => %{"title" => "T", "avatar_attachment_id" => "att-1"},
      "invalid visibility" => %{"title" => "T", "visibility" => "public"},
      "non-string visibility" => %{"title" => "T", "visibility" => 5},
      "non-string topic" => %{"title" => "T", "topic" => 42},
      "im role owner" => %{
        "title" => "T",
        "initial_members" => [%{"user_id" => @other, "role" => "owner"}]
      },
      "im role bot" => %{
        "title" => "T",
        "initial_members" => [%{"user_id" => @other, "role" => "bot"}]
      },
      "im is creator" => %{
        "title" => "T",
        "initial_members" => [%{"user_id" => @uid, "role" => "member"}]
      },
      "im user_id missing" => %{"title" => "T", "initial_members" => [%{"role" => "member"}]},
      "im not an object" => %{"title" => "T", "initial_members" => ["just-a-string"]}
    }

    n = 0

    for {label, body} <- cases do
      n = n + 1

      assert {:error, %Errors.ApiError{code: "INVALID_MESSAGE", http_status: 422}} =
               Channel.create(@uid, "key-v-#{n}", body),
             "expected 422 INVALID_MESSAGE for #{label}: #{inspect(body)}"
    end
  end

  # --------------------------------------------------------------- update

  test "update → row updated, channel.updated + system.notice, mv unchanged, live frames" do
    cid = "ch-upd-" <> Ecto.UUID.generate()

    seed_channel(cid,
      title: "Before",
      topic: "old-topic",
      visibility: "private",
      created_by: @uid
    )

    seed_membership(cid, @uid, "owner")
    seed_profile(@uid, "Creator", nil)

    before_updated_at = channel_row(cid)["updated_at"]

    channel_topic = subscribe("channel:" <> cid)
    user_topic = subscribe("user:" <> @uid)
    assert_receive {:sub_ready, _}, 2_000
    assert_receive {:sub_ready, _}, 2_000
    send(channel_topic.pid, :go)
    send(user_topic.pid, :go)

    {:ok, response} =
      Channel.update(@uid, "key-u1", cid, %{
        "title" => "After",
        "topic" => nil,
        "visibility" => "public_listed"
      })

    # response = ChannelMetaProjection with the NEW values
    meta = channel_row(cid)

    assert response["channel"] == %{
             "channel_id" => cid,
             "kind" => "channel",
             "visibility" => "public_listed",
             "title" => "After",
             "topic" => nil,
             "avatar_url" => nil,
             "member_count" => 1,
             "status" => "active",
             "created_at" => iso(meta["created_at"]),
             "updated_at" => iso(meta["updated_at"])
           }

    assert meta["title"] == "After"
    assert meta["topic"] == nil
    assert meta["visibility"] == "public_listed"
    assert meta["membership_version"] == 1
    assert meta["updated_at"] != before_updated_at

    # channel.updated + system.notice, both at the (unchanged) mv
    [updated, notice] = events(cid)
    assert updated["event_type"] == "channel.updated"
    assert updated["actor_kind"] == "user"
    assert updated["actor_id"] == @uid
    assert updated["membership_version_at_event"] == 1

    assert updated["payload"]["channel_id"] == cid

    assert updated["payload"]["channel_changes"] == %{
             "title" => %{"before" => "Before", "after" => "After"},
             "topic" => %{"before" => "old-topic", "after" => nil},
             "visibility" => %{"before" => "private", "after" => "public_listed"}
           }

    assert updated["payload"]["actor_kind"] == "user"
    assert updated["payload"]["actor_id"] == @uid

    assert notice["event_type"] == "system.notice"
    assert notice["actor_kind"] == "user"
    assert notice["actor_id"] == @uid
    assert notice["membership_version_at_event"] == 1
    assert notice["payload"]["notice_kind"] == "channel.updated"
    assert notice["payload"]["actor_user_id"] == @uid
    assert notice["payload"]["target_user_id"] == nil
    assert notice["payload"]["message_id"] == nil
    assert notice["payload"]["channel_changes"] == updated["payload"]["channel_changes"]

    # live frames on channel:<id> (in event_id order)
    frames = Task.await(channel_topic, 5_000)
    [updated_frame, notice_frame] = frames

    assert updated_frame["frame_type"] == "event"
    assert updated_frame["type"] == "channel.updated"
    assert updated_frame["event_id"] == updated["event_id"]
    assert updated_frame["membership_version_at_event"] == 1

    assert updated_frame["payload"]["actor"] == %{
             "user_id" => @uid,
             "display_name" => "Creator",
             "avatar_url" => nil
           }

    assert updated_frame["payload"]["channel_changes"] == updated["payload"]["channel_changes"]

    assert notice_frame["type"] == "system.notice"
    assert notice_frame["event_id"] == notice["event_id"]
    assert notice_frame["payload"]["notice_kind"] == "channel.updated"

    assert notice_frame["payload"]["actor"] == %{
             "user_id" => @uid,
             "display_name" => "Creator",
             "avatar_url" => nil
           }

    assert notice_frame["payload"]["target_user"] == nil
    assert notice_frame["payload"]["message_id"] == nil
    assert notice_frame["payload"]["channel_changes"] == updated["payload"]["channel_changes"]

    # D8: update is NOT in the my_channels_changed trigger set — the user
    # topic stays silent (only the channel topic receives live frames).
    assert Task.await(user_topic, 5_000) == []
  end

  test "update without changes → no events, updated_at unchanged, idem recorded + replayed" do
    cid = "ch-upd2-" <> Ecto.UUID.generate()
    seed_channel(cid, title: "Same", topic: "t", visibility: "private", created_by: @uid)
    seed_membership(cid, @uid, "owner")

    before_updated_at = channel_row(cid)["updated_at"]

    {:ok, response} = Channel.update(@uid, "key-u2", cid, %{"title" => "Same", "topic" => "t"})
    assert response["channel"]["updated_at"] == iso(before_updated_at)
    assert events(cid) == []

    # same-key replay → identical response
    {:ok, r2} = Channel.update(@uid, "key-u2", cid, %{"title" => "Same", "topic" => "t"})
    assert r2 == response

    [idem] = idem_rows("channel.update") |> Enum.filter(&(&1["operation_id"] == "key-u2"))
    body = idem["response_json"]
    assert body["channel"]["title"] == "Same"
  end

  test "update empty body → no events, current projection" do
    cid = "ch-upd3-" <> Ecto.UUID.generate()
    seed_channel(cid, title: "Base", topic: "keep", visibility: "private", created_by: @uid)
    seed_membership(cid, @uid, "owner")

    {:ok, response} = Channel.update(@uid, "key-u3", cid, %{})
    assert response["channel"]["title"] == "Base"
    assert response["channel"]["topic"] == "keep"
    assert response["channel"]["visibility"] == "private"
    assert events(cid) == []
  end

  test "update gates: 404 / DM kind / dissolved / non-owner-admin / avatar / visibility" do
    missing = "ch-none-" <> Ecto.UUID.generate()

    assert {:error, %Errors.ApiError{code: "CHANNEL_NOT_FOUND", http_status: 404}} =
             Channel.update(@uid, "key-g1", missing, %{"title" => "x"})

    dm = "ch-dm-" <> Ecto.UUID.generate()
    seed_channel(dm, kind: "dm", created_by: @uid)
    seed_membership(dm, @uid, "owner")

    assert {:error, %Errors.ApiError{code: "UNSUPPORTED_CHANNEL_KIND", http_status: 409}} =
             Channel.update(@uid, "key-g2", dm, %{"title" => "x"})

    dissolved = "ch-dis-" <> Ecto.UUID.generate()
    seed_channel(dissolved, status: "dissolved", created_by: @uid)
    seed_membership(dissolved, @uid, "owner")

    assert {:error, %Errors.ApiError{code: "CHANNEL_DISSOLVED", http_status: 409}} =
             Channel.update(@uid, "key-g3", dissolved, %{"title" => "x"})

    plain = "ch-plain-" <> Ecto.UUID.generate()
    seed_channel(plain, created_by: @uid)
    seed_membership(plain, @uid, "member")
    seed_membership(plain, @other, "owner")

    assert {:error, %Errors.ApiError{code: "FORBIDDEN", http_status: 403}} =
             Channel.update(@uid, "key-g4", plain, %{"title" => "x"})

    cid = "ch-g5-" <> Ecto.UUID.generate()
    seed_channel(cid, created_by: @uid)
    seed_membership(cid, @uid, "owner")

    assert {:error, %Errors.ApiError{code: "INVALID_MESSAGE", http_status: 422}} =
             Channel.update(@uid, "key-g5", cid, %{"avatar_attachment_id" => "att-1"})

    assert {:error, %Errors.ApiError{code: "INVALID_MESSAGE", http_status: 422}} =
             Channel.update(@uid, "key-g6", cid, %{"visibility" => "public"})
  end

  test "update idempotency: same key replays; different body conflicts (presence-aware)" do
    cid = "ch-idem-" <> Ecto.UUID.generate()
    seed_channel(cid, title: "I", topic: "t", visibility: "private", created_by: @uid)
    seed_membership(cid, @uid, "owner")

    {:ok, r1} = Channel.update(@uid, "key-u4", cid, %{"title" => "New"})
    {:ok, r2} = Channel.update(@uid, "key-u4", cid, %{"title" => "New"})
    assert r1 == r2

    # presence-aware hash: omit-topic vs explicit topic:null are DIFFERENT bodies
    {:error, %Errors.ApiError{code: "IDEMPOTENCY_CONFLICT"}} =
      Channel.update(@uid, "key-u4", cid, %{"title" => "New", "topic" => nil})
  end

  # ------------------------------------------------------------- dissolve

  test "dissolve → tombstone row, mv bump, events, my_channels_changed to all members" do
    cid = "ch-dis2-" <> Ecto.UUID.generate()
    seed_channel(cid, title: "Doomed", created_by: @uid, member_count: 2)
    seed_membership(cid, @uid, "owner")
    seed_membership(cid, @other, "member")
    seed_profile(@uid, "Creator", nil)

    channel_topic = subscribe("channel:" <> cid)
    other_topic = subscribe("user:" <> @other)
    uid_topic = subscribe("user:" <> @uid)
    assert_receive {:sub_ready, _}, 2_000
    assert_receive {:sub_ready, _}, 2_000
    assert_receive {:sub_ready, _}, 2_000

    Enum.each([channel_topic, other_topic, uid_topic], fn task -> send(task.pid, :go) end)

    {:ok, response} = Channel.dissolve(@uid, "key-d1", cid)

    assert response["channel"]["channel_id"] == cid
    assert response["channel"]["status"] == "dissolved"
    assert is_binary(response["channel"]["updated_at"])

    meta = channel_row(cid)
    assert meta["status"] == "dissolved"
    assert meta["membership_version"] == 2
    assert meta["member_count"] == 2

    [dissolved, notice] = events(cid)
    assert dissolved["event_type"] == "channel.dissolved"
    assert dissolved["actor_kind"] == "user"
    assert dissolved["actor_id"] == @uid
    assert dissolved["membership_version_at_event"] == 2
    assert dissolved["payload"]["status"] == "dissolved"
    assert dissolved["payload"]["dissolved_at"] != nil
    assert dissolved["payload"]["actor_kind"] == "user"
    assert dissolved["payload"]["actor_id"] == @uid

    assert notice["event_type"] == "system.notice"
    assert notice["membership_version_at_event"] == 2
    assert notice["payload"]["notice_kind"] == "channel.dissolved"
    assert notice["payload"]["actor_user_id"] == @uid
    assert notice["payload"]["target_user_id"] == nil
    assert notice["payload"]["message_id"] == nil
    assert notice["payload"]["channel_changes"] == nil

    frames = Task.await(channel_topic, 5_000)
    [dissolved_frame, notice_frame] = frames

    assert dissolved_frame["type"] == "channel.dissolved"
    assert dissolved_frame["event_id"] == dissolved["event_id"]
    assert dissolved_frame["membership_version_at_event"] == 2

    assert dissolved_frame["payload"]["actor"] == %{
             "user_id" => @uid,
             "display_name" => "Creator",
             "avatar_url" => nil
           }

    assert dissolved_frame["payload"]["dissolved_at"] == dissolved["payload"]["dissolved_at"]

    assert notice_frame["type"] == "system.notice"
    assert notice_frame["event_id"] == notice["event_id"]
    assert notice_frame["payload"]["notice_kind"] == "channel.dissolved"
    assert notice_frame["payload"]["actor"]["user_id"] == @uid

    hint = %{
      "frame_type" => "user_event",
      "event" => "my_channels_changed",
      "reason" => "channel_dissolved",
      "changed_channel_id" => cid
    }

    assert Task.await(other_topic, 5_000) == [hint]
    assert Task.await(uid_topic, 5_000) == [hint]
  end

  test "dissolve gates: 404 / DM / non-owner (role) / already-dissolved cached result" do
    missing = "ch-none2-" <> Ecto.UUID.generate()

    assert {:error, %Errors.ApiError{code: "CHANNEL_NOT_FOUND", http_status: 404}} =
             Channel.dissolve(@uid, "key-g7", missing)

    dm = "ch-dm2-" <> Ecto.UUID.generate()
    seed_channel(dm, kind: "dm", created_by: @uid)
    seed_membership(dm, @uid, "owner")

    assert {:error, %Errors.ApiError{code: "UNSUPPORTED_CHANNEL_KIND", http_status: 409}} =
             Channel.dissolve(@uid, "key-g8", dm)

    # Owner gate (#25) consults the ACTIVE member role, not channels.created_by:
    # a non-owner member is rejected ...
    plain = "ch-plain2-" <> Ecto.UUID.generate()
    seed_channel(plain, created_by: @other)
    seed_membership(plain, @uid, "member")
    seed_membership(plain, @other, "owner")

    assert {:error, %Errors.ApiError{code: "FORBIDDEN", http_status: 403}} =
             Channel.dissolve(@uid, "key-g9", plain)

    # ... and holding created_by alone is NOT enough once the owner role has
    # moved (the old Worker's created_by gate would have let this through).
    stale_creator = "ch-stale-" <> Ecto.UUID.generate()
    seed_channel(stale_creator, created_by: @uid)
    seed_membership(stale_creator, @uid, "admin")
    seed_membership(stale_creator, @other, "owner")

    assert {:error,
            %Errors.ApiError{
              code: "FORBIDDEN",
              http_status: 403,
              message: "only owner may dissolve"
            }} =
             Channel.dissolve(@uid, "key-g9b", stale_creator)

    cid = "ch-dis3-" <> Ecto.UUID.generate()
    seed_channel(cid, status: "dissolved", created_by: @uid)
    seed_membership(cid, @uid, "owner")

    {:ok, response} = Channel.dissolve(@uid, "key-d2", cid)
    assert response["channel"]["status"] == "dissolved"
    # no events emitted for the already-dissolved path
    assert events(cid) == []

    # same-key replay → identical cached response
    {:ok, r2} = Channel.dissolve(@uid, "key-d2", cid)
    assert r2 == response
  end

  test "dissolve owner gate: the role owner dissolves even when created_by lags" do
    # The mirror-image divergence: created_by still points at the (demoted)
    # original creator, but the OWNER role has moved. The role gate lets the
    # real owner through; the old Worker's created_by gate would have rejected.
    cid = "ch-role-owner-" <> Ecto.UUID.generate()
    seed_channel(cid, created_by: @uid)
    seed_membership(cid, @uid, "member")
    seed_membership(cid, @other, "owner")
    seed_profile(@other, "Other Person", nil)

    {:ok, response} = Channel.dissolve(@other, "key-role-1", cid)
    assert response["channel"]["channel_id"] == cid
    assert response["channel"]["status"] == "dissolved"

    [dissolved, notice] = events(cid)
    assert dissolved["event_type"] == "channel.dissolved"
    assert dissolved["actor_id"] == @other
    assert notice["event_type"] == "system.notice"
    assert notice["payload"]["notice_kind"] == "channel.dissolved"
  end

  test "dissolve after owner transfer: demoted old owner loses the right, new owner dissolves" do
    cid = "ch-xfer-dissolve-" <> Ecto.UUID.generate()
    seed_channel(cid, created_by: @uid)
    seed_membership(cid, @uid, "owner")
    seed_membership(cid, @other, "admin")
    seed_profile(@uid, "Creator", nil)
    seed_profile(@other, "Other Person", nil)

    {:ok, transfer_response} =
      Channel.transfer_owner(@uid, "key-xfer-1", cid, %{
        "target_user_id" => @other,
        "previous_owner_role" => "admin"
      })

    assert transfer_response["new_owner"] == %{"user_id" => @other, "role" => "owner"}
    assert transfer_response["previous_owner"]["user_id"] == @uid

    # #12 hands created_by over in the same transaction as the role swap.
    assert channel_row(cid)["created_by"] == @other

    # The demoted old owner (admin now) already lost the right to dissolve.
    assert {:error, %Errors.ApiError{code: "FORBIDDEN", http_status: 403}} =
             Channel.dissolve(@uid, "key-xfer-2", cid)

    # The new owner dissolves.
    {:ok, response} = Channel.dissolve(@other, "key-xfer-3", cid)
    assert response["channel"]["status"] == "dissolved"

    # A late dissolve by the old owner hits the already-dissolved path: the
    # status gate precedes the owner gate (old Worker parity), so ANY user
    # re-dissolving a dissolved channel gets the 200 tombstone, not 409.
    {:ok, late} = Channel.dissolve(@uid, "key-xfer-4", cid)
    assert late["channel"]["status"] == "dissolved"
  end

  test "dissolve keeps channel_pins + read_state rows; the tombstone stays readable" do
    cid = "ch-keep-" <> Ecto.UUID.generate()
    seed_channel(cid, created_by: @uid)
    seed_membership(cid, @uid, "owner")
    seed_membership(cid, @other, "member")
    seed_profile(@uid, "Creator", nil)
    seed_profile(@other, "Other Person", nil)

    # A pinned message ...
    message_id = seed_message("msg-keep-1", cid, @other, "keep me pinned", event_id: eid(1))
    pin_id = Ecto.UUID.generate()
    seed_pin(pin_id, cid, message_id)

    # ... and both members carry read_state cursors.
    seed_read_state(@uid, cid, eid(3))
    seed_read_state(@other, cid, eid(3))

    {:ok, response} = Channel.dissolve(@uid, "key-keep-1", cid)
    assert response["channel"]["status"] == "dissolved"

    # The pin row survives (the top bar of a dissolved channel still renders
    # its snapshot, contract §10.6 pin recovery).
    [pin] = ChannelPins.list_rows(cid)
    assert pin["pin_id"] == pin_id
    assert pin["source_message_id"] == message_id

    # The read_state cursors survive (bootstrap keeps projecting
    # last_read_event_id for the tombstone, contract §5.4).
    read_rows =
      Query.rows(
        Repo.query(
          "SELECT user_id, last_read_event_id FROM chat_v2.read_state WHERE channel_id = $1 ORDER BY user_id",
          [cid]
        )
      )

    assert Enum.map(read_rows, & &1["user_id"]) == [@uid, @other]

    Enum.each(read_rows, fn row -> assert row["last_read_event_id"] == eid(3) end)

    # End-to-end: the tombstone is still READABLE via bootstrap — the channel
    # lists with its read cursor and the pin snapshot intact.
    bootstrap = Bootstrap.fetch(@uid, cid)

    [summary] = Enum.filter(bootstrap["channels"], &(&1["channel_id"] == cid))
    assert summary["status"] == "dissolved"
    assert summary["last_read_event_id"] == eid(3)
    assert summary["role"] == "owner"

    [pin_wire] = bootstrap["channel_pins"]
    assert pin_wire["pin_id"] == pin_id
    assert pin_wire["source_message_id"] == message_id
    assert pin_wire["message"]["text"] == "keep me pinned"
  end

  test "subsequent writes to a dissolved channel → 409 CHANNEL_DISSOLVED" do
    cid = "ch-dis4-" <> Ecto.UUID.generate()
    seed_channel(cid, created_by: @uid)
    seed_membership(cid, @uid, "owner")

    {:ok, _} = Channel.dissolve(@uid, "key-d3", cid)

    assert {:error, %Errors.ApiError{code: "CHANNEL_DISSOLVED", http_status: 409}} =
             Channel.update(@uid, "key-d4", cid, %{"title" => "too late"})

    # a second dissolve (new key) hits the already-dissolved cached path
    {:ok, r} = Channel.dissolve(@uid, "key-d5", cid)
    assert r["channel"]["status"] == "dissolved"
  end

  # ------------------------------------------------------------ replay parity

  test "timeline replay re-projects lifecycle events (live == replay builders)" do
    seed_profile(@uid, "Creator", nil)
    seed_profile(@other, "Other Person", nil)

    {:ok, response} =
      Channel.create(@uid, "key-r1", %{
        "title" => "Replay",
        "initial_members" => [%{"user_id" => @other, "role" => "member"}]
      })

    cid = response["channel"]["channel_id"]
    {:ok, _} = Channel.update(@uid, "key-r2", cid, %{"topic" => "new topic"})
    {:ok, _} = Channel.dissolve(@uid, "key-r3", cid)

    # Gap-recovery replay (`GET .../events`, §6.1b) re-projects every event
    # type (including `system.notice`), mirroring the live broadcast builder.
    # (Timeline history `GET .../messages` intentionally excludes
    # `system.notice`, matching the old Worker's TIMELINE_HISTORY_EVENT_TYPES.)
    %{events: items} = Timeline.channel_events(@uid, cid, nil, 100)

    by_type = Enum.group_by(items, &Map.fetch!(&1, "type"))

    [created] = by_type["channel.created"]
    assert created["payload"]["actor"]["user_id"] == @uid
    assert created["payload"]["actor"]["display_name"] == "Creator"
    assert created["payload"]["channel"]["title"] == "Replay"
    assert created["payload"]["channel"]["visibility"] == "private"

    joined = by_type["member.joined"]
    assert length(joined) == 2

    Enum.each(joined, fn frame ->
      payload = frame["payload"]
      assert payload["user"]["user_id"] in [@uid, @other]
      assert payload["actor"] == nil
      assert payload["join_source"] == nil
    end)

    [updated] = by_type["channel.updated"]
    assert updated["payload"]["actor"]["user_id"] == @uid
    assert updated["payload"]["channel_changes"]["topic"]["before"] == nil
    assert updated["payload"]["channel_changes"]["topic"]["after"] == "new topic"

    [dissolved] = by_type["channel.dissolved"]
    assert dissolved["payload"]["actor"]["display_name"] == "Creator"
    assert dissolved["payload"]["status"] == "dissolved"
    assert dissolved["payload"]["dissolved_at"] != nil

    notices = by_type["system.notice"]
    assert length(notices) == 3

    kinds = notices |> Enum.map(& &1["payload"]["notice_kind"]) |> Enum.sort()
    assert kinds == ["channel.created", "channel.dissolved", "channel.updated"]

    Enum.each(notices, fn frame ->
      payload = frame["payload"]
      assert payload["actor"]["user_id"] == @uid
      assert payload["target_user"] == nil
      assert payload["message_id"] == nil
    end)
  end
end
