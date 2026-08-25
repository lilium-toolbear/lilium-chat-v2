/**
 * Volatile-field normalization (spec §7.2).
 *
 * Instead of whitelisting fields to ignore, we REPLACE volatile values with
 * placeholders before diffing:
 *   - server-generated UUIDs            → `{{UUID}}`
 *   - ISO-8601 / HTTP-date timestamps   → `{{TS}}`
 *   - `req_<uuidv7>` request ids        → `req_{{UUID}}`
 *   - `Bearer <token>`                 → `{{JWT}}` (header values only)
 *
 * S3 / object-store fields (contract §8.1/§8.2, issue #27 batch B):
 *   - presigned `upload_url`           → host kept, path → `{{S3_OBJECT_PATH}}`,
 *     `X-Amz-Date` → `{{TS}}`, credential date → `{{TS}}`,
 *     `X-Amz-Signature` → `{{S3_SIGNATURE}}`, query sorted;
 *     algorithm / expires / signed-headers / credential scope COMPARED
 *   - public attachment `url`          → `{{S3_OBJECT_URL}}`
 *
 * Contract-delta normalizations (each cited; the contract is the SSOT):
 *   - `IDEMPOTENCY_CONFLICT` `message` → the unified v2.31 wording
 *     (contract §2.5 v2.31 delta note: old Worker varies per operation,
 *     "conformance 差分对 message 归一化（#27）")
 *   - `POST /api/chat/channels` response: the response is `{ channel,
 *     membership }` (contract §5.2b). The old Worker instead returns a
 *     TOP-LEVEL `joined_at` and no `membership` — synthesize
 *     `membership = { role: "owner", joined_at }` (creator is always owner,
 *     §5.2b) and drop the legacy top-level field.
 *   - `last_event_id` / `last_read_event_id` → `{{EVENT_ID}}` (any value,
 *     including null). Contract §3.2: per-channel monotonic UUIDv7 cursor —
 *     server-minted, not reproducible across targets. Old-Worker delta: the
 *     channel LIST route hardcodes `null` (lilium-chat
 *     src/chat/channel-list.ts `last_event_id: null`), while the Elixir
 *     implementation returns the real last event id (the contract-correct
 *     value).
 *   - ChannelSummary items (channels list / bootstrap `channels[]`): the
 *     legacy `topic` / `created_at` / `updated_at` fields are dropped from
 *     both sides. Contract §3.2 ChannelSummary is exactly 13 fields — those
 *     three are §3.3 ChannelDetail fields that the old Worker (and, for the
 *     list, the Elixir implementation) additionally emit.
 *   - Bootstrap `active_channel`: the legacy `unread_count` /
 *     `last_read_event_id` / `last_message_preview` / `last_message_at` /
 *     `last_event_id` fields are dropped from both sides. Contract §4.1
 *     defines `active_channel` as the 11-field ChannelDetail shape; the old
 *     Worker returns a full ChannelSummary there.
 *   - Event frames / event list items (WS `wsReceived`, `events[]`,
 *     messages-list event items, bootstrap `messages.items`):
 *       * `payload.channel_id` / `payload.event_id` are dropped from
 *         message-lifecycle event payloads on BOTH sides. Contract §10.4:
 *         the `message.*` event payload is `{ channel_id, event_id, message }`
 *         (Elixir conforms); the old Worker omits those two payload keys —
 *         recorded old-Worker delta.
 *       * `system.notice` frames are dropped from event lists on BOTH sides.
 *         Contract §5.2b requires a `system.notice` (`notice_kind =
 *         "channel.created"`) per channel create and §10.4 lists the type;
 *         the old Worker emits NO `system.notice` at all (delta) — without
 *         the drop the event lists differ structurally (extra rows).
 *   - `FORBIDDEN` error message on `GET /channels/{id}` →
 *     `"not a channel member"`. Contract §2.6 shows that exact envelope
 *     wording for FORBIDDEN; the old Worker says "not a member" (delta),
 *     the v2 implementation previously said "Forbidden" (fixed in lib).
 *   - `invite_code` (response values) and `/api/chat/invites/<code>` request
 *     paths → `{{INVITE_CODE}}`. Contract §5.8: the invite code is a
 *     server-minted channel-level credential ("邀请码原文只返回一次") — not
 *     reproducible across targets.
 *
 *   Issue #27 batch B (member / invite / join / DM scenarios):
 *   - Channel-list `items` (GET /channels) and bootstrap `channels[]` are
 *     SORTED on both sides by (kind, title, dm_peer user_id). Contract §5.1
 *     pins only the `{items, next_cursor}` shape — no ordering; the old
 *     Worker returns `my_channels` insertion order (no ORDER BY), the v2
 *     implementation returns `updated_at DESC, channel_id DESC`. Both are
 *     implementation details; the sort key is made of scenario-deterministic
 *     values (fixed titles / fixed actor ids), so the order is stable
 *     across targets.
 *   - `invite_url` (response value) → host kept, last path segment (the
 *     invite code) → `{{INVITE_CODE}}`. Contract §5.8: `invite_url` =
 *     `API_BASE_URL + /chat/invites/<code>` — the base is identical on both
 *     targets (same configured origin), the code is server-minted.
 *   - `MEMBER_NOT_FOUND` messages, pinned per old-Worker throw site (the
 *     old Worker varies wording per route; the v2 implementation answers the
 *     generic "Member not found" everywhere):
 *       * `GET .../members/{user_id}` (show) → `"user is not a member of this
 *         channel"`;
 *       * `PATCH .../members/{user_id}` (role), `DELETE .../members/{user_id}`
 *         (remove), `POST .../owner-transfer` → `"target not an active member"`.
 *     Contract §7.1b–§7.5 pin the code (404) but not the wording; §2.5 v2.31
 *     delta note licenses the message normalization.
 *   - `CHANNEL_NOT_FOUND` messages on the member READ routes (list / show)
 *     → `"channel not created"` (the old Worker's read-route wording).
 *   - `CHANNEL_NOT_FOUND` on the join route → `"channel not found"` (the old
 *     Worker's join-route wording). Contract §5.7 pins the code (404), not
 *     the wording; the v2 implementation answers "Channel not found"
 *     everywhere (§2.5 v2.31 delta note).
 *   - `FORBIDDEN` messages on the member READ routes (list / show) →
 *     `"not a channel member"` (contract §2.6 envelope wording, same rule as
 *     channel detail; the old Worker says "not a member" on these routes,
 *     the v2 implementation "Forbidden").
 *   - BotTokenCreated `plaintext` → `{{BOT_TOKEN}}`. Contract §9 (Bot create):
 *     `{ token_id, name, scopes, plaintext, created_at, expires_at }` —
 *     "`plaintext` 只返回一次": server-minted, opaque, not reproducible
 *     across targets.
 *   - Bootstrap `event_state.per_channel` → `{}` on both sides. Contract §4.1:
 *     the map is `{ channel_id: last_event_id }` — keys and values are
 *     server-minted UUIDv7, and the target sets differ by design: the old
 *     Worker's list rows hardcode `last_event_id: null` (known delta — its
 *     per_channel injects only the active NON-DM channel's cursor from the
 *     read bundle; a DM active channel gets none), while the v2 implementation
 *     populates the map for every listed channel (the contract-correct
 *     reading: "每个 channel_summary 项也带自身 last_event_id，二者一致").
 *     Same family as the `last_event_id` normalization above.
 *
 *   Issue #27 batch C (message write path):
 *   - `system.notice` frames are also dropped from WS fanout captures
 *     (`wsReceived`) on BOTH sides. Contract §6.5: an admin/owner delete of a
 *     FOREIGN message emits an optional `system.notice` — the Elixir
 *     implementation broadcasts it as a fanout frame, the old Worker emits no
 *     such frame (same delta family as the event-list drop above; the
 *     contract marks the notice optional: "可选").
 *   - `GET /channels/{id}` (channel detail) `channel` object: the legacy
 *     `last_message_preview` / `last_message_at` fields are dropped from both
 *     sides. Contract §3.3 ChannelDetail is 11 fields and has no such keys —
 *     they are §3.2 ChannelSummary denormalizations that both targets emit on
 *     the detail read with DIFFERENT formats (old Worker: raw text / "" when
 *     empty; v2: "display name: text" per the §3.2 example). Same family as
 *     the §4.1 `active_channel` trim above.
 *   - `ChannelPin.pinned_by` (contract §3.10.3): the `display_name` of the
 *     pin's `pinned_by` UserSummary is placeholdered to `{{PINNED_BY_NAME}}`
 *     on both sides. The old Worker resolves `pinned_by` with a FALLBACK
 *     display name (`user-<id-prefix>`) on the channel-detail read, the
 *     pin-event fanout frames, and the event-replay read, while the v2
 *     implementation resolves the LIVE profile on all three (the initial pin
 *     ack/event resolve the live profile on BOTH targets). The contract fixes
 *     the UserSummary shape but not the resolution source, so only the
 *     display name is placeholdered; `user_id` / `avatar_url` remain compared.
 *
 *   Issue #27 batch D (bot domain — HTTP + Bot Gateway WS + Bot Stream WS):
 *   - `GET /api/chat/commands/directory` `items` (contract §9.12.1): SORTED
 *     on both sides by (bot_command_id, name). §9.12.1 pins the
 *     `{ items, next_cursor }` shape but not the item order. Both
 *     implementations ORDER BY `updated_at DESC, bot_command_id DESC`, but
 *     catalog sync mints every command with ONE shared timestamp, so
 *     `updated_at` ties and the ORDER BY falls through to the RANDOM TAILS
 *     of the server-minted UUIDv7 ids — which differ per target (each DB
 *     mints its own), so the item order is a per-target coin flip (the
 *     bot-http directory steps flipped ask/ponder order across runs). The
 *     sort runs AFTER the deep value pass, when `bot_command_id` is already
 *     `{{UUID}}`, so the key reduces to the scenario-deterministic command
 *     name. Same family as the batch B channel-list sort.
 *   - `ws_url` (the `start_stream` effect result `stream.ws_url`, contract
 *     §9.7.3) → `ws://{{HOST}}<path>`: the host is a deployment detail
 *     (each target builds the URL from its own listen address —
 *     127.0.0.1:8791 vs 127.0.0.1:4000); the path's channel/message UUIDs
 *     go through the embedded-UUID rule and stay comparable.
 *   - `delivery` frames, kind `command_invocation` (contract §9.7.1): the
 *     body the old Worker queues is `{delivery_type, invocation_id,
 *     bot_command: {…no options…}, invoker, options, reply_to?}` while the
 *     contract shows `{invocation_id, command: {…options…}, invoker}` (the
 *     v2 implementation conforms). Both sides are aligned to the contract
 *     shape: `command` := `bot_command` (with the old Worker's top-level
 *     `options` merged in), then `bot_command` / `delivery_type` / top-level
 *     `options` / `reply_to` are dropped.
 *   - `command.invoke` `command_ack` payload (contract §9.5): the old Worker
 *     additionally returns an `invocation_message` projection; the contract
 *     ack payload is `{channel_id, invocation_id, event_id}`. Dropped from
 *     both sides (the invocation message itself is still compared through
 *     its own `message.created` fanout frame on both targets).
 *   - `command.invoked` event frames — LIVE fanout AND replay reads
 *     (GET events / messages timeline / bootstrap), both sides (contract
 *     §9.5 live example / §9.6.2 storage rule): the old Worker persists AND
 *     emits the subset payload `{invocation, command_id}`; the v2
 *     implementation carries the full wire payload
 *     (`+ command_name + invoked_name + actor`). The contract §9.6.2
 *     storage rule keeps stable ids only (replay re-projects display
 *     fields live), so `payload.command_name` / `payload.invoked_name` /
 *     `payload.actor` are dropped from both sides — the `invocation`
 *     block and `command_id` stay compared.
 *   - `command_snapshot_json` (`command.binding_updated` event payload
 *     `binding_changes`, contract §9.5 binding delta): the `before` /
 *     `after` snapshot values are JSON-encoded STRINGS on the old Worker
 *     and parsed OBJECTS on the v2 implementation (the contract shows the
 *     snapshot object, not its encoding). String values are parsed to
 *     objects on both sides so the same snapshot content is compared.
 *   - `definition_hash` inside Bot Gateway frames (contract §9.7.1
 *     `delivery` body `command`, §9.7.4 `session.start` `bot_command`):
 *     `command.definition_hash` / `bot_command.definition_hash` →
 *     `{{DEF_HASH}}`. The value is a server-computed definition hash —
 *     the old Worker persists the literal fallback `snapshot:<bot_command_id>`
 *     (old `command.ts` definition_hash fallback), the v2 implementation
 *     the real sha256; the contract fixes the field, not the algorithm
 *     output.
 *
 *   - `meta.close` (WS close code, on `ws.close` steps): DROPPED from both
 *     sides. The close code is a transport detail (Cowboy vs miniflare
 *     legitimately differ) — the old Worker closes a secondary
 *     live-session browser socket gracefully (the code is not captured
 *     before the async close settles) while the v2 implementation has
 *     closed the same socket with a spurious 1002 (protocol error). The
 *     DATA (wsReceived frames / HTTP bodies) is the parity signal; the
 *     close code is not (see the 2026-08-25 batch D report, message-write).
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

/**
 * ISO-8601 timestamp (contract §2.3 — "所有时间字段使用 ISO 8601 UTC 字符串",
 * example `2026-06-21T05:30:00Z`). The designator is OPTIONAL in the pattern:
 * the Elixir implementation used to emit UTC without a designator
 * (`DateTime.to_iso8601` / naive-UTC rendering, e.g.
 * `2026-08-25T07:55:23.132583`) — fixed in lib to append `Z`, but the
 * normalization stays permissive so a raw UTC wall time is still `{{TS}}`
 * and never diffs as a literal.
 */
