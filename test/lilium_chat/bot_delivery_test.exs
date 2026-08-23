defmodule LiliumChat.BotDeliveryTest do
  @moduledoc """
  Bot delivery commit + offline policy + crash recovery tests
  (contract §9.7 / spec D14, issue #17).

  Covers the issue acceptance criteria:

  * AC2 — `BOT_OFFLINE` precheck does not persist the invocation;
  * AC3 — crash → `bot_deliveries` recovery + resume on reconnect.
  """

  use LiliumChat.DataCase, async: false

  import LiliumChatWeb.BotFixtures

  alias LiliumChat.{BotConnection, BotDelivery, Query, Repo}

  defp bot_id(), do: "bot-del-" <> LiliumChat.Ids.uuidv7()

  defp channel_id(), do: "ch-del-" <> LiliumChat.Ids.uuidv7()

  setup do
    # Short TTLs so the offline-policy paths are testable without sleeps.
    Application.put_env(:lilium_chat, :bot_gateway,
      lease_ttl_ms: 60_000,
      offline_ttl_ms: 30_000,
      message_event_ttl_ms: 1_000
    )

    on_exit(fn ->
      Application.put_env(:lilium_chat, :bot_gateway,
        lease_ttl_ms: 60_000,
        offline_ttl_ms: 30_000,
        message_event_ttl_ms: 30_000
      )
    end)

    :ok
  end

  defp connect_bot!(bot_id, channel_pid \\ self()) do
    %{ready: ready, frames: frames} = BotConnection.connect(bot_id, channel_pid, nil)
    {ready, frames}
  end

  defp invocation_attrs(bot_id, channel_id) do
    %{
      channel_id: channel_id,
      bot_id: bot_id,
      invoker_user_id: "user-inv-001",
      bot_command_id: "bc-001",
      command_name: "ask",
      invoked_name: "ask",
      schema_version: 3,
      definition_hash: "sha256:abc",
      options: %{"q" => "hello"}
    }
  end

  defp interaction_attrs(bot_id, channel_id) do
    %{
      channel_id: channel_id,
      bot_id: bot_id,
      actor_user_id: "user-act-001",
      message_id: "msg-001",
      component_id: "cmp-001",
      custom_id: "confirm",
      value: true,
      command_id: "cmd-001",
      dedupe_principal_key: "channel:#{channel_id}:user-act-001:msg-001:cmp-001"
    }
  end

  defp message_projection do
    %{
      "message_id" => "msg-001",
      "command_id" => "cmd-001",
      "channel_id" => "ch-x",
      "sender" => %{
        "kind" => "user",
        "user" => %{"user_id" => "user-act-001", "display_name" => "Kuma", "avatar_url" => nil}
      },
      "type" => "text",
      "format" => "plain",
      "status" => "normal",
      "stream_state" => "none",
      "text" => "hello everyone",
      "reply_to" => nil,
      "reply_snapshot" => nil,
      "attachments" => [],
      "sticker" => nil,
      "components" => [],
      "mentions" => [],
      "command_invocation" => nil,
      "created_at" => "2026-08-23T00:00:00Z",
      "updated_at" => "2026-08-23T00:00:00Z",
      "edited_at" => nil,
      "deleted_at" => nil,
      "recalled_at" => nil
    }
  end

  # ------------------------------------------------------------- AC2 precheck

  test "AC2: commit_invocation while offline → BOT_OFFLINE, nothing persisted" do
    bot_id = bot_id()
    seed_bot("owner-1", bot_id: bot_id)
    channel_id = channel_id()

    assert {:error, %LiliumChat.Errors.ApiError{code: "BOT_OFFLINE"}} =
             BotDelivery.commit_invocation(invocation_attrs(bot_id, channel_id))

    assert count_rows("SELECT 1 FROM chat_v2.command_invocations ci WHERE ci.bot_id = $1", [
             bot_id
           ]) == 0

    assert count_rows("SELECT 1 FROM chat_v2.bot_deliveries bd WHERE bd.bot_id = $1", [bot_id]) ==
             0
  end

  test "AC2: commit_interaction while offline → BOT_OFFLINE, nothing persisted" do
    bot_id = bot_id()
    seed_bot("owner-1", bot_id: bot_id)
    channel_id = channel_id()

    assert {:error, %LiliumChat.Errors.ApiError{code: "BOT_OFFLINE"}} =
             BotDelivery.commit_interaction(interaction_attrs(bot_id, channel_id))

    assert count_rows(
             "SELECT 1 FROM chat_v2.interactions i WHERE i.message_id = 'msg-001' AND i.actor_user_id = 'user-act-001'",
             []
           ) == 0

    assert count_rows("SELECT 1 FROM chat_v2.bot_deliveries bd WHERE bd.bot_id = $1", [bot_id]) ==
             0
  end

  test "commit_message_event while offline is passive (no error, row pending)" do
    bot_id = bot_id()
    seed_bot("owner-1", bot_id: bot_id)
    channel_id = channel_id()

    assert {:ok, %{delivery_id: delivery_id}} =
             BotDelivery.commit_message_event(%{
               channel_id: channel_id,
               bot_id: bot_id,
               event_id: "evt-001",
               message: message_projection()
             })

    assert delivery_id

    assert count_rows(
             "SELECT 1 FROM chat_v2.bot_deliveries bd WHERE bd.bot_id = $1 AND bd.status = 'pending'",
             [bot_id]
           ) == 1
  end

  # ------------------------------------------------------- commit while online

  test "commit_invocation while online persists rows and pushes the delivery frame" do
    bot_id = bot_id()
    seed_bot("owner-1", bot_id: bot_id)
    channel_id = channel_id()

    connect_bot!(bot_id)

    assert {:ok, %{delivery_id: delivery_id, invocation_id: invocation_id}} =
             BotDelivery.commit_invocation(invocation_attrs(bot_id, channel_id))

    assert_receive {:bot_ws_push, frame}, 1_000

    # envelope
    assert frame["type"] == "delivery"
    assert frame["api_version"] == "lilium.chat.bot.v1"
    assert frame["delivery_id"] == delivery_id
    assert frame["kind"] == "command_invocation"
    assert frame["channel_id"] == channel_id

    # contract §9.7.1 body
    assert frame["invocation_id"] == invocation_id

    assert %{
             "bot_command_id" => "bc-001",
             "name" => "ask",
             "invoked_name" => "ask",
             "schema_version" => 3,
             "definition_hash" => "sha256:abc",
             "options" => %{"q" => "hello"}
           } = frame["command"]

    assert %{"user_id" => "user-inv-001", "display_name" => _name} = frame["invoker"]

    # rows persisted
    assert count_rows(
             "SELECT 1 FROM chat_v2.command_invocations ci WHERE ci.invocation_id = $1 AND ci.status = 'pending'",
             [invocation_id]
           ) == 1

    assert count_rows(
             "SELECT 1 FROM chat_v2.bot_deliveries bd WHERE bd.delivery_id = $1 AND bd.status = 'pending'",
             [delivery_id]
           ) == 1
  end

  test "commit_interaction while online pushes the message_interaction frame" do
    bot_id = bot_id()
    seed_bot("owner-1", bot_id: bot_id)
    channel_id = channel_id()

    connect_bot!(bot_id)

    assert {:ok, %{delivery_id: delivery_id, interaction_id: interaction_id}} =
             BotDelivery.commit_interaction(interaction_attrs(bot_id, channel_id))

    assert_receive {:bot_ws_push, frame}, 1_000

    assert frame["type"] == "delivery"
    assert frame["delivery_id"] == delivery_id
    assert frame["kind"] == "message_interaction"
    assert frame["channel_id"] == channel_id
    assert frame["interaction_id"] == interaction_id
    assert frame["message_id"] == "msg-001"

    assert %{
             "component_id" => "cmp-001",
             "custom_id" => "confirm",
             "value" => true
           } = frame["component"]

    assert %{"user_id" => "user-act-001"} = frame["actor"]
  end

  test "commit_message_event while online pushes the message_event frame" do
    bot_id = bot_id()
    seed_bot("owner-1", bot_id: bot_id)
    channel_id = channel_id()

    connect_bot!(bot_id)

    assert {:ok, %{delivery_id: delivery_id}} =
             BotDelivery.commit_message_event(%{
               channel_id: channel_id,
               bot_id: bot_id,
               event_id: "evt-001",
               occurred_at: ~U[2026-08-23 00:00:00Z],
               message: message_projection()
             })

    assert_receive {:bot_ws_push, frame}, 1_000

    assert frame["type"] == "delivery"
    assert frame["delivery_id"] == delivery_id
    assert frame["kind"] == "message_event"
    assert frame["channel_id"] == channel_id

    assert %{"event_id" => "evt-001", "type" => "message.created", "occurred_at" => occurred} =
             frame["event"]

    assert occurred =~ "2026-08-23T00:00:00"

    assert frame["message"]["text"] == "hello everyone"
    assert frame["message"]["sender"]["user"]["user_id"] == "user-act-001"
  end

  # -------------------------------------------------------- delivery_result

  test "delivery_result: unknown delivery_id → failed ack" do
    bot_id = bot_id()
    seed_bot("owner-1", bot_id: bot_id)

    connect_bot!(bot_id)

    ack =
      BotConnection.deliver_result(bot_id, "no-such-delivery", [
        %{
          "type" => "send_message",
          "client_effect_id" => "ce-1",
          "message" => %{"type" => "text", "text" => "hi"}
        }
      ])

    assert ack["type"] == "delivery_ack"
    assert ack["status"] == "failed"
    assert ack["error"]["code"] == "BOT_EFFECT_INVALID"
  end

  test "delivery_result: send_message effect → applied ack + rows completed (AC3 part 2)" do
    bot_id = bot_id()
    seed_bot("owner-1", bot_id: bot_id)
    channel_id = channel_id()

    connect_bot!(bot_id)

    assert {:ok, %{delivery_id: delivery_id, invocation_id: invocation_id}} =
             BotDelivery.commit_invocation(invocation_attrs(bot_id, channel_id))

    assert_receive {:bot_ws_push, _frame}, 1_000

    ack =
      BotConnection.deliver_result(bot_id, delivery_id, [
        %{
          "type" => "send_message",
          "client_effect_id" => "ce-1",
          "message" => %{"type" => "text", "text" => "the answer"}
        }
      ])

    assert ack["type"] == "delivery_ack"
    assert ack["api_version"] == "lilium.chat.bot.v1"
    assert ack["delivery_id"] == delivery_id
    assert ack["status"] == "applied"

    assert [
             %{
               "type" => "send_message",
               "status" => "applied",
               "client_effect_id" => "ce-1",
               "message_id" => message_id
             }
           ] =
             ack["effect_results"]

    assert is_binary(message_id)

    assert count_rows(
             "SELECT 1 FROM chat_v2.bot_deliveries bd WHERE bd.delivery_id = $1 AND bd.status = 'delivered' AND bd.delivered_at IS NOT NULL",
             [delivery_id]
           ) == 1

    assert count_rows(
             "SELECT 1 FROM chat_v2.command_invocations ci WHERE ci.invocation_id = $1 AND ci.status = 'completed'",
             [invocation_id]
           ) == 1
  end

  test "delivery_result: duplicate result (at-least-once replay) replays the same ack" do
    bot_id = bot_id()
    seed_bot("owner-1", bot_id: bot_id)
    channel_id = channel_id()

    connect_bot!(bot_id)

    assert {:ok, %{delivery_id: delivery_id}} =
             BotDelivery.commit_invocation(invocation_attrs(bot_id, channel_id))

    assert_receive {:bot_ws_push, _frame}, 1_000

    effects = [
      %{
        "type" => "send_message",
        "client_effect_id" => "ce-1",
        "message" => %{"type" => "text", "text" => "once"}
      }
    ]

    ack1 = BotConnection.deliver_result(bot_id, delivery_id, effects)
    ack2 = BotConnection.deliver_result(bot_id, delivery_id, effects)

    assert ack1["status"] == "applied"
    assert ack2 == ack1

    # exactly one messages row was created despite two results
    assert count_rows(
             "SELECT 1 FROM chat_v2.messages m WHERE m.channel_id = $1",
             [channel_id]
           ) == 1
  end

  test "delivery_result: invalid effect → failed ack + rows failed" do
    bot_id = bot_id()
    seed_bot("owner-1", bot_id: bot_id)
    channel_id = channel_id()

    connect_bot!(bot_id)

    assert {:ok, %{delivery_id: delivery_id, invocation_id: invocation_id}} =
             BotDelivery.commit_invocation(invocation_attrs(bot_id, channel_id))

    assert_receive {:bot_ws_push, _frame}, 1_000

    ack =
      BotConnection.deliver_result(bot_id, delivery_id, [
        %{"type" => "append_stream", "client_effect_id" => "ce-1"}
      ])

    assert ack["status"] == "failed"
    assert ack["error"]["code"] == "BOT_EFFECT_INVALID"

    assert count_rows(
             "SELECT 1 FROM chat_v2.bot_deliveries bd WHERE bd.delivery_id = $1 AND bd.status = 'dropped'",
             [delivery_id]
           ) == 1

    assert count_rows(
             "SELECT 1 FROM chat_v2.command_invocations ci WHERE ci.invocation_id = $1 AND ci.status = 'failed'",
             [invocation_id]
           ) == 1
  end

  # -------------------------------------------------------- crash recovery

  test "AC3: crash → pending rows survive → reconnect resumes in delivery_id order" do
    bot_id = bot_id()
    seed_bot("owner-1", bot_id: bot_id)
    channel_id = channel_id()

    # First connection: two deliveries are committed.
    connect_bot!(bot_id)

    assert {:ok, %{delivery_id: d1}} =
             BotDelivery.commit_invocation(invocation_attrs(bot_id, channel_id))

    assert_receive {:bot_ws_push, _frame}, 1_000

    assert {:ok, %{delivery_id: d2}} =
             BotDelivery.commit_message_event(%{
               channel_id: channel_id,
               bot_id: bot_id,
               event_id: "evt-crash-1",
               message: message_projection()
             })

    assert_receive {:bot_ws_push, _frame}, 1_000

    # Neither result arrives before the server "crashes".
    BotConnection.detach(bot_id, :crash)
    assert wait_offline?(bot_id), "bot should be offline after detach"

    # Rows survive in bot_deliveries (D14).
    assert count_rows(
             "SELECT 1 FROM chat_v2.bot_deliveries bd WHERE bd.bot_id = $1 AND bd.status = 'pending'",
             [bot_id]
           ) == 2

    # Reconnect: hello resumes both deliveries, in delivery_id order.
    %{ready: _ready, frames: frames} = BotConnection.connect(bot_id, self(), "resumed")

    assert length(frames) == 2
    assert Enum.map(frames, & &1["delivery_id"]) == [d1, d2]
    assert hd(frames)["kind"] == "command_invocation"
    assert tl(frames) |> hd() |> then(& &1["kind"]) == "message_event"

    # Completing the resumed delivery works.
    ack =
      BotConnection.deliver_result(bot_id, d1, [
        %{
          "type" => "send_message",
          "client_effect_id" => "ce-1",
          "message" => %{"type" => "text", "text" => "after crash"}
        }
      ])

    assert ack["status"] == "applied"
  end

  test "resume_frames returns all pending deliveries as contract frames" do
    bot_id = bot_id()
    seed_bot("owner-1", bot_id: bot_id)
    channel_id = channel_id()

    connect_bot!(bot_id)

    assert {:ok, %{delivery_id: d1, invocation_id: invocation_id}} =
             BotDelivery.commit_invocation(invocation_attrs(bot_id, channel_id))

    frames = BotDelivery.resume_frames(bot_id)

    assert [
             %{
               "type" => "delivery",
               "api_version" => "lilium.chat.bot.v1",
               "delivery_id" => ^d1,
               "kind" => "command_invocation",
               "channel_id" => ^channel_id,
               "invocation_id" => ^invocation_id
             }
           ] = frames
  end

  # ---------------------------------------------------------- offline TTL

  test "expire_offline: invocation + interaction → dropped, business rows failed" do
    bot_id = bot_id()
    seed_bot("owner-1", bot_id: bot_id)
    channel_id = channel_id()

    connect_bot!(bot_id)

    assert {:ok, %{invocation_id: invocation_id}} =
             BotDelivery.commit_invocation(invocation_attrs(bot_id, channel_id))

    assert_receive {:bot_ws_push, _frame}, 1_000

    assert {:ok, %{interaction_id: interaction_id}} =
             BotDelivery.commit_interaction(interaction_attrs(bot_id, channel_id))

    assert_receive {:bot_ws_push, _frame}, 1_000

    BotConnection.detach(bot_id, :ws_close)

    # Not yet expired: still pending.
    assert BotDelivery.expire_offline(bot_id) == 2

    assert count_rows(
             "SELECT 1 FROM chat_v2.bot_deliveries bd WHERE bd.bot_id = $1 AND bd.status = 'dropped'",
             [bot_id]
           ) == 2

    assert count_rows(
             "SELECT 1 FROM chat_v2.command_invocations ci WHERE ci.invocation_id = $1 AND ci.status = 'failed' AND ci.error_code = 'BOT_OFFLINE'",
             [invocation_id]
           ) == 1

    assert count_rows(
             "SELECT 1 FROM chat_v2.interactions i WHERE i.interaction_id = $1 AND i.status = 'failed'",
             [interaction_id]
           ) == 1
  end

  test "expire_offline: message_event rows expire after their TTL (passive)" do
    bot_id = bot_id()
    seed_bot("owner-1", bot_id: bot_id)
    channel_id = channel_id()

    # A long-expired event and a fresh one (TTL = 1s in this test's config).
    old_event =
      Repo.query!(
        """
        INSERT INTO chat_v2.bot_deliveries
          (delivery_id, channel_id, bot_id, kind, invocation_id, interaction_id,
           event_id, request_json, status, attempts, max_attempts, created_at, updated_at)
        VALUES ($1, $2, $3, 'message_event', NULL, NULL, $4, $5, 'pending', 0, 5, $6, $6)
        """,
        [
          LiliumChat.Ids.uuidv7(),
          channel_id,
          bot_id,
          "evt-old",
          %{"event" => %{"event_id" => "evt-old", "type" => "message.created"}, "message" => %{}},
          DateTime.utc_now() |> DateTime.add(-3_600, :second)
        ],
        type: true
      )

    # The fresh one is committed "now" (stays pending — its TTL has not passed).
    now_row =
      Repo.query!(
        """
        INSERT INTO chat_v2.bot_deliveries
          (delivery_id, channel_id, bot_id, kind, invocation_id, interaction_id,
           event_id, request_json, status, attempts, max_attempts, created_at, updated_at)
        VALUES ($1, $2, $3, 'message_event', NULL, NULL, $4, $5, 'pending', 0, 5, $6, $6)
        """,
        [
          LiliumChat.Ids.uuidv7(),
          channel_id,
          bot_id,
          "evt-fresh",
          %{
            "event" => %{"event_id" => "evt-fresh", "type" => "message.created"},
            "message" => %{}
          },
          DateTime.utc_now()
        ],
        type: true
      )

    _ = old_event
    _ = now_row

    assert BotDelivery.expire_offline(bot_id) == 1

    rows =
      Query.rows(
        Repo.query(
          "SELECT status FROM chat_v2.bot_deliveries bd WHERE bd.bot_id = $1 ORDER BY created_at",
          [bot_id],
          type: true
        )
      )

    assert [%{"status" => "dropped"}, %{"status" => "pending"}] = rows
  end

  # ------------------------------------------------------------------- lease

  test "lease expiry: the session goes offline and the channel is notified" do
    Application.put_env(:lilium_chat, :bot_gateway,
      lease_ttl_ms: 80,
      offline_ttl_ms: 30_000,
      message_event_ttl_ms: 1_000
    )

    bot_id = bot_id()
    seed_bot("owner-1", bot_id: bot_id)

    connect_bot!(bot_id)
    assert BotConnection.online?(bot_id)

    # No ping refreshes → the lease fires (contract §9.7.1: the server
    # closes the bot WS with reason lease_expired; Phoenix currently
    # notifies, the bot notices on its own WS timeout).
    assert_receive {:bot_ws_notify, %{"type" => "lease_expired"}}, 1_000

    assert wait_offline?(bot_id)
  end

  # ---------------------------------------------------------- max attempts

  test "resume enforces max_attempts: the row drops and the business row fails" do
    bot_id = bot_id()
    seed_bot("owner-1", bot_id: bot_id)
    channel_id = channel_id()

    connect_bot!(bot_id)

    assert {:ok, %{delivery_id: delivery_id, invocation_id: invocation_id}} =
             BotDelivery.commit_invocation(invocation_attrs(bot_id, channel_id))

    assert_receive {:bot_ws_push, _}, 1_000

    # Each resume pass is a delivery attempt; max_attempts = 3 (old Worker
    # parity). The row must not retry forever.
    Enum.each(1..3, fn _ ->
      BotConnection.detach(bot_id, :ws_close)
      assert wait_offline?(bot_id)
      connect_bot!(bot_id)
    end)

    rows =
      Query.rows(
        Repo.query(
          "SELECT status, attempts, last_error FROM chat_v2.bot_deliveries WHERE delivery_id = $1",
          [delivery_id],
          type: true
        )
      )

    assert [%{"status" => "dropped", "attempts" => 3, "last_error" => "max_attempts"}] = rows

    assert count_rows(
             "SELECT 1 FROM chat_v2.command_invocations WHERE invocation_id = $1 AND status = 'failed' AND error_code = 'BOT_OFFLINE'",
             [invocation_id]
           ) == 1
  end

  test "offline expiry reschedules while pending rows remain" do
    Application.put_env(:lilium_chat, :bot_gateway,
      lease_ttl_ms: 60_000,
      offline_ttl_ms: 50,
      message_event_ttl_ms: 100
    )

    bot_id = bot_id()
    seed_bot("owner-1", bot_id: bot_id)
    channel_id = channel_id()

    connect_bot!(bot_id)

    # A fresh passive event: too young for the first offline expiries.
    assert {:ok, %{delivery_id: _d}} =
             BotDelivery.commit_message_event(%{
               channel_id: channel_id,
               bot_id: bot_id,
               event_id: "evt-resched-1",
               message: message_projection()
             })

    assert_receive {:bot_ws_push, _}, 1_000

    BotConnection.detach(bot_id, :ws_close)
    assert wait_offline?(bot_id)

    # The offline TTL fires, finds the still-young event, reschedules, and a
    # later firing drops it once its own TTL has elapsed. A single-shot
    # expiry (no reschedules) would never drop it — it was fresh at the
    # first firing.
    Process.sleep(500)

    assert count_rows(
             "SELECT 1 FROM chat_v2.bot_deliveries WHERE bot_id = $1 AND status = 'dropped' AND last_error = 'offline expired'",
             [bot_id]
           ) == 1
  end

  # ---------------------------------------------------------------- helpers

  defp count_rows(sql, params) do
    Repo.query(sql, params, type: true)
    |> Query.rows()
    |> length()
  end

  defp wait_offline?(bot_id, attempts \\ 50) do
    Enum.any?(1..attempts, fn _ ->
      if BotConnection.online?(bot_id) do
        Process.sleep(20)
        false
      else
        true
      end
    end)
  end
end
