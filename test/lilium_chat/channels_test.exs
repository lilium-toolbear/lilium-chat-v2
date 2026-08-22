defmodule LiliumChat.ChannelsTest do
  @moduledoc """
  Domain tests for `LiliumChat.Channels` (contract §5, issue #6): the
  `GET /api/chat/channels` list and `GET /api/chat/channels/{id}` detail,
  wire shape, membership filtering, preview, pins, and error codes.
  """

  use LiliumChat.DataCase, async: false

  import LiliumChatWeb.ReadFixtures

  alias LiliumChat.Channels
  alias LiliumChat.Errors

  @viewer "11111111-1111-7111-8111-111111111111"
  @other "22222222-2222-7222-8222-222222222222"

  test "list_for_user returns ChannelSummaryApi rows for active memberships only" do
    ch_a = "aaaaaaaa-0000-7000-8000-aaaaaaaaaaaa"
    ch_b = "bbbbbbbb-0000-7000-8000-bbbbbbbbbbbb"
    ch_left = "cccccccc-0000-7000-8000-cccccccccccc"

    seed_channel(ch_a, title: "Alpha", created_by: @viewer, member_count: 2)
    seed_membership(ch_a, @viewer, "admin")
    seed_membership(ch_a, @other, "member")
    seed_profile(@other, "Alice O'Hara", "https://cdn.example.com/alice.png")

    seed_message("aaaaaaaa-0001-7000-8000-000000000001", ch_a, @other, "hello alpha",
      event_id: eid(1),
      created_at: t(1)
    )

    seed_channel(ch_b, title: "Bravo", created_by: @viewer)
    seed_membership(ch_b, @viewer, "member")

    seed_channel(ch_left, title: "Charlie (left)", created_by: @viewer)
    seed_membership(ch_left, @viewer, "member", status: "left")

    items = Channels.list_for_user(@viewer)
    ids = Enum.map(items, & &1["channel_id"])

    assert ch_a in ids
    assert ch_b in ids
    refute ch_left in ids

    alpha = Enum.find(items, &(&1["channel_id"] == ch_a))
    assert alpha["title"] == "Alpha"
    assert alpha["role"] == "admin"
    assert alpha["visibility"] == "private"
    assert alpha["kind"] == "channel"
    assert alpha["member_count"] == 2
    assert alpha["last_message_preview"] == "Alice O'Hara: hello alpha"
    assert alpha["last_message_at"] != nil
    assert alpha["last_event_id"] == eid(1)
    assert alpha["unread_count"] == 0
    # full ChannelSummaryApi surface
    assert Map.has_key?(alpha, "last_read_event_id")
    assert Map.has_key?(alpha, "topic")
    assert Map.has_key?(alpha, "status")
  end

  test "list_for_user counts unread messages created after the read cursor" do
    ch = "dddddddd-0000-7000-8000-dddddddddddd"
    seed_channel(ch, title: "Delta", created_by: @viewer)
    seed_membership(ch, @viewer, "member")

    seed_message("dddddddd-0001-7000-8000-000000000001", ch, @viewer, "one",
      event_id: eid(1),
      created_at: t(1)
    )

    seed_message("dddddddd-0002-7000-8000-000000000002", ch, @viewer, "two",
      event_id: eid(2),
      created_at: t(2)
    )

    seed_message("dddddddd-0003-7000-8000-000000000003", ch, @viewer, "three",
      event_id: eid(3),
      created_at: t(3)
    )

    # read cursor before everything → all 3 message.created events are unread
    seed_read_state(@viewer, ch, eid(0))

    [%{"channel_id" => ^ch, "unread_count" => unread}] = Channels.list_for_user(@viewer)
    assert unread == 3

    # read up to eid(2) → only the newest (eid 3) is unread
    seed_read_state(@viewer, ch, eid(2))
    [%{"channel_id" => ^ch, "unread_count" => unread2}] = Channels.list_for_user(@viewer)
    assert unread2 == 1
  end

  test "list_for_user resolves a missing profile to the user-<id> fallback preview name" do
    ch = "eeeeeeee-0000-7000-8000-eeeeeeeeeeee"
    seed_channel(ch, title: "Echo", created_by: @viewer)
    seed_membership(ch, @viewer, "member")

    sender = "9f8e7d6c-1234-7abc-9def-0a1b2c3d4e5f"

    seed_message("eeeeeeee-0001-7000-8000-000000000001", ch, sender, "hi",
      event_id: eid(1),
      created_at: t(1)
    )

    [%{"channel_id" => ^ch, "last_message_preview" => preview}] = Channels.list_for_user(@viewer)
    assert preview == "user-9f8e7d6c: hi"
  end

  test "detail returns the channel summary + pins for a member" do
    ch = "aaaaaaaa-0000-7000-8000-aaaaaaaaaaaa"
    seed_channel(ch, title: "Alpha", created_by: @viewer, topic: "team room")
    seed_membership(ch, @viewer, "admin")

    message_id = "aaaaaaaa-0002-7000-8000-000000000002"
    seed_message(message_id, ch, @viewer, "pinned message", event_id: eid(1), created_at: t(1))

    seed_pin(ch, message_id)

    %{channel: channel, channel_pins: pins} = Channels.detail(@viewer, ch)

    assert channel["channel_id"] == ch
    assert channel["title"] == "Alpha"
    assert channel["topic"] == "team room"
    assert channel["role"] == "admin"
    assert channel["last_message_preview"] =~ "pinned message"
    assert length(pins) == 1
    pin = hd(pins)
    assert pin["source_message_id"] == message_id
    assert pin["pin_kind"] == "message"
    # §3.10.3 wire shape: pinned_by is a resolved UserSummary, message is the
    # projection, and the internal raw/storage keys are not on the wire.
    assert pin["pinned_by"]["user_id"] == @viewer
    assert is_map(pin["message"])
    refute Map.has_key?(pin, "pinned_by_user_id")
    refute Map.has_key?(pin, "message_projection")
    refute Map.has_key?(pin, "created_at")
    refute Map.has_key?(pin, "updated_at")
  end

  test "detail raises CHANNEL_NOT_FOUND for a missing channel" do
    error =
      assert_raise Errors.ApiError, fn ->
        Channels.detail(@viewer, "ffffffff-0000-7000-8000-ffffffffffff")
      end

    assert error.code == "CHANNEL_NOT_FOUND"
    assert error.http_status == 404
  end

  test "detail raises FORBIDDEN for a private channel with no membership" do
    ch = "aaaaaaaa-0000-7000-8000-aaaaaaaaaaaa"
    seed_channel(ch, title: "Alpha", visibility: "private", created_by: @other)
    # viewer is NOT a member

    error =
      assert_raise Errors.ApiError, fn ->
        Channels.detail(@viewer, ch)
      end

    assert error.code == "FORBIDDEN"
    assert error.http_status == 403
  end

  # ------------------------------------------------------------- helpers

  defp t(n), do: DateTime.utc_now() |> DateTime.add(n, :second)

  defp seed_pin(channel_id, source_message_id) do
    now = DateTime.utc_now()

    Repo.query!(
      """
      INSERT INTO chat_v2.channel_pins (pin_id, channel_id, pin_kind, pin_owner_kind,
        pin_owner_id, priority, source_message_id, pinned_by_user_id, pinned_at,
        last_pin_event_id, message_projection_json, created_at, updated_at)
      VALUES ($1, $2, 'message', 'user', $3, 0, $4, $3, $5, $6, '{}', $5, $5)
      """,
      [Ecto.UUID.generate(), channel_id, @viewer, source_message_id, now, Ecto.UUID.generate()],
      type: true
    )
  end
end
