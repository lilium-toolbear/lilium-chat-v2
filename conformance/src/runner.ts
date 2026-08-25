/**
 * Scenario runner: executes one scenario against one target endpoint and
 * records a full Capture (every HTTP request/response, every WS frame, in
 * order). The runner is protocol-agnostic — targets only provide base URLs.
 */

import { makeJwt } from "./jwt.js";
import { CapturingWebSocket } from "./ws-client.js";
import type { ReadPathProbe } from "./read-path.js";
import type {
  Capture,
  HttpStep,
  HttpResponseCapture,
  Scenario,
  Step,
  StepCapture,
  WsCommandStep,
  WsEventStep,
} from "./types.js";

export interface Endpoint {
  name: string;
  /** e.g. http://127.0.0.1:8791 */
  httpBase: string;
  /** e.g. ws://127.0.0.1:8791 */
  wsBase: string;
}

export interface RunOptions {
  jwtSecret: string;
  /** Origin header for WS upgrade (contract §2.1 whitelist). */
  origin?: string;
  /** Read-path observation probe (spec §7.5); only used by steps with `readProbe`. */
  readProbe?: ReadPathProbe | null;
  /** Default wait timeout for ws.command / ws.event steps. */
  waitTimeoutMs?: number;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DEFAULT_WAIT_MS = 10_000;
const RETRY_INTERVAL_MS = 250;
const DEFAULT_MAX_ATTEMPTS = 20;
/**
 * Fanout settle (issue #27 batch C). Fanout delivery is asynchronous on BOTH
 * targets but at different speeds: the old Worker pushes channel-event frames
 * synchronously inside the write request (plus user_event hints a few ms
 * later via the UserDirectory projection alarm), while the Elixir target
 * delivers every frame via the Postgres fanout AFTER the write response.
 * Without a settle, the same fanout lands in different steps on the two
 * targets (a step-boundary false positive). Waiting a fixed window before
 * draining each step's socket buffers pins the union of frames per step on
 * both sides (both targets' frames arrive far faster than this window).
 */
const SETTLE_MS = 400;

// ---------------------------------------------------------------------------
// Scenario static analysis
// ---------------------------------------------------------------------------

/**
 * Collect client-generated UUIDs from the scenario BEFORE interpolation:
 * actor user ids plus every UUID literal in step definitions (command_ids,
 * Idempotency-Key values, mention targets, …). These must survive
 * normalization — they are deterministic inputs both targets must echo.
 * Server-minted ids arrive only via `${var}` interpolation and are never
 * collected here, so they get normalized like any other volatile value.
 */
export function collectKnownClientIds(scenario: Scenario): Set<string> {
  const ids = new Set<string>();
  for (const actor of Object.values(scenario.actors)) {
    if (UUID_RE.test(actor.userId)) ids.add(actor.userId.toLowerCase());
  }
  const scan = (value: unknown): void => {
    if (typeof value === "string") {
      if (UUID_RE.test(value.trim())) ids.add(value.trim().toLowerCase());
      return;
    }
    if (Array.isArray(value)) {
      for (const v of value) scan(v);
      return;
    }
    if (value !== null && typeof value === "object") {
      for (const v of Object.values(value as Record<string, unknown>)) scan(v);
    }
  };
  for (const step of scenario.steps) scan(step);
  return ids;
}

// ---------------------------------------------------------------------------
// Interpolation + JSON pointer helpers
// ---------------------------------------------------------------------------

export class MissingVarError extends Error {
  constructor(name: string) {
    super(`missing scenario var \`${name}\``);
  }
}

function interpolateString(value: string, vars: Map<string, unknown>): string {
  return value.replace(/\$\{([a-zA-Z0-9_]+)\}/g, (_m, name: string) => {
    if (!vars.has(name)) throw new MissingVarError(name);
    const v = vars.get(name);
    if (v === null || v === undefined) throw new MissingVarError(name);
    return String(v);
  });
}

function interpolateDeep(value: unknown, vars: Map<string, unknown>): unknown {
  if (typeof value === "string") return interpolateString(value, vars);
  if (Array.isArray(value)) return value.map((v) => interpolateDeep(v, vars));
  if (value !== null && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) out[k] = interpolateDeep(v, vars);
    return out;
  }
  return value;
}

