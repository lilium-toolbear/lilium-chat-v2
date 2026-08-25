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

/** Frame predicate used by WS steps (waitFor / alsoUntil / until / capture.from). */
export type WsPredicate = (frame: unknown, ctx: StepContext) => boolean;

/**
 * Capture a var from a specific frame of the step's capture window: the
 * FIRST frame in `matchedFrames` that satisfies `from`. Use for server
 * frames that are not the ack (e.g. a bot `delivery` frame's `delivery_id`
 * or a `session.start` frame's `session_id` — contract §9.7).
 */
export interface WsCaptureRef {
  from: WsPredicate;
  /** JSON pointer into the matched frame, e.g. `$.delivery_id`. */
  pointer: string;
}

export interface ActorSpec {
  /** ToolBear user UUID — fixed per scenario, identical across targets. */
  userId: string;
  /** Extra JWT claims beyond `sub` (e.g. `{ admin: true }`). */
  jwtClaims?: Record<string, unknown>;
  /**
   * Relative `exp` offset in seconds from mint time (e.g. `-3600` for an
   * already-expired token). Omitted → default 1h validity.
   */
  jwtExpSeconds?: number;
}

interface BaseStep {
  actor: string;
  /** Label for reports. Defaults to kind + index. */
  name?: string;
}

export interface HttpStep extends BaseStep {
  kind: "http";
  method: "GET" | "POST" | "PATCH" | "PUT" | "DELETE";
  /**
   * Path (may contain `${var}` interpolation), e.g. `/api/chat/bootstrap`.
   * With `absolute`, `path` is the FULL URL instead of a target-relative
   * path (used for the S3 PUT steps that hit the fixture object store).
   */
  path: string;
  /** Treat `path` as a full `http(s)://` URL rather than target-relative. */
  absolute?: boolean;
  body?: unknown;
  /**
   * Raw binary body (base64) sent AS-IS — the JSON body (`body`) is
   * `JSON.stringify`ed, which would corrupt binary content and mangle the
   * Content-Length that a presigned PUT signature constrains (contract
   * §8.1: Content-Length ≤ size_bytes, exact bytes required). When set,
   * `body` must be omitted; the base64 string itself is recorded in the
   * capture (static scenario literal — deterministic across targets).
   */
  base64Body?: string;
  /**
   * Request headers. A value of `null` marks the header as EXPLICITLY
   * omitted — notably `Authorization: null` suppresses the actor's default
   * Bearer token (unauthenticated request, contract §2.1).
   */
  headers?: Record<string, string | null>;
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
  /**
   * WS endpoint path (default `/api/chat/ws` — the browser socket).
   * `${var}` interpolation is supported: the bot Stream WS path
   * (`/api/chat/bot/channels/{ch}/streams/{msg}/ws`, contract §9.15) is
   * assembled from captured ids.
   */
  path?: string;
  /**
   * Subprotocols to offer (default: the browser pair
   * `["lilium.chat.v2", "bearer.<actor jwt>"]`). Bot sockets (contract §9.1 /
   * §9.7 / §9.15) offer the contract version plus the `bearer.<bot_token>`
   * entry — the Elixir sockets read the token from that subprotocol; the old
   * Worker reads the Authorization header (sent via `headers` below). The
   * server echoes the contract version on both targets, so
   * `meta.negotiated_protocol` stays comparable.
   */
  protocols?: string[];
  /**
   * Extra upgrade request headers (values interpolated; `null` = omit).
   * Bot WS upgrades carry `Authorization: Bearer <bot_token>` (the old
   * Worker's ONLY token carrier on WS; the Elixir socket accepts either
   * carrier, so sending both is safe on both).
   */
  headers?: Record<string, string | null>;
}

export interface WsCommandStep extends BaseStep {
  kind: "ws.command";
  /** Command frame to send (client owns `command_id`). */
  frame: unknown;
  /**
   * Close the capture window when a received frame satisfies this predicate.
   * When omitted, the frame is **fire-and-forget**: the server sends no
   * reply frame in response (contract §9.7.4 — `session.start_ack`,
   * `session.input_ack`, and `session.close` are answered only by the
   * follow-up server-pushed frames such as `session.closed`), so the capture
   * window closes immediately after the send and any queued frames are
   * recorded under this step.
   */
  waitFor?: (frame: unknown, ctx: StepContext) => boolean;
  /**
   * Additional frame(s) that must also arrive before the window closes (e.g.
   * the fanout event after message.send ack). Ack-then-event vs
   * event-then-ack both land in THIS step, so delivery-order races don't
   * false-positive. An array form waits for EVERY listed frame (issue #27
   * D: an invoke window that must also contain the bot-side push — the
   * `command_invocation` delivery, `session.start`, …).
   */
  alsoUntil?: WsPredicate | WsPredicate[];
  /**
   * Actors whose pending frames are pulled into THIS step's capture when the
   * window closes (issue #27 D): after the actor-socket predicates match,
   * each listed socket is spliced up to its last frame matching ANY window
   * predicate. Deterministic placement of cross-socket frames (the bot
   * `delivery` / `session.*` push that races the invoke ack+event) — they
   * are captured under the step that triggered them on both targets.
   * Unmatched trailing frames still land via the end-of-step drain.
   */
  alsoSplice?: string[];
  /**
   * varName → capture source. A string is a JSON pointer into the frame that
   * matched `waitFor` (the ack — never the alsoUntil fanout frame); a
   * `WsCaptureRef` object captures from the first window frame that
   * satisfies `from` (server-minted ids that only exist on a non-ack frame —
   * e.g. the `start_stream` effect result's `message_id`, which is the
   * Stream WS path parameter, or a bot `delivery` frame's `delivery_id`).
   * Resolution runs after the end-of-step drain, so a frame that arrives
   * during the 400ms settle still resolves.
   */
  capture?: Record<string, string | WsCaptureRef>;
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
