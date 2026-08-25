/**
 * Conformance scenario: bot domain — Bot Stream WS (issue #27 batch D).
 *
 * Full `lilium.chat.bot.stream.v1` protocol round-trip (contract §9.15):
 *
 *   start_stream effect (§9.14)
 *     * command.invoke → command_invocation delivery → bot `delivery_result`
 *       with a `start_stream` effect → `delivery_ack` effect_result carries
 *       `stream.ws_url` (host normalized to {{HOST}}) — the ws_url is the
 *       Stream WS upgrade path.
 *
 *   Stream WS transport (§9.15.1) — upgrade probes pinned by HTTP status
 *     * unknown bot token        → 401 UNAUTHORIZED
 *     * token missing chat:messages:write → 403 BOT_SCOPE_DENIED
 *     * unknown stream (registry miss)    → 404 BOT_STREAM_NOT_FOUND
 *     * finalized stream (registry status finalized) → 410 BOT_STREAM_EXPIRED
 *
 *   Stream frames + sequence rules (§9.15.2, §9.15.3)
 *     * hello → ready `{channel_id, message_id, expires_at, ack_seq}`
 *       (fresh stream ack_seq = 0)
 *     * append seq 1 → append_ack {ack_seq: 1}
 *     * append seq 3 (received_seq 1) → stream_error BOT_STREAM_SEQUENCE_GAP
 *       (retryable)
 *     * append seq 2 → append_ack {ack_seq: 2}
 *     * ping → pong
 *     * finalize {final_seq: 2} → finalized_ack {ok: true, message_id,
 *       event_id} — one canonical txn: final messages row +
 *       message.stream_finalized event (NO message.created, §9.15.4)
 *
 *   Read surfaces: GET .../messages (final streamed message with the
 *   accumulated deltas, stream_state final), GET .../events
 *   (message.stream_finalized), GET /bootstrap (§4.1).
 *
 * Deterministic inputs only: fixed actors, fixed command_id literals,
 * fixed client_effect_id literals. The stream path is wired from the
 * start_stream effect result captured on the delivery_ack (the stream
 * message has no canonical read surface before finalize).
 */

import type { Scenario } from "../src/types.js";
import { ALICE_USER_ID } from "./read-paths.js";

const BOT_ACTOR_ID = "6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e73";

const BOT_API = "lilium.chat.bot.v1";
const STREAM_API = "lilium.chat.bot.stream.v1";

const KEY_CHANNEL_CREATE = "batchd-s-channel-create";
const KEY_BOT_CREATE = "batchd-s-bot-create";
const KEY_SCOPE_TOKEN = "batchd-s-scope-token";
const KEY_SYNC = "batchd-s-commands-sync";
const KEY_BIND_DRAFT = "batchd-s-bind-draft";

const CMD_INVOKE_DRAFT = "0199c0aa-7e11-7000-8000-000000000e11";
const CMD_LIVE_START_ALICE = "0199c0aa-7e12-7000-8000-000000000e12";

/** Ghost stream message id (valid v7 literal, never minted). */
const GHOST_STREAM_MESSAGE_ID = "0199c0aa-7d01-7000-8000-000000000d01";
/** Ghost bot token (valid `lcbot_` shape, unknown hash). */
const GHOST_BOT_TOKEN = "lcbot_" + "B".repeat(43);
// Baked at definition time: the runner only interpolates runtime-captured
// names, so TS consts (ghost id / ghost token) are folded into literals here,
// while runtime captures (channelId, botToken, …) stay as `${name}` text.
const GHOST_BEARER_SUBPROTOCOL = `bearer.${GHOST_BOT_TOKEN}`;
const GHOST_AUTH_HEADER = `Bearer ${GHOST_BOT_TOKEN}`;
const GHOST_STREAM_PATH = `/api/chat/bot/channels/\${channelId}/streams/${GHOST_STREAM_MESSAGE_ID}/ws`;

const CATALOG_BODY = {
  commands: [
    {
      name: "draft",
      aliases: [],
      description: "Streamed draft answer",
      help_text: "用法: /draft",
      options: [],
      default_member_permission: "member",
      execution: { mode: "stateless" },
    },
  ],
};

// ------------------------------------------------------------------ helpers

const isRec = (v: unknown): v is Record<string, unknown> =>
  typeof v === "object" && v !== null;

