defmodule LiliumChat.InvitesTest do
  @moduledoc """
  Domain tests for `LiliumChat.Invites` (contract §5.10, issue #7): the
  invite preview — shape, my_membership mapping, INVITE_NOT_FOUND boundaries
  (missing / revoked / expired / channel missing), and the read-only bound.
  """

  use LiliumChat.DataCase, async: false

  import LiliumChatWeb.ReadFixtures

  alias LiliumChat.Invites
  alias LiliumChat.Observability.ReadPath

  @viewer "11111111-1111-7111-8111-111111111111"
  @u1 "11111111-0000-7000-8000-000000000001"
  @u2 "22222222-0000-7000-8000-000000000002"
  @u3 "33333333-0000-7000-8000-000000000003"
  @u4 "44444444-0000-7000-8000-000000000004"

  @channel "cccccccc-0000-7000-8000-cccccccccccc"

  test "preview returns the §5.10 wire shape with sample members (≤3, user_id order)" do
    seed_channel(@channel, title: "Invited Channel", created_by: @u1, member_count: 4)
    seed_membership(@channel, @u1, "owner")
    seed_membership(@channel, @u2, "admin")
    seed_membership(@channel, @u3, "member")
    seed_membership(@channel, @u4, "member")
    seed_profile(@u1, "Invite Alice", nil)
    seed_profile(@u2, "Invite Bob", nil)
    seed_profile(@u3, "Invite Carol", nil)

    seed_invite("inv_abc123", @channel, created_by: @u1, max_uses: 10)

    preview = Invites.preview(@viewer, "inv_abc123")

    assert preview["invite"]["invite_code"] == "inv_abc123"
    assert preview["invite"]["expires_at"] != nil
    assert preview["invite"]["max_uses"] == 10

    channel = preview["channel"]
    assert channel["channel_id"] == @channel
    assert channel["title"] == "Invited Channel"
    assert channel["kind"] == "channel"
    assert channel["visibility"] == "private"
    assert channel["member_count"] == 4
    assert channel["status"] == "active"
    assert Map.has_key?(channel, "avatar_url")

    assert preview["inviter"] == %{
             "user_id" => @u1,
             "display_name" => "Invite Alice",
             "avatar_url" => nil
           }

    # Up to 3 sample members, ordered by user_id ASC.
    assert length(preview["sample_members"]) == 3
    assert Enum.map(preview["sample_members"], & &1["user_id"]) == [@u1, @u2, @u3]

    # The viewer has not joined yet.
    assert preview["my_membership"] == %{"status" => "not_joined", "channel_id" => nil}
  end

  test "preview reports the caller's own membership state" do
    seed_channel(@channel, title: "Invited Channel", created_by: @u1)
    seed_invite("inv_own", @channel, created_by: @u1)

    # Active member.
    seed_membership(@channel, @viewer, "member")
    active = Invites.preview(@viewer, "inv_own")
    assert active["my_membership"] == %{"status" => "active", "channel_id" => @channel}

    # Left member.
    Repo.query!(
      "UPDATE chat_v2.channel_members SET status = 'left' WHERE channel_id = $1 AND user_id = $2",
      [@channel, @viewer]
    )

    left = Invites.preview(@viewer, "inv_own")
    assert left["my_membership"] == %{"status" => "left", "channel_id" => nil}
  end

  test "INVITE_NOT_FOUND: missing / revoked / expired / channel missing" do
    seed_channel(@channel, title: "Invited Channel", created_by: @u1)
    seed_invite("inv_revoked", @channel, created_by: @u1, revoked_at: DateTime.utc_now())

    seed_invite("inv_expired", @channel,
      created_by: @u1,
      expires_at: DateTime.utc_now() |> DateTime.add(-1, :day)
    )

    seed_invite("inv_orphan", "99999999-0000-7000-8000-999999999999", created_by: @u1)

    for code <- ["inv_nope", "inv_revoked", "inv_expired", "inv_orphan"] do
      assert_error(fn -> Invites.preview(@viewer, code) end, "INVITE_NOT_FOUND", 404)
    end
  end

  test "preview is read-only and bounded (A12)" do
    seed_channel(@channel, title: "Invited Channel", created_by: @u1)
    seed_membership(@channel, @u1, "owner")
    seed_profile(@u1, "Invite Alice", nil)
    seed_invite("inv_ro", @channel, created_by: @u1)

    {_result, stats} = ReadPath.run(fn -> Invites.preview(@viewer, "inv_ro") end)
    assert stats.writes == 0
    # invite+channel (1) + samples (1) + my_membership (1) + profiles (1).
    assert stats.reads <= 4
  end

  test "invite without a max_uses projects null" do
    seed_channel(@channel, title: "Invited Channel", created_by: @u1)
    seed_invite("inv_unlimited", @channel, created_by: @u1)

    preview = Invites.preview(@viewer, "inv_unlimited")
    assert preview["invite"]["max_uses"] == nil
  end

  # ---------------------------------------------------------------- helpers

  defp assert_error(fun, code, http_status) do
    try do
      fun.()
      flunk("expected #{code}")
    catch
      :error, e ->
        assert e.code == code
        assert e.http_status == http_status
    end
  end
end
