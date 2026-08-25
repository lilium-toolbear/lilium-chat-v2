# Issue #27 — Conformance 补全 + go/no-go 闸门（report）

Date: 2026-08-25 · Base: `main @ 937d9fc` · Contract: `docs/api-contract.md` v2.31 (SSOT)
Targets: `worker` = old reference Cloudflare Worker (`../lilium-chat`, wrangler/miniflare @ :8791)
vs `elixir` = this Phoenix app @ :4000. Deterministic scenario scripts per spec §7; both
targets run from empty state; diff after volatile-field normalization.

**Bottom line: GO.** All three new scenarios pass with **diff 0** on the final runs,
full `mix test` green (852/852), `mix compile --warnings-as-errors` clean.

| scenario | steps | final result | report file (reports/) |
|---|---|---|---|
| `read-paths` | 26 | **PASS — diff 0, GATE: GO** | `read-paths__worker-8791-vs-elixir-http---127.0.0.1-4000__2026-08-25T09-13-36-465Z.*` |
| `uploads-presign-finalize` | 17 | **PASS — diff 0, GATE: GO** | `uploads-presign-finalize__…__2026-08-25T09-02-42-450Z.*` |
| `stickers` | 17 | **PASS — diff 0, GATE: GO** | `stickers__…__2026-08-25T09-12-13-009Z.*` |

Read-path observations (§7.5) all pass on every run (ok=true, hiddenWrites=0, query
counts bounded; e.g. bootstrap:post ≤ 18 queries, channels:detail ≤ 8).

## (a) Coverage table

New coverage added by this batch (all previously uncovered contract READ endpoints in
(A), plus the presign/finalize and sticker write paths):

### `conformance/scenarios/read-paths.ts` — 26 steps
| area | steps | contract § |
|---|---|---|
| bootstrap (empty) | `bootstrap:empty` | §4.1 |
| channel directory / list / detail | `channels:list:empty`, `channels:directory:empty`, `channels:list:post`, `channels:list:stranger`, `channels:detail`, `channels:detail:non-member` (403) | §3.2, §5.2, §2.6 |
| channel create (write, needed for read state) | `channels:create` + `sync:channel-projected` | §5.2b |
| members | `members:list`, `members:show` | §5.3 |
| invites (read path) | `invites:create` (write), `invites:preview:member`, `invites:preview:stranger` (403/404 gates) | §5.8 |
| messages | `messages:list:empty`, `messages:list:post`, `messages:context` (cursor pagination) | §6.1 |
| events | `events:channel:empty`, `events:channel:post` (cursor pagination) | §6.2 |
| bootstrap (populated) | `bootstrap:post` | §4.1 |
| WS browser protocol | `ws:connect`, `ws:live_start`, `ws:message_send`, `ws:close` (incl. fanout lease grace observation) | §10 |

### `conformance/scenarios/uploads-presign-finalize.ts` — 17 steps
| area | steps | contract § |
|---|---|---|
| user presign | `uploads:user:presign` (deterministic 12345-byte image, Idempotency-Key) | §8.1 |
| S3 PUT | `s3:put:user` (raw binary `base64Body` against shared fake-S3 fixture) | §8.1 |
| finalize | `uploads:user:finalize` (etag from PUT response) | §8.2 |
| idempotency | `uploads:user:presign:replay` (same key+body → 200 replay), `uploads:user:presign:conflict` (same key, different body → 409) | §2.5 |
| gates | `uploads:user:finalize:cross-user` (foreign owner), `uploads:user:finalize:unknown` (unknown id → 415) | §8.2 |
| bot fixtures | `bots:create` (capture `bot_id` + `initial_token.plaintext`), `bot:commands:sync` (PUT commands), `bot:commands:bind` (PATCH channel binding) | §9.16–9.17 |
| bot presign/PUT/finalize | `bot:presign`, `s3:put:bot`, `bot:finalize` | §9.17.1 |
| bot idempotency | `bot:presign:replay`, `bot:presign:conflict` | §2.5 |

