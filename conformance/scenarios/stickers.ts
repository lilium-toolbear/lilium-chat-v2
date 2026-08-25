/**
 * Conformance scenario: personal sticker library (issue #27 batch C).
 *
 * Contract §8.3:
 *   * GET    /api/chat/stickers                 — personal library list
 *   * POST   /api/chat/stickers                 — save (Idempotency-Key)
 *   * DELETE /api/chat/stickers/{sticker_id}    — delete (Idempotency-Key)
 *
 * Flow: presign + PUT + finalize a user-owned attachment (the save source —
 * §8.3 accepts a finalized attachment owned by the caller without a channel
 * message link), then:
 *
 *   1. list (empty)
 *   2. save → { sticker: { sticker_id, attachment, created_at } }
 *   3. save replay (same key + same body → cached, same sticker_id)
 *   4. save conflict (same key + different body → 409 IDEMPOTENCY_CONFLICT)
 *   5. list (one item) — alice
 *   6. list (empty)    — bob (personal library, §8.3)
 *   7. bob delete alice's sticker → 403 FORBIDDEN
 *   8. alice delete → { sticker_id, deleted: true }
 *   9. delete replay (same key + same body → cached)
 *   10. list (empty again)
 *   11. re-save → revives the soft-deleted item (same sticker_id)
 *   12. list (one item again)
 *
 * The attachment bytes are the same deterministic 12345-byte payload as the
 * uploads scenario (see uploads-presign-finalize.ts).
 */

import type { Scenario } from "../src/types.js";

export const ALICE_USER_ID = "6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e6f";
export const BOB_USER_ID = "6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e70";

const IMAGE_SIZE = 12_345;
const IMAGE_BYTES = Buffer.alloc(IMAGE_SIZE);
for (let i = 0; i < IMAGE_SIZE; i++) IMAGE_BYTES[i] = i % 256;
const IMAGE_B64 = IMAGE_BYTES.toString("base64");

const UPLOAD_HEADERS = {
  "Content-Type": "image/png",
  "Cache-Control": "public, max-age=31536000, immutable",
};

const PRESIGN_BODY = {
  filename: "sticker.png",
  mime_type: "image/png",
  size_bytes: IMAGE_SIZE,
  width: 32,
  height: 32,
  blurhash: null,
};

// A different attachment_id for the save IDEMPOTENCY_CONFLICT replay — the
// idempotency conflict fires BEFORE source resolution (old Worker order),
// so the unknown id must not be resolvable.
const CONFLICT_ATTACHMENT_ID = "00000000-0000-7000-8000-000000000598";

export const stickers: Scenario = {
  name: "stickers",
  description:
    "Sticker library conformance (issue #27 C): §8.3 list/save/delete — idempotent saves (replay + conflict), cross-user delete gate, soft-delete + revive, personal-library isolation.",
  actors: {
    alice: { userId: ALICE_USER_ID },
    bob: { userId: BOB_USER_ID },
  },
  steps: [
    // fixture: channel (the save body carries channel_id per §8.3)
    {
      kind: "http",
      actor: "alice",
      name: "channels:create",
      method: "POST",
      path: "/api/chat/channels",
      headers: { "Idempotency-Key": "conformance-stickers-channel" },
      body: {
        title: "Stickers Channel",
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

    // fixture: alice's finalized attachment (the sticker source)
    {
      kind: "http",
      actor: "alice",
      name: "uploads:presign",
      method: "POST",
      path: "/api/chat/uploads/images/presign",
      headers: { "Idempotency-Key": "conformance-sticker-presign" },
      body: PRESIGN_BODY,
      capture: {
        uploadUrl: "$.upload_url",
        attachmentId: "$.attachment_id",
      },
    },
    {
      kind: "http",
      actor: "alice",
      name: "s3:put",
      method: "PUT",
      absolute: true,
      path: "${uploadUrl}",
      headers: UPLOAD_HEADERS,
      base64Body: IMAGE_B64,
    },
    {
      kind: "http",
      actor: "alice",
      name: "uploads:finalize",
      method: "POST",
      path: "/api/chat/uploads/images/${attachmentId}/finalize",
      headers: { "Idempotency-Key": "conformance-sticker-finalize" },
      body: { etag: "conformance-etag" },
    },

    // ---------------------------------------------------------------- list
    {
      kind: "http",
      actor: "alice",
      name: "stickers:list:empty",
      method: "GET",
      path: "/api/chat/stickers",
      readProbe: { maxQueries: 50 },
    },

    // --------------------------------------------------------------- save
    {
      kind: "http",
      actor: "alice",
      name: "stickers:save",
      method: "POST",
      path: "/api/chat/stickers",
      headers: { "Idempotency-Key": "conformance-sticker-save" },
      body: {
        channel_id: "${channelId}",
        attachment_id: "${attachmentId}",
      },
      capture: { stickerId: "$.sticker.sticker_id" },
    },
    {
      kind: "http",
      actor: "alice",
      name: "stickers:save:replay",
      method: "POST",
      path: "/api/chat/stickers",
      headers: { "Idempotency-Key": "conformance-sticker-save" },
      body: {
        channel_id: "${channelId}",
        attachment_id: "${attachmentId}",
      },
    },
    {
      kind: "http",
      actor: "alice",
      name: "stickers:save:conflict",
      method: "POST",
      path: "/api/chat/stickers",
      headers: { "Idempotency-Key": "conformance-sticker-save" },
      body: {
        channel_id: "${channelId}",
        attachment_id: CONFLICT_ATTACHMENT_ID,
      },
    },

    // --------------------------------------------------------------- list
    {
      kind: "http",
      actor: "alice",
      name: "stickers:list:alice",
      method: "GET",
      path: "/api/chat/stickers",
      readProbe: { maxQueries: 50 },
    },
    {
      kind: "http",
      actor: "bob",
      name: "stickers:list:bob",
      method: "GET",
      path: "/api/chat/stickers",
      readProbe: { maxQueries: 50 },
    },

    // -------------------------------------------------------------- delete
    {
      kind: "http",
      actor: "bob",
      name: "stickers:delete:cross-user",
      method: "DELETE",
      path: "/api/chat/stickers/${stickerId}",
      headers: { "Idempotency-Key": "conformance-sticker-delete-bob" },
    },
    {
      kind: "http",
      actor: "alice",
      name: "stickers:delete",
      method: "DELETE",
      path: "/api/chat/stickers/${stickerId}",
      headers: { "Idempotency-Key": "conformance-sticker-delete" },
    },
    {
      kind: "http",
      actor: "alice",
      name: "stickers:delete:replay",
      method: "DELETE",
      path: "/api/chat/stickers/${stickerId}",
      headers: { "Idempotency-Key": "conformance-sticker-delete" },
    },
    {
      kind: "http",
      actor: "alice",
      name: "stickers:list:after-delete",
      method: "GET",
      path: "/api/chat/stickers",
      readProbe: { maxQueries: 50 },
    },

    // ------------------------------------------------------------- revive
    {
      kind: "http",
      actor: "alice",
      name: "stickers:save:revive",
      method: "POST",
      path: "/api/chat/stickers",
      headers: { "Idempotency-Key": "conformance-sticker-resave" },
      body: {
        channel_id: "${channelId}",
        attachment_id: "${attachmentId}",
      },
      capture: { stickerIdRevived: "$.sticker.sticker_id" },
    },
    {
      kind: "http",
      actor: "alice",
      name: "stickers:list:after-revive",
      method: "GET",
      path: "/api/chat/stickers",
      readProbe: { maxQueries: 50 },
    },
  ],
};
