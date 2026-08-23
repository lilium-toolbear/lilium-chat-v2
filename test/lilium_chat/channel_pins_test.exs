defmodule LiliumChat.ChannelPinsTest do
  @moduledoc """
  `channel.pin_message` / `channel.unpin_message` write-path tests
  (issue #10, contract §6.7 / §3.10, spec A7/A8).

  Process-level tests driven through the per-channel writer process
  (`LiliumChat.Channel.pin_message/2` / `unpin_message/2`): ack + event
  wire shapes, no-op re-pin, owner/admin gates, pin limit, idempotency.
  """

  use LiliumChat.DataCase, async: false

  import LiliumChatWeb.ReadFixtures

  alias LiliumChat.{Channel, Errors, Query, Repo}

  @uid "6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e6f"
  @other "7a2f3d4e-5b6c-8d9e-0f1a-2b3c4d5e6f70"

  # ----------------------------------------------------------------- helpers

  defp channel!(role \\ "owner") do
    cid = "ch-pin-" <> Ecto.UUID.generate()
    seed_channel(cid, kind: "channel", visibility: "private", status: "active")
    seed_membership(cid, @uid, role)
    cid
  end

  defp dm_channel! do
    cid = "ch-pin-dm-" <> Ecto.UUID.generate()
    seed_channel(cid, kind: "dm", visibility: "private", status: "active")
    seed_membership(cid, @uid, "owner")
    cid
  end

  defp pin!(channel_id, command_id, source_message_id),
    do:
      Channel.pin_message(
        channel_id,
        %{
          user_id: @uid,
          command_id: command_id,
          payload: %{"source_message_id" => source_message_id}
        }
      )

  defp unpin!(channel_id, command_id, payload),
    do:
      Channel.unpin_message(
        channel_id,
        %{user_id: @uid, command_id: command_id, payload: payload}
      )

  defp events(channel_id) do
    Query.rows(
      Repo.query(
        "SELECT event_id, event_type, actor_kind, actor_id, payload " <>
          "FROM chat_v2.events WHERE channel_id = $1 ORDER BY event_id",
        [channel_id],
        type: true
      )
    )
  end

  defp pins(channel_id) do
    Query.rows(
      Repo.query(
        "SELECT pin_id, pin_kind, pin_owner_kind, pin_owner_id, priority, pinned_by_user_id, " <>
          "last_pin_event_id, message_projection_json " <>
          "FROM chat_v2.channel_pins WHERE channel_id = $1 ORDER BY pin_id",
        [channel_id],
        type: true
      )
    )
  end

  # ------------------------------------------------------- pin_message

  test "pin → committed ack with ChannelPin wire + channel.pin.set event + row" do
    cid = channel!()
    mid = seed_message("msg-p001", cid, @uid, "pin me")

    {:ok, ack} = pin!(cid, "cmd-p001", mid)

    assert ack["frame_type"] == "command_ack"
    assert ack["command"] == "channel.pin_message"
    assert ack["status"] == "committed"
    assert ack["payload"]["channel_id"] == cid
    assert is_binary(ack["payload"]["event_id"])

    pin = ack["payload"]["pin"]
    assert pin["pin_id"]
    assert pin["channel_id"] == cid
    assert pin["pin_kind"] == "pinned_message"
    assert pin["pin_owner_kind"] == "user"
    assert pin["pin_owner_id"] == @uid
    assert pin["priority"] == 10
    assert pin["session_id"] == nil
    assert pin["source_message_id"] == mid

    assert pin["pinned_by"] == %{
             "user_id" => @uid,
             "display_name" => "user-6f1e2c3d",
             "avatar_url" => nil
           }

    assert pin["pinned_at"]
    assert pin["expires_at"] == nil
    assert pin["last_pin_event_id"] == ack["payload"]["event_id"]

    # PinMessageProjection (§3.10): sender summary + text snapshot
    projection = pin["message"]
    assert is_binary(projection["projection_id"])
    assert projection["channel_id"] == cid
    assert projection["sender"]["kind"] == "user"
    assert projection["sender"]["user"]["user_id"] == @uid
    assert projection["type"] == "text"
    assert projection["format"] == "plain"
    assert projection["text"] == "pin me"
    assert projection["components"] == []
    assert is_binary(projection["created_at"])
    assert is_binary(projection["updated_at"])

    # timeline event: channel.pin.set, actor system, full wire payload
    [event] = Enum.filter(events(cid), &(&1["event_type"] == "channel.pin.set"))
    assert event["event_id"] == ack["payload"]["event_id"]
    assert event["actor_kind"] == "system"
    assert event["payload"]["pin"]["pin_id"] == pin["pin_id"]
    assert event["payload"]["pin"]["message"]["text"] == "pin me"

    # AC4: the pin does NOT enter `messages` pagination
    [%{"count" => msg_count}] =
      Query.rows(
        Repo.query("SELECT COUNT(*) AS count FROM chat_v2.messages WHERE channel_id = $1", [cid])
      )

    assert msg_count == 1

    [row] = pins(cid)
    assert row["pinned_by_user_id"] == @uid
    assert row["last_pin_event_id"] == ack["payload"]["event_id"]
  end

  test "duplicate pin (different command_id, unchanged source) → no-op, no new event" do
    cid = channel!()
    mid = seed_message("msg-p002", cid, @uid, "once")

    {:ok, ack1} = pin!(cid, "cmd-p002a", mid)
    {:ok, ack2} = pin!(cid, "cmd-p002b", mid)

    # the no-op ack carries the EXISTING pin's last_pin_event_id (§6.7.1)
    assert ack2["payload"]["event_id"] == ack1["payload"]["event_id"]
    assert ack2["payload"]["pin"]["pin_id"] == ack1["payload"]["pin"]["pin_id"]

    set_events = Enum.filter(events(cid), &(&1["event_type"] == "channel.pin.set"))
    assert length(set_events) == 1

    # idempotency row for the new command_id is committed (no error, no event)
    pin_rows = pins(cid)
    assert length(pin_rows) == 1
  end

  # ----------------------------------------------------------- gates

  test "pin gates: member role → PIN_FORBIDDEN; non-member → FORBIDDEN; DM → UNSUPPORTED_CHANNEL_KIND" do
    # plain member
    member_cid = "ch-pin-role"
    seed_channel(member_cid, kind: "channel", visibility: "private", status: "active")
    seed_membership(member_cid, @uid, "member")
    mid = seed_message("msg-p003", member_cid, @uid, "hi")

    assert {:error,
            %Errors.ApiError{
              code: "PIN_FORBIDDEN",
              message: "only owner or admin can pin messages"
            }} =
             pin!(member_cid, "cmd-p003", mid)

    # non-member
    nm_cid = "ch-pin-nm"
    seed_channel(nm_cid, kind: "channel", visibility: "private", status: "active")
    seed_membership(nm_cid, @other, "member")
    mid2 = seed_message("msg-p004", nm_cid, @other, "hi")

    assert {:error, %Errors.ApiError{code: "FORBIDDEN", message: "not a channel member"}} =
             pin!(nm_cid, "cmd-p004", mid2)

    # DM channel
    dm_cid = dm_channel!()
    mid3 = seed_message("msg-p005", dm_cid, @uid, "dm")

    assert {:error,
            %Errors.ApiError{
              code: "UNSUPPORTED_CHANNEL_KIND",
              message: "operation not supported for DM channels"
            }} =
             pin!(dm_cid, "cmd-p005", mid3)
  end

  test "pin payload gates: missing source / non-text / deleted / streaming / not found" do
    cid = channel!()

    assert {:error,
            %Errors.ApiError{code: "INVALID_MESSAGE", message: "source_message_id required"}} =
             Channel.pin_message(
               cid,
               %{user_id: @uid, command_id: "cmd-p006", payload: %{}}
             )

    assert {:error, %Errors.ApiError{code: "MESSAGE_NOT_FOUND"}} = pin!(cid, "cmd-p007", "nope")

    mid_img = seed_message("msg-p008", cid, @uid, nil, type: "image", event: false)

    assert {:error,
            %Errors.ApiError{
              code: "PIN_SOURCE_INVALID",
              message: "only text messages can be pinned"
            }} =
             pin!(cid, "cmd-p008", mid_img)

    mid_del = seed_message("msg-p009", cid, @uid, "gone", status: "deleted", event: false)

    assert {:error,
            %Errors.ApiError{
              code: "PIN_SOURCE_INVALID",
              message: "message status cannot be pinned"
            }} =
             pin!(cid, "cmd-p009", mid_del)

    mid_stream =
      seed_message("msg-p010", cid, @uid, "streaming", stream_state: "streaming", event: false)

    assert {:error,
            %Errors.ApiError{
              code: "PIN_SOURCE_INVALID",
              message: "streaming message cannot be pinned"
            }} =
             pin!(cid, "cmd-p010", mid_stream)
  end

  test "pin limit: the 9th pin → PIN_SOURCE_INVALID 'channel pin limit reached'" do
    cid = channel!()

    for i <- 1..8 do
      mid = "msg-plim-#{i}"
      seed_message(mid, cid, @uid, "msg #{i}")
      assert {:ok, _} = pin!(cid, "cmd-plim-#{i}", mid)
    end

    mid9 = "msg-plim-9"
    seed_message(mid9, cid, @uid, "msg 9")

    assert {:error,
            %Errors.ApiError{code: "PIN_SOURCE_INVALID", message: "channel pin limit reached"}} =
             pin!(cid, "cmd-plim-9", mid9)

    assert length(pins(cid)) == 8
  end

  # ---------------------------------------------------------- unpin

  test "unpin by pin_id → channel.pin.cleared + row deleted" do
    cid = channel!()
    mid = seed_message("msg-u001", cid, @uid, "pin me")
    {:ok, pin_ack} = pin!(cid, "cmd-u001", mid)
    pin_id = pin_ack["payload"]["pin"]["pin_id"]

    {:ok, ack} = unpin!(cid, "cmd-u002", %{"pin_id" => pin_id})

    assert ack["payload"]["channel_id"] == cid
    assert is_binary(ack["payload"]["event_id"])

    [cleared] = Enum.filter(events(cid), &(&1["event_type"] == "channel.pin.cleared"))
    assert cleared["event_id"] == ack["payload"]["event_id"]
    assert cleared["payload"]["pin_id"] == pin_id
    assert cleared["payload"]["channel_id"] == cid
    assert cleared["payload"]["pin_kind"] == "pinned_message"
    assert cleared["payload"]["source_message_id"] == mid

    [] = pins(cid)
  end

  test "unpin by source_message_id → same cleared event" do
    cid = channel!()
    mid = seed_message("msg-u003", cid, @uid, "pin me")
    {:ok, _} = pin!(cid, "cmd-u003", mid)

    {:ok, ack} = unpin!(cid, "cmd-u004", %{"source_message_id" => mid})

    [cleared] = Enum.filter(events(cid), &(&1["event_type"] == "channel.pin.cleared"))
    assert cleared["payload"]["source_message_id"] == mid
    assert cleared["event_id"] == ack["payload"]["event_id"]
    [] = pins(cid)
  end

  test "unpin gates: both/none locators → INVALID_MESSAGE; missing → PIN_NOT_FOUND; wrong channel → PIN_NOT_FOUND" do
    cid = channel!()
    mid = seed_message("msg-u005", cid, @uid, "pin me")
    {:ok, pin_ack} = pin!(cid, "cmd-u005", mid)
    pin_id = pin_ack["payload"]["pin"]["pin_id"]

    assert {:error,
            %Errors.ApiError{
              code: "INVALID_MESSAGE",
              message: "exactly one of pin_id or source_message_id required"
            }} =
             unpin!(cid, "cmd-u006", %{"pin_id" => pin_id, "source_message_id" => mid})

    assert {:error, %Errors.ApiError{code: "INVALID_MESSAGE"}} =
             unpin!(cid, "cmd-u007", %{})

    assert {:error, %Errors.ApiError{code: "PIN_NOT_FOUND", message: "pin not found"}} =
             unpin!(cid, "cmd-u008", %{"pin_id" => "pin-nope"})

    # wrong channel: the pin belongs to `cid`; the command targets another
    # channel the user owns → PIN_NOT_FOUND (locator resolves to the pin row,
    # whose channel_id does not match)
    cid2 = channel!()

    assert {:error, %Errors.ApiError{code: "PIN_NOT_FOUND"}} =
             Channel.unpin_message(cid2, %{
               user_id: @uid,
               command_id: "cmd-u010",
               payload: %{"source_message_id" => mid}
             })
  end

  test "unpin: non pinned_message kind → PIN_FORBIDDEN 'cannot unpin this pin kind'" do
    cid = channel!()
    mid = seed_message("msg-u011", cid, @uid, "pin me")
    {:ok, pin_ack} = pin!(cid, "cmd-u011", mid)
    pin_id = pin_ack["payload"]["pin"]["pin_id"]

    # mutate the row into a different pin kind (e.g. a bot_control pin)
    Repo.query!(
      "UPDATE chat_v2.channel_pins SET pin_kind = 'bot_control' WHERE pin_id = $1",
      [pin_id]
    )

    assert {:error,
            %Errors.ApiError{code: "PIN_FORBIDDEN", message: "cannot unpin this pin kind"}} =
             unpin!(cid, "cmd-u012", %{"pin_id" => pin_id})
  end

  # ------------------------------------------------------- idempotency

  test "pin + unpin idempotency: cached replay, no duplicate events" do
    cid = channel!()
    mid = seed_message("msg-i001", cid, @uid, "idempotent")

    {:ok, ack1} = pin!(cid, "cmd-i001", mid)
    {:ok, ack2} = pin!(cid, "cmd-i001", mid)

    assert ack1["payload"]["event_id"] == ack2["payload"]["event_id"]
    assert length(Enum.filter(events(cid), &(&1["event_type"] == "channel.pin.set"))) == 1

    {:ok, un1} = unpin!(cid, "cmd-i002", %{"pin_id" => ack1["payload"]["pin"]["pin_id"]})
    {:ok, un2} = unpin!(cid, "cmd-i002", %{"pin_id" => ack1["payload"]["pin"]["pin_id"]})

    assert un1["payload"]["event_id"] == un2["payload"]["event_id"]
    assert length(Enum.filter(events(cid), &(&1["event_type"] == "channel.pin.cleared"))) == 1

    # a different command_id with a different body → conflict
    assert {:error, %Errors.ApiError{code: "IDEMPOTENCY_CONFLICT"}} =
             unpin!(cid, "cmd-i002", %{"pin_id" => "a-different-pin"})
  end
end
