defmodule LiliumChat.StickersTest do
  @moduledoc """
  Domain tests for `LiliumChat.Stickers` (contract §8.3, issue #7): the
  personal sticker library — ordering, soft-delete exclusion, keyset paging,
  attachment projection, read-only bound.
  """

  use LiliumChat.DataCase, async: false

  import LiliumChatWeb.ReadFixtures

  alias LiliumChat.Observability.ReadPath
  alias LiliumChat.Stickers

  @viewer "11111111-1111-7111-8111-111111111111"
  @other "22222222-2222-7222-8222-222222222222"

  test "lists only the caller's stickers, newest first, excluding deleted rows" do
    ts30 = t(30)
    ts20 = t(20)
    ts10 = t(10)

    seed_personal_sticker("st_newest", @viewer, "att_newest", created_at: ts30)
    seed_personal_sticker("st_middle", @viewer, "att_middle", created_at: ts20)
    seed_personal_sticker("st_oldest", @viewer, "att_oldest", created_at: ts10)

    seed_personal_sticker("st_deleted", @viewer, "att_deleted",
      created_at: t(40),
      deleted_at: DateTime.utc_now()
    )

    seed_personal_sticker("st_other_user", @other, "att_other", created_at: t(50))

    %{items: items, next_cursor: next_cursor} = Stickers.list_for_user(@viewer)

    # The old Worker sets next_cursor to the last row's created_at whenever the
    # page is non-empty (no over-fetch / short-page detection).
    assert next_cursor == NaiveDateTime.to_iso8601(ts10)
    assert Enum.map(items, & &1["sticker_id"]) == ["st_newest", "st_middle", "st_oldest"]

    [first | _] = items

    assert first["attachment"] == %{
             "attachment_id" => "att_newest",
             "url" => "https://s3.example.com/att_newest",
             "mime_type" => "image/png",
             "width" => 512,
             "height" => 512,
             "size_bytes" => 12345,
             "blurhash" => nil
           }

    assert first["created_at"] != nil
  end

  test "custom attachment fields project through" do
    seed_personal_sticker(
      "st_custom",
      @viewer,
      "att_custom",
      url: "https://cdn.example.com/custom.webp",
      mime_type: "image/webp",
      width: 256,
      height: 384,
      size_bytes: 999,
      blurhash: "LEHV6=WB2yoe_4jXaet7WU",
      created_at: t(1)
    )

    %{items: [item]} = Stickers.list_for_user(@viewer)

    assert item["attachment"]["url"] == "https://cdn.example.com/custom.webp"
    assert item["attachment"]["mime_type"] == "image/webp"
    assert item["attachment"]["width"] == 256
    assert item["attachment"]["height"] == 384
    assert item["attachment"]["size_bytes"] == 999
    assert item["attachment"]["blurhash"] == "LEHV6=WB2yoe_4jXaet7WU"
  end

  test "keyset cursor pages newest-first with the last row's created_at" do
    for n <- 1..5 do
      seed_personal_sticker("st_#{n}", @viewer, "att_#{n}", created_at: t(n))
    end

    page1 = Stickers.list_for_user(@viewer, limit: 2)
    assert length(page1.items) == 2
    # Newest first: t(5) then t(4).
    assert hd(page1.items)["sticker_id"] == "st_5"
    assert Enum.at(page1.items, 1)["sticker_id"] == "st_4"
    assert is_binary(page1.next_cursor)

    page2 = Stickers.list_for_user(@viewer, limit: 2, cursor: page1.next_cursor)
    assert length(page2.items) == 2
    assert hd(page2.items)["sticker_id"] == "st_3"

    page3 = Stickers.list_for_user(@viewer, limit: 2, cursor: page2.next_cursor)
    assert length(page3.items) == 1
    assert hd(page3.items)["sticker_id"] == "st_1"

    # A cursor past everything yields an empty page (the old Worker keeps
    # next_cursor non-null whenever the page was non-empty; the empty final
    # page has a null cursor).
    page4 = Stickers.list_for_user(@viewer, limit: 2, cursor: page3.next_cursor)
    assert page4.items == []
    assert page4.next_cursor == nil
  end

  test "an invalid cursor falls back to the first page" do
    ts1 = t(1)
    seed_personal_sticker("st_a", @viewer, "att_a", created_at: ts1)

    %{items: with_bad_cursor, next_cursor: cursor} =
      Stickers.list_for_user(@viewer, cursor: "not-a-timestamp")

    assert cursor == NaiveDateTime.to_iso8601(ts1)
    assert with_bad_cursor == Stickers.list_for_user(@viewer).items
  end

  test "an empty library returns an empty page" do
    result = Stickers.list_for_user(@viewer)
    assert result == %{items: [], next_cursor: nil}
  end

  test "list_for_user executes zero write statements (A12)" do
    seed_personal_sticker("st_ro", @viewer, "att_ro", created_at: t(1))

    {_result, stats} = ReadPath.run(fn -> Stickers.list_for_user(@viewer) end)
    assert stats.writes == 0
    # One statement only.
    assert stats.reads == 1
  end

  # ---------------------------------------------------------------- helpers

  # Truncate to microseconds: the column is timestamp(6) and PG would round
  # sub-microsecond digits, making stored-value comparisons flaky.
  defp t(n), do: DateTime.utc_now() |> DateTime.add(n, :second) |> DateTime.truncate(:microsecond)
end
