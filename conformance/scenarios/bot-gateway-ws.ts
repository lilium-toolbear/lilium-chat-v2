/**
 * Conformance scenario: bot domain — Bot Gateway WS (issue #27 batch D).
 *
 * Full `lilium.chat.bot.v1` gateway protocol round-trip on one channel
 * (alice = owner + session starter, bob = member, bot = the conformance bot):
 *
 *   Transport (§9.1, §9.7.1)
 *     * GET /api/chat/bot/ws upgrade — `lilium.chat.bot.v1` subprotocol +
 *       bot token (`bearer.<token>` subprotocol on both targets; the
 *       contract's `Authorization: Bearer` carrier is sent as a header too)
 *     * hello → ready (bot_id / session_id / server_time), ping → pong
 *
 *   command.invoke + delivery (§9.5, §9.7.1)
 *     * stateless invoke (committed ack + `command.invoked` fanout) → the
 *       bot receives the `delivery` frame (kind `command_invocation`) →
 *       bot `delivery_result` with a send_message effect (two button
 *       components) → `delivery_ack` with effect_results; the bot reply
 *       message id is captured from the `message.created` fanout
 *
 *   interaction.submit + delivery (§9.6, §9.7.1)
 *     * member submits the confirm component → committed ack +
 *       `interaction.created` fanout → bot receives `delivery` (kind
 *       `message_interaction`) → bot `delivery_result` with
 *       disable_components → `delivery_ack` → `interaction.completed`
 *       fanout + GET .../events read surface
 *
 *   Invoke prechecks (§9.5, contract error table)
 *     * stale command_manifest_version → COMMAND_MANIFEST_VERSION_STALE
 *     * blocked binding → COMMAND_NOT_ALLOWED (binding block/allow cycle)
 *     * bot disconnected → BOT_OFFLINE (retryable, nothing persisted)
 *
 *   Stateful session lifecycle (§9.7.4, §9.12.2)
 *     * stateful invoke (committed ack + session_id) → `session.start` push
 *       → `session.start_ack` (silent reply — the server answers with the
 *       `stateful_session.started` fanout + the session-control pin, not a
 *       bot-visible frame)
 *     * session.input (seq 1) for the starter's next message →
 *       `session.input_ack {last_received_seq: 1}` (also silent)
 *     * STATEFUL_SESSION_BUSY on a second stateful invoke while active
 *     * platform stop: starter interaction.submit on the session-control
 *       pin (`platform:stop_session`) → short-circuit ack (no interaction
 *       row) → `session.stop_requested` push → bot `session.close` →
 *       `session.closed` push + `stateful_session.closed` /
 *       `channel.pin.cleared` fanout
 *
 *   Read surfaces after every write: GET .../messages (§6.1 ASC timeline),
 *   GET .../events (§6.1b), GET /channels/{id} (§5.2 channel_pins),
 *   GET /bootstrap (§4.1).
 *
 * Deterministic inputs only: fixed actors, fixed command_id literals,
 * fixed client_effect_id literals, fixed button component_ids (UUIDv7
 * literals — the contract requires bot-supplied component ids, §3.8).
 * The channel manifest version is script-deterministic (0 at channel
 * create, +1 per binding update) so invoke frames carry the exact number.
 * Server-minted ids/timestamps are normalized before diffing.
 *
 * Bot-frame capture (issue #27 D harness): the `delivery` / `session.start`
 * pushes land on the bot socket while the write is in flight, so each write
 * step captures the bot-minted ids (`delivery_id`, `session_id`) from the
 * drained bot frame via a `WsCaptureRef` (`from` predicate + pointer). The
 * bot then answers in the very next step, keeping the old Worker's
 * at-least-once delivery row (`bot_deliveries`, 1 s re-push alarm) from
 * re-pushing before the `delivery_result` completes it.
 */

import type { Scenario } from "../src/types.js";
import { ALICE_USER_ID, BOB_USER_ID } from "./read-paths.js";

const BOT_ACTOR_ID = "6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e72";

const API = "lilium.chat.bot.v1";