### `conformance/scenarios/stickers.ts` — 17 steps
| area | steps | contract § |
|---|---|---|
| source fixture | `channels:create`, `uploads:presign`, `s3:put`, `uploads:finalize` (32×32 sticker.png) | §8.1/§8.2 |
| list | `stickers:list:empty`, `stickers:list:alice`, `stickers:list:bob` (per-user isolation) | §8.3 |
| save | `stickers:save` (Idempotency-Key), `stickers:save:replay`, `stickers:save:conflict` (unknown attachment) | §8.3 |
| delete | `stickers:delete:cross-user`, `stickers:delete`, `stickers:delete:replay` | §8.3 |
| revival | `stickers:save:revive` (re-save after delete), list re-checks | §8.3 |

Scenario invariants honored: one etag literal per finalize Idempotency-Key (hash parity);
unknown-attachment finalize uses `etag: null`; replay = same key + same body; `absolute`
+ `base64Body` steps carry deterministic bytes, and the captured presigned URL is
normalized (`{{S3_OBJECT_PATH}}`) while the **signature/algorithm/signed-headers are
still compared** — so SigV4 canonical-form parity is actually exercised.

## (b) Per-scenario diff status (trajectory)

| scenario | run 1 | intermediate | final |
|---|---|---|---|
| read-paths | 38 diffs | 10 → 0 after Elixir fixes + path-with-query matching fix | **0 (GO)** |
| uploads-presign-finalize | 7 diffs (3 root causes) | etag mystery resolved (stale fake-S3 process, see (e)) | **0 (GO)** |
| stickers | 5 diffs (1 root cause: cross-user delete) | owner-scope no-op parity fix | **0 (GO)** |

## (c) Elixir fixes (all test-first in `test/`)

1. **WS raw-protocol / BrowserSocket** (`lib/lilium_chat_web/browser_socket.ex`, new
   `test/lilium_chat_web/browser_raw_ws_test.exs`): raw `handle_in/2` + `handle_info/2`
   overrides must precede `use Phoenix.Socket` (clause ordering is load-bearing);
   fake test sockets need `pubsub_server: LiliumChat.PubSub` and the internal
   Phoenix socket state map. Also **strips `membership_version_at_event` from
   event frames at the raw-push branch** (post-gate): D8 makes it an in-process
   socket-cache gate field, not a §10.4 wire field — the old Worker strips it the
   same way.
2. **dm_peer key** (`lib/lilium_chat/channels.ex`, `test/.../read_path_controller_test.exs`):
   non-DM channel detail no longer emits an explicit `dm_peer: null` key (§3.3
   ChannelDetail has no `dm_peer` for `kind: channel`).
3. **FORBIDDEN wording** (`channels.ex`, same test file): `GET /channels/{id}`
   non-member 403 message → `"not a channel member"` (§2.6 envelope wording; old
   Worker says "not a member" — delta, normalized, see (d)).
4. **ISO-8601 `Z` timestamps** (`lib/lilium_chat/projections.ex` new `iso_z/1` +
   `format_ts/1`; applied in `bootstrap.ex` (delegates to it), `bot_delivery.ex`,
   `stream.ex` ×2, `bot_gateway.ex` `server_time`, `browser_channel.ex`
   `lease_expiry`): §2.3 requires `2026-06-21T05:30:00Z` shape; the Elixir app
   previously emitted designator-less UTC at several sites. `DateTime.to_utc/1` is
   undefined in this Elixir 1.20.3 build, hence the conditional append-`Z` helper.
5. **bootstrap.messages via Timeline** (`lib/lilium_chat/bootstrap.ex`,
   `test/lilium_chat/bootstrap_test.exs`): populated `messages` now come from
   `Timeline.messages_page/3` (event frames `frame_type="event"`,
   `type="message.created"`, `payload.message.*`) instead of a bespoke
   `query_messages/1` projection; `query_my_channels` visibility filter fixed to
   `status NOT IN ('deleted','recalled')` with `message_id` tiebreak. Round-trip
   budget documented (≤11 reads; observed ≤18 total for bootstrap:post).
6. **SigV4 canonical headers** (`lib/lilium_chat/s3.ex`, `test/lilium_chat/s3_test.exs`):
   canonical header NAMES lowercased + sorted and `X-Amz-SignedHeaders` =
   `cache-control;content-type;host` (both in the canonical request and the query
   param). Old Worker / aws4fetch is the reference; the old mixed-case form was
   non-conforming to AWS SigV4.
