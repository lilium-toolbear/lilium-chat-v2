/**
 * Conformance scenario: DM open / pair reuse / DM-only behaviors (issue #27
 * batch B, contract §5.2c).
 *
 *   * POST /dms (§5.2c) — get-or-create pair semantics:
 *     - alice opens a DM with bob (fresh pair)
 *     - idempotent replay (same key + body → cached response)
 *     - bob opens the SAME pair (new key, reverse direction) → the SAME
 *       `channel_id` (pair uniqueness, A↔B), his `dm_peer` is alice and the
 *       DM title/avatar resolve to alice's profile
 *     - a second pair (bob ↔ carol) for the multi-channel list projection
 *   * error pins:
 *     - missing `recipient_user_id` → 422 INVALID_DM_TARGET
 *       "recipient_user_id required"
 *     - self-DM → 422 INVALID_DM_TARGET "cannot open DM with yourself"
 *     - unknown recipient → 404 DM_TARGET_NOT_FOUND "recipient user not found"
 *     - key reuse with a different recipient → 409 IDEMPOTENCY_CONFLICT
 *   * DM-only behaviors (§5.2c):
 *     - member ops on a DM → 409 UNSUPPORTED_CHANNEL_KIND "operation not
 *       supported for DM channels"
 *     - `GET .../commands` → empty manifest `{ version: 0, items: [] }`
 *   * read-state projections:
 *     - GET /channels (dm_peer resolution for every listed DM, list rows for
 *       a user with multiple DMs)
 *     - GET /channels/{id} detail (DM detail: dm_peer + peer title/avatar)
 *     - GET /channels/{id}/members (DM members: both participants, role
 *       member)
 *     - GET .../events (DM lifecycle frames)
 *     - GET /bootstrap (channels[] + active_channel for the DM)
 *
 * Deterministic inputs only: fixed actors, fixed Idempotency-Keys, one
 * retry-until-settled step for the Worker's projection-lagged user channel
 * list.
 */

import type { Scenario } from "../src/types.js";
import { ALICE_USER_ID, BOB_USER_ID } from "./read-paths.js";

const CAROL_USER_ID = "6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e80";
const GHOST_USER_ID = "6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5f99"; // valid UUID, never seeded

const KEY_OPEN_AB = "conformance-dm-open-ab";
const KEY_OPEN_BA = "conformance-dm-open-ba";
const KEY_OPEN_SELF = "conformance-dm-open-self";
const KEY_OPEN_MISSING = "conformance-dm-open-missing";
const KEY_OPEN_GHOST = "conformance-dm-open-ghost";
const KEY_OPEN_CONFLICT = "conformance-dm-open-ab"; // same key as KEY_OPEN_AB, different recipient
const KEY_OPEN_BC = "conformance-dm-open-bc";
const KEY_DM_MEMBER_ADD = "conformance-dm-member-add";

