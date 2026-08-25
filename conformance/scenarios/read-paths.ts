/**
 * Conformance scenario: contract READ endpoints (issue #27 batch A).
 *
 * Covers the read surface that bootstrap-send-fanout does not exercise,
 * around a deterministic write fixture (one channel, one message):
 *
 *   * GET /bootstrap                 (§2.7) — empty + post-state
 *   * GET /channels                  (§5.2)  — empty + post-state, two users
 *   * GET /channels/directory        (§5.6)  — empty (private channel)
 *   * GET /channels/{id}             (§5.2b) — member detail + non-member gate
 *   * GET /channels/{id}/members     (§7.1)  — list + single-member read
 *   * GET /invites/{code}            (§5.8/§5.10) — preview, member + stranger
 *   * GET /channels/{id}/messages    (§6.1)  — empty + after message.send
 *   * GET /channels/{id}/messages/{id}/context  (§6.6)
 *   * GET /channels/{id}/events      (§6.1b) — empty + after message.send
 *   * GET /stickers                  (§8.3)  — empty personal library
 *
 * Every read step carries a readProbe (§7.5): reads must be read-only with
 * a bounded query count on both targets.
 *
 * Deterministic inputs only: fixed actors, fixed command_id, fixed titles.
 * Server-minted ids/timestamps are normalized before diffing.
 */

import type { Scenario } from "../src/types.js";

export const ALICE_USER_ID = "6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e6f";
export const BOB_USER_ID = "6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e70";

const LIVE_START_CMD = "0199c0aa-3311-7000-8000-0000000000a1";
const MESSAGE_SEND_CMD = "0199c0aa-3322-7000-8000-0000000000a2";

