# Issue #19 — Worker-parity brief (graceful stop + session runtime)

Sources: old Worker `src/chat/{stateful-session,stateful-bot-delivery,platform-pin-interaction,bot-gateway-session,channel-pins,bot-gateway-protocol}.ts`, `src/do/{chat-channel/handlers/{stateful-session,bot-session-effects-handlers},chat-channel/alarm-handler,bot-connection/{object,stateful}}.ts`, `src/contract/{bot-gateway,stateful-session-api}.ts`; contract `docs/api-contract.md` §9.6.4 / §9.7.4 / §9.9. Start (`session.start` / `start_ack` / pin create) is **#20**.

## 1. Row lifecycle

`stateful_command_sessions.status`:

| Status | Meaning |
|---|---|
| `starting` | Inserted by invoke (#20). `input_next_seq=1`, `input_last_acked_seq=0`, `effect_last_acked_seq=0`. |
| `active` | After `session.start_ack`. Effects + listen enqueue allowed. |
| `suspended` | In active-set / stoppable; no Worker writer observed. |
| `closing` | After `platform:stop_session`. Effects still allowed. Repeat stop → `SESSION_STOP_IN_PROGRESS`. |
| `closed` | Terminal. Any close reason except TTL `timeout`. |
| `failed` | Terminal. **Only** TTL expire (`reason === "timeout"`). `start_timeout` / `stop_timeout` are `closed`. |
| `expired` | Named terminal; Worker close path does not write it. |

Active-set (mutex + GET): `starting|active|suspended|closing`. Worker unique index `uniq_active_stateful_session_per_channel` — **missing in Elixir**; add it. Resume-ref set is the same four.

`closeStatefulSession` no-ops if already `closed|expired|failed`. Sets `closed_at`, `close_reason`, emits `stateful_session.closed`, deletes session_control pin + `channel.pin.cleared`, pushes `session.closed`, drops BotConnection ref, deletes alarms `stateful_session_{start_timeout,expire,stop_grace}`.

## 2. Create vs #19 seed

#20 `statefulCommandInvoke` inserts the row + `session.start`. #19 tests **INSERT** an `active` (or `closing`) row + platform `session_control` pin. No public Browser HTTP create/stop (`§9.12.2`). Worker `stopStatefulSession` RPC is immediate close — **do not port**; Browser stop is pin interaction only.

Minimum test helpers: `StatefulSessions.seed_active/1` (listen_rules, seqs=0/1, `expires_at`) + `ChannelPins.upsert_session_control/1`.

## 3. `session.effects` / ack / seq

Bot → server:

```json
{"type":"session.effects","api_version":"lilium.chat.bot.v1","session_id":"…","effect_seq":1,"effects":[{…}]}
```

`effect_seq` integer ≥ 1. First new seq is `effect_last_acked_seq+1` (starts 0). Replay: `effect_seq <= last_acked`. Gap → reject `BOT_EFFECT_INVALID` `"effect sequence gap"`.

Allowlist (`SESSION_GATEWAY_EFFECT_TYPES`): **only** `set_channel_pin` | `update_channel_pin` | `clear_channel_pin`. Not `send_message` / `start_stream` (those stay on `delivery_result`). Contract §9.7.3 is broader; **Worker wins**.

- `set`: `pin_kind` ∈ `{bot_control, announcement}` only. Never set `session_control`.
- `update`: own bot pins; **or** platform session pin if `allowSessionControl=true` (session path only). Session pin **cannot patch `components`**.
- `clear`: own bot pins only; never `session_control` / `pinned_message`.

Status must be `active|closing`. Bot mismatch / no session pin → reject. DM → `UNSUPPORTED_CHANNEL_KIND`.

Idempotency: hash of effects **minus** `client_effect_id` (`JSON.stringify` in Worker). Same seq + same hash → replay stored `effect_results` and re-finalize if needed. Same seq + different hash → `BOT_EFFECT_CONFLICT`. Elixir: `chat_v2.idempotency` namespace `session_effect`, unique `(session_id, effect_seq)` (D10). Then `UPDATE effect_last_acked_seq`.

Ack:

```json
{"type":"session.effects_ack","api_version":"lilium.chat.bot.v1","session_id":"…","effect_seq":1,"status":"applied"|"rejected","effect_results":[{"client_effect_id","type","status":"applied","pin_id","event_id"}],"error":{"code","message"}}
```

Most failures are **rejected acks**, not thrown. Missing BotConnection ref → reject `STATEFUL_SESSION_NOT_FOUND`. Channel apply throw → `CHAT_WORKER_UNAVAILABLE`.

## 4. `session.input` vs `session.stop_requested`

`session.input` is a **sequenced listen event** (`seq`, `channel_id`, `event`, `message`). Stop is a **control frame** (no `seq`). Mixing would ack-advance `input_last_acked_seq` and look like a `message.created`. Tests assert stop frame has no `seq`.

## 5. `platform:stop_session`

Browser: `interaction.submit` + `pin_id` (not `message_id`) + `custom_id=platform:stop_session`. `platform:` prefix = platform short-circuit: no interaction row, no `interaction_id`, bot need not be online.

Order (`applyPlatformStopSessionInTxn`):

1. `custom_id` else `INVALID_MESSAGE`
2. pin exists in channel else `PIN_NOT_FOUND`
3. `pin_kind=session_control` and `pin_owner_kind=platform` else `INVALID_MESSAGE`
4. `pin.session_id` set
5. session same channel else `STATEFUL_SESSION_NOT_FOUND`
6. `closing` → **`SESSION_STOP_IN_PROGRESS` 409**
7. not in `starting|active|suspended` → `STATEFUL_SESSION_NOT_ACTIVE`
8. actor = starter **or** owner/admin else `FORBIDDEN`
9. component on pin else `COMPONENT_NOT_FOUND`; `disabled` → `COMPONENT_DISABLED`

Then same txn: `status=closing`; rebuild pin projection `stopDisabled=true`, `stopLabel="正在停止…"` (keep `component_id`); `channel.pin.updated`; arm grace `now+30000`; enqueue stop frame. Idempotency: `interaction.submit` + `command_id`.

`committed_ack` payload (`PlatformPinInteractionAck`, **no** `interaction_id`):

```json
{"channel_id","event_id","pin_id","session_id","custom_id":"platform:stop_session"}
```

`event_id` = the `channel.pin.updated` id. Wrapped as Browser `command_ack` / `interaction.submit` / `status=committed`.

Stop button (`buildSessionControlStopComponents`): `kind=button`, `custom_id=platform:stop_session`, `style=danger`, `interaction_policy=per_user_once`, label `停止` → `正在停止…`, `disabled=true`. Pin: `pin_owner_id=00000000-0000-7000-8000-000000000600`, `priority=0`.

## 6. `session.stop_requested`

```json
{"type":"session.stop_requested","api_version":"lilium.chat.bot.v1","session_id":"…","reason":"user_stop","actor_user_id":"…","grace_timeout_ms":30000}
```

Worker: outbox kind `stateful_session_stop_requested` → `BotConnection.pushSessionFrame` (JSON to live WS; false if offline → retry). Elixir: `BotConnection.push_frame/2` (already `:offline` if down). No SQLite refs (D10 dropped `active_stateful_session_refs`) — look up `bot_id` from the session row.

## 7. `session.close` / `session.closed`

Bot → server: `{type:"session.close", api_version, session_id, reason?}`. Missing reason → `bot_closed`. BotConnection looks up channel and calls `closeStatefulSession`.

Server → bot: `{type:"session.closed", api_version, session_id, status, reason}`.

Reasons: `user_stop`, `stop_timeout`, `timeout` (TTL → **failed**), `start_timeout` (#20), `bot_closed`, `orphaned`, `backlog_overflow`. Event payload: `{actor_kind:"system", actor_id:"system", session_id, bot_command_id, command_name, status, reason, closed_at}`.

## 8. Timeouts / force-close

| Const | Value | Job / effect |
|---|---|---|
| `SESSION_STOP_GRACE_MS` | **30000** | `stateful_session_stop_grace`; if still `closing` → close `stop_timeout` |
| `SESSION_START_TIMEOUT_MS` | 30000 | #20 only |
| Session TTL | `expires_at` | `stateful_session_expire` on `active|suspended|closing` → close `timeout` → **failed** |
| `DEFAULT_MAX_PENDING_INPUTS` | 1000 | overflow → close `backlog_overflow` |

Force-close: pin DELETE + `channel.pin.cleared` + `stateful_session.closed` + `session.closed` + drop ref. Elixir has no `alarm_jobs` — Channel `Process.send_after` **and** persist `stop_grace_at` (new column; sessions have no `updated_at`). On Channel restart, re-arm or fire due `closing` rows.

## 9. Listen / `stateful_session_inputs` — **#19, not #20**

Table already exists. Enqueue is **runtime on `message.created`**, not invoke:

- Only `status='active'` (not starting/closing)
- `matchesListenRules`: `type` in `message_types`; drop bot senders unless `include_bot_messages`; drop starter’s user msgs unless `include_own_messages`
- INSERT `stateful_session_inputs` (`status=pending`, seq=`input_next_seq`), bump next seq, push:

```json
{"type":"session.input","api_version":"lilium.chat.bot.v1","session_id","channel_id","seq","event":{"event_id","type":"message.created","occurred_at"},"message":{/* §3.4 wire */}}
```

`session.input_ack` `{session_id, last_received_seq}` → `input_last_acked_seq` + rows `acked`. Resume: unacked `pending|sent` with `seq > last_acked`.

**Do not** implement listen as §9.9 `delivery` `kind=message_event`. Worker listen is `session.input`. §9.9 is deferred/legacy wording. Enqueue is not required to close the stop AC, but it is not #20.

## 10. Elixir modules

| Module | Role |
|---|---|
| `LiliumChat.StatefulSession` | statuses, listen match, TTL, constants, seed |
| `LiliumChat.StatefulSessions` | stop / close / expire / enqueue / input_ack — Channel-txn writers |
| `LiliumChat.BotEffects` | `session_gateway_effect_types/0`; `apply_session/3` with `allow_session_control: true`; deepen pin merge + events (#17 stubs) |
| `LiliumChat.BotGateway` | parse/build `session.{effects,effects_ack,stop_requested,close,closed,input,input_ack}` |
| `LiliumChat.ChannelPins` | `build_session_control_projection/1`, disable-Stop update, `clear_by_session_id/2` |
| `LiliumChat.Channel` | `submit_interaction/2`, `session_effects/2`, `session_close/2`; grace + expire timers |
| `LiliumChat.BotConnection` | `handle_session_effects/2`, `handle_session_close/1`; `push_frame` for stop/input/closed |
| `LiliumChatWeb.BrowserChannel` | `interaction.submit` pin locator → platform short-circuit |
| `LiliumChatWeb.BotChannel` | `handle_in` for session frames |
| Migration | partial unique active session/channel; unique session_control/channel; optional `stop_grace_at` |

Reuse: `Idempotency` (`user_command` + `session_effect`), `ChannelEvents`, `Errors` (`SESSION_STOP_IN_PROGRESS` already 409), `CommandManifest` platform bot id, `BotConnection.push_frame/2`.
