# Issue #27 batch B — 频道生命周期 / 成员 / 邀请 / 公开加入 / DM 一致性（report）

Date: 2026-08-25 · Base: `main @ 04e732c` · Contract: `docs/api-contract.md` v2.31 (SSOT)
Targets: `worker` = old reference Cloudflare Worker (`../lilium-chat`, wrangler/miniflare @ :8791)
vs `elixir` = this Phoenix app @ :4000. Deterministic scenario scripts per spec §7; both
targets run from empty state; diff after volatile-field normalization.

**Bottom line: GO.** All five new scenarios pass with **diff 0** on the final runs;
all five pre-existing batch-A scenarios re-verified at **diff 0** after this batch's
`normalize.ts` changes; full `mix test` green (**853/853**, baseline 852 + 1 new test),
`mix compile --warnings-as-errors` clean, `mix format --check-formatted` clean,
conformance `tsc --noEmit` clean.

| scenario | steps | final result | report file (reports/) |
|---|---|---|---|
| `channel-lifecycle` | 30 | **PASS — diff 0, GATE: GO** | `channel-lifecycle__…__2026-08-25T10-28-39-899Z.*` |
| `member-lifecycle` | 39 | **PASS — diff 0, GATE: GO** | `member-lifecycle__…__2026-08-25T10-30-56-983Z.*` |
| `invite-lifecycle` | 20 | **PASS — diff 0, GATE: GO** | `invite-lifecycle__…__2026-08-25T10-36-19-204Z.*` |
| `public-join` | 20 | **PASS — diff 0, GATE: GO** | `public-join__…__2026-08-25T10-37-18-975Z.*` |
| `dm-open` | 17 | **PASS — diff 0, GATE: GO** | `dm-open__…__2026-08-25T10-52-07-963Z.*` |

Pre-existing scenarios re-run after this batch's harness changes (all **PASS — diff 0,
GATE: GO**): `bootstrap-send-fanout` (`…T10-53-22-781Z`), `jwt-auth-boundaries`
(`…T10-53-42-698Z`), `read-paths` (`…T10-54-15-312Z`), `uploads-presign-finalize`
(`…T10-54-40-222Z`), `stickers` (`…T10-55-06-595Z`).

Read-path observations (§7.5) pass on every final run (ok=true, hiddenWrites=0, bounded
query counts; e.g. member reads 3–5 queries, invite preview 3–6, DM bootstrap ≤ 9,
directory/list ≤ 8).

## (a) Coverage table

New coverage added by batch B (lifecycle writes + their read-state projections, all
previously uncovered write surfaces in §5/§7):

### `conformance/scenarios/channel-lifecycle.ts` — 30 steps
| area | steps | contract § |
|---|---|---|
| create (private + initial admin member; public_listed) | `channels:create:private:with-admin`, `channels:create:public` | §5.2b |
| idempotency | `channels:create:replay` (same key+body → 200 cached), `channels:create:conflict` (same key, different body → 409 IDEMPOTENCY_CONFLICT) | §2.5 |
| list/detail read-state projection (retry-until-settled, then probe) | `sync:channels-projected`, `channels:list:post-create`, `channels:detail:private:member`, `channels:detail:private:admin`, `channels:detail:public:stranger` | §3.2, §5.1, §5.2 |
| members (read, initial) | `members:list:initial`, `members:show:bob:initial` | §7.1 |
| public directory projection | `sync:directory-projected`, `directory:post-create` | §5.6 |
| update | `channels:update:title-topic`, `channels:update:visibility`, `channels:update:noop` (empty body), `channels:update:forbidden` (403 non-owner), `channels:update:invalid-visibility` (422), post-update detail + directory re-read, `events:private:post-update` (channel.created + channel.updated frames, `channel_changes` before/after) | §5.3, §10.4 |
| dissolve | `channels:dissolve:forbidden` (403 non-owner), `channels:dissolve`, `channels:dissolve:replay`, post-dissolve list retry (status `dissolved`), `channels:detail:post-dissolve` (still readable, §5.4), `members:list:post-dissolve`, `events:public:post-dissolve` (channel.dissolved frame), `channels:update:post-dissolve` (409 CHANNEL_DISSOLVED), `members:add:post-dissolve` (409) | §5.4, §7.5 |