const ISO_TS_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})?$/;

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
/** Per-channel event cursor (`last_event_id` / `last_read_event_id`, §3.2). */
export const PLACEHOLDER_EVENT_ID = "{{EVENT_ID}}";
/** Server-minted invite credential (§5.8). */
export const PLACEHOLDER_INVITE_CODE = "{{INVITE_CODE}}";
/** Server-minted bot token plaintext (BotTokenCreated, "只返回一次"). */
export const PLACEHOLDER_BOT_TOKEN = "{{BOT_TOKEN}}";
/**
 * Denormalized `UserSummary.display_name` under a pin's `pinned_by` (contract
 * §3.10.3). The old Worker resolves it with a FALLBACK display name
 * (`user-<id-prefix>`) on the detail read, pin-event fanout, and event-replay
 * paths, while the v2 implementation resolves the LIVE profile on all of them
 * (the initial pin ack/event resolve live on BOTH). The contract pins the
 * UserSummary shape but not the resolution source → placeholder (issue #27 C).
 */
export const PLACEHOLDER_PINNED_BY_NAME = "{{PINNED_BY_NAME}}";

/**
 * WebSocket endpoint host inside a `ws_url` (contract §9.7.3 `start_stream`
 * result): each target builds the stream URL from its own listen address
 * (127.0.0.1:8791 vs 127.0.0.1:4000) — the host is deployment config, the
 * path stays compared (see module doc, issue #27 batch D).
 */
