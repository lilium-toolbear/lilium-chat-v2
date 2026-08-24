# Release build + deployment (issue #21, spec §2.3 / §10)

Single-machine deployment of the Elixir rewrite: `mix release` single
binary + systemd on gina, front proxy (Caddy/nginx) + Cloudflared tunnel
unchanged (`chat.kuma.homes`).

## 1. Build the release

The host has no Elixir toolchain (everything runs in the podman container,
see AGENTS.md). Build with `MIX_ENV=prod`:

```bash
scripts/dev.sh up app
podman exec lilium_chat_app sh -c 'MIX_ENV=prod mix deps.get && MIX_ENV=prod mix release --overwrite'
```

The release lands at `_build/prod/rel/lilium_chat/`:

- `bin/lilium_chat` — the single binary (`start` / `eval` / `rpc` …);
- `bin/server` — overlay launcher (sets `PHX_SERVER=true`, from
  `rel/overlays/bin/server`);
- `lib/` + `releases/` — the OTP release.

Copy the whole directory to gina:

```bash
rsync -az --delete _build/prod/rel/lilium_chat/ gina:/opt/lilium-chat-v2/
```

## 2. Environment (systemd EnvironmentFile)

`/etc/lilium-chat/lilium_chat.env` (`0600 root:lilium`) — every var from
`config/runtime.exs` (see `.env.example`):

| Var | Required | Notes |
|---|---|---|
| `DATABASE_URL` | yes | `ecto://USER:PASS@HOST/DB` — same PG instance as the old deployment (spec D4) |
| `SECRET_KEY_BASE` | yes | `mix phx.gen.secret` |
| `JWT_SECRET` | yes | reuse the ToolBear JWT secret from the old Worker (spec §6.1) |
| `PHX_HOST` | yes | `chat.kuma.homes` |
| `PORT` | no | default 4000 (front proxy upstream) |
| `S3_*` | no* | SeaweedFS creds for presign (spec §6.2); the app boots without them |
| `SENTRY_DSN` | no | same Sentry instance as the old Worker (`sentry.kuma.homes/api/9/…`) |
| `SENTRY_ENVIRONMENT` | no | default `production` (old Worker parity) |
| `DEBUG_TOKEN` | no | enables `/internal/debug/*`; unset ⇒ debug surface disabled |
| `HOUSEKEEPING_*` | no | GC cadence/TTL overrides (defaults in `config.exs`) |
| `POOL_SIZE` | no | default 10 |
| `ECTO_IPV6` | no | `true`/`1` to bind inet6 |

## 3. systemd

`deploy/lilium_chat.service` — see the header comment in the unit file for
install + ops commands. Summary:

```bash
sudo install -m 644 deploy/lilium_chat.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now lilium_chat
journalctl -u lilium_chat -f          # JSON logs (spec D18)
curl -s localhost:4000/health | jq    # {status: "ok", db: true}
curl -s localhost:4000/metrics | head # Prometheus text format
```

## 4. Ops probes (spec §10)

- `GET /health` — liveness + one PG `SELECT 1`.
- `GET /metrics` — Prometheus scrape (`TelemetryMetricsPrometheus.Core`,
  one port, no second listener). Key series: `lilium_chat_websocket_connections`,
  `lilium_chat_pubsub_subscribers`, `lilium_chat_pubsub_topics`,
  `lilium_chat_pubsub_subscribers_per_topic`, `lilium_chat_streams_active`,
  `lilium_chat_pubsub_broadcast_duration`, `lilium_chat_idempotency_conflict`,
  `lilium_chat_repo_query_*` (PG statement time — the §10 "PG 事务 p99"
  operational proxy via histogram_quantile; Ecto emits no transaction-level
  event, and statement count per request is bounded by
  `lilium_chat_request_query_count_*`, 读路径查询数).
- `/internal/debug/*` — DEBUG_TOKEN-gated read-only SQL surface (old-Worker
  equivalents): `GET /internal/debug/classes`, `POST /internal/debug/sql`,
  `POST /internal/debug/sql-all`. SELECT/WITH only, no statement chaining,
  5s `statement_timeout`, 5000-row cap with a `truncated` flag.

## 5. Housekeeping GC

The app runs a periodic Housekeeping GenServer (60s default) that GCs:

- `chat_v2.idempotency` by `expires_at` (spec D10),
- `pending` attachments past the presign window (spec §6.2),
- stale non-terminal stream rows (contract §9.15.5: empty text → live-only
  `message.stream_abandon_cleanup` frame, no canonical write; non-empty
  text → canonical abandon through the per-channel writer with a
  `message.stream_abandoned` event),
- terminal `bot_deliveries` rows (`delivered`/`dropped`) past retention
  (spec D14; `pending` rows are the crash-recovery queue and are kept).

Tune via `HOUSEKEEPING_*` env vars; per-sweep row counts are logged on
every sweep.

## 6. Not needed anymore (spec §10)

Outbox dead-letter cleanup, alarm-spin巡检, free-tier row limit monitoring,
and the two-Worker deployment are all gone in the single-machine design.
