import { describe, expect, it } from "vitest";
import { normalizeCapture, PLACEHOLDER_JWT, PLACEHOLDER_TS, PLACEHOLDER_UUID } from "../src/normalize.js";
import type { Capture } from "../src/types.js";

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
});
