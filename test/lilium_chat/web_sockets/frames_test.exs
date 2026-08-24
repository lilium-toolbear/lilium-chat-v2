defmodule LiliumChat.WebSockets.FramesTest do
  @moduledoc """
  Frame codec tests (contract §10.2 / §10.4, issue #8).

  Verifies the wire shape of every frame type against the contract:
  command, command_ack (payload-bearing), command_error, event,
  user_event, read_state_updated, stream_event.
  """

  use ExUnit.Case, async: true

  alias LiliumChat.WebSockets.Frames

  # ----------------------------------------------------------- command

  test "command frame has correct shape" do
    frame = Frames.command("session.live_start", "cmd-001", %{})

    assert frame["frame_type"] == "command"
    assert frame["command"] == "session.live_start"
    assert frame["command_id"] == "cmd-001"
    assert frame["payload"] == %{}
    refute Map.has_key?(frame, "channel_id")
  end

  test "command frame with channel_id" do
    frame = Frames.command("message.send", "cmd-002", %{"text" => "hi"}, "ch-001")

    assert frame["channel_id"] == "ch-001"
    assert frame["payload"] == %{"text" => "hi"}
  end

  # -------------------------------------------------------- command_ack

  test "command_ack for session.live_start has correct shape" do
    frame =
      Frames.command_ack(
        "session.live_start",
        "cmd-001",
        %{
          "session_id" => "sess-001",
          "subscribed_channel_count" => 3,
          "lease_expires_at" => "2026-08-19T12:00:00Z"
        }
      )

    assert frame["frame_type"] == "command_ack"
    assert frame["command"] == "session.live_start"
    assert frame["command_id"] == "cmd-001"
    assert frame["status"] == "committed"
    assert frame["payload"]["session_id"] == "sess-001"
    assert frame["payload"]["subscribed_channel_count"] == 3
    assert frame["payload"]["lease_expires_at"] == "2026-08-19T12:00:00Z"
  end

  test "command_ack for session.heartbeat has correct shape" do
    frame =
      Frames.command_ack(
        "session.heartbeat",
        "cmd-002",
        %{
          "session_id" => "sess-001",
          "lease_expires_at" => "2026-08-19T12:04:00Z"
        }
      )

    assert frame["frame_type"] == "command_ack"
    assert frame["command"] == "session.heartbeat"
    assert frame["command_id"] == "cmd-002"
    assert frame["status"] == "committed"
    assert frame["payload"]["session_id"] == "sess-001"
    assert frame["payload"]["lease_expires_at"] == "2026-08-19T12:04:00Z"
    # No subscribed_channel_count for heartbeat
    refute Map.has_key?(frame["payload"], "subscribed_channel_count")
  end

  test "command_ack for message.send is payload-bearing (A4)" do
    message = %{
      "message_id" => "msg-001",
      "channel_id" => "ch-001",
      "text" => "hello"
    }

    frame =
      Frames.command_ack(
        "message.send",
        "cmd-003",
        %{
          "channel_id" => "ch-001",
          "event_id" => "evt-001",
          "message" => message
        }
      )

    assert frame["frame_type"] == "command_ack"
    assert frame["status"] == "committed"
    assert frame["payload"]["channel_id"] == "ch-001"
    assert frame["payload"]["event_id"] == "evt-001"
    assert frame["payload"]["message"]["message_id"] == "msg-001"
  end

  test "command_ack for channel.mark_read (no event_id, §5.5)" do
    frame =
      Frames.command_ack(
        "channel.mark_read",
        "cmd-004",
        %{
          "channel_id" => "ch-001",
          "last_read_event_id" => "evt-002",
          "unread_count" => 0
        }
      )

    assert frame["payload"]["channel_id"] == "ch-001"
    assert frame["payload"]["last_read_event_id"] == "evt-002"
    assert frame["payload"]["unread_count"] == 0
    refute Map.has_key?(frame["payload"], "event_id")
  end

  # ---------------------------------------------------- command_error

  test "command_error frame has correct shape" do
    frame =
      Frames.command_error("cmd-001", %{
        code: "IDEMPOTENCY_CONFLICT",
        message: "idempotency key reused with different request body",
        retryable: false
      })

    assert frame["frame_type"] == "command_error"
    assert frame["command_id"] == "cmd-001"
    assert frame["error"]["code"] == "IDEMPOTENCY_CONFLICT"
    assert frame["error"]["retryable"] == false
  end

  # ------------------------------------------------------------- event

  test "event frame has correct EventEnvelope shape (§10.4)" do
    frame =
      Frames.event(
        "evt-001",
        "message.created",
        "ch-001",
        "2026-06-21T05:30:00Z",
        %{"message" => %{"message_id" => "msg-001"}}
      )

    assert frame["frame_type"] == "event"
    assert frame["api_version"] == "lilium.chat.v1"
    assert frame["event_id"] == "evt-001"
    assert frame["type"] == "message.created"
    assert frame["channel_id"] == "ch-001"
    assert frame["occurred_at"] == "2026-06-21T05:30:00Z"
    assert frame["payload"]["message"]["message_id"] == "msg-001"
  end

  # -------------------------------------------------------- user_event

  test "user_event frame for my_channels_changed (§10.5)" do
    frame = Frames.user_event("my_channels_changed", "member_added", "ch-001")

    assert frame["frame_type"] == "user_event"
    assert frame["event"] == "my_channels_changed"
    assert frame["reason"] == "member_added"
    assert frame["changed_channel_id"] == "ch-001"
    # Not a channel timeline event — no event_id
    refute Map.has_key?(frame, "event_id")
  end

  # ------------------------------------------------- read_state_updated

  test "read_state_updated frame (§5.5 multi-session)" do
    frame = Frames.read_state_updated("ch-001", "evt-002", 0)

    assert frame["frame_type"] == "read_state_updated"
    assert frame["channel_id"] == "ch-001"
    assert frame["last_read_event_id"] == "evt-002"
    assert frame["unread_count"] == 0
  end

  # ------------------------------------------------------- stream_event

  test "stream_event frame for message.stream_started (§9.16)" do
    frame =
      Frames.stream_event("message.stream_started", "ch-001", %{
        "channel_id" => "ch-001",
        "message_id" => "msg-001"
      })

    assert frame["frame_type"] == "stream_event"
    assert frame["api_version"] == "lilium.chat.stream.v1"
    assert frame["type"] == "message.stream_started"
    assert frame["channel_id"] == "ch-001"
    assert frame["payload"]["message_id"] == "msg-001"
  end

  # ------------------------------------------------------ parse_command

  test "parse_command extracts command fields" do
    frame = Frames.command("session.live_start", "cmd-001", %{})

    assert {:ok, {"session.live_start", "cmd-001", nil, %{}}} =
             Frames.parse_command(frame)
  end

  test "parse_command with channel_id" do
    frame = Frames.command("message.send", "cmd-002", %{"text" => "hi"}, "ch-001")

    assert {:ok, {"message.send", "cmd-002", "ch-001", %{"text" => "hi"}}} =
             Frames.parse_command(frame)
  end

  test "parse_command rejects non-command frame" do
    assert {:error, _} = Frames.parse_command(%{"frame_type" => "event"})
  end

  test "parse_command rejects missing command" do
    assert {:error, _} = Frames.parse_command(%{"frame_type" => "command"})
  end

  test "parse_command rejects missing command_id" do
    assert {:error, _} =
             Frames.parse_command(%{
               "frame_type" => "command",
               "command" => "session.live_start"
             })
  end

  # ------------------------------------------------------------- api_version

  test "api_version constants" do
    assert Frames.api_version() == "lilium.chat.v1"
    assert Frames.stream_api_version() == "lilium.chat.stream.v1"
  end
end