/** Tiny JSON pointer: `$.channel.channel_id`, numeric segments index arrays. */
export function jsonPointer(body: unknown, pointer: string): unknown {
  const parts = pointer.replace(/^\$\.?/, "").split(".").filter(Boolean);
  let cur: unknown = body;
  for (const part of parts) {
    if (cur === null || typeof cur !== "object") return undefined;
    cur = (cur as Record<string, unknown>)[part];
  }
  return cur;
}

// ---------------------------------------------------------------------------
// HTTP capture
// ---------------------------------------------------------------------------

async function httpCapture(
  endpoint: Endpoint,
  method: string,
  path: string,
  headers: Record<string, string>,
  body: unknown,
  absolute: boolean,
  base64Body: string | undefined,
): Promise<{ response: HttpResponseCapture; requestHeaders: Record<string, string> }> {
  const url = absolute ? path : `${endpoint.httpBase}${path}`;
  const requestHeaders: Record<string, string> = { ...headers };
  let payload: string | Uint8Array | undefined;
  if (base64Body !== undefined) {
    // Raw binary body (S3 presigned PUT): bytes + Content-Length must match
    // exactly what the scenario sent (contract §8.1 size cap).
    payload = Buffer.from(base64Body, "base64");
  } else if (body !== undefined) {
    requestHeaders["Content-Type"] = requestHeaders["Content-Type"] ?? "application/json";
    payload = JSON.stringify(body);
  }
  const res = await fetch(url, { method, headers: requestHeaders, body: payload, redirect: "manual" });

  const responseHeaders: Record<string, string> = {};
  res.headers.forEach((v, k) => {
    responseHeaders[k.toLowerCase()] = v;
  });

  const text = await res.text();
  let responseBody: unknown;
  if (text.length > 0) {
    try {
      responseBody = JSON.parse(text);
    } catch {
      responseBody = text; // non-JSON body — kept raw for diff fidelity
    }
  } else {
    responseBody = null;
  }

  return { response: { status: res.status, headers: responseHeaders, body: responseBody }, requestHeaders };
}

// ---------------------------------------------------------------------------
// Runner
// ---------------------------------------------------------------------------

interface SocketSession {
  ws: CapturingWebSocket;
  pending: unknown[];
  closedInfo?: { code: number | undefined; reason: string };
}

