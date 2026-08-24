defmodule LiliumChat.TimelineTest do
  @moduledoc """
  Domain tests for `LiliumChat.Timeline` (contract §6.1 / §6.1b / §6.6 / §10.3,
  issue #6): replay re-projection, the A9 deleted/recalled safe projection,
  pagination cursors, and the A12 "reads are strictly read-only" guarantee.
  """

  use LiliumChat.DataCase, async: false

  import LiliumChatWeb.ReadFixtures

  alias LiliumChat.Errors
  alias LiliumChat.Observability.ReadPath
  alias LiliumChat.Timeline

  @viewer "11111111-1111-7111-8111-111111111111"
  @other "22222222-2222-7222-8222-222222222222"

  # ---------------------------------------------------------- messages page

  test "messages_page projects message events to the full EventFrame wire shape" do
    ch = "aaaaaaaa-0000-7000-8000-aaaaaaaaaaaa"
    seed_channel(ch, title: "Alpha", created_by: @viewer)
    seed_membership(ch, @viewer, "member")
    seed_membership(ch, @other, "member")
    seed_profile(@other, "Alice O'Hara", "https://cdn.example.com/alice.png")

    m1 =
      seed_message("aaaaaaaa-0001-7000-8000-000000000001", ch, @other, "hello world",
        event_id: eid(1),
        created_at: t(1)
      )

    _m2 =
      seed_message("aaaaaaaa-0002-7000-8000-000000000002", ch, @viewer, "hi back",
        event_id: eid(2),
        created_at: t(2)
      )

    page = Timeline.messages_page(@viewer, ch, %{})
    assert page.next_cursor == nil
    assert length(page.items) == 2

    # ascending (oldest first)
    assert Enum.map(page.items, & &1["event_id"]) == [eid(1), eid(2)]

    frame = hd(page.items)
    assert frame["frame_type"] == "event"
    assert frame["api_version"] == "lilium.chat.v1"
    assert frame["event_id"] == eid(1)
    assert frame["type"] == "message.created"
    assert frame["channel_id"] == ch
    assert frame["occurred_at"] != nil
    assert is_map(frame["payload"]["message"])

    message = frame["payload"]["message"]
    assert message["message_id"] == m1
    assert message["text"] == "hello world"
    assert message["status"] == "normal"
    assert message["sender"]["kind"] == "user"
    assert message["sender"]["user"]["display_name"] == "Alice O'Hara"
    assert message["sender"]["user"]["avatar_url"] == "https://cdn.example.com/alice.png"
    # full message wire surface
    assert Map.has_key?(message, "command_id")
    assert Map.has_key?(message, "attachments")
    assert message["attachments"] == []
    assert Map.has_key?(message, "reply_snapshot")
    assert Map.has_key?(message, "mentions")
  end

  test "messages_page suppresses message.created for deleted/recalled messages (A9)" do
    ch = "bbbbbbbb-0000-7000-8000-bbbbbbbbbbbb"
    seed_channel(ch, created_by: @viewer)
    seed_membership(ch, @viewer, "member")

    seed_message("bbbbbbbb-0001-7000-8000-000000000001", ch, @viewer, "keep me",
      event_id: eid(1),
      created_at: t(1)
    )

    seed_message("bbbbbbbb-0002-7000-8000-000000000002", ch, @viewer, "gone",
      event_id: eid(2),
      status: "deleted",
      created_at: t(2)
    )

    seed_message("bbbbbbbb-0003-7000-8000-000000000003", ch, @viewer, "recalled too",
      event_id: eid(3),
      status: "recalled",
      created_at: t(3)
    )

    page = Timeline.messages_page(@viewer, ch, %{})
    ids = Enum.map(page.items, & &1["event_id"])

    # only the visible message.created survives; the deleted/recalled ones drop
    assert ids == [eid(1)]
  end

  test "channel_events applies the safe projection to a message.recalled of a hidden message" do
    ch = "cccccccc-0000-7000-8000-cccccccccccc"
    seed_channel(ch, created_by: @viewer)
    seed_membership(ch, @viewer, "member")

    m =
      seed_message("cccccccc-0001-7000-8000-000000000001", ch, @viewer, "original text",
        event_id: eid(1),
        created_at: t(1)
      )

    set_message_status(m, "recalled")

    seed_event(eid(2), ch, "message.recalled", %{"message" => %{"message_id" => m}},
      actor_kind: "user",
      actor_id: @viewer,
      occurred_at: t(2)
    )

    page = Timeline.channel_events(@viewer, ch, "", 100)
    # the message.created (eid 1) is suppressed — only the recall event remains
    [recalled] = page.events
    assert recalled["event_id"] == eid(2)
    assert recalled["type"] == "message.recalled"

    message = recalled["payload"]["message"]
    assert message["status"] == "recalled"
    assert message["text"] == nil
    assert message["attachments"] == []
    assert message["mentions"] == []
    assert message["command_invocation"] == nil
  end

  # ------------------------------------- attachments/stickers projection (#15)

  test "messages_page projects an image message's attachments" do
    ch = "gggggggg-0000-7000-8000-gggggggggggg"
    seed_channel(ch, created_by: @viewer)
    seed_membership(ch, @viewer, "member")

    att = seed_attachment("att-tl-1", owner_user_id: @other)

    m =
      seed_message("gggggggg-0001-7000-8000-000000000001", ch, @other, nil,
        type: "image",
        event_id: eid(1),
        created_at: t(1)
      )

    seed_message_attachment(m, att)

    page = Timeline.messages_page(@viewer, ch, %{})
    [frame] = page.items
    assert frame["type"] == "message.created"

    message = frame["payload"]["message"]
    assert message["type"] == "image"
    assert message["sticker"] == nil

    assert message["attachments"] == [
             %{
               "attachment_id" => att,
               "url" => "https://s3.example.com/#{att}",
               "mime_type" => "image/png",
               "size_bytes" => 1024,
               "width" => 100,
               "height" => 100,
               "blurhash" => nil
             }
           ]
  end

  test "messages_page projects a sticker message's sticker snapshot" do
    ch = "hhhhhhhh-0000-7000-8000-hhhhhhhhhhhh"
    seed_channel(ch, created_by: @viewer)
    seed_membership(ch, @viewer, "member")

    m =
      seed_message("hhhhhhhh-0001-7000-8000-000000000001", ch, @other, nil,
        type: "sticker",
        event_id: eid(1),
        created_at: t(1)
      )

    seed_sticker(
      m,
      sticker_id: "st-tl-1",
      attachment_id: "att-tl-2",
      url: "https://s3.example.com/att-tl-2",
      size_bytes: 777
    )

    page = Timeline.messages_page(@viewer, ch, %{})
    [frame] = page.items
    message = frame["payload"]["message"]

    # contract §3.4: the sticker projection carries the sender-side sticker_id
    # AND the canonical attachment_id; attachments=[] to avoid a double render.
    assert message["type"] == "sticker"

    assert message["sticker"] == %{
             "sticker_id" => "st-tl-1",
             "attachment_id" => "att-tl-2",
             "url" => "https://s3.example.com/att-tl-2",
             "mime_type" => "image/png",
             "width" => 64,
             "height" => 64,
             "size_bytes" => 777,
             "blurhash" => nil
           }

    assert message["attachments"] == []
    assert message["mentions"] == []
  end

  test "safe projection: a recalled sticker message clears the sticker field (A9, no content leak)" do
    ch = "iiiiiiii-0000-7000-8000-iiiiiiiiiiii"
    seed_channel(ch, created_by: @viewer)
    seed_membership(ch, @viewer, "member")

    m =
      seed_message("iiiiiiii-0001-7000-8000-000000000001", ch, @viewer, nil,
        type: "sticker",
        event_id: eid(1),
        created_at: t(1)
      )

    seed_sticker(m, sticker_id: "st-tl-3", attachment_id: "att-tl-3")

    set_message_status(m, "recalled")

    seed_event(
      eid(2),
      ch,
      "message.recalled",
      %{"message" => %{"message_id" => m}},
      actor_kind: "user",
      actor_id: @viewer,
      occurred_at: t(2)
    )

    page = Timeline.channel_events(@viewer, ch, "", 100)
    # the message.created (eid 1) is suppressed — only the recall event remains
    [recalled] = page.events
    assert recalled["type"] == "message.recalled"

    message = recalled["payload"]["message"]
    assert message["type"] == "sticker"
    assert message["status"] == "recalled"
    assert message["text"] == nil
    assert message["sticker"] == nil
    assert message["attachments"] == []
    assert message["mentions"] == []
  end

  test "safe projection: a deleted image message clears its attachments (A9)" do
    ch = "jjjjjjjj-0000-7000-8000-jjjjjjjjjjjj"
    seed_channel(ch, created_by: @viewer)
    seed_membership(ch, @viewer, "member")

    att = seed_attachment("att-tl-4", owner_user_id: @viewer)

    m =
      seed_message("jjjjjjjj-0001-7000-8000-000000000001", ch, @viewer, nil,
        type: "image",
        event_id: eid(1),
        created_at: t(1)
      )

    seed_message_attachment(m, att)

    set_message_status(m, "deleted")

    seed_event(
      eid(2),
      ch,
      "message.deleted",
      %{"message" => %{"message_id" => m}},
      actor_kind: "user",
      actor_id: @viewer,
      occurred_at: t(2)
    )

    page = Timeline.channel_events(@viewer, ch, "", 100)
    [deleted] = page.events
    assert deleted["type"] == "message.deleted"

    message = deleted["payload"]["message"]
    assert message["type"] == "image"
    assert message["status"] == "deleted"
    assert message["attachments"] == []
    assert message["sticker"] == nil
  end

  test "messages_page suppresses a deleted sticker message's created event entirely" do
    ch = "kkkkkkkk-0000-7000-8000-kkkkkkkkkkkk"
    seed_channel(ch, created_by: @viewer)
    seed_membership(ch, @viewer, "member")

    m =
      seed_message("kkkkkkkk-0001-7000-8000-000000000001", ch, @viewer, nil,
        type: "sticker",
        event_id: eid(1),
        status: "deleted",
        created_at: t(1)
      )

    seed_sticker(m, sticker_id: "st-tl-4", attachment_id: "att-tl-5")

    # history returns no items at all — no sticker content leaks via history
    page = Timeline.messages_page(@viewer, ch, %{})
    assert page.items == []
  end

  test "messages_page pages with limit + next_cursor" do
    ch = "dddddddd-0000-7000-8000-dddddddddddd"
    seed_channel(ch, created_by: @viewer)
    seed_membership(ch, @viewer, "member")

    for n <- 1..5 do
      seed_message(
        "dddddddd-000#{n}-7000-8000-000000000000",
        ch,
        @viewer,
        "msg #{n}",
        event_id: eid(n),
        created_at: t(n)
      )
    end

    first = Timeline.messages_page(@viewer, ch, %{"limit" => "2"})
    assert length(first.items) == 2
    # default (no cursor) = newest page, ascending
    assert Enum.map(first.items, & &1["event_id"]) == [eid(4), eid(5)]
    assert first.next_cursor == eid(4)

    # page back with before = oldest of the newest page
    second = Timeline.messages_page(@viewer, ch, %{"limit" => "2", "before" => eid(4)})
    assert Enum.map(second.items, & &1["event_id"]) == [eid(2), eid(3)]
    assert second.next_cursor == eid(2)

    third = Timeline.messages_page(@viewer, ch, %{"limit" => "2", "before" => eid(2)})
    assert Enum.map(third.items, & &1["event_id"]) == [eid(1)]
    assert third.next_cursor == nil
  end

  test "messages_page forwards after a cursor (ascending, oldest-after first)" do
    ch = "eeeeeeee-0000-7000-8000-eeeeeeeeeeee"
    seed_channel(ch, created_by: @viewer)
    seed_membership(ch, @viewer, "member")

    for n <- 1..5 do
      seed_message(
        "eeeeeeee-000#{n}-7000-8000-000000000000",
        ch,
        @viewer,
        "msg #{n}",
        event_id: eid(n),
        created_at: t(n)
      )
    end

    page = Timeline.messages_page(@viewer, ch, %{"limit" => "2", "after" => eid(1)})
    assert Enum.map(page.items, & &1["event_id"]) == [eid(2), eid(3)]
    assert page.next_cursor == eid(3)
  end

  # ---------------------------------------------------------- channel events

  test "channel_events returns all event types with latest_event_id + next_cursor" do
    ch = "aaaaaaaa-0000-7000-8000-aaaaaaaaaaaa"
    seed_channel(ch, created_by: @viewer)
    seed_membership(ch, @viewer, "member")
    seed_membership(ch, @other, "member")
    seed_profile(@other, "Alice", nil)

    seed_message("aaaaaaaa-0001-7000-8000-000000000001", ch, @other, "msg",
      event_id: eid(1),
      created_at: t(1)
    )

    # a non-message (management) event — included in full event replay
    seed_event(
      eid(2),
      ch,
      "member.joined",
      %{
        "channel_id" => ch,
        "actor_kind" => "user",
        "actor_id" => @other,
        "target_user_id" => @other
      },
      occurred_at: t(2)
    )

    page = Timeline.channel_events(@viewer, ch, "", 100)

    assert Enum.map(page.events, & &1["event_id"]) == [eid(1), eid(2)]
    assert page.latest_event_id == eid(2)
    assert page.next_cursor == nil

    # the member.joined payload has actor resolved to a UserSummary
    [_, joined] = page.events
    assert joined["type"] == "member.joined"
    assert joined["payload"]["actor"]["user_id"] == @other
    assert joined["payload"]["actor"]["display_name"] == "Alice"
    # raw refs are stripped and replaced by resolved UserSummaries (§10.3)
    assert joined["payload"]["target_user"]["user_id"] == @other
    refute Map.has_key?(joined["payload"], "actor_kind")
    refute Map.has_key?(joined["payload"], "actor_id")
    refute Map.has_key?(joined["payload"], "target_user_id")
  end

  test "channel_events latest_event_id falls back to the channel max when page is empty" do
    ch = "bbbbbbbb-0000-7000-8000-bbbbbbbbbbbb"
    seed_channel(ch, created_by: @viewer)
    seed_membership(ch, @viewer, "member")

    seed_message("bbbbbbbb-0001-7000-8000-000000000001", ch, @viewer, "only",
      event_id: eid(1),
      created_at: t(1)
    )

    # cursor past the newest → empty page
    page = Timeline.channel_events(@viewer, ch, eid(1), 100)
    assert page.events == []
    assert page.latest_event_id == eid(1)
  end

  test "channel_events pages forward (ascending) from the earliest, truncated (§6.1b)" do
    ch = "eeeeeeee-0000-7000-8000-eeeeeeeeeeee"
    seed_channel(ch, created_by: @viewer)
    seed_membership(ch, @viewer, "member")

    for n <- 1..4 do
      seed_event(
        eid(n),
        ch,
        "member.joined",
        %{
          "channel_id" => ch,
          "actor_kind" => "user",
          "actor_id" => @viewer
        },
        occurred_at: t(n)
      )
    end

    # no cursor → starts at the EARLIEST event, ascending, truncated to `limit`
    page = Timeline.channel_events(@viewer, ch, "", 2)
    assert Enum.map(page.events, & &1["event_id"]) == [eid(1), eid(2)]
    # next_cursor = newest of the returned page (so a client can continue forward)
    assert page.next_cursor == eid(2)

    # continue from the cursor → the next forward page
    rest = Timeline.channel_events(@viewer, ch, eid(2), 100)
    assert Enum.map(rest.events, & &1["event_id"]) == [eid(3), eid(4)]
    assert rest.next_cursor == nil
  end

  # ---------------------------------------------------------- global events

  test "global_events merges per-channel frames + last_event_id_per_channel" do
    ch_a = "aaaaaaaa-0000-7000-8000-aaaaaaaaaaaa"
    ch_b = "bbbbbbbb-0000-7000-8000-bbbbbbbbbbbb"

    for ch <- [ch_a, ch_b] do
      seed_channel(ch, created_by: @viewer)
      seed_membership(ch, @viewer, "member")
    end

    # distinct globally-unique event ids per channel (events_pkey is global)
    seed_message("aaaaaaaa-0001-7000-8000-000000000001", ch_a, @viewer, "in a",
      event_id: eid(1),
      created_at: t(1)
    )

    seed_message("bbbbbbbb-0001-7000-8000-000000000001", ch_b, @viewer, "in b",
      event_id: eid(100),
      created_at: t(1)
    )

    body = Timeline.global_events(@viewer, [{ch_a, ""}, {ch_b, ""}])
    assert body.next_cursor == nil
    assert length(body.items) == 2
    assert body.last_event_id_per_channel == %{ch_a => eid(1), ch_b => eid(100)}
  end

  test "global_events excludes channels the user cannot see (private non-member)" do
    # private channel the viewer is NOT a member of → excluded
    private = "cccccccc-0000-7000-8000-cccccccccccc"
    seed_channel(private, visibility: "private", created_by: @other)

    seed_event(
      eid(1),
      private,
      "member.joined",
      %{
        "channel_id" => private,
        "actor_kind" => "user",
        "actor_id" => @other
      },
      occurred_at: t(1)
    )

    # public channel with no explicit membership → still visible
    pub = "dddddddd-0000-7000-8000-dddddddddddd"
    seed_channel(pub, visibility: "public", created_by: @other)

    seed_event(
      eid(100),
      pub,
      "member.joined",
      %{
        "channel_id" => pub,
        "actor_kind" => "user",
        "actor_id" => @other
      },
      occurred_at: t(1)
    )

    body = Timeline.global_events(@viewer, [{private, ""}, {pub, ""}])
    # only the public channel's event is projected
    assert [only] = body.items
    assert only["channel_id"] == pub
    assert body.last_event_id_per_channel == %{pub => eid(100)}
  end

  # ---------------------------------------------------------- message context

  test "message_context returns an anchor window around a message" do
    ch = "cccccccc-0000-7000-8000-cccccccccccc"
    seed_channel(ch, created_by: @viewer)
    seed_membership(ch, @viewer, "member")

    for n <- 1..3 do
      seed_message(
        "cccccccc-000#{n}-7000-8000-000000000000",
        ch,
        @viewer,
        "msg #{n}",
        event_id: eid(n),
        created_at: t(n)
      )
    end

    anchor_id = "cccccccc-0002-7000-8000-000000000000"
    body = Timeline.message_context(@viewer, ch, anchor_id, %{"before" => "1", "after" => "1"})

    assert body.anchor_message_id == anchor_id
    ids = Enum.map(body.items, & &1["event_id"])
    # before (eid 1) + anchor (eid 2) + after (eid 3)
    assert ids == [eid(1), eid(2), eid(3)]
  end

  test "message_context raises MESSAGE_NOT_FOUND for a deleted anchor" do
    ch = "dddddddd-0000-7000-8000-dddddddddddd"
    seed_channel(ch, created_by: @viewer)
    seed_membership(ch, @viewer, "member")

    m =
      seed_message("dddddddd-0001-7000-8000-000000000001", ch, @viewer, "x",
        event_id: eid(1),
        status: "deleted",
        created_at: t(1)
      )

    error =
      assert_raise Errors.ApiError, fn ->
        Timeline.message_context(@viewer, ch, m, %{})
      end

    assert error.code == "MESSAGE_NOT_FOUND"
  end

  test "message_context raises MESSAGE_NOT_FOUND for a missing message" do
    ch = "eeeeeeee-0000-7000-8000-eeeeeeeeeeee"
    seed_channel(ch, created_by: @viewer)
    seed_membership(ch, @viewer, "member")

    error =
      assert_raise Errors.ApiError, fn ->
        Timeline.message_context(@viewer, ch, "eeeeeeee-9999-7999-8999-999999999999", %{})
      end

    assert error.code == "MESSAGE_NOT_FOUND"
  end

  # ---------------------------------------------------------- A12 read-only

  test "the read path executes no writes (A12)" do
    ch = "aaaaaaaa-0000-7000-8000-aaaaaaaaaaaa"
    seed_channel(ch, created_by: @viewer)
    seed_membership(ch, @viewer, "member")

    seed_message("aaaaaaaa-0001-7000-8000-000000000001", ch, @viewer, "hi",
      event_id: eid(1),
      created_at: t(1)
    )

    assert {:ok, %{reads: reads, writes: 0}} =
             ReadPath.assert_read_only!(
               fn ->
                 Timeline.messages_page(@viewer, ch, %{})
                 Timeline.channel_events(@viewer, ch, "", 100)
                 Timeline.global_events(@viewer, [{ch, ""}])
               end,
               "GET /api/chat/channels/* (read path)"
             )

    assert reads > 0
  end

  # ------------------------------------------------ bot messages (#19)

  test "messages_page replays bot messages with components + bot summary" do
    ch = "cccccccc-0000-7000-8000-cccccccccccc"
    bot_id = "bot-tl-0001"
    seed_channel(ch, created_by: @viewer)
    seed_membership(ch, @viewer, "member")
    seed_profile(@viewer, "Viewer", nil)

    # The read path resolves bot summaries live from bot_apps.
    Repo.query!(
      "INSERT INTO chat_v2.bot_apps (bot_id, owner_user_id, display_name, avatar_url, " <>
        "description, visibility, status, created_at, updated_at) " <>
        "VALUES ($1, 'owner', 'Kuma Bot', 'https://cdn.example.com/kuma.png', NULL, " <>
        "'official', 'active', now(), now())",
      [bot_id],
      type: true
    )

    message_id = "cccccccc-0001-7000-8000-0000000000c1"
    event_id = eid(1)
    now = t(1)

    Repo.query!(
      """
      INSERT INTO chat_v2.messages (message_id, command_id, dedupe_principal_key, channel_id,
        sender_kind, sender_user_id, sender_bot_id, type, format, status, text, reply_to,
        reply_snapshot_json, components_json, stream_state, invocation_json,
        created_at, updated_at, event_id)
      VALUES ($1, $2, $3, $4, 'bot', NULL, $5, 'text', 'markdown', 'normal', 'pick one',
        NULL, NULL, $6, 'none', NULL, $7, $7, $8)
      """,
      [
        message_id,
        Ecto.UUID.generate(),
        "bot:#{bot_id}",
        ch,
        bot_id,
        Jason.encode!([
          %{
            "component_id" => "c-1",
            "kind" => "button",
            "custom_id" => "yes",
            "label" => "Yes"
          }
        ]),
        now,
        event_id
      ],
      type: true
    )

    seed_event(
      event_id,
      ch,
      "message.created",
      %{"message" => %{"message_id" => message_id}},
      actor_kind: "bot",
      actor_id: bot_id,
      occurred_at: now
    )

    page = Timeline.messages_page(@viewer, ch, %{})
    assert length(page.items) == 1

    frame = hd(page.items)
    assert frame["type"] == "message.created"
    message = frame["payload"]["message"]

    # components round-trip from messages.components_json (contract §3.8)
    assert message["components"] == [
             %{
               "component_id" => "c-1",
               "kind" => "button",
               "custom_id" => "yes",
               "label" => "Yes"
             }
           ]

    # the bot sender carries the bot_apps summary (contract §3.4)
    assert message["sender"] == %{
             "kind" => "bot",
             "bot" => %{
               "bot_id" => bot_id,
               "display_name" => "Kuma Bot",
               "avatar_url" => "https://cdn.example.com/kuma.png"
             }
           }
  end

  # ------------------------------------------------------------- helpers

  defp t(n), do: DateTime.utc_now() |> DateTime.add(n, :second)

  defp set_message_status(message_id, status) do
    Repo.query!(
      "UPDATE chat_v2.messages SET status = $2 WHERE message_id = $1",
      [message_id, status],
      type: true
    )
  end
end
