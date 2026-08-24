defmodule LiliumChat.BotEffectsTest do
  @moduledoc """
  Bot effect validation + idempotency tests (contract §9.7.3 / §9.14, issue #17).
  """

  use LiliumChat.DataCase, async: false

  import LiliumChatWeb.BotFixtures

  alias LiliumChat.{BotEffects, Ids, Projections, Query, Repo}

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

  test "apply: start_stream returns the stream handle and does not insert a message" do
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

    # Contract §9.14: start_stream does not insert a canonical messages row
    # (the Stream process is the in-memory registry; finalize/abandon write).
    rows =
      Query.rows(
        Repo.query(
          "SELECT stream_state, status FROM chat_v2.messages WHERE message_id = $1",
          [message_id],
          type: true
        )
      )

    assert rows == []

    assert %{status: :streaming, bot_id: @bot} =
             LiliumChat.Stream.debug_state(channel, message_id)
  end

  test "apply: pin effects validate ownership and persist the pin" do
    # Contract §3.10.2: `PinMessageDraft` requires `format` AND
    # `components: MessageComponent[]` (the old Worker
    # `parsePinMessageDraft` rejects a missing/unknown format or a missing
    # components array).
    assert {:applied, %{"pin_id" => pin_id}} =
             BotEffects.apply(@channel, @bot, %{
               "type" => "set_channel_pin",
               "client_effect_id" => "pin-1",
               "pin_kind" => "announcement",
               "message" => %{"format" => "plain", "text" => "pinned!", "components" => []}
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

  # ------------------------------------------------- update_message (#19)

  test "apply: update_message text edit flips status normal→edited and sets edited_at" do
    {:applied, %{"message_id" => message_id}} =
      BotEffects.apply(@channel, @bot, %{
        "type" => "send_message",
        "client_effect_id" => "seed-edit",
        "message" => %{"type" => "text", "text" => "original"}
      })

    assert {:applied, %{"message_id" => ^message_id, "event_id" => event_id}} =
             BotEffects.apply(@channel, @bot, %{
               "type" => "update_message",
               "client_effect_id" => "up-edit",
               "message_id" => message_id,
               "message" => %{"text" => "edited text"}
             })

    assert is_binary(event_id)

    [
      %{"status" => "edited", "edited_at" => edited_at, "text" => "edited text"}
    ] =
      Query.rows(
        Repo.query(
          "SELECT status, edited_at, text FROM chat_v2.messages WHERE message_id = $1",
          [message_id],
          type: true
        )
      )

    assert timestamp?(edited_at)

    assert event_count(@channel, "message.updated") == 1

    # idempotent replay
    assert {:cached, %{"message_id" => ^message_id}} =
             BotEffects.apply(@channel, @bot, %{
               "type" => "update_message",
               "client_effect_id" => "up-edit",
               "message_id" => message_id,
               "message" => %{"text" => "edited text"}
             })
  end

  test "apply: update_message relinks attachments (image) and clears them back to text" do
    seed_bot_attachment("att-1")
    seed_bot_attachment("att-2")

    {:applied, %{"message_id" => message_id}} =
      BotEffects.apply(@channel, @bot, %{
        "type" => "send_message",
        "client_effect_id" => "seed-att",
        "message" => %{"type" => "text", "text" => "base"}
      })

    assert {:applied, _} =
             BotEffects.apply(@channel, @bot, %{
               "type" => "update_message",
               "client_effect_id" => "up-att",
               "message_id" => message_id,
               "message" => %{"attachment_ids" => ["att-1"]}
             })

    assert [%{"type" => "image"}] =
             Query.rows(
               Repo.query(
                 "SELECT type FROM chat_v2.messages WHERE message_id = $1",
                 [message_id],
                 type: true
               )
             )

    assert linked_attachments(message_id) == ["att-1"]

    # An attachment from another channel is not resolvable.
    seed_bot_attachment("att-foreign")

    Repo.query!(
      "UPDATE chat_v2.attachments SET channel_id = 'ch-other' WHERE attachment_id = $1",
      ["att-foreign"]
    )

    assert {:error, %LiliumChat.Errors.ApiError{code: "BOT_EFFECT_INVALID"}} =
             BotEffects.apply(@channel, @bot, %{
               "type" => "update_message",
               "client_effect_id" => "up-att-foreign",
               "message_id" => message_id,
               "message" => %{"attachment_ids" => ["att-foreign"]}
             })

    # An empty list clears the relink and reverts the type to text.
    assert {:applied, _} =
             BotEffects.apply(@channel, @bot, %{
               "type" => "update_message",
               "client_effect_id" => "up-att-clear",
               "message_id" => message_id,
               "message" => %{"attachment_ids" => []}
             })

    assert [%{"type" => "text"}] =
             Query.rows(
               Repo.query(
                 "SELECT type FROM chat_v2.messages WHERE message_id = $1",
                 [message_id],
                 type: true
               )
             )

    assert linked_attachments(message_id) == []
  end

  test "apply: update_message gates — unknown / recalled / streaming messages" do
    # unknown message
    assert {:error, %LiliumChat.Errors.ApiError{code: "BOT_EFFECT_INVALID"}} =
             BotEffects.apply(@channel, @bot, %{
               "type" => "update_message",
               "client_effect_id" => "up-404",
               "message_id" => "no-such-message",
               "message" => %{"text" => "x"}
             })

    {:applied, %{"message_id" => message_id}} =
      BotEffects.apply(@channel, @bot, %{
        "type" => "send_message",
        "client_effect_id" => "seed-gate",
        "message" => %{"type" => "text", "text" => "g"}
      })

    # a recalled message is not mutable
    Repo.query!("UPDATE chat_v2.messages SET status = 'recalled' WHERE message_id = $1", [
      message_id
    ])

    assert {:error, %LiliumChat.Errors.ApiError{code: "BOT_EFFECT_INVALID"}} =
             BotEffects.apply(@channel, @bot, %{
               "type" => "update_message",
               "client_effect_id" => "up-recalled",
               "message_id" => message_id,
               "message" => %{"text" => "x"}
             })

    # a streaming message is not mutable
    Repo.query!(
      "UPDATE chat_v2.messages SET status = 'normal', stream_state = 'streaming' WHERE message_id = $1",
      [message_id]
    )

    assert {:error, %LiliumChat.Errors.ApiError{code: "BOT_EFFECT_INVALID"}} =
             BotEffects.apply(@channel, @bot, %{
               "type" => "update_message",
               "client_effect_id" => "up-streaming",
               "message_id" => message_id,
               "message" => %{"text" => "x"}
             })
  end

  # ----------------------------------------------- disable_components (#19)

  test "apply: disable_components disables only the listed components" do
    c1 = Ids.uuidv7()
    c2 = Ids.uuidv7()

    components = [
      %{
        "component_id" => c1,
        "kind" => "button",
        "style" => "primary",
        "custom_id" => "confirm",
        "label" => "Yes",
        "disabled" => false
      },
      %{
        "component_id" => c2,
        "kind" => "button",
        "style" => "danger",
        "custom_id" => "cancel",
        "label" => "No",
        "disabled" => false
      }
    ]

    {:applied, %{"message_id" => message_id}} =
      BotEffects.apply(@channel, @bot, %{
        "type" => "send_message",
        "client_effect_id" => "seed-cmp",
        "message" => %{"type" => "text", "text" => "pick", "components" => components}
      })

    # components persisted to `components_json`
    assert stored_component_ids(message_id) == [c1, c2]

    assert {:applied, %{"message_id" => ^message_id, "event_id" => event_id}} =
             BotEffects.apply(@channel, @bot, %{
               "type" => "disable_components",
               "client_effect_id" => "dis-1",
               "message_id" => message_id,
               "component_ids" => [c1]
             })

    assert is_binary(event_id)

    stored = stored_components(message_id)
    assert Enum.find(stored, &(&1["component_id"] == c1))["disabled"] == true
    assert Enum.find(stored, &(&1["component_id"] == c2))["disabled"] != true

    # unknown component id → BOT_EFFECT_INVALID
    assert {:error, %LiliumChat.Errors.ApiError{code: "BOT_EFFECT_INVALID"}} =
             BotEffects.apply(@channel, @bot, %{
               "type" => "disable_components",
               "client_effect_id" => "dis-2",
               "message_id" => message_id,
               "component_ids" => [Ids.uuidv7()]
             })

    # idempotent replay
    assert {:cached, %{"message_id" => ^message_id}} =
             BotEffects.apply(@channel, @bot, %{
               "type" => "disable_components",
               "client_effect_id" => "dis-1",
               "message_id" => message_id,
               "component_ids" => [c1]
             })
  end

  # --------------------------------------------------------- start_stream (#19)

  test "apply: start_stream allocates no event row and replay rehydrates the stream" do
    effect = %{
      "type" => "start_stream",
      "client_effect_id" => "ss-replay",
      "message" => %{"type" => "text", "text" => ""}
    }

    assert {:applied, result1} = BotEffects.apply(@channel, @bot, effect)
    assert {:cached, result2} = BotEffects.apply(@channel, @bot, effect)

    # the cached result is identical (same message_id + same handle)
    assert result2["message_id"] == result1["message_id"]
    assert result2["stream"] == result1["stream"]

    message_id = result1["message_id"]

    # the ephemeral stream process is still alive after the replay
    assert %{status: :streaming, bot_id: @bot} =
             LiliumChat.Stream.debug_state(@channel, message_id)

    # no canonical messages row and NO event row for the ephemeral stream
    assert Query.rows(
             Repo.query("SELECT 1 FROM chat_v2.messages WHERE message_id = $1", [
               message_id
             ])
           ) == []

    assert event_count(@channel, "message.created") == 0
  end

  # ------------------------------------------------- projections (#19)

  test "apply_effects: the live event frame carries the bot summary and components" do
    component_id = Ids.uuidv7()

    components = [
      %{
        "component_id" => component_id,
        "kind" => "button",
        "style" => "primary",
        "custom_id" => "go",
        "label" => "Go",
        "disabled" => false
      }
    ]

    {%{effect_results: [result], event_frames: [frame]}, _seq} =
      BotEffects.apply_effects(@channel, 0, @bot, [
        %{
          "type" => "send_message",
          "client_effect_id" => "proj-1",
          "message" => %{"type" => "text", "text" => "interactive", "components" => components}
        }
      ])

    assert result["status"] == "applied"
    message_id = result["message_id"]

    assert frame["type"] == "message.created"
    message = frame["payload"]["message"]

    # The bot sender is projected with the bot_apps summary (contract §3.4).
    assert message["sender"] == %{
             "kind" => "bot",
             "bot" => %{"bot_id" => @bot, "display_name" => "Test Bot", "avatar_url" => nil}
           }

    # components round-trip into the stored row and the live projection.
    assert Enum.map(message["components"], & &1["component_id"]) == [component_id]
    assert stored_component_ids(message_id) == [component_id]
  end

  # ------------------------------------------------------------- helpers

  defp seed_bot_attachment(attachment_id) do
    now = DateTime.utc_now()

    Repo.query!(
      """
      INSERT INTO chat_v2.attachments
        (attachment_id, owner_user_id, owner_bot_id, channel_id, kind, filename,
         mime_type, size_bytes, width, height, blurhash, storage_key, url, status, created_at)
      VALUES ($1, NULL, $2, $3, 'image', 'f.png', 'image/png', 10, 10, 10, NULL, $4, $5, 'finalized', $6)
      """,
      [
        attachment_id,
        @bot,
        @channel,
        "k/#{attachment_id}",
        "https://s3.example.com/#{attachment_id}",
        now
      ],
      type: true
    )
  end

  defp event_count(channel_id, event_type) do
    Repo.query(
      "SELECT COUNT(*) AS n FROM chat_v2.events WHERE channel_id = $1 AND event_type = $2",
      [channel_id, event_type]
    )
    |> case do
      {:ok, %{rows: [[n]]}} -> n
    end
  end

  defp linked_attachments(message_id) do
    Query.rows(
      Repo.query(
        "SELECT a.attachment_id AS attachment_id FROM chat_v2.message_attachments ma " <>
          "JOIN chat_v2.attachments a ON a.attachment_id = ma.attachment_id " <>
          "WHERE ma.message_id = $1 ORDER BY a.attachment_id",
        [message_id],
        type: true
      )
    )
    |> Enum.map(& &1["attachment_id"])
  end

  defp stored_components(message_id) do
    row =
      Query.rows(
        Repo.query(
          "SELECT components_json FROM chat_v2.messages WHERE message_id = $1",
          [message_id],
          type: true
        )
      )
      |> List.first()

    Projections.json_list(row["components_json"])
  end

  defp stored_component_ids(message_id) do
    stored_components(message_id) |> Enum.map(& &1["component_id"])
  end

  # Raw parameterized queries decode timestamptz as NaiveDateTime; parameterless
  # ones as DateTime — accept either.
  defp timestamp?(value), do: is_struct(value, NaiveDateTime) or is_struct(value, DateTime)
end