export const PLACEHOLDER_HOST = "{{HOST}}";
/**
 * Server-computed command definition hash inside Bot Gateway frames (see
 * module doc, issue #27 batch D): the old Worker persists the literal
 * `snapshot:<bot_command_id>` fallback, the v2 implementation the real
 * sha256 — the algorithm output is not compared.
 */
export const PLACEHOLDER_DEF_HASH = "{{DEF_HASH}}";
/** Presigned S3 PUT object path — see module doc (contract §8.1). */
export const PLACEHOLDER_S3_OBJECT_PATH = "{{S3_OBJECT_PATH}}";
/** Volatile SigV4 signature value (covers X-Amz-Date). */
export const PLACEHOLDER_S3_SIGNATURE = "{{S3_SIGNATURE}}";
/** Public object URL — host AND path are deployment/impl details (§8.2). */
export const PLACEHOLDER_S3_OBJECT_URL = "{{S3_OBJECT_URL}}";

/**
 * The unified v2.31 IDEMPOTENCY_CONFLICT message. Contract §2.5 (v2.31 delta
 * note, "conformance 差分对 message 归一化（#27）"): v2 implementations use
 * `idempotency key reused with different request body` for ALL operations;
 * the old Worker varies per operation (`command_id reused …`, `idempotency_key
 * reused …`, `operation_id reused …`, `Idempotency-Key reused …`). Clients
 * must key off the `code`, so the diff normalizes the message for this code.
 */
export const IDEMPOTENCY_CONFLICT_CODE = "IDEMPOTENCY_CONFLICT";
export const IDEMPOTENCY_CONFLICT_MESSAGE = "idempotency key reused with different request body";

function isKnownClientId(value: string, opts: NormalizeOptions): boolean {
  return opts.knownClientIds?.has(value.toLowerCase()) ?? false;
}

// ---------------------------------------------------------------------------
// S3 URL normalization (contract §8.1 / §8.2)
// ---------------------------------------------------------------------------

/**
 * Normalize one S3 object URL string, or return `null` when the string is not
 * an S3 object URL (and the caller should leave it untouched).
 *
 * Two shapes, per contract:
 *
 * 1. PRESIGNED PUT (contract §8.1 `upload_url` — "presigned PUT 5 分钟过期,
 *    约束 Content-Type / Content-Length"). The stable, contract-relevant
 *    parts — `X-Amz-Algorithm`, `X-Amz-Expires` (TTL), `X-Amz-SignedHeaders`
 *    (the signed header set), and the credential SCOPE (access key + region)
 *    — are compared strictly; both targets sign with the same conformance
 *    creds. Volatile parts are masked: the object PATH (key format is a
 *    documented legacy delta — contract §8.1 keys are `chat/{attachment_id}`,
 *    the old Worker stores `chat/attachments/{id}.{ext}`), `X-Amz-Date`
 *    (request timestamp) and `X-Amz-Signature` (covers the date). The
 *    HOST is kept: both targets configure the same S3_ENDPOINT, and the
 *    presigned URL must be reachable by the same browser on both sides.
 *
 * 2. PUBLIC object URL (contract §8.2 `attachment.url` — "浏览器可直接读取的
 *    长期公开附件访问 URL" and "对象存储 key 不暴露给前端"). BOTH host and
 *    path are normalized to a single placeholder: the host is
 *    deployment-config (S3_PUBLIC_BASE differs per target topology — the
 *    host-side worker target uses 127.0.0.1:8900, the Elixir container uses
 *    the compose service name) and the path is the impl-defined object key.
 *    Detection: the path's first segment is the `chat` object namespace
 *    (contract §8.1 key prefix; also covers the old Worker's
 *    `chat/attachments/…` legacy key and the `chat/avatars/…` avatar
 *    namespace).
 */
