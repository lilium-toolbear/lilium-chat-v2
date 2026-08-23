defmodule LiliumChat.BotEffectsTest do
  @moduledoc """
  Bot effect validation + idempotency tests (contract §9.7.3 / §9.14, issue #17).
  """

  use LiliumChat.DataCase, async: false

  import LiliumChatWeb.BotFixtures

  alias LiliumChat.{BotEffects, Query, Repo}

  @channel "ch-eff-0001"
  @bot "bot-eff-0001"

  setup do
    seed_bot("owner-1", bot_id: @bot)
    :ok
  end

  # ------------------------------------------------------------- validation

  test "validate: all seven main-gateway effect types are accepted" do
    effects = [
      %{
        "type" => "send_message",
        "client_effect_id" => "1",
        "message" => %{"type" => "text", "text" => "hi"}
      },
      %{
        "type" => "update_message",
        "client_effect_id" => "2",
        "message_id" => "m-1",
        "message" => %{"text" => "new"}
      },
      %{
        "type" => "disable_components",
        "client_effect_id" => "3",
        "message_id" => "m-1",
        "component_ids" => ["c-1"]
      },
      %{
        "type" => "start_stream",
        "client_effect_id" => "4",
        "message" => %{"type" => "text", "text" => ""}
      },
      %{
        "type" => "set_channel_pin",
        "client_effect_id" => "5",
        "pin_kind" => "announcement",
        "message" => %{"text" => "pinned"}
      },
      %{
        "type" => "update_channel_pin",
        "client_effect_id" => "6",
        "pin_id" => "p-1",
        "message" => %{"text" => "pinned 2"}
      },
      %{"type" => "clear_channel_pin", "client_effect_id" => "7", "pin_id" => "p-1"}
    ]

    assert {:ok, ^effects} = BotEffects.validate(effects)
  end

  test "validate: append_stream / finalize_stream are rejected on the main gateway" do
    for type <- ["append_stream", "finalize_stream"] do
      assert {:error, %LiliumChat.Errors.ApiError{code: "BOT_EFFECT_INVALID"}} =
               BotEffects.validate([%{"type" => type, "client_effect_id" => "1"}])
    end
  end

  test "validate: unsafe-markdown is official-bots-only" do
    effect = %{
      "type" => "send_message",
      "client_effect_id" => "1",
      "message" => %{"type" => "text", "format" => "unsafe-markdown", "text" => "raw"}
    }

    assert {:error, %LiliumChat.Errors.ApiError{code: "BOT_EFFECT_INVALID"}} =
             BotEffects.validate([effect], is_official: false)

    assert {:ok, _} = BotEffects.validate([effect], is_official: true)
  end

  test "validate: per-type field rules" do
    # send_message: text message with attachments
    assert {:error, %LiliumChat.Errors.ApiError{}} =
             BotEffects.validate([
               %{
                 "type" => "send_message",
                 "client_effect_id" => "1",
                 "message" => %{"type" => "text", "text" => "t", "attachment_ids" => ["a"]}
               }
             ])

    # send_message: image without attachments
    assert {:error, %LiliumChat.Errors.ApiError{}} =
             BotEffects.validate([
               %{
                 "type" => "send_message",
                 "client_effect_id" => "1",
                 "message" => %{"type" => "image"}
               }
             ])

    # update_message: no patch fields
    assert {:error, %LiliumChat.Errors.ApiError{}} =
             BotEffects.validate([
               %{
                 "type" => "update_message",
                 "client_effect_id" => "1",
                 "message_id" => "m-1",
                 "message" => %{}
               }
             ])

    # start_stream: components / attachment_ids forbidden
    assert {:error, %LiliumChat.Errors.ApiError{}} =
             BotEffects.validate([
               %{
                 "type" => "start_stream",
                 "client_effect_id" => "1",
                 "message" => %{"type" => "text", "components" => [%{"custom_id" => "x"}]}
               }
             ])

    assert {:error, %LiliumChat.Errors.ApiError{}} =
             BotEffects.validate([
               %{
                 "type" => "start_stream",
                 "client_effect_id" => "1",
                 "message" => %{"type" => "text", "attachment_ids" => ["a"]}
               }
             ])

    # pins
    assert {:error, %LiliumChat.Errors.ApiError{}} =
             BotEffects.validate([
               %{
                 "type" => "set_channel_pin",
                 "client_effect_id" => "1",
                 "pin_kind" => "session_control",
                 "message" => %{}
               }
             ])

    assert {:error, %LiliumChat.Errors.ApiError{}} =
             BotEffects.validate([%{"type" => "clear_channel_pin", "client_effect_id" => "1"}])

    # client_effect_id required
    assert {:error, %LiliumChat.Errors.ApiError{}} =
             BotEffects.validate([
               %{"type" => "send_message", "message" => %{"type" => "text", "text" => "t"}}
             ])
  end

  # ----------------------------------------------------------- request hash

  test "request_hash is stable for the same logical body and ignores client_effect_id" do
    a = %{
      "type" => "send_message",
      "client_effect_id" => "x",
      "message" => %{"type" => "text", "text" => "hello"}
    }

    b = %{a | "client_effect_id" => "y"}

    assert BotEffects.request_hash(a) == BotEffects.request_hash(b)

    c = %{a | "message" => %{"type" => "text", "text" => "world"}}
    assert BotEffects.request_hash(a) != BotEffects.request_hash(c)
  end

  # ------------------------------------------------------------------ apply

  test "apply: send_message inserts a minimal messages row and returns effect_result" do
    effect = %{
      "type" => "send_message",
      "client_effect_id" => "ce-1",
      "message" => %{"type" => "text", "text" => "hello from bot", "format" => "markdown"}
    }

    assert {:applied, result} = BotEffects.apply(@channel, @bot, effect)

    # Wire shape per contract §9.7.3 / §9.14: `type` (not `effect_type`) +
    # `status`.
    assert result["type"] == "send_message"
    assert result["status"] == "applied"
    assert result["client_effect_id"] == "ce-1"
    message_id = result["message_id"]
    assert is_binary(message_id)

    channel = @channel
    bot = @bot

    rows =
      Query.rows(
        Repo.query(
          "SELECT message_id, channel_id, sender_kind, sender_bot_id, type, format, status, stream_state, text " <>
            "FROM chat_v2.messages WHERE message_id = $1",
          [message_id],
          type: true
        )
      )

    assert [
             %{
               "message_id" => ^message_id,
               "channel_id" => ^channel,
               "sender_kind" => "bot",
               "sender_bot_id" => ^bot,
               "type" => "text",
               "format" => "markdown",
               "status" => "normal",
               "stream_state" => "none",
               "text" => "hello from bot"
             }
           ] = rows
  end

  test "apply: duplicate effect (same key + same body) replays the stored result" do
    effect = %{
      "type" => "send_message",
      "client_effect_id" => "ce-1",
      "message" => %{"type" => "text", "text" => "once"}
    }

    assert {:applied, %{"message_id" => message_id}} = BotEffects.apply(@channel, @bot, effect)

    assert {:cached, result} = BotEffects.apply(@channel, @bot, effect)
    assert result["message_id"] == message_id

    # no second messages row was inserted
    count =
      Repo.query(
        "SELECT count(*) AS n FROM chat_v2.messages WHERE channel_id = $1",
        [@channel],
        type: true
      )
      |> Query.rows()
      |> List.first()
      |> Map.get("n")

    assert count == 1
  end

  test "apply: same client_effect_id with a different body → BOT_EFFECT_CONFLICT" do
    assert {:applied, _} =
             BotEffects.apply(@channel, @bot, %{
               "type" => "send_message",
               "client_effect_id" => "ce-1",
               "message" => %{"type" => "text", "text" => "v1"}
             })

    assert {:error, %LiliumChat.Errors.ApiError{code: "BOT_EFFECT_CONFLICT"}} =
             BotEffects.apply(@channel, @bot, %{
               "type" => "send_message",
               "client_effect_id" => "ce-1",
               "message" => %{"type" => "text", "text" => "v2"}
             })
  end

  test "apply: the idempotency row is stored under the bot_effect namespace" do
    BotEffects.apply(@channel, @bot, %{
      "type" => "send_message",
      "client_effect_id" => "ce-1",
      "message" => %{"type" => "text", "text" => "t"}
    })

    rows =
      Query.rows(
        Repo.query(
          "SELECT namespace, channel_id, bot_id, client_effect_id, effect_type, message_id " <>
            "FROM chat_v2.idempotency WHERE namespace = 'bot_effect' AND client_effect_id = 'ce-1'",
          [],
          type: true
        )
      )

    assert [
             %{
               "namespace" => "bot_effect",
               "channel_id" => @channel,
               "bot_id" => @bot,
               "client_effect_id" => "ce-1",
               "effect_type" => "send_message",
               "message_id" => _message_id
             }
           ] = rows
  end

  test "apply: update_message on a bot-owned message updates it; foreign message fails" do
    seed = %{
      "type" => "send_message",
      "client_effect_id" => "seed",
      "message" => %{"type" => "text", "text" => "original"}
    }

    {:applied, %{"message_id" => message_id}} = BotEffects.apply(@channel, @bot, seed)

    update = %{
      "type" => "update_message",
      "client_effect_id" => "up-1",
      "message_id" => message_id,
      "message" => %{"text" => "edited"}
    }

    assert {:applied, %{"message_id" => ^message_id}} =
             BotEffects.apply(@channel, @bot, update)

    rows =
      Query.rows(
        Repo.query("SELECT text FROM chat_v2.messages WHERE message_id = $1", [message_id],
          type: true
        )
      )

    assert [%{"text" => "edited"}] = rows

    # A different bot's message is not updatable by this bot
    foreign = %{
      "type" => "update_message",
      "client_effect_id" => "up-2",
      "message_id" => message_id,
      "message" => %{"text" => "x"}
    }

    assert {:error, %LiliumChat.Errors.ApiError{code: "BOT_EFFECT_INVALID"}} =
             BotEffects.apply(@channel, "other-bot", foreign)
  end

  test "apply: start_stream inserts a streaming message and returns the stream handle" do
    channel = @channel

    assert {:applied, result} =
             BotEffects.apply(@channel, @bot, %{
               "type" => "start_stream",
               "client_effect_id" => "ss-1",
               "message" => %{"type" => "text", "text" => ""}
             })

    message_id = result["message_id"]
    assert is_binary(message_id)

    # Contract §9.14: the ack MUST carry the stream handle (Stream WS URL +
    # expires_at) — the bot connects to the Stream WS before it expires.
    assert %{
             "channel_id" => ^channel,
             "message_id" => ^message_id,
             "ws_url" => ws_url,
             "expires_at" => expires_at
           } = result["stream"]

    assert ws_url == "/api/chat/bot/channels/#{channel}/streams/#{message_id}/ws"
    assert {:ok, %DateTime{}, _} = DateTime.from_iso8601(expires_at)

    # Minimal (#17) seam: a streaming placeholder row stands in for the
    # streaming registry (the registry itself lands with #19).
    rows =
      Query.rows(
        Repo.query(
          "SELECT stream_state, status FROM chat_v2.messages WHERE message_id = $1",
          [message_id],
          type: true
        )
      )

    assert [%{"stream_state" => "streaming", "status" => "normal"}] = rows
  end

  test "apply: pin effects validate ownership and persist the pin" do
    assert {:applied, %{"pin_id" => pin_id}} =
             BotEffects.apply(@channel, @bot, %{
               "type" => "set_channel_pin",
               "client_effect_id" => "pin-1",
               "pin_kind" => "announcement",
               "message" => %{"text" => "pinned!"}
             })

    assert is_binary(pin_id)

    rows =
      Query.rows(
        Repo.query(
          "SELECT pin_kind, pin_owner_kind, pin_owner_id, priority, message_projection_json " <>
            "FROM chat_v2.channel_pins WHERE pin_id = $1",
          [pin_id],
          type: true
        )
      )

    assert [
             %{
               "pin_kind" => "announcement",
               "pin_owner_kind" => "bot",
               "pin_owner_id" => @bot,
               "priority" => 20,
               "message_projection_json" => %{"text" => "pinned!"}
             }
           ] = rows

    assert {:applied, %{"pin_id" => ^pin_id}} =
             BotEffects.apply(@channel, @bot, %{
               "type" => "update_channel_pin",
               "client_effect_id" => "pin-2",
               "pin_id" => pin_id,
               "message" => %{"text" => "pinned 2"}
             })

    assert {:applied, %{"pin_id" => ^pin_id}} =
             BotEffects.apply(@channel, @bot, %{
               "type" => "clear_channel_pin",
               "client_effect_id" => "pin-3",
               "pin_id" => pin_id
             })

    # unknown pin
    assert {:error, %LiliumChat.Errors.ApiError{code: "BOT_EFFECT_INVALID"}} =
             BotEffects.apply(@channel, @bot, %{
               "type" => "clear_channel_pin",
               "client_effect_id" => "pin-4",
               "pin_id" => "no-such-pin"
             })

    # another bot's pin is not modifiable
    assert {:error, %LiliumChat.Errors.ApiError{code: "BOT_EFFECT_INVALID"}} =
             BotEffects.apply(@channel, "other-bot", %{
               "type" => "clear_channel_pin",
               "client_effect_id" => "pin-5",
               "pin_id" => pin_id
             })
  end
end
