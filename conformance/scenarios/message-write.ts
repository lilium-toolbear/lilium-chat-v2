/**
 * Conformance scenario: browser WS write path (issue #27 batch C).
 *
 * The write surface around one deterministic channel (alice = owner, bob =
 * admin via initial_members, carol = non-member → member):
 *
 *   * message.send   (§6.2) — full payload surface: text, reply_to,
 *     mentions, attachments (real presign → S3 PUT → finalize flow, §8.1/§8.2);
 *     committed ack with the message projection + `message.created` fanout;
 *     idempotency: command_id replay (same body → cached ack) and conflict
 *     (same command_id, different body → IDEMPOTENCY_CONFLICT); parse gates
 *     (text-with-attachments); membership gate (non-member →
 *     CHANNEL_NOT_FOUND "channel not found or not a member"); dissolved
 *     channel gate (CHANNEL_DISSOLVED).
 *   * message.edit / message.recall / message.delete (§6.3–§6.5) — ack
 *     mutation payload (status edited / recalled / deleted, tombstone
 *     projections) + `message.updated` / `message.recalled` /
 *     `message.deleted` fanout; owner/role gates (not sender →
 *     MESSAGE_NOT_EDITABLE; non-admin delete → FORBIDDEN); admin delete of a
 *     foreign message (the Elixir-only `system.notice` fanout is normalized
 *     away, see normalize.ts).
 *   * channel.mark_read (§5.5) — ack `{channel_id, last_read_event_id,
 *     unread_count}` (NO event_id, NO message projection, NO timeline
 *     event); monotonic cursor (older cursor → stored value returned);
 *     non-member gate (FORBIDDEN "not an active member"); missing cursor /
 *     missing channel_id gates; `read_state_updated` broadcast to the user's
 *     OTHER live sessions (second alice socket).
 *   * channel.pin_message / channel.unpin_message (§6.7) — owner/admin gate
 *     (PIN_FORBIDDEN), pin ack `{channel_id, event_id, pin}` +
 *     `channel.pin.set` fanout, no-op re-pin (existing `last_pin_event_id`,
 *     no new event), source edit → `channel.pin.updated`, unpin ack
 *     `{channel_id, event_id}` + `channel.pin.cleared`, PIN_NOT_FOUND on
 *     second unpin, INVALID_MESSAGE (exactly one locator),
 *     PIN_SOURCE_INVALID (deleted source); `channel_pins` read projection on
 *     BOTH the channel detail (§5.2) and bootstrap (§4.1) while a pin is
 *     active.
 *
 * Read-surface verification (every write re-checked on the read side):
 * GET .../messages (§6.1, tombstones filtered), GET .../messages/{id}/context
 * (§6.6), GET .../events (§6.1b — full event replay incl. pin frames),
 * GET /bootstrap (§4.1 — channel summaries `last_read_event_id` +
 * `unread_count`, active-channel messages), GET /channels/{id} (§5.2 —
 * channel_pins).
 *
 * Deterministic inputs only: fixed actors, fixed command_id /
 * Idempotency-Key literals, fixed texts. Server-minted ids/timestamps are
 * normalized before diffing.
 */

import type { Scenario } from "../src/types.js";
import { ALICE_USER_ID, BOB_USER_ID } from "./read-paths.js";

export const CAROL_USER_ID = "6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e80";

/** 12345 deterministic bytes (contract §8.1 example size_bytes). */
const IMAGE_SIZE = 12_345;
const IMAGE_BYTES = Buffer.alloc(IMAGE_SIZE);
for (let i = 0; i < IMAGE_SIZE; i++) IMAGE_BYTES[i] = i % 256;
const IMAGE_B64 = IMAGE_BYTES.toString("base64");

/** Signed headers the presign mandates (contract §8.1 upload_headers). */
const UPLOAD_HEADERS = {
  "Content-Type": "image/png",
  "Cache-Control": "public, max-age=31536000, immutable",
};

const PRESIGN_BODY = {
  filename: "conformance-write.png",
  mime_type: "image/png",
  size_bytes: IMAGE_SIZE,
  width: 64,
  height: 48,
  blurhash: null,
};

// ---------------------------------------------------------------- constants

const KEY_CREATE_MAIN = "conformance-mw-main";
const KEY_CREATE_DISSOLVE = "conformance-mw-dissolve-ch";
const KEY_DISSOLVE = "conformance-mw-dissolve";
const KEY_ADD_CAROL = "conformance-mw-add-carol";
const KEY_PRESIGN = "conformance-mw-presign";
const KEY_FINALIZE = "conformance-mw-finalize";

const CMD_LIVE_ALICE = "0199d1c1-0100-7000-8000-0000000000a1";
const CMD_LIVE_BOB = "0199d1c1-0100-7000-8000-0000000000a2";
const CMD_LIVE_CAROL = "0199d1c1-0100-7000-8000-0000000000a3";
const CMD_LIVE_ALICE2 = "0199d1c1-0100-7000-8000-0000000000a4";
// Carol's SECOND live_start (after she joins main): her first lease
// registered zero channels, so without a re-live the two targets fan out
// differently to her socket post-join (old Worker picks up the new
// membership; the v2 PubSub subscription is fixed at live_start time).
// Re-living makes her subscription deterministic on BOTH sides.
const CMD_LIVE_CAROL2 = "0199d1c1-0100-7000-8000-0000000000a5";

