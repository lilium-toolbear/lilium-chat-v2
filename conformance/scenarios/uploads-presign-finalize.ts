/**
 * Conformance scenario: presign/finalize uploads (issue #27 batch B).
 *
 *   * User routes (contract §8.1/§8.2):
 *       POST /api/chat/uploads/images/presign
 *       PUT  {presigned upload_url}            (fixture S3 store)
 *       POST /api/chat/uploads/images/{id}/finalize
 *   * Bot routes (contract §9.17.1):
 *       POST /api/chat/bots                                   (bot fixture)
 *       PUT  /api/chat/bot/commands                           (bot fixture)
 *       PATCH /api/chat/channels/{id}/commands/{bot_command_id}
 *       POST /api/chat/bot/channels/{id}/uploads/images/presign
 *       PUT  {presigned upload_url}
 *       POST /api/chat/bot/channels/{id}/uploads/images/{id}/finalize
 *
 * Both targets sign against the same fixture object store (fake-s3 compose
 * service; S3_ENDPOINT host is identical on both targets by construction —
 * see conformance/fixtures/fake-s3.mjs + docker-compose.yml). The PUT step
 * sends a STATIC 12345-byte binary (base64Body): identical bytes on both
 * targets, and exactly the size_bytes the presign body declares (contract
 * §8.2 finalize HEAD verifies Content-Type + Content-Length).
 *
 * Idempotency coverage (per §2.5): same key + same body → cached replay
 * (byte-identical response); same key + different body → 409
 * IDEMPOTENCY_CONFLICT (message normalized by the harness, contract §2.5
 * v2.31 delta note).
 */

import type { Scenario } from "../src/types.js";

export const ALICE_USER_ID = "6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e6f";
export const BOB_USER_ID = "6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e70";

/** 12345 deterministic bytes (contract §8.1 example size_bytes). */
const IMAGE_SIZE = 12_345;
const IMAGE_BYTES = Buffer.alloc(IMAGE_SIZE);
for (let i = 0; i < IMAGE_SIZE; i++) IMAGE_BYTES[i] = i % 256;
const IMAGE_B64 = IMAGE_BYTES.toString("base64");

// Signed headers the presign mandates (contract §8.1 upload_headers).
const UPLOAD_HEADERS = {
  "Content-Type": "image/png",
  "Cache-Control": "public, max-age=31536000, immutable",
};

// A second presign body for the IDEMPOTENCY_CONFLICT replay (same key,
// different filename → different request hash).
const CONFLICT_PRESIGN_BODY = {
  filename: "other.png",
  mime_type: "image/png",
  size_bytes: IMAGE_SIZE,
  width: 16,
  height: 16,
  blurhash: null,
};

const PRESIGN_BODY = {
  filename: "conformance.png",
  mime_type: "image/png",
  size_bytes: IMAGE_SIZE,
  width: 64,
  height: 48,
  blurhash: null,
};

const BOT_PRESIGN_BODY = {
  filename: "bot-image.png",
  mime_type: "image/png",
  size_bytes: IMAGE_SIZE,
  width: 32,
  height: 32,
  blurhash: null,
};