export const dmOpen: Scenario = {
  name: "dm-open",
  description:
    "DM open (issue #27 B): pair get-or-create (A↔B same channel_id, reverse direction), dm_peer projection (list + detail + bootstrap), DM-only behaviors (409 UNSUPPORTED_CHANNEL_KIND on member ops, empty commands manifest), error pins (INVALID_DM_TARGET ×2, DM_TARGET_NOT_FOUND, IDEMPOTENCY_CONFLICT).",
  actors: {
    alice: { userId: ALICE_USER_ID },
    bob: { userId: BOB_USER_ID },
    carol: { userId: CAROL_USER_ID },
  },
  steps: [
    // --------------------------------------------------------- pair open
    // alice opens the DM with bob (fresh pair).
    {
      kind: "http",
      actor: "alice",
      name: "dms:open:alice-to-bob",
      method: "POST",
      path: "/api/chat/dms",
      headers: { "Idempotency-Key": KEY_OPEN_AB },
      body: { recipient_user_id: BOB_USER_ID },
      capture: { dmAb: "$.channel.channel_id" },
    },
    // Idempotent replay: same key + same body → the recorded response.
    {
      kind: "http",
      actor: "alice",
      name: "dms:open:replay",
      method: "POST",
      path: "/api/chat/dms",
      headers: { "Idempotency-Key": KEY_OPEN_AB },
      body: { recipient_user_id: BOB_USER_ID },
    },
    // bob opens the SAME pair (reverse direction, new key) → the SAME
    // channel: his response's dm_peer is alice, the title resolves to
    // alice's display name.
    {
      kind: "http",
      actor: "bob",
      name: "dms:open:bob-to-alice",
      method: "POST",
      path: "/api/chat/dms",
      headers: { "Idempotency-Key": KEY_OPEN_BA },
      body: { recipient_user_id: ALICE_USER_ID },
    },

    // ------------------------------------------------------- error pins
    // Missing recipient_user_id.
    {
      kind: "http",
      actor: "alice",
      name: "dms:open:missing-recipient",
      method: "POST",
      path: "/api/chat/dms",
      headers: { "Idempotency-Key": KEY_OPEN_MISSING },
      body: {},
    },
    // Self-DM.
    {
      kind: "http",
      actor: "alice",
      name: "dms:open:self",
      method: "POST",
      path: "/api/chat/dms",
      headers: { "Idempotency-Key": KEY_OPEN_SELF },
      body: { recipient_user_id: ALICE_USER_ID },
    },
    // Unknown recipient.
    {
      kind: "http",
      actor: "alice",
      name: "dms:open:ghost",
      method: "POST",
      path: "/api/chat/dms",
      headers: { "Idempotency-Key": KEY_OPEN_GHOST },
      body: { recipient_user_id: GHOST_USER_ID },
    },
    // Key reuse with a DIFFERENT recipient → IDEMPOTENCY_CONFLICT (409).
    {
      kind: "http",
      actor: "alice",
      name: "dms:open:conflict",
      method: "POST",
      path: "/api/chat/dms",
      headers: { "Idempotency-Key": KEY_OPEN_CONFLICT },
      body: { recipient_user_id: GHOST_USER_ID },
    },

    // ----------------------------------------------- second pair (carol)
    {
      kind: "http",
      actor: "bob",
      name: "dms:open:bob-to-carol",
      method: "POST",
      path: "/api/chat/dms",
      headers: { "Idempotency-Key": KEY_OPEN_BC },
      body: { recipient_user_id: CAROL_USER_ID },
      capture: { dmBc: "$.channel.channel_id" },
    },
    // Worker: the user channel list is outbox+alarm fed — poll until both of
    // bob's DMs are listed. Only the final response is captured.
    {
      kind: "http",
      actor: "bob",
      name: "sync:dm-listed",
      method: "GET",
      path: "/api/chat/channels",
      retryUntil: (res, ctx) => {
        if (typeof res.body !== "object" || res.body === null) return false;
        const items = (res.body as { items?: Array<{ channel_id?: string }> }).items ?? [];
        const ab = ctx.vars.get("dmAb");
        const bc = ctx.vars.get("dmBc");
        return (
          items.some((it) => it.channel_id === ab) && items.some((it) => it.channel_id === bc)
        );
      },
      maxAttempts: 40,
    },
    {
      kind: "http",
      actor: "bob",
      name: "channels:list:bob",
      method: "GET",
      path: "/api/chat/channels",
      readProbe: { maxQueries: 50 },
    },
    {
      kind: "http",
      actor: "alice",
      name: "channels:list:alice",
      method: "GET",
      path: "/api/chat/channels",
      readProbe: { maxQueries: 50 },
    },

    // --------------------------------------------------- DM-only gates
    // Member ops on a DM channel → UNSUPPORTED_CHANNEL_KIND (409).
    {
      kind: "http",
      actor: "alice",
      name: "members:add:dm-gate",
      method: "POST",
      path: "/api/chat/channels/${dmAb}/members",
      headers: { "Idempotency-Key": KEY_DM_MEMBER_ADD },
      body: { user_id: CAROL_USER_ID, role: "member" },
    },
    // The DM commands manifest is always the empty manifest (§5.2c exception).
    {
      kind: "http",
      actor: "alice",
      name: "commands:dm-manifest",
      method: "GET",
      path: "/api/chat/channels/${dmAb}/commands",
      readProbe: { maxQueries: 50 },
    },

    // --------------------------------------------------- read surface
    // DM detail (bob's view): dm_peer is alice, title = alice's name.
    {
      kind: "http",
      actor: "bob",
      name: "channels:detail:dm:bob-view",
      method: "GET",
      path: "/api/chat/channels/${dmAb}",
      readProbe: { maxQueries: 50 },
    },
    // DM members: both participants, role member, keyset order.
    {
      kind: "http",
      actor: "alice",
      name: "members:list:dm",
      method: "GET",
      path: "/api/chat/channels/${dmAb}/members",
      readProbe: { maxQueries: 50 },
    },
    // DM lifecycle event frames.
    {
      kind: "http",
      actor: "alice",
      name: "events:dm",
      method: "GET",
      path: "/api/chat/channels/${dmAb}/events",
      readProbe: { maxQueries: 50 },
    },
    // Bootstrap: channels[] carries the DM summary (dm_peer), and
    // active_channel is the DM detail shape.
    {
      kind: "http",
      actor: "alice",
      name: "bootstrap:dm",
      method: "GET",
      path: "/api/chat/bootstrap?channel_id=${dmAb}",
      readProbe: { maxQueries: 50 },
    },
  ],
};