7. **Owner-scoped finalize lookup** (`lib/lilium_chat/uploads.ex`,
   `test/lilium_chat/uploads_test.exs` + controller test): finalize looks up the
   pending attachment **with** `owner_user_id` in the WHERE clause, so a foreign
   attachment surfaces as `415 UNSUPPORTED_ATTACHMENT_TYPE "attachment not found"`
   — exactly the old Worker's per-DO behavior. Contract §8.2 ("确认 pending
   attachment 属于当前用户") is silent on the exact code → parity with reference
   wins; recorded below.
8. **Sticker cross-user delete = idempotent no-op** (`lib/lilium_chat/stickers.ex`,
   `test/lilium_chat/stickers_test.exs` + controller test): a sticker owned by
   another user is simply not in the caller's library (old Worker: per-DO storage,
   its forbidden branch is unreachable in practice) → `200 {sticker_id, deleted:true}`.
   Contract §8.3: `sticker_id` 跨用户不稳定 + 重复删除幂等.

## (d) Harness / normalization changes (each with contract citation)

`conformance/src/normalize.ts` (module doc carries the full citation table):

| normalization | contract citation |
|---|---|
| ISO-8601 timestamps → `{{TS}}`, **designator now optional** in the pattern | §2.3 — Elixir used to emit designator-less UTC (now fixed in lib, rule stays permissive) |
| `last_event_id` / `last_read_event_id` (any value incl. null) → `{{EVENT_ID}}` | §3.2 per-channel monotonic UUIDv7, server-minted. Old-Worker delta: list route hardcodes `null`; Elixir returns the real last event id (contract-correct) |
| ChannelSummary items (channels list + bootstrap `channels[]`): drop `topic` / `created_at` / `updated_at` (and null `last_message_*`) | §3.2 ChannelSummary = exactly 13 fields; those are §3.3 ChannelDetail fields the implementations additionally emit |
| Bootstrap `active_channel`: drop `unread_count` / `last_read_event_id` / `last_message_preview` / `last_message_at` / `last_event_id` | §4.1 — `active_channel` is the 11-field ChannelDetail shape; old Worker returns a full ChannelSummary there |
| Event frames / event list items: drop `payload.channel_id` + `payload.event_id` on `message.*` payloads (both sides) | §10.4 — payload is `{channel_id, event_id, message}`; Elixir conforms, old Worker omits the two keys (delta) |
| Event frames: drop `system.notice` frames from arrays (both sides) | §5.2b/§10.4 — channel create emits `system.notice` (`channel.created`); old Worker emits **no** `system.notice` at all (delta) |
| `POST /api/chat/channels` response: synthesize `membership = {role:"owner", joined_at}` and drop top-level `joined_at` (old-Worker side) | §5.2b — response is `{channel, membership}`; creator is always owner |
| `FORBIDDEN` message on `GET /channels/{id}` → `"not a channel member"` | §2.6 envelope wording; old Worker "not a member" (delta), Elixir previously "Forbidden" (fixed in lib) |
| `invite_code` values + `/api/chat/invites/<code>(/accept)?` request paths → `{{INVITE_CODE}}` | §5.8 — server-minted channel credential, "邀请码原文只返回一次" |
| BotTokenCreated `plaintext` → `{{BOT_TOKEN}}` | §9 — "`plaintext` 只返回一次" |
| `IDEMPOTENCY_CONFLICT` message → unified `"idempotency key reused with different request body"` | §2.5 v2.31 delta note (old Worker varies wording per operation) |
| presigned `upload_url`: host kept, path → `{{S3_OBJECT_PATH}}`, `X-Amz-Date`/credential date → `{{TS}}`, `X-Amz-Signature` → `{{S3_SIGNATURE}}`, query keys sorted; algorithm/expires/signed-headers/credential scope still compared | §8.1 (SigV4 presign; object key not exposed to frontend) |
| public attachment URL → `{{S3_OBJECT_URL}}` (path is a server-minted storage key) | §8.1/§8.2 — "对象存储 key 不暴露给前端" |
| transport headers (cache-control, content-length, date, transfer-encoding; `vary: accept-encoding` component) dropped | HTTP/1.1 framing / framework detail, not API contract (miniflare vs Bandit) |
| path matching on `path.split("?")[0]` for bootstrap normalization (request path carries `?channel_id=`) | harness bug fix (cost one extra run) |