### `conformance/scenarios/member-lifecycle.ts` — 39 steps
| area | steps | contract § |
|---|---|---|
| create (private, alice owner) + baseline reads | `channels:create`, `members:list:initial`, `members:show:self`, `members:show:never-joined` (404 MEMBER_NOT_FOUND), `members:list:non-member-viewer` (403), `members:list:channel-not-found` (404) | §7.1, §7.1b |
| add | `members:add:bob`, `members:add:bob:replay` (idempotent), `members:add:bob:noop` (already active → 409), `members:add:bob:role-change-pin` (422 — P0-5: add ≠ role change), `members:add:self` (422), `members:add:by-member` (403), post-add list + show | §7.1 |
| role | `members:role:bob:promote` (member→admin), `members:role:bob:demote` (admin→member), `members:role:missing-role` (422), `members:role:owner-pin` (422 — owner role fixed), `members:role:by-nonowner` (403), `members:role:never-joined` (404) | §7.2 |
| remove | `members:add:carol:admin`, `members:remove:bob`, `members:show:bob:left` (status `left`), `members:list:post-remove`, `members:remove:bob:again` (404), `members:remove:carol:by-admin` (admin may remove non-owner), `members:list:post-cleanup` | §7.4 |
| reactivation | `members:add:bob:reactivate` (left row → fresh join, role reset member), `members:show:bob:reactivated` | §7.1 |
| owner transfer | `owner-transfer:by-member` (403), `owner-transfer:non-member-target` (404), `owner-transfer:bad-previous-role` (422 — previous_owner_role must be admin/member), `owner-transfer` (alice→bob, previous_owner_role `admin`), `owner-transfer:replay`, post-transfer list/show (`members:list:post-transfer`, `members:show:alice:demoted`, `members:show:bob:owner`), `events:full` (two member.role_updated frames, mv+1/mv+2) | §7.5, §10.4 |

### `conformance/scenarios/invite-lifecycle.ts` — 20 steps
| area | steps | contract § |
|---|---|---|
| create (write) | `channels:create`, `invites:create:default` (capture `invite_code`), `invites:create:refresh:max1` (re-create upsert: max_uses 1, refresh) | §5.8 |
| preview (read) | `invites:preview:member` (member, my_membership active), `invites:preview:stranger` (not_joined) | §5.10 |
| accept | `invites:accept:bob` (join_source `invite`, membership active), `invites:accept:bob:replay` (idempotent), `invites:accept:bob:already-active` (no-op, invite not consumed), `invites:preview:post-accept` (my_membership active for bob) | §5.9, §5.10 |
| remove + max_uses | `members:remove:bob`, `invites:accept:bob:max-uses` (409 INVITE_NOT_AVAILABLE, used_count 1/1) | §5.9 |
| expiry | `invites:create:refresh:short-ttl` (expires_in_seconds 1) + `wait:ttl` (1.5s), `invites:accept:bob:expired` (404 "invite not found"), `invites:preview:expired` (404 "invite expired or revoked") | §5.9, §5.10 |
| wrong code | `invites:preview:wrong-code` (404), `invites:accept:wrong-code` (404) | §5.9, §5.10 |
| reads after | `members:list:post`, `members:show:bob:left`, `events:post` (member.joined join_source `invite` frame) | §7.1, §10.4 |

### `conformance/scenarios/public-join.ts` — 20 steps
| area | steps | contract § |
|---|---|---|
| fixtures (3 visibilities) | `channels:create:public` (public_listed), `channels:create:private`, `channels:create:unlisted` (public_unlisted) | §5.2b |
| list/directory projection | `sync:channels-projected`, `channels:list:post`, `directory:post` | §5.1, §5.6 |
| join (non-member) | `join:bob:public` (fresh join → member), `join:bob:public:replay` (idempotent), `join:bob:public:again` (active-member no-op, existing role), `join:bob:private-gate` (403), `join:bob:unlisted-gate` (403) | §5.7 |
| DM kind gate | `dms:open:for-gate` (fixture DM), `join:bob:dm-gate` (409 UNSUPPORTED_CHANNEL_KIND) | §5.7 |
| dissolved / missing | `channels:dissolve`, `join:bob:dissolved` (409 CHANNEL_DISSOLVED), `join:bob:not-found` (ghost channel → 404 CHANNEL_NOT_FOUND) | §5.4, §5.7 |
| reads after | `members:list:post`, `members:show:bob`, `events:post` (member.joined frame), `channels:detail:bob:post-dissolve` (dissolved channel still readable to member) | §7.1, §10.4, §5.2 |

