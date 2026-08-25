/**
 * Conformance scenario: bot domain — HTTP surface (issue #27 batch D).
 *
 * Covers every bot HTTP route in the contract v2.31 that is bot-token or
 * Browser-JWT scoped (presign/finalize bot routes are covered by batch A):
 *
 *   Developer Bots API (§9.10, Browser JWT, owner-scoped)
 *     * POST   /api/chat/bots                 — create + one-shot initial token
 *     * GET    /api/chat/bots                 — owner list (command_count)
 *     * GET    /api/chat/bots/{bot_id}        — show (+ non-owner 403)
 *     * PATCH  /api/chat/bots/{bot_id}        — update (+ non-owner 403, official-needs-admin)
 *     * GET    /api/chat/bots/{bot_id}/tokens — token metadata (no plaintext)
 *     * POST   /api/chat/bots/{bot_id}/tokens — create token (one-shot plaintext)
 *     * DELETE /api/chat/bots/{bot_id}/tokens/{token_id} — revoke
 *
 *   Admin Bots API (§9.11, Browser JWT + admin claim)
 *     * GET    /api/chat/admin/bots           — global list (+ q/limit filters)
 *     * GET    /api/chat/admin/bots/{bot_id}  — show
 *     * PATCH  /api/chat/admin/bots/{bot_id}  — update
 *     * GET    /api/chat/admin/bots/{bot_id}/tokens
 *     * DELETE /api/chat/admin/bots/{bot_id}/tokens/{token_id}
 *     * non-admin caller → 403 ADMIN_ACCESS_REQUIRED
 *
 *   Bot catalog sync (§9.3, bot token `chat:commands:manage`)
 *     * PUT /api/chat/bot/commands — stateless + stateful commands,
 *       idempotent replay + IDEMPOTENCY_CONFLICT, bad-token 401
 *
 *   Channel command manifest + bindings (§9.4, Browser JWT)
 *     * GET   /channels/{id}/commands — role-filtered manifest (owner sees
 *       platform /help + /permission; member sees /help only), bot command
 *       appears after allow binding, disappears after block, role-filtered
 *       after permission_override
 *     * PATCH /channels/{id}/commands/{bot_command_id} — binding updates
 *     * DM channel manifest → {version: 0, items: []}
 *
 *   Global command directory (§9.12.1, Browser JWT)
 *     * GET /api/chat/commands/directory — query + empty-query full list
 *
 * Deterministic inputs only: fixed actors, fixed Idempotency-Keys, fixed
 * command definitions (definition_hash is a pure function of the definition
 * on both targets). Server-minted ids/timestamps/tokens are normalized.
 */

import type { Scenario } from "../src/types.js";
import { ALICE_USER_ID, BOB_USER_ID } from "./read-paths.js";

const ADMIN_USER_ID = "6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e71";

const KEY_BOT_CREATE = "batchd-bot-create";
const KEY_BOT_UPDATE = "batchd-bot-update";
const KEY_BOT_UPDATE_NONOWNER = "batchd-bot-update-nonowner";
const KEY_BOT_UPDATE_OFFICIAL = "batchd-bot-update-official";
const KEY_TOKEN_CREATE = "batchd-token-create";
const KEY_TOKEN_REVOKE = "batchd-token-revoke";
const KEY_ADMIN_PATCH = "batchd-admin-patch";
const KEY_ADMIN_TOKEN_REVOKE = "batchd-admin-token-revoke";
const KEY_SYNC = "batchd-bot-commands-sync";
const KEY_BIND_ALLOWED = "batchd-bind-ask-allowed";
const KEY_BIND_BLOCKED = "batchd-bind-ask-blocked";
const KEY_BIND_ADMIN = "batchd-bind-ask-admin";
const KEY_CHANNEL_CREATE = "batchd-channel-create";
const KEY_DM_OPEN = "batchd-dm-open";

/** Unknown-bot probe (deterministic, never minted). */
const GHOST_BOT_ID = "0199c0aa-9d00-7000-8000-00000000b0f1";
/** Unknown-token probe (valid `lcbot_` shape, unknown hash). */
const GHOST_BOT_TOKEN = "lcbot_" + "A".repeat(43);

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
            include_own_messages: false,
          },
        },
      },
    },
  ],
};

/** Same catalog with one option description changed → different request hash. */
const CATALOG_BODY_CONFLICT: typeof CATALOG_BODY = {
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
          description: "Changed for conflict probe",
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
            include_own_messages: false,
          },
        },
      },
    },
  ],
};

