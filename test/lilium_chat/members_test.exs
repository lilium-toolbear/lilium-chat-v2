defmodule LiliumChat.MembersTest do
  @moduledoc """
  Domain tests for `LiliumChat.Members` (contract §7.1 / §7.1b, issue #7):
  the member list (ordering, typeahead, keyset paging) and the exact
  single-member read, error codes, read-only bound.
  """

  use LiliumChat.DataCase, async: false

  import LiliumChatWeb.ReadFixtures

  alias LiliumChat.Errors
  alias LiliumChat.Members
  alias LiliumChat.Observability.ReadPath

  @viewer "11111111-1111-7111-8111-111111111111"
  @u1 "11111111-0000-7000-8000-000000000001"
  @u2 "22222222-0000-7000-8000-000000000002"
  @u3 "33333333-0000-7000-8000-000000000003"
  @u4 "44444444-0000-7000-8000-000000000004"

  test "list orders by role rank, joined_at, user_id and excludes left members" do
    ch = seed_channel_with_viewer()

    seed_membership(ch, @u1, "member", joined_at: t(10))
    seed_membership(ch, @u2, "owner", joined_at: t(20))
    seed_membership(ch, @u3, "admin", joined_at: t(30))
    seed_membership(ch, @u4, "member", joined_at: t(5))
    seed_membership(ch, "55555555-0000-7000-8000-000000000005", "member", status: "left")

    %{items: items} = Members.list(@viewer, ch)

    # owner (0) → admin (1) → members by joined_at ASC. The viewer is also an
    # active member (gate) and joined earliest (t0), so leads the members.
    assert Enum.map(items, & &1["role"]) == ["owner", "admin", "member", "member", "member"]
    assert Enum.map(items, & &1["user"]["user_id"]) == [@u2, @u3, @viewer, @u4, @u1]

    [first | _] = items
    assert first["joined_at"] != nil
  end

  test "list breaks equal joined_at by user_id ASC (and role rank first)" do
    ch = seed_channel_with_viewer()

    # Two members sharing an identical joined_at: must order by user_id ASC.
    same_join = DateTime.utc_now() |> DateTime.add(15, :second)
    seed_membership(ch, "33333333-0000-7000-8000-000000000009", "member", joined_at: same_join)
    seed_membership(ch, "11111111-0000-7000-8000-000000000008", "member", joined_at: same_join)

    %{items: items} = Members.list(@viewer, ch)

    ids = Enum.map(items, & &1["user"]["user_id"])
    # Both same-joined members trail the viewer (earliest join); of them, the
    # lower user_id comes first.
    assert ids == [
             @viewer,
             "11111111-0000-7000-8000-000000000008",
             "33333333-0000-7000-8000-000000000009"
           ]
  end

  test "list pages with a keyset cursor (over-fetch 101, limit slicing)" do
    ch = seed_channel_with_viewer()

    # 6 seeded members + the viewer (gate, joined earliest) = 7 active;
    # limit 4 → first page 4 + cursor, second page 3.
    for {user, n} <-
          [
            {@u1, 1},
            {@u2, 2},
            {@u3, 3},
            {@u4, 4},
            {"55555555-0000-7000-8000-000000000005", 5},
            {"66666666-0000-7000-8000-000000000006", 6}
          ] do
      seed_membership(ch, user, "member", joined_at: t(n))
    end

    page1 = Members.list(@viewer, ch, limit: 4)
    assert length(page1.items) == 4
    assert is_binary(page1.next_cursor)

    page2 = Members.list(@viewer, ch, limit: 4, cursor: page1.next_cursor)
    assert length(page2.items) == 3
    assert page2.next_cursor == nil

    all = Enum.flat_map([page1, page2], & &1.items) |> Enum.map(& &1["user"]["user_id"])
    assert length(all) == 7
    assert Enum.uniq(all) == all
    # The viewer joined earliest → leads the list.
    assert hd(page1.items)["user"]["user_id"] == @viewer
  end

  test "list with query filters by display-name/user-id prefix and never pages" do
    ch = seed_channel_with_viewer()

    seed_membership(ch, @u1, "member", joined_at: t(1))
    seed_membership(ch, @u2, "member", joined_at: t(2))
    seed_membership(ch, @u3, "member", joined_at: t(3))
    seed_profile(@u1, "Alice Zhang", nil)
    seed_profile(@u2, "Bob Stone", nil)
    seed_profile(@u3, "Carol Ann", nil)

    %{items: alice, next_cursor: cursor} = Members.list(@viewer, ch, query: "ali")
    assert cursor == nil
    assert Enum.map(alice, & &1["user"]["user_id"]) == [@u1]
    assert hd(alice)["user"]["display_name"] == "Alice Zhang"

    # Case-insensitive.
    %{items: case_insensitive} = Members.list(@viewer, ch, query: "ALICE")
    assert length(case_insensitive) == 1

    # User-id prefix (the fallback display name does not match, so the
    # user_id branch must carry it).
    %{items: by_id} = Members.list(@viewer, ch, query: String.downcase(@u2))
    assert Enum.map(by_id, & &1["user"]["user_id"]) == [@u2]

    # No match → empty.
    %{items: none} = Members.list(@viewer, ch, query: "zzz")
    assert none == []
  end

  test "detail returns the exact member record (any status)" do
    ch = seed_channel_with_viewer()
    seed_membership(ch, @u1, "admin", joined_at: t(1))
    seed_profile(@u1, "Alice Zhang", "https://cdn.example.com/a.png")

    detail = Members.detail(@viewer, ch, @u1)

    assert detail["user"] == %{
             "user_id" => @u1,
             "display_name" => "Alice Zhang",
             "avatar_url" => "https://cdn.example.com/a.png"
           }

    assert detail["role"] == "admin"
    assert detail["status"] == "active"
    assert detail["joined_at"] != nil
  end

  test "detail reports left members with status left" do
    ch = seed_channel_with_viewer()
    seed_membership(ch, @u1, "member", joined_at: t(1), status: "left")

    detail = Members.detail(@viewer, ch, @u1)
    assert detail["status"] == "left"
  end

  test "detail falls back to the user-<8hex> display name without a profile row" do
    ch = seed_channel_with_viewer()
    seed_membership(ch, @u1, "member", joined_at: t(1))

    detail = Members.detail(@viewer, ch, @u1)

    assert detail["user"]["display_name"] ==
             "user-#{@u1 |> String.downcase() |> String.slice(0, 8)}"
  end

  test "gate errors: missing channel, non-member viewer, unknown target member" do
    ch = seed_channel_with_viewer()
    seed_membership(ch, @u1, "member", joined_at: t(1))

    for fun <- [
          fn -> Members.list(@viewer, "00000000-0000-7000-8000-0000000000ff") end,
          fn -> Members.detail(@viewer, "00000000-0000-7000-8000-0000000000ff", @u1) end,
          fn -> Members.list("99999999-0000-7000-8000-000000000099", ch) end,
          fn -> Members.detail("99999999-0000-7000-8000-000000000099", ch, @u1) end,
          fn -> Members.detail(@viewer, ch, "88888888-0000-7000-8000-000000000088") end
        ] do
      assert_raise Errors.ApiError, fun
    end
  end

  test "gate errors carry the contract codes" do
    ch = seed_channel_with_viewer()
    seed_membership(ch, @u1, "member", joined_at: t(1))

    assert_error(
      fn -> Members.list(@viewer, "00000000-0000-7000-8000-0000000000ff") end,
      "CHANNEL_NOT_FOUND",
      404
    )

    assert_error(
      fn -> Members.list("99999999-0000-7000-8000-000000000099", ch) end,
      "FORBIDDEN",
      403
    )

    assert_error(
      fn -> Members.detail(@viewer, ch, "88888888-0000-7000-8000-000000000088") end,
      "MEMBER_NOT_FOUND",
      404
    )
  end

  test "list executes zero write statements (A12)" do
    ch = seed_channel_with_viewer()
    seed_membership(ch, @u1, "member", joined_at: t(1))
    seed_profile(@u1, "Alice Zhang", nil)

    {_result, stats} = ReadPath.run(fn -> Members.list(@viewer, ch) end)
    assert stats.writes == 0
    # gate (1) + over-fetch (1) + profiles (1 batch).
    assert stats.reads <= 3

    {_result2, stats2} = ReadPath.run(fn -> Members.detail(@viewer, ch, @u1) end)
    assert stats2.writes == 0
    # gate (1) + member row (1) + profile (1).
    assert stats2.reads <= 3
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

  defp seed_channel_with_viewer do
    ch = "cccccccc-0000-7000-8000-cccccccccccc"
    seed_channel(ch, title: "Members Channel")
    seed_membership(ch, @viewer, "member")
    ch
  end

  defp t(n), do: DateTime.utc_now() |> DateTime.add(n, :second)
end