function normalizeS3Url(value: string): string | null {
  if (!/^(https?):\/\/[^\s]+$/i.test(value)) return null;
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    return null;
  }
  if (url.host.length === 0) return null;

  const segments = url.pathname.split("/").filter((s) => s.length > 0);
  if (segments.length === 0) return null;

  const query = new URLSearchParams(url.search);
  const isPresigned = query.has("X-Amz-Signature");

  if (isPresigned) {
    const sorted: string[] = [];
    for (const key of [...query.keys()].sort()) {
      let val = query.get(key) as string;
      if (key === "X-Amz-Date") {
        val = PLACEHOLDER_TS;
      } else if (key === "X-Amz-Credential") {
        // `<access_key>/<date>/<region>/s3/aws4_request` — the date is the
        // signing date (volatile); access key + region compared strictly.
        const parts = val.split("/");
        if (parts.length >= 5) parts[1] = PLACEHOLDER_TS;
        val = parts.join("/");
      } else if (key === "X-Amz-Signature") {
        val = PLACEHOLDER_S3_SIGNATURE;
      }
      sorted.push(`${encodeURIComponent(key)}=${encodeURIComponent(val)}`);
    }
    return `${url.protocol}//${url.host}${PLACEHOLDER_S3_OBJECT_PATH}?${sorted.join("&")}`;
  }

  if (segments[0] === "chat") {
    return PLACEHOLDER_S3_OBJECT_URL;
  }
  return null;
}

/** `/api/chat/invites/{invite_code}` paths (contract §5.8/§5.10). */
const INVITE_PATH_RE = /^\/api\/chat\/invites\/[0-9a-zA-Z]{1,32}(\/accept)?$/;

/**
 * `invite_url` normalization (contract §5.8): keep the host + base path, mask
 * only the final segment (the server-minted invite code).
 */
function normalizeInviteUrl(value: string): string {
  const m = /^(https?:\/\/[^\s/]+\/chat\/invites\/)[^\s/?]+/i.exec(value);
  if (m) return `${m[1]}${PLACEHOLDER_INVITE_CODE}`;
  return value;
}

function normalizeString(
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
  // §5.8: the invite code is a server-minted credential — mask it in the
  // request path (`/api/chat/invites/<code>`) so preview/accept steps diff
  // across targets despite different minted codes.
  if (context === "body" && INVITE_PATH_RE.test(trimmed)) {
    return trimmed.replace(
      INVITE_PATH_RE,
      `/api/chat/invites/${PLACEHOLDER_INVITE_CODE}$2`,
    );
  }
  // S3 object URLs (presigned upload_url / public attachment url) — body
  // context only (a presigned URL would never appear in a header).
  if (context === "body") {
    const s3 = normalizeS3Url(value);
    if (s3 !== null) return s3;
  }
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

      // Contract-delta field normalizations (see module doc):
      //
      // `last_event_id` / `last_read_event_id` (§3.2): per-channel monotonic
      // UUIDv7 cursors — server-minted, not comparable across targets. The
      // old Worker hardcodes `null` on the channel list route; the Elixir
      // implementation returns the real cursor. Both sides → placeholder.
      if (
        (key === "last_event_id" || key === "last_read_event_id") &&
        (v === null || typeof v === "string")
      ) {
        out[finalKey] = PLACEHOLDER_EVENT_ID;
        continue;
      }
      // `invite_code` (§5.8): server-minted channel-level credential.
      if (key === "invite_code" && typeof v === "string") {
        out[finalKey] = PLACEHOLDER_INVITE_CODE;
        continue;
      }
      // `plaintext` (BotTokenCreated, contract: "plaintext 只返回一次"):
      // server-minted bot token — not reproducible across targets.
      if (key === "plaintext" && typeof v === "string") {
        out[finalKey] = PLACEHOLDER_BOT_TOKEN;
        continue;
      }
      // `invite_url` (§5.8): `API_BASE_URL + /chat/invites/<code>`. The base
      // is identical on both targets (same configured origin); the code is
      // server-minted → mask only the last path segment.
      if (key === "invite_url" && typeof v === "string") {
        out[finalKey] = normalizeInviteUrl(v);
        continue;
      }
      // `ws_url` (contract §9.7.3 `start_stream` result): mask the host —
      // each target serves the stream WS from its own listen address — and
      // run the embedded-UUID pass over the rest so the path's
      // channel/message UUIDs (server-minted, differ per run) are masked and
      // the path stays comparable (see module doc, issue #27 batch D).
      if (key === "ws_url" && typeof v === "string") {
        const hostMasked = v.replace(/^(wss?:\/\/)[^\s/]+/i, `$1${PLACEHOLDER_HOST}`);
        out[finalKey] = normalizeString(hostMasked, opts, context);
        continue;
      }
      // `command_snapshot_json` (command.binding_updated payload
      // `binding_changes`, issue #27 D — see module doc): the old Worker
      // stores the `before` / `after` snapshots as JSON-encoded STRINGS,
      // the v2 implementation as parsed OBJECTS. Parse strings to objects
      // (recursively normalized — the embedded UUIDs get masked) so both
      // sides compare as the same structural snapshot.
      if (key === "command_snapshot_json" && v !== null && typeof v === "object" && !Array.isArray(v)) {
        const snapshot: Record<string, unknown> = {};
        for (const [innerKey, innerValue] of Object.entries(v as Record<string, unknown>)) {
          if (typeof innerValue === "string") {
            try {
              snapshot[innerKey] = normalizeDeep(JSON.parse(innerValue), opts, context);
              continue;
            } catch {
              // not JSON (e.g. "null") — compare as-is
            }
          }
          snapshot[innerKey] = normalizeDeep(innerValue, opts, context);
        }
        out[finalKey] = snapshot;
        continue;
      }
      // `pinned_by` (ChannelPin, contract §3.10.3): denormalized UserSummary.
      // The old Worker resolves it with a FALLBACK display name on the detail
      // read, pin-event fanout, and event-replay paths; the v2 implementation
      // resolves the LIVE profile on all of them (the initial pin ack/event
      // resolve live on BOTH). Resolution source is contract-silent →
      // placeholder the display name; user_id / avatar_url stay comparable.
      if (key === "pinned_by" && v !== null && typeof v === "object" && !Array.isArray(v)) {
        const userOut: Record<string, unknown> = {};
        for (const [uk, uv] of Object.entries(v as Record<string, unknown>)) {
          userOut[uk] = uk === "display_name"
            ? PLACEHOLDER_PINNED_BY_NAME
            : normalizeDeep(uv, opts, context);
        }
        out[finalKey] = userOut;
        continue;
      }

      out[finalKey] = normalizeDeep(v, opts, context);
    }
    return out;
  }
  return value;
}