const CMD_SEND_M1 = "0199d1c1-0200-7000-8000-0000000000b1";
const CMD_SEND_M2 = "0199d1c1-0200-7000-8000-0000000000b2";
const CMD_SEND_M3 = "0199d1c1-0200-7000-8000-0000000000b3";
const CMD_SEND_M4 = "0199d1c1-0200-7000-8000-0000000000b4";
const CMD_SEND_M5 = "0199d1c1-0200-7000-8000-0000000000b5";
const CMD_SEND_M6 = "0199d1c1-0200-7000-8000-0000000000b6";
const CMD_SEND_CAROL_NONMEMBER = "0199d1c1-0200-7000-8000-0000000000b7";
const CMD_SEND_M7 = "0199d1c1-0200-7000-8000-0000000000b8";
const CMD_SEND_TEXT_WITH_ATTACH = "0199d1c1-0200-7000-8000-0000000000b9";
const CMD_SEND_DISSOLVED = "0199d1c1-0900-7000-8000-0000000000j1";
const CMD_SEND_REPLAY = CMD_SEND_M1; // same command_id + same body → cached
const CMD_SEND_CONFLICT = CMD_SEND_M1; // same command_id + different body → 409

const CMD_EDIT_M1 = "0199d1c1-0300-7000-8000-0000000000c1";
const CMD_EDIT_M4 = "0199d1c1-0300-7000-8000-0000000000c2";
const CMD_EDIT_M1_RECALLED = "0199d1c1-0300-7000-8000-0000000000c3";
const CMD_EDIT_M3_BOB = "0199d1c1-0300-7000-8000-0000000000c4";

const CMD_RECALL_M1 = "0199d1c1-0400-7000-8000-0000000000d1";
const CMD_RECALL_M2_ALICE = "0199d1c1-0400-7000-8000-0000000000d2";
const CMD_RECALL_M3_BOB = "0199d1c1-0400-7000-8000-0000000000d3";

const CMD_DELETE_M3_BOB = "0199d1c1-0500-7000-8000-0000000000e1";
const CMD_DELETE_M4_CAROL = "0199d1c1-0500-7000-8000-0000000000e2";
const CMD_DELETE_M7_CAROL = "0199d1c1-0500-7000-8000-0000000000e3";

const CMD_PIN_M4 = "0199d1c1-0600-7000-8000-0000000000f1";
const CMD_PIN_M4_NOREPIN = "0199d1c1-0600-7000-8000-0000000000f2";
const CMD_PIN_M4_CAROL = "0199d1c1-0600-7000-8000-0000000000f3";
const CMD_PIN_M3_DELETED = "0199d1c1-0600-7000-8000-0000000000f4";
const CMD_UNPIN_1 = "0199d1c1-0700-7000-8000-0000000000g1";
const CMD_UNPIN_AGAIN = "0199d1c1-0700-7000-8000-0000000000g2";
const CMD_UNPIN_NORELOC = "0199d1c1-0700-7000-8000-0000000000g3";

const CMD_MR_MISSING_CURSOR = "0199d1c1-0800-7000-8000-0000000000h1";
const CMD_MR_MISSING_CHANNEL = "0199d1c1-0800-7000-8000-0000000000h2";
const CMD_MR_CAROL_NONMEMBER = "0199d1c1-0800-7000-8000-0000000000h3";
const CMD_MR_1 = "0199d1c1-0800-7000-8000-0000000000h4";
const CMD_MR_2 = "0199d1c1-0800-7000-8000-0000000000h5";
const CMD_MR_3 = "0199d1c1-0800-7000-8000-0000000000h6";
const CMD_MR_CAROL_1 = "0199d1c1-0800-7000-8000-0000000000h7";

/**
 * A cursor OLDER than any server-minted UUIDv7 event id (the "0000…" time
 * prefix sorts before the ~2026 generation prefix), so the first mark_read
 * always advances and the stored value is echoed back verbatim — a
 * scenario-deterministic literal (not normalized) that both targets must
 * return byte-identically.
 */
const MR_OLD_CURSOR = "00000000-0000-7000-8000-000000000001";

// ------------------------------------------------------------------ helpers

const isRec = (v: unknown): v is Record<string, unknown> =>
  typeof v === "object" && v !== null;

const ack = (command: string, commandId: string) => (f: unknown): boolean =>
  isRec(f) && f.frame_type === "command_ack" && f.command === command && f.command_id === commandId;

const cmdErr = (commandId: string) => (f: unknown): boolean =>
  isRec(f) && f.frame_type === "command_error" && f.command_id === commandId;

const ev = (type: string) => (f: unknown): boolean =>
  isRec(f) && f.frame_type === "event" && f.type === type;

const sendFrame = (
  commandId: string,
  channelId: string,
  payload: Record<string, unknown>,
) => ({
  frame_type: "command",
  command: "message.send",
  command_id: commandId,
  channel_id: channelId,
  payload,
});

const listChannelInItems = (res: { body: unknown }, channelId: unknown): boolean => {
  if (typeof res.body !== "object" || res.body === null) return false;
  const items = (res.body as { items?: Array<{ channel_id?: string }> }).items ?? [];
  return items.some((it) => it.channel_id === channelId);
};

