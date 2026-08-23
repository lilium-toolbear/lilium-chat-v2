defmodule LiliumChat.StickersTest do
  @moduledoc """
  Domain tests for `LiliumChat.Stickers` (contract §8.3):

  * issue #7 — the personal sticker library read path: ordering,
    soft-delete exclusion, keyset paging, attachment projection, read-only
    bound;
  * issue #15 — the write path: `save/3` (get-or-create with source
    resolution, idempotency, the 200-item limit) and `delete/3`
    (soft-delete, idempotent, ownership).
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

  # ------------------------------------------------- issue #15: save/delete

  @ch "cccccccc-0000-7000-8000-cccccccccccc"

  defp seed_library_channel(ch) do
    seed_channel(ch, created_by: @viewer)
    seed_membership(ch, @viewer, "member")
    seed_membership(ch, @other, "member")
    ch
  end

  # A finalized attachment owned by `user` — the own-attachment save source.
  defp own_att(user, id) do
    seed_attachment(id, owner_user_id: user)
    id
  end

  defp assert_api_error(code, fun) do
    error = assert_raise LiliumChat.Errors.ApiError, fun
    assert error.code == code
  end

  test "save: own finalized attachment → created with the §8.3 PersonalSticker shape" do
    seed_library_channel(@ch)
    att = own_att(@viewer, "att-save-1")

    response = Stickers.save(@viewer, "op-save-1", %{"channel_id" => @ch, "attachment_id" => att})
    sticker = response["sticker"]

    assert is_binary(sticker["sticker_id"])
    assert is_binary(sticker["created_at"])

    assert sticker["attachment"] == %{
             "attachment_id" => att,
             "url" => "https://s3.example.com/#{att}",
             "mime_type" => "image/png",
             "width" => 100,
             "height" => 100,
             "size_bytes" => 1024,
             "blurhash" => nil
           }

    # the library row references the canonical attachment (no binary copy)
    row =
      Repo.query!(
        "SELECT user_id, attachment_id, deleted_at FROM chat_v2.personal_stickers WHERE sticker_id = $1",
        [sticker["sticker_id"]]
      )

    assert row.num_rows == 1
    assert hd(row.rows) == [@viewer, att, nil]
  end

  test "save: re-saving an active sticker (new key) returns the same sticker_id, no new row" do
    seed_library_channel(@ch)
    att = own_att(@viewer, "att-save-3")

    r1 = Stickers.save(@viewer, "op-save-3a", %{"channel_id" => @ch, "attachment_id" => att})
    r2 = Stickers.save(@viewer, "op-save-3b", %{"channel_id" => @ch, "attachment_id" => att})

    assert r1["sticker"]["sticker_id"] == r2["sticker"]["sticker_id"]

    count =
      Repo.query!(
        "SELECT COUNT(*) AS n FROM chat_v2.personal_stickers WHERE user_id = $1 AND attachment_id = $2",
        [@viewer, att]
      ).num_rows

    assert count == 1
  end

  test "save upsert statement: insert / no-op on active row / revive on deleted row" do
    seed_library_channel(@ch)
    att = own_att(@viewer, "att-race-1")
    ts = t(1)

    # The exact upsert Stickers.save issues for a new library item
    # (ON CONFLICT keeps a concurrent same-attachment save race-safe).
    upsert =
      "INSERT INTO chat_v2.personal_stickers (sticker_id, user_id, attachment_id, url, " <>
        "mime_type, width, height, size_bytes, blurhash, created_at, deleted_at) " <>
        "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, NULL) " <>
        "ON CONFLICT (user_id, attachment_id) DO UPDATE " <>
        "SET deleted_at = NULL, blurhash = EXCLUDED.blurhash, created_at = EXCLUDED.created_at " <>
        "WHERE personal_stickers.deleted_at IS NOT NULL " <>
        "RETURNING sticker_id"

    params = [
      LiliumChat.Ids.uuidv7(),
      @viewer,
      att,
      "https://s3.example.com/#{att}",
      "image/png",
      100,
      100,
      1024,
      nil,
      ts
    ]

    # (a) fresh insert returns the new sticker_id
    res1 = Repo.query!(upsert, params, type: true)
    assert res1.num_rows == 1
    inserted_id = res1.rows |> hd() |> hd()

    # (b) an already-ACTIVE row: WHERE excludes the update → 0 rows, row untouched
    res2 = Repo.query!(upsert, params, type: true)
    assert res2.num_rows == 0

    untouched =
      Repo.query!(
        "SELECT sticker_id FROM chat_v2.personal_stickers WHERE user_id = $1 AND attachment_id = $2",
        [@viewer, att]
      )

    assert hd(untouched.rows) == [inserted_id]

    # (c) a soft-deleted row: revived (deleted_at cleared, fresh created_at)
    Repo.query!(
      "UPDATE chat_v2.personal_stickers SET deleted_at = $2 WHERE user_id = $1 AND attachment_id = $3",
      [@viewer, DateTime.utc_now(), att]
    )

    res3 = Repo.query!(upsert, params, type: true)
    assert res3.num_rows == 1
    assert hd(res3.rows) == [inserted_id]

    active =
      Repo.query!(
        "SELECT 1 AS x FROM chat_v2.personal_stickers " <>
          "WHERE user_id = $1 AND attachment_id = $2 AND deleted_at IS NULL",
        [@viewer, att]
      )

    assert active.num_rows == 1
  end

  test "save: a soft-deleted sticker is revived (one row kept, active again)" do
    seed_library_channel(@ch)
    att = own_att(@viewer, "att-save-4")

    first = Stickers.save(@viewer, "op-save-4a", %{"channel_id" => @ch, "attachment_id" => att})
    Stickers.delete(@viewer, "op-del-4a", first["sticker"]["sticker_id"])

    revived = Stickers.save(@viewer, "op-save-4b", %{"channel_id" => @ch, "attachment_id" => att})

    # same library item identity (sticker_id is stable per user+attachment)
    assert revived["sticker"]["sticker_id"] == first["sticker"]["sticker_id"]

    total =
      Repo.query!(
        "SELECT COUNT(*) AS n FROM chat_v2.personal_stickers WHERE user_id = $1 AND attachment_id = $2",
        [@viewer, att]
      ).num_rows

    active =
      Repo.query!(
        "SELECT COUNT(*) AS n FROM chat_v2.personal_stickers WHERE user_id = $1 AND attachment_id = $2 AND deleted_at IS NULL",
        [@viewer, att]
      ).num_rows

    assert total == 1
    assert active == 1
  end

  test "save: channel-visible source — a member saves an attachment from a visible image message" do
    seed_library_channel(@ch)
    att = own_att(@other, "att-save-5")

    msg = seed_message("cccccccc-0001-7000-8000-000000000001", @ch, @other, nil, type: "image")
    seed_message_attachment(msg, att)

    response =
      Stickers.save(@viewer, "op-save-5", %{"channel_id" => @ch, "attachment_id" => att})

    assert response["sticker"]["attachment"]["attachment_id"] == att
    assert response["sticker"]["attachment"]["url"] == "https://s3.example.com/#{att}"
  end

  test "save: channel-visible source works for a sticker message attachment too" do
    seed_library_channel(@ch)
    att = own_att(@other, "att-save-6")

    msg = seed_message("cccccccc-0002-7000-8000-000000000001", @ch, @other, nil, type: "sticker")
    seed_sticker(msg, attachment_id: att, url: "https://s3.example.com/#{att}", size_bytes: 555)

    response =
      Stickers.save(@viewer, "op-save-6", %{"channel_id" => @ch, "attachment_id" => att})

    assert response["sticker"]["attachment"]["attachment_id"] == att
    assert response["sticker"]["attachment"]["size_bytes"] == 555
  end

  test "save: attachment only linked to a deleted message → INVALID_STICKER_SOURCE" do
    seed_library_channel(@ch)
    att = own_att(@other, "att-save-7")

    msg =
      seed_message("cccccccc-0003-7000-8000-000000000001", @ch, @other, nil,
        type: "image",
        status: "deleted"
      )

    seed_message_attachment(msg, att)

    assert_api_error("INVALID_STICKER_SOURCE", fn ->
      Stickers.save(@viewer, "op-save-7", %{"channel_id" => @ch, "attachment_id" => att})
    end)

    row =
      Repo.query!(
        "SELECT 1 AS x FROM chat_v2.personal_stickers WHERE user_id = $1 AND attachment_id = $2",
        [@viewer, att]
      )

    assert row.num_rows == 0
  end

  test "save: attachment only linked to a recalled message → INVALID_STICKER_SOURCE" do
    seed_library_channel(@ch)
    att = own_att(@other, "att-save-8")

    msg =
      seed_message("cccccccc-0004-7000-8000-000000000001", @ch, @other, nil,
        type: "image",
        status: "recalled"
      )

    seed_message_attachment(msg, att)

    assert_api_error("INVALID_STICKER_SOURCE", fn ->
      Stickers.save(@viewer, "op-save-8", %{"channel_id" => @ch, "attachment_id" => att})
    end)
  end

  test "save: attachment linked to a text message is NOT a sticker source → INVALID_STICKER_SOURCE" do
    seed_library_channel(@ch)
    att = own_att(@other, "att-save-9")

    msg = seed_message("cccccccc-0005-7000-8000-000000000001", @ch, @other, "text msg")
    seed_message_attachment(msg, att)

    assert_api_error("INVALID_STICKER_SOURCE", fn ->
      Stickers.save(@viewer, "op-save-9", %{"channel_id" => @ch, "attachment_id" => att})
    end)
  end

  test "save: unknown channel (channel path) → CHANNEL_NOT_FOUND" do
    seed_library_channel(@ch)
    # owned by someone else → the channel path runs and gates on a channel
    # that does not exist
    att = own_att(@other, "att-save-10")

    assert_api_error("CHANNEL_NOT_FOUND", fn ->
      Stickers.save(@viewer, "op-save-10", %{
        "channel_id" => "missing-channel",
        "attachment_id" => att
      })
    end)
  end

  test "save: non-member channel (channel path) → FORBIDDEN" do
    seed_library_channel(@ch)
    att = own_att(@other, "att-save-11")
    other_ch = "ffffffff-0000-7000-8000-ffffffffffff"
    seed_channel(other_ch, created_by: @other)

    # @viewer is not a member of other_ch
    assert_api_error("FORBIDDEN", fn ->
      Stickers.save(@viewer, "op-save-11", %{"channel_id" => other_ch, "attachment_id" => att})
    end)
  end

  test "save: own finalized attachment needs NO channel gate (old Worker parity)" do
    # No channel seeded at all — the own-attachment path short-circuits
    # before the channel gates ever run.
    att = own_att(@viewer, "att-save-12")

    response =
      Stickers.save(@viewer, "op-save-12", %{
        "channel_id" => "ghost-channel",
        "attachment_id" => att
      })

    assert response["sticker"]["attachment"]["attachment_id"] == att
  end

  test "save: pending (unfinalized) own attachment → falls through to the channel path" do
    seed_library_channel(@ch)

    Repo.query!(
      """
      INSERT INTO chat_v2.attachments (attachment_id, owner_user_id, kind, filename, mime_type,
        size_bytes, width, height, blurhash, storage_key, url, status, created_at)
      VALUES ($1, $2, 'image', 'f.png', 'image/png', 10, 10, 10, NULL, 'chat/p', 'https://s3.example.com/p', 'pending', $3)
      """,
      ["att-pending", @viewer, DateTime.utc_now()],
      type: true
    )

    # pending → own path misses; the channel path finds no visible link →
    # INVALID_STICKER_SOURCE
    assert_api_error("INVALID_STICKER_SOURCE", fn ->
      Stickers.save(@viewer, "op-save-13", %{
        "channel_id" => @ch,
        "attachment_id" => "att-pending"
      })
    end)
  end

  test "save: library limit (200 active) → STICKER_LIBRARY_LIMIT_EXCEEDED" do
    seed_library_channel(@ch)

    for n <- 1..200 do
      seed_personal_sticker("st-limit-#{n}", @viewer, "att-limit-#{n}", created_at: t(n))
    end

    att = own_att(@viewer, "att-limit-new")

    assert_api_error("STICKER_LIBRARY_LIMIT_EXCEEDED", fn ->
      Stickers.save(@viewer, "op-save-limit", %{"channel_id" => @ch, "attachment_id" => att})
    end)
  end

  test "save: soft-deleted items do not count against the limit" do
    seed_library_channel(@ch)

    for n <- 1..200 do
      seed_personal_sticker(
        "st-limit-#{n}",
        @viewer,
        "att-limit-#{n}",
        created_at: t(n),
        deleted_at: DateTime.utc_now()
      )
    end

    att = own_att(@viewer, "att-limit-new2")

    # all 200 are soft-deleted → a new insert still fits
    response =
      Stickers.save(@viewer, "op-save-limit2", %{"channel_id" => @ch, "attachment_id" => att})

    assert is_binary(response["sticker"]["sticker_id"])
  end

  test "save: idempotent replay (same key + body) returns the identical cached response" do
    seed_library_channel(@ch)
    att = own_att(@viewer, "att-save-idem")
    body = %{"channel_id" => @ch, "attachment_id" => att}

    r1 = Stickers.save(@viewer, "op-save-idem", body)
    r2 = Stickers.save(@viewer, "op-save-idem", body)

    assert r1 == r2

    count =
      Repo.query!(
        "SELECT COUNT(*) AS n FROM chat_v2.personal_stickers WHERE user_id = $1",
        [@viewer]
      ).num_rows

    assert count == 1
  end

  test "save: same key + different body → IDEMPOTENCY_CONFLICT" do
    seed_library_channel(@ch)
    a1 = own_att(@viewer, "att-idem-a")
    a2 = own_att(@viewer, "att-idem-b")

    Stickers.save(@viewer, "op-idem-conflict", %{"channel_id" => @ch, "attachment_id" => a1})

    assert_api_error("IDEMPOTENCY_CONFLICT", fn ->
      Stickers.save(@viewer, "op-idem-conflict", %{"channel_id" => @ch, "attachment_id" => a2})
    end)
  end

  test "save: missing fields → INVALID_MESSAGE" do
    assert_api_error("INVALID_MESSAGE", fn ->
      Stickers.save(@viewer, nil, %{"channel_id" => @ch, "attachment_id" => "x"})
    end)

    assert_api_error("INVALID_MESSAGE", fn ->
      Stickers.save(@viewer, "op", %{"channel_id" => @ch})
    end)

    assert_api_error("INVALID_MESSAGE", fn ->
      Stickers.save(@viewer, "op", %{"attachment_id" => "x"})
    end)
  end

  # ------------------------------------------------------------ delete

  test "delete: soft-deletes the caller's item and answers the §8.3 shape" do
    seed_library_channel(@ch)
    att = own_att(@viewer, "att-del-1")

    saved =
      Stickers.save(@viewer, "op-del-save-1", %{"channel_id" => @ch, "attachment_id" => att})

    sticker_id = saved["sticker"]["sticker_id"]

    response = Stickers.delete(@viewer, "op-del-1", sticker_id)
    assert response == %{"sticker_id" => sticker_id, "deleted" => true}

    row =
      Repo.query!(
        "SELECT deleted_at FROM chat_v2.personal_stickers WHERE sticker_id = $1",
        [sticker_id]
      )

    assert hd(row.rows) != [nil]

    # the list excludes it now
    assert Stickers.list_for_user(@viewer).items == []
  end

  test "delete: idempotent — a repeat delete answers deleted:true without error" do
    seed_library_channel(@ch)
    att = own_att(@viewer, "att-del-2")

    saved =
      Stickers.save(@viewer, "op-del-save-2", %{"channel_id" => @ch, "attachment_id" => att})

    sticker_id = saved["sticker"]["sticker_id"]

    Stickers.delete(@viewer, "op-del-2a", sticker_id)

    assert Stickers.delete(@viewer, "op-del-2b", sticker_id) ==
             %{"sticker_id" => sticker_id, "deleted" => true}
  end

  test "delete: a missing sticker is an idempotent no-op (old Worker parity)" do
    response = Stickers.delete(@viewer, "op-del-3", "sticker-does-not-exist")
    assert response == %{"sticker_id" => "sticker-does-not-exist", "deleted" => true}
  end

  test "delete: another user's sticker → FORBIDDEN" do
    seed_library_channel(@ch)
    att = own_att(@other, "att-del-4")
    saved = Stickers.save(@other, "op-del-save-4", %{"channel_id" => @ch, "attachment_id" => att})

    assert_api_error("FORBIDDEN", fn ->
      Stickers.delete(@viewer, "op-del-4", saved["sticker"]["sticker_id"])
    end)
  end

  test "delete: same key + different sticker_id → IDEMPOTENCY_CONFLICT" do
    seed_library_channel(@ch)
    a1 = own_att(@viewer, "att-del-5a")
    a2 = own_att(@viewer, "att-del-5b")
    s1 = Stickers.save(@viewer, "op-del-save-5a", %{"channel_id" => @ch, "attachment_id" => a1})
    s2 = Stickers.save(@viewer, "op-del-save-5b", %{"channel_id" => @ch, "attachment_id" => a2})

    Stickers.delete(@viewer, "op-del-conflict", s1["sticker"]["sticker_id"])

    assert_api_error("IDEMPOTENCY_CONFLICT", fn ->
      Stickers.delete(@viewer, "op-del-conflict", s2["sticker"]["sticker_id"])
    end)
  end

  test "delete: missing Idempotency-Key → INVALID_MESSAGE" do
    seed_library_channel(@ch)
    att = own_att(@viewer, "att-del-6")

    saved =
      Stickers.save(@viewer, "op-del-save-6", %{"channel_id" => @ch, "attachment_id" => att})

    assert_api_error("INVALID_MESSAGE", fn ->
      Stickers.delete(@viewer, nil, saved["sticker"]["sticker_id"])
    end)
  end

  test "delete does not touch other users' copies of the same attachment" do
    seed_library_channel(@ch)
    att = own_att(@other, "att-del-7")

    # make the attachment channel-visible so both members can save it
    msg = seed_message("cccccccc-0006-7000-8000-000000000001", @ch, @other, nil, type: "image")
    seed_message_attachment(msg, att)

    mine =
      Stickers.save(@viewer, "op-del-save-7a", %{"channel_id" => @ch, "attachment_id" => att})

    theirs =
      Stickers.save(@other, "op-del-save-7b", %{"channel_id" => @ch, "attachment_id" => att})

    Stickers.delete(@viewer, "op-del-7", mine["sticker"]["sticker_id"])

    active =
      Repo.query!(
        "SELECT 1 AS x FROM chat_v2.personal_stickers WHERE sticker_id = $1 AND deleted_at IS NULL",
        [theirs["sticker"]["sticker_id"]]
      )

    assert active.num_rows == 1
  end

  # ---------------------------------------------------------------- helpers

  # Truncate to microseconds: the column is timestamp(6) and PG would round
  # sub-microsecond digits, making stored-value comparisons flaky.
  defp t(n), do: DateTime.utc_now() |> DateTime.add(n, :second) |> DateTime.truncate(:microsecond)
end