// ---------------------------------------------------------------------------
// Contract-delta normalizations (cited above in the module doc)
// ---------------------------------------------------------------------------

/**
 * Unify `IDEMPOTENCY_CONFLICT` messages (contract §2.5 v2.31 delta, #27).
 * Applied to any object tree that carries an `error` member (HTTP response
 * bodies, WS frames): when `error.code === "IDEMPOTENCY_CONFLICT"` the
 * message is replaced with the unified v2.31 wording. The old Worker's
 * per-operation wordings all normalize to the same string; the v2
 * implementation already matches it.
 */
function normalizeIdempotencyConflict(value: unknown): unknown {
  if (Array.isArray(value)) return value.map((v) => normalizeIdempotencyConflict(v));
  if (value !== null && typeof value === "object") {
    const record = value as Record<string, unknown>;
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(record)) {
      out[k] = normalizeIdempotencyConflict(v);
    }
    const err = out["error"];
    if (
      err !== null &&
      typeof err === "object" &&
      (err as Record<string, unknown>)["code"] === IDEMPOTENCY_CONFLICT_CODE
    ) {
      (err as Record<string, unknown>)["message"] = IDEMPOTENCY_CONFLICT_MESSAGE;
    }
    return out;
  }
  return value;
}

/**
 * `POST /api/chat/channels` (contract §5.2b): the response is
 * `{ channel, membership: { role, joined_at } }`. The old Worker instead
 * returns a TOP-LEVEL `joined_at` and no `membership` object. The creator is
 * always `owner` (§5.2b: "创建者自动成为 owner"), so synthesize
 * `membership = { role: "owner", joined_at }` from the legacy field and drop
 * the top-level one, aligning the Worker with the contract shape the Elixir
 * implementation already emits. (For a response that already carries
 * `membership` — the Elixir side — only the legacy top-level drop applies,
 * which is a no-op.)
 */
function normalizeChannelCreateBody(body: unknown): unknown {
  if (body !== null && typeof body === "object" && !Array.isArray(body)) {
    const record = body as Record<string, unknown>;
    if (Object.hasOwn(record, "joined_at")) {
      const { joined_at: legacyJoinedAt, membership, ...rest } = record;
      const out: Record<string, unknown> = { ...rest };
      out["membership"] =
        membership ?? { role: "owner", joined_at: legacyJoinedAt };
      return out;
    }
  }
  return body;
}

/**
 * ChannelSummary trim (contract §3.2): the 13-field ChannelSummary has no
 * `topic` / `created_at` / `updated_at` (those are §3.3 ChannelDetail fields).
 * Both targets emit them on the channels list + bootstrap `channels[]`; drop
 * from both so the summary shape is compared as the contract defines it.
 *
 * `last_message_preview` / `last_message_at` are also dropped from bootstrap
 * summaries: they are read-model denormalizations whose nullness is
 * implementation-dependent — the old Worker's bootstrap projection (directory
 * style, §5.6 note: "`last_message_preview=null` … 留待 future plan 回填";
 * §3428 "last_message_preview text — Deferred") leaves them null while the
 * Elixir bootstrap computes real values from the shared DB.
 */
function trimChannelSummaryItem(value: unknown): unknown {
  if (value !== null && typeof value === "object" && !Array.isArray(value)) {
    const record = value as Record<string, unknown>;
    if ("channel_id" in record && "kind" in record && "title" in record) {
      const {
        topic: _t,
        created_at: _c,
        updated_at: _u,
        last_message_preview: _p,
        last_message_at: _a,
        ...rest
      } = record;
      return rest;
    }
  }
  return value;
}

/**
 * Bootstrap `active_channel` trim (contract §4.1): `active_channel` is the
 * 11-field ChannelDetail shape — no `unread_count` / `last_read_event_id` /
 * `last_message_preview` / `last_message_at` / `last_event_id`. The old Worker
 * returns a full ChannelSummary there; drop the extras from both sides.
 */
const ACTIVE_CHANNEL_EXTRA_FIELDS = [
  "unread_count",
  "last_read_event_id",
  "last_message_preview",
  "last_message_at",
  "last_event_id",
];

function trimActiveChannel(value: unknown): unknown {
  if (value !== null && typeof value === "object" && !Array.isArray(value)) {
    const record = value as Record<string, unknown>;
    for (const field of ACTIVE_CHANNEL_EXTRA_FIELDS) {
      delete record[field];
    }
  }
  return value;
}

/**
 * Channel-detail `channel` trim (contract §3.3, issue #27 batch C): the
 * `GET /channels/{id}` `channel` object is the 11-field ChannelDetail shape —
 * it has NO `last_message_preview` / `last_message_at` (those are §3.2
 * ChannelSummary denormalizations). Both targets emit them on the detail read
 * with DIFFERENT formats (old Worker: raw message text, "" when empty; v2:
 * "display name: text" per the §3.2 example), so compare with the preview
 * dropped from both sides. Same family as the §4.1 `active_channel` trim.
 */
