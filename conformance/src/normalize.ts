/**
 * Volatile-field normalization (spec §7.2).
 *
 * Instead of whitelisting fields to ignore, we REPLACE volatile values with
 * placeholders before diffing:
 *   - server-generated UUIDs            → `{{UUID}}`
 *   - ISO-8601 / HTTP-date timestamps   → `{{TS}}`
 *   - `req_<uuidv7>` request ids        → `req_{{UUID}}`
 *   - `Authorization: Bearer <jwt>`     → `{{JWT}}` (header values only)
 *
 * TRANSPORT-level response headers are dropped from BOTH captures before
 * diffing — they are HTTP/1.1 framing / server-framework details, not API
 * contract (miniflare vs Bandit legitimately differ):
 *   - cache-control, content-length, date, transfer-encoding → removed
 *   - vary → `accept-encoding` component dropped (gzip capability), the rest
 *     compared case-insensitively as a sorted set (CORS-relevant parts stay)
 *
 * Client-generated ids (command_id, Idempotency-Key, actor user ids, and any
 * other UUID literals written in the scenario script itself) are NOT
 * normalized: they are deterministic inputs that both targets must echo
 * identically, so a mismatch there is a real diff, not noise.
 */

import type { Capture, StepCapture } from "./types.js";

/** Any RFC-4122-shaped UUID (v1–v8), case-insensitive. */
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** ISO-8601 timestamp with explicit UTC designator (contract §2.3 uses `Z`). */
const ISO_TS_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/;

/** RFC-7231 HTTP-date, e.g. `Date: Wed, 21 Aug 2026 05:30:00 GMT`. */
const HTTP_DATE_RE =
  /^(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun),\s+\d{2}\s+(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+\d{4}\s+\d{2}:\d{2}:\d{2}\s+GMT$/i;

/** `req_<uuidv7>` — contract §2.6 / errors.ts request id shape. */
const REQUEST_ID_RE = /^req_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** `Bearer <token>` — masked only in header values. */
const BEARER_RE = /^Bearer\s+\S+$/i;

/** UUIDs embedded in larger strings (query params, opaque cursors, …). */
const UUID_EMBEDDED_RE = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi;

export interface NormalizeOptions {
  /**
   * Client-generated ids that must survive normalization (lower-cased).
   * Collected by the runner from the scenario script: command_ids,
   * Idempotency-Key values, actor user ids, and UUID literals present in the
   * scenario BEFORE `${var}` interpolation.
   */
  knownClientIds?: ReadonlySet<string>;
}

export const PLACEHOLDER_UUID = "{{UUID}}";
export const PLACEHOLDER_TS = "{{TS}}";
export const PLACEHOLDER_JWT = "{{JWT}}";
export const PLACEHOLDER_REQUEST_ID = "req_{{UUID}}";

function isKnownClientId(value: string, opts: NormalizeOptions): boolean {
  return opts.knownClientIds?.has(value.toLowerCase()) ?? false;
}

/**
 * Normalize a single string value. Header context enables JWT masking.
 * Whole-string rules first (request id / bare UUID / timestamps); as a
 * fallback, UUIDs EMBEDDED in larger strings (query params, opaque cursors)
 * are replaced in place — known client ids survive.
 */
export function normalizeString(
  value: string,
  opts: NormalizeOptions,
  context: "header" | "body",
): string {
  if (context === "header" && BEARER_RE.test(value)) return PLACEHOLDER_JWT;
  const trimmed = value.trim();
  if (REQUEST_ID_RE.test(trimmed)) return PLACEHOLDER_REQUEST_ID;
  if (UUID_RE.test(trimmed)) {
    return isKnownClientId(trimmed, opts) ? value : PLACEHOLDER_UUID;
  }
  if (ISO_TS_RE.test(trimmed) || HTTP_DATE_RE.test(trimmed)) return PLACEHOLDER_TS;
  if (UUID_EMBEDDED_RE.test(value)) {
    UUID_EMBEDDED_RE.lastIndex = 0;
    return value.replace(UUID_EMBEDDED_RE, (m) => (isKnownClientId(m, opts) ? m : PLACEHOLDER_UUID));
  }
  return value;
}

function normalizeDeep(
  value: unknown,
  opts: NormalizeOptions,
  context: "header" | "body",
): unknown {
  if (typeof value === "string") return normalizeString(value, opts, context);
  if (Array.isArray(value)) return value.map((v) => normalizeDeep(v, opts, context));
  if (value !== null && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const [key, v] of Object.entries(value as Record<string, unknown>)) {
      // Object KEYS can be server-minted ids too (e.g. event_state.per_channel
      // is keyed by channel_id). Normalize them; disambiguate collisions in
      // encounter order so two same-sized maps keep diffable key sets.
      const normKey = normalizeString(key, opts, context);
      let finalKey = normKey;
      let n = 2;
      while (finalKey in out) finalKey = `${normKey}#${n++}`;
      out[finalKey] = normalizeDeep(v, opts, context);
    }
    return out;
  }
  return value;
}

/** HTTP/1.1 framing / server-framework headers — not API contract (see module doc). */
const TRANSPORT_HEADERS = new Set(["cache-control", "content-length", "date", "transfer-encoding"]);

/**
 * `Vary` normalization: drop the `accept-encoding` component (gzip capability
 * differs per server), compare the rest case-insensitively as a sorted set so
 * header order never diffs. CORS-relevant components (e.g. `origin`) survive.
 */
function normalizeVary(value: string): string {
  return value
    .split(",")
    .map((s) => s.trim().toLowerCase())
    .filter((s) => s.length > 0 && s !== "accept-encoding")
    .sort()
    .join(", ");
}

/** Normalize a RESPONSE header map: transport headers dropped, vary canonicalized. */
function normalizeResponseHeaders(
  headers: Record<string, string>,
  opts: NormalizeOptions,
): Record<string, string> {
  const normalized = normalizeDeep(headers, opts, "header") as Record<string, string>;
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(normalized)) {
    if (TRANSPORT_HEADERS.has(k)) continue;
    out[k] = k === "vary" ? normalizeVary(v) : v;
  }
  return out;
}

/** Normalize one capture: header maps get header context, bodies get body context. */
export function normalizeCapture(capture: Capture, opts: NormalizeOptions = {}): Capture {
  const steps = capture.steps.map((step) => {
    const next: Record<string, unknown> = { ...step };
    if (step.http) {
      next.http = {
        request: {
          method: step.http.request.method,
          path: normalizeString(step.http.request.path, opts, "body") as string,
          headers: normalizeDeep(step.http.request.headers, opts, "header") as Record<string, string>,
          body: step.http.request.body === undefined ? undefined : normalizeDeep(step.http.request.body, opts, "body"),
        },
        response: {
          status: step.http.response.status,
          headers: normalizeResponseHeaders(step.http.response.headers, opts),
          body: normalizeDeep(step.http.response.body, opts, "body"),
        },
      };
    }
    if (step.wsSent !== undefined) {
      next.wsSent = step.wsSent.map((f) => normalizeDeep(f, opts, "body"));
    }
    if (step.wsReceived !== undefined) {
      next.wsReceived = step.wsReceived.map((f) => normalizeDeep(f, opts, "body"));
    }
    return next as unknown as StepCapture;
  });
  return {
    scenario: capture.scenario,
    target: capture.target,
    capturedAt: normalizeString(capture.capturedAt, opts, "body") as string,
    steps,
  };
}
