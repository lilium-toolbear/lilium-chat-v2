/**
 * Conformance scenario: channel lifecycle create → update → dissolve
 * (issue #27 batch B, contract §5.2b / §5.3 / §5.4 / §5.6 / §7.1).
 *
 * Covers the full non-DM channel lifecycle on two channels:
 *
 *   * POST /channels            (§5.2b) — private channel WITH initial_members
 *     (bob as admin) + a public_listed channel; idempotent replay of the
 *     create key; IDEMPOTENCY_CONFLICT on key reuse with a different body
 *   * PATCH /channels/{id}      (§5.3)  — multi-field update (title + topic),
 *     single-field visibility change, empty-body no-op, FORBIDDEN (non-member),
 *     INVALID_MESSAGE (bad visibility)
 *   * POST /channels/{id}/dissolve (§5.4) — FORBIDDEN (non-owner), dissolve,
 *     idempotent replay, post-dissolve writes → CHANNEL_DISSOLVED
 *   * read-state projections after each mutation:
 *       - GET /channels          (§5.1)  — dissolved channel still listed
 *       - GET /channels/{id}     (§5.2b) — status=active → status=dissolved
 *       - GET /channels/directory (§5.6) — only public_listed channels
 *       - GET .../members        (§7.1)  — members list after lifecycle ops
 *       - GET .../events         (§6.1b) — channel.created / member.joined ×2 /
 *         channel.updated ×2 / channel.dissolved event frames (the old
 *         Worker's system.notice absence is normalized away, see normalize.ts)
 *
 * Deterministic inputs only: fixed actors, fixed Idempotency-Keys, fixed
 * titles. Server-minted ids/timestamps are normalized before diffing.
 */

import type { Scenario } from "../src/types.js";
import { ALICE_USER_ID, BOB_USER_ID } from "./read-paths.js";

const KEY_CREATE_PRIVATE = "conformance-lifecycle-create-private";
const KEY_CREATE_PUBLIC = "conformance-lifecycle-create-public";
const KEY_CREATE_PRIVATE_CONFLICT = "conformance-lifecycle-create-private"; // same key, different body
const KEY_UPDATE_1 = "conformance-lifecycle-update-1";
const KEY_UPDATE_2 = "conformance-lifecycle-update-2";
const KEY_UPDATE_NOOP = "conformance-lifecycle-update-noop";
const KEY_UPDATE_FORBIDDEN = "conformance-lifecycle-update-forbidden";
const KEY_UPDATE_BADVIS = "conformance-lifecycle-update-badvis";
const KEY_UPDATE_POSTDISSOLVE = "conformance-lifecycle-update-postdissolve";
const KEY_DISSOLVE = "conformance-lifecycle-dissolve";
const KEY_DISSOLVE_FORBIDDEN = "conformance-lifecycle-dissolve-forbidden";
const KEY_ADD_POSTDISSOLVE = "conformance-lifecycle-add-postdissolve";

