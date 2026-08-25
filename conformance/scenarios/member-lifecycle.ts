/**
 * Conformance scenario: member management (issue #27 batch B, contract
 * §7.1 / §7.1b / §7.2 / §7.3 / §7.4 / §7.5).
 *
 * One fresh private channel (alice = owner only), then the full member
 * state machine driven against it:
 *
 *   * POST   .../members            (§7.2) — fresh add (admin_add), no-op
 *     re-add, role-change-via-add pin (P0-5), add-self / add-owner pins,
 *     FORBIDDEN (member caller), MEMBER_NOT_FOUND-style re-add after leave
 *   * PATCH  .../members/{user_id}  (§7.3) — promote / demote, missing role,
 *     owner-role pin, self-role pin, FORBIDDEN (non-owner caller),
 *     MEMBER_NOT_FOUND target
 *   * DELETE .../members/{user_id}  (§7.4) — owner-remove, self-leave,
 *     re-remove pin (MEMBER_NOT_FOUND)
 *   * POST   .../owner-transfer     (§7.5) — FORBIDDEN (non-owner), non-member
 *     target, invalid previous_owner_role, successful atomic transfer
 *     (mv +2, two member.role_updated events), idempotent replay
 *
 * After every mutation the scenario verifies the read surface:
 *   * GET .../members          (§7.1) — role-ordered active-member list
 *   * GET .../members/{user_id} (§7.1b) — status active → left (left_at
 *     readable), role / joined_at preserved
 *   * GET .../events           (§6.1b) — member.joined (join_source
 *     admin_add) / member.role_updated / member.left (leave_source self vs
 *     removed) frames with membership_version schedule
 *
 * Deterministic inputs only: fixed actors (alice/bob/carol), fixed
 * Idempotency-Keys. Server-minted ids/timestamps are normalized.
 */

import type { Scenario } from "../src/types.js";
import { ALICE_USER_ID, BOB_USER_ID } from "./read-paths.js";

export const CAROL_USER_ID = "6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e80";
const GHOST_USER_ID = "6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5f99"; // valid UUID, never seeded

const KEY_CREATE = "conformance-members-create";
const KEY_ADD_BOB = "conformance-members-add-bob";
const KEY_ADD_BOB_ROLE = "conformance-members-add-bob-role";
const KEY_ADD_BOB_AGAIN = "conformance-members-add-bob-again";
const KEY_ADD_SELF = "conformance-members-add-self";
const KEY_ADD_BY_MEMBER = "conformance-members-add-by-member";
const KEY_ADD_CAROL = "conformance-members-add-carol";
const KEY_ROLE_BOB_ADMIN = "conformance-members-role-bob-admin";
const KEY_ROLE_BOB_MEMBER = "conformance-members-role-bob-member";
const KEY_ROLE_MISSING = "conformance-members-role-missing";
const KEY_ROLE_OWNER = "conformance-members-role-owner";
const KEY_ROLE_BY_NONOWNER = "conformance-members-role-by-nonowner";
const KEY_ROLE_GHOST = "conformance-members-role-ghost";
const KEY_REMOVE_BOB = "conformance-members-remove-bob";
const KEY_REMOVE_BOB_AGAIN = "conformance-members-remove-bob-again";
const KEY_LEAVE_BOB = "conformance-members-leave-bob";
const KEY_READD_BOB = "conformance-members-readd-bob";
const KEY_REMOVE_CAROL = "conformance-members-remove-carol";
const KEY_XFER_BY_MEMBER = "conformance-members-xfer-by-member";
const KEY_XFER_NONMEMBER = "conformance-members-xfer-nonmember";
const KEY_XFER_BADROLE = "conformance-members-xfer-badrole";
const KEY_XFER = "conformance-members-xfer";