### `conformance/scenarios/dm-open.ts` — 17 steps
| area | steps | contract § |
|---|---|---|
| open (write) | `dms:open:alice-to-bob` (capture `dmAb`), `dms:open:replay` (idempotent, same channel), `dms:open:bob-to-alice` (reverse pair → same channel, dm_peer flips to alice), `dms:open:missing-recipient` (422 INVALID_DM_TARGET), `dms:open:self` (422), `dms:open:ghost` (404 DM_TARGET_NOT_FOUND), `dms:open:conflict` (same key, different recipient → 409 IDEMPOTENCY_CONFLICT), `dms:open:bob-to-carol` (second pair) | §5.2c, §2.5 |
| list projection | `sync:dm-listed`, `channels:list:bob`, `channels:list:alice` (DM summaries: dm_peer + resolved title) | §5.1 |
| DM-only behaviors | `members:add:dm-gate` (409 UNSUPPORTED_CHANNEL_KIND — no member management on DMs), `commands:dm-manifest` (empty manifest `{version:0, items:[]}`), `channels:detail:dm:bob-view`, `members:list:dm` (both peers, role member), `events:dm` (DM lifecycle frames), `bootstrap:dm` (`?channel_id=` DM active channel: dm_peer + resolved title in `channels[]` and `active_channel`, empty `messages`, `channel_pins []`) | §5.2, §7.1, §10.4, §4.1 |

Scenario invariants honored: deterministic v7-shaped UUID literals for actors/fixtures;
`ALICE_USER_ID`/`BOB_USER_ID` imported from `read-paths.ts` (not redefined); Carol
(`6f1e2c3d-…-5e80`) added to `conformance/fixtures/seed-users.sql`; server-minted ids
captured (`capture`) and interpolated (`${var}`); every write verified via its read
surface in-scenario (members list/show, channel list/detail, events, directory,
bootstrap); retry-until-settled steps (Worker outbox+alarm-fed projections) carry no
readProbe and are followed by probe-only reads; `avatar_attachment_id: null`
everywhere (avoids the known attachments-tick 415/422 delta).

## (b) Per-scenario diff status (trajectory)

| scenario | run 1 | intermediate | final |
|---|---|---|---|
| channel-lifecycle | 0 diffs | — | **0 (GO)** |
| member-lifecycle | 0 diffs | — | **0 (GO)** |
| invite-lifecycle | 1 diff (1 root cause: INVITE_NOT_FOUND wording, Elixir side) | test-first lib fix (c.1) + app restart | **0 (GO)** |
| public-join | 0 diffs | — | **0 (GO)** |
| dm-open | 5 diffs (2 root causes: Elixir bootstrap DM projection; event_state cursor map) | test-first lib fix (c.2) + normalization (d.4) + app restart | **0 (GO)** |

## (c) Elixir fixes (all test-first in `test/`)

1. **Invite preview `INVITE_NOT_FOUND` wordings**
   (`lib/lilium_chat/invites.ex`, `test/lilium_chat/invites_test.exs`):
   the missing-row and missing-channel branches raised the generic default
   ("Invite not found"); the old-Worker reference says "invite not found" there and
   "invite expired or revoked" for revoked/expired. Both branches now carry the explicit
   old-Worker wording (the expired/revoked branch already matched). Test now asserts
   the message per code (missing / revoked / expired / orphan).
2. **Bootstrap DM peer projection** (`lib/lilium_chat/bootstrap.ex`,
   `test/lilium_chat/bootstrap_test.exs`): the bootstrap "tracer-bullet" projection left
   `channels[].dm_peer = null` / `title = ""` for DMs and omitted `dm_peer` from
   `active_channel` entirely, while the old Worker's bootstrap returns the inflated list
   entries (peer UserSummary + peer-derived title/avatar, contract §3.2). Added the
   `dm_peer_user_id` subquery to `query_my_channels/1`, a `with_dm_peer/3` mirror of
   `LiliumChat.Channels.with_dm_peer/3` applied to both `channels[]` and
   `active_channel`, and DM peer ids in the profile batch. Query count unchanged (the
   peer id is an inline subquery of the existing single list query; profiles stay one
   batch).

## (d) Harness / normalization changes (each with contract citation)

`conformance/src/normalize.ts` (module doc carries the full citation table). Batch B
additions:

