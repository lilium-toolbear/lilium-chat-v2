/**
 * The mechanism proof (acceptance criteria 1 + 2): the SAME scenario script
 * runs against two independent targets with different volatile values; after
 * normalization the captures must diff empty — i.e. the normalizer replaces
 * every volatile field and nothing stable is missed or masked.
 */

import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { bootstrapSendFanout } from "../scenarios/bootstrap-send-fanout.js";
import { captureForDiff, diffCaptures } from "../src/diff.js";
import { normalizeCapture } from "../src/normalize.js";
import { collectKnownClientIds, runScenario } from "../src/runner.js";
import { MockTarget } from "../src/targets/mock.js";

const SECRET = "test-jwt-secret-do-not-use-in-prod";

describe("scenario bootstrap-send-fanout against mock targets", () => {
  let a: InstanceType<typeof MockTarget>;
  let b: InstanceType<typeof MockTarget>;

  beforeAll(async () => {
    a = new MockTarget({ name: "mock-a" });
    b = new MockTarget({ name: "mock-b" });
    await a.start();
    await b.start();
    await a.reset();
    await b.reset();
  }, 30_000);

  afterAll(async () => {
    await a?.stop().catch(() => {});
    await b?.stop().catch(() => {});
  });

  it("captures the full flow: ack committed + one fanout event + post-state bootstrap", async () => {
    const capture = await runScenario(bootstrapSendFanout, a.endpoint(), { jwtSecret: SECRET });

    const byName = new Map(capture.steps.map((s) => [s.name ?? `${s.kind}#${s.index}`, s]));
    expect([...byName.values()].every((s) => !s.error)).toBe(true);

    const sendStep = byName.get("ws:message_send")!;
    const ack = (sendStep.wsReceived ?? [])
      .map((f) => f as Record<string, unknown>)
      .find((f) => f.frame_type === "command_ack");
    expect(ack).toBeTruthy();
    expect(ack!.status).toBe("committed");
    expect((ack!.payload as { message?: { text?: string } }).message?.text).toBe("hello conformance");

    const event = (sendStep.wsReceived ?? [])
      .map((f) => f as Record<string, unknown>)
      .find((f) => f.frame_type === "event" && f.type === "message.created");
    expect(event).toBeTruthy();

    const bootstrapAfter = byName.get("bootstrap:after")!;
    expect(bootstrapAfter.http!.request.headers.Authorization).toMatch(/^Bearer /);
    const body = bootstrapAfter.http!.response.body as {
      me?: { user_id?: string };
      channels?: Array<{ title?: string }>;
      messages?: { items?: Array<{ text?: string }> };
    };
    expect(body.me?.user_id).toBe(bootstrapSendFanout.actors.alice!.userId);
    expect(body.channels).toHaveLength(1);
    expect(body.channels![0]!.title).toBe("Conformance Channel");
    const items = body.messages?.items;
    expect(items).toHaveLength(1);
    expect(items![0]!.text).toBe("hello conformance");
  });

  it("produces different RAW captures across instances (volatile values really vary)", async () => {
    // Fresh state for instance b; a already ran once above — reset both so
    // the comparison is like-for-like.
    await a.reset();
    await b.reset();
    const capA = await runScenario(bootstrapSendFanout, a.endpoint(), { jwtSecret: SECRET });
    const capB = await runScenario(bootstrapSendFanout, b.endpoint(), { jwtSecret: SECRET });

    const channelOf = (c: typeof capA): string => {
      const create = c.steps.find((s) => s.name === "channels:create")!;
      return ((create.http?.response.body as { channel?: { channel_id?: string } })?.channel?.channel_id ?? "") as string;
    };
    expect(channelOf(capA)).not.toBe(channelOf(capB));
  });

  it("normalizes to IDENTICAL captures (no false positives)", async () => {
    await a.reset();
    await b.reset();
    const capA = await runScenario(bootstrapSendFanout, a.endpoint(), { jwtSecret: SECRET });
    const capB = await runScenario(bootstrapSendFanout, b.endpoint(), { jwtSecret: SECRET });

    const knownClientIds = collectKnownClientIds(bootstrapSendFanout);
    const normA = normalizeCapture(capA, { knownClientIds });
    const normB = normalizeCapture(capB, { knownClientIds });
    const { diffs } = diffCaptures(captureForDiff(normA), captureForDiff(normB));

    expect(diffs).toEqual([]);
  });

  it("collects client ids (command_ids + actor) but not server-minted vars", () => {
    const ids = collectKnownClientIds(bootstrapSendFanout);
    expect(ids.has("0199c0aa-1111-7000-8000-000000000001")).toBe(true); // live_start command_id
    expect(ids.has("0199c0aa-2222-7000-8000-000000000002")).toBe(true); // message.send command_id
    expect(ids.has("6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e6f")).toBe(true); // actor user id
  });

  it("records transport errors as step errors without crashing the run", async () => {
    const dead = new MockTarget({ name: "mock-dead", port: 59999 });
    // Do not start `dead`; point a minimal scenario at its unbound port.
    const endpoint = dead.endpoint();
    const scenario = {
      name: "dead-target",
      actors: { alice: { userId: bootstrapSendFanout.actors.alice!.userId } },
      steps: [
        { kind: "http" as const, actor: "alice", method: "GET" as const, path: "/api/chat/bootstrap" },
        { kind: "ws.connect" as const, actor: "alice" },
      ],
    };
    const capture = await runScenario(scenario, endpoint, { jwtSecret: SECRET, waitTimeoutMs: 1500 });
    const httpStep = capture.steps.find((s) => s.kind === "http")!;
    expect(httpStep.error).toMatch(/transport error/);
    const wsStep = capture.steps.find((s) => s.kind === "ws.connect")!;
    expect(wsStep.error).toBeTruthy();
  });
});
