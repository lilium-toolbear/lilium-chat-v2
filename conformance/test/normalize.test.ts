import { describe, expect, it } from "vitest";
import {
  normalizeCapture,
  PLACEHOLDER_DEF_HASH,
  PLACEHOLDER_JWT,
  PLACEHOLDER_TS,
  PLACEHOLDER_UUID,
} from "../src/normalize.js";
import type { Capture, StepCapture } from "../src/types.js";

function captureWith(body: unknown): Capture {
  return {
    scenario: "t",
    target: "t",
    capturedAt: "2026-08-21T05:30:00.000Z",
    steps: [
      {
        index: 0,
        kind: "http",
        actor: "a",
        http: {
          request: { method: "GET", path: "/x", headers: { Authorization: "Bearer eyJhbGciOiJIUzI1NiJ9.abc.def" } },
          response: { status: 200, headers: { "content-type": "application/json", date: "Wed, 21 Aug 2026 05:30:00 GMT", "x-request-id": "req_0199c0aa-1111-7000-8000-000000000001" }, body },
        },
      },
    ],
  };
}

describe("normalizeCapture", () => {
  it("replaces server-generated UUIDs with {{UUID}}", () => {
    const out = normalizeCapture(captureWith({ id: "0199c0aa-1111-7000-8000-000000000002", list: ["6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e6f"] }));
    const body = out.steps[0]!.http!.response.body as { id: string; list: string[] };
    expect(body.id).toBe(PLACEHOLDER_UUID);
    expect(body.list[0]).toBe(PLACEHOLDER_UUID);
  });

  it("preserves known client ids (deterministic inputs must echo identically)", () => {
    const clientId = "0199c0aa-2222-7000-8000-000000000002";
    const out = normalizeCapture(captureWith({ command_id: clientId, other: "0199c0aa-3333-7000-8000-000000000003" }), {
      knownClientIds: new Set([clientId.toLowerCase()]),
    });
    const body = out.steps[0]!.http!.response.body as { command_id: string; other: string };
    expect(body.command_id).toBe(clientId);
    expect(body.other).toBe(PLACEHOLDER_UUID);
  });

  it("normalizes ISO-8601 and HTTP-date timestamps to {{TS}}", () => {
    const out = normalizeCapture(captureWith({ at: "2026-08-21T05:30:00Z", ms: "2026-08-21T05:30:00.123Z" }));
    const body = out.steps[0]!.http!.response.body as { at: string; ms: string };
    expect(body.at).toBe(PLACEHOLDER_TS);
    expect(body.ms).toBe(PLACEHOLDER_TS);
    expect(out.capturedAt).toBe(PLACEHOLDER_TS);
  });

  it("drops transport-level response headers (HTTP/1.1 framing, not API contract)", () => {
    const cap = captureWith({});
    const h = cap.steps[0]!.http!.response.headers as Record<string, string>;
    h["cache-control"] = "max-age=0";
    h["content-length"] = "42";
    h["transfer-encoding"] = "chunked";
    const out = normalizeCapture(cap);
    const headers = out.steps[0]!.http!.response.headers;
    expect(headers.date).toBeUndefined();
    expect(headers["cache-control"]).toBeUndefined();
    expect(headers["content-length"]).toBeUndefined();
    expect(headers["transfer-encoding"]).toBeUndefined();
    // Semantic headers survive.
    expect(headers["x-request-id"]).toBe("req_{{UUID}}");
    expect(headers["content-type"]).toBe("application/json");
  });

  it("canonicalizes Vary (drops accept-encoding, case/order-insensitive)", () => {
    const cap = captureWith({});
    (cap.steps[0]!.http!.response.headers as Record<string, string>)["vary"] = "Accept-Encoding, Origin";
    const out = normalizeCapture(cap);
    expect(out.steps[0]!.http!.response.headers.vary).toBe("origin");
  });

  it("normalizes req_<uuidv7> request ids", () => {
    const out = normalizeCapture(captureWith({}));
    expect(out.steps[0]!.http!.response.headers["x-request-id"]).toBe("req_{{UUID}}");
  });

  it("masks Authorization bearer tokens in header context only", () => {
    const out = normalizeCapture(captureWith({ text: "Bearer not-a-real-token-in-body" }));
    expect(out.steps[0]!.http!.request.headers.Authorization).toBe(PLACEHOLDER_JWT);
    // Body values that merely look like bearer strings are left alone (fidelity).
    const body = out.steps[0]!.http!.response.body as { text: string };
    expect(body.text).toBe("Bearer not-a-real-token-in-body");
  });

  it("leaves stable values untouched", () => {
    const out = normalizeCapture(captureWith({ status: "committed", count: 3, title: "Conformance Channel", flag: null }));
    const body = out.steps[0]!.http!.response.body as Record<string, unknown>;
    expect(body).toEqual({ status: "committed", count: 3, title: "Conformance Channel", flag: null });
  });

  it("normalizes WS frames the same way as HTTP bodies", () => {
    const cap = captureWith(null);
    cap.steps[0]!.wsReceived = [
      { frame_type: "event", event_id: "0199c0aa-4444-7000-8000-000000000004", occurred_at: "2026-08-21T05:30:01Z" },
    ];
    const out = normalizeCapture(cap);
    const frame = out.steps[0]!.wsReceived![0] as Record<string, string>;
    expect(frame.event_id).toBe(PLACEHOLDER_UUID);
    expect(frame.occurred_at).toBe(PLACEHOLDER_TS);
  });

  it("parses command_snapshot_json string snapshots into objects (issue #27 D)", () => {
    // Old Worker stores the binding-change snapshot as a JSON-encoded string;
    // the v2 implementation stores the parsed object. Both must compare as the
    // same structural snapshot (UUIDs masked, content compared).
    const snapshot = {
      bot_command_id: "0199c0aa-5555-7000-8000-000000000005",
      name: "ask",
      execution: { mode: "stateless" },
    };
    const body = {
      items: [
        {
          frame_type: "event",
          type: "command.binding_updated",
          payload: {
            binding_changes: {
              command_snapshot_json: {
                before: null,
                after: JSON.stringify(snapshot),
              },
            },
          },
        },
      ],
    };
    const out = normalizeCapture(captureWith(body));
    const after = (out.steps[0]!.http!.response.body as any).items[0].payload
      .binding_changes.command_snapshot_json.after;
    expect(after).toBeInstanceOf(Object);
    expect(after.bot_command_id).toBe(PLACEHOLDER_UUID);
    expect(after.name).toBe("ask");
    expect(after.execution).toEqual({ mode: "stateless" });
  });

  it("drops display fields from command.invoked payloads on LIVE and replay (issue #27 D)", () => {
    const frame = {
      frame_type: "event",
      type: "command.invoked",
      payload: {
        invocation: { invocation_id: "0199c0aa-6666-7000-8000-000000000006", status: "pending", created_at: "2026-08-21T05:30:00Z" },
        command_id: "0199c0aa-7777-7000-8000-000000000007",
        command_name: "ask",
        invoked_name: "/ask",
        actor: { user_id: "6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e6f", display_name: "A" },
      },
    };
    const cap = captureWith(null);
    cap.steps[0]!.wsReceived = [frame];
    const out = normalizeCapture(cap);
    const payload = (out.steps[0]!.wsReceived![0] as any).payload;
    expect(payload.command_name).toBeUndefined();
    expect(payload.invoked_name).toBeUndefined();
    expect(payload.actor).toBeUndefined();
    expect(payload.command_id).toBe(PLACEHOLDER_UUID);
    expect(payload.invocation.status).toBe("pending");
  });

  it("masks definition_hash on delivery + session.start bot frames (issue #27 D)", () => {
    const delivery = {
      type: "delivery",
      kind: "command_invocation",
      delivery_id: "0199c0aa-8888-7000-8000-000000000008",
      bot_command: { bot_command_id: "0199c0aa-9999-7000-8000-000000000009", definition_hash: "snapshot:0199c0aa-9999-7000-8000-000000000009" },
      options: { prompt: { type: "string", value: "x" } },
    };
    const sessionStart = {
      type: "session.start",
      session_id: "0199c0aa-aaaa-7000-8000-00000000000a",
      bot_command: { bot_command_id: "0199c0aa-9999-7000-8000-000000000009", definition_hash: "7ed301ae35b92b1eeacd8c4ffc1288ba4779617eb2e0ac93f061da5cc8f27e7a" },
    };
    const cap = captureWith(null);
    cap.steps[0]!.wsReceived = [delivery, sessionStart];
    const out = normalizeCapture(cap);
    const d = out.steps[0]!.wsReceived![0] as any;
    expect(d.command.definition_hash).toBe(PLACEHOLDER_DEF_HASH);
    expect(d.bot_command).toBeUndefined();
    const s = out.steps[0]!.wsReceived![1] as any;
    expect(s.bot_command.definition_hash).toBe(PLACEHOLDER_DEF_HASH);
  });

  it("sorts command-directory items by (bot_command_id, name) on both sides (issue #27 D)", () => {
    // The directory route is the one place item order is forced: contract
    // §9.12.1 pins the { items, next_cursor } shape, not the order, and the
    // server-side ORDER BY (updated_at DESC, bot_command_id DESC) ties on the
    // shared catalog-sync timestamp, falling through to per-target random
    // UUIDv7 tails (the bot-http directory steps flipped ask/ponder order
    // across runs). Swapped input order must come out sorted identically on
    // both sides — after the deep pass bot_command_id is {{UUID}} on both,
    // so the (bot_command_id, name) key reduces to the command name.
    const cap = captureWith({
      items: [
        {
          bot_command_id: "0199c0aa-bbbb-7000-8000-00000000000b",
          name: "ponder",
          aliases: [],
          description: "",
          help_text: "",
          bot: { bot_id: "0199c0aa-cccc-7000-8000-00000000000c", display_name: "ToolBear", avatar_url: null },
          options: [],
          default_member_permission: "member",
          execution: { mode: "stateless" },
        },
        {
          bot_command_id: "0199c0aa-dddd-7000-8000-00000000000d",
          name: "ask",
          aliases: [],
          description: "",
          help_text: "",
          bot: { bot_id: "0199c0aa-cccc-7000-8000-00000000000c", display_name: "ToolBear", avatar_url: null },
          options: [],
          default_member_permission: "member",
          execution: { mode: "stateless" },
        },
      ],
      next_cursor: null,
    });
    cap.steps[0]!.http!.request.path = "/api/chat/commands/directory?query=&limit=50";
    const out = normalizeCapture(cap);
    const body = out.steps[0]!.http!.response.body as {
      items: Array<Record<string, unknown>>;
      next_cursor: unknown;
    };
    expect(body.items.map((i) => i.name)).toEqual(["ask", "ponder"]);
    expect(body.items.map((i) => i.bot_command_id)).toEqual([PLACEHOLDER_UUID, PLACEHOLDER_UUID]);
    expect(body.next_cursor).toBeNull();
  });

  it("does NOT sort items on non-directory routes (sort is route-scoped)", () => {
    const cap = captureWith({
      items: [
        { bot_command_id: "0199c0aa-eeee-7000-8000-00000000000e", name: "zeta" },
        { bot_command_id: "0199c0aa-ffff-7000-8000-00000000000f", name: "alpha" },
      ],
    });
    const out = normalizeCapture(cap);
    const body = out.steps[0]!.http!.response.body as { items: Array<Record<string, unknown>> };
    expect(body.items.map((i) => i.name)).toEqual(["zeta", "alpha"]);
  });
});