export async function runScenario(scenario: Scenario, endpoint: Endpoint, opts: RunOptions): Promise<Capture> {
  const vars = new Map<string, unknown>();
  const sockets = new Map<string, SocketSession>();
  const steps: StepCapture[] = [];
  const socketFailedActors = new Set<string>();

  // Mint actor tokens once per run (volatile; masked by the normalizer).
  const nowSec = Math.floor(Date.now() / 1000);
  const tokens = new Map<string, string>();
  for (const [actorName, actor] of Object.entries(scenario.actors)) {
    tokens.set(actorName, await makeJwt(opts.jwtSecret, {
      sub: actor.userId,
      claims: actor.jwtClaims,
      exp: actor.jwtExpSeconds !== undefined ? nowSec + actor.jwtExpSeconds : undefined,
    }));
  }

  const waitMs = opts.waitTimeoutMs ?? DEFAULT_WAIT_MS;
  const origin = opts.origin ?? "https://lilium.kuma.homes";

  /** Drain all socket buffers into the current step capture. */
  const drainTo = (step: StepCapture): void => {
    for (const session of sockets.values()) {
      if (session.pending.length > 0) {
        const frames = session.pending.splice(0);
        step.wsReceived = [...(step.wsReceived ?? []), ...frames];
      }
    }
  };

  /**
   * Wait until EVERY predicate has matched some frame in `pending`. Returns
   * frames up to and including the last match, so ack+event land in one
   * window regardless of arrival order.
   */
  const waitUntilAll = async (
    actor: string,
    predicates: Array<(frame: unknown) => boolean>,
    timeoutMs: number,
  ): Promise<{ matchedFrames: unknown[]; timedOut: boolean }> => {
    const session = sockets.get(actor);
    if (!session) throw new Error(`no open socket for actor ${actor}`);
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const unmatched = new Set(predicates);
      let last = -1;
      for (let i = 0; i < session.pending.length; i++) {
        for (const p of unmatched) {
          if (p(session.pending[i])) {
            unmatched.delete(p);
            last = i;
            break;
          }
        }
        if (unmatched.size === 0) {
          return { matchedFrames: session.pending.splice(0, last + 1), timedOut: false };
        }
      }
      await new Promise((r) => setTimeout(r, 25));
    }
    return { matchedFrames: session.pending.splice(0), timedOut: true };
  };

  const openSocket = async (actor: string): Promise<SocketSession> => {
    const token = tokens.get(actor);
    if (!token) throw new Error(`no token for actor ${actor}`);
    const pending: unknown[] = [];
    const ws = new CapturingWebSocket({
      url: `${endpoint.wsBase}/api/chat/ws`,
      protocols: ["lilium.chat.v2", `bearer.${token}`],
      headers: { Origin: origin },
      onFrame: (frame) => pending.push(frame),
      onClose: (code, reason) => {
        const s = sockets.get(actor);
        if (s) s.closedInfo = { code, reason };
      },
    });
    await ws.ready();
    const session: SocketSession = { ws, pending };
    sockets.set(actor, session);
    return session;
  };

  for (let i = 0; i < scenario.steps.length; i++) {
    const rawStep = scenario.steps[i];
    if (!rawStep) continue;
    const stepDef = rawStep;
    const step: StepCapture = {
      index: i,
      kind: stepDef.kind,
      name: stepDef.name ?? `${stepDef.kind}#${i}`,
      actor: stepDef.actor,
    };

    try {
      switch (stepDef.kind) {
        case "http": {
          const probe = stepDef.readProbe ? opts.readProbe ?? null : null;
          if (probe) await probe.beginRead(stepDef.readProbe!.maxQueries);
          const done = await runHttpStep(stepDef, step, endpoint, vars, tokens, origin);
          if (probe) {
            step.readObservation = await probe.endRead();
          }
          if (!done) break; // missing var — recorded as error
          break;
        }
        case "ws.connect": {
          const session = await openSocket(stepDef.actor);
          step.meta = { negotiated_protocol: session.ws.negotiatedProtocol };
          break;
        }
        case "ws.command": {
          if (socketFailedActors.has(stepDef.actor) || !sockets.has(stepDef.actor)) {
            step.error = "no open socket for actor";
            break;
          }
          const frame = interpolateDeep(stepDef.frame, vars);
          sockets.get(stepDef.actor)!.ws.send(frame);
          step.wsSent = [frame];
          const predicates: Array<(f: unknown) => boolean> = [(f) => stepDef.waitFor(f, { vars })];
          if (stepDef.alsoUntil) predicates.push((f) => stepDef.alsoUntil!(f, { vars }));
          const { matchedFrames, timedOut } = await waitUntilAll(
            stepDef.actor,
            predicates,
            stepDef.waitTimeoutMs ?? waitMs,
          );
          step.wsReceived = matchedFrames;
          if (timedOut) {
            step.error = `timeout waiting for ack${stepDef.alsoUntil ? "+fanout" : ""} after ${stepDef.waitTimeoutMs ?? waitMs}ms`;
          }
          break;
        }
        case "ws.event": {
          if (socketFailedActors.has(stepDef.actor) || !sockets.has(stepDef.actor)) {
            step.error = "no open socket for actor";
            break;
          }
          const { matchedFrames, timedOut } = await waitUntilAll(
            stepDef.actor,
            [(f) => stepDef.until(f, { vars })],
            stepDef.timeoutMs ?? waitMs,
          );
          step.wsReceived = matchedFrames;
          if (timedOut) {
            step.error = `timeout waiting for event after ${stepDef.timeoutMs ?? waitMs}ms`;
          } else if (stepDef.capture) {
            const matched = matchedFrames.find((f) => stepDef.until!(f, { vars }));
            for (const [varName, pointer] of Object.entries(stepDef.capture)) {
              const value = jsonPointer(matched, pointer);
              if (value !== undefined) vars.set(varName, value);
            }
          }
          break;
        }
        case "ws.close": {
          const session = sockets.get(stepDef.actor);
          if (session) {
            session.ws.close();
            step.meta = session.closedInfo ? { close: session.closedInfo } : {};
            sockets.delete(stepDef.actor);
          } else {
            step.error = "no open socket for actor";
          }
          break;
        }
        case "wait": {
          await new Promise((r) => setTimeout(r, stepDef.ms));
          break;
        }
      }
    } catch (err) {
      step.error = err instanceof Error ? err.message : String(err);
      if (stepDef.kind === "ws.connect") socketFailedActors.add(stepDef.actor);
    }

    // Settle before draining so both targets capture the same fanout union in
    // the same step (see SETTLE_MS). `wait` steps already provide the window;
    // connect/close produce no pending frames.
    if (
      stepDef.kind === "http" ||
      stepDef.kind === "ws.command" ||
      stepDef.kind === "ws.event"
    ) {
      await new Promise((r) => setTimeout(r, SETTLE_MS));
    }
    drainTo(step);
    steps.push(step);

    // If a ws.connect failed, later ws steps for that actor are recorded as skipped.
    if (step.error && stepDef.kind === "ws.connect") {
      socketFailedActors.add(stepDef.actor);
    }
  }

  // Final drain: give late frames a short window so both targets are treated alike.
  await new Promise((r) => setTimeout(r, 500));
  const finalDrain: StepCapture = { index: scenario.steps.length, kind: "drain", name: "__final_drain", actor: "*" };
  drainTo(finalDrain);
  if (finalDrain.wsReceived && finalDrain.wsReceived.length > 0) steps.push(finalDrain);

  for (const session of sockets.values()) session.ws.close();

  return { scenario: scenario.name, target: endpoint.name, capturedAt: new Date().toISOString(), steps };
}

