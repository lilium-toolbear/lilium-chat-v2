# lilium-chat-v2

Elixir/Phoenix rewrite of the lilium-chat backend — **single-machine deploy,
protocol-compatible drop-in replace** for the Cloudflare Worker.

- **Spec (实现 spec)**: [`docs/specs/2026-08-19-lilium-chat-elixir-redesign.md`](docs/specs/2026-08-19-lilium-chat-elixir-redesign.md)
- **Research**: [`docs/specs/2026-08-19-elixir-rewrite-research.md`](docs/specs/2026-08-19-elixir-rewrite-research.md)
- **API contract (source of truth, v2.31)**: [`docs/api-contract.md`](docs/api-contract.md)
- **Old repo (reference + conformance target)**: `../lilium-chat`

## Tech stack (spec §2.1)

| Layer | Choice |
|---|---|
| HTTP/WS | Phoenix 1.7 + Bandit |
| Runtime | Elixir 1.20 / OTP 29 |
| DB | PostgreSQL 18 — business tables in schema `chat_v2`, profiles in `public.users`, same instance |
| Internal messaging | Phoenix.PubSub (per-channel / per-user topics) |
| JWT | joken (HS256, same `JWT_SECRET` as the old Worker) |
| S3 SigV4 | self-implemented (spec §6.2: sign with bucket, return without bucket) |
| Observability | Telemetry → Prometheus, Sentry, JSON logs |

## Development environment (podman)

The host has **no Elixir toolchain** — everything runs in containers:

- `docker.io/library/elixir:1.20-otp-29` — app (deps, compile, server, tests)
- `docker.io/library/postgres:18` — database

`docker-compose.yml` wires both together; `lilium_hex` / `lilium_mix`
named volumes cache hex packages and mix archives across runs.

```bash
# bash (git-bash / WSL)
scripts/dev.sh up                    # postgres + app (mix phx.server on :4000)
scripts/dev.sh up postgres           # DB only
scripts/dev.sh deps                  # mix deps.get
scripts/dev.sh setup                 # mix ecto.setup (create + migrate + seed)
scripts/dev.sh test                  # mix test
scripts/dev.sh psql                  # psql shell into the dev DB
scripts/dev.sh logs app              # tail logs
scripts/dev.sh down                  # stop + remove containers

# PowerShell (native Windows)
.\scripts\dev.ps1 up
.\scripts\dev.ps1 test
```

Or plain podman compose:

```bash
podman compose up -d postgres
podman compose run --rm app mix deps.get
podman compose run --rm app mix test
podman compose up app        # foreground: mix phx.server on http://127.0.0.1:4000
```

App: <http://127.0.0.1:4000> — `GET /api/chat/health` (liveness + DB check).

## Configuration

Env vars (see `.env.example`):

| Var | Purpose |
|---|---|
| `JWT_SECRET` | ToolBear JWT HS256 secret (spec §6.1) — reuse the old deployment's value |
| `S3_ACCESS_KEY_ID` / `S3_SECRET_ACCESS_KEY` / `S3_ENDPOINT` / `S3_BUCKET` | SeaweedFS SigV4 presign (spec §6.2) |
| `PRESIGN_TTL_SECONDS` | presign TTL, default 300 |
| `SENTRY_DSN` | Sentry destination (spec §10) |
| `DB_HOSTNAME` / `DB_PORT` | dev DB location (compose sets `DB_HOSTNAME=postgres`) |

CORS origins default to the old repo's whitelist (`lilium.kuma.homes` +
localhost:5174/3334) — `config :lilium_chat, :cors, origins`.

## Layout

```
config/                  app + endpoint + repo config (chat_v2 schema)
lib/lilium_chat/         domain (context, repo, processes)
lib/lilium_chat_web/     endpoint, router (/api/chat/*), controllers
priv/repo/migrations/    Ecto migrations → chat_v2 schema
scripts/dev.{sh,ps1}     podman dev environment helpers
docker-compose.yml       postgres:18 + elixir:1.20-otp-29 dev env
docs/                    spec + api-contract (v2.31, SoT)
```

## Conventions

- Wire format follows `docs/api-contract.md` (v2.31) — 50 routes, 3 WS
  protocols, 68 error codes, envelope `{error:{code,message,retryable}}`,
  `X-Request-Id: req_<uuidv7>`.
- Per-channel **monotonic UUIDv7** `event_id` (contract invariant).
- Reads are strictly read-only and hit one PG instance with bounded
  query count (spec §4) — no per-channel backend fan-out.
- Old repo stays untouched; it is the conformance differential target
  (`wrangler dev`) and the reference implementation.