export const channelLifecycle: Scenario = {
  name: "channel-lifecycle",
  description:
    "Channel lifecycle (issue #27 B): create (with initial_members) → update → dissolve with event-frame + list/detail/directory/members read-state verification, idempotent replays, and error pins (FORBIDDEN / CHANNEL_DISSOLVED / INVALID_MESSAGE / IDEMPOTENCY_CONFLICT).",
  actors: {
    alice: { userId: ALICE_USER_ID },
    bob: { userId: BOB_USER_ID },
  },
  steps: [
    // ------------------------------------------------------------- create
    {
      kind: "http",
      actor: "alice",
      name: "channels:create:private:with-admin",
      method: "POST",
      path: "/api/chat/channels",
      headers: { "Idempotency-Key": KEY_CREATE_PRIVATE },
      body: {
        title: "Lifecycle Private",
        topic: "lifecycle private topic",
        avatar_attachment_id: null,
        visibility: "private",
        initial_members: [{ user_id: BOB_USER_ID, role: "admin" }],
      },
      capture: { privChannel: "$.channel.channel_id" },
    },
    {
      kind: "http",
      actor: "alice",
      name: "channels:create:public",
      method: "POST",
      path: "/api/chat/channels",
      headers: { "Idempotency-Key": KEY_CREATE_PUBLIC },
      body: {
        title: "Lifecycle Public",
        topic: null,
        avatar_attachment_id: null,
        visibility: "public_listed",
        initial_members: [],
      },
      capture: { pubChannel: "$.channel.channel_id" },
    },
    // Idempotent replay: same key + same body → the recorded response.
    {
      kind: "http",
      actor: "alice",
      name: "channels:create:replay",
      method: "POST",
      path: "/api/chat/channels",
      headers: { "Idempotency-Key": KEY_CREATE_PRIVATE },
      body: {
        title: "Lifecycle Private",
        topic: "lifecycle private topic",
        avatar_attachment_id: null,
        visibility: "private",
        initial_members: [{ user_id: BOB_USER_ID, role: "admin" }],
      },
    },
    // Key reuse with a DIFFERENT body → IDEMPOTENCY_CONFLICT (409).
    {
      kind: "http",
      actor: "alice",
      name: "channels:create:conflict",
      method: "POST",
      path: "/api/chat/channels",
      headers: { "Idempotency-Key": KEY_CREATE_PRIVATE_CONFLICT },
      body: {
        title: "Lifecycle Private (other body)",
        topic: "lifecycle private topic",
        avatar_attachment_id: null,
        visibility: "private",
        initial_members: [{ user_id: BOB_USER_ID, role: "admin" }],
      },
    },
    // The old Worker projects membership via outbox+alarm; poll until both
    // channels are listed. Only the final response is captured.
    {
      kind: "http",
      actor: "alice",
      name: "sync:channels-projected",
      method: "GET",
      path: "/api/chat/channels",
      retryUntil: (res, ctx) => {
        if (typeof res.body !== "object" || res.body === null) return false;
        const items = (res.body as { items?: Array<{ channel_id?: string }> }).items ?? [];
        const priv = ctx.vars.get("privChannel");
        const pub = ctx.vars.get("pubChannel");
        return items.some((it) => it.channel_id === priv) && items.some((it) => it.channel_id === pub);
      },
      maxAttempts: 40,
    },

    // ------------------------------------------------ reads: post-create
    {
      kind: "http",
      actor: "alice",
      name: "channels:list:post-create",
      method: "GET",
      path: "/api/chat/channels",
      readProbe: { maxQueries: 50 },
    },
    {
      kind: "http",
      actor: "alice",
      name: "channels:detail:private:member",
      method: "GET",
      path: "/api/chat/channels/${privChannel}",
      readProbe: { maxQueries: 50 },
    },
    {
      kind: "http",
      actor: "bob",
      name: "channels:detail:private:admin",
      method: "GET",
      path: "/api/chat/channels/${privChannel}",
      readProbe: { maxQueries: 50 },
    },
    {
      kind: "http",
      actor: "bob",
      name: "channels:detail:public:stranger",
      method: "GET",
      path: "/api/chat/channels/${pubChannel}",
      readProbe: { maxQueries: 50 },
    },
    {
      kind: "http",
      actor: "alice",
      name: "members:list:initial",
      method: "GET",
      path: "/api/chat/channels/${privChannel}/members",
      readProbe: { maxQueries: 50 },
    },
    {
      kind: "http",
      actor: "alice",
      name: "members:show:bob:initial",
      method: "GET",
      path: "/api/chat/channels/${privChannel}/members/" + BOB_USER_ID,
      readProbe: { maxQueries: 50 },
    },
    // The old Worker's public directory is outbox+alarm fed; poll until the
    // public_listed channel is listed (the Elixir directory reads PG directly
    // and settles immediately). Only the final response is captured.
    {
      kind: "http",
      actor: "alice",
      name: "sync:directory-projected",
      method: "GET",
      path: "/api/chat/channels/directory",
      retryUntil: (res, ctx) => {
        if (typeof res.body !== "object" || res.body === null) return false;
        const pub = ctx.vars.get("pubChannel");
        const items = (res.body as { items?: Array<{ channel_id?: string }> }).items ?? [];
        return items.some((it) => it.channel_id === pub);
      },
      maxAttempts: 40,
    },
    {
      kind: "http",
      actor: "alice",
      name: "directory:post-create",
      method: "GET",
      path: "/api/chat/channels/directory",
      readProbe: { maxQueries: 50 },
    },

    // ------------------------------------------------------------- update
    // Multi-field change (title + topic) → one channel.updated event.
    {
      kind: "http",
      actor: "alice",
      name: "channels:update:title-topic",
      method: "PATCH",
      path: "/api/chat/channels/${privChannel}",
      headers: { "Idempotency-Key": KEY_UPDATE_1 },
      body: { title: "Lifecycle Private v2", topic: "updated topic" },
    },
    // Single-field visibility change (private → public_unlisted).
    {
      kind: "http",
      actor: "alice",
      name: "channels:update:visibility",
      method: "PATCH",
      path: "/api/chat/channels/${privChannel}",
      headers: { "Idempotency-Key": KEY_UPDATE_2 },
      body: { visibility: "public_unlisted" },
    },
    // Empty body → no-op: no event, updated_at unchanged (current state echo).
    {
      kind: "http",
      actor: "alice",
      name: "channels:update:noop",
      method: "PATCH",
      path: "/api/chat/channels/${privChannel}",
      headers: { "Idempotency-Key": KEY_UPDATE_NOOP },
      body: {},
    },
    // bob is not a member of the public channel → FORBIDDEN (403).
    {
      kind: "http",
      actor: "bob",
      name: "channels:update:forbidden",
      method: "PATCH",
      path: "/api/chat/channels/${pubChannel}",
      headers: { "Idempotency-Key": KEY_UPDATE_FORBIDDEN },
      body: { title: "stolen" },
    },
    // Invalid visibility value → INVALID_MESSAGE (422).
    {
      kind: "http",
      actor: "alice",
      name: "channels:update:invalid-visibility",
      method: "PATCH",
      path: "/api/chat/channels/${pubChannel}",
      headers: { "Idempotency-Key": KEY_UPDATE_BADVIS },
      body: { visibility: "listed" },
    },

    // --------------------------------------------- reads: post-update
    {
      kind: "http",
      actor: "alice",
      name: "channels:detail:private:post-update",
      method: "GET",
      path: "/api/chat/channels/${privChannel}",
      readProbe: { maxQueries: 50 },
    },
    {
      kind: "http",
      actor: "alice",
      name: "directory:post-update",
      method: "GET",
      path: "/api/chat/channels/directory",
      readProbe: { maxQueries: 50 },
    },
    {
      kind: "http",
      actor: "alice",
      name: "events:private:post-update",
      method: "GET",
      path: "/api/chat/channels/${privChannel}/events",
      readProbe: { maxQueries: 50 },
    },

    // ----------------------------------------------------------- dissolve
    // bob is not the owner of the public channel → FORBIDDEN (403).
    {
      kind: "http",
      actor: "bob",
      name: "channels:dissolve:forbidden",
      method: "POST",
      path: "/api/chat/channels/${pubChannel}/dissolve",
      headers: { "Idempotency-Key": KEY_DISSOLVE_FORBIDDEN },
      body: {},
    },
    {
      kind: "http",
      actor: "alice",
      name: "channels:dissolve",
      method: "POST",
      path: "/api/chat/channels/${pubChannel}/dissolve",
      headers: { "Idempotency-Key": KEY_DISSOLVE },
      body: {},
    },
    // Idempotent replay of the dissolve key → same response.
    {
      kind: "http",
      actor: "alice",
      name: "channels:dissolve:replay",
      method: "POST",
      path: "/api/chat/channels/${pubChannel}/dissolve",
      headers: { "Idempotency-Key": KEY_DISSOLVE },
      body: {},
    },

    // ----------------------------------------- reads: post-dissolve state
    // Dissolved channels remain READABLE to current members (§5.4): the
    // channel list keeps the row (status="dissolved"). The old Worker
    // projects membership via outbox+alarm — poll until the row is listed
    // with the dissolved status.
    {
      kind: "http",
      actor: "alice",
      name: "channels:list:post-dissolve",
      method: "GET",
      path: "/api/chat/channels",
      retryUntil: (res, ctx) => {
        if (typeof res.body !== "object" || res.body === null) return false;
        const pub = ctx.vars.get("pubChannel");
        const items = (res.body as { items?: Array<{ channel_id?: string; status?: string }> }).items ?? [];
        const row = items.find((it) => it.channel_id === pub);
        return row !== undefined && row.status === "dissolved";
      },
      maxAttempts: 40,
    },
    {
      kind: "http",
      actor: "alice",
      name: "channels:detail:post-dissolve",
      method: "GET",
      path: "/api/chat/channels/${pubChannel}",
      readProbe: { maxQueries: 50 },
    },
    {
      kind: "http",
      actor: "alice",
      name: "members:list:post-dissolve",
      method: "GET",
      path: "/api/chat/channels/${pubChannel}/members",
      readProbe: { maxQueries: 50 },
    },
    {
      kind: "http",
      actor: "alice",
      name: "events:public:post-dissolve",
      method: "GET",
      path: "/api/chat/channels/${pubChannel}/events",
      readProbe: { maxQueries: 50 },
    },

    // ------------------------------------------------ post-dissolve gates
    // Writes to a dissolved channel → CHANNEL_DISSOLVED (409).
    {
      kind: "http",
      actor: "alice",
      name: "channels:update:post-dissolve",
      method: "PATCH",
      path: "/api/chat/channels/${pubChannel}",
      headers: { "Idempotency-Key": KEY_UPDATE_POSTDISSOLVE },
      body: { title: "late title" },
    },
    {
      kind: "http",
      actor: "alice",
      name: "members:add:post-dissolve",
      method: "POST",
      path: "/api/chat/channels/${pubChannel}/members",
      headers: { "Idempotency-Key": KEY_ADD_POSTDISSOLVE },
      body: { user_id: BOB_USER_ID, role: "member" },
    },
  ],
};
