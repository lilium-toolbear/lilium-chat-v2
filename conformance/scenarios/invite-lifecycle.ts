/**
 * Conformance scenario: invites (issue #27 batch B, contract §5.8 / §5.9 /
 * §5.10).
 *
 * One fresh private channel (alice only), then the personal-invite
 * lifecycle:
 *
 *   * POST .../invites (§5.8) — default create, refresh with `max_uses: 1`
 *     (same deterministic personal code — the upsert/un-revoke branch),
 *     refresh with a 1-second TTL.
 *   * GET  /invites/{code} (§5.10) — preview as an active member
 *     (`my_membership.status = "active"` + channel_id), as a stranger
 *     (`not_joined` + null), and the post-accept preview.
 *   * POST /invites/{code}/accept (§5.9) — bob's fresh accept (member row +
 *     member.joined join_source "invite" with inviter), idempotent replay,
 *     already-active no-op (invite NOT consumed), then:
 *     * removal of bob + accept with `max_uses: 1` / `used_count: 1` →
 *       409 INVITE_NOT_AVAILABLE "invite max uses exceeded"
 *     * expired invite → 404 INVITE_NOT_FOUND (accept: "invite not found";
 *       preview: "invite expired or revoked")
 *     * wrong code → 404 INVITE_NOT_FOUND "invite not found" (preview and
 *       accept)
 *
 * Invite codes are deterministic (SHA-256 personal code), so the preview /
 * accept steps reuse the captured code. `invite_url` (base + code) is
 * normalized in conformance/src/normalize.ts (§5.8).
 *
 * Deterministic inputs only: fixed actors, fixed Idempotency-Keys, one
 * short wait for the 1-second TTL.
 */

import type { Scenario } from "../src/types.js";
import { ALICE_USER_ID, BOB_USER_ID } from "./read-paths.js";

const KEY_CREATE = "conformance-invites-create";
const KEY_INVITE_DEFAULT = "conformance-invites-default";
const KEY_INVITE_MAX1 = "conformance-invites-max1";
const KEY_INVITE_TTL = "conformance-invites-ttl";
const KEY_ACCEPT_BOB = "conformance-invites-accept-bob";
const KEY_ACCEPT_BOB_AGAIN = "conformance-invites-accept-bob-again";
const KEY_ACCEPT_BOB_MAXUSES = "conformance-invites-accept-bob-maxuses";
const KEY_ACCEPT_BOB_EXPIRED = "conformance-invites-accept-bob-expired";
const KEY_ACCEPT_WRONG = "conformance-invites-accept-wrong";
const KEY_REMOVE_BOB = "conformance-invites-remove-bob";

const WRONG_CODE = "00000000deadbeef"; // 16-hex, never minted