async function runHttpStep(
  stepDef: HttpStep,
  step: StepCapture,
  endpoint: Endpoint,
  vars: Map<string, unknown>,
  tokens: Map<string, string>,
  origin: string,
): Promise<boolean> {
  if (stepDef.body !== undefined && stepDef.base64Body !== undefined) {
    step.error = "http step: `body` and `base64Body` are mutually exclusive";
    return false;
  }
  let path: string;
  let body: unknown;
  let headers: Record<string, string>;
  try {
    path = interpolateString(stepDef.path, vars);
    body = stepDef.body === undefined ? undefined : interpolateDeep(stepDef.body, vars);
    const rawHeaders = stepDef.headers ?? {};
    // `null` value = header explicitly omitted (e.g. Authorization: null).
    headers = Object.fromEntries(
      Object.entries(rawHeaders)
        .filter(([, v]) => v !== null)
        .map(([k, v]) => [k, interpolateString(v as string, vars)]),
    );
    const authExplicit = "Authorization" in rawHeaders || "authorization" in rawHeaders;
    const token = tokens.get(stepDef.actor);
    if (token && !authExplicit) {
      headers.Authorization = `Bearer ${token}`;
    }
    if (!headers.Origin && !headers.origin) headers.Origin = origin;
  } catch (err) {
    step.error = err instanceof Error ? err.message : String(err);
    return false;
  }

  // Capture the base64 string itself for binary bodies — a static scenario
  // literal, deterministic across targets (the decoded bytes are volatile-
  // free by construction).
  const capturedBody = stepDef.base64Body !== undefined ? stepDef.base64Body : body;

  const attempt = async (): Promise<HttpResponseCapture> => {
    const { response, requestHeaders } = await httpCapture(
      endpoint,
      stepDef.method,
      path,
      headers,
      body,
      stepDef.absolute === true,
      stepDef.base64Body,
    );
    if (!step.http) {
      step.http = {
        request: { method: stepDef.method, path, headers: requestHeaders, body: capturedBody },
        response,
      };
    } else {
      step.http.response = response; // retryUntil: keep final response only
    }
    return response;
  };

  try {
    let response = await attempt();
    if (stepDef.retryUntil) {
      const maxAttempts = stepDef.maxAttempts ?? DEFAULT_MAX_ATTEMPTS;
      for (let n = 2; n <= maxAttempts && !stepDef.retryUntil(response, { vars }); n++) {
        await new Promise((r) => setTimeout(r, RETRY_INTERVAL_MS));
        response = await attempt();
      }
      if (!stepDef.retryUntil(response, { vars })) {
        step.error = `retryUntil: predicate not satisfied after ${maxAttempts} attempts`;
      }
    }
  } catch (err) {
    step.error = `transport error: ${err instanceof Error ? err.message : String(err)}`;
    return true; // transport failure recorded; later steps may still be independent
  }

  if (stepDef.capture && !step.error) {
    for (const [varName, pointer] of Object.entries(stepDef.capture)) {
      const value = jsonPointer(step.http!.response.body, pointer);
      if (value === undefined) {
        step.error = `capture: pointer ${pointer} not found in response body`;
        break;
      }
      vars.set(varName, value);
    }
  }
  return true;
}
