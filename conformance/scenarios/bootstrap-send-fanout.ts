/**
 * Representative go/no-go scenario (spec §7.4 Phase 0 subset):
 *
 *   bootstrap (empty) → create channel → wait for projection → WS connect →
 *   session.live_start → message.send (committed ack) → 1 fanout
 *   (message.created live event) → bootstrap (post-state, read probe).
 *
 * Deterministic inputs only: fixed actor, fixed command_ids, fixed text.
 * Everything the server mints (channel/message/event ids, timestamps,
 * request ids, session id) is volatile and gets normalized before diffing.
 */

import type { Scenario } from "../src/types.js";

export const ALICE_USER_ID = "6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e6f";

const LIVE_START_CMD = "0199c0aa-1111-7000-8000-000000000001";
const MESSAGE_SEND_CMD = "0199c0aa-2222-7000-8000-000000000002";

export const bootstrapSendFanout: Scenario = {
  name: "bootstrap-send-fanout",
  description:
    "Bootstrap (empty) + channel create + WS live_start + message.send committed ack + one fanout event + post-state bootstrap with read-path probe.",
  actors: {
    alice: { userId: ALICE_USER_ID },
  },
  steps: [
    {
      kind: "http",
      actor: "alice",
      name: "bootstrap:initial",
      method: "GET",
      path: "/api/chat/bootstrap",
      readProbe: { maxQueries: 50 },
    },
    {
      kind: "http",
      actor: "alice",
      name: "channels:create",
      method: "POST",
      path: "/api/chat/channels",
      headers: { "Idempotency-Key": "conformance-channel-create" },
      body: {
        title: "Conformance Channel",
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
      // The old Worker projects membership into UserDirectory via an
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
      // The fanout lease is registered out-of-band (old Worker: outbox + DO
      // alarm; Elixir: PubSub subscription). A short grace keeps the
      // message.send from racing ahead of lease registration. Not captured.
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
          text: "hello conformance",
          reply_to_message_id: null,
          attachment_ids: [],
          mentions: [],
        },
      },
      waitFor: (frame) => {
        const f = frame as { frame_type?: string; command_id?: string };
        return f.frame_type === "command_ack" && f.command_id === MESSAGE_SEND_CMD;
      },
      // 1 fanout: message.created on the sender's own live session. Ack and
      // event share this window so arrival order (ack-then-event vs the
      // reverse) does not split them across steps and false-positive the diff.
      alsoUntil: (frame, ctx) => {
        const f = frame as { frame_type?: string; type?: string; channel_id?: string };
        return f.frame_type === "event" && f.type === "message.created" && f.channel_id === ctx.vars.get("channelId");
      },
      waitTimeoutMs: 15_000,
    },
    {
      kind: "http",
      actor: "alice",
      name: "bootstrap:after",
      method: "GET",
      path: "/api/chat/bootstrap?channel_id=${channelId}",
      readProbe: { maxQueries: 50 },
    },
    { kind: "ws.close", actor: "alice", name: "ws:close" },
  ],
};