const CHANNEL_DETAIL_EXTRA_FIELDS = ["last_message_preview", "last_message_at"];

function trimChannelDetailBody(body: unknown): unknown {
  if (body !== null && typeof body === "object" && !Array.isArray(body)) {
    const record = body as Record<string, unknown>;
    const channel = record["channel"];
    if (channel !== null && typeof channel === "object" && !Array.isArray(channel)) {
      const ch = channel as Record<string, unknown>;
      for (const field of CHANNEL_DETAIL_EXTRA_FIELDS) {
        delete ch[field];
      }
    }
  }
  return body;
}

/**
 * Sort key for ChannelSummary lists (see module doc, issue #27 batch B):
 * (kind, title, dm_peer user_id) — all scenario-deterministic values, so the
 * resulting order is identical on both targets despite different server-side
 * orderings (old Worker: my_channels insertion order; v2: updated_at DESC).
 */
function channelSummarySortKey(item: unknown): [string, string, string] {
  if (item !== null && typeof item === "object") {
    const record = item as Record<string, unknown>;
    const kind = typeof record["kind"] === "string" ? record["kind"] : "";
    const title = typeof record["title"] === "string" ? record["title"] : "";
    const peer = record["dm_peer"];
    const peerId =
      peer !== null &&
      typeof peer === "object" &&
      typeof (peer as Record<string, unknown>)["user_id"] === "string"
        ? ((peer as Record<string, unknown>)["user_id"] as string)
        : "";
    return [kind, title, peerId];
  }
  return ["", "", ""];
}

function compareChannelSummaries(a: unknown, b: unknown): number {
  const ka = channelSummarySortKey(a);
  const kb = channelSummarySortKey(b);
  const pairs: Array<[string, string]> = [
    [ka[0] ?? "", kb[0] ?? ""],
    [ka[1] ?? "", kb[1] ?? ""],
    [ka[2] ?? "", kb[2] ?? ""],
  ];
  for (const [x, y] of pairs) {
    if (x < y) return -1;
    if (x > y) return 1;
  }
  return 0;
}

function trimAndSortChannelList(list: unknown[]): unknown[] {
  return list.map((item) => trimChannelSummaryItem(item)).sort(compareChannelSummaries);
}

/**
 * Apply the ChannelSummary trim to a list endpoint's `items[]` or the
 * bootstrap response's `channels[]`, plus the §4.1 `active_channel` trim for
 * the bootstrap response. ChannelSummary lists are also sorted (see module
 * doc — contract §5.1 pins no ordering).
 */
function trimListedChannelSummaries(body: unknown, path: string): unknown {
  if (body === null || typeof body !== "object" || Array.isArray(body)) return body;
  const record = body as Record<string, unknown>;
  if (Array.isArray(record["items"])) {
    record["items"] = trimAndSortChannelList(record["items"] as unknown[]);
  }
  if (path === "/api/chat/bootstrap") {
    if (Array.isArray(record["channels"])) {
      record["channels"] = trimAndSortChannelList(record["channels"] as unknown[]);
    }
    if (record["active_channel"] !== undefined) {
      record["active_channel"] = trimActiveChannel(record["active_channel"]);
    }
    // §4.1 event_state.per_channel — see module doc (server-minted cursor
    // map; target sets differ by design, old-Worker delta family).
    const eventState = record["event_state"];
    if (eventState !== null && typeof eventState === "object" && !Array.isArray(eventState)) {
      (eventState as Record<string, unknown>)["per_channel"] = {};
    }
  }
  return record;
}

/**
 * Sort key for command-directory items (see module doc, issue #27 batch D):
 * (bot_command_id, name). The sort runs AFTER the deep value pass, where
 * `bot_command_id` is already `{{UUID}}` (catalog-sync-minted, not a known
 * client id), so the key reduces to the scenario-deterministic command name
 * — identical on both targets despite the server-side ORDER BY
 * (updated_at DESC, bot_command_id DESC) tying on the shared catalog-sync
 * timestamp and falling through to per-target random UUIDv7 id tails.
 */
function commandDirectorySortKey(item: unknown): [string, string] {
  if (item !== null && typeof item === "object") {
    const record = item as Record<string, unknown>;
    const id = typeof record["bot_command_id"] === "string" ? record["bot_command_id"] : "";
    const name = typeof record["name"] === "string" ? record["name"] : "";
    return [id, name];
  }
  return ["", ""];
}

function compareCommandDirectoryItems(a: unknown, b: unknown): number {
  const ka = commandDirectorySortKey(a);
  const kb = commandDirectorySortKey(b);
  if (ka[0] !== kb[0]) return ka[0] < kb[0] ? -1 : 1;
  if (ka[1] !== kb[1]) return ka[1] < kb[1] ? -1 : 1;
  return 0;
}

/**
 * `GET /api/chat/commands/directory` (contract §9.12.1, issue #27 batch D):
 * the response is `{ items, next_cursor }` — the contract pins the shape, not
 * the item order (see module doc). Sort `items` in place on both sides;
 * `next_cursor` passes through compared.
 */
function sortCommandDirectoryItems(body: unknown): unknown {
  if (body === null || typeof body !== "object" || Array.isArray(body)) return body;
  const record = body as Record<string, unknown>;
  if (Array.isArray(record["items"])) {
    record["items"] = (record["items"] as unknown[]).slice().sort(compareCommandDirectoryItems);
  }
  return record;
}

/**
 * Event-frame normalizations (contract §10.4, issue #27). Applied to the whole
 * response body / WS capture after the deep value pass:
 *   * drop `payload.channel_id` / `payload.event_id` from `message.*` event
 *     frames (the old Worker omits them; §10.4 canonical payload is
 *     `{ channel_id, event_id, message }`);
 *   * drop `system.notice` frames from event lists (the old Worker emits none
 *     — §5.2b/§10.4 — so the lists would otherwise differ structurally).
 * Non-event objects pass through untouched.
 */