Harness plumbing (new): `base64Body` (raw binary body, mutually exclusive with
`body`) + `absolute: true` http steps (`conformance/src/types.ts`,
`conformance/src/runner.ts`); shared in-memory S3 fixture
`conformance/fixtures/fake-s3.mjs` (PUT stores by exact path; etag =
`sha256(body).hex[:16]`; HEAD/GET answer the stored content-type +
content-length — the only surface finalize checks, §8.2); `conformance/src/worker.ts`
now writes `.dev.vars` with the fake-S3 creds each start (it rewrites the file,
so file-only edits get clobbered); `seed-users.sql` + `wrangler.conformance.jsonc`
carry the deterministic alice/bob fixtures.

## (e) Environment changes

- `docker-compose.yml`: new `fake-s3` service (node:22-alpine, `conformance/fixtures/fake-s3.mjs`, :8900).
- Fake-S3 creds `conformance-access-key` / `conformance-secret-key`, bucket
  `lilium-chat-attachments`, region `us-east-1` — set in compose for the Elixir app
  and written by the harness into the Worker's `.dev.vars`.
- **Old-Worker gotcha**: the Worker's `createS3Client` reads `S3_ACCESS_KEY_ID` /
  `S3_SECRET_ACCESS_KEY` even though signing is local — missing them yields a
  generic `503 CHAT_WORKER_UNAVAILABLE` (error handler swallows).
- **mix test caveat**: the app container now carries the fake-S3 `S3_*` env, so the
  suite must run with them cleared:
  `env -u S3_ENDPOINT -u S3_PUBLIC_BASE -u S3_ACCESS_KEY_ID -u S3_SECRET_ACCESS_KEY -u S3_BUCKET -u S3_REGION mix test`
  (TestTransport tests expect the `s3.kuma.homes` defaults).
- App restart after lib changes: `podman compose -f docker-compose.yml up -d --force-recreate app`
  from `lilium-chat-v2/`.
- Known flake: `LiliumChatWeb.QueryCountingTest` (and once the housekeeping
  attachment sweep test, seed-dependent) — retry once; both pass in the final full
  run (852/852).

## (f) Remaining issues

### Old-Worker-vs-contract deltas (recorded; normalized where the contract is silent or both-side-structural)

1. `POST /api/chat/channels`: top-level `joined_at`, no `membership` object (§5.2b).
2. `IDEMPOTENCY_CONFLICT` message wording varies per operation (§2.5 v2.31 unified wording).
3. No `system.notice` (`channel.created`) emitted on channel create (§5.2b).
4. Channel list hardcodes `last_event_id: null` (§3.2 — Elixir's real last event id is the contract-correct value).
5. ChannelSummary items carry extra `topic` / `created_at` / `updated_at` (§3.2 = 13 fields).
6. `message.*` event payloads omit `payload.channel_id` / `payload.event_id` (§10.4 — Elixir conforms).
7. Finalize cross-user: `415 UNSUPPORTED_ATTACHMENT_TYPE "attachment not found"`
   (per-DO scoping) where §8.2 only says "belongs to current user" — Elixir now
   matches via owner-scoped lookup (fix (c).7).
8. Sticker cross-user delete: no-op success `200 deleted:true` (§8.3 跨用户不稳定) —
   Elixir now matches (fix (c).8).
9. `ws:close` meta: first runs diffed `close 1011` vs absent; final runs both
   capture `meta: {}` (no server close frame after client close) — closed with the
   BrowserSocket raw-protocol work, no normalization needed.
10. S3 public URL host/bucket: old Worker drops the bucket segment
    (`…/lilium-chat-attachments/chat/…` vs `…/chat/…`); §8.2 example includes the
    bucket. Normalized as `{{S3_OBJECT_URL}}` (storage-key opacity) — revisit if
    the contract pins the exact host shape.

### Open items / follow-ups

- `attachments.url` bucket-in/out normalization stays until the contract pins the
  public host (see 10).
- `QueryCountingTest` flake (timing-sensitive) — retry-once in CI if it resurfaces.
- Temp probe files in `conformance/` (`tmp_*`) deleted as part of this task's
  cleanup; scenario runs leave no state (fake-S3 is in-memory, keys are UUIDs).
- Nothing committed per batch instructions — working tree holds: 3 new scenarios +
  registrations (`cli.ts`), `normalize.ts`/`runner.ts`/`types.ts`/`worker.ts`
  extensions, `fake-s3.mjs` fixture, compose service, 12 `lib/` files, 6 test files.
