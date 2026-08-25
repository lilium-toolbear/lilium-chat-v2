# Issue #27 batch C — 消息写路径（send / edit / recall / delete / mark_read / pin）一致性（report）

Date: 2026-08-25 · Base: `main @ 928cfbd` · Contract: `docs/api-contract.md` v2.31 (SSOT)
Targets: `worker` = old reference Cloudflare Worker (`../lilium-chat`, wrangler/miniflare @ :8791)
vs `elixir` = this Phoenix app @ :4000. Deterministic scenario scripts per spec §7; both
targets run from empty state; diff after volatile-field normalization.

**Bottom line: GO.** The new `message-write` scenario (102 steps — the full browser WS
write path: `message.send` / `message.edit` / `message.recall` / `message.delete`,
`channel.mark_read`, `channel.pin_message` / `channel.unpin_message`) passes with
**diff 0** on two consecutive final runs; all ten pre-existing scenarios (batches A+B)
re-verified at **diff 0** after this batch's `runner.ts` / `normalize.ts` changes;
`mix test` green (**853/853** — no Elixir lib changes this batch),
`mix compile --warnings-as-errors` clean, `mix format --check-formatted` clean,
conformance `tsc --noEmit` clean.

| scenario | steps | final result | report file (reports/) |
|---|---|---|---|
| `message-write` | 102 | **PASS — diff 0, GATE: GO** | `message-write__…__2026-08-25T13-10-01-235Z.*` |

Pre-existing scenarios re-run after this batch's harness changes (all **PASS — diff 0,
GATE: GO**): `bootstrap-send-fanout` (`…T13-00-26-549Z`), `jwt-auth-boundaries`
(`…T13-00-54-615Z`), `read-paths` (`…T13-01-48-196Z`), `uploads-presign-finalize`
(`…T13-02-27-943Z`), `stickers` (`…T13-03-09-031Z`), `channel-lifecycle`
(`…T13-04-12-182Z`), `member-lifecycle` (`…T13-05-30-700Z`), `invite-lifecycle`
(`…T13-06-19-158Z`), `public-join` (`…T13-07-06-313Z`), `dm-open`
(`…T13-07-48-344Z`).

Read-path observations (§7.5) pass on every final run (ok=true, hiddenWrites=0, bounded
query counts; e.g. timeline list 10–11 queries, message context 15, channel detail 8,
events read 11, bootstrap 19).

## (a) Coverage table

New coverage added by batch C — every §6.2–§6.7 write command on the browser WS, each
verified via BOTH the WS capture (ack + fanout frames on all four live sockets) and the
HTTP read surfaces (timeline list, events read, message context, channel detail,
bootstrap):