export const inviteLifecycle: Scenario = {
  name: "invite-lifecycle",
  description:
    "Invites (issue #27 B): create/refresh (personal deterministic code, un-revoke upsert), §5.10 preview (active / not_joined / expired / wrong-code), §5.9 accept (fresh + replay + already-active no-op), INVITE_NOT_AVAILABLE (max_uses), expired/wrong-code INVITE_NOT_FOUND, member.joined join_source=invite frame.",
  actors: {
    alice: { userId: ALICE_USER_ID },
    bob: { userId: BOB_USER_ID },
  },
  steps: [
    // ----------------------------------------------------------- fixture
    {
      kind: "http",
      actor: "alice",
      name: "channels:create",
      method: "POST",
      path: "/api/chat/channels",
      headers: { "Idempotency-Key": KEY_CREATE },
      body: {
        title: "Invite Lifecycle",
        topic: null,
        avatar_attachment_id: null,
        visibility: "private",
        initial_members: [],
      },
      capture: { inviteChannel: "$.channel.channel_id" },
    },

    // ---------------------------------------------------------- create
    // Default invite (expires_in_seconds 604800, max_uses null).
    {
      kind: "http",
      actor: "alice",
      name: "invites:create:default",
      method: "POST",
      path: "/api/chat/channels/${inviteChannel}/invites",
      headers: { "Idempotency-Key": KEY_INVITE_DEFAULT },
      body: {},
      capture: { inviteCode: "$.invite_code" },
    },
    // Refresh: max_uses 1 on the SAME personal code (upsert branch).
    {
      kind: "http",
      actor: "alice",
      name: "invites:create:refresh:max1",
      method: "POST",
      path: "/api/chat/channels/${inviteChannel}/invites",
      headers: { "Idempotency-Key": KEY_INVITE_MAX1 },
      body: { max_uses: 1 },
    },

    // -------------------------------------------------------- previews
    // Active-member preview: my_membership active + channel_id.
    {
      kind: "http",
      actor: "alice",
      name: "invites:preview:member",
      method: "GET",
      path: "/api/chat/invites/${inviteCode}",
      readProbe: { maxQueries: 50 },
    },
    // Stranger preview: my_membership not_joined + null channel_id.
    {
      kind: "http",
      actor: "bob",
      name: "invites:preview:stranger",
      method: "GET",
      path: "/api/chat/invites/${inviteCode}",
      readProbe: { maxQueries: 50 },
    },

    // ---------------------------------------------------------- accept
    // Bob's fresh accept: member row + member.joined (join_source invite).
    {
      kind: "http",
      actor: "bob",
      name: "invites:accept:bob",
      method: "POST",
      path: "/api/chat/invites/${inviteCode}/accept",
      headers: { "Idempotency-Key": KEY_ACCEPT_BOB },
      body: {},
    },
    // Idempotent replay (cached response).
    {
      kind: "http",
      actor: "bob",
      name: "invites:accept:bob:replay",
      method: "POST",
      path: "/api/chat/invites/${inviteCode}/accept",
      headers: { "Idempotency-Key": KEY_ACCEPT_BOB },
      body: {},
    },
    // Already-active no-op: the invite is NOT consumed (used_count stays 1).
    {
      kind: "http",
      actor: "bob",
      name: "invites:accept:bob:already-active",
      method: "POST",
      path: "/api/chat/invites/${inviteCode}/accept",
      headers: { "Idempotency-Key": KEY_ACCEPT_BOB_AGAIN },
      body: {},
    },
    // Post-accept preview: bob now sees himself as active.
    {
      kind: "http",
      actor: "bob",
      name: "invites:preview:post-accept",
      method: "GET",
      path: "/api/chat/invites/${inviteCode}",
      readProbe: { maxQueries: 50 },
    },

    // ------------------------------------------------- max_uses pin
    // Remove bob (his row goes to status left, used_count stays 1).
    {
      kind: "http",
      actor: "alice",
      name: "members:remove:bob",
      method: "DELETE",
      path: "/api/chat/channels/${inviteChannel}/members/" + BOB_USER_ID,
      headers: { "Idempotency-Key": KEY_REMOVE_BOB },
    },
    // Re-accept with max_uses=1 / used_count=1 → 409 INVITE_NOT_AVAILABLE.
    {
      kind: "http",
      actor: "bob",
      name: "invites:accept:bob:max-uses",
      method: "POST",
      path: "/api/chat/invites/${inviteCode}/accept",
      headers: { "Idempotency-Key": KEY_ACCEPT_BOB_MAXUSES },
      body: {},
    },

    // ------------------------------------------------- expiry pin
    // Refresh the same code with a 1-second TTL (max_uses back to null).
    {
      kind: "http",
      actor: "alice",
      name: "invites:create:refresh:short-ttl",
      method: "POST",
      path: "/api/chat/channels/${inviteChannel}/invites",
      headers: { "Idempotency-Key": KEY_INVITE_TTL },
      body: { expires_in_seconds: 1 },
    },
    // Let the 1-second TTL lapse.
    { kind: "wait", actor: "alice", ms: 1500, name: "wait:ttl" },
    // Expired accept → 404 INVITE_NOT_FOUND ("invite not found").
    {
      kind: "http",
      actor: "bob",
      name: "invites:accept:bob:expired",
      method: "POST",
      path: "/api/chat/invites/${inviteCode}/accept",
      headers: { "Idempotency-Key": KEY_ACCEPT_BOB_EXPIRED },
      body: {},
    },
    // Expired preview → 404 INVITE_NOT_FOUND ("invite expired or revoked").
    {
      kind: "http",
      actor: "alice",
      name: "invites:preview:expired",
      method: "GET",
      path: "/api/chat/invites/${inviteCode}",
      readProbe: { maxQueries: 50 },
    },

    // ------------------------------------------------- wrong-code pins
    // Preview an unknown code.
    {
      kind: "http",
      actor: "bob",
      name: "invites:preview:wrong-code",
      method: "GET",
      path: "/api/chat/invites/" + WRONG_CODE,
      readProbe: { maxQueries: 50 },
    },
    // Accept an unknown code.
    {
      kind: "http",
      actor: "bob",
      name: "invites:accept:wrong-code",
      method: "POST",
      path: "/api/chat/invites/" + WRONG_CODE + "/accept",
      headers: { "Idempotency-Key": KEY_ACCEPT_WRONG },
      body: {},
    },

    // --------------------------------------------------- read surface
    // bob is left: the list holds only alice.
    {
      kind: "http",
      actor: "alice",
      name: "members:list:post",
      method: "GET",
      path: "/api/chat/channels/${inviteChannel}/members",
      readProbe: { maxQueries: 50 },
    },
    // Left row stays readable (status left, role preserved).
    {
      kind: "http",
      actor: "alice",
      name: "members:show:bob:left",
      method: "GET",
      path: "/api/chat/channels/${inviteChannel}/members/" + BOB_USER_ID,
      readProbe: { maxQueries: 50 },
    },
    // Event frames: channel.created + member.joined (alice) +
    // member.joined (bob, join_source invite, inviter alice).
    {
      kind: "http",
      actor: "alice",
      name: "events:post",
      method: "GET",
      path: "/api/chat/channels/${inviteChannel}/events",
      readProbe: { maxQueries: 50 },
    },
  ],
};