export const messageWrite: Scenario = {
  name: "message-write",
  description:
    "Browser WS write path (issue #27 C): message.send (text/reply/mentions/attachments + idempotency + gates), message.edit/recall/delete (role gates + tombstones), channel.mark_read (monotonic cursor + read_state_updated hint), channel.pin/unpin (pin lifecycle + channel_pins projection), all re-verified on the read surface (messages/context/events/bootstrap/detail).",
  actors: {
    alice: { userId: ALICE_USER_ID },
    bob: { userId: BOB_USER_ID },
    carol: { userId: CAROL_USER_ID },
    alice2: { userId: ALICE_USER_ID },
  },
  steps: [
    // --------------------------------------------------- fixture: channels
    {
      kind: "http",
      actor: "alice",
      name: "channels:create:main",
      method: "POST",
      path: "/api/chat/channels",
      headers: { "Idempotency-Key": KEY_CREATE_MAIN },
      body: {
        title: "Write Main",
        topic: "batch C write path",
        avatar_attachment_id: null,
        visibility: "private",
        initial_members: [{ user_id: BOB_USER_ID, role: "admin" }],
      },
      capture: { main: "$.channel.channel_id" },
    },
    {
      kind: "http",
      actor: "alice",
      name: "channels:create:dissolve",
      method: "POST",
      path: "/api/chat/channels",
      headers: { "Idempotency-Key": KEY_CREATE_DISSOLVE },
      body: {
        title: "Write Dissolve",
        topic: null,
        avatar_attachment_id: null,
        visibility: "private",
        initial_members: [],
      },
      capture: { dissolveCh: "$.channel.channel_id" },
    },
    {
      kind: "http",
      actor: "alice",
      name: "sync:alice:list",
      method: "GET",
      path: "/api/chat/channels",
      // The old Worker projects membership via outbox+alarm — poll until the
      // channel is listed for alice (also proves the UserDirectory my_channels
      // row that channel.mark_read requires). Only the final response is
      // captured, so attempt counts never diff.
      retryUntil: (res, ctx) => listChannelInItems(res, ctx.vars.get("main")),
      maxAttempts: 40,
    },
    {
      kind: "http",
      actor: "bob",
      name: "sync:bob:list",
      method: "GET",
      path: "/api/chat/channels",
      retryUntil: (res, ctx) => listChannelInItems(res, ctx.vars.get("main")),
      maxAttempts: 40,
    },

    // ------------------------------------------- fixture: attachment (S3)
    {
      kind: "http",
      actor: "alice",
      name: "uploads:presign",
      method: "POST",
      path: "/api/chat/uploads/images/presign",
      headers: { "Idempotency-Key": KEY_PRESIGN },
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
      headers: { "Idempotency-Key": KEY_FINALIZE },
      body: { etag: "conformance-mw-etag" },
      capture: {
        attachmentUrl: "$.attachment.url",
      },
    },

    // --------------------------------------------------- sockets + live
    { kind: "ws.connect", actor: "alice", name: "ws:connect:alice" },
    { kind: "ws.connect", actor: "bob", name: "ws:connect:bob" },
    { kind: "ws.connect", actor: "carol", name: "ws:connect:carol" },
    { kind: "ws.connect", actor: "alice2", name: "ws:connect:alice2" },
    {
      kind: "ws.command",
      actor: "alice",
      name: "ws:live_start:alice",
      frame: {
        frame_type: "command",
        command: "session.live_start",
        command_id: CMD_LIVE_ALICE,
        payload: {},
      },
      waitFor: (f) => ack("session.live_start", CMD_LIVE_ALICE)(f),
    },
    {
      kind: "ws.command",
      actor: "bob",
      name: "ws:live_start:bob",
      frame: {
        frame_type: "command",
        command: "session.live_start",
        command_id: CMD_LIVE_BOB,
        payload: {},
      },
      waitFor: (f) => ack("session.live_start", CMD_LIVE_BOB)(f),
    },
    {
      kind: "ws.command",
      actor: "carol",
      name: "ws:live_start:carol",
      frame: {
        frame_type: "command",
        command: "session.live_start",
        command_id: CMD_LIVE_CAROL,
        payload: {},
      },
      waitFor: (f) => ack("session.live_start", CMD_LIVE_CAROL)(f),
    },
    {
      kind: "ws.command",
      actor: "alice2",
      name: "ws:live_start:alice2",
      frame: {
        frame_type: "command",
        command: "session.live_start",
        command_id: CMD_LIVE_ALICE2,
        payload: {},
      },
      waitFor: (f) => ack("session.live_start", CMD_LIVE_ALICE2)(f),
    },
    {
      kind: "wait",
      actor: "alice",
      name: "sync:fanout-lease-grace",
      // Fanout leases are registered out-of-band (old Worker: outbox + DO
      // alarm; Elixir: PubSub subscription). Grace period before the first
      // fanout-producing command (batch A idiom). Not captured.
      ms: 1000,
    },

    // ------------------------------------------ gates before first writes
    {
      kind: "ws.command",
      actor: "alice",
      name: "ws:mark_read:missing-cursor",
      frame: {
        frame_type: "command",
        command: "channel.mark_read",
        command_id: CMD_MR_MISSING_CURSOR,
        channel_id: "${main}",
        payload: {},
      },
      waitFor: (f) => cmdErr(CMD_MR_MISSING_CURSOR)(f),
    },
    {
      kind: "ws.command",
      actor: "alice",
      name: "ws:mark_read:missing-channel",
      frame: {
        frame_type: "command",
        command: "channel.mark_read",
        command_id: CMD_MR_MISSING_CHANNEL,
        payload: { last_read_event_id: MR_OLD_CURSOR },
      },
      waitFor: (f) => cmdErr(CMD_MR_MISSING_CHANNEL)(f),
    },
    {
      kind: "ws.command",
      actor: "carol",
      name: "ws:mark_read:non-member",
      frame: {
        frame_type: "command",
        command: "channel.mark_read",
        command_id: CMD_MR_CAROL_NONMEMBER,
        channel_id: "${main}",
        payload: { last_read_event_id: MR_OLD_CURSOR },
      },
      waitFor: (f) => cmdErr(CMD_MR_CAROL_NONMEMBER)(f),
    },
    {
      kind: "ws.command",
      actor: "carol",
      name: "ws:send:non-member",
      frame: sendFrame(CMD_SEND_CAROL_NONMEMBER, "${main}", {
        type: "text",
        text: "carol not a member yet",
        reply_to_message_id: null,
        attachment_ids: [],
        mentions: [],
      }),
      waitFor: (f) => cmdErr(CMD_SEND_CAROL_NONMEMBER)(f),
    },

    // ------------------------------------------------- sends (m1 … m6)
    {
      kind: "ws.command",
      actor: "alice",
      name: "ws:send:m1",
      frame: sendFrame(CMD_SEND_M1, "${main}", {
        type: "text",
        text: "mw m1",
        reply_to_message_id: null,
        attachment_ids: [],
        mentions: [],
      }),
      waitFor: (f) => ack("message.send", CMD_SEND_M1)(f),
      alsoUntil: (f) => ev("message.created")(f),
    },
    { kind: "wait", actor: "alice", name: "sync:fanout:m1", ms: 750 },
    {
      kind: "http",
      actor: "alice",
      name: "messages:list:m1",
      method: "GET",
      path: "/api/chat/channels/${main}/messages",
      readProbe: { maxQueries: 50 },
      // Timeline history (contract §6.1): items[] is an ASC event timeline —
      // the channel prefix is always [channel.created, member.joined (owner),
      // member.joined (admin)] for this scenario's channel, so m1 is items[3].
      capture: { m1Id: "$.items.3.payload.message.message_id" },
    },
    {
      kind: "ws.command",
      actor: "bob",
      name: "ws:send:m2:reply:mention",
      frame: sendFrame(CMD_SEND_M2, "${main}", {
        type: "text",
        text: "mw m2 reply to m1",
        reply_to_message_id: "${m1Id}",
        attachment_ids: [],
        mentions: [{ user_id: ALICE_USER_ID, start: 0, end: 2 }],
      }),
      waitFor: (f) => ack("message.send", CMD_SEND_M2)(f),
      alsoUntil: (f) => ev("message.created")(f),
    },
    { kind: "wait", actor: "bob", name: "sync:fanout:m2", ms: 750 },
    {
      kind: "http",
      actor: "bob",
      name: "messages:list:m2",
      method: "GET",
      path: "/api/chat/channels/${main}/messages",
      readProbe: { maxQueries: 50 },
      capture: { m2Id: "$.items.4.payload.message.message_id" },
    },
    {
      kind: "ws.command",
      actor: "alice",
      name: "ws:send:m3:reply",
      frame: sendFrame(CMD_SEND_M3, "${main}", {
        type: "text",
        text: "mw m3 reply to m2",
        reply_to_message_id: "${m2Id}",
        attachment_ids: [],
        mentions: [],
      }),
      waitFor: (f) => ack("message.send", CMD_SEND_M3)(f),
      alsoUntil: (f) => ev("message.created")(f),
    },
    { kind: "wait", actor: "alice", name: "sync:fanout:m3", ms: 750 },
    {
      kind: "ws.command",
      actor: "alice",
      name: "ws:send:m4:pin-source",
      frame: sendFrame(CMD_SEND_M4, "${main}", {
        type: "text",
        text: "mw m4 pin source",
        reply_to_message_id: null,
        attachment_ids: [],
        mentions: [],
      }),
      waitFor: (f) => ack("message.send", CMD_SEND_M4)(f),
      alsoUntil: (f) => ev("message.created")(f),
    },
    { kind: "wait", actor: "alice", name: "sync:fanout:m4", ms: 750 },
    {
      kind: "ws.command",
      actor: "bob",
      name: "ws:send:m5",
      frame: sendFrame(CMD_SEND_M5, "${main}", {
        type: "text",
        text: "mw m5",
        reply_to_message_id: null,
        attachment_ids: [],
        mentions: [],
      }),
      waitFor: (f) => ack("message.send", CMD_SEND_M5)(f),
      alsoUntil: (f) => ev("message.created")(f),
    },
    { kind: "wait", actor: "bob", name: "sync:fanout:m5", ms: 750 },
    {
      kind: "ws.command",
      actor: "alice",
      name: "ws:send:m6:image",
      frame: sendFrame(CMD_SEND_M6, "${main}", {
        type: "image",
        text: null,
        reply_to_message_id: null,
        attachment_ids: ["${attachmentId}"],
        mentions: [],
      }),
      waitFor: (f) => ack("message.send", CMD_SEND_M6)(f),
      alsoUntil: (f) => ev("message.created")(f),
    },
    { kind: "wait", actor: "alice", name: "sync:fanout:m6", ms: 750 },

    // ----------------------------------------- idempotency + parse gates
    {
      kind: "ws.command",
      actor: "alice",
      name: "ws:send:replay:m1",
      // Same command_id + same body → cached committed ack (same message).
      frame: sendFrame(CMD_SEND_REPLAY, "${main}", {
        type: "text",
        text: "mw m1",
        reply_to_message_id: null,
        attachment_ids: [],
        mentions: [],
      }),
      waitFor: (f) => ack("message.send", CMD_SEND_REPLAY)(f),
    },
    { kind: "wait", actor: "alice", name: "sync:replay", ms: 500 },
    {
      kind: "ws.command",
      actor: "alice",
      name: "ws:send:conflict:m1",
      // Same command_id + DIFFERENT body → 409 IDEMPOTENCY_CONFLICT.
      frame: sendFrame(CMD_SEND_CONFLICT, "${main}", {
        type: "text",
        text: "mw m1 conflict",
        reply_to_message_id: null,
        attachment_ids: [],
        mentions: [],
      }),
      waitFor: (f) => cmdErr(CMD_SEND_CONFLICT)(f),
    },
    {
      kind: "ws.command",
      actor: "alice",
      name: "ws:send:gate:text-with-attachments",
      frame: sendFrame(CMD_SEND_TEXT_WITH_ATTACH, "${main}", {
        type: "text",
        text: "text with attachments is invalid",
        reply_to_message_id: null,
        attachment_ids: ["${attachmentId}"],
        mentions: [],
      }),
      waitFor: (f) => cmdErr(CMD_SEND_TEXT_WITH_ATTACH)(f),
    },
    { kind: "wait", actor: "alice", name: "sync:gates", ms: 500 },

    // ------------------------------------------------ read: full surface
    {
      kind: "http",
      actor: "alice",
      name: "messages:list:all",
      method: "GET",
      path: "/api/chat/channels/${main}/messages",
      readProbe: { maxQueries: 50 },
      // Timeline = [c, mj, mj, m1, m2, m3, m4, m5, m6] (9 items, ASC).
      capture: {
        m6Id: "$.items.8.payload.message.message_id",
        m5Id: "$.items.7.payload.message.message_id",
        m4Id: "$.items.6.payload.message.message_id",
        m3Id: "$.items.5.payload.message.message_id",
        m2IdAll: "$.items.4.payload.message.message_id",
        m1IdAll: "$.items.3.payload.message.message_id",
      },
    },
    {
      kind: "http",
      actor: "alice",
      name: "events:read:pre",
      method: "GET",
      path: "/api/chat/channels/${main}/events",
      readProbe: { maxQueries: 50 },
      capture: {
        latestEventId: "$.latest_event_id",
      },
    },
    {
      kind: "http",
      actor: "alice",
      name: "messages:context:m3:pre",
      method: "GET",
      path: "/api/chat/channels/${main}/messages/${m3Id}/context",
      readProbe: { maxQueries: 50 },
    },
    {
      kind: "http",
      actor: "alice",
      name: "channels:detail:pre",
      method: "GET",
      path: "/api/chat/channels/${main}",
      readProbe: { maxQueries: 50 },
    },

    // --------------------------------------------- carol joins (member)
    {
      kind: "http",
      actor: "alice",
      name: "members:add:carol",
      method: "POST",
      path: "/api/chat/channels/${main}/members",
      headers: { "Idempotency-Key": KEY_ADD_CAROL },
      body: { user_id: CAROL_USER_ID, role: "member" },
    },
    {
      kind: "http",
      actor: "carol",
      name: "sync:carol:list",
      method: "GET",
      path: "/api/chat/channels",
      // Old-Worker UserDirectory projection for carol must settle before her
      // member-gated writes (mark_read + send require her my_channels row).
      // Only the final response is captured, so attempt counts never diff.
      retryUntil: (res, ctx) => listChannelInItems(res, ctx.vars.get("main")),
      maxAttempts: 40,
    },
    {
      kind: "ws.command",
      actor: "carol",
      name: "ws:live_start:carol2",
      // Re-live now that carol is a member: her FIRST live_start registered
      // zero channels, so her fanout subscription for main must be (re)established
      // on BOTH targets before she should receive main's fanout. Ack carries
      // subscribed_channel_count=1 (main only).
      frame: {
        frame_type: "command",
        command: "session.live_start",
        command_id: CMD_LIVE_CAROL2,
        payload: {},
      },
      waitFor: (f) => ack("session.live_start", CMD_LIVE_CAROL2)(f),
    },
    { kind: "wait", actor: "carol", name: "sync:carol-lease", ms: 750 },

    // --------------------------------------- mutation gates (no state chg)
    {
      kind: "ws.command",
      actor: "bob",
      name: "ws:edit:gate:foreign",
      frame: {
        frame_type: "command",
        command: "message.edit",
        command_id: CMD_EDIT_M3_BOB,
        channel_id: "${main}",
        payload: { message_id: "${m3Id}", text: "bob tries to edit m3" },
      },
      waitFor: (f) => cmdErr(CMD_EDIT_M3_BOB)(f),
    },
    {
      kind: "ws.command",
      actor: "bob",
      name: "ws:recall:gate:foreign",
      frame: {
        frame_type: "command",
        command: "message.recall",
        command_id: CMD_RECALL_M3_BOB,
        channel_id: "${main}",
        payload: { message_id: "${m3Id}" },
      },
      waitFor: (f) => cmdErr(CMD_RECALL_M3_BOB)(f),
    },
    {
      kind: "ws.command",
      actor: "carol",
      name: "ws:delete:gate:foreign-member",
      frame: {
        frame_type: "command",
        command: "message.delete",
        command_id: CMD_DELETE_M4_CAROL,
        channel_id: "${main}",
        payload: { message_id: "${m4Id}", reason: null },
      },
      waitFor: (f) => cmdErr(CMD_DELETE_M4_CAROL)(f),
    },
    {
      kind: "ws.command",
      actor: "carol",
      name: "ws:pin:gate:member-role",
      frame: {
        frame_type: "command",
        command: "channel.pin_message",
        command_id: CMD_PIN_M4_CAROL,
        channel_id: "${main}",
        payload: { source_message_id: "${m4Id}" },
      },
      waitFor: (f) => cmdErr(CMD_PIN_M4_CAROL)(f),
    },
    { kind: "wait", actor: "alice", name: "sync:mutation-gates", ms: 500 },

    // ------------------------------------ admin delete (system.notice on v2)
    {
      kind: "ws.command",
      actor: "bob",
      name: "ws:delete:m3:admin-foreign",
      frame: {
        frame_type: "command",
        command: "message.delete",
        command_id: CMD_DELETE_M3_BOB,
        channel_id: "${main}",
        payload: { message_id: "${m3Id}", reason: "duplicate" },
      },
      waitFor: (f) => ack("message.delete", CMD_DELETE_M3_BOB)(f),
      alsoUntil: (f) => ev("message.deleted")(f),
    },
    { kind: "wait", actor: "bob", name: "sync:fanout:delete-m3", ms: 750 },
    {
      kind: "ws.command",
      actor: "alice",
      name: "ws:pin:gate:deleted-source",
      frame: {
        frame_type: "command",
        command: "channel.pin_message",
        command_id: CMD_PIN_M3_DELETED,
        channel_id: "${main}",
        payload: { source_message_id: "${m3Id}" },
      },
      waitFor: (f) => cmdErr(CMD_PIN_M3_DELETED)(f),
    },
    { kind: "wait", actor: "alice", name: "sync:pin-gate", ms: 500 },

    // ------------------------------------------------- pin lifecycle (m4)
    {
      kind: "ws.command",
      actor: "alice",
      name: "ws:pin:m4",
      frame: {
        frame_type: "command",
        command: "channel.pin_message",
        command_id: CMD_PIN_M4,
        channel_id: "${main}",
        payload: { source_message_id: "${m4Id}" },
      },
      waitFor: (f) => ack("channel.pin_message", CMD_PIN_M4)(f),
      alsoUntil: (f) => ev("channel.pin.set")(f),
    },
    { kind: "wait", actor: "alice", name: "sync:fanout:pin-set", ms: 750 },
    {
      kind: "http",
      actor: "alice",
      name: "channels:detail:pin-active",
      method: "GET",
      path: "/api/chat/channels/${main}",
      readProbe: { maxQueries: 50 },
      capture: { pinId: "$.channel_pins.0.pin_id" },
    },
    {
      kind: "http",
      actor: "alice",
      name: "bootstrap:pin-active",
      method: "GET",
      path: "/api/chat/bootstrap?channel_id=${main}",
      readProbe: { maxQueries: 50 },
    },
    {
      kind: "ws.command",
      actor: "alice",
      name: "ws:pin:m4:no-op-repin",
      // Same source, new command_id, unchanged message → NO new event; the
      // ack carries the existing pin's last_pin_event_id.
      frame: {
        frame_type: "command",
        command: "channel.pin_message",
        command_id: CMD_PIN_M4_NOREPIN,
        channel_id: "${main}",
        payload: { source_message_id: "${m4Id}" },
      },
      waitFor: (f) => ack("channel.pin_message", CMD_PIN_M4_NOREPIN)(f),
    },
    { kind: "wait", actor: "alice", name: "sync:no-op-repin", ms: 500 },
    {
      kind: "ws.command",
      actor: "alice",
      name: "ws:edit:m4:pin-sync",
      frame: {
        frame_type: "command",
        command: "message.edit",
        command_id: CMD_EDIT_M4,
        channel_id: "${main}",
        payload: { message_id: "${m4Id}", text: "mw m4 edited" },
      },
      waitFor: (f) => ack("message.edit", CMD_EDIT_M4)(f),
      // The pin lifecycle emits a SECOND frame (channel.pin.updated) after
      // message.updated; it is drained into the following sync step.
      alsoUntil: (f) => ev("message.updated")(f),
    },
    { kind: "wait", actor: "alice", name: "sync:fanout:pin-updated", ms: 750 },
    {
      kind: "http",
      actor: "alice",
      name: "channels:detail:pin-updated",
      method: "GET",
      path: "/api/chat/channels/${main}",
      readProbe: { maxQueries: 50 },
    },
    {
      kind: "ws.command",
      actor: "alice",
      name: "ws:unpin:m4",
      frame: {
        frame_type: "command",
        command: "channel.unpin_message",
        command_id: CMD_UNPIN_1,
        channel_id: "${main}",
        payload: { pin_id: "${pinId}" },
      },
      waitFor: (f) => ack("channel.unpin_message", CMD_UNPIN_1)(f),
      alsoUntil: (f) => ev("channel.pin.cleared")(f),
    },
    { kind: "wait", actor: "alice", name: "sync:fanout:pin-cleared", ms: 750 },
    {
      kind: "ws.command",
      actor: "alice",
      name: "ws:unpin:m4:again",
      frame: {
        frame_type: "command",
        command: "channel.unpin_message",
        command_id: CMD_UNPIN_AGAIN,
        channel_id: "${main}",
        payload: { pin_id: "${pinId}" },
      },
      waitFor: (f) => cmdErr(CMD_UNPIN_AGAIN)(f),
    },
    {
      kind: "ws.command",
      actor: "alice",
      name: "ws:unpin:no-locator",
      frame: {
        frame_type: "command",
        command: "channel.unpin_message",
        command_id: CMD_UNPIN_NORELOC,
        channel_id: "${main}",
        payload: {},
      },
      waitFor: (f) => cmdErr(CMD_UNPIN_NORELOC)(f),
    },
    {
      kind: "http",
      actor: "alice",
      name: "channels:detail:pin-cleared",
      method: "GET",
      path: "/api/chat/channels/${main}",
      readProbe: { maxQueries: 50 },
    },

    // ------------------------------------------- m1 edit + recall (m2 keeps)
    {
      kind: "ws.command",
      actor: "alice",
      name: "ws:edit:m1",
      frame: {
        frame_type: "command",
        command: "message.edit",
        command_id: CMD_EDIT_M1,
        channel_id: "${main}",
        payload: { message_id: "${m1Id}", text: "mw m1 edited" },
      },
      waitFor: (f) => ack("message.edit", CMD_EDIT_M1)(f),
      alsoUntil: (f) => ev("message.updated")(f),
    },
    { kind: "wait", actor: "alice", name: "sync:fanout:edit-m1", ms: 750 },
    {
      kind: "ws.command",
      actor: "alice",
      name: "ws:recall:m1",
      frame: {
        frame_type: "command",
        command: "message.recall",
        command_id: CMD_RECALL_M1,
        channel_id: "${main}",
        payload: { message_id: "${m1Id}" },
      },
      waitFor: (f) => ack("message.recall", CMD_RECALL_M1)(f),
      alsoUntil: (f) => ev("message.recalled")(f),
    },
    { kind: "wait", actor: "alice", name: "sync:fanout:recall-m1", ms: 750 },
    {
      kind: "ws.command",
      actor: "alice",
      name: "ws:edit:gate:recalled",
      frame: {
        frame_type: "command",
        command: "message.edit",
        command_id: CMD_EDIT_M1_RECALLED,
        channel_id: "${main}",
        payload: { message_id: "${m1Id}", text: "edit recalled m1" },
      },
      waitFor: (f) => cmdErr(CMD_EDIT_M1_RECALLED)(f),
    },
    {
      kind: "ws.command",
      actor: "alice",
      name: "ws:recall:gate:foreign",
      frame: {
        frame_type: "command",
        command: "message.recall",
        command_id: CMD_RECALL_M2_ALICE,
        channel_id: "${main}",
        payload: { message_id: "${m2Id}" },
      },
      waitFor: (f) => cmdErr(CMD_RECALL_M2_ALICE)(f),
    },
    { kind: "wait", actor: "alice", name: "sync:recall-gates", ms: 500 },

    // ---------------------------------------------- carol: member + delete
    {
      kind: "ws.command",
      actor: "carol",
      name: "ws:send:m7:carol",
      frame: sendFrame(CMD_SEND_M7, "${main}", {
        type: "text",
        text: "mw m7 carol",
        reply_to_message_id: null,
        attachment_ids: [],
        mentions: [],
      }),
      // carol re-lived after joining (ws:live_start:carol2), so her socket is
      // subscribed to main's fanout on BOTH targets — await her own copy.
      waitFor: (f) => ack("message.send", CMD_SEND_M7)(f),
      alsoUntil: (f) => ev("message.created")(f),
    },
    { kind: "wait", actor: "carol", name: "sync:fanout:m7", ms: 750 },
    {
      kind: "http",
      actor: "carol",
      name: "messages:list:m7-id",
      method: "GET",
      path: "/api/chat/channels/${main}/messages",
      readProbe: { maxQueries: 50 },
      // Timeline now excludes m1 (recalled) + m3 (deleted); carol's
      // member.joined is at index 7 and m7 is the newest event (index 8).
      capture: { m7Id: "$.items.8.payload.message.message_id" },
    },
    {
      kind: "ws.command",
      actor: "carol",
      name: "ws:delete:m7:self",
      frame: {
        frame_type: "command",
        command: "message.delete",
        command_id: CMD_DELETE_M7_CAROL,
        channel_id: "${main}",
        payload: { message_id: "${m7Id}", reason: "typo" },
      },
      // carol is subscribed (re-lived post-join) — await her own copy.
      waitFor: (f) => ack("message.delete", CMD_DELETE_M7_CAROL)(f),
      alsoUntil: (f) => ev("message.deleted")(f),
    },
    { kind: "wait", actor: "carol", name: "sync:fanout:delete-m7", ms: 750 },

    // -------------------------------------------------- dissolved gate
    {
      kind: "http",
      actor: "alice",
      name: "channels:dissolve",
      method: "POST",
      path: "/api/chat/channels/${dissolveCh}/dissolve",
      headers: { "Idempotency-Key": KEY_DISSOLVE },
      body: {},
    },
    {
      kind: "ws.command",
      actor: "alice",
      name: "ws:send:gate:dissolved",
      frame: sendFrame(CMD_SEND_DISSOLVED, "${dissolveCh}", {
        type: "text",
        text: "sent after dissolve",
        reply_to_message_id: null,
        attachment_ids: [],
        mentions: [],
      }),
      waitFor: (f) => cmdErr(CMD_SEND_DISSOLVED)(f),
    },
    { kind: "wait", actor: "alice", name: "sync:dissolved-gate", ms: 500 },

    // --------------------------------------------------- mark_read phase
    {
      kind: "http",
      actor: "alice",
      name: "events:read:latest",
      method: "GET",
      path: "/api/chat/channels/${main}/events",
      readProbe: { maxQueries: 50 },
      capture: { latestEventId2: "$.latest_event_id" },
    },
    {
      kind: "ws.command",
      actor: "alice",
      name: "ws:mark_read:old-cursor",
      // Cursor older than every event → advances; the literal is echoed back
      // (scenario-deterministic, NOT normalized) with the full unread count.
      frame: {
        frame_type: "command",
        command: "channel.mark_read",
        command_id: CMD_MR_1,
        channel_id: "${main}",
        payload: { last_read_event_id: MR_OLD_CURSOR },
      },
      waitFor: (f) => ack("channel.mark_read", CMD_MR_1)(f),
    },
    { kind: "wait", actor: "alice", name: "sync:mr1", ms: 500 },
    {
      kind: "ws.command",
      actor: "alice",
      name: "ws:mark_read:latest",
      // Advances to the true latest event → unread 0; broadcasts
      // read_state_updated to alice's OTHER live session (alice2).
      frame: {
        frame_type: "command",
        command: "channel.mark_read",
        command_id: CMD_MR_2,
        channel_id: "${main}",
        payload: { last_read_event_id: "${latestEventId2}" },
      },
      waitFor: (f) => ack("channel.mark_read", CMD_MR_2)(f),
    },
    {
      // The read_state_updated hint goes to alice's OTHER session (alice2) a
      // few ms after the ack. This wait is the deterministic drain point:
      // the frame lands in THIS step's wsReceived on both targets (in-process
      // delivery is far faster than the window), so the hint frame is
      // verified by the diff without a step-boundary race.
      kind: "wait",
      actor: "alice",
      name: "sync:hint:read_state_updated",
      ms: 750,
    },
    {
      kind: "ws.command",
      actor: "alice",
      name: "ws:mark_read:no-advance",
      // Older cursor again → stored value returned, NO broadcast.
      frame: {
        frame_type: "command",
        command: "channel.mark_read",
        command_id: CMD_MR_3,
        channel_id: "${main}",
        payload: { last_read_event_id: MR_OLD_CURSOR },
      },
      waitFor: (f) => ack("channel.mark_read", CMD_MR_3)(f),
    },
    {
      kind: "ws.command",
      actor: "carol",
      name: "ws:mark_read:carol",
      frame: {
        frame_type: "command",
        command: "channel.mark_read",
        command_id: CMD_MR_CAROL_1,
        channel_id: "${main}",
        payload: { last_read_event_id: MR_OLD_CURSOR },
      },
      waitFor: (f) => ack("channel.mark_read", CMD_MR_CAROL_1)(f),
    },
    { kind: "wait", actor: "alice", name: "sync:mark-read", ms: 750 },

    // ------------------------------------------------- final read surface
    {
      kind: "http",
      actor: "alice",
      name: "messages:list:final",
      method: "GET",
      path: "/api/chat/channels/${main}/messages",
      readProbe: { maxQueries: 50 },
    },
    {
      kind: "http",
      actor: "alice",
      name: "messages:context:m2:final",
      method: "GET",
      path: "/api/chat/channels/${main}/messages/${m2Id}/context",
      readProbe: { maxQueries: 50 },
    },
    {
      kind: "http",
      actor: "alice",
      name: "events:read:final",
      method: "GET",
      path: "/api/chat/channels/${main}/events",
      readProbe: { maxQueries: 50 },
    },
    {
      kind: "http",
      actor: "alice",
      name: "bootstrap:final",
      method: "GET",
      path: "/api/chat/bootstrap?channel_id=${main}",
      readProbe: { maxQueries: 50 },
    },
    {
      kind: "http",
      actor: "alice",
      name: "channels:detail:final",
      method: "GET",
      path: "/api/chat/channels/${main}",
      readProbe: { maxQueries: 50 },
    },

    // ------------------------------------------------------------- close
    { kind: "ws.close", actor: "alice", name: "ws:close:alice" },
    { kind: "ws.close", actor: "bob", name: "ws:close:bob" },
    { kind: "ws.close", actor: "carol", name: "ws:close:carol" },
    { kind: "ws.close", actor: "alice2", name: "ws:close:alice2" },
  ],
};
