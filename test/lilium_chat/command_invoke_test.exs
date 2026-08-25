defmodule LiliumChat.CommandInvokeTest do
  @moduledoc """
  `command.invoke` + `session.start` / `start_ack` + the interaction
  lifecycle tests (contract §9.5 / §9.6 / §9.12, issue #20):

  * stateless invoke — ack shape, invocation message, `command.invoked`
    event, `command_invocation` delivery, gates (channel / DM / dissolved /
    member / manifest version), `invoked_name` routing, current-catalog
    correctness (`BOT_COMMAND_DISABLED`), options validation, permission,
    `BOT_OFFLINE` precheck, idempotent replay, definition-drift snapshot
    refresh;
  * platform `/help` + `/permission` shortcuts (sync bot message +
    completed invocation; binding mutation);
  * stateful invoke — session row (`starting`), `session.start` frame,
    `STATEFUL_SESSION_BUSY` artifacts, `start_ack` activation (pin create),
    start-timeout force-close;
  * the `exclusive` component lock + `interaction.completed` / `.failed`
    delivery lifecycle.
  """

  use LiliumChat.DataCase, async: false

  import LiliumChatWeb.ReadFixtures
  import LiliumChatWeb.BotFixtures

  alias LiliumChat.{
    BotConnection,
    BotDelivery,
    BotGateway,
    Channel,
    ChannelPins,
    Errors,
    Projections,
    Query,
    Repo,
    StatefulSessions
  }

  @uid "6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e6f"
  @other "7a2f3d4e-5b6c-8d9e-0f1a-2b3c4d5e6f70"
  @help_id "00000000-0000-7000-8000-000000000700"
  @permission_id "00000000-0000-7000-8000-000000000708"

  # ----------------------------------------------------------------- helpers

  defp channel!(opts \\ []) do
    cid = "ch-s20-" <> Ecto.UUID.generate()

    seed_channel(
      cid,
      Keyword.merge([kind: "channel", visibility: "private", status: "active"], opts)
    )

    seed_membership(cid, @uid, "member")
    seed_membership(cid, @other, "member")
    cid
  end

  defp new_bot(display_name \\ "Invoke Bot") do
    bot_id = "bot-s20-" <> Ecto.UUID.generate()
    seed_bot("owner-s20", bot_id: bot_id, display_name: display_name)
    bot_id
  end

  defp stateless_command(bot_id, name, opts \\ []) do
    seed_bot_command(
      bot_id,
      name,
      Keyword.merge(
        [
          aliases: ["q"],
          options: [
            %{"name" => "prompt", "type" => "string", "required" => true},
            %{"name" => "count", "type" => "integer", "min" => 1, "max" => 10}
          ]
        ],
        opts
      )
    )
  end

  defp stateful_command(bot_id, name, opts \\ []) do
    seed_bot_command(
      bot_id,
      name,
      Keyword.merge(
        [
          execution_mode: "stateful",
          stateful_config: %{
            "mutex_scope" => "channel",
            "default_ttl_seconds" => 300,
            "max_ttl_seconds" => 600,
            "listen_capability" => %{
              "message_types" => ["text"],
              "include_bot_messages" => false,
              "include_own_messages" => false
            }
          }
        ],
        opts
      )
    )
  end

  defp bind!(cid, command_id, bot_id, opts \\ []) do
    # The binding snapshot is the channel's name source (invoked_name gate,
    # §9.5) — carry `:aliases` through so alias invocations match.
    aliases = Keyword.get(opts, :aliases, [])
    opts = Keyword.delete(opts, :aliases)

    seed_binding(
      cid,
      command_id,
      Keyword.merge(
        [
          bot_id: bot_id,
          snapshot:
            snapshot(command_id,
              name: "ask",
              aliases: aliases,
              bot_id: bot_id,
              bot_name: "Invoke Bot",
              options: [
                %{"name" => "prompt", "type" => "string", "required" => true},
                %{"name" => "count", "type" => "integer", "min" => 1, "max" => 10}
              ]
            )
        ],
        opts
      )
    )

    command_id
  end

  defp connect_bot!(bot_id) do
    %{ready: _ready, frames: _frames} = BotConnection.connect(bot_id, self(), nil)
    :ok
  end

  # Upgrade @other to owner (channel!() already seeds @other as member).
  defp make_other_owner!(cid) do
    Repo.query!(
      "UPDATE chat_v2.channel_members SET role = 'owner' WHERE channel_id = $1 AND user_id = $2",
      [cid, @other],
      type: true
    )
  end

  defp invoke(cid, command_id, payload) do
    Channel.invoke_command(cid, %{user_id: @uid, command_id: command_id, payload: payload})
  end

  defp events(channel_id) do
    Query.rows(
      Repo.query(
        "SELECT event_id, event_type, payload FROM chat_v2.events WHERE channel_id = $1 ORDER BY event_id",
        [channel_id],
        type: true
      )
    )
  end

  defp event_types(channel_id), do: Enum.map(events(channel_id), & &1["event_type"])

  defp invocation_rows(channel_id) do
    Query.rows(
      Repo.query(
        "SELECT * FROM chat_v2.command_invocations WHERE channel_id = $1 ORDER BY created_at",
        [channel_id],
        type: true
      )
    )
  end

  defp delivery_rows(channel_id) do
    Query.rows(
      Repo.query(
        "SELECT * FROM chat_v2.bot_deliveries WHERE channel_id = $1 ORDER BY created_at",
        [channel_id],
        type: true
      )
    )
  end

  defp session_row(session_id), do: StatefulSessions.get(session_id)

  defp payload_of(events, type) do
    Enum.find(events, &(&1["event_type"] == type))["payload"]
  end

  defp wait_for(fun, attempts \\ 200) do
    Enum.any?(1..attempts, fn _ ->
      if fun.() do
        true
      else
        Process.sleep(5)
        false
      end
    end)
  end

  # ------------------------------------------------------------- stateless

  test "invoke: stateless command → ack + invocation message + command.invoked + delivery" do
    cid = channel!()
    bot = new_bot()
    command_id = stateless_command(bot, "ask")
    bind!(cid, command_id, bot)
    connect_bot!(bot)

    assert {:ok, ack} =
             invoke(cid, "op-invoke-1", %{
               "bot_command_id" => command_id,
               "invoked_name" => "ask",
               "options" => %{"prompt" => %{"type" => "string", "value" => "hello"}}
             })

    assert %{"channel_id" => ^cid, "invocation_id" => invocation_id, "event_id" => event_id} = ack

    # invocation row: pending (completion happens on delivery_result)
    [inv] = invocation_rows(cid)
    assert inv["invocation_id"] == invocation_id
    assert inv["command_id"] == "op-invoke-1"
    assert inv["invoker_user_id"] == @uid
    assert inv["bot_id"] == bot
    assert inv["bot_command_id"] == command_id
    assert inv["command_name"] == "ask"
    assert inv["invoked_name"] == "ask"
    assert inv["status"] == "pending"
    assert inv["options_json"] == %{"prompt" => %{"type" => "string", "value" => "hello"}}

    # events: invocation message (message.created) then command.invoked
    assert event_types(cid) == ["message.created", "command.invoked"]

    invoked = payload_of(events(cid), "command.invoked")
    assert invoked["invocation"]["invocation_id"] == invocation_id
    assert invoked["invocation"]["status"] == "pending"
    assert invoked["command_id"] == "op-invoke-1"
    assert invoked["command_name"] == "ask"
    assert invoked["actor_user_id"] == @uid

    # the invocation message carries the invocation refs (stored shape:
    # stable refs only — the read path re-projects the full message)
    created = payload_of(events(cid), "message.created")
    message = created["message"]
    assert message["sender_kind"] == "user"
    assert message["sender_user_id"] == @uid
    assert message["text"] == "/ask hello"
    assert message["invocation_json"]["bot_command_id"] == command_id
    assert message["invocation_json"]["invoked_name"] == "ask"

    # delivery frame pushed live
    assert_receive {:bot_ws_push, frame}, 1_000
    assert frame["type"] == "delivery"
    assert frame["kind"] == "command_invocation"
    assert frame["invocation_id"] == invocation_id
    assert frame["channel_id"] == cid
    assert frame["command"]["bot_command_id"] == command_id
    assert frame["command"]["name"] == "ask"
    assert frame["command"]["invoked_name"] == "ask"
    assert frame["command"]["options"] == %{"prompt" => %{"type" => "string", "value" => "hello"}}
    assert frame["invoker"]["user_id"] == @uid

    # durable delivery row
    [delivery] = delivery_rows(cid)
    assert delivery["kind"] == "command_invocation"
    assert delivery["invocation_id"] == invocation_id
    assert delivery["status"] == "pending"

    # the ack event_id is the command.invoked event
    assert events(cid)
           |> Enum.find(&(&1["event_type"] == "command.invoked"))
           |> Map.get("event_id") ==
             event_id
  end

  test "invoke: alias invoked_name routes + display text uses the alias" do
    cid = channel!()
    bot = new_bot()
    command_id = stateless_command(bot, "ask", aliases: ["q"])
    bind!(cid, command_id, bot, aliases: ["q"])
    connect_bot!(bot)

    {:ok, ack} =
      invoke(cid, "op-invoke-2", %{
        "bot_command_id" => command_id,
        "invoked_name" => "q",
        "options" => %{"prompt" => %{"type" => "string", "value" => "hi"}}
      })

    assert ack["invocation_id"]

    created = payload_of(events(cid), "message.created")
    assert created["message"]["text"] == "/q hi"

    invoked = payload_of(events(cid), "command.invoked")
    # stored: canonical command_name + the invoked alias; the wire
    # `command_name` = invoked_name || canonical (read path)
    assert invoked["command_name"] == "ask"
    assert invoked["invoked_name"] == "q"

    [inv] = invocation_rows(cid)
    assert inv["invoked_name"] == "q"
  end

  test "invoke: read path re-projects command.invoked (command_name + actor) and interaction.created (component_label)" do
    cid = channel!()
    bot = new_bot()
    command_id = stateless_command(bot, "ask", aliases: ["q"])
    bind!(cid, command_id, bot, aliases: ["q"])
    connect_bot!(bot)

    {:ok, _ack} =
      invoke(cid, "op-invoke-2b", %{
        "bot_command_id" => command_id,
        "invoked_name" => "q",
        "options" => %{"prompt" => %{"type" => "string", "value" => "hi"}}
      })

    %{events: events} = LiliumChat.Timeline.channel_events(@uid, cid, nil, 10)

    invoked = Enum.find(events, &(&1["type"] == "command.invoked"))
    # wire command_name = invoked_name (the alias) || canonical
    assert invoked["payload"]["command_name"] == "q"
    assert invoked["payload"]["actor"]["user_id"] == @uid
  end

  test "invoke: wrong invoked_name → COMMAND_NOT_FOUND, nothing persisted" do
    cid = channel!()
    bot = new_bot()
    command_id = stateless_command(bot, "ask")
    bind!(cid, command_id, bot)
    connect_bot!(bot)

    assert {:error, %Errors.ApiError{code: "COMMAND_NOT_FOUND"}} =
             invoke(cid, "op-invoke-3", %{
               "bot_command_id" => command_id,
               "invoked_name" => "nope",
               "options" => %{"prompt" => %{"type" => "string", "value" => "x"}}
             })

    assert invocation_rows(cid) == []
    assert events(cid) == []
  end

  test "invoke: options validation (missing required / unknown / type mismatch) → INVALID_COMMAND_OPTIONS" do
    cid = channel!()
    bot = new_bot()
    command_id = stateless_command(bot, "ask")
    bind!(cid, command_id, bot)
    connect_bot!(bot)

    assert {:error, %Errors.ApiError{code: "INVALID_COMMAND_OPTIONS", message: msg1}} =
             invoke(cid, "op-invoke-4", %{
               "bot_command_id" => command_id,
               "options" => %{}
             })

    assert msg1 =~ "missing required option: prompt"

    assert {:error, %Errors.ApiError{code: "INVALID_COMMAND_OPTIONS", message: msg2}} =
             invoke(cid, "op-invoke-5", %{
               "bot_command_id" => command_id,
               "options" => %{
                 "prompt" => %{"type" => "string", "value" => "x"},
                 "bogus" => %{"type" => "string", "value" => "y"}
               }
             })

    assert msg2 =~ "unknown option: bogus"

    assert {:error, %Errors.ApiError{code: "INVALID_COMMAND_OPTIONS", message: msg3}} =
             invoke(cid, "op-invoke-6", %{
               "bot_command_id" => command_id,
               "options" => %{"prompt" => %{"type" => "integer", "value" => 5}}
             })

    assert msg3 =~ "type mismatch"
    assert invocation_rows(cid) == []
  end

  test "invoke: option min/max bounds (integer)" do
    cid = channel!()
    bot = new_bot()
    command_id = stateless_command(bot, "ask")
    bind!(cid, command_id, bot)
    connect_bot!(bot)

    assert {:error, %Errors.ApiError{code: "INVALID_COMMAND_OPTIONS"}} =
             invoke(cid, "op-invoke-7", %{
               "bot_command_id" => command_id,
               "options" => %{
                 "prompt" => %{"type" => "string", "value" => "x"},
                 "count" => %{"type" => "integer", "value" => 99}
               }
             })

    assert {:error, %Errors.ApiError{code: "INVALID_COMMAND_OPTIONS"}} =
             invoke(cid, "op-invoke-8", %{
               "bot_command_id" => command_id,
               "options" => %{
                 "prompt" => %{"type" => "string", "value" => "x"},
                 "count" => %{"type" => "integer", "value" => 0}
               }
             })

    {:ok, _} =
      invoke(cid, "op-invoke-9", %{
        "bot_command_id" => command_id,
        "options" => %{
          "prompt" => %{"type" => "string", "value" => "x"},
          "count" => %{"type" => "integer", "value" => 5}
        }
      })
  end

  test "invoke: bot offline → BOT_OFFLINE (retryable), nothing persisted" do
    cid = channel!()
    bot = new_bot()
    command_id = stateless_command(bot, "ask")
    bind!(cid, command_id, bot)
    # bot NOT connected

    assert {:error, %Errors.ApiError{code: "BOT_OFFLINE", retryable: true}} =
             invoke(cid, "op-invoke-10", %{
               "bot_command_id" => command_id,
               "options" => %{"prompt" => %{"type" => "string", "value" => "x"}}
             })

    assert invocation_rows(cid) == []
    assert events(cid) == []
  end

  test "invoke: blocked binding → COMMAND_NOT_ALLOWED (old-Worker parity)" do
    cid = channel!()
    bot = new_bot()
    command_id = stateless_command(bot, "ask")
    bind!(cid, command_id, bot, status: "blocked")
    connect_bot!(bot)

    assert {:error,
            %Errors.ApiError{
              code: "COMMAND_NOT_ALLOWED",
              message: "This slash command is not allowed in this channel.",
              retryable: false
            }} =
             invoke(cid, "op-invoke-11", %{
               "bot_command_id" => command_id,
               "options" => %{"prompt" => %{"type" => "string", "value" => "x"}}
             })
  end

  test "invoke: no binding + not official → COMMAND_NOT_ALLOWED (old-Worker parity)" do
    cid = channel!()
    bot = new_bot()
    command_id = stateless_command(bot, "ask")
    connect_bot!(bot)

    assert {:error,
            %Errors.ApiError{
              code: "COMMAND_NOT_ALLOWED",
              message: "This slash command is not allowed in this channel.",
              retryable: false
            }} =
             invoke(cid, "op-invoke-12", %{
               "bot_command_id" => command_id,
               "options" => %{"prompt" => %{"type" => "string", "value" => "x"}}
             })
  end

  test "invoke: official catalog fallback (no binding row needed)" do
    cid = channel!()
    bot = seed_bot("owner-s20", display_name: "Official Bot", visibility: "official")
    command_id = stateless_command(bot, "ask")
    connect_bot!(bot)

    {:ok, ack} =
      invoke(cid, "op-invoke-13", %{
        "bot_command_id" => command_id,
        "options" => %{"prompt" => %{"type" => "string", "value" => "x"}}
      })

    assert ack["invocation_id"]
    assert [inv] = invocation_rows(cid)
    assert inv["bot_id"] == bot
  end

  test "invoke: BOT_COMMAND_DISABLED when the catalog command is disabled" do
    cid = channel!()
    bot = new_bot()
    command_id = stateless_command(bot, "ask", status: "disabled")
    bind!(cid, command_id, bot)
    connect_bot!(bot)

    assert {:error, %Errors.ApiError{code: "BOT_COMMAND_DISABLED"}} =
             invoke(cid, "op-invoke-14", %{
               "bot_command_id" => command_id,
               "options" => %{"prompt" => %{"type" => "string", "value" => "x"}}
             })
  end

  test "invoke: permission gate → COMMAND_PERMISSION_DENIED" do
    cid = channel!()
    bot = new_bot()
    command_id = stateless_command(bot, "ask", permission: "owner")
    bind!(cid, command_id, bot)
    connect_bot!(bot)

    assert {:error, %Errors.ApiError{code: "COMMAND_PERMISSION_DENIED"}} =
             invoke(cid, "op-invoke-15", %{
               "bot_command_id" => command_id,
               "options" => %{"prompt" => %{"type" => "string", "value" => "x"}}
             })
  end

  test "invoke: DM channel → UNSUPPORTED_CHANNEL_KIND" do
    cid = channel!(kind: "dm")
    bot = new_bot()
    command_id = stateless_command(bot, "ask")

    assert {:error, %Errors.ApiError{code: "UNSUPPORTED_CHANNEL_KIND"}} =
             invoke(cid, "op-invoke-16", %{
               "bot_command_id" => command_id,
               "options" => %{}
             })
  end

  test "invoke: dissolved channel → CHANNEL_DISSOLVED" do
    cid = channel!(status: "dissolved")
    bot = new_bot()
    command_id = stateless_command(bot, "ask")

    assert {:error, %Errors.ApiError{code: "CHANNEL_DISSOLVED"}} =
             invoke(cid, "op-invoke-17", %{
               "bot_command_id" => command_id,
               "options" => %{}
             })
  end

  test "invoke: non-member → FORBIDDEN" do
    cid = channel!()
    bot = new_bot()
    command_id = stateless_command(bot, "ask")

    assert {:error, %Errors.ApiError{code: "FORBIDDEN"}} =
             Channel.invoke_command(cid, %{
               user_id: "not-a-member",
               command_id: "op-invoke-18",
               payload: %{"bot_command_id" => command_id, "options" => %{}}
             })
  end

  test "invoke: stale command_manifest_version → COMMAND_MANIFEST_VERSION_STALE" do
    cid = channel!()
    bot = new_bot()
    command_id = stateless_command(bot, "ask")
    bind!(cid, command_id, bot)
    connect_bot!(bot)

    # old-Worker parity (command.ts:260): the message carries no
    # `(current N)` suffix — contract §11 pins the code, not the wording.
    assert {:error,
            %Errors.ApiError{
              code: "COMMAND_MANIFEST_VERSION_STALE",
              message: "command manifest version is stale"
            }} =
             invoke(cid, "op-invoke-19", %{
               "bot_command_id" => command_id,
               "command_manifest_version" => 999,
               "options" => %{"prompt" => %{"type" => "string", "value" => "x"}}
             })

    # matching version passes (a fresh channel's manifest version is 0)
    {:ok, _} =
      invoke(cid, "op-invoke-20", %{
        "bot_command_id" => command_id,
        "command_manifest_version" => 0,
        "options" => %{"prompt" => %{"type" => "string", "value" => "x"}}
      })
  end

  test "invoke: reply_to_message_id resolves + MESSAGE_NOT_FOUND for a bad target" do
    cid = channel!()
    bot = new_bot()
    command_id = stateless_command(bot, "ask")
    bind!(cid, command_id, bot)
    connect_bot!(bot)

    # target message (user message)
    Repo.query!(
      """
      INSERT INTO chat_v2.messages (
        message_id, command_id, dedupe_principal_key, channel_id, sender_kind,
        sender_user_id, type, format, status, text, stream_state, created_at, updated_at
      ) VALUES ($1, $2, $3, $4, 'user', $5, 'text', 'plain', 'normal', $6, 'none', $7, $7)
      """,
      [
        "msg-reply-target",
        "op-x",
        "user:" <> @other,
        cid,
        @other,
        "reply me",
        DateTime.utc_now()
      ],
      type: true
    )

    {:ok, _} =
      invoke(cid, "op-invoke-21", %{
        "bot_command_id" => command_id,
        "reply_to_message_id" => "msg-reply-target",
        "options" => %{"prompt" => %{"type" => "string", "value" => "x"}}
      })

    assert {:error, %Errors.ApiError{code: "MESSAGE_NOT_FOUND"}} =
             invoke(cid, "op-invoke-22", %{
               "bot_command_id" => command_id,
               "reply_to_message_id" => "no-such-message",
               "options" => %{"prompt" => %{"type" => "string", "value" => "x"}}
             })
  end

  test "invoke: reply to an image message clears the stored reply snapshot text_preview (#26 B1)" do
    cid = channel!()
    bot = new_bot()
    command_id = stateless_command(bot, "ask")
    bind!(cid, command_id, bot)
    connect_bot!(bot)

    Repo.query!(
      """
      INSERT INTO chat_v2.messages (
        message_id, command_id, dedupe_principal_key, channel_id, sender_kind,
        sender_user_id, type, format, status, text, stream_state, created_at, updated_at
      ) VALUES ($1, $2, $3, $4, 'user', $5, 'image', 'plain', 'normal', NULL, 'none', $6, $6)
      """,
      ["msg-reply-img-target", "op-x", "user:" <> @other, cid, @other, DateTime.utc_now()],
      type: true
    )

    {:ok, _} =
      invoke(cid, "op-invoke-21b", %{
        "bot_command_id" => command_id,
        "reply_to_message_id" => "msg-reply-img-target",
        "options" => %{"prompt" => %{"type" => "string", "value" => "x"}}
      })

    [inv] =
      Query.rows(
        Repo.query(
          "SELECT reply_snapshot_json FROM chat_v2.messages " <>
            "WHERE channel_id = $1 AND invocation_json IS NOT NULL",
          [cid],
          type: true
        )
      )

    snapshot = Projections.json_map(inv["reply_snapshot_json"])
    assert snapshot["message_id"] == "msg-reply-img-target"
    assert snapshot["text_preview"] == ""
    refute Map.has_key?(snapshot, "media_preview")
  end

  test "invoke: idempotent replay returns the cached ack with no new events" do
    cid = channel!()
    bot = new_bot()
    command_id = stateless_command(bot, "ask")
    bind!(cid, command_id, bot)
    connect_bot!(bot)

    payload = %{
      "bot_command_id" => command_id,
      "invoked_name" => "ask",
      "options" => %{"prompt" => %{"type" => "string", "value" => "hello"}}
    }

    {:ok, ack1} = invoke(cid, "op-invoke-23", payload)
    {:ok, ack2} = invoke(cid, "op-invoke-23", payload)

    assert ack1 == ack2
    assert length(events(cid)) == 2
    assert length(invocation_rows(cid)) == 1
  end

  test "invoke: same command_id + different body → IDEMPOTENCY_CONFLICT, no artifacts" do
    cid = channel!()
    bot = new_bot()
    command_id = stateless_command(bot, "ask")
    bind!(cid, command_id, bot)
    connect_bot!(bot)

    {:ok, _} =
      invoke(cid, "op-invoke-24", %{
        "bot_command_id" => command_id,
        "options" => %{"prompt" => %{"type" => "string", "value" => "hello"}}
      })

    assert {:error, %Errors.ApiError{code: "IDEMPOTENCY_CONFLICT"}} =
             invoke(cid, "op-invoke-24", %{
               "bot_command_id" => command_id,
               "options" => %{"prompt" => %{"type" => "string", "value" => "different"}}
             })

    # the conflict leaves exactly the first invocation's artifacts
    assert length(events(cid)) == 2
    assert length(invocation_rows(cid)) == 1
  end

  test "invoke: definition drift refreshes the allowed binding snapshot" do
    cid = channel!()
    bot = new_bot()
    command_id = stateless_command(bot, "ask")
    bind!(cid, command_id, bot)
    connect_bot!(bot)

    # stored snapshot uses the old definition (no count option)
    Repo.query!(
      """
      UPDATE chat_v2.channel_command_bindings
      SET command_snapshot_json = $3
      WHERE channel_id = $1 AND bot_command_id = $2
      """,
      [
        cid,
        command_id,
        snapshot(command_id, name: "ask", bot_id: bot, bot_name: "Invoke Bot", options: [])
      ],
      type: true
    )

    {:ok, _} =
      invoke(cid, "op-invoke-25", %{
        "bot_command_id" => command_id,
        "options" => %{"prompt" => %{"type" => "string", "value" => "x"}}
      })

    # the binding snapshot was refreshed to the current definition
    [binding] =
      Query.rows(
        Repo.query(
          "SELECT command_snapshot_json FROM chat_v2.channel_command_bindings WHERE channel_id = $1 AND bot_command_id = $2",
          [cid, command_id]
        )
      )

    refreshed = Projections.json_map(binding["command_snapshot_json"])
    assert length(refreshed["options"]) == 2
  end

  # ------------------------------------------------------------ platform

  test "/help: sync bot message + completed invocation + ack with message" do
    cid = channel!()
    bot = new_bot()
    command_id = stateless_command(bot, "ask")
    bind!(cid, command_id, bot)

    {:ok, ack} =
      invoke(cid, "op-help-1", %{
        "bot_command_id" => @help_id,
        "options" => %{}
      })

    assert %{
             "channel_id" => ^cid,
             "invocation_id" => _invocation_id,
             "event_id" => _event_id,
             "message_id" => _message_id,
             "message" => message
           } = ack

    assert message["sender"]["kind"] == "bot"
    assert message["sender"]["bot"]["bot_id"] == "00000000-0000-7000-8000-000000000600"
    assert message["format"] == "markdown"
    assert message["text"] =~ "/ask"
    assert message["text"] =~ "test command"

    [inv] = invocation_rows(cid)
    assert inv["status"] == "completed"
    assert inv["bot_command_id"] == @help_id

    # events: invocation message + the help bot message (message.created x2)
    assert event_types(cid) == ["message.created", "message.created"]
  end

  test "/help: command option returns that command's help_text" do
    cid = channel!()
    bot = new_bot()
    command_id = stateless_command(bot, "ask", help_text: "Ask me anything")
    # the manifest (which /help lists) reads the BINDING SNAPSHOT — seed its
    # help_text so the option lookup returns it (stale-snapshot drift is the
    # invoke-time concern, not /help).
    bind!(cid, command_id, bot,
      snapshot:
        snapshot(command_id,
          name: "ask",
          bot_id: bot,
          bot_name: "Invoke Bot",
          help_text: "Ask me anything"
        )
    )

    {:ok, ack} =
      invoke(cid, "op-help-2", %{
        "bot_command_id" => @help_id,
        "options" => %{"command" => %{"type" => "string", "value" => "ask"}}
      })

    assert ack["message"]["text"] == "Ask me anything"
  end

  test "/help: unknown command option → 未知命令 text" do
    cid = channel!()

    {:ok, ack} =
      invoke(cid, "op-help-3", %{
        "bot_command_id" => @help_id,
        "options" => %{"command" => %{"type" => "string", "value" => "bogus"}}
      })

    assert ack["message"]["text"] == "未知命令: bogus"
  end

  test "/permission: member caller → COMMAND_PERMISSION_DENIED" do
    cid = channel!()

    assert {:error, %Errors.ApiError{code: "COMMAND_PERMISSION_DENIED"}} =
             invoke(cid, "op-perm-1", %{
               "bot_command_id" => @permission_id,
               "options" => %{}
             })
  end

  test "/permission: owner lists commands" do
    cid = channel!()
    make_other_owner!(cid)
    bot = new_bot()
    command_id = stateless_command(bot, "ask")
    bind!(cid, command_id, bot)

    {:ok, ack} =
      Channel.invoke_command(cid, %{
        user_id: @other,
        command_id: "op-perm-2",
        payload: %{"bot_command_id" => @permission_id, "options" => %{}}
      })

    assert ack["message"]["text"] =~ "当前频道命令权限"
    assert ack["message"]["text"] =~ "/ask"

    [inv] = invocation_rows(cid)
    assert inv["status"] == "completed"
  end

  test "/permission: on/off mutates the binding + binding_updated event" do
    cid = channel!()
    make_other_owner!(cid)
    bot = new_bot()
    command_id = stateless_command(bot, "ask")
    bind!(cid, command_id, bot)

    # off → blocked
    {:ok, _} =
      Channel.invoke_command(cid, %{
        user_id: @other,
        command_id: "op-perm-3",
        payload: %{
          "bot_command_id" => @permission_id,
          "options" => %{
            "command" => %{"type" => "string", "value" => "ask"},
            "action" => %{"type" => "string", "value" => "off"}
          }
        }
      })

    [binding] =
      Query.rows(
        Repo.query(
          "SELECT status FROM chat_v2.channel_command_bindings WHERE channel_id = $1 AND bot_command_id = $2",
          [cid, command_id]
        )
      )

    assert binding["status"] == "blocked"

    assert "command.binding_updated" in event_types(cid)

    # on → allowed again
    {:ok, _} =
      Channel.invoke_command(cid, %{
        user_id: @other,
        command_id: "op-perm-4",
        payload: %{
          "bot_command_id" => @permission_id,
          "options" => %{
            "command" => %{"type" => "string", "value" => "ask"},
            "action" => %{"type" => "string", "value" => "on"}
          }
        }
      })

    [binding2] =
      Query.rows(
        Repo.query(
          "SELECT status FROM chat_v2.channel_command_bindings WHERE channel_id = $1 AND bot_command_id = $2",
          [cid, command_id]
        )
      )

    assert binding2["status"] == "allowed"
  end

  test "/permission: on for an unblocked official command → OFFICIAL_COMMAND_AUTO_ALLOWED" do
    cid = channel!()
    make_other_owner!(cid)
    bot = seed_bot("owner-s20", display_name: "Official Bot", visibility: "official")
    _command_id = stateless_command(bot, "ask")

    assert {:error, %Errors.ApiError{code: "OFFICIAL_COMMAND_AUTO_ALLOWED"}} =
             Channel.invoke_command(cid, %{
               user_id: @other,
               command_id: "op-perm-5",
               payload: %{
                 "bot_command_id" => @permission_id,
                 "options" => %{
                   "command" => %{"type" => "string", "value" => "ask"},
                   "action" => %{"type" => "string", "value" => "on"}
                 }
               }
             })
  end

  # -------------------------------------------------------------- stateful

  test "stateful invoke: session row (starting) + session.start frame + ack with session_id" do
    cid = channel!()
    bot = new_bot()
    command_id = stateful_command(bot, "session_cmd")
    bind!(cid, command_id, bot)
    connect_bot!(bot)

    {:ok, ack} =
      invoke(cid, "op-state-1", %{
        "bot_command_id" => command_id,
        "options" => %{}
      })

    assert %{
             "channel_id" => ^cid,
             "invocation_id" => invocation_id,
             "session_id" => session_id,
             "event_id" => _event_id
           } = ack

    session = session_row(session_id)
    assert session["status"] == "starting"
    assert session["bot_id"] == bot
    assert session["bot_command_id"] == command_id
    assert session["invocation_id"] == invocation_id
    assert session["started_by_user_id"] == @uid
    assert session["input_next_seq"] == 1
    assert session["input_last_acked_seq"] == 0
    assert session["effect_last_acked_seq"] == 0

    # session.start frame pushed live
    assert_receive {:bot_ws_push, frame}, 1_000
    assert frame["type"] == "session.start"
    assert frame["api_version"] == BotGateway.api_version()
    assert frame["session_id"] == session_id
    assert frame["channel_id"] == cid
    assert frame["bot_command"]["bot_command_id"] == command_id
    assert frame["bot_command"]["name"] == "session_cmd"
    assert frame["invoker"]["user_id"] == @uid
    assert frame["listen_rules"]["message_types"] == ["text"]
    assert frame["input_seq_start"] == 1
    assert frame["expires_at"]

    # stateful invokes carry no `command_invocations` row (the session row
    # is the business record; old Worker `statefulCommandInvoke`); only the
    # invocation message event is on the timeline.
    assert invocation_rows(cid) == []
    assert event_types(cid) == ["message.created"]
  end

  test "stateful invoke: busy channel → STATEFUL_SESSION_BUSY + command.failed artifacts" do
    cid = channel!()
    bot = new_bot()
    command_id = stateful_command(bot, "session_cmd")
    bind!(cid, command_id, bot)
    connect_bot!(bot)

    # seed an active session WITH its session_control pin (a pin-less active
    # session would be closed as an orphan first — old Worker
    # `closeOrphanStatefulSessionWithoutControlPin`).
    session =
      StatefulSessions.seed_active(%{channel_id: cid, bot_id: bot, started_by_user_id: @uid})

    ChannelPins.upsert_session_control(cid, session["session_id"], "session_cmd", "starter")

    # Busy invoke returns the 3-tuple `{:error, api_error, event_frames}` —
    # the failure artifacts (invocation message + command.failed) the caller
    # pushes to its own socket before the `command_error` (issue #27 batch D).
    assert {:error, %Errors.ApiError{code: "STATEFUL_SESSION_BUSY"}, _frames} =
             invoke(cid, "op-state-2", %{
               "bot_command_id" => command_id,
               "options" => %{}
             })

    # the invocation message + command.failed artifact were committed
    assert event_types(cid) == ["message.created", "command.failed"]
    failed = payload_of(events(cid), "command.failed")
    assert failed["error_code"] == "STATEFUL_SESSION_BUSY"

    # no second session row
    rows =
      Query.rows(
        Repo.query(
          "SELECT COUNT(*) AS n FROM chat_v2.stateful_command_sessions WHERE channel_id = $1",
          [cid]
        )
      )

    assert hd(rows)["n"] == 1
  end

  test "start_ack: starting → active + stateful_session.started + session_control pin" do
    cid = channel!()
    bot = new_bot()
    command_id = stateful_command(bot, "session_cmd")
    bind!(cid, command_id, bot)
    connect_bot!(bot)

    {:ok, ack} =
      invoke(cid, "op-state-3", %{
        "bot_command_id" => command_id,
        "options" => %{}
      })

    session_id = ack["session_id"]

    assert_receive {:bot_ws_push, %{"type" => "session.start"}}, 1_000

    {:ok, %{}} = Channel.session_start_ack(cid, %{session_id: session_id})

    session = session_row(session_id)
    assert session["status"] == "active"

    # events: invocation message → stateful_session.started → channel.pin.set
    assert event_types(cid) == [
             "message.created",
             "stateful_session.started",
             "channel.pin.set"
           ]

    started = payload_of(events(cid), "stateful_session.started")
    # Contract-silent → old Worker shape: the payload NESTS a `session` object
    # (issue #27 batch D) — not a flat top-level `session_id`.
    assert started["session"]["session_id"] == session_id
    assert started["session"]["status"] == "active"
    assert started["session"]["command_name"] == "session_cmd"
    assert started["session"]["started_by"]["user_id"] == @uid

    pin = ChannelPins.get_session_control_pin(cid)
    assert pin["pin_kind"] == "session_control"
    assert pin["pin_owner_kind"] == "platform"
    assert pin["session_id"] == session_id

    pin_projection = Projections.json_map(pin["message_projection_json"])
    assert pin_projection["text"] =~ "/session_cmd"
    stop = hd(pin_projection["components"])
    assert stop["custom_id"] == BotGateway.platform_stop_session_custom_id()
    assert stop["interaction_policy"] == "per_user_once"
  end

  test "start_ack: session not in starting state → STATEFUL_SESSION_NOT_ACTIVE" do
    cid = channel!()
    bot = new_bot()
    session = StatefulSessions.seed_active(%{channel_id: cid, bot_id: bot})

    assert {:error, %Errors.ApiError{code: "STATEFUL_SESSION_NOT_ACTIVE"}} =
             Channel.session_start_ack(cid, %{session_id: session["session_id"]})
  end

  test "start_timeout: force-closes a starting session (start_timeout)" do
    cid = channel!()
    bot = new_bot()
    command_id = stateful_command(bot, "session_cmd")
    bind!(cid, command_id, bot)
    connect_bot!(bot)

    {:ok, ack} =
      invoke(cid, "op-state-4", %{
        "bot_command_id" => command_id,
        "options" => %{}
      })

    session_id = ack["session_id"]

    # fire the writer's start-timeout timer directly (30 s in production)
    [{pid, _}] = Registry.lookup(LiliumChat.Channels.Registry, cid)
    send(pid, {:session_start_timeout, session_id})

    assert wait_for(fn -> session_row(session_id)["status"] == "closed" end)

    row = session_row(session_id)
    assert row["close_reason"] == "start_timeout"

    closed = payload_of(events(cid), "stateful_session.closed")
    assert closed["reason"] == "start_timeout"
  end

  test "stateful invoke: TTL = min(default, max, binding cap)" do
    cid = channel!()
    bot = new_bot()
    command_id = stateful_command(bot, "session_cmd")
    # binding cap below the default TTL
    bind!(cid, command_id, bot, stateful_max_ttl_seconds: 60)
    connect_bot!(bot)

    {:ok, ack} =
      invoke(cid, "op-state-5", %{
        "bot_command_id" => command_id,
        "options" => %{}
      })

    session = session_row(ack["session_id"])
    ttl = NaiveDateTime.diff(session["expires_at"], session["started_at"], :second)
    assert ttl == 60
  end

  # --------------------------------------------- interaction lifecycle (#20)

  test "exclusive lock: submit writes disabled component + message.updated before interaction.created" do
    cid = channel!()
    bot = new_bot()
    connect_bot!(bot)

    # subscribe for the live broadcast (component_label assertion)
    Phoenix.PubSub.subscribe(LiliumChat.PubSub, "channel:" <> cid)

    # a bot message with an exclusive button
    message_id = "msg-exclusive-" <> Ecto.UUID.generate()
    component_id = "comp-exclusive-" <> Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO chat_v2.messages (
        message_id, command_id, dedupe_principal_key, channel_id, sender_kind,
        sender_bot_id, type, format, status, text,
        components_json, stream_state, created_at, updated_at
      ) VALUES ($1, $2, $3, $4, 'bot', $5, 'text', 'plain', 'normal',
                'Pick one', $6, 'none', $7, $7)
      """,
      [
        message_id,
        "op-x",
        "bot:" <> bot,
        cid,
        bot,
        [
          %{
            "component_id" => component_id,
            "kind" => "button",
            "custom_id" => "pick",
            "label" => "Pick",
            "style" => "primary",
            "disabled" => false,
            "interaction_policy" => "exclusive"
          }
        ],
        DateTime.utc_now()
      ],
      type: true
    )

    {:ok, ack} =
      Channel.submit_interaction(cid, %{
        user_id: @uid,
        command_id: "op-x1",
        payload: %{
          "message_id" => message_id,
          "component_id" => component_id,
          "custom_id" => "pick",
          "value" => true
        }
      })

    assert %{"interaction_id" => _id, "event_id" => _eid} = ack

    # events: message.updated (lock) FIRST, then interaction.created
    assert event_types(cid) == ["message.updated", "interaction.created"]

    # the lock event references the message (the stored lifecycle payload
    # carries no components — the read path re-projects them)
    locked = payload_of(events(cid), "message.updated")
    assert locked["message"]["message_id"] == message_id
    assert locked["message"]["text"] == "Pick one"

    # the LIVE interaction.created broadcast carries `component_label`
    # (contract §9.6), matching the replay projection
    assert_receive {:broadcast, _topic, %{"type" => "interaction.created"} = frame}, 1_000
    assert frame["payload"]["component_label"] == "Pick"

    # the stored message row reflects the lock
    [row] =
      Query.rows(
        Repo.query(
          "SELECT components_json FROM chat_v2.messages WHERE message_id = $1",
          [message_id]
        )
      )

    [stored_component] = Projections.json_list(row["components_json"])
    assert stored_component["disabled"] == true

    # a second submit → COMPONENT_ALREADY_USED
    assert {:error, %Errors.ApiError{code: "COMPONENT_ALREADY_USED"}} =
             Channel.submit_interaction(cid, %{
               user_id: @other,
               command_id: "op-x2",
               payload: %{
                 "message_id" => message_id,
                 "component_id" => component_id,
                 "custom_id" => "pick",
                 "value" => true
               }
             })
  end

  test "interaction.completed: delivery_result finalizes with the message projection" do
    cid = channel!()
    bot = new_bot()
    connect_bot!(bot)

    message_id = "msg-complete-" <> Ecto.UUID.generate()
    component_id = "comp-complete-" <> Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO chat_v2.messages (
        message_id, command_id, dedupe_principal_key, channel_id, sender_kind,
        sender_bot_id, type, format, status, text,
        components_json, stream_state, created_at, updated_at
      ) VALUES ($1, $2, $3, $4, 'bot', $5, 'text', 'plain', 'normal',
                'Pick one', $6, 'none', $7, $7)
      """,
      [
        message_id,
        "op-x",
        "bot:" <> bot,
        cid,
        bot,
        [
          %{
            "component_id" => component_id,
            "kind" => "button",
            "custom_id" => "confirm",
            "label" => "Confirm",
            "style" => "primary",
            "disabled" => false,
            "interaction_policy" => "multi"
          }
        ],
        DateTime.utc_now()
      ],
      type: true
    )

    {:ok, ack} =
      Channel.submit_interaction(cid, %{
        user_id: @uid,
        command_id: "op-i1",
        payload: %{
          "message_id" => message_id,
          "component_id" => component_id,
          "custom_id" => "confirm",
          "value" => true
        }
      })

    interaction_id = ack["interaction_id"]

    # the bot answers the delivery with effects: [] (contract §9.6.1)
    assert_receive {:bot_ws_push, %{"type" => "delivery", "delivery_id" => delivery_id}}, 1_000

    ack_frame = BotDelivery.apply_result(bot, delivery_id, [])
    assert ack_frame["status"] == "applied"

    # interaction.completed event: content-bearing message projection
    assert "interaction.completed" in event_types(cid)
    completed = payload_of(events(cid), "interaction.completed")
    assert completed["command_id"] == "op-i1"
    # stored shape: stable message refs (components re-projected on replay —
    # the LIVE broadcast frame carries the full projection with components)
    assert completed["message"]["message_id"] == message_id
    assert completed["message"]["text"] == "Pick one"
    assert completed["message"]["sender_bot_id"] == bot

    [interaction] =
      Query.rows(
        Repo.query(
          "SELECT status FROM chat_v2.interactions WHERE interaction_id = $1",
          [interaction_id]
        )
      )

    assert interaction["status"] == "completed"
  end

  test "interaction.failed: invalid delivery_result effects → interaction.failed event" do
    cid = channel!()
    bot = new_bot()
    connect_bot!(bot)

    message_id = "msg-fail-" <> Ecto.UUID.generate()
    component_id = "comp-fail-" <> Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO chat_v2.messages (
        message_id, command_id, dedupe_principal_key, channel_id, sender_kind,
        sender_bot_id, type, format, status, text,
        components_json, stream_state, created_at, updated_at
      ) VALUES ($1, $2, $3, $4, 'bot', $5, 'text', 'plain', 'normal',
                'Pick one', $6, 'none', $7, $7)
      """,
      [
        message_id,
        "op-x",
        "bot:" <> bot,
        cid,
        bot,
        [
          %{
            "component_id" => component_id,
            "kind" => "button",
            "custom_id" => "confirm",
            "label" => "Confirm",
            "style" => "primary",
            "disabled" => false,
            "interaction_policy" => "multi"
          }
        ],
        DateTime.utc_now()
      ],
      type: true
    )

    {:ok, ack} =
      Channel.submit_interaction(cid, %{
        user_id: @uid,
        command_id: "op-i2",
        payload: %{
          "message_id" => message_id,
          "component_id" => component_id,
          "custom_id" => "confirm",
          "value" => true
        }
      })

    interaction_id = ack["interaction_id"]

    assert_receive {:bot_ws_push, %{"type" => "delivery", "delivery_id" => delivery_id}}, 1_000

    # an invalid effect (append_stream is rejected on the main gateway)
    ack_frame = BotDelivery.apply_result(bot, delivery_id, [%{"type" => "append_stream"}])
    assert ack_frame["status"] == "failed"

    assert "interaction.failed" in event_types(cid)
    failed = payload_of(events(cid), "interaction.failed")
    assert failed["command_id"] == "op-i2"
    assert failed["error_code"] == "BOT_EFFECT_INVALID"
    assert failed["retryable"] == false

    [interaction] =
      Query.rows(
        Repo.query(
          "SELECT status FROM chat_v2.interactions WHERE interaction_id = $1",
          [interaction_id]
        )
      )

    assert interaction["status"] == "failed"
  end

  test "BotGateway: session.start_ack parse" do
    assert {:ok, %{session_id: "s1"}} =
             BotGateway.parse_session_start_ack(%{
               "type" => "session.start_ack",
               "api_version" => BotGateway.api_version(),
               "session_id" => "s1"
             })

    assert {:error, _} =
             BotGateway.parse_session_start_ack(%{
               "type" => "session.start_ack",
               "api_version" => BotGateway.api_version(),
               "session_id" => 5
             })

    assert {:error, _} =
             BotGateway.parse_session_start_ack(%{
               "type" => "session.close",
               "session_id" => "s1"
             })
  end
end