export const uploadsPresignFinalize: Scenario = {
  name: "uploads-presign-finalize",
  description:
    "Presign/finalize conformance (issue #27 B): user §8.1/§8.2 + bot §9.17.1 routes, real SigV4 PUT against the fixture store, idempotency replay/conflict, cross-user + unknown-attachment gates.",
  actors: {
    alice: { userId: ALICE_USER_ID },
    bob: { userId: BOB_USER_ID },
  },
  steps: [
    // -------------------------------------------- fixture: channel (bot)
    {
      kind: "http",
      actor: "alice",
      name: "channels:create",
      method: "POST",
      path: "/api/chat/channels",
      headers: { "Idempotency-Key": "conformance-uploads-channel" },
      body: {
        title: "Uploads Channel",
        topic: null,
        avatar_attachment_id: null,
        visibility: "private",
        initial_members: [],
      },
      capture: { channelId: "$.channel.channel_id" },
    },
    {
      kind: "http",
      actor: "alice",
      name: "sync:channel-projected",
      method: "GET",
      path: "/api/chat/channels",
      retryUntil: (res, ctx) => {
        const channelId = ctx.vars.get("channelId");
        if (typeof res.body !== "object" || res.body === null) return false;
        const items = (res.body as { items?: Array<{ channel_id?: string }> }).items ?? [];
        return items.some((it) => it.channel_id === channelId);
      },
      maxAttempts: 40,
    },

    // ------------------------------------------------- user presign flow
    {
      kind: "http",
      actor: "alice",
      name: "uploads:user:presign",
      method: "POST",
      path: "/api/chat/uploads/images/presign",
      headers: { "Idempotency-Key": "conformance-presign-1" },
      body: PRESIGN_BODY,
      capture: {
        uploadUrl: "$.upload_url",
        attachmentId: "$.attachment_id",
      },
    },
    {
      kind: "http",
      actor: "alice",
      name: "s3:put:user",
      method: "PUT",
      absolute: true,
      path: "${uploadUrl}",
      headers: UPLOAD_HEADERS,
      base64Body: IMAGE_B64,
    },
    {
      kind: "http",
      actor: "alice",
      name: "uploads:user:finalize",
      method: "POST",
      path: "/api/chat/uploads/images/${attachmentId}/finalize",
      headers: { "Idempotency-Key": "conformance-finalize-1" },
      body: { etag: "conformance-etag" },
      capture: {
        userAttachmentUrl: "$.attachment.url",
      },
    },

    // ------------------------------------------- idempotency: user presign
    {
      kind: "http",
      actor: "alice",
      name: "uploads:user:presign:replay",
      method: "POST",
      path: "/api/chat/uploads/images/presign",
      headers: { "Idempotency-Key": "conformance-presign-1" },
      body: PRESIGN_BODY,
    },
    {
      kind: "http",
      actor: "alice",
      name: "uploads:user:presign:conflict",
      method: "POST",
      path: "/api/chat/uploads/images/presign",
      headers: { "Idempotency-Key": "conformance-presign-1" },
      body: CONFLICT_PRESIGN_BODY,
    },

    // ------------------------------------------------- gates: finalize
    {
      kind: "http",
      actor: "bob",
      name: "uploads:user:finalize:cross-user",
      method: "POST",
      path: "/api/chat/uploads/images/${attachmentId}/finalize",
      headers: { "Idempotency-Key": "conformance-finalize-bob" },
      body: { etag: "conformance-etag" },
    },
    {
      kind: "http",
      actor: "alice",
      name: "uploads:user:finalize:unknown",
      method: "POST",
      path: "/api/chat/uploads/images/00000000-0000-7000-8000-000000000599/finalize",
      headers: { "Idempotency-Key": "conformance-finalize-unknown" },
      body: { etag: null },
    },

    // ------------------------------------------------- fixture: bot
    {
      kind: "http",
      actor: "alice",
      name: "bots:create",
      method: "POST",
      path: "/api/chat/bots",
      headers: { "Idempotency-Key": "conformance-bot-create" },
      body: {
        display_name: "Conformance Bot",
        avatar_url: null,
        description: null,
        issue_initial_token: true,
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
        "Idempotency-Key": "conformance-bot-commands",
      },
      body: {
        commands: [
          {
            name: "ask",
            aliases: [],
            description: "Conformance bot command",
            help_text: null,
            options: [],
            default_member_permission: "member",
            execution: { mode: "stateless" },
          },
        ],
      },
      capture: { botCommandId: "$.commands.0.bot_command_id" },
    },
    {
      kind: "http",
      actor: "alice",
      name: "bot:commands:bind",
      method: "PATCH",
      path: "/api/chat/channels/${channelId}/commands/${botCommandId}",
      headers: { "Idempotency-Key": "conformance-bot-bind" },
      body: { status: "allowed" },
    },

    // ------------------------------------------------- bot presign flow
    {
      kind: "http",
      actor: "alice",
      name: "bot:presign",
      method: "POST",
      path: "/api/chat/bot/channels/${channelId}/uploads/images/presign",
      headers: {
        Authorization: "Bearer ${botToken}",
        "Idempotency-Key": "conformance-bot-presign",
      },
      body: BOT_PRESIGN_BODY,
      capture: {
        botUploadUrl: "$.upload_url",
        botAttachmentId: "$.attachment_id",
      },
    },
    {
      kind: "http",
      actor: "alice",
      name: "s3:put:bot",
      method: "PUT",
      absolute: true,
      path: "${botUploadUrl}",
      headers: UPLOAD_HEADERS,
      base64Body: IMAGE_B64,
    },
    {
      kind: "http",
      actor: "alice",
      name: "bot:finalize",
      method: "POST",
      // Contract §9.17.1: attachment_id in the PATH; body carries only the
      // etag; no Idempotency-Key on bot finalize (parity with old Worker).
      path: "/api/chat/bot/channels/${channelId}/uploads/images/${botAttachmentId}/finalize",
      headers: { Authorization: "Bearer ${botToken}" },
      body: { etag: "conformance-bot-etag" },
      capture: {
        botAttachmentUrl: "$.attachment.url",
      },
    },

    // -------------------------------------------- idempotency: bot presign
    {
      kind: "http",
      actor: "alice",
      name: "bot:presign:replay",
      method: "POST",
      path: "/api/chat/bot/channels/${channelId}/uploads/images/presign",
      headers: {
        Authorization: "Bearer ${botToken}",
        "Idempotency-Key": "conformance-bot-presign",
      },
      body: BOT_PRESIGN_BODY,
    },
    {
      kind: "http",
      actor: "alice",
      name: "bot:presign:conflict",
      method: "POST",
      path: "/api/chat/bot/channels/${channelId}/uploads/images/presign",
      headers: {
        Authorization: "Bearer ${botToken}",
        "Idempotency-Key": "conformance-bot-presign",
      },
      body: { ...BOT_PRESIGN_BODY, filename: "other-bot.png" },
    },
  ],
};