export const botHttp: Scenario = {
  name: "bot-http",
  description:
    "Bot domain HTTP (issue #27 D): developer + admin Bots API (create/list/show/patch/tokens/revoke + ownership and admin gates), bot catalog sync (stateless + stateful, idempotency, bad token), channel command manifest role-filtering + binding updates + DM manifest, global command directory.",
  actors: {
    alice: { userId: ALICE_USER_ID },
    bob: { userId: BOB_USER_ID },
    admin: { userId: ADMIN_USER_ID, jwtClaims: { admin: true } },
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
        title: "Batch D Bot",
        visibility: "private",
        initial_members: [{ user_id: BOB_USER_ID, role: "member" }],
      },
      capture: { channelId: "$.channel.channel_id" },
    },

    // ------------------------------------- developer bots API (§9.10)
    {
      kind: "http",
      actor: "alice",
      name: "bots:create",
      method: "POST",
      path: "/api/chat/bots",
      headers: { "Idempotency-Key": KEY_BOT_CREATE },
      body: {
        display_name: "Batch D Bot",
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
      name: "bots:list",
      method: "GET",
      path: "/api/chat/bots",
    },
    {
      kind: "http",
      actor: "alice",
      name: "bots:show",
      method: "GET",
      path: "/api/chat/bots/${botId}",
    },
    {
      kind: "http",
      actor: "bob",
      name: "bots:show:nonowner",
      method: "GET",
      path: "/api/chat/bots/${botId}",
    },
    {
      kind: "http",
      actor: "alice",
      name: "bots:update",
      method: "PATCH",
      path: "/api/chat/bots/${botId}",
      headers: { "Idempotency-Key": KEY_BOT_UPDATE },
      body: {
        display_name: "Batch D Bot v2",
        description: "conformance bot",
      },
    },
    {
      kind: "http",
      actor: "bob",
      name: "bots:update:nonowner",
      method: "PATCH",
      path: "/api/chat/bots/${botId}",
      headers: { "Idempotency-Key": KEY_BOT_UPDATE_NONOWNER },
      body: { display_name: "stolen" },
    },
    {
      kind: "http",
      actor: "alice",
      name: "bots:update:official",
      method: "PATCH",
      path: "/api/chat/bots/${botId}",
      headers: { "Idempotency-Key": KEY_BOT_UPDATE_OFFICIAL },
      body: { visibility: "official" },
    },
    {
      kind: "http",
      actor: "alice",
      name: "bots:tokens:list",
      method: "GET",
      path: "/api/chat/bots/${botId}/tokens",
    },
    {
      kind: "http",
      actor: "alice",
      name: "bots:token:create",
      method: "POST",
      path: "/api/chat/bots/${botId}/tokens",
      headers: { "Idempotency-Key": KEY_TOKEN_CREATE },
      body: {
        name: "revocable",
        scopes: ["chat:runtime:connect", "chat:commands:manage"],
      },
      capture: { revocableTokenId: "$.token.token_id" },
    },
    {
      kind: "http",
      actor: "alice",
      name: "bots:token:revoke",
      method: "DELETE",
      path: "/api/chat/bots/${botId}/tokens/${revocableTokenId}",
      headers: { "Idempotency-Key": KEY_TOKEN_REVOKE },
    },
    {
      kind: "http",
      actor: "alice",
      name: "bots:tokens:list:after",
      method: "GET",
      path: "/api/chat/bots/${botId}/tokens",
    },

    // ---------------------------------------- admin bots API (§9.11)
    {
      kind: "http",
      actor: "admin",
      name: "admin:bots:list",
      method: "GET",
      path: "/api/chat/admin/bots",
    },
    {
      kind: "http",
      actor: "admin",
      name: "admin:bots:list:q",
      method: "GET",
      path: "/api/chat/admin/bots?q=batch&limit=10",
    },
    {
      kind: "http",
      actor: "admin",
      name: "admin:bots:show",
      method: "GET",
      path: "/api/chat/admin/bots/${botId}",
    },
    {
      kind: "http",
      actor: "admin",
      name: "admin:bots:show:unknown",
      method: "GET",
      path: `/api/chat/admin/bots/${GHOST_BOT_ID}`,
    },
    {
      kind: "http",
      actor: "admin",
      name: "admin:bots:patch",
      method: "PATCH",
      path: "/api/chat/admin/bots/${botId}",
      headers: { "Idempotency-Key": KEY_ADMIN_PATCH },
      body: {
        description: "admin patched",
        visibility: "unlisted",
      },
    },
    {
      kind: "http",
      actor: "admin",
      name: "admin:bots:tokens",
      method: "GET",
      path: "/api/chat/admin/bots/${botId}/tokens",
    },
    {
      kind: "http",
      actor: "admin",
      name: "admin:bots:token:revoke",
      method: "DELETE",
      path: "/api/chat/admin/bots/${botId}/tokens/${revocableTokenId}",
      headers: { "Idempotency-Key": KEY_ADMIN_TOKEN_REVOKE },
    },
    {
      kind: "http",
      actor: "alice",
      name: "admin:bots:nonadmin",
      method: "GET",
      path: "/api/chat/admin/bots",
    },

    // -------------------------------- bot catalog sync (§9.3, bot token)
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
      name: "bot:commands:sync:replay",
      method: "PUT",
      path: "/api/chat/bot/commands",
      headers: {
        Authorization: "Bearer ${botToken}",
        "Idempotency-Key": KEY_SYNC,
      },
      body: CATALOG_BODY,
    },
    {
      kind: "http",
      actor: "alice",
      name: "bot:commands:sync:conflict",
      method: "PUT",
      path: "/api/chat/bot/commands",
      headers: {
        Authorization: "Bearer ${botToken}",
        "Idempotency-Key": KEY_SYNC,
      },
      body: CATALOG_BODY_CONFLICT,
    },
    {
      kind: "http",
      actor: "alice",
      name: "bot:commands:sync:badtoken",
      method: "PUT",
      path: "/api/chat/bot/commands",
      headers: {
        Authorization: `Bearer ${GHOST_BOT_TOKEN}`,
        "Idempotency-Key": "batchd-bot-commands-badtoken",
      },
      body: CATALOG_BODY,
    },

    // ------------------------- manifest reads + bindings (§9.4, JWT)
    {
      kind: "http",
      actor: "alice",
      name: "manifest:initial",
      method: "GET",
      path: "/api/chat/channels/${channelId}/commands",
      readProbe: { maxQueries: 50 },
    },
    {
      kind: "http",
      actor: "alice",
      name: "bind:ask",
      method: "PATCH",
      path: "/api/chat/channels/${channelId}/commands/${askId}",
      headers: { "Idempotency-Key": KEY_BIND_ALLOWED },
      body: { status: "allowed" },
    },
    {
      kind: "http",
      actor: "alice",
      name: "manifest:after-bind",
      method: "GET",
      path: "/api/chat/channels/${channelId}/commands",
      readProbe: { maxQueries: 50 },
    },
    {
      kind: "http",
      actor: "bob",
      name: "manifest:after-bind:member",
      method: "GET",
      path: "/api/chat/channels/${channelId}/commands",
      readProbe: { maxQueries: 50 },
    },
    {
      kind: "http",
      actor: "alice",
      name: "bind:ask:block",
      method: "PATCH",
      path: "/api/chat/channels/${channelId}/commands/${askId}",
      headers: { "Idempotency-Key": KEY_BIND_BLOCKED },
      body: { status: "blocked" },
    },
    {
      kind: "http",
      actor: "alice",
      name: "manifest:after-block",
      method: "GET",
      path: "/api/chat/channels/${channelId}/commands",
      readProbe: { maxQueries: 50 },
    },
    {
      kind: "http",
      actor: "alice",
      name: "bind:ask:admin",
      method: "PATCH",
      path: "/api/chat/channels/${channelId}/commands/${askId}",
      headers: { "Idempotency-Key": KEY_BIND_ADMIN },
      body: { status: "allowed", permission_override: "admin" },
    },
    {
      kind: "http",
      actor: "alice",
      name: "manifest:after-admin-override",
      method: "GET",
      path: "/api/chat/channels/${channelId}/commands",
      readProbe: { maxQueries: 50 },
    },
    {
      kind: "http",
      actor: "bob",
      name: "manifest:after-admin-override:member",
      method: "GET",
      path: "/api/chat/channels/${channelId}/commands",
      readProbe: { maxQueries: 50 },
    },
    {
      kind: "http",
      actor: "alice",
      name: "bind:ponder",
      method: "PATCH",
      path: "/api/chat/channels/${channelId}/commands/${ponderId}",
      headers: { "Idempotency-Key": "batchd-bind-ponder" },
      body: { status: "allowed", stateful_max_ttl_seconds: 600 },
    },
    {
      kind: "http",
      actor: "alice",
      name: "manifest:after-ponder-bind",
      method: "GET",
      path: "/api/chat/channels/${channelId}/commands",
      readProbe: { maxQueries: 50 },
    },

    // ------------------------------------- DM manifest (§9.4 rule)
    {
      kind: "http",
      actor: "alice",
      name: "dms:open",
      method: "POST",
      path: "/api/chat/dms",
      headers: { "Idempotency-Key": KEY_DM_OPEN },
      body: { recipient_user_id: BOB_USER_ID },
      capture: { dmChannelId: "$.channel.channel_id" },
    },
    {
      kind: "http",
      actor: "alice",
      name: "manifest:dm",
      method: "GET",
      path: "/api/chat/channels/${dmChannelId}/commands",
      readProbe: { maxQueries: 50 },
    },

    // ---------------------------------- command directory (§9.12.1)
    {
      kind: "http",
      actor: "alice",
      name: "directory:query-ask",
      method: "GET",
      path: "/api/chat/commands/directory?query=ask&limit=50",
    },
    {
      kind: "http",
      actor: "alice",
      name: "directory:query-empty",
      method: "GET",
      path: "/api/chat/commands/directory?query=&limit=50",
    },
  ],
};