| normalization | contract citation |
|---|---|
| `invite_url` (response value): host + `/chat/invites/` kept, last path segment (the invite code) → `{{INVITE_CODE}}` | §5.8 — `invite_url = API_BASE_URL + /chat/invites/<code>`; the base is identical on both targets (same configured origin, verified in `wrangler.conformance.jsonc` + `config/config.exs`), the code is server-minted |
| Channel-list `items[]` (GET /channels) and bootstrap `channels[]` SORTED on both sides by (kind, title, dm_peer user_id) | §5.1 pins only the `{items, next_cursor}` shape — no ordering. Old Worker returns `my_channels` insertion order (no ORDER BY); the v2 implementation returns `updated_at DESC, channel_id DESC`. Both are implementation details; the sort key is scenario-deterministic (fixed titles / fixed actor ids), so the order is stable across targets |
| `MEMBER_NOT_FOUND` messages, pinned per old-Worker throw site: `GET …/members/{user_id}` (show) → `"user is not a member of this channel"`; `PATCH/DELETE …/members/{user_id}` (role/remove) + `POST …/owner-transfer` → `"target not an active member"` | §7.1b–§7.5 pin the code (404) but not the wording; the v2 implementation answers the generic "Member not found" everywhere; §2.5 v2.31 delta note licenses the message normalization |
| `CHANNEL_NOT_FOUND` on the member READ routes (list/show) → `"channel not created"` (old-Worker read-route wording); on the join route → `"channel not found"` (old-Worker join-route wording) | §7.1 / §5.7 pin the code (404), not the wording; the v2 implementation answers "Channel not found" everywhere (§2.5 v2.31 delta note) |
| `FORBIDDEN` on the member READ routes (list/show) → `"not a channel member"` | §2.6 envelope wording (same rule as channel detail); old Worker "not a member", v2 implementation "Forbidden" |
| Bootstrap `event_state.per_channel` → `{}` on both sides | §4.1 — the map is `{channel_id: last_event_id}` (server-minted UUIDv7 keys and values) and the target sets differ by design: the old Worker's list rows hardcode `last_event_id: null` (known delta — its per_channel injects only the active NON-DM channel's cursor from the read bundle; a DM active channel gets none), while the v2 implementation populates the map for every listed channel (the contract-correct reading: "每个 channel_summary 项也带自身 last_event_id，二者一致"). Same family as the batch-A `last_event_id` normalization |

All batch-A rules are untouched and still pass (the five pre-existing scenarios were
re-run to diff 0 after the shared-path changes — list sorting, bootstrap handling).

## (e) Environment changes

- Two app restarts after lib changes:
  `podman compose -f docker-compose.yml up -d --force-recreate app` from `lilium-chat-v2/`
  (after the invites fix and after the bootstrap fix).
- `conformance/fixtures/seed-users.sql` now carries the third actor Carol
  (`6f1e2c3d-4a5b-7c8d-9e0f-1a2b3c4d5e80`, "Conformance Carol") — idempotent upsert into
  the shared dev PG, visible to both targets (Worker UserDirectory profile stub +
  Elixir `public.users`).
- Full `mix test` run: **853/853** (baseline 852 + 1 new bootstrap DM test). No flakes
  this batch — `LiliumChatWeb.QueryCountingTest` and the housekeeping attachment-sweep
  test both passed without retry. The batch-A S3-env caveat did not recur (suite green
  without clearing `S3_*` env vars this run).
- Conformance harness `tsc --noEmit` clean after the `normalize.ts` additions.

## (f) Remaining issues

### Old-Worker-vs-contract deltas (recorded; normalized where the contract is silent or both-side-structural)

1. Bootstrap `event_state.per_channel`: the old Worker injects only the active NON-DM
   channel's cursor (and nothing for a DM active channel) because its list rows hardcode
   `last_event_id: null` (batch-A delta #4 family). The v2 implementation's map is the
   contract-correct reading of §4.1. Normalized to `{}` on both sides (d).
2. DM bootstrap `active_channel`: the old Worker returns the inflated list entry (full
   ChannelSummary incl. `dm_peer` + resolved title) where §4.1's example shows the
   11-field ChannelDetail shape — handled by the batch-A `active_channel` trim; this
   batch's Elixir fix (c.2) closes the DM-peer gap so the trimmed shapes match.
3. Invite preview 404 wording: the v2 implementation used the generic "Invite not found"
   default (fixed in lib, c.1) — the old-Worker wording is now canonical per the
   reference-implementation-parity rule.
4. DM `title`/`dm_peer` resolution in channel lists: both sides resolve the peer
   (display name + avatar) for DM summaries — the v2 list route was already conforming;
   the bootstrap projection lagged (fixed, c.2).

### Open items / follow-ups

- **Invite revoke has no HTTP route on either target.** The contract defines the revoked
  *state* (404 `INVITE_NOT_FOUND` covers 不存在/已撤销/已过期) but the route table has no
  revoke endpoint; `revoked_at` is set only via import/debug surfaces. The only reachable
  revocation-adjacent behavior — re-create (upsert) un-revokes + refreshes — is covered
  by `invite-lifecycle`. A future revoke route (or import-surface test) should extend
  that scenario.
- `event_state.per_channel` stays normalized to `{}` until the old-Worker
  `last_event_id: null` list-route delta is resolved or the contract pins the cursor map
  semantics.
- `QueryCountingTest` flake (timing-sensitive, batch-A known) — retry-once in CI if it
  resurfaces.
- Nothing committed per batch instructions — working tree holds: 5 new scenarios +
  registrations (`cli.ts`), `normalize.ts` batch-B rules, `seed-users.sql` (Carol),
  2 `lib/` files (`invites.ex`, `bootstrap.ex`), 2 test files
  (`invites_test.exs`, `bootstrap_test.exs`), this report.