function normalizeEventFrames(value: unknown): unknown {
  if (Array.isArray(value)) {
    return value
      .map((v) => normalizeEventFrames(v))
      .filter(
        (v) =>
          !(
            v !== null &&
            typeof v === "object" &&
            (v as Record<string, unknown>)["frame_type"] === "event" &&
            (v as Record<string, unknown>)["type"] === "system.notice"
          ),
      );
  }
  if (value !== null && typeof value === "object") {
    const record = value as Record<string, unknown>;
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(record)) {
      out[k] = normalizeEventFrames(v);
    }
    if (out["frame_type"] === "event") {
      const payload = out["payload"];
      if (payload !== null && typeof payload === "object" && !Array.isArray(payload)) {
        delete (payload as Record<string, unknown>)["channel_id"];
        delete (payload as Record<string, unknown>)["event_id"];
        // issue #27 D (see module doc): command.invoked — the old Worker
        // persists the `{invocation, command_id}` subset, the v2
        // implementation the full wire payload; the display fields are
        // re-projected live on replay (contract §9.6.2), so drop them on
        // BOTH sides (LIVE fanout and every replay read).
        if (out["type"] === "command.invoked") {
          delete (payload as Record<string, unknown>)["command_name"];
          delete (payload as Record<string, unknown>)["invoked_name"];
          delete (payload as Record<string, unknown>)["actor"];
        }
      }
    }
    return out;
  }
  return value;
}

/**
 * `FORBIDDEN` on `GET /channels/{id}` (contract §2.6): unify the message to
 * the envelope's canonical wording. The old Worker says "not a member"; the
 * v2 implementation previously said "Forbidden" (fixed in lib to the §2.6
 * wording). The code is the stable machine code; the message is the human
 * string the §2.6 example pins.
 */
function normalizeForbiddenDetailMessage(body: unknown): unknown {
  if (body !== null && typeof body === "object" && !Array.isArray(body)) {
    const record = body as Record<string, unknown>;
    const err = record["error"];
    if (
      err !== null &&
      typeof err === "object" &&
      (err as Record<string, unknown>)["code"] === "FORBIDDEN"
    ) {
      return { ...record, error: { ...(err as object), message: "not a channel member" } };
    }
  }
  return body;
}

/** `/api/chat/channels/{id}/members` (list / add). */
const MEMBER_LIST_ROUTE_RE = /^\/api\/chat\/channels\/[^/]+\/members$/;
/** `/api/chat/channels/{id}/members/{user_id}` (show / role / remove). */
const MEMBER_ITEM_ROUTE_RE = /^\/api\/chat\/channels\/[^/]+\/members\/[^/]+$/;
/** `/api/chat/channels/{id}/owner-transfer` (contract §7.5). */
const OWNER_TRANSFER_ROUTE_RE = /^\/api\/chat\/channels\/[^/]+\/owner-transfer$/;
/** `/api/chat/channels/{id}/join` (contract §5.7). */
const JOIN_ROUTE_RE = /^\/api\/chat\/channels\/[^/]+\/join$/;

/**
 * Issue #27 batch B: unify a few error messages whose wording the contract
 * does NOT pin (it pins only the code + status) and where the old Worker's
 * per-route wordings differ from the v2 implementation's generic ones.
 * Cited in the module doc; the old Worker wording is the reference at every
 * throw site for these codes (the old Worker itself varies per route —
 * e.g. MEMBER_NOT_FOUND is "user is not a member of this channel" on the
 * show read but "target not an active member" on role/remove/transfer).
 */
function normalizeBatchBErrorMessages(body: unknown, method: string, pathNoQuery: string): unknown {
  if (body !== null && typeof body === "object" && !Array.isArray(body)) {
    const record = body as Record<string, unknown>;
    const err = record["error"];
    if (err === null || typeof err !== "object") return body;
    const error = err as Record<string, unknown>;
    const code = error["code"];
    const memberRead = MEMBER_LIST_ROUTE_RE.test(pathNoQuery) || MEMBER_ITEM_ROUTE_RE.test(pathNoQuery);
    let message: string | undefined;
    if (code === "MEMBER_NOT_FOUND" && method === "GET" && MEMBER_ITEM_ROUTE_RE.test(pathNoQuery)) {
      message = "user is not a member of this channel";
    } else if (
      code === "MEMBER_NOT_FOUND" &&
      ((method === "PATCH" || method === "DELETE") && MEMBER_ITEM_ROUTE_RE.test(pathNoQuery)) ||
      (code === "MEMBER_NOT_FOUND" && method === "POST" && OWNER_TRANSFER_ROUTE_RE.test(pathNoQuery))
    ) {
      message = "target not an active member";
    } else if (code === "CHANNEL_NOT_FOUND" && memberRead) {
      message = "channel not created";
    } else if (code === "CHANNEL_NOT_FOUND" && method === "POST" && JOIN_ROUTE_RE.test(pathNoQuery)) {
      message = "channel not found";
    } else if (code === "FORBIDDEN" && memberRead) {
      message = "not a channel member";
    }
    if (message !== undefined) {
      return { ...record, error: { ...error, message } };
    }
  }
  return body;
}

/**
 * Issue #27 batch D (see module doc): contract-shape alignment for Bot
 * Gateway frames, applied to `wsSent` / `wsReceived` frames:
 *
 *   * `delivery` frames of kind `command_invocation` → contract §9.7.1 body
 *     (`command` key, options nested, no `delivery_type` / top-level
 *     `options` / `reply_to` — the old Worker's queued body shape);
 *   * `command.invoke` `command_ack` payloads → contract §9.5 shape (no
 *     `invocation_message` — the old Worker's extra field);
 *   * `definition_hash` → `{{DEF_HASH}}` on `delivery` (kind
 *     `command_invocation`) `command` and `session.start` `bot_command`
 *     (see module doc, issue #27 D).
 *
 * The `command.invoked` payload trim lives in `normalizeEventFrames` (it
 * applies to replay reads as well as WS frames — see module doc).
 */