const ack = (command: string, commandId: string) => (f: unknown): boolean =>
  isRec(f) && f.frame_type === "command_ack" && f.command === command && f.command_id === commandId;

const ev = (type: string) => (f: unknown): boolean =>
  isRec(f) && f.frame_type === "event" && f.type === type;

const botFrame = (type: string) => (f: unknown): boolean => isRec(f) && f.type === type;

const botDelivery = (kind: string) => (f: unknown): boolean =>
  isRec(f) && f.type === "delivery" && f.kind === kind;

const botDeliveryAck = (varName: string) => (f: unknown, ctx: { vars: Map<string, unknown> }): boolean =>
  isRec(f) && f.type === "delivery_ack" && f.delivery_id === ctx.vars.get(varName);

export const botStreamWs: Scenario = {
  name: "bot-stream-ws",
  description:
    "Bot Stream WS (issue #27 D): start_stream effect → Stream WS upgrade (hello/ready with fresh ack_seq), append seq rules (accept, BOT_STREAM_SEQUENCE_GAP, ack), ping/pong, finalize → finalized_ack, upgrade auth probes (401/403/404/410), final streamed message re-verified on the read surface.",
  actors: {
    alice: { userId: ALICE_USER_ID },
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
        title: "Batch D Stream",
        visibility: "private",
        initial_members: [],
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
        display_name: "Batch D Stream Bot",
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
      name: "bots:token:gateway-only",
      method: "POST",
      path: "/api/chat/bots/${botId}/tokens",
      headers: { "Idempotency-Key": KEY_SCOPE_TOKEN },
      body: {
        name: "gateway-only",
        scopes: ["chat:runtime:connect"],
      },
      capture: { gatewayOnlyToken: "$.token.plaintext" },
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
      capture: { draftId: "$.commands.0.bot_command_id" },
    },
    {
      kind: "http",
      actor: "alice",
      name: "bind:draft",
      method: "PATCH",
      path: "/api/chat/channels/${channelId}/commands/${draftId}",
      headers: { "Idempotency-Key": KEY_BIND_DRAFT },
      body: { status: "allowed" },
    },
    {
      kind: "http",
      actor: "alice",
      name: "manifest:read",
      method: "GET",
      path: "/api/chat/channels/${channelId}/commands",
      readProbe: { maxQueries: 50 },
    },

    // ------------------------------------- gateway: invoke + start_stream
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
      ms: 1000,
    },
    {
      kind: "ws.connect",
      actor: "bot",
      name: "bot:ws:connect",
      path: "/api/chat/bot/ws",
      protocols: [BOT_API, "bearer.${botToken}"],
      headers: { Authorization: "Bearer ${botToken}" },
    },
    {
      kind: "ws.command",
      actor: "bot",
      name: "bot:hello",
      frame: { type: "hello", api_version: BOT_API, last_received_delivery_id: null },
      waitFor: botFrame("ready"),
    },
    {
      kind: "ws.command",
      actor: "alice",
      name: "ws:invoke:draft",
      frame: {
        frame_type: "command",
        command: "command.invoke",
        command_id: CMD_INVOKE_DRAFT,
        channel_id: "${channelId}",
        payload: {
          bot_command_id: "${draftId}",
          invoked_name: "draft",
          options: {},
          // Manifest version: 0 at channel create, +1 (bind:draft) → 1.
          command_manifest_version: 1,
          reply_to_message_id: null,
        },
      },
      waitFor: ack("command.invoke", CMD_INVOKE_DRAFT),
      alsoUntil: ev("command.invoked"),
      // The command_invocation delivery is pushed to the bot during the
      // write; capture its delivery_id from the drained bot frame.
      capture: { deliveryId: { from: botDelivery("command_invocation"), pointer: "$.delivery_id" } },
    },
    {
      kind: "ws.command",
      actor: "bot",
      name: "bot:delivery_result:start_stream",
      frame: {
        type: "delivery_result",
        api_version: BOT_API,
        delivery_id: "${deliveryId}",
        status: "ok",
        effects: [
          {
            client_effect_id: "fx-stream-1",
            type: "start_stream",
            message: {
              type: "text",
              format: "markdown",
              reply_to_message_id: null,
              attachment_ids: [],
              components: [],
            },
          },
        ],
      },
      waitFor: botDeliveryAck("deliveryId"),
      capture: {
        // Stream WS path parameter — only exists on the effect result
        // (no canonical message row until finalize, contract §9.14).
        streamMessageId: "$.effect_results.0.message_id",
      },
    },
    {
      kind: "ws.close",
      actor: "bot",
      name: "bot:ws:close",
    },

    // ------------------------------------- stream upgrade auth probes
    // The ws library reports non-101 upgrades as "unexpected server
    // response <status>" — the status is the pinned parity surface; the
    // JSON error body in the rejection follows the contract error envelope
    // (same code/message/retryable on both targets — verified in the
    // old-Worker route + Elixir handle_connect_error).
    {
      kind: "ws.connect",
      actor: "bot",
      name: "stream:connect:badtoken",
      path: GHOST_STREAM_PATH,
      protocols: [STREAM_API, GHOST_BEARER_SUBPROTOCOL],
      headers: { Authorization: GHOST_AUTH_HEADER },
    },
    {
      kind: "ws.connect",
      actor: "bot",
      name: "stream:connect:noscope",
      path: GHOST_STREAM_PATH,
      protocols: [STREAM_API, "bearer.${gatewayOnlyToken}"],
      headers: { Authorization: "Bearer ${gatewayOnlyToken}" },
    },
    {
      kind: "ws.connect",
      actor: "bot",
      name: "stream:connect:unknown",
      path: GHOST_STREAM_PATH,
      protocols: [STREAM_API, "bearer.${botToken}"],
      headers: { Authorization: "Bearer ${botToken}" },
    },

    // ------------------------------------- stream: hello/append/finalize
    {
      kind: "ws.connect",
      actor: "bot",
      name: "stream:ws:connect",
      path: "/api/chat/bot/channels/${channelId}/streams/${streamMessageId}/ws",
      protocols: [STREAM_API, "bearer.${botToken}"],
      headers: { Authorization: "Bearer ${botToken}" },
    },
    {
      kind: "ws.command",
      actor: "bot",
      name: "stream:hello",
      frame: { type: "hello", api_version: STREAM_API },
      waitFor: botFrame("ready"),
    },
    {
      kind: "ws.command",
      actor: "bot",
      name: "stream:append:seq1",
      frame: { type: "append", api_version: STREAM_API, seq: 1, delta: "Conformance " },
      waitFor: botFrame("append_ack"),
    },
    {
      kind: "ws.command",
      actor: "bot",
      name: "stream:append:gap",
      frame: { type: "append", api_version: STREAM_API, seq: 3, delta: "(gap)" },
      waitFor: botFrame("stream_error"),
    },
    {
      kind: "ws.command",
      actor: "bot",
      name: "stream:append:seq2",
      frame: { type: "append", api_version: STREAM_API, seq: 2, delta: "stream OK." },
      waitFor: botFrame("append_ack"),
    },
    {
      kind: "ws.command",
      actor: "bot",
      name: "stream:ping",
      frame: { type: "ping", api_version: STREAM_API },
      waitFor: botFrame("pong"),
    },
    {
      kind: "ws.command",
      actor: "bot",
      name: "stream:finalize",
      frame: { type: "finalize", api_version: STREAM_API, final_seq: 2, attachment_ids: [] },
      waitFor: botFrame("finalized_ack"),
    },
    { kind: "wait", actor: "bot", name: "sync:fanout:stream-final", ms: 750 },
    {
      kind: "ws.close",
      actor: "bot",
      name: "stream:ws:close",
    },

    // ------------------------------------- read surfaces (post-finalize)
    {
      kind: "http",
      actor: "alice",
      name: "messages:list:stream",
      method: "GET",
      path: "/api/chat/channels/${channelId}/messages",
      readProbe: { maxQueries: 50 },
    },
    {
      kind: "http",
      actor: "alice",
      name: "events:read",
      method: "GET",
      path: "/api/chat/channels/${channelId}/events",
      readProbe: { maxQueries: 50 },
    },
    {
      kind: "http",
      actor: "alice",
      name: "bootstrap:final",
      method: "GET",
      path: "/api/chat/bootstrap?channel_id=${channelId}",
      readProbe: { maxQueries: 80 },
    },

    // --------------------- finalized-stream upgrade probe (410, §9.15.1)
    {
      kind: "ws.connect",
      actor: "bot",
      name: "stream:connect:finalized",
      path: "/api/chat/bot/channels/${channelId}/streams/${streamMessageId}/ws",
      protocols: [STREAM_API, "bearer.${botToken}"],
      headers: { Authorization: "Bearer ${botToken}" },
    },
  ],
};