### `conformance/scenarios/message-write.ts` — 102 steps
| area | steps | contract § |
|---|---|---|
| fixtures (main: alice owner + bob admin via `initial_members`; separate `dissolve` channel) + projection polls | `channels:create:main`, `channels:create:dissolve`, `sync:alice:list`, `sync:bob:list` | §5.2b, §5.1 |
| upload fake-S3 flow (image attachment for m6) | `uploads:presign`, `s3:put` (12345-byte body), `uploads:finalize` | §8.1, §8.2 |
| sockets + live (4 sockets: alice, bob, carol, alice2; `session.live_start` ×4 + lease grace) | `ws:connect` ×4, `ws:live_start` ×4, `sync:fanout-lease-grace` (1 s) | §10.1, §5.11 |
| pre-write gates (missing cursor / missing channel / non-member mark_read; non-member send) | `ws:mark_read:missing-cursor`, `ws:mark_read:missing-channel`, `ws:mark_read:non-member`, `ws:send:non-member` | §5.5, §6.2 |
| `message.send` — m1–m6 (text; reply+mention; reply; pin-source; bob text; image+attachment) with fanout drains | `ws:send:m1`, `ws:send:m2:reply:mention`, `ws:send:m3:reply`, `ws:send:m4:pin-source`, `ws:send:m5`, `ws:send:m6:image` (+ `sync:fanout:m*`) | §6.2, §10.4 |
| idempotency (`command_id` durable key) | `ws:send:replay:m1` (same body → cached ack), `ws:send:conflict:m1` (different body → 409 IDEMPOTENCY_CONFLICT), `ws:send:gate:text-with-attachments` (422 INVALID_MESSAGE) | §2.5, §6.2 |
| read surfaces (timeline list / events / context / detail) | `messages:list:m1`, `messages:list:m2`, `messages:list:all`, `events:read:pre`, `messages:context:m3:pre`, `channels:detail:pre` | §6.1, §6.1b, §6.6, §5.2b |
| carol joins + fanout re-subscription | `members:add:carol`, `sync:carol:list` (retry-until-settled), `ws:live_start:carol2` (post-join re-live, count 1), `sync:carol-lease` | §7.1, §5.11, §10.5 |
| mutation gates (foreign edit / foreign recall / member delete / member pin) | `ws:edit:gate:foreign`, `ws:recall:gate:foreign`, `ws:delete:gate:foreign-member`, `ws:pin:gate:member-role` | §6.3, §6.4, §6.5, §6.7 |
| admin foreign delete (v2 `system.notice` fanout) + pin-on-deleted-source gate | `ws:delete:m3:admin-foreign`, `ws:pin:gate:deleted-source` | §6.5 |
| pin lifecycle (pin → detail + bootstrap projection → no-op re-pin → edit-sync → unpin ×2 + gate) | `ws:pin:m4`, `channels:detail:pin-active`, `bootstrap:pin-active`, `ws:pin:m4:no-op-repin`, `ws:edit:m4:pin-sync`, `channels:detail:pin-updated`, `ws:unpin:m4`, `ws:unpin:m4:again` (PIN_NOT_FOUND), `ws:unpin:no-locator` (INVALID_MESSAGE), `channels:detail:pin-cleared` | §6.7, §3.10 |
| edit + recall + gates (edit-recalled; foreign recall) | `ws:edit:m1`, `ws:recall:m1`, `ws:edit:gate:recalled`, `ws:recall:gate:foreign` | §6.3, §6.4 |
| carol (now subscribed) send + self-delete | `ws:send:m7:carol`, `messages:list:m7-id`, `ws:delete:m7:self` | §6.2, §6.5, §6.1 |
| dissolved-channel gate | `channels:dissolve`, `ws:send:gate:dissolved` (CHANNEL_DISSOLVED) | §5.4, §6.2 |
| `channel.mark_read` (monotonic cursor; `read_state_updated` to the user's other live session) | `events:read:latest`, `ws:mark_read:old-cursor`, `ws:mark_read:latest` (+ `sync:hint:read_state_updated` on alice2), `ws:mark_read:no-advance` (return-stored, no broadcast), `ws:mark_read:carol` | §5.5 |
| final reads (post-mutation timeline: recalled/deleted dropped, edited re-projected, reply_snapshot re-projected; context of the reply target) | `messages:list:final`, `messages:context:m2:final`, `events:read:final`, `bootstrap:final`, `channels:detail:final` | §6.1, §6.6, §6.1b, §4.1, §5.2b |
| close | `ws:close` ×4 | §10.1 |

Scenario invariants honored: deterministic v7-shaped UUID literals for all command_ids /
Idempotency-Keys; `ALICE_USER_ID` / `BOB_USER_ID` imported from `read-paths.ts`, Carol
from `conformance/fixtures/seed-users.sql`; server-minted ids captured (`capture`) and
interpolated (`${var}`) — message ids come from the timeline read (contract §6.1:
`items[]` is the ASC event timeline `[channel.created, member.joined(owner),
member.joined(admin), message.created…]`, message data under
`items[N].payload.message`); error steps pin the exact `{code, message, retryable}`
envelope; every fanout-bearing step awaits its fanout (`alsoUntil`) on the sender's
socket and drains the other three sockets through the runner settle.

## (b) Per-scenario diff status (trajectory)

| run (reports/ timestamp) | diffs | root causes → fix |
|---|---|---|
| `…T12-11-32-603Z` (run 1) | 46 | all scenario/harness: (1) capture pointers assumed bare messages — §6.1 returns an event timeline, so `m1Id…m7Id` were never captured (downstream steps errored identically on both sides); (2) step-boundary fanout races — the old Worker delivers channel frames synchronously inside the write request while the v2 app delivers via the Postgres fanout after the response, so the same fanout landed in different steps on the two targets (steps 43/44, 75/76, 80/81); (3) `last_message_preview` value delta on channel detail (5 diffs) |
| `…T12-32-24-805Z` (run 2) | 16 | after capture + runner-settle + `system.notice`-WS + detail-trim fixes: 7 × `pinned_by.display_name` (old-Worker fallback name) + 9 × fanout frame-count (carol post-join membership) |
| `…T12-59-26-156Z` (run 3) | **0 (GO)** | after the `pinned_by` normalization + carol post-join re-live |
| `…T13-10-01-235Z` (run 4, regression-suite re-run) | **0 (GO)** | stability re-run (11 scenarios in one pass, all GO) |

## (c) Elixir fixes (all test-first in `test/`)

**None.** The v2 write path already conformed: all 46 + 16 run-1/run-2 diffs traced to
scenario authoring, harness timing, and old-Worker-vs-contract deltas (normalized per the
batch rule — contract-silent or both-side-structural). No `lib/` or `test/` file changed
in this batch; `mix test` 853/853 confirms the untouched baseline.

## (d) Harness / normalization changes (each with contract citation)

`conformance/src/normalize.ts` (module doc carries the full citation table) and
`conformance/src/runner.ts`. Batch C additions:

| change | contract citation |
|---|---|
| **Runner settle** (`runner.ts`, `SETTLE_MS = 400`): a fixed settle window before draining each step's socket buffers for http / ws.command / ws.event steps, so both targets capture the same fanout union in the same step. The old Worker pushes channel frames synchronously inside the write request (user_event hints a few ms later via the projection alarm); the v2 app delivers every frame via the Postgres fanout AFTER the write response — without the settle the same fanout lands in different steps on the two targets (a step-boundary false positive). | §10.5 — live fanout is best-effort and delivery timing is implementation-defined (the contract pins frame shapes, not arrival latency) |
| **WS `wsReceived` array-level event-frame pass** (`normalize.ts`): `wsReceived` frames are now normalized as an ARRAY (not per-frame), so `normalizeEventFrames`' array branch runs: `system.notice` fanout frames are dropped from WS captures on both sides (Elixir broadcasts the §6.5 admin-action notices — e.g. 4 copies on the admin foreign-delete and on dissolve; the old Worker emits none), and the `message.*` payload trims (`channel_id` / `event_id`) apply uniformly. | §6.5 — the notice is an OPTIONAL weak-hint event ("可选"); the old Worker emits none, so without the drop the captures differ structurally. Same family as the existing event-list `system.notice` drop |
| **`ChannelPin.pinned_by.display_name` → `{{PINNED_BY_NAME}}`** (`normalize.ts`, `PLACEHOLDER_PINNED_BY_NAME`): the pin's `pinned_by` UserSummary display name is placeholdered on both sides; `user_id` / `avatar_url` stay compared. The old Worker resolves `pinned_by` with a FALLBACK display name (`user-<id-prefix>`) on the channel-detail read, the pin-event fanout frames, and the event-replay read, while the v2 implementation resolves the LIVE profile on all three (the initial pin ack/event resolve the live profile on BOTH targets, which is why only the read/delivery paths diffed). | §3.10.3 — `pinned_by` is a `UserSummary`; the contract pins the shape but not the resolution source |
| **Channel-detail `channel` trim** (`normalize.ts`, `trimChannelDetailBody`): `last_message_preview` + `last_message_at` dropped from the `GET /channels/{id}` `channel` object on both sides. The v2.31 §3.3 ChannelDetail is 11 fields and has neither key — they are §3.2 ChannelSummary denormalizations both targets emit on the detail read with DIFFERENT formats (old Worker: raw message text, `""` when empty; v2: `"display name: text"` per the §3.2 example). | §3.3 (11-field ChannelDetail) vs §3.2 (ChannelSummary preview, format example) — same family as the batch-A §4.1 `active_channel` trim |

All batch-A/B rules are untouched and still pass (the ten pre-existing scenarios were
re-run to diff 0 after the shared-path changes — runner settle + normalizer).

## (e) Environment changes

- **No Elixir lib/test changes → no app restart** (`lilium_chat_app` kept running
  through the batch; pg / fake_s3 untouched).
- `conformance/fixtures/seed-users.sql` already carried Carol (batch B) — no fixture
  changes this batch.
- Full `mix test`: **853/853** on retry — one known flake on the first full pass
  (`LiliumChatWeb.QueryCountingTest`, the pg_stat_statements oracle; passes in
  isolation on re-run — the batch-A/B known flake, no lib changes to attribute it to).
- `mix compile --warnings-as-errors` clean; `mix format --check-formatted` clean;
  conformance `tsc --noEmit` clean after the `normalize.ts` / `runner.ts` additions.

## (f) Remaining issues

### Old-Worker-vs-contract deltas (recorded; normalized where the contract is silent or both-side-structural)

1. **`pinned_by` resolution source** — the old Worker's detail read / pin fanout /
   event replay resolve `pinned_by` with the fallback `user-<id-prefix>` display name;
   the v2 implementation resolves the live profile everywhere (initial pin ack/event on
   both targets). Normalized per §3.10.3 (d) — the contract pins the UserSummary shape
   only.
2. **Channel-detail summary fields** — both targets emit the §3.2 summary denormalizations
   (`unread_count`, `last_read_event_id`, `last_message_preview`, `last_message_at`,
   `last_event_id`) on the §5.2b detail read; only `last_message_preview` /
   `last_message_at` value-diffed (format family) and are trimmed (d); the cursor
   fields were already normalized to `{{EVENT_ID}}` and `unread_count` matched
   (0/0 — no mark_read yet at those steps).
3. **`system.notice` fanout** — the v2 app broadcasts the optional §6.5 weak-hint frames
   (admin/owner foreign-delete, channel.dissolved); the old Worker emits none. Dropped
   from WS captures + event lists (d + pre-existing).
4. **Fanout membership for a user who joins AFTER `session.live_start`** — the old
   Worker starts delivering to her socket once she is a member (its lease/delivery path
   sees the new membership), while the v2 PubSub subscription is fixed at live_start
   time. The scenario avoids the unpinned semantic by re-living carol post-join
   (`ws:live_start:carol2`, ack `subscribed_channel_count=1` — verified identical on
   both targets), which also exercises the re-live path.

### Open items / follow-ups

- **Pin limit (8) untested** — reaching `PIN_SOURCE_INVALID` "channel pin limit reached"
  needs 9 pins in one channel (expensive); both targets share the constant
  (`MAX_CHANNEL_PINS` / `@max_pins`). A dedicated sub-scenario could cover it.
- **Mention validation semantics** — §6.2 pins `mentions: [{user_id, start, end}]` but
  not whether the text at `[start, end)` must match mention syntax; the scenario uses a
  syntactically valid range and both targets accept it.
- **§6.1 messages-list envelope** — both targets return the ASC event timeline
  (`channel.created` / `member.joined` / `message.created` frames) where the contract
  says "return the latest page" of visible non-deleted/non-recalled messages; neither
  the in-page order nor the exact item envelope is pinned, and both targets agree
  (ASC, channel prefix first), so no normalization was needed. Worth a contract note.
- **`read_state_updated` delivery** — verified on alice2's socket (the caller's other
  live session) via the post-`mark_read` drain; no-advance (older cursor) correctly
  emits no hint on either target.
- `QueryCountingTest` flake (batch-A/B known) — retry-once in CI if it resurfaces.
- Nothing committed per batch instructions — working tree holds: 1 new scenario
  (`conformance/scenarios/message-write.ts`) + its `cli.ts` registration,
  `conformance/src/runner.ts` (settle), `conformance/src/normalize.ts` (batch-C rules),
  this report.
