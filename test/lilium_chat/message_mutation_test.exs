defmodule LiliumChat.MessageMutationTest do
  @moduledoc """
  `message.edit` / `message.recall` / `message.delete` write-path tests
  (issue #10, contract §6.3–§6.5, spec A2/A9).

  Process-level tests driven through `LiliumChat.Channel.mutate_message/2`
  (the per-channel writer process): wire shape, edit history + audit rows,
  safe projection, gates, idempotency, pin lifecycle sync, `system.notice`.
  """

  use LiliumChat.DataCase, async: false

  import LiliumChatWeb.ReadFixtures

  alias LiliumChat.{Channel, Errors, Query, Repo, Timeline}

  @uid "6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e6f"
  @other "7a2f3d4e-5b6c-8d9e-0f1a-2b3c4d5e6f70"

  # ----------------------------------------------------------------- helpers

  defp channel!(role \\ "member") do
    cid = "ch-mut-" <> Ecto.UUID.generate()
    seed_channel(cid, kind: "channel", visibility: "private", status: "active")
    seed_membership(cid, @uid, role)
    cid
  end

  defp dm_channel! do
    cid = "ch-dm-" <> Ecto.UUID.generate()
    seed_channel(cid, kind: "dm", visibility: "private", status: "active")
    seed_membership(cid, @uid, "owner")
    seed_membership(cid, @other, "member")
    cid
  end

  defp mutate!(channel_id, command_id, operation, payload),
    do:
      Channel.mutate_message(
        channel_id,
        %{user_id: @uid, command_id: command_id, operation: operation, payload: payload}
      )

  defp events(channel_id) do
    Query.rows(
      Repo.query(
        "SELECT event_id, event_type, actor_kind, actor_id, payload FROM chat_v2.events " <>
          "WHERE channel_id = $1 ORDER BY event_id",
        [channel_id],
        type: true
      )
    )
  end

  defp row(channel_id, message_id) do
    Query.rows(
      Repo.query(
        "SELECT * FROM chat_v2.messages WHERE channel_id = $1 AND message_id = $2",
        [channel_id, message_id],
        type: true
      )
    )
    |> List.first()
  end

  # ------------------------------------------- AC1: wire shape (§6.3–§6.5)

  test "edit → committed ack with edited projection, message_edits row + message.updated event" do
    cid = channel!()
    mid = seed_message("msg-edit-001", cid, @uid, "before")

    {:ok, ack} =
      mutate!(cid, "cmd-edit-001", "message.edit", %{"message_id" => mid, "text" => "after"})

    assert ack["frame_type"] == "command_ack"
    assert ack["command"] == "message.edit"
    assert ack["command_id"] == "cmd-edit-001"
    assert ack["status"] == "committed"

    payload = ack["payload"]
    assert payload["channel_id"] == cid
    assert is_binary(payload["event_id"])

    msg = payload["message"]
    assert msg["message_id"] == mid
    # command_id stays the ORIGINAL send command id (§6.3)
    assert msg["command_id"] == row(cid, mid)["command_id"]
    assert msg["status"] == "edited"
    assert msg["text"] == "after"
    assert is_binary(msg["edited_at"])
    assert msg["recalled_at"] == nil
    assert msg["deleted_at"] == nil

    # stored row
    stored = row(cid, mid)
    assert stored["status"] == "edited"
    assert stored["text"] == "after"
    assert stored["edited_at"] != nil

    # edit history row (spec A2): edit_id = event_id + ":edit"
    [edit] =
      Query.rows(
        Repo.query(
          "SELECT edit_id, message_id, old_text, new_text, editor_user_id, request_id, edited_at " <>
            "FROM chat_v2.message_edits WHERE message_id = $1",
          [mid],
          type: true
        )
      )

    assert edit["edit_id"] == payload["event_id"] <> ":edit"
    assert edit["old_text"] == "before"
    assert edit["new_text"] == "after"
    assert edit["editor_user_id"] == @uid
    assert edit["request_id"] == "cmd-edit-001"
    assert edit["edited_at"] != nil

    # paired timeline event
    [event] = Enum.filter(events(cid), &(&1["event_type"] == "message.updated"))
    assert event["event_id"] == payload["event_id"]
    assert event["actor_kind"] == "user"
    assert event["actor_id"] == @uid
  end

  test "recall → safe projection (no text leak) + audit row + message.recalled event" do
    cid = channel!()
    mid = seed_message("msg-recall-001", cid, @uid, "secret text")

    {:ok, ack} = mutate!(cid, "cmd-recall-001", "message.recall", %{"message_id" => mid})

    msg = ack["payload"]["message"]
    assert msg["status"] == "recalled"
    assert msg["text"] == nil
    assert msg["attachments"] == []
    assert msg["mentions"] == []
    assert is_binary(msg["recalled_at"])
    assert is_nil(msg["edited_at"])

    [audit] =
      Query.rows(
        Repo.query(
          "SELECT audit_id, action, target_type, target_id, before_json, after_json, request_id " <>
            "FROM chat_v2.audit_logs WHERE target_id = $1",
          [mid],
          type: true
        )
      )

    assert audit["audit_id"] == ack["payload"]["event_id"] <> ":audit"
    assert audit["action"] == "message.recall"
    assert audit["target_type"] == "message"
    assert audit["before_json"]["text"] == "secret text"
    assert audit["after_json"]["status"] == "recalled"
    assert audit["request_id"] == "cmd-recall-001"

    [event] = Enum.filter(events(cid), &(&1["event_type"] == "message.recalled"))
    assert event["event_id"] == ack["payload"]["event_id"]

    # replay (GET .../events gap recovery) re-projects the SAME safe
    # projection + the contract §10.4 payload ids (A9)
    replay = Timeline.channel_events(@uid, cid, nil, 100)
    [replayed] = Enum.filter(replay.events, &(&1["type"] == "message.recalled"))

    assert replayed["payload"]["channel_id"] == cid
    assert replayed["payload"]["event_id"] == replayed["event_id"]
    assert replayed["payload"]["message"]["status"] == "recalled"
    assert replayed["payload"]["message"]["text"] == nil
    assert replayed["payload"]["message"]["attachments"] == []
  end

  test "delete → deleted safe projection with deleted_by; audit row carries reason" do
    cid = channel!()
    mid = seed_message("msg-del-001", cid, @uid, "bye")

    {:ok, ack} =
      mutate!(cid, "cmd-del-001", "message.delete", %{"message_id" => mid, "reason" => "too long"})

    msg = ack["payload"]["message"]
    assert msg["status"] == "deleted"
    assert msg["text"] == nil
    assert is_binary(msg["deleted_at"])

    stored = row(cid, mid)
    assert stored["status"] == "deleted"
    assert stored["deleted_by"] == @uid

    [audit] =
      Query.rows(
        Repo.query(
          "SELECT reason FROM chat_v2.audit_logs WHERE target_id = $1 AND action = 'message.delete'",
          [mid]
        )
      )

    assert audit["reason"] == "too long"
  end

  test "admin deleting another's message → system.notice (stored ref form); own delete → no notice" do
    cid = channel!("owner")
    mid_theirs = seed_message("msg-not-001", cid, @other, "theirs")
    mid_mine = seed_message("msg-not-002", cid, @uid, "mine")

    {:ok, ack_theirs} =
      mutate!(cid, "cmd-not-001", "message.delete", %{"message_id" => mid_theirs})

    types = Enum.map(events(cid), & &1["event_type"])
    assert "system.notice" in types

    [notice] = Enum.filter(events(cid), &(&1["event_type"] == "system.notice"))
    # stored payload keeps stable refs (contract §10.4), NOT summaries
    assert notice["payload"]["notice_kind"] == "message.deleted"
    assert notice["payload"]["actor_user_id"] == @uid
    assert notice["payload"]["target_user_id"] == @other
    assert notice["payload"]["message_id"] == mid_theirs
    assert notice["payload"]["channel_changes"] == nil
    # notice event_id follows the main event
    assert notice["event_id"] > ack_theirs["payload"]["event_id"]

    # deleting own message → NO notice
    {:ok, _} = mutate!(cid, "cmd-not-002", "message.delete", %{"message_id" => mid_mine})

    notices = Enum.filter(events(cid), &(&1["event_type"] == "system.notice"))
    assert length(notices) == 1
  end

  # ------------------------------------------------------- gates (§6.3–6.5)

  test "edit: not the sender → MESSAGE_NOT_EDITABLE 'message is not editable'" do
    cid = channel!("owner")
    mid = seed_message("msg-gate-e1", cid, @other, "theirs")

    assert {:error,
            %Errors.ApiError{code: "MESSAGE_NOT_EDITABLE", message: "message is not editable"}} =
             mutate!(cid, "cmd-gate-e1", "message.edit", %{"message_id" => mid, "text" => "x"})
  end

  test "edit: image type → MESSAGE_NOT_EDITABLE" do
    cid = channel!()
    mid = seed_message("msg-gate-e2", cid, @uid, nil, type: "image", event: false)

    assert {:error, %Errors.ApiError{code: "MESSAGE_NOT_EDITABLE"}} =
             mutate!(cid, "cmd-gate-e2", "message.edit", %{"message_id" => mid, "text" => "x"})
  end

  test "edit: deleted message → MESSAGE_NOT_EDITABLE" do
    cid = channel!()
    mid = seed_message("msg-gate-e3", cid, @uid, "gone", status: "deleted", event: false)

    assert {:error, %Errors.ApiError{code: "MESSAGE_NOT_EDITABLE"}} =
             mutate!(cid, "cmd-gate-e3", "message.edit", %{"message_id" => mid, "text" => "x"})
  end

  test "edit: missing message_id / empty text → INVALID_MESSAGE" do
    cid = channel!()

    assert {:error, %Errors.ApiError{code: "INVALID_MESSAGE", message: "message_id is required"}} =
             mutate!(cid, "cmd-gate-e4", "message.edit", %{"text" => "x"})

    mid = seed_message("msg-gate-e5", cid, @uid, "hi")

    assert {:error, %Errors.ApiError{code: "INVALID_MESSAGE", message: "message text is empty"}} =
             mutate!(cid, "cmd-gate-e5", "message.edit", %{"message_id" => mid, "text" => "   "})
  end

  test "recall: not the sender → 'message is not recallable'; recalled again → not recallable" do
    cid = channel!("owner")
    mid = seed_message("msg-gate-r1", cid, @other, "theirs")

    assert {:error,
            %Errors.ApiError{code: "MESSAGE_NOT_EDITABLE", message: "message is not recallable"}} =
             mutate!(cid, "cmd-gate-r1", "message.recall", %{"message_id" => mid})

    mid2 = seed_message("msg-gate-r2", cid, @uid, "mine")
    assert {:ok, _} = mutate!(cid, "cmd-gate-r2", "message.recall", %{"message_id" => mid2})

    assert {:error,
            %Errors.ApiError{code: "MESSAGE_NOT_EDITABLE", message: "message is not recallable"}} =
             mutate!(cid, "cmd-gate-r3", "message.recall", %{"message_id" => mid2})
  end

  test "delete: plain member deleting another's message → FORBIDDEN" do
    cid = channel!()
    mid = seed_message("msg-gate-d1", cid, @other, "theirs")

    assert {:error,
            %Errors.ApiError{code: "FORBIDDEN", message: "only sender or owner/admin may delete"}} =
             mutate!(cid, "cmd-gate-d1", "message.delete", %{"message_id" => mid})
  end

  test "delete: owner deleting another's message → committed" do
    cid = channel!("owner")
    mid = seed_message("msg-gate-d2", cid, @other, "theirs")

    assert {:ok, ack} = mutate!(cid, "cmd-gate-d2", "message.delete", %{"message_id" => mid})
    assert ack["payload"]["message"]["status"] == "deleted"
  end

  test "delete in DM: only the sender may delete" do
    cid = dm_channel!()
    mid_theirs = seed_message("msg-gate-d3", cid, @other, "dm theirs")

    # @uid is the DM owner (role owner) but NOT the sender → FORBIDDEN in DM
    assert {:error, %Errors.ApiError{code: "FORBIDDEN", message: "only sender may delete in DM"}} =
             mutate!(cid, "cmd-gate-d3", "message.delete", %{"message_id" => mid_theirs})

    mid_mine = seed_message("msg-gate-d4", cid, @uid, "dm mine")
    assert {:ok, _} = mutate!(cid, "cmd-gate-d4", "message.delete", %{"message_id" => mid_mine})
  end

  test "delete: deleted message → 'message is not deletable'; recalled message is deletable" do
    cid = channel!()
    mid_del = seed_message("msg-gate-d5", cid, @uid, "gone", status: "deleted", event: false)
    mid_rec = seed_message("msg-gate-d6", cid, @uid, "recalled", status: "recalled", event: false)

    assert {:error,
            %Errors.ApiError{code: "MESSAGE_NOT_EDITABLE", message: "message is not deletable"}} =
             mutate!(cid, "cmd-gate-d5", "message.delete", %{"message_id" => mid_del})

    assert {:ok, _} = mutate!(cid, "cmd-gate-d6", "message.delete", %{"message_id" => mid_rec})
  end

  test "gates: message not found / non-member / dissolved" do
    cid = channel!()
    seed_message("msg-gate-x1", cid, @uid, "hi")

    assert {:error, %Errors.ApiError{code: "MESSAGE_NOT_FOUND"}} =
             mutate!(cid, "cmd-gate-x1", "message.edit", %{"message_id" => "nope", "text" => "x"})

    other_cid = "ch-gate-nm"
    seed_channel(other_cid, kind: "channel", visibility: "private", status: "active")
    seed_membership(other_cid, @other, "member")

    assert {:error,
            %Errors.ApiError{
              code: "CHANNEL_NOT_FOUND",
              message: "channel not found or not a member"
            }} =
             mutate!(other_cid, "cmd-gate-x2", "message.edit", %{
               "message_id" => "nope",
               "text" => "x"
             })

    dissolved_cid = "ch-gate-dis"
    seed_channel(dissolved_cid, kind: "channel", visibility: "private", status: "dissolved")
    seed_membership(dissolved_cid, @uid, "member")

    assert {:error, %Errors.ApiError{code: "CHANNEL_DISSOLVED"}} =
             mutate!(dissolved_cid, "cmd-gate-x3", "message.edit", %{
               "message_id" => "nope",
               "text" => "x"
             })
  end

  # ------------------------------------------------------- idempotency

  test "same command_id + same body → cached replay (one event); different body → conflict" do
    cid = channel!()
    mid = seed_message("msg-idem-001", cid, @uid, "v1")
    body = %{"message_id" => mid, "text" => "v2"}

    {:ok, ack1} = mutate!(cid, "cmd-idem-m1", "message.edit", body)
    {:ok, ack2} = mutate!(cid, "cmd-idem-m1", "message.edit", body)

    assert ack1["payload"]["event_id"] == ack2["payload"]["event_id"]
    assert ack2["payload"]["message"]["text"] == "v2"

    updated = Enum.filter(events(cid), &(&1["event_type"] == "message.updated"))
    assert length(updated) == 1

    assert {:error, %Errors.ApiError{code: "IDEMPOTENCY_CONFLICT"}} =
             mutate!(cid, "cmd-idem-m1", "message.edit", %{
               "message_id" => mid,
               "text" => "DIFFERENT"
             })
  end

  test "different command_id → distinct events" do
    cid = channel!()
    mid = seed_message("msg-idem-002", cid, @uid, "v1")

    {:ok, a} = mutate!(cid, "cmd-idem-m2a", "message.edit", %{"message_id" => mid, "text" => "a"})
    {:ok, b} = mutate!(cid, "cmd-idem-m2b", "message.edit", %{"message_id" => mid, "text" => "b"})

    assert a["payload"]["event_id"] != b["payload"]["event_id"]
  end

  # ------------------------------------------------- pin lifecycle sync

  test "editing a pinned message → channel.pin.updated, pin row projection + cursor advanced" do
    cid = channel!("owner")
    mid = seed_message("msg-pin-001", cid, @uid, "pinned text")

    {:ok, pin_ack} =
      Channel.pin_message(cid, %{
        user_id: @uid,
        command_id: "cmd-pin-src-001",
        payload: %{"source_message_id" => mid}
      })

    pin_id = pin_ack["payload"]["pin"]["pin_id"]
    assert pin_ack["payload"]["pin"]["message"]["text"] == "pinned text"

    {:ok, edit_ack} =
      mutate!(cid, "cmd-pin-edit-001", "message.edit", %{
        "message_id" => mid,
        "text" => "edited pin"
      })

    types = Enum.map(events(cid), & &1["event_type"])
    assert "channel.pin.updated" in types

    [pin_event] = Enum.filter(events(cid), &(&1["event_type"] == "channel.pin.updated"))
    # event_id order: main mutation < pin sync
    assert pin_event["event_id"] > edit_ack["payload"]["event_id"]

    [pin_row] =
      Query.rows(
        Repo.query("SELECT * FROM chat_v2.channel_pins WHERE pin_id = $1", [pin_id], type: true)
      )

    assert pin_row["last_pin_event_id"] == pin_event["event_id"]
    projection = pin_row["message_projection_json"]
    assert projection["text"] == "edited pin"
    assert projection["projection_id"] == pin_ack["payload"]["pin"]["message"]["projection_id"]

    # the pin event payload carries the full wire pin
    assert pin_event["payload"]["pin"]["pin_id"] == pin_id
    assert pin_event["payload"]["pin"]["message"]["text"] == "edited pin"
  end

  test "recalling a pinned message → pin row deleted + channel.pin.cleared" do
    cid = channel!("owner")
    mid = seed_message("msg-pin-002", cid, @uid, "pinned recall")

    {:ok, pin_ack} =
      Channel.pin_message(cid, %{
        user_id: @uid,
        command_id: "cmd-pin-src-002",
        payload: %{"source_message_id" => mid}
      })

    pin_id = pin_ack["payload"]["pin"]["pin_id"]

    {:ok, _} = mutate!(cid, "cmd-pin-recall-001", "message.recall", %{"message_id" => mid})

    [cleared] = Enum.filter(events(cid), &(&1["event_type"] == "channel.pin.cleared"))
    assert cleared["payload"]["pin_id"] == pin_id
    assert cleared["payload"]["channel_id"] == cid
    assert cleared["payload"]["pin_kind"] == "pinned_message"
    assert cleared["payload"]["source_message_id"] == mid

    [] =
      Query.rows(
        Repo.query("SELECT pin_id FROM chat_v2.channel_pins WHERE pin_id = $1", [pin_id])
      )
  end

  # ------------------------------------------------------- event ordering

  test "delete with pin + notice: event_id order is main < pin < notice" do
    cid = channel!("owner")
    mid = seed_message("msg-order-001", cid, @other, "all three")

    {:ok, _} =
      Channel.pin_message(cid, %{
        user_id: @uid,
        command_id: "cmd-order-pin",
        payload: %{"source_message_id" => mid}
      })

    {:ok, ack} = mutate!(cid, "cmd-order-del", "message.delete", %{"message_id" => mid})

    main_id = ack["payload"]["event_id"]

    [pin_event] = Enum.filter(events(cid), &(&1["event_type"] == "channel.pin.cleared"))
    [notice] = Enum.filter(events(cid), &(&1["event_type"] == "system.notice"))

    assert main_id < pin_event["event_id"]
    assert pin_event["event_id"] < notice["event_id"]
  end
end
