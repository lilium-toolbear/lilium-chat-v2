/**
 * Conformance scenario: public join + kind/visibility gates (issue #27
 * batch B, contract §5.7).
 *
 * alice creates three fresh channels (public_listed / private /
 * public_unlisted). bob (non-member) then exercises the join endpoint:
 *
 *   * public_listed: fresh join (join_source "public"), idempotent replay,
 *     already-active no-op (role preserved)
 *   * private / public_unlisted: 403 FORBIDDEN "channel is not publicly
 *     joinable" (visibility gate, non-members only)
 *   * DM channel: 409 UNSUPPORTED_CHANNEL_KIND "operation not supported
 *     for DM channels" (kind gate runs before visibility / membership)
 *   * dissolved channel: 409 CHANNEL_DISSOLVED "channel is dissolved"
 *   * missing channel: 404 CHANNEL_NOT_FOUND
 *
 * Read surface after the joins: member list / single-member read, event
 * frames (channel.created + member.joined public + channel.dissolved), and
 * the post-dissolve detail read (dissolved channels stay readable to
 * members, §5.4).
 *
 * Deterministic inputs only: fixed actors, fixed Idempotency-Keys, a
 * retry-until-settled step for the Worker's projection-lagged user channel
 * list.
 */

import type { Scenario } from "../src/types.js";
import { ALICE_USER_ID, BOB_USER_ID } from "./read-paths.js";

const KEY_CREATE_PUBLIC = "conformance-join-create-public";
const KEY_CREATE_PRIVATE = "conformance-join-create-private";
const KEY_CREATE_UNLISTED = "conformance-join-create-unlisted";
const KEY_JOIN_PUBLIC = "conformance-join-public";
const KEY_JOIN_PUBLIC_AGAIN = "conformance-join-public-again";
const KEY_JOIN_PRIVATE = "conformance-join-private";
const KEY_JOIN_UNLISTED = "conformance-join-unlisted";
const KEY_DM_OPEN = "conformance-join-dm";
const KEY_JOIN_DM = "conformance-join-dm-gate";
const KEY_JOIN_DISSOLVED = "conformance-join-dissolved";
const KEY_JOIN_GHOST = "conformance-join-ghost";
const KEY_DISSOLVE = "conformance-join-dissolve";

const GHOST_CHANNEL_ID = "6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5f99"; // valid UUID, never created