function normalizeBotFrames(value: unknown): unknown {
  if (Array.isArray(value)) return value.map((v) => normalizeBotFrames(v));
  if (value !== null && typeof value === "object") {
    const record = value as Record<string, unknown>;
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(record)) out[k] = normalizeBotFrames(v);

    if (out["type"] === "delivery" && out["kind"] === "command_invocation") {
      const botCommand = out["bot_command"];
      if (out["command"] === undefined && botCommand !== undefined) {
        const cmd: Record<string, unknown> = { ...(botCommand as Record<string, unknown>) };
        if (out["options"] !== undefined) cmd["options"] = out["options"];
        out["command"] = cmd;
      }
      const command = out["command"];
      if (command !== null && typeof command === "object" && !Array.isArray(command)) {
        if (Object.hasOwn(command as Record<string, unknown>, "definition_hash")) {
          (command as Record<string, unknown>)["definition_hash"] = PLACEHOLDER_DEF_HASH;
        }
      }
      delete out["bot_command"];
      delete out["delivery_type"];
      delete out["options"];
      delete out["reply_to"];
    }

    if (out["frame_type"] === "command_ack" && out["command"] === "command.invoke") {
      const payload = out["payload"];
      if (payload !== null && typeof payload === "object" && !Array.isArray(payload)) {
        delete (payload as Record<string, unknown>)["invocation_message"];
      }
    }

    if (out["type"] === "session.start") {
      const botCommand = out["bot_command"];
      if (botCommand !== null && typeof botCommand === "object" && !Array.isArray(botCommand)) {
        if (Object.hasOwn(botCommand as Record<string, unknown>, "definition_hash")) {
          (botCommand as Record<string, unknown>)["definition_hash"] = PLACEHOLDER_DEF_HASH;
        }
      }
    }

    return out;
  }
  return value;
}

// ---------------------------------------------------------------------------
// HTTP header normalization
// ---------------------------------------------------------------------------

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
    // `meta.close` (WS close code, issue #27 batch D): the close code is a
    // TRANSPORT detail, not API contract — Cowboy (v2) and miniflare (old
    // Worker) legitimately differ. Concretely the old Worker closes a
    // secondary live-session browser socket gracefully (the code is not
    // captured before the async close settles) while the v2 implementation
    // has closed the same socket with a spurious 1002 (protocol error) —
    // see the 2026-08-25 batch D report, message-write step 101. The DATA
    // (wsReceived frames / HTTP bodies) is the parity signal; the close
    // code is not. Drop it from both sides (other meta fields, e.g.
    // `negotiated_protocol`, stay compared).
    if (step.meta !== undefined) {
      const { close: _close, ...metaRest } = step.meta as Record<string, unknown>;
      next["meta"] = metaRest;
    }
    if (step.http) {
      const requestBody = step.http.request.body;
      let responseBody = normalizeDeep(step.http.response.body, opts, "body");
      // Contract-delta: IDEMPOTENCY_CONFLICT message unification (§2.5 v2.31).
      responseBody = normalizeIdempotencyConflict(responseBody);
      // Contract-delta: event-frame shape (§10.4 / §5.2b — see module doc).
      responseBody = normalizeEventFrames(responseBody);
      // Contract-delta: §5.2b channel-create `membership` synthesis.
      if (step.http.request.method === "POST" && step.http.request.path === "/api/chat/channels") {
        responseBody = normalizeChannelCreateBody(responseBody);
      }
      // Contract-delta: ChannelSummary trim (§3.2) on the channels list +
      // bootstrap `channels[]`; `active_channel` trim (§4.1) on bootstrap.
      // The request path carries a query string (`?channel_id=…`) — match on
      // the path component only.
      const pathNoQuery = (step.http.request.path ?? "").split("?")[0] ?? "";
      if (
        step.http.request.method === "GET" &&
        (pathNoQuery === "/api/chat/channels" || pathNoQuery === "/api/chat/bootstrap")
      ) {
        responseBody = trimListedChannelSummaries(responseBody, pathNoQuery);
      }
      // Contract-delta: command-directory item order (§9.12.1, issue #27
      // batch D — see module doc): the contract pins the
      // `{ items, next_cursor }` shape, not the order; sort `items` on both
      // sides by (bot_command_id, name).
      if (
        step.http.request.method === "GET" &&
        pathNoQuery === "/api/chat/commands/directory"
      ) {
        responseBody = sortCommandDirectoryItems(responseBody);
      }
      // Contract-delta: FORBIDDEN wording on channel detail (§2.6) +
      // ChannelDetail `last_message_preview`/`last_message_at` trim (§3.3).
      if (
        step.http.request.method === "GET" &&
        /^\/api\/chat\/channels\/[^/]+$/.test(pathNoQuery)
      ) {
        responseBody = normalizeForbiddenDetailMessage(responseBody);
        responseBody = trimChannelDetailBody(responseBody);
      }
      // Contract-delta: issue #27 batch B error-wording unification (member
      // routes + join route — see module doc).
      responseBody = normalizeBatchBErrorMessages(
        responseBody,
        step.http.request.method,
        pathNoQuery,
      );
      next.http = {
        request: {
          method: step.http.request.method,
          // The request path is normalized in body context so ABSOLUTE S3
          // PUT paths (presigned upload_url interpolated from the presign
          // capture) get the same treatment as response-side upload_urls.
          path: normalizeString(step.http.request.path, opts, "body") as string,
          headers: normalizeDeep(step.http.request.headers, opts, "header") as Record<string, string>,
          body: requestBody === undefined ? undefined : normalizeDeep(requestBody, opts, "body"),
        },
        response: {
          status: step.http.response.status,
          headers: normalizeResponseHeaders(step.http.response.headers, opts),
          body: responseBody,
        },
      };
    }
    if (step.wsSent !== undefined) {
      next.wsSent = step.wsSent.map((f) =>
        normalizeBotFrames(normalizeEventFrames(normalizeIdempotencyConflict(normalizeDeep(f, opts, "body")))),
      );
    }
    if (step.wsReceived !== undefined) {
      // ARRAY-level pass (not per-frame): besides the per-frame payload trims,
      // the array branch drops `system.notice` fanout frames (Elixir-only
      // §6.5 admin-delete notice — see module doc, issue #27 batch C).
      const frames = step.wsReceived.map((f) =>
        normalizeIdempotencyConflict(normalizeDeep(f, opts, "body")),
      );
      next.wsReceived = normalizeBotFrames(normalizeEventFrames(frames)) as unknown as StepCapture["wsReceived"];
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