export const memberLifecycle: Scenario = {
  name: "member-lifecycle",
  description:
    "Member management (issue #27 B): add/role-change/remove/self-leave/owner-transfer with membership_version schedule, member.joined/member.left/member.role_updated event frames, §7.1 list + §7.1b status reads, and error pins (FORBIDDEN / INVALID_MESSAGE / MEMBER_NOT_FOUND / CHANNEL_NOT_FOUND).",
  actors: {
    alice: { userId: ALICE_USER_ID },
    bob: { userId: BOB_USER_ID },
    carol: { userId: CAROL_USER_ID },
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
        title: "Members Lifecycle",
        topic: null,
        avatar_attachment_id: null,
        visibility: "private",
        initial_members: [],
      },
      capture: { channelId: "$.channel.channel_id" },
    },
    // The members reads gate on ChatChannel membership directly (no
    // projection lag), so no sync step is needed for the member surface.

    // ------------------------------------------------------ baseline reads
    {
      kind: "http",
      actor: "alice",
      name: "members:list:initial",
      method: "GET",
      path: "/api/chat/channels/${channelId}/members",
      readProbe: { maxQueries: 50 },
    },
    {
      kind: "http",
      actor: "alice",
      name: "members:show:self",
      method: "GET",
      path: "/api/chat/channels/${channelId}/members/" + ALICE_USER_ID,
      readProbe: { maxQueries: 50 },
    },
    {
      kind: "http",
      actor: "alice",
      name: "members:show:never-joined",
      method: "GET",
      path: "/api/chat/channels/${channelId}/members/" + BOB_USER_ID,
      readProbe: { maxQueries: 50 },
    },
    {
      kind: "http",
      actor: "bob",
      name: "members:list:non-member-viewer",
      method: "GET",
      path: "/api/chat/channels/${channelId}/members",
      readProbe: { maxQueries: 50 },
    },
    {
      kind: "http",
      actor: "alice",
      name: "members:list:channel-not-found",
      method: "GET",
      path: "/api/chat/channels/" + GHOST_USER_ID + "/members",
      readProbe: { maxQueries: 50 },
    },

    // ------------------------------------------------------------- add
    // Fresh add (bob, role member) — admin_add source.
    {
      kind: "http",
      actor: "alice",
      name: "members:add:bob",
      method: "POST",
      path: "/api/chat/channels/${channelId}/members",
      headers: { "Idempotency-Key": KEY_ADD_BOB },
      body: { user_id: BOB_USER_ID, role: "member" },
    },
    // Idempotent replay of the add.
    {
      kind: "http",
      actor: "alice",
      name: "members:add:bob:replay",
      method: "POST",
      path: "/api/chat/channels/${channelId}/members",
      headers: { "Idempotency-Key": KEY_ADD_BOB },
      body: { user_id: BOB_USER_ID, role: "member" },
    },
    // Active member + SAME role → idempotent no-op (no state change).
    {
      kind: "http",
      actor: "alice",
      name: "members:add:bob:noop",
      method: "POST",
      path: "/api/chat/channels/${channelId}/members",
      headers: { "Idempotency-Key": KEY_ADD_BOB_AGAIN },
      body: { user_id: BOB_USER_ID, role: "member" },
    },
    // Active member + DIFFERENT role → pin: use PATCH (P0-5).
    {
      kind: "http",
      actor: "alice",
      name: "members:add:bob:role-change-pin",
      method: "POST",
      path: "/api/chat/channels/${channelId}/members",
      headers: { "Idempotency-Key": KEY_ADD_BOB_ROLE },
      body: { user_id: BOB_USER_ID, role: "admin" },
    },
    // Add self → INVALID_MESSAGE.
    {
      kind: "http",
      actor: "alice",
      name: "members:add:self",
      method: "POST",
      path: "/api/chat/channels/${channelId}/members",
      headers: { "Idempotency-Key": KEY_ADD_SELF },
      body: { user_id: ALICE_USER_ID, role: "member" },
    },
    // Plain member caller → FORBIDDEN.
    {
      kind: "http",
      actor: "bob",
      name: "members:add:by-member",
      method: "POST",
      path: "/api/chat/channels/${channelId}/members",
      headers: { "Idempotency-Key": KEY_ADD_BY_MEMBER },
      body: { user_id: CAROL_USER_ID, role: "member" },
    },

    // -------------------------------------------------------- reads: post-add
    {
      kind: "http",
      actor: "alice",
      name: "members:list:post-add",
      method: "GET",
      path: "/api/chat/channels/${channelId}/members",
      readProbe: { maxQueries: 50 },
    },
    {
      kind: "http",
      actor: "bob",
      name: "members:show:bob:active",
      method: "GET",
      path: "/api/chat/channels/${channelId}/members/" + BOB_USER_ID,
      readProbe: { maxQueries: 50 },
    },

    // ------------------------------------------------------------- role
    // Promote bob to admin.
    {
      kind: "http",
      actor: "alice",
      name: "members:role:bob:promote",
      method: "PATCH",
      path: "/api/chat/channels/${channelId}/members/" + BOB_USER_ID,
      headers: { "Idempotency-Key": KEY_ROLE_BOB_ADMIN },
      body: { role: "admin" },
    },
    // Demote bob back to member.
    {
      kind: "http",
      actor: "alice",
      name: "members:role:bob:demote",
      method: "PATCH",
      path: "/api/chat/channels/${channelId}/members/" + BOB_USER_ID,
      headers: { "Idempotency-Key": KEY_ROLE_BOB_MEMBER },
      body: { role: "member" },
    },
    // Missing role → INVALID_MESSAGE.
    {
      kind: "http",
      actor: "alice",
      name: "members:role:missing-role",
      method: "PATCH",
      path: "/api/chat/channels/${channelId}/members/" + BOB_USER_ID,
      headers: { "Idempotency-Key": KEY_ROLE_MISSING },
      body: {},
    },
    // Owner role is fixed → INVALID_MESSAGE.
    {
      kind: "http",
      actor: "alice",
      name: "members:role:owner-pin",
      method: "PATCH",
      path: "/api/chat/channels/${channelId}/members/" + ALICE_USER_ID,
      headers: { "Idempotency-Key": KEY_ROLE_OWNER },
      body: { role: "admin" },
    },
    // Non-owner caller → FORBIDDEN.
    {
      kind: "http",
      actor: "bob",
      name: "members:role:by-nonowner",
      method: "PATCH",
      path: "/api/chat/channels/${channelId}/members/" + BOB_USER_ID,
      headers: { "Idempotency-Key": KEY_ROLE_BY_NONOWNER },
      body: { role: "admin" },
    },
    // Target never joined → MEMBER_NOT_FOUND.
    {
      kind: "http",
      actor: "alice",
      name: "members:role:never-joined",
      method: "PATCH",
      path: "/api/chat/channels/${channelId}/members/" + GHOST_USER_ID,
      headers: { "Idempotency-Key": KEY_ROLE_GHOST },
      body: { role: "member" },
    },

    // ------------------------------------------------------------- add 2
    // Fresh add of a SECOND user with admin role (carol).
    {
      kind: "http",
      actor: "alice",
      name: "members:add:carol:admin",
      method: "POST",
      path: "/api/chat/channels/${channelId}/members",
      headers: { "Idempotency-Key": KEY_ADD_CAROL },
      body: { user_id: CAROL_USER_ID, role: "admin" },
    },
    {
      kind: "http",
      actor: "alice",
      name: "members:list:post-second-add",
      method: "GET",
      path: "/api/chat/channels/${channelId}/members",
      readProbe: { maxQueries: 50 },
    },

    // ----------------------------------------------------------- remove
    // Owner removes bob → leave_source "removed".
    {
      kind: "http",
      actor: "alice",
      name: "members:remove:bob",
      method: "DELETE",
      path: "/api/chat/channels/${channelId}/members/" + BOB_USER_ID,
      headers: { "Idempotency-Key": KEY_REMOVE_BOB },
    },
    {
      kind: "http",
      actor: "alice",
      name: "members:show:bob:left",
      method: "GET",
      path: "/api/chat/channels/${channelId}/members/" + BOB_USER_ID,
      readProbe: { maxQueries: 50 },
    },
    {
      kind: "http",
      actor: "alice",
      name: "members:list:post-remove",
      method: "GET",
      path: "/api/chat/channels/${channelId}/members",
      readProbe: { maxQueries: 50 },
    },
    // Re-remove a left member → MEMBER_NOT_FOUND (row is not active).
    {
      kind: "http",
      actor: "alice",
      name: "members:remove:bob:again",
      method: "DELETE",
      path: "/api/chat/channels/${channelId}/members/" + BOB_USER_ID,
      headers: { "Idempotency-Key": KEY_REMOVE_BOB_AGAIN },
    },
    // Self-leave (bob leaves his own membership) → leave_source "self".
    {
      kind: "http",
      actor: "carol",
      name: "members:remove:carol:by-admin",
      method: "DELETE",
      path: "/api/chat/channels/${channelId}/members/" + CAROL_USER_ID,
      headers: { "Idempotency-Key": KEY_REMOVE_CAROL },
    },
    {
      kind: "http",
      actor: "alice",
      name: "members:list:post-cleanup",
      method: "GET",
      path: "/api/chat/channels/${channelId}/members",
      readProbe: { maxQueries: 50 },
    },

    // ---------------------------------------------- reactivation (re-add)
    // Re-adding a LEFT member reactivates the row (fresh joined_at, count +1).
    {
      kind: "http",
      actor: "alice",
      name: "members:add:bob:reactivate",
      method: "POST",
      path: "/api/chat/channels/${channelId}/members",
      headers: { "Idempotency-Key": KEY_READD_BOB },
      body: { user_id: BOB_USER_ID, role: "member" },
    },
    {
      kind: "http",
      actor: "alice",
      name: "members:show:bob:reactivated",
      method: "GET",
      path: "/api/chat/channels/${channelId}/members/" + BOB_USER_ID,
      readProbe: { maxQueries: 50 },
    },

    // ---------------------------------------------------- owner-transfer
    // Non-owner caller → FORBIDDEN.
    {
      kind: "http",
      actor: "bob",
      name: "owner-transfer:by-member",
      method: "POST",
      path: "/api/chat/channels/${channelId}/owner-transfer",
      headers: { "Idempotency-Key": KEY_XFER_BY_MEMBER },
      body: { target_user_id: BOB_USER_ID, previous_owner_role: "admin" },
    },
    // Target never joined → MEMBER_NOT_FOUND.
    {
      kind: "http",
      actor: "alice",
      name: "owner-transfer:non-member-target",
      method: "POST",
      path: "/api/chat/channels/${channelId}/owner-transfer",
      headers: { "Idempotency-Key": KEY_XFER_NONMEMBER },
      body: { target_user_id: GHOST_USER_ID, previous_owner_role: "admin" },
    },
    // Invalid previous_owner_role → INVALID_MESSAGE.
    {
      kind: "http",
      actor: "alice",
      name: "owner-transfer:bad-previous-role",
      method: "POST",
      path: "/api/chat/channels/${channelId}/owner-transfer",
      headers: { "Idempotency-Key": KEY_XFER_BADROLE },
      body: { target_user_id: BOB_USER_ID, previous_owner_role: "owner" },
    },
    // Successful atomic transfer: alice (owner) → bob (owner), alice → admin.
    {
      kind: "http",
      actor: "alice",
      name: "owner-transfer",
      method: "POST",
      path: "/api/chat/channels/${channelId}/owner-transfer",
      headers: { "Idempotency-Key": KEY_XFER },
      body: { target_user_id: BOB_USER_ID, previous_owner_role: "admin" },
    },
    // Idempotent replay of the transfer.
    {
      kind: "http",
      actor: "alice",
      name: "owner-transfer:replay",
      method: "POST",
      path: "/api/chat/channels/${channelId}/owner-transfer",
      headers: { "Idempotency-Key": KEY_XFER },
      body: { target_user_id: BOB_USER_ID, previous_owner_role: "admin" },
    },

    // -------------------------------------------- reads: post-transfer
    {
      kind: "http",
      actor: "alice",
      name: "members:list:post-transfer",
      method: "GET",
      path: "/api/chat/channels/${channelId}/members",
      readProbe: { maxQueries: 50 },
    },
    {
      kind: "http",
      actor: "alice",
      name: "members:show:alice:demoted",
      method: "GET",
      path: "/api/chat/channels/${channelId}/members/" + ALICE_USER_ID,
      readProbe: { maxQueries: 50 },
    },
    {
      kind: "http",
      actor: "bob",
      name: "members:show:bob:owner",
      method: "GET",
      path: "/api/chat/channels/${channelId}/members/" + BOB_USER_ID,
      readProbe: { maxQueries: 50 },
    },
    {
      kind: "http",
      actor: "bob",
      name: "events:full",
      method: "GET",
      path: "/api/chat/channels/${channelId}/events",
      readProbe: { maxQueries: 50 },
    },
  ],
};
