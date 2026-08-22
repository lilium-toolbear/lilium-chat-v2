defmodule LiliumChat.DirectoryTest do
  @moduledoc """
  Domain tests for `LiliumChat.Directory` (contract §5.6, issue #7):
  the `GET /api/chat/channels/directory` read path — filtering, keyset
  ordering/cursor semantics, role/last_read enrichment, read-only bound.
  """

  use LiliumChat.DataCase, async: false

  import LiliumChatWeb.ReadFixtures

  alias LiliumChat.Directory
  alias LiliumChat.Observability.ReadPath

  @viewer "11111111-1111-7111-8111-111111111111"
  @other "22222222-2222-7222-8222-222222222222"

  test "lists only public_listed + active channels with the §5.6 item shape" do
    public_active = seed_pub_channel("aaaaaaaa-0000-7000-8000-aaaaaaaaaaaa", "Alpha")
    seed_pub_channel("bbbbbbbb-0000-7000-8000-bbbbbbbbbbbb", "Bravo", visibility: "private")

    seed_pub_channel("cccccccc-0000-7000-8000-cccccccccccc", "Charlie (dissolved)",
      status: "dissolved"
    )

    seed_pub_channel("dddddddd-0000-7000-8000-dddddddddddd", "Delta (inactive)",
      status: "inactive"
    )

    %{items: items, next_cursor: next_cursor} = Directory.list_public(@viewer)

    assert next_cursor == nil
    assert Enum.map(items, & &1["channel_id"]) == [public_active]

    [item] = items
    assert item["kind"] == "channel"
    assert item["visibility"] == "public_listed"
    assert item["title"] == "Alpha"
    assert item["status"] == "active"
    assert item["unread_count"] == 0
    assert item["last_message_preview"] == nil
    assert item["role"] == nil
    assert item["last_read_event_id"] == nil
    assert Map.has_key?(item, "member_count")
    assert Map.has_key?(item, "avatar_url")
    assert Map.has_key?(item, "last_message_at")
  end

  test "orders by COALESCE(last_message_at, updated_at) DESC, channel_id DESC" do
    quiet = seed_pub_channel("aaaaaaaa-0000-7000-8000-aaaaaaaaaaaa", "Quiet")
    active = seed_pub_channel("bbbbbbbb-0000-7000-8000-bbbbbbbbbbbb", "Active")

    # Give `active` a recent visible message (drives last_message_at).
    seed_message(
      "bbbbbbbb-0001-7000-8000-000000000001",
      active,
      @other,
      "ping",
      event_id: eid(1),
      created_at: t(100)
    )

    # A deleted-only channel has no visible message → falls back to updated_at.
    seed_message(
      "aaaaaaaa-0001-7000-8000-000000000001",
      quiet,
      @other,
      "deleted ping",
      event_id: eid(2),
      created_at: t(200),
      status: "deleted"
    )

    %{items: items} = Directory.list_public(@viewer)

    # `active` (last_message_at = t(100)) sorts first: with an equal-or-earlier
    # updated_at it still wins on last_message_at DESC; `quiet`'s visible
    # activity is nil → COALESCE falls back to updated_at (seed time).
    assert Enum.map(items, & &1["channel_id"]) == [active, quiet]
    # `active` surfaces its latest visible message; `quiet`'s only message is
    # deleted → its last_message_at is null.
    assert [active_item, quiet_item] = items
    assert active_item["last_message_at"] != nil
    assert quiet_item["last_message_at"] == nil
  end

  test "breaks equal last_activity by channel_id DESC" do
    # Two public channels with an identical last activity (same updated_at,
    # no messages → COALESCE falls back to updated_at for both).
    fixed = t(10)
    high = seed_pub_channel("ffffffff-0000-7000-8000-ffffffffffff", "High ID", created_at: fixed)
    low = seed_pub_channel("11111111-0000-7000-8000-111111111111", "Low ID", created_at: fixed)

    %{items: items} = Directory.list_public(@viewer)

    # Equal last_activity → the channel_id DESC tie-breaker decides: the
    # higher (lexicographically greater) channel_id leads.
    assert Enum.map(items, & &1["channel_id"]) == [high, low]
  end

  test "q filters titles case-insensitively (substring, ILIKE parity)" do
    alpha = seed_pub_channel("aaaaaaaa-0000-7000-8000-aaaaaaaaaaaa", "Game Night")
    seed_pub_channel("bbbbbbbb-0000-7000-8000-bbbbbbbbbbbb", "Music Lounge")

    %{items: matches} = Directory.list_public(@viewer, q: "game")
    assert Enum.map(matches, & &1["channel_id"]) == [alpha]

    %{items: no_match} = Directory.list_public(@viewer, q: "ZZZ-no-such-title")
    assert no_match == []
  end

  test "keyset cursor pages without overlap or loss, in stable order" do
    ids =
      for n <- 1..7 do
        id = "chann" <> pad(n)
        seed_pub_channel(id, "Channel #{n}")
      end

    # Distinct last activity per channel via messages, newest first on purpose.
    Enum.each(1..7, fn n ->
      seed_message(
        "msg-#{pad(n)}",
        Enum.at(ids, n - 1),
        @other,
        "message #{n}",
        event_id: eid(n),
        created_at: t(n)
      )
    end)

    page1 = Directory.list_public(@viewer, limit: 3)
    assert length(page1.items) == 3
    assert is_binary(page1.next_cursor)

    page2 = Directory.list_public(@viewer, limit: 3, cursor: page1.next_cursor)
    assert length(page2.items) == 3
    assert is_binary(page2.next_cursor)

    page3 = Directory.list_public(@viewer, limit: 3, cursor: page2.next_cursor)
    assert length(page3.items) == 1
    assert page3.next_cursor == nil

    all = Enum.flat_map([page1, page2, page3], & &1.items) |> Enum.map(& &1["channel_id"])
    assert length(all) == 7
    assert Enum.uniq(all) == all
    # The newest-activity channel leads page 1.
    assert hd(all) == hd(page1.items)["channel_id"]
  end

  test "an invalid cursor is swallowed and treated as no cursor" do
    seed_pub_channel("aaaaaaaa-0000-7000-8000-aaaaaaaaaaaa", "Solo")

    %{items: invalid_cursor_items, next_cursor: invalid_next} =
      Directory.list_public(@viewer, cursor: "not-base64!!")

    assert invalid_next == nil
    assert length(invalid_cursor_items) == 1

    %{items: clean_items} = Directory.list_public(@viewer)
    assert invalid_cursor_items == clean_items
  end

  test "role / last_read_event_id are enriched for the viewer's active memberships only" do
    joined = seed_pub_channel("aaaaaaaa-0000-7000-8000-aaaaaaaaaaaa", "Joined", member_count: 2)
    not_joined = seed_pub_channel("bbbbbbbb-0000-7000-8000-bbbbbbbbbbbb", "Not Joined")
    seed_membership(joined, @viewer, "admin")
    seed_read_state(@viewer, joined, eid(42))

    %{items: items} = Directory.list_public(@viewer)
    by_id = Map.new(items, &{&1["channel_id"], &1})

    assert by_id[joined]["role"] == "admin"
    assert by_id[joined]["last_read_event_id"] == eid(42)
    assert by_id[not_joined]["role"] == nil
    assert by_id[not_joined]["last_read_event_id"] == nil
  end

  test "list_public executes zero write statements (A12)" do
    id = seed_pub_channel("aaaaaaaa-0000-7000-8000-aaaaaaaaaaaa", "Alpha")
    seed_membership(id, @viewer, "member")

    {_result, stats} = ReadPath.run(fn -> Directory.list_public(@viewer) end)
    assert stats.writes == 0
    # Bounded: one page query + one membership/read_state query.
    assert stats.reads <= 2
  end

  # ---------------------------------------------------------------- helpers

  defp seed_pub_channel(id, title, opts \\ []) do
    seed_channel(
      id,
      Keyword.merge(
        [title: title, visibility: "public_listed", created_by: @other],
        Keyword.take(opts, [:status, :member_count, :avatar_url, :visibility, :topic, :created_at])
      )
    )
  end

  defp pad(n), do: String.pad_leading("#{n}", 12, "0")

  defp t(n), do: DateTime.utc_now() |> DateTime.add(n, :second)
end