export const readPaths: Scenario = {
  name: "read-paths",
  description:
    "Read-surface conformance (issue #27 A): bootstrap/channels/directory/detail/members/invite-preview/messages/context/events/stickers, empty + post-state, all read-probed.",
  actors: {
    alice: { userId: ALICE_USER_ID },
    bob: { userId: BOB_USER_ID },
  },
  steps: [
    // ------------------------------------------------------------- empty
    {
      kind: "http",
      actor: "alice",
      name: "bootstrap:empty",
      method: "GET",
      path: "/api/chat/bootstrap",
      readProbe: { maxQueries: 50 },
    },
    {
      kind: "http",
      actor: "alice",
      name: "channels:list:empty",
      method: "GET",
      path: "/api/chat/channels",
      readProbe: { maxQueries: 50 },
    },
    {
      kind: "http",
      actor: "alice",
      name: "channels:directory:empty",
      method: "GET",
      path: "/api/chat/channels/directory",
      readProbe: { maxQueries: 50 },
    },
    {
      kind: "http",
      actor: "alice",
      name: "stickers:list:empty",
      method: "GET",
      path: "/api/chat/stickers",
      readProbe: { maxQueries: 50 },
    },

    // ------------------------------------------------ fixture: channel
    {
      kind: "http",
      actor: "alice",
      name: "channels:create",
      method: "POST",
      path: "/api/chat/channels",
      headers: { "Idempotency-Key": "conformance-readpaths-channel" },
      body: {
        title: "Read Paths Channel",
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
      // The old Worker projects membership into UserDirectory via
      // outbox+alarm; poll until the channel is listed. Only the final
      // response is captured, so attempt counts never diff.
      retryUntil: (res, ctx) => {
        const channelId = ctx.vars.get("channelId");
        if (typeof res.body !== "object" || res.body === null) return false;
        const items = (res.body as { items?: Array<{ channel_id?: string }> }).items ?? [];
        return items.some((it) => it.channel_id === channelId);
      },
      maxAttempts: 40,
    },

    // ------------------------------------------------- reads: membership
    {
      kind: "http",
      actor: "alice",
      name: "channels:list:post",
      method: "GET",
      path: "/api/chat/channels",
      readProbe: { maxQueries: 50 },
    },
    {
      kind: "http",
      actor: "alice",
      name: "channels:detail",
      method: "GET",
      path: "/api/chat/channels/${channelId}",
      readProbe: { maxQueries: 50 },
    },
    {
      kind: "http",
      actor: "bob",
      name: "channels:detail:non-member",
      method: "GET",
      path: "/api/chat/channels/${channelId}",
      readProbe: { maxQueries: 50 },
    },
    {
      kind: "http",
      actor: "alice",
      name: "members:list",
      method: "GET",
      path: "/api/chat/channels/${channelId}/members",
      readProbe: { maxQueries: 50 },
    },
    {
      kind: "http",
      actor: "alice",
      name: "members:show",
      method: "GET",
      // alice is a member; ${channelId} is runner-interpolated at runtime.
      path: "/api/chat/channels/${channelId}/members/" + ALICE_USER_ID,
      readProbe: { maxQueries: 50 },
    },
    {
      kind: "http",
      actor: "alice",
      name: "invites:create",
      method: "POST",
      path: "/api/chat/channels/${channelId}/invites",
      headers: { "Idempotency-Key": "conformance-readpaths-invite" },
      body: {},
      // Contract §5.8: flat response { invite_code, invite_url, expires_at, max_uses }
      capture: { inviteCode: "$.invite_code" },
    },
    {
      kind: "http",
      actor: "alice",
      name: "invites:preview:member",
      method: "GET",
      path: "/api/chat/invites/${inviteCode}",
      readProbe: { maxQueries: 50 },
    },
    {
      kind: "http",
      actor: "bob",
      name: "invites:preview:stranger",
      method: "GET",
      path: "/api/chat/invites/${inviteCode}",
      readProbe: { maxQueries: 50 },
    },

    // ------------------------------------------------ reads: empty channel
    {
      kind: "http",
      actor: "alice",
      name: "messages:list:empty",
      method: "GET",
      path: "/api/chat/channels/${channelId}/messages",
      readProbe: { maxQueries: 50 },
    },
    {
      kind: "http",
      actor: "alice",
      name: "events:channel:empty",
      method: "GET",
      path: "/api/chat/channels/${channelId}/events",
      readProbe: { maxQueries: 50 },
    },

    // --------------------------------------------- fixture: one message
    { kind: "ws.connect", actor: "alice", name: "ws:connect" },
    {
      kind: "ws.command",
      actor: "alice",
      name: "ws:live_start",
      frame: {
        frame_type: "command",
        command: "session.live_start",
        command_id: LIVE_START_CMD,
        payload: {},
      },
      waitFor: (frame) => {
        const f = frame as { frame_type?: string; command_id?: string };
        return f.frame_type === "command_ack" && f.command_id === LIVE_START_CMD;
      },
    },
    {
      kind: "wait",
      actor: "alice",
      name: "sync:fanout-lease-grace",
      ms: 1000,
    },
    {
      kind: "ws.command",
      actor: "alice",
      name: "ws:message_send",
      frame: {
        frame_type: "command",
        command: "message.send",
        command_id: MESSAGE_SEND_CMD,
        channel_id: "${channelId}",
        payload: {
          type: "text",
          text: "read paths conformance",
          reply_to_message_id: null,
          attachment_ids: [],
          mentions: [],
        },
      },
      waitFor: (frame) => {
        const f = frame as { frame_type?: string; command_id?: string };
        return f.frame_type === "command_ack" && f.command_id === MESSAGE_SEND_CMD;
      },
      alsoUntil: (frame, ctx) => {
        const f = frame as { frame_type?: string; type?: string; channel_id?: string };
        return (
          f.frame_type === "event" &&
          f.type === "message.created" &&
          f.channel_id === ctx.vars.get("channelId")
        );
      },
      waitTimeoutMs: 15_000,
    },
    {
      kind: "http",
      actor: "alice",
      name: "messages:list:post",
      method: "GET",
      path: "/api/chat/channels/${channelId}/messages",
      readProbe: { maxQueries: 50 },
      // Contract §6.1: { items: [...], next_cursor } — newest page; the
      // single message we sent is the first (and only) item.
      capture: { messageId: "$.items.0.message_id" },
    },

    // ------------------------------------------- reads: post-message state
    {
      kind: "http",
      actor: "alice",
      name: "messages:context",
      method: "GET",
      path: "/api/chat/channels/${channelId}/messages/${messageId}/context",
      readProbe: { maxQueries: 50 },
    },
    {
      kind: "http",
      actor: "alice",
      name: "events:channel:post",
      method: "GET",
      path: "/api/chat/channels/${channelId}/events",
      readProbe: { maxQueries: 50 },
    },
    {
      kind: "http",
      actor: "alice",
      name: "bootstrap:post",
      method: "GET",
      path: "/api/chat/bootstrap?channel_id=${channelId}",
      readProbe: { maxQueries: 50 },
    },
    {
      kind: "http",
      actor: "bob",
      name: "channels:list:stranger",
      method: "GET",
      path: "/api/chat/channels",
      readProbe: { maxQueries: 50 },
    },
    { kind: "ws.close", actor: "alice", name: "ws:close" },
  ],
};
