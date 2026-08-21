/**
 * Conformance harness types (spec §7, issue #1).
 *
 * A Scenario is a deterministic script of HTTP/WS steps. The same scenario is
 * executed against two targets that both start from empty state ("the script
 * IS the fixture", spec §7.1). Every step's request and every response/frame
 * are captured; captures are normalized (volatile fields → placeholders) and
 * diffed structurally.
 */

// ---------------------------------------------------------------------------
// Scenario definition
// ---------------------------------------------------------------------------

/** Runtime context handed to step predicates (retryUntil / waitFor / until). */
export interface StepContext {
  /** Vars captured so far by earlier steps (`capture` pointers). */
  vars: Map<string, unknown>;
}

export interface ActorSpec {
  /** ToolBear user UUID — fixed per scenario, identical across targets. */
  userId: string;
  /** Extra JWT claims beyond `sub` (e.g. `{ admin: true }`). */
  jwtClaims?: Record<string, unknown>;
}

interface BaseStep {
  actor: string;
  /** Label for reports. Defaults to kind + index. */
  name?: string;
}

export interface HttpStep extends BaseStep {
  kind: "http";
  method: "GET" | "POST" | "PATCH" | "PUT" | "DELETE";
  /** Path (may contain `${var}` interpolation), e.g. `/api/chat/bootstrap`. */
  path: string;
  body?: unknown;
  headers?: Record<string, string>;
  /**
   * Optional retry loop for async projections (e.g. channel list after
   * create). Re-executes until the predicate passes or `maxAttempts` is
   * exhausted. Only the FINAL response is recorded in the capture, so
   * differing attempt counts never produce a diff. The predicate receives
   * the runtime context (captured vars) so it can match interpolated ids.
   */
  retryUntil?: (response: HttpResponseCapture, ctx: StepContext) => boolean;
  maxAttempts?: number;
  /** varName → JSON pointer into the response body, e.g. `$.channel.channel_id`. */
  capture?: Record<string, string>;
  /**
   * Marks this step as a read-path observation probe (spec §7.5 / D15):
   * asserts no hidden writes and a bounded PG query count around the request.
   */
  readProbe?: { maxQueries?: number };
}

export interface WsConnectStep extends BaseStep {
  kind: "ws.connect";
}

export interface WsCommandStep extends BaseStep {
  kind: "ws.command";
  /** Command frame to send (client owns `command_id`). */
  frame: unknown;
  /** Close the capture window when a received frame satisfies this predicate. */
  waitFor: (frame: unknown, ctx: StepContext) => boolean;
  /**
   * Additional frame that must also arrive before the window closes (e.g. the
   * fanout event after message.send ack). Ack-then-event vs event-then-ack
   * both land in THIS step, so delivery-order races don't false-positive.
   */
  alsoUntil?: (frame: unknown, ctx: StepContext) => boolean;
  waitTimeoutMs?: number;
}

export interface WsEventStep extends BaseStep {
  kind: "ws.event";
  /** Match on a received frame, typically `event.type` + `channel_id`. */
  until: (frame: unknown, ctx: StepContext) => boolean;
  timeoutMs?: number;
  /** varName → JSON pointer into the MATCHED frame. */
  capture?: Record<string, string>;
}

export interface WsCloseStep extends BaseStep {
  kind: "ws.close";
}

/** Harness-level synchronization barrier. NOT recorded in the capture. */
export interface WaitStep extends BaseStep {
  kind: "wait";
  ms: number;
}

export type Step =
  | HttpStep
  | WsConnectStep
  | WsCommandStep
  | WsEventStep
  | WsCloseStep
  | WaitStep;

export interface Scenario {
  name: string;
  description?: string;
  actors: Record<string, ActorSpec>;
  steps: Step[];
}

// ---------------------------------------------------------------------------
// Capture (what the harness recorded against one target)
// ---------------------------------------------------------------------------

export interface HttpRequestCapture {
  method: string;
  path: string;
  /** Request headers as sent. Authorization is masked by the normalizer. */
  headers: Record<string, string>;
  body?: unknown;
}

export interface HttpResponseCapture {
  status: number;
  /** All response headers (lower-cased keys). Volatile values normalized. */
  headers: Record<string, string>;
  /** Parsed JSON body, or raw text when the body is not JSON. */
  body: unknown;
}

export interface StepCapture {
  index: number;
  kind: string;
  name?: string;
  actor: string;
  http?: { request: HttpRequestCapture; response: HttpResponseCapture };
  /** Frames this step sent (ws.command). */
  wsSent?: unknown[];
  /** Frames received during this step's capture window, in arrival order. */
  wsReceived?: unknown[];
  /** Transport-level facts (negotiated subprotocol, close code, …). Not wire payload. */
  meta?: Record<string, unknown>;
  /** Read-path observation for steps marked `readProbe` (spec §7.5). */
  readObservation?: import("./read-path.js").ReadObservation;
  /** Transport-level failure (timeout / refused / protocol error). Not a wire diff by itself — both targets failing the same way still diffs equal. */
  error?: string;
}

export interface Capture {
  scenario: string;
  target: string;
  /** ISO timestamp of capture start — normalized to {{TS}}. */
  capturedAt: string;
  steps: StepCapture[];
}

// ---------------------------------------------------------------------------
// Diff + report
// ---------------------------------------------------------------------------

export interface DiffEntry {
  /** JSON-pointer-ish path into the (normalized) capture, e.g. `steps[3].response.body.error.code`. */
  path: string;
  left?: unknown;
  right?: unknown;
}

export const MISSING = Symbol("missing");

export function isMissing(value: unknown): boolean {
  return value === MISSING;
}
