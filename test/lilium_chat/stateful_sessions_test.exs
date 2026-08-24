defmodule LiliumChat.StatefulSessionsTest do
  @moduledoc """
   Stateful command session tests (contract §9.7.3 / §9.7.4 / §9.12, issue
  #19): the `platform:stop_session` graceful-stop flow (acceptance A5),
  `session.effects` (pin-only allowlist + `effect_seq` idempotency), the
  listen-rules input enqueue (`session.input`), `session.input_ack`
  accounting, and the stop-grace / TTL expiry timers.

  Seeding goes through the issue #20 seam (`StatefulSessions.seed_active/1`
  + `ChannelPins.upsert_session_control/5`); `session.start` / `start_ack`
  themselves belong to issue #20.
  """

  use LiliumChat.DataCase, async: false

  import LiliumChatWeb.ReadFixtures
  import LiliumChatWeb.BotFixtures

  alias LiliumChat.{
    BotConnection,
    Channel,
    ChannelPins,
    Errors,
    Ids,
    Projections,
    Query,
    Repo,
    StatefulSessions
  }

  @uid "6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e6f"
  @other "7a2f3d4e-5b6c-8d9e-0f1a-2b3c4d5e6f70"

  # ----------------------------------------------------------------- helpers

  defp channel!() do
    cid = "ch-s19-" <> Ecto.UUID.generate()
    seed_channel(cid, kind: "channel", visibility: "private", status: "active")
    seed_membership(cid, @uid, "member")
    seed_membership(cid, @other, "member")
    cid
  end

  defp new_bot() do
    bot_id = "bot-s19-" <> Ecto.UUID.generate()
    seed_bot("owner-s19", bot_id: bot_id, display_name: "Session Bot")
    bot_id
  end

  defp seed_session(channel_id, bot_id, attrs \\ %{}) do
    StatefulSessions.seed_active(
      %{channel_id: channel_id, bot_id: bot_id, started_by_user_id: @uid}
      |> Map.merge(attrs)
    )
  end

  defp seed_pin!(channel_id, session_id) do
    ChannelPins.upsert_session_control(channel_id, session_id, "stateful", "Kuma")
  end

  defp connect_bot!(bot_id) do
    %{ready: _ready, frames: _frames} = BotConnection.connect(bot_id, self(), nil)
    :ok
  end

  defp session_row(session_id), do: StatefulSessions.get(session_id)

  defp pin_projection(pin_id) do
    pin = ChannelPins.get_row(pin_id)
    Projections.json_map(pin["message_projection_json"])
  end

  defp set_pin_projection(pin_id, projection) do
    Repo.query!(
      "UPDATE chat_v2.channel_pins SET message_projection_json = $2 WHERE pin_id = $1",
      [pin_id, projection],
      type: true
    )
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

  defp event_count(channel_id, event_type) do
    Repo.query(
      "SELECT COUNT(*) AS n FROM chat_v2.events WHERE channel_id = $1 AND event_type = $2",
      [channel_id, event_type]
    )
    |> case do
      {:ok, %{rows: [[n]]}} -> n
    end
  end

  defp input_count(session_id) do
    Repo.query(
      "SELECT COUNT(*) AS n FROM chat_v2.stateful_session_inputs WHERE session_id = $1",
      [session_id]
    )
    |> case do
      {:ok, %{rows: [[n]]}} -> n
    end
  end

  defp interaction_count(message_id) do
    Repo.query(
      "SELECT COUNT(*) AS n FROM chat_v2.interactions WHERE message_id = $1",
      [message_id]
    )
    |> case do
      {:ok, %{rows: [[n]]}} -> n
    end
  end

  defp writer_pid!(channel_id) do
    [{pid, _}] = Registry.lookup(LiliumChat.Channels.Registry, channel_id)
    pid
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

  # Raw parameterized queries decode timestamptz as NaiveDateTime; parameterless
  # ones as DateTime — accept either.
  defp timestamp?(value), do: is_struct(value, NaiveDateTime) or is_struct(value, DateTime)

  # Fresh per-channel event-sequence state for module-level applier calls
  # (the Channel writer process owns the real sequence).
  defp fresh_seq(), do: %{last_ms: System.system_time(:millisecond), counter: 0}

  defp pin_effect(client_effect_id, text) do
    %{
      "type" => "set_channel_pin",
      "client_effect_id" => client_effect_id,
      "pin_kind" => "bot_control",
      "message" => %{"format" => "markdown", "text" => text, "components" => []}
    }
  end

  # ------------------------------------------------------- A5: request_stop

  test "A5: platform stop → closing + disabled Stop + pin.updated + stop_requested (no seq)" do
    cid = channel!()
    bot = new_bot()
    session = seed_session(cid, bot)
    pin = seed_pin!(cid, session["session_id"])
    sid = session["session_id"]
    connect_bot!(bot)

    {:ok, ack} = Channel.request_stop(cid, %{pin_id: pin["pin_id"], user_id: @uid, admin: false})

    # the committed ack (contract §9.12.2) — an interaction ack WITHOUT an
    # interaction_id (it is the platform shortcut, not a stored interaction)
    assert ack["channel_id"] == cid
    assert is_binary(ack["event_id"])
    assert ack["pin_id"] == pin["pin_id"]
    assert ack["session_id"] == sid
    assert ack["custom_id"] == "platform:stop_session"
    refute Map.has_key?(ack, "interaction_id")

    # the session is closing with a persisted stop-grace target
    row = session_row(sid)
    assert row["status"] == "closing"
    assert timestamp?(row["stop_grace_at"])

    # the pin's Stop component is disabled + relabeled
    projection = pin_projection(pin["pin_id"])
    stop = Enum.find(projection["components"], &(&1["custom_id"] == "platform:stop_session"))
    assert stop["disabled"] == true
    assert stop["label"] == "正在停止…"

    # the channel.pin.updated event is committed
    assert event_count(cid, "channel.pin.updated") == 1
    [frame] = events(cid)
    assert frame["event_type"] == "channel.pin.updated"

    # the bot receives session.stop_requested — a control frame, NOT a
    # session.input (no `seq` field, contract §9.7.4)
    assert_receive {:bot_ws_push, pushed}, 1_000
    assert pushed["type"] == "session.stop_requested"
    assert pushed["api_version"] == "lilium.chat.bot.v1"
    assert pushed["session_id"] == sid
    assert pushed["reason"] == "user_stop"
    assert pushed["actor_user_id"] == @uid
    assert pushed["grace_timeout_ms"] == 30_000
    refute Map.has_key?(pushed, "seq")

    # the stop did NOT enqueue a session.input
    assert input_count(sid) == 0
  end

  test "A5: gate order — pin / session / status / actor / component" do
    # PIN_NOT_FOUND
    cid1 = channel!()

    assert {:error, %Errors.ApiError{code: "PIN_NOT_FOUND"}} =
             Channel.request_stop(cid1, %{pin_id: "no-such-pin", user_id: @uid, admin: false})

    # INVALID_MESSAGE: a bot-owned pin is not a session control pin
    cid2 = channel!()
    bot2 = new_bot()

    {bot_pin_id, _eid, _frame, _seq} =
      ChannelPins.bot_set(
        cid2,
        fresh_seq(),
        bot2,
        "bot_control",
        %{"format" => "plain", "text" => "controls", "components" => []},
        %{"display_name" => "Session Bot", "avatar_url" => nil}
      )

    assert {:error, %Errors.ApiError{code: "INVALID_MESSAGE"}} =
             Channel.request_stop(cid2, %{pin_id: bot_pin_id, user_id: @uid, admin: false})

    # STATEFUL_SESSION_NOT_FOUND: the pin points at a missing session
    cid3 = channel!()
    orphan_pin = ChannelPins.upsert_session_control(cid3, "no-such-session", "stateful", "Kuma")

    assert {:error, %Errors.ApiError{code: "STATEFUL_SESSION_NOT_FOUND"}} =
             Channel.request_stop(cid3, %{
               pin_id: orphan_pin["pin_id"],
               user_id: @uid,
               admin: false
             })

    # SESSION_STOP_IN_PROGRESS: already closing
    cid4 = channel!()
    bot4 = new_bot()
    closing = seed_session(cid4, bot4, %{:status => "closing"})
    pin4 = seed_pin!(cid4, closing["session_id"])

    assert {:error, %Errors.ApiError{code: "SESSION_STOP_IN_PROGRESS"}} =
             Channel.request_stop(cid4, %{pin_id: pin4["pin_id"], user_id: @uid, admin: false})

    # STATEFUL_SESSION_NOT_ACTIVE: a terminal session cannot be stopped
    cid5 = channel!()
    bot5 = new_bot()
    closed = seed_session(cid5, bot5, %{:status => "closed"})
    pin5 = seed_pin!(cid5, closed["session_id"])

    assert {:error, %Errors.ApiError{code: "STATEFUL_SESSION_NOT_ACTIVE"}} =
             Channel.request_stop(cid5, %{pin_id: pin5["pin_id"], user_id: @uid, admin: false})

    # FORBIDDEN: a non-starter without admin rights — then the admin bypass
    cid6 = channel!()
    bot6 = new_bot()
    session6 = seed_session(cid6, bot6)
    pin6 = seed_pin!(cid6, session6["session_id"])

    assert {:error, %Errors.ApiError{code: "FORBIDDEN"}} =
             Channel.request_stop(cid6, %{pin_id: pin6["pin_id"], user_id: @other, admin: false})

    assert {:ok, ack} =
             Channel.request_stop(cid6, %{pin_id: pin6["pin_id"], user_id: @other, admin: true})

    assert ack["session_id"] == session6["session_id"]

    # COMPONENT_NOT_FOUND: the pin projection has no Stop button
    cid7 = channel!()
    bot7 = new_bot()
    session7 = seed_session(cid7, bot7)
    pin7 = seed_pin!(cid7, session7["session_id"])
    set_pin_projection(pin7["pin_id"], Map.put(pin_projection(pin7["pin_id"]), "components", []))

    assert {:error, %Errors.ApiError{code: "COMPONENT_NOT_FOUND"}} =
             Channel.request_stop(cid7, %{pin_id: pin7["pin_id"], user_id: @uid, admin: false})

    # COMPONENT_DISABLED: the Stop button is already disabled
    cid8 = channel!()
    bot8 = new_bot()
    session8 = seed_session(cid8, bot8)
    pin8 = seed_pin!(cid8, session8["session_id"])

    projection8 = pin_projection(pin8["pin_id"])

    disabled_components =
      for component <- projection8["components"] do
        Map.put(component, "disabled", true)
      end

    set_pin_projection(pin8["pin_id"], Map.put(projection8, "components", disabled_components))

    assert {:error, %Errors.ApiError{code: "COMPONENT_DISABLED"}} =
             Channel.request_stop(cid8, %{pin_id: pin8["pin_id"], user_id: @uid, admin: false})
  end

  test "A5: stop → bot session.close → closed (pin cleared + events + session.closed)" do
    cid = channel!()
    bot = new_bot()
    session = seed_session(cid, bot)
    pin = seed_pin!(cid, session["session_id"])
    sid = session["session_id"]
    connect_bot!(bot)

    {:ok, _ack} = Channel.request_stop(cid, %{pin_id: pin["pin_id"], user_id: @uid, admin: false})

    assert_receive {:bot_ws_push, %{"type" => "session.stop_requested"}}, 1_000

    # the bot answers with session.close (no reason → bot_closed)
    {:ok, %{}} = Channel.session_close(cid, %{bot_id: bot, session_id: sid, reason: nil})

    row = session_row(sid)
    assert row["status"] == "closed"
    assert row["close_reason"] == "bot_closed"
    assert timestamp?(row["closed_at"])

    # the session control pin is deleted
    assert ChannelPins.get_session_control_pin(cid) == nil

    # events: pin.updated (stop) → stateful_session.closed → pin.cleared
    # (old Worker `closeStatefulSession` order — closed emits first)
    assert Enum.map(events(cid), & &1["event_type"]) ==
             ["channel.pin.updated", "stateful_session.closed", "channel.pin.cleared"]

    cleared = Enum.find(events(cid), &(&1["event_type"] == "channel.pin.cleared"))
    assert cleared["payload"]["pin_id"] == pin["pin_id"]
    assert cleared["payload"]["channel_id"] == cid
    assert cleared["payload"]["pin_kind"] == "session_control"
    assert cleared["payload"]["session_id"] == sid

    closed = Enum.find(events(cid), &(&1["event_type"] == "stateful_session.closed"))
    assert closed["payload"]["session_id"] == sid
    assert closed["payload"]["status"] == "closed"
    assert closed["payload"]["reason"] == "bot_closed"
    assert closed["payload"]["command_name"] == "stateful"

    # the bot is told via session.closed
    assert_receive {:bot_ws_push, frame}, 1_000
    assert frame["type"] == "session.closed"
    assert frame["session_id"] == sid
    assert frame["status"] == "closed"
    assert frame["reason"] == "bot_closed"
  end

  test "stop grace timer: force-closes a closing session (stop_timeout)" do
    cid = channel!()
    bot = new_bot()
    session = seed_session(cid, bot)
    pin = seed_pin!(cid, session["session_id"])
    sid = session["session_id"]
    connect_bot!(bot)

    {:ok, _} = Channel.request_stop(cid, %{pin_id: pin["pin_id"], user_id: @uid, admin: false})

    assert_receive {:bot_ws_push, %{"type" => "session.stop_requested"}}, 1_000

    # fire the writer's stop-grace timer directly (30 s in production)
    send(writer_pid!(cid), {:session_stop_grace, sid})

    assert wait_for(fn -> session_row(sid)["status"] == "closed" end)

    row = session_row(sid)
    assert row["close_reason"] == "stop_timeout"
    assert ChannelPins.get_session_control_pin(cid) == nil
    assert event_count(cid, "stateful_session.closed") == 1

    assert_receive {:bot_ws_push, %{"type" => "session.closed", "reason" => "stop_timeout"}},
                   1_000
  end

  test "TTL expiry timer: closes with reason timeout → status failed" do
    cid = channel!()
    bot = new_bot()
    session = seed_session(cid, bot, %{:expires_at => DateTime.utc_now()})
    seed_pin!(cid, session["session_id"])
    sid = session["session_id"]
    connect_bot!(bot)

    {:ok, _} = Channel.ensure_started(cid)
    send(writer_pid!(cid), {:session_expiry, sid})

    assert wait_for(fn -> session_row(sid)["status"] == "failed" end)

    row = session_row(sid)
    assert row["close_reason"] == "timeout"
    assert ChannelPins.get_session_control_pin(cid) == nil
    assert event_count(cid, "stateful_session.closed") == 1

    assert_receive {:bot_ws_push,
                    %{"type" => "session.closed", "status" => "failed", "reason" => "timeout"}},
                   1_000
  end

  # --------------------------------------------------------- session.effects

  test "session.effects: fresh set_channel_pin → effects_ack + seq bump + idem row" do
    cid = channel!()
    bot = new_bot()
    session = seed_session(cid, bot)
    seed_pin!(cid, session["session_id"])
    sid = session["session_id"]
    connect_bot!(bot)

    {:ok, ack} =
      Channel.session_effects(cid, %{
        bot_id: bot,
        session_id: sid,
        effect_seq: 1,
        effects: [pin_effect("se-1", "session says hi")]
      })

    assert ack["type"] == "session.effects_ack"
    assert ack["api_version"] == "lilium.chat.bot.v1"
    assert ack["session_id"] == sid
    assert ack["effect_seq"] == 1
    assert ack["status"] == "applied"

    assert [
             %{
               "client_effect_id" => "se-1",
               "type" => "set_channel_pin",
               "status" => "applied",
               "pin_id" => pin_id,
               "event_id" => event_id
             }
           ] = ack["effect_results"]

    assert is_binary(pin_id)
    assert is_binary(event_id)

    # the session's effect sequence advanced
    assert session_row(sid)["effect_last_acked_seq"] == 1

    # the pin is persisted (bot-owned, in-channel) and the event committed
    pin_row = ChannelPins.get_row(pin_id)
    assert pin_row["channel_id"] == cid
    assert pin_row["pin_owner_kind"] == "bot"
    assert pin_row["pin_owner_id"] == bot
    assert event_count(cid, "channel.pin.set") == 1

    # the session_effect idempotency row is stored
    idem =
      Query.rows(
        Repo.query(
          "SELECT request_hash FROM chat_v2.idempotency " <>
            "WHERE namespace = 'session_effect' AND session_id = $1 AND effect_seq = 1",
          [sid],
          type: true
        )
      )

    assert length(idem) == 1
  end

  test "session.effects: replay (same seq + body) returns the identical ack" do
    cid = channel!()
    bot = new_bot()
    session = seed_session(cid, bot)
    seed_pin!(cid, session["session_id"])
    sid = session["session_id"]

    input = %{
      bot_id: bot,
      session_id: sid,
      effect_seq: 1,
      effects: [pin_effect("se-1", "session says hi")]
    }

    {:ok, ack1} = Channel.session_effects(cid, input)
    {:ok, ack2} = Channel.session_effects(cid, input)

    assert ack1 == ack2
    assert ack1["status"] == "applied"

    # exactly one pin and one channel.pin.set event despite two frames
    pin_id = hd(ack1["effect_results"])["pin_id"]
    assert ChannelPins.get_bot_pin_by_kind(bot, "bot_control")["pin_id"] == pin_id
    assert event_count(cid, "channel.pin.set") == 1
  end

  test "session.effects: effect_seq gap → BOT_EFFECT_INVALID" do
    cid = channel!()
    bot = new_bot()
    session = seed_session(cid, bot)
    seed_pin!(cid, session["session_id"])

    assert {:error, %Errors.ApiError{code: "BOT_EFFECT_INVALID"}} =
             Channel.session_effects(cid, %{
               bot_id: bot,
               session_id: session["session_id"],
               effect_seq: 2,
               effects: [pin_effect("se-2", "gap")]
             })
  end

  test "session.effects: effect_seq reused with a different body → BOT_EFFECT_CONFLICT" do
    cid = channel!()
    bot = new_bot()
    session = seed_session(cid, bot)
    seed_pin!(cid, session["session_id"])
    sid = session["session_id"]

    {:ok, _ack} =
      Channel.session_effects(cid, %{
        bot_id: bot,
        session_id: sid,
        effect_seq: 1,
        effects: [pin_effect("se-1", "v1")]
      })

    assert {:error, %Errors.ApiError{code: "BOT_EFFECT_CONFLICT"}} =
             Channel.session_effects(cid, %{
               bot_id: bot,
               session_id: sid,
               effect_seq: 1,
               effects: [pin_effect("se-1", "v2")]
             })
  end

  test "session.effects: non-pin effect types are rejected" do
    cid = channel!()
    bot = new_bot()
    session = seed_session(cid, bot)
    seed_pin!(cid, session["session_id"])

    assert {:error, %Errors.ApiError{code: "BOT_EFFECT_INVALID"}} =
             Channel.session_effects(cid, %{
               bot_id: bot,
               session_id: session["session_id"],
               effect_seq: 1,
               effects: [
                 %{
                   "type" => "send_message",
                   "client_effect_id" => "se-1",
                   "message" => %{"type" => "text", "text" => "nope"}
                 }
               ]
             })
  end

  test "session.effects: bot mismatch / suspended session / pin for another session" do
    cid = channel!()
    bot = new_bot()
    session = seed_session(cid, bot)
    sid = session["session_id"]

    # bot mismatch (the channel has no session pin yet either, but the bot
    # gate runs first)
    assert {:error, %Errors.ApiError{code: "BOT_EFFECT_INVALID"}} =
             Channel.session_effects(cid, %{
               bot_id: "bot-other",
               session_id: sid,
               effect_seq: 1,
               effects: [pin_effect("se-1", "mismatch")]
             })

    # suspended session → not active
    seed_pin!(cid, sid)

    Repo.query!(
      "UPDATE chat_v2.stateful_command_sessions SET status = 'suspended' WHERE session_id = $1",
      [sid]
    )

    assert {:error, %Errors.ApiError{code: "STATEFUL_SESSION_NOT_ACTIVE"}} =
             Channel.session_effects(cid, %{
               bot_id: bot,
               session_id: sid,
               effect_seq: 1,
               effects: [pin_effect("se-1", "suspended")]
             })

    # repair the status, then point the channel pin at a different session
    Repo.query!(
      "UPDATE chat_v2.stateful_command_sessions SET status = 'active' WHERE session_id = $1",
      [sid]
    )

    Repo.query!(
      "UPDATE chat_v2.channel_pins SET session_id = 'some-other-session' WHERE channel_id = $1",
      [cid]
    )

    assert {:error, %Errors.ApiError{code: "BOT_EFFECT_INVALID"}} =
             Channel.session_effects(cid, %{
               bot_id: bot,
               session_id: sid,
               effect_seq: 1,
               effects: [pin_effect("se-1", "other pin")]
             })
  end

  test "session.effects: session_control pin display patch (text only; components forbidden)" do
    cid = channel!()
    bot = new_bot()
    session = seed_session(cid, bot)
    pin = seed_pin!(cid, session["session_id"])
    sid = session["session_id"]

    patch = %{
      "type" => "update_channel_pin",
      "client_effect_id" => "se-1",
      "pin_id" => pin["pin_id"],
      "message" => %{"format" => "markdown", "text" => "computing…"}
    }

    {:ok, ack} =
      Channel.session_effects(cid, %{
        bot_id: bot,
        session_id: sid,
        effect_seq: 1,
        effects: [patch]
      })

    assert ack["status"] == "applied"

    pin_id = pin["pin_id"]

    assert [
             %{
               "client_effect_id" => "se-1",
               "type" => "update_channel_pin",
               "status" => "applied",
               "pin_id" => ^pin_id
             }
           ] = ack["effect_results"]

    assert pin_projection(pin_id)["text"] == "computing…"
    assert event_count(cid, "channel.pin.updated") == 1

    # components may NOT be patched on a session_control pin
    assert {:error, %Errors.ApiError{code: "BOT_EFFECT_INVALID"}} =
             Channel.session_effects(cid, %{
               bot_id: bot,
               session_id: sid,
               effect_seq: 2,
               effects: [
                 %{
                   "type" => "update_channel_pin",
                   "client_effect_id" => "se-2",
                   "pin_id" => pin_id,
                   "message" => %{"components" => []}
                 }
               ]
             })
  end

  test "delivery_result: update_channel_pin on the session pin is rejected" do
    cid = channel!()
    bot = new_bot()
    session = seed_session(cid, bot)
    pin = seed_pin!(cid, session["session_id"])

    assert {:error, %Errors.ApiError{code: "BOT_EFFECT_INVALID"}} =
             Channel.apply_bot_effects(cid, %{
               bot_id: bot,
               effects: [
                 %{
                   "type" => "update_channel_pin",
                   "client_effect_id" => "dr-1",
                   "pin_id" => pin["pin_id"],
                   "message" => %{"text" => "nope"}
                 }
               ]
             })
  end

  # ---------------------------------------------------- listen-rules inputs

  test "message.created (user) → session.input enqueue + push to the bot" do
    cid = channel!()
    bot = new_bot()
    session = seed_session(cid, bot)
    sid = session["session_id"]
    connect_bot!(bot)

    {:ok, ack} =
      Channel.send_message(cid, %{
        user_id: @other,
        command_id: "cmd-listen-1",
        payload: %{"type" => "text", "text" => "hello session"}
      })

    assert ack["status"] == "committed"
    message = ack["payload"]["message"]

    assert_receive {:bot_ws_push, frame}, 1_000
    assert frame["type"] == "session.input"
    assert frame["api_version"] == "lilium.chat.bot.v1"
    assert frame["session_id"] == sid
    assert frame["channel_id"] == cid
    assert frame["seq"] == 1
    assert frame["event"]["type"] == "message.created"
    assert frame["event"]["event_id"] == ack["payload"]["event_id"]
    assert frame["message"]["message_id"] == message["message_id"]
    assert frame["message"]["text"] == "hello session"

    # the input row is persisted (pending)
    rows =
      Query.rows(
        Repo.query(
          "SELECT seq, status, message_id FROM chat_v2.stateful_session_inputs WHERE session_id = $1",
          [sid],
          type: true
        )
      )

    expected_message_id = message["message_id"]

    assert [
             %{"seq" => 1, "status" => "pending", "message_id" => ^expected_message_id}
           ] = rows

    assert session_row(sid)["input_next_seq"] == 2
  end

  test "enqueue_input: listen rules filter own / bot / wrong-type messages" do
    cid = channel!()
    bot = new_bot()
    session = seed_session(cid, bot)
    sid = session["session_id"]

    base = %{
      event_id: "evt-1",
      occurred_at: DateTime.utc_now(),
      message: %{"message_id" => "m-1", "text" => "t"}
    }

    # the starter's own message is excluded (include_own_messages: false)
    assert {:ok, _, %{event_frames: []}} =
             StatefulSessions.enqueue_input(
               cid,
               0,
               Map.merge(base, %{
                 type: "text",
                 sender_kind: "user",
                 sender_user_id: @uid,
                 sender_bot_id: nil
               })
             )

    # a bot message is excluded (include_bot_messages: false)
    assert {:ok, _, %{event_frames: []}} =
             StatefulSessions.enqueue_input(
               cid,
               0,
               Map.merge(base, %{
                 type: "text",
                 sender_kind: "bot",
                 sender_user_id: nil,
                 sender_bot_id: bot
               })
             )

    # a non-listed type is excluded (message_types: ["text"])
    assert {:ok, _, %{event_frames: []}} =
             StatefulSessions.enqueue_input(
               cid,
               0,
               Map.merge(base, %{
                 type: "image",
                 sender_kind: "user",
                 sender_user_id: @other,
                 sender_bot_id: nil
               })
             )

    assert input_count(sid) == 0

    # …and with include_bot_messages the bot's own messages DO count
    cid2 = channel!()
    bot2 = new_bot()

    session2 =
      seed_session(cid2, bot2, %{
        listen_rules: %{
          "message_types" => ["text"],
          "include_bot_messages" => true,
          "include_own_messages" => false
        }
      })

    assert {:ok, _, %{event_frames: []}} =
             StatefulSessions.enqueue_input(
               cid2,
               0,
               Map.merge(base, %{
                 type: "text",
                 sender_kind: "bot",
                 sender_user_id: nil,
                 sender_bot_id: bot2
               })
             )

    assert input_count(session2["session_id"]) == 1
  end

  test "no active session → the enqueue is a no-op (the send is unaffected)" do
    cid = channel!()
    _bot = new_bot()

    {:ok, ack} =
      Channel.send_message(cid, %{
        user_id: @other,
        command_id: "cmd-nosession",
        payload: %{"type" => "text", "text" => "quiet channel"}
      })

    assert ack["status"] == "committed"

    inputs =
      Repo.query(
        "SELECT COUNT(*) AS n FROM chat_v2.stateful_session_inputs WHERE channel_id = $1",
        [cid]
      )
      |> case do
        {:ok, %{rows: [[n]]}} -> n
      end

    assert inputs == 0
  end

  test "session.input_ack advances input_last_acked_seq and marks inputs acked" do
    cid = channel!()
    bot = new_bot()
    session = seed_session(cid, bot)
    sid = session["session_id"]
    connect_bot!(bot)

    {:ok, _} =
      Channel.send_message(cid, %{
        user_id: @other,
        command_id: "cmd-ack-1",
        payload: %{"type" => "text", "text" => "a"}
      })

    assert_receive {:bot_ws_push, %{"type" => "session.input", "seq" => 1}}, 1_000

    {:ok, %{}} = Channel.session_input_ack(cid, %{session_id: sid, last_received_seq: 1})

    assert session_row(sid)["input_last_acked_seq"] == 1

    assert [
             %{"status" => "acked", "acked_at" => acked_at}
           ] =
             Query.rows(
               Repo.query(
                 "SELECT status, acked_at FROM chat_v2.stateful_session_inputs WHERE session_id = $1",
                 [sid],
                 type: true
               )
             )

    assert timestamp?(acked_at)
  end

  test "backlog overflow (>1000 pending) → close backlog_overflow" do
    cid = channel!()
    bot = new_bot()
    session = seed_session(cid, bot)
    sid = session["session_id"]
    seed_pin!(cid, sid)
    connect_bot!(bot)

    # 1001 pending inputs — over the 1000 backlog limit
    Repo.query!(
      """
      INSERT INTO chat_v2.stateful_session_inputs
        (session_id, seq, channel_id, event_id, message_id, message_projection_json, status, created_at)
      SELECT $1, g, $2, 'evt-' || g, '', '{}'::jsonb, 'pending', now()
      FROM generate_series(1, 1001) AS g
      """,
      [sid, cid],
      type: true
    )

    # the user's send still commits — the overflow close rides along
    {:ok, ack} =
      Channel.send_message(cid, %{
        user_id: @other,
        command_id: "cmd-bl-1",
        payload: %{"type" => "text", "text" => "overflow"}
      })

    assert ack["status"] == "committed"

    row = session_row(sid)
    assert row["status"] == "closed"
    assert row["close_reason"] == "backlog_overflow"

    # the session pin is cleared with the close
    assert ChannelPins.get_session_control_pin(cid) == nil
    assert event_count(cid, "channel.pin.cleared") == 1

    closed =
      Enum.find(events(cid), &(&1["event_type"] == "stateful_session.closed"))

    assert closed["payload"]["status"] == "closed"
    assert closed["payload"]["reason"] == "backlog_overflow"

    assert_receive {:bot_ws_push, %{"type" => "session.closed", "reason" => "backlog_overflow"}},
                   1_000
  end

  # ------------------------------------------------ interaction.submit (#19)

  defp button_component(custom_id, opts \\ []) do
    component = %{
      "component_id" => Ids.uuidv7(),
      "kind" => "button",
      "custom_id" => custom_id,
      "disabled" => false,
      "style" => "primary",
      "label" => "Click"
    }

    if policy = Keyword.get(opts, :interaction_policy) do
      Map.put(component, "interaction_policy", policy)
    else
      component
    end
  end

  defp seed_bot_pin(cid, bot_id, components) do
    draft = %{
      "format" => "markdown",
      "text" => "bot pin",
      "components" => components
    }

    # Unique ms per call so repeated seeds never collide on event ids.
    seq = %{
      last_ms: System.system_time(:millisecond) + System.unique_integer([:positive]),
      counter: 0
    }

    {pin_id, _event_id, _frame, _seq} =
      ChannelPins.bot_set(cid, seq, bot_id, "bot_control", draft, %{
        "display_name" => "Session Bot",
        "avatar_url" => nil
      })

    pin_id
  end

  defp stored_component(pin_id, component_id) do
    projection = pin_projection(pin_id)
    Enum.find(projection["components"], &(&1["component_id"] == component_id))
  end

  defp seed_bot_message(cid, bot_id, components) do
    message_id = "msg-int-" <> Ecto.UUID.generate()
    event_id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    Repo.query!(
      """
      INSERT INTO chat_v2.messages
        (message_id, command_id, dedupe_principal_key, channel_id,
         sender_kind, sender_bot_id, type, format, status, text,
         components_json, stream_state, created_at, updated_at, event_id)
      VALUES ($1, $2, $2, $3, 'bot', $4, 'text', 'plain', 'normal', 'bot msg',
              $5, 'none', $6, $6, $7)
      """,
      [message_id, Ecto.UUID.generate(), cid, bot_id, components, now, event_id],
      type: true
    )

    message_id
  end

  defp submit(cid, command_id, payload) do
    Channel.submit_interaction(cid, %{user_id: @uid, command_id: command_id, payload: payload})
  end

  defp stop_component(pin) do
    projection = pin_projection(pin["pin_id"])
    Enum.find(projection["components"], &(&1["custom_id"] == "platform:stop_session"))
  end

  defp send_text(cid, user_id, text) do
    Channel.send_message(cid, %{
      user_id: user_id,
      command_id: "cmd-#{Ecto.UUID.generate()}",
      payload: %{"type" => "text", "text" => text}
    })
  end

  test "interaction.submit: platform:stop_session short-circuit (A5 browser entry)" do
    cid = channel!()
    bot = new_bot()
    session = seed_session(cid, bot)
    pin = seed_pin!(cid, session["session_id"])
    sid = session["session_id"]
    connect_bot!(bot)

    stop = stop_component(pin)

    {:ok, response} =
      submit(
        cid,
        "cmd-stop-1",
        %{
          "pin_id" => pin["pin_id"],
          "component_id" => stop["component_id"],
          "custom_id" => "platform:stop_session",
          "value" => true
        }
      )

    # PlatformPinInteractionAck
    assert response["channel_id"] == cid
    assert response["pin_id"] == pin["pin_id"]
    assert response["session_id"] == sid
    assert response["custom_id"] == "platform:stop_session"
    assert is_binary(response["event_id"])

    # session entered the closing window + the bot is told via session.stop_requested
    assert session_row(sid)["status"] == "closing"
    assert event_count(cid, "channel.pin.updated") == 1

    assert_receive {:bot_ws_push, %{"type" => "session.stop_requested", "session_id" => ^sid}},
                   1_000

    # the Stop button is disabled on the pin
    assert stored_stop = stored_component(pin["pin_id"], stop["component_id"])
    assert stored_stop["disabled"] == true
  end

  test "interaction.submit: a second stop attempt (new key) hits stop-in-progress" do
    cid = channel!()
    bot = new_bot()
    session = seed_session(cid, bot)
    pin = seed_pin!(cid, session["session_id"])
    connect_bot!(bot)

    stop = stop_component(pin)

    payload = %{
      "pin_id" => pin["pin_id"],
      "component_id" => stop["component_id"],
      "custom_id" => "platform:stop_session",
      "value" => true
    }

    {:ok, _} = submit(cid, "cmd-stop-2", payload)
    assert session_row(session["session_id"])["status"] == "closing"

    # A fresh attempt (new command_id) is rejected before the stop flow:
    # the Stop button was disabled by the first commit, and the disabled
    # gate (old-Worker parity) runs ahead of `request_stop`'s
    # SESSION_STOP_IN_PROGRESS check.
    assert {:error,
            %Errors.ApiError{code: "COMPONENT_DISABLED", message: "component is disabled"}} =
             submit(cid, "cmd-stop-3", payload)
  end

  test "interaction.submit: bot pin interaction commits row + delivery + event" do
    cid = channel!()
    bot = new_bot()
    component = button_component("approve-btn")
    pin_id = seed_bot_pin(cid, bot, [component])
    connect_bot!(bot)

    stored = stored_component(pin_id, component["component_id"])
    assert stored["disabled"] == false

    {:ok, response} =
      submit(
        cid,
        "cmd-pin-1",
        %{
          "pin_id" => pin_id,
          "component_id" => component["component_id"],
          "custom_id" => "approve-btn",
          "value" => true
        }
      )

    assert response["channel_id"] == cid
    assert is_binary(response["interaction_id"])
    assert is_binary(response["event_id"])

    # interaction row: pin interactions store the pin id in message_id
    [row] =
      Query.rows(
        Repo.query(
          "SELECT message_id, component_id, custom_id, actor_user_id, status FROM chat_v2.interactions WHERE message_id = $1",
          [pin_id],
          type: true
        )
      )

    assert row["component_id"] == component["component_id"]
    assert row["custom_id"] == "approve-btn"
    assert row["actor_user_id"] == @uid
    assert row["status"] == "pending"

    # the bot receives the message_interaction delivery (pin body)
    assert_receive {:bot_ws_push, frame}, 1_000

    assert frame["kind"] == "message_interaction"
    assert frame["pin_id"] == pin_id
    assert frame["interaction_id"] == response["interaction_id"]
    assert frame["component"]["component_id"] == component["component_id"]
    assert frame["component"]["value"] == true
    assert frame["actor"]["user_id"] == @uid

    # interaction.created is stored (actor re-projects live on read) + live frame
    [event] =
      events(cid)
      |> Enum.filter(&(&1["event_type"] == "interaction.created"))

    assert event["payload"]["interaction"]["interaction_id"] == response["interaction_id"]
    assert event["payload"]["pin_id"] == pin_id
    assert event["payload"]["component_id"] == component["component_id"]
    assert event["payload"]["command_id"] == "cmd-pin-1"

    # same command_id + body → cached idempotency replay (one row only)
    {:ok, response2} =
      submit(
        cid,
        "cmd-pin-1",
        %{
          "pin_id" => pin_id,
          "component_id" => component["component_id"],
          "custom_id" => "approve-btn",
          "value" => true
        }
      )

    assert response2 == response
    assert interaction_count(pin_id) == 1
  end

  test "interaction.submit: per_user_once and exclusive policy gates" do
    cid = channel!()
    bot = new_bot()

    once = button_component("once-btn", interaction_policy: "per_user_once")
    once_pin = seed_bot_pin(cid, bot, [once])
    connect_bot!(bot)

    {:ok, _} =
      submit(
        cid,
        "cmd-policy-1",
        %{
          "pin_id" => once_pin,
          "component_id" => once["component_id"],
          "custom_id" => "once-btn",
          "value" => true
        }
      )

    # same user, NEW command_id → the per_user_once gate (count includes pending)
    assert {:error, %Errors.ApiError{code: "INTERACTION_ALREADY_SUBMITTED"}} =
             submit(
               cid,
               "cmd-policy-2",
               %{
                 "pin_id" => once_pin,
                 "component_id" => once["component_id"],
                 "custom_id" => "once-btn",
                 "value" => true
               }
             )

    exclusive = button_component("x-btn", interaction_policy: "exclusive")
    exclusive_pin = seed_bot_pin(cid, bot, [exclusive])

    {:ok, _} =
      submit(
        cid,
        "cmd-policy-3",
        %{
          "pin_id" => exclusive_pin,
          "component_id" => exclusive["component_id"],
          "custom_id" => "x-btn",
          "value" => true
        }
      )

    assert {:error, %Errors.ApiError{code: "COMPONENT_ALREADY_USED"}} =
             submit(
               cid,
               "cmd-policy-4",
               %{
                 "pin_id" => exclusive_pin,
                 "component_id" => exclusive["component_id"],
                 "custom_id" => "x-btn",
                 "value" => true
               }
             )
  end

  test "interaction.submit: value / disabled / lookup / locator gates" do
    cid = channel!()
    bot = new_bot()
    button = button_component("gate-btn")
    pin_id = seed_bot_pin(cid, bot, [button])
    connect_bot!(bot)

    # value gate: a button wants exactly `true`
    assert {:error, %Errors.ApiError{code: "INVALID_INTERACTION_VALUE"}} =
             submit(
               cid,
               "cmd-gate-1",
               %{
                 "pin_id" => pin_id,
                 "component_id" => button["component_id"],
                 "custom_id" => "gate-btn",
                 "value" => false
               }
             )

    # component / locator gates
    assert {:error, %Errors.ApiError{code: "COMPONENT_NOT_FOUND"}} =
             submit(
               cid,
               "cmd-gate-2",
               %{
                 "pin_id" => pin_id,
                 "component_id" => Ids.uuidv7(),
                 "custom_id" => "gate-btn",
                 "value" => true
               }
             )

    assert {:error, %Errors.ApiError{code: "INVALID_MESSAGE"}} =
             submit(
               cid,
               "cmd-gate-3",
               %{
                 "pin_id" => pin_id,
                 "component_id" => button["component_id"],
                 "custom_id" => "wrong",
                 "value" => true
               }
             )

    assert {:error, %Errors.ApiError{code: "PIN_NOT_FOUND"}} =
             submit(
               cid,
               "cmd-gate-4",
               %{
                 "pin_id" => Ecto.UUID.generate(),
                 "component_id" => button["component_id"],
                 "custom_id" => "gate-btn",
                 "value" => true
               }
             )

    # locator exclusivity
    assert {:error, %Errors.ApiError{code: "INVALID_MESSAGE"}} =
             submit(
               cid,
               "cmd-gate-5",
               %{
                 "pin_id" => pin_id,
                 "message_id" => "msg-1",
                 "component_id" => button["component_id"],
                 "custom_id" => "gate-btn",
                 "value" => true
               }
             )

    # disabled gate
    disabled =
      %{
        "component_id" => Ids.uuidv7(),
        "kind" => "button",
        "custom_id" => "disabled-btn",
        "disabled" => true,
        "style" => "primary",
        "label" => "Off"
      }

    disabled_pin = seed_bot_pin(cid, bot, [disabled])

    assert {:error, %Errors.ApiError{code: "COMPONENT_DISABLED"}} =
             submit(
               cid,
               "cmd-gate-6",
               %{
                 "pin_id" => disabled_pin,
                 "component_id" => disabled["component_id"],
                 "custom_id" => "disabled-btn",
                 "value" => true
               }
             )
  end

  test "interaction.submit: targeted policy allows only the target user" do
    cid = channel!()
    bot = new_bot()

    targeted_raw =
      %{
        "component_id" => Ids.uuidv7(),
        "kind" => "button",
        "custom_id" => "target-btn",
        "disabled" => false,
        "style" => "primary",
        "label" => "For you",
        "interaction_policy" => "targeted",
        "target_user_id" => @uid
      }

    pin_id = seed_bot_pin(cid, bot, [targeted_raw])
    connect_bot!(bot)

    component = stored_component(pin_id, targeted_raw["component_id"])

    # the target user is allowed
    {:ok, response} =
      submit(
        cid,
        "cmd-target-1",
        %{
          "pin_id" => pin_id,
          "component_id" => component["component_id"],
          "custom_id" => "target-btn",
          "value" => true
        }
      )

    assert is_binary(response["interaction_id"])

    # a different (non-target) user is forbidden
    assert {:error, %Errors.ApiError{code: "INTERACTION_FORBIDDEN_TARGET"}} =
             Channel.submit_interaction(cid, %{
               user_id: @other,
               command_id: "cmd-target-2",
               payload: %{
                 "pin_id" => pin_id,
                 "component_id" => component["component_id"],
                 "custom_id" => "target-btn",
                 "value" => true
               }
             })
  end

  test "interaction.submit: bot offline + membership + unsupported platform ids" do
    cid = channel!()
    bot = new_bot()
    button = button_component("offline-btn")
    pin_id = seed_bot_pin(cid, bot, [button])

    # the bot never connected → offline
    assert {:error, %Errors.ApiError{code: "BOT_OFFLINE"}} =
             submit(
               cid,
               "cmd-offline-1",
               %{
                 "pin_id" => pin_id,
                 "component_id" => button["component_id"],
                 "custom_id" => "offline-btn",
                 "value" => true
               }
             )

    # non-member gate (a seeded member-less user id)
    connect_bot!(bot)

    assert {:error, %Errors.ApiError{code: "FORBIDDEN"}} =
             Channel.submit_interaction(
               cid,
               %{
                 user_id: "9c3a5e6f-7d8b-4a9c-b3d5-0e1f2a3b4c5d",
                 command_id: "cmd-nomember",
                 payload: %{
                   "pin_id" => pin_id,
                   "component_id" => button["component_id"],
                   "custom_id" => "offline-btn",
                   "value" => true
                 }
               }
             )

    # `platform:` custom_id on a BOT pin → not platform-owned
    assert {:error, %Errors.ApiError{code: "INVALID_MESSAGE"}} =
             submit(
               cid,
               "cmd-platform-1",
               %{
                 "pin_id" => pin_id,
                 "component_id" => button["component_id"],
                 "custom_id" => "platform:stop_session",
                 "value" => true
               }
             )
  end

  test "interaction.submit: message locator interactions on bot messages" do
    cid = channel!()
    bot = new_bot()
    button = button_component("msg-btn")
    message_id = seed_bot_message(cid, bot, [button])
    connect_bot!(bot)

    {:ok, response} =
      submit(
        cid,
        "cmd-msg-1",
        %{
          "message_id" => message_id,
          "component_id" => button["component_id"],
          "custom_id" => "msg-btn",
          "value" => true
        }
      )

    assert response["channel_id"] == cid
    assert is_binary(response["interaction_id"])

    # the delivery body carries message_id (not pin_id)
    assert_receive {:bot_ws_push, frame}, 1_000

    assert frame["kind"] == "message_interaction"
    assert frame["message_id"] == message_id
    assert Map.has_key?(frame, "pin_id") == false

    # non-bot message → INVALID_MESSAGE
    user_message = seed_message("msg-user-1", cid, @uid, "hi")

    assert {:error, %Errors.ApiError{code: "INVALID_MESSAGE"}} =
             submit(
               cid,
               "cmd-msg-2",
               %{
                 "message_id" => user_message,
                 "component_id" => button["component_id"],
                 "custom_id" => "msg-btn",
                 "value" => true
               }
             )

    # missing message
    assert {:error, %Errors.ApiError{code: "MESSAGE_NOT_FOUND"}} =
             submit(
               cid,
               "cmd-msg-3",
               %{
                 "message_id" => "msg-missing",
                 "component_id" => button["component_id"],
                 "custom_id" => "msg-btn",
                 "value" => true
               }
             )
  end

  # -------------------------------------------------- resume + ack gates

  test "resume: unacked session inputs are re-pushed on bot reconnect" do
    cid = channel!()
    bot = new_bot()
    session = seed_session(cid, bot)
    sid = session["session_id"]
    connect_bot!(bot)

    {:ok, _} = send_text(cid, @other, "first")
    {:ok, _} = send_text(cid, @other, "second")
    assert input_count(sid) == 2

    # reconnect: both unacked inputs are re-pushed in seq order
    %{frames: frames} = BotConnection.connect(bot, self(), nil)

    session_frames = Enum.filter(frames, &(&1["type"] == "session.input"))
    assert length(session_frames) == 2
    assert Enum.map(session_frames, & &1["seq"]) == [1, 2]
    assert Enum.all?(session_frames, &(&1["session_id"] == sid))
    assert Enum.all?(session_frames, &(&1["channel_id"] == cid))

    # ack seq 1 → only seq 2 remains unacked on the next resume
    {:ok, %{}} = Channel.session_input_ack(cid, %{session_id: sid, last_received_seq: 1})

    %{frames: frames2} = BotConnection.connect(bot, self(), nil)

    session_frames2 = Enum.filter(frames2, &(&1["type"] == "session.input"))
    assert Enum.map(session_frames2, & &1["seq"]) == [2]
  end

  test "input_ack: a closing session does not advance the ack cursor" do
    cid = channel!()
    bot = new_bot()
    session = seed_session(cid, bot)
    pin = seed_pin!(cid, session["session_id"])
    sid = session["session_id"]
    connect_bot!(bot)

    {:ok, _} = send_text(cid, @other, "hi")
    assert session_row(sid)["input_last_acked_seq"] == 0

    {:ok, _} = Channel.request_stop(cid, %{pin_id: pin["pin_id"], user_id: @uid, admin: false})
    assert session_row(sid)["status"] == "closing"

    {:ok, %{}} = Channel.session_input_ack(cid, %{session_id: sid, last_received_seq: 1})

    # the session cursor stays (old Worker: the UPDATE is status-gated)
    assert session_row(sid)["input_last_acked_seq"] == 0
  end

  test "session.effects: non-map effect → BOT_EFFECT_INVALID (type undefined)" do
    cid = channel!()
    bot = new_bot()
    session = seed_session(cid, bot)
    seed_pin!(cid, session["session_id"])

    assert {:error,
            %Errors.ApiError{
              code: "BOT_EFFECT_INVALID",
              message: "unsupported effect type on session.effects: undefined"
            }} =
             Channel.session_effects(cid, %{
               bot_id: bot,
               session_id: session["session_id"],
               effect_seq: 1,
               effects: ["oops"]
             })
  end

  test "request_stop: a session-control pin with no session → PIN_NOT_FOUND" do
    cid = channel!()
    bot = new_bot()
    session = seed_session(cid, bot)
    pin = seed_pin!(cid, session["session_id"])

    # detach the pin from its session
    Repo.query!(
      "UPDATE chat_v2.channel_pins SET session_id = NULL WHERE pin_id = $1",
      [pin["pin_id"]]
    )

    assert {:error,
            %Errors.ApiError{code: "PIN_NOT_FOUND", message: "pin not bound to a session"}} =
             Channel.request_stop(cid, %{
               pin_id: pin["pin_id"],
               user_id: @uid,
               admin: false
             })
  end
end