export const publicJoin: Scenario = {
  name: "public-join",
  description:
    "Public join + gates (issue #27 B): non-member join of public_listed (fresh/replay/already-active), visibility gate 403 (private, public_unlisted), DM kind gate 409 UNSUPPORTED_CHANNEL_KIND, dissolved 409, missing 404, member.joined join_source=public frames, post-dissolve readable detail.",
  actors: {
    alice: { userId: ALICE_USER_ID },
    bob: { userId: BOB_USER_ID },
  },
  steps: [
    // ----------------------------------------------------------- fixtures
    {
      kind: "http",
      actor: "alice",
      name: "channels:create:public",
      method: "POST",
      path: "/api/chat/channels",
      headers: { "Idempotency-Key": KEY_CREATE_PUBLIC },
      body: {
        title: "Joinable Public",
        topic: null,
        avatar_attachment_id: null,
        visibility: "public_listed",
        initial_members: [],
      },
      capture: { joinChannel: "$.channel.channel_id" },
    },
    {
      kind: "http",
      actor: "alice",
      name: "channels:create:private",
      method: "POST",
      path: "/api/chat/channels",
      headers: { "Idempotency-Key": KEY_CREATE_PRIVATE },
      body: {
        title: "Join Gate Private",
        topic: null,
        avatar_attachment_id: null,
        visibility: "private",
        initial_members: [],
      },
      capture: { gatePrivate: "$.channel.channel_id" },
    },
    {
      kind: "http",
      actor: "alice",
      name: "channels:create:unlisted",
      method: "POST",
      path: "/api/chat/channels",
      headers: { "Idempotency-Key": KEY_CREATE_UNLISTED },
      body: {
        title: "Join Gate Unlisted",
        topic: null,
        avatar_attachment_id: null,
        visibility: "public_unlisted",
        initial_members: [],
      },
      capture: { gateUnlisted: "$.channel.channel_id" },
    },
    // Worker: the user channel list is an outbox + alarm fed projection —
    // wait until all three rows are settled before the probe reads.
    {
      kind: "http",
      actor: "alice",
      name: "sync:channels-projected",
      method: "GET",
      path: "/api/chat/channels",
      retryUntil: (res, ctx) => {
        if (typeof res.body !== "object" || res.body === null) return false;
        const items = (res.body as { items?: Array<{ channel_id?: string }> }).items ?? [];
        const join = ctx.vars.get("joinChannel");
        const gatePrivate = ctx.vars.get("gatePrivate");
        const gateUnlisted = ctx.vars.get("gateUnlisted");
        return (
          items.some((it) => it.channel_id === join) &&
          items.some((it) => it.channel_id === gatePrivate) &&
          items.some((it) => it.channel_id === gateUnlisted)
        );
      },
      maxAttempts: 40,
    },
    {
      kind: "http",
      actor: "alice",
      name: "channels:list:post",
      method: "GET",
      path: "/api/chat/channels",
      readProbe: { maxQueries: 50 },
    },
    // Only the public_listed channel is discoverable (§5.6).
    {
      kind: "http",
      actor: "alice",
      name: "directory:post",
      method: "GET",
      path: "/api/chat/channels/directory",
      readProbe: { maxQueries: 50 },
    },

    // ------------------------------------------------------- public join
    // bob joins the public channel (fresh, join_source "public").
    {
      kind: "http",
      actor: "bob",
      name: "join:bob:public",
      method: "POST",
      path: "/api/chat/channels/${joinChannel}/join",
      headers: { "Idempotency-Key": KEY_JOIN_PUBLIC },
      body: {},
    },
    // Idempotent replay of the join.
    {
      kind: "http",
      actor: "bob",
      name: "join:bob:public:replay",
      method: "POST",
      path: "/api/chat/channels/${joinChannel}/join",
      headers: { "Idempotency-Key": KEY_JOIN_PUBLIC },
      body: {},
    },
    // Already-active no-op (existing role returned, no state change).
    {
      kind: "http",
      actor: "bob",
      name: "join:bob:public:again",
      method: "POST",
      path: "/api/chat/channels/${joinChannel}/join",
      headers: { "Idempotency-Key": KEY_JOIN_PUBLIC_AGAIN },
      body: {},
    },

    // ------------------------------------------------- visibility gates
    // private channel is not publicly joinable.
    {
      kind: "http",
      actor: "bob",
      name: "join:bob:private-gate",
      method: "POST",
      path: "/api/chat/channels/${gatePrivate}/join",
      headers: { "Idempotency-Key": KEY_JOIN_PRIVATE },
      body: {},
    },
    // public_unlisted is not publicly joinable either.
    {
      kind: "http",
      actor: "bob",
      name: "join:bob:unlisted-gate",
      method: "POST",
      path: "/api/chat/channels/${gateUnlisted}/join",
      headers: { "Idempotency-Key": KEY_JOIN_UNLISTED },
      body: {},
    },

    // ------------------------------------------------------ DM kind gate
    // alice opens a DM with bob (both become active DM members).
    {
      kind: "http",
      actor: "alice",
      name: "dms:open:for-gate",
      method: "POST",
      path: "/api/chat/dms",
      headers: { "Idempotency-Key": KEY_DM_OPEN },
      body: { recipient_user_id: BOB_USER_ID },
      capture: { dmChannel: "$.channel.channel_id" },
    },
    // Joining a DM channel hits the kind gate.
    {
      kind: "http",
      actor: "bob",
      name: "join:bob:dm-gate",
      method: "POST",
      path: "/api/chat/channels/${dmChannel}/join",
      headers: { "Idempotency-Key": KEY_JOIN_DM },
      body: {},
    },

    // -------------------------------------------------- dissolved gate
    // alice dissolves the public channel (she is owner).
    {
      kind: "http",
      actor: "alice",
      name: "channels:dissolve",
      method: "POST",
      path: "/api/chat/channels/${joinChannel}/dissolve",
      headers: { "Idempotency-Key": KEY_DISSOLVE },
      body: {},
    },
    // Joining a dissolved channel → 409 CHANNEL_DISSOLVED.
    {
      kind: "http",
      actor: "bob",
      name: "join:bob:dissolved",
      method: "POST",
      path: "/api/chat/channels/${joinChannel}/join",
      headers: { "Idempotency-Key": KEY_JOIN_DISSOLVED },
      body: {},
    },
    // Joining a missing channel → 404 CHANNEL_NOT_FOUND.
    {
      kind: "http",
      actor: "bob",
      name: "join:bob:not-found",
      method: "POST",
      path: "/api/chat/channels/" + GHOST_CHANNEL_ID + "/join",
      headers: { "Idempotency-Key": KEY_JOIN_GHOST },
      body: {},
    },

    // --------------------------------------------------- read surface
    {
      kind: "http",
      actor: "alice",
      name: "members:list:post",
      method: "GET",
      path: "/api/chat/channels/${joinChannel}/members",
      readProbe: { maxQueries: 50 },
    },
    {
      kind: "http",
      actor: "alice",
      name: "members:show:bob",
      method: "GET",
      path: "/api/chat/channels/${joinChannel}/members/" + BOB_USER_ID,
      readProbe: { maxQueries: 50 },
    },
    // channel.created + member.joined (alice) + member.joined (bob,
    // join_source public) + channel.dissolved.
    {
      kind: "http",
      actor: "alice",
      name: "events:post",
      method: "GET",
      path: "/api/chat/channels/${joinChannel}/events",
      readProbe: { maxQueries: 50 },
    },
    // Dissolved channels stay readable to members (§5.4).
    {
      kind: "http",
      actor: "bob",
      name: "channels:detail:bob:post-dissolve",
      method: "GET",
      path: "/api/chat/channels/${joinChannel}",
      readProbe: { maxQueries: 50 },
    },
  ],
};