const KEY_CHANNEL_CREATE = "batchd-gw-channel-create";
const KEY_BOT_CREATE = "batchd-gw-bot-create";
const KEY_SYNC = "batchd-gw-commands-sync";
const KEY_BIND_ASK = "batchd-gw-bind-ask";
const KEY_BIND_PONDER = "batchd-gw-bind-ponder";
const KEY_BIND_ASK_BLOCK = "batchd-gw-bind-ask-block";
const KEY_BIND_ASK_ALLOW = "batchd-gw-bind-ask-allow";

// Browser command ids (deterministic UUIDv7 literals).
const CMD_LIVE_START_ALICE = "0199c0aa-7a01-7000-8000-000000000a01";
const CMD_LIVE_START_BOB = "0199c0aa-7a02-7000-8000-000000000a02";
const CMD_INVOKE_ASK = "0199c0aa-7a11-7000-8000-000000000a11";
const CMD_INVOKE_STALE = "0199c0aa-7a12-7000-8000-000000000a12";
const CMD_INVOKE_BLOCKED = "0199c0aa-7a13-7000-8000-000000000a13";
const CMD_INTERACT_CONFIRM = "0199c0aa-7a14-7000-8000-000000000a14";
const CMD_INVOKE_PONDER = "0199c0aa-7a15-7000-8000-000000000a15";
const CMD_INVOKE_BUSY = "0199c0aa-7a16-7000-8000-000000000a16";
const CMD_MSG_INPUT = "0199c0aa-7a17-7000-8000-000000000a17";
const CMD_STOP_SESSION = "0199c0aa-7a18-7000-8000-000000000a18";
const CMD_INVOKE_OFFLINE = "0199c0aa-7a19-7000-8000-000000000a19";

// Bot-supplied component ids (contract §3.8 requires UUIDv7 literals).
const COMP_CONFIRM = "0199c0aa-7b01-7000-8000-000000000b01";
const COMP_CANCEL = "0199c0aa-7b02-7000-8000-000000000b02";

const BOT_REPLY_TEXT = "A conformance run is a diff-zero proof that both targets behave identically.";

const CATALOG_BODY = {
  commands: [
    {
      name: "ask",
      aliases: [],
      description: "Ask the conformance assistant",
      help_text: "用法: /ask <prompt>",
      options: [
        {
          name: "prompt",
          type: "string",
          required: true,
          description: "Question",
        },
      ],
      default_member_permission: "member",
      execution: { mode: "stateless" },
    },
    {
      name: "ponder",
      aliases: [],
      description: "Stateful pondering session",
      help_text: "用法: /ponder",
      options: [],
      default_member_permission: "member",
      execution: {
        mode: "stateful",
        stateful: {
          mutex_scope: "channel",
          default_ttl_seconds: 300,
          max_ttl_seconds: 900,
          listen_capability: {
            message_types: ["text"],
            include_bot_messages: false,
            include_own_messages: true,
          },
        },
      },
    },
  ],
};

// ------------------------------------------------------------------ helpers

const isRec = (v: unknown): v is Record<string, unknown> =>
  typeof v === "object" && v !== null;

const ack = (command: string, commandId: string) => (f: unknown): boolean =>
  isRec(f) && f.frame_type === "command_ack" && f.command === command && f.command_id === commandId;

const cmdErr = (commandId: string) => (f: unknown): boolean =>
  isRec(f) && f.frame_type === "command_error" && f.command_id === commandId;

const ev = (type: string) => (f: unknown): boolean =>
  isRec(f) && f.frame_type === "event" && f.type === type;

/** Bot gateway frame (raw protocol — `type` at top level, no frame_type). */
const botFrame = (type: string) => (f: unknown): boolean => isRec(f) && f.type === type;

const botDelivery = (kind: string) => (f: unknown): boolean =>
  isRec(f) && f.type === "delivery" && f.kind === kind;

const botDeliveryAck = (varName: string) => (f: unknown, ctx: { vars: Map<string, unknown> }): boolean =>
  isRec(f) && f.type === "delivery_ack" && f.delivery_id === ctx.vars.get(varName);

/** `message.created` fanout for the bot's reply (matched on its text). */
const botReplyCreated = (f: unknown): boolean => {
  if (!isRec(f) || f.frame_type !== "event" || f.type !== "message.created") return false;
  const payload = isRec(f.payload) ? f.payload : {};
  const message = isRec(payload["message"]) ? payload["message"] : {};
  return typeof message["text"] === "string" && (message["text"] as string).includes("diff-zero proof");
};

export const botGatewayWs: Scenario = {
  name: "bot-gateway-ws",
  description:
    "Bot Gateway WS (issue #27 D): hello/ping, command.invoke → command_invocation delivery → delivery_result (send_message with button components) → delivery_ack, interaction.submit → message_interaction delivery → disable_components, manifest-stale / not-allowed / bot-offline prechecks, full stateful session lifecycle (session.start → input → busy → platform stop → session.close → closed) with every write re-verified on the read surface.",
  actors: {
    alice: { userId: ALICE_USER_ID },
    bob: { userId: BOB_USER_ID },
    bot: { userId: BOT_ACTOR_ID },
  },
  steps: [
    // ------------------------------------------------- fixture: channel
    {
      kind: "http",
      actor: "alice",
      name: "channels:create",
      method: "POST",
      path: "/api/chat/channels",
      headers: { "Idempotency-Key": KEY_CHANNEL_CREATE },
      body: {
        title: "Batch D Gateway",
        visibility: "private",
        initial_members: [{ user_id: BOB_USER_ID, role: "member" }],
      },
      capture: { channelId: "$.channel.channel_id" },
    },

    // --------------------------------------------- fixture: bot + catalog
    {
      kind: "http",
      actor: "alice",
      name: "bots:create",
      method: "POST",
      path: "/api/chat/bots",
      headers: { "Idempotency-Key": KEY_BOT_CREATE },
      body: {
        display_name: "Batch D Gateway Bot",
        avatar_url: null,
        description: null,
        visibility: "private",
        issue_initial_token: true,
        initial_token_name: "default",
      },
      capture: {
        botId: "$.bot.bot_id",
        botToken: "$.initial_token.plaintext",
      },
    },
    {
      kind: "http",
      actor: "alice",
      name: "bot:commands:sync",
      method: "PUT",
      path: "/api/chat/bot/commands",
      headers: {
        Authorization: "Bearer ${botToken}",
        "Idempotency-Key": KEY_SYNC,
      },
      body: CATALOG_BODY,
      capture: {
        askId: "$.commands.0.bot_command_id",
        ponderId: "$.commands.1.bot_command_id",
      },
    },
    {
      kind: "http",
      actor: "alice",
      name: "bind:ask",
      method: "PATCH",
      path: "/api/chat/channels/${channelId}/commands/${askId}",
      headers: { "Idempotency-Key": KEY_BIND_ASK },
      body: { status: "allowed" },
    },
    {
      kind: "http",
      actor: "alice",
      name: "bind:ponder",
      method: "PATCH",
      path: "/api/chat/channels/${channelId}/commands/${ponderId}",
      headers: { "Idempotency-Key": KEY_BIND_PONDER },
      body: { status: "allowed", stateful_max_ttl_seconds: 600 },
    },
    {
      kind: "http",
      actor: "alice",
      name: "manifest:read",
      method: "GET",
      path: "/api/chat/channels/${channelId}/commands",
      readProbe: { maxQueries: 50 },
    },

    // ------------------------------------------------- sockets + handshake
    { kind: "ws.connect", actor: "alice", name: "alice:ws:connect" },
    {
      kind: "ws.command",
      actor: "alice",
      name: "alice:live_start",
      frame: {
        frame_type: "command",
        command: "session.live_start",
        command_id: CMD_LIVE_START_ALICE,
        payload: {},
      },
      waitFor: ack("session.live_start", CMD_LIVE_START_ALICE),
    },
    {
      kind: "wait",
      actor: "alice",
      name: "sync:fanout-lease:alice",
      // The fanout lease is registered out-of-band (old Worker: outbox + DO
      // alarm; Elixir: PubSub subscription). A grace keeps the first fanout
      // from racing ahead of lease registration (batch C pattern).
      ms: 1000,
    },
    { kind: "ws.connect", actor: "bob", name: "bob:ws:connect" },
    {
      kind: "ws.command",
      actor: "bob",
      name: "bob:live_start",
      frame: {
        frame_type: "command",
        command: "session.live_start",
        command_id: CMD_LIVE_START_BOB,
        payload: {},
      },
      waitFor: ack("session.live_start", CMD_LIVE_START_BOB),
    },
    {
      kind: "wait",
      actor: "bob",
      name: "sync:fanout-lease:bob",
      ms: 1000,
    },
    {
      kind: "ws.connect",
      actor: "bot",
      name: "bot:ws:connect",
      path: "/api/chat/bot/ws",
      protocols: [API, "bearer.${botToken}"],
      headers: { Authorization: "Bearer ${botToken}" },
    },
    {
      kind: "ws.command",
      actor: "bot",
      name: "bot:hello",
      frame: { type: "hello", api_version: API, last_received_delivery_id: null },
      waitFor: botFrame("ready"),
    },
    {
      kind: "ws.command",
      actor: "bot",
      name: "bot:ping",
      frame: { type: "ping", api_version: API },
      waitFor: botFrame("pong"),
    },

    // ------------------------------------- stateless invoke + delivery
    {
      kind: "ws.command",
      actor: "alice",
      name: "ws:invoke:ask",
      frame: {
        frame_type: "command",
        command: "command.invoke",
        command_id: CMD_INVOKE_ASK,
        channel_id: "${channelId}",
        payload: {
          bot_command_id: "${askId}",
          invoked_name: "ask",
          options: { prompt: { type: "string", value: "What is conformance?" } },
          // Script-deterministic manifest version: 0 at channel create,
          // +1 per binding update (bind:ask, bind:ponder) → 2 here.
          command_manifest_version: 2,
          reply_to_message_id: null,
        },
      },
      waitFor: ack("command.invoke", CMD_INVOKE_ASK),
      alsoUntil: ev("command.invoked"),
      // The `command_invocation` delivery is pushed to the bot during the
      // write; capture its delivery_id from the drained bot frame.
      capture: { deliveryId1: { from: botDelivery("command_invocation"), pointer: "$.delivery_id" } },
    },
    {
      kind: "ws.command",
      actor: "bot",
      name: "bot:delivery_result:ask",
      frame: {
        type: "delivery_result",
        api_version: API,
        delivery_id: "${deliveryId1}",
        status: "ok",
        effects: [
          {
            client_effect_id: "fx-ask-reply",
            type: "send_message",
            message: {
              type: "text",
              format: "markdown",
              text: BOT_REPLY_TEXT,
              reply_to_message_id: null,
              attachment_ids: [],
              components: [
                {
                  component_id: COMP_CONFIRM,
                  custom_id: "confirm",
                  disabled: false,
                  kind: "button",
                  style: "primary",
                  label: "Confirm",
                },
                {
                  component_id: COMP_CANCEL,
                  custom_id: "cancel",
                  disabled: false,
                  kind: "button",
                  style: "secondary",
                  label: "Cancel",
                },
              ],
            },
          },
        ],
      },
      waitFor: botDeliveryAck("deliveryId1"),
      // The bot reply message id only exists on the message.created fanout
      // (drained into this step); capture it for the interaction probe.
      capture: { botMessageId: { from: botReplyCreated, pointer: "$.payload.message.message_id" } },
    },
    {
      kind: "http",
      actor: "alice",
      name: "messages:list:bot-reply",
      method: "GET",
      path: "/api/chat/channels/${channelId}/messages",
      readProbe: { maxQueries: 50 },
    },

    // ------------------------------------- interaction + delivery
    {
      kind: "ws.command",
      actor: "bob",
      name: "ws:interact:confirm",
      frame: {
        frame_type: "command",
        command: "interaction.submit",
        command_id: CMD_INTERACT_CONFIRM,
        channel_id: "${channelId}",
        payload: {
          message_id: "${botMessageId}",
          component_id: COMP_CONFIRM,
          custom_id: "confirm",
          value: true,
        },
      },
      waitFor: ack("interaction.submit", CMD_INTERACT_CONFIRM),
      alsoUntil: ev("interaction.created"),
      capture: { deliveryId2: { from: botDelivery("message_interaction"), pointer: "$.delivery_id" } },
    },
    {
      kind: "ws.command",
      actor: "bot",
      name: "bot:delivery_result:interaction",
      frame: {
        type: "delivery_result",
        api_version: API,
        delivery_id: "${deliveryId2}",
        status: "ok",
        effects: [
          {
            client_effect_id: "fx-disarm-confirm",
            type: "disable_components",
            message_id: "${botMessageId}",
            component_ids: [COMP_CONFIRM],
          },
        ],
      },
      waitFor: botDeliveryAck("deliveryId2"),
    },
    { kind: "wait", actor: "bot", name: "sync:fanout:interaction", ms: 750 },
    {
      kind: "http",
      actor: "alice",
      name: "events:read",
      method: "GET",
      path: "/api/chat/channels/${channelId}/events",
      readProbe: { maxQueries: 50 },
    },

    // ------------------------------------- invoke prechecks (errors)
    {
      kind: "ws.command",
      actor: "alice",
      name: "ws:invoke:stale",
      frame: {
        frame_type: "command",
        command: "command.invoke",
        command_id: CMD_INVOKE_STALE,
        channel_id: "${channelId}",
        payload: {
          bot_command_id: "${askId}",
          invoked_name: "ask",
          options: { prompt: { type: "string", value: "stale probe" } },
          command_manifest_version: 1,
          reply_to_message_id: null,
        },
      },
      waitFor: cmdErr(CMD_INVOKE_STALE),
    },
    {
      kind: "http",
      actor: "alice",
      name: "bind:ask:block",
      method: "PATCH",
      path: "/api/chat/channels/${channelId}/commands/${askId}",
      headers: { "Idempotency-Key": KEY_BIND_ASK_BLOCK },
      body: { status: "blocked" },
    },
    {
      kind: "ws.command",
      actor: "alice",
      name: "ws:invoke:blocked",
      frame: {
        frame_type: "command",
        command: "command.invoke",
        command_id: CMD_INVOKE_BLOCKED,
        channel_id: "${channelId}",
        payload: {
          bot_command_id: "${askId}",
          invoked_name: "ask",
          options: { prompt: { type: "string", value: "blocked probe" } },
          command_manifest_version: 3,
          reply_to_message_id: null,
        },
      },
      waitFor: cmdErr(CMD_INVOKE_BLOCKED),
    },
    {
      kind: "http",
      actor: "alice",
      name: "bind:ask:allow",
      method: "PATCH",
      path: "/api/chat/channels/${channelId}/commands/${askId}",
      headers: { "Idempotency-Key": KEY_BIND_ASK_ALLOW },
      body: { status: "allowed" },
    },

    // ------------------------------------- stateful session lifecycle
    {
      kind: "ws.command",
      actor: "alice",
      name: "ws:invoke:ponder",
      frame: {
        frame_type: "command",
        command: "command.invoke",
        command_id: CMD_INVOKE_PONDER,
        channel_id: "${channelId}",
        payload: {
          bot_command_id: "${ponderId}",
          invoked_name: "ponder",
          options: {},
          // manifest version after block + re-allow → 4
          command_manifest_version: 4,
          reply_to_message_id: null,
        },
      },
      waitFor: ack("command.invoke", CMD_INVOKE_PONDER),
      alsoUntil: ev("command.invoked"),
      // The stateful invoke pushes `session.start` to the bot during the
      // write; capture the session_id from the drained bot frame.
      capture: { sessionId: { from: botFrame("session.start"), pointer: "$.session_id" } },
    },
    {
      kind: "ws.command",
      actor: "bot",
      name: "bot:session:start_ack",
      frame: { type: "session.start_ack", api_version: API, session_id: "${sessionId}" },
      // Fire-and-forget: the old Worker's BotConnection sends no bot-visible
      // reply for session.start_ack (contract §9.7.4) — the server answers
      // with the stateful_session.started fanout + the session-control pin.
    },
    { kind: "wait", actor: "bot", name: "sync:session-started", ms: 750 },
    {
      kind: "ws.command",
      actor: "alice",
      name: "ws:msg:input",
      frame: {
        frame_type: "command",
        command: "message.send",
        command_id: CMD_MSG_INPUT,
        channel_id: "${channelId}",
        payload: {
          type: "text",
          text: "Keep pondering — session input probe",
          reply_to_message_id: null,
          attachment_ids: [],
          mentions: [],
        },
      },
      waitFor: ack("message.send", CMD_MSG_INPUT),
      alsoUntil: ev("message.created"),
    },
    {
      kind: "ws.command",
      actor: "bot",
      name: "bot:session:input_ack",
      frame: {
        type: "session.input_ack",
        api_version: API,
        session_id: "${sessionId}",
        last_received_seq: 1,
      },
      // Fire-and-forget (silent reply, contract §9.7.4).
    },
    {
      kind: "ws.command",
      actor: "alice",
      name: "ws:invoke:busy",
      frame: {
        frame_type: "command",
        command: "command.invoke",
        command_id: CMD_INVOKE_BUSY,
        channel_id: "${channelId}",
        payload: {
          bot_command_id: "${ponderId}",
          invoked_name: "ponder",
          options: {},
          command_manifest_version: 4,
          reply_to_message_id: null,
        },
      },
      waitFor: cmdErr(CMD_INVOKE_BUSY),
    },
    {
      kind: "http",
      actor: "alice",
      name: "channels:detail:session-active",
      method: "GET",
      path: "/api/chat/channels/${channelId}",
      readProbe: { maxQueries: 50 },
      capture: {
        pinId: "$.channel_pins.0.pin_id",
        pinStopComponentId: "$.channel_pins.0.message.components.0.component_id",
      },
    },

    // ------------------------------------- platform stop + session close
    {
      kind: "ws.command",
      actor: "alice",
      name: "ws:stop:session",
      frame: {
        frame_type: "command",
        command: "interaction.submit",
        command_id: CMD_STOP_SESSION,
        channel_id: "${channelId}",
        payload: {
          pin_id: "${pinId}",
          component_id: "${pinStopComponentId}",
          custom_id: "platform:stop_session",
          value: true,
        },
      },
      waitFor: ack("interaction.submit", CMD_STOP_SESSION),
      alsoUntil: ev("channel.pin.updated"),
    },
    {
      kind: "ws.command",
      actor: "bot",
      name: "bot:session:close",
      frame: {
        type: "session.close",
        api_version: API,
        session_id: "${sessionId}",
        reason: "bot_closed",
      },
      waitFor: botFrame("session.closed"),
    },
    { kind: "wait", actor: "bot", name: "sync:session-closed", ms: 750 },
    {
      kind: "http",
      actor: "alice",
      name: "channels:detail:session-closed",
      method: "GET",
      path: "/api/chat/channels/${channelId}",
      readProbe: { maxQueries: 50 },
    },
    {
      kind: "http",
      actor: "alice",
      name: "events:read:after",
      method: "GET",
      path: "/api/chat/channels/${channelId}/events",
      readProbe: { maxQueries: 50 },
    },

    // ------------------------------------- BOT_OFFLINE precheck
    {
      kind: "ws.close",
      actor: "bot",
      name: "bot:ws:close",
    },
    { kind: "wait", actor: "alice", name: "sync:bot-disconnect", ms: 750 },
    {
      kind: "ws.command",
      actor: "alice",
      name: "ws:invoke:offline",
      frame: {
        frame_type: "command",
        command: "command.invoke",
        command_id: CMD_INVOKE_OFFLINE,
        channel_id: "${channelId}",
        payload: {
          bot_command_id: "${askId}",
          invoked_name: "ask",
          options: { prompt: { type: "string", value: "offline probe" } },
          command_manifest_version: 4,
          reply_to_message_id: null,
        },
      },
      waitFor: cmdErr(CMD_INVOKE_OFFLINE),
    },

    // ------------------------------------- final bootstrap read surface
    {
      kind: "http",
      actor: "alice",
      name: "bootstrap:final",
      method: "GET",
      path: "/api/chat/bootstrap?channel_id=${channelId}",
      readProbe: { maxQueries: 80 },
    },
  ],
};
