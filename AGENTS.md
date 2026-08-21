# Repository Guidelines

`lilium-chat-v2` is the **Elixir/Phoenix rewrite** of the lilium-chat backend
(Cloudflare Worker → single-machine Phoenix + PostgreSQL). Protocol-compatible
drop-in replace: the old repo `../lilium-chat` stays untouched as reference
implementation and conformance differential target.

## Authoritative references (priority order)

1. [`docs/api-contract.md`](docs/api-contract.md) — Browser/Bot API **single source of truth** (v2.31). When contract and implementation disagree, the contract wins.
2. [`docs/specs/2026-08-19-lilium-chat-elixir-redesign.md`](docs/specs/2026-08-19-lilium-chat-elixir-redesign.md) — implementation spec (decisions D1–D18, storage design, phase plan).
3. Old repo `../lilium-chat` — reference implementation (`src/errors.ts`, `src/auth/jwt.ts`, `src/s3/presign.ts`, `src/allowed-origins.ts`, …).

## Development environment (podman — host has no Elixir)

- App: `docker.io/library/elixir:1.20-otp-29` · DB: `docker.io/library/postgres:18`
- `docker-compose.yml` defines both services; `lilium_hex`/`lilium_mix` volumes cache hex + mix archives.
- All Elixir work runs in the container:

```bash
scripts/dev.sh up postgres      # or: .\scripts\dev.ps1 up postgres
scripts/dev.sh deps             # mix deps.get
scripts/dev.sh setup            # mix ecto.setup (create + migrate + seed)
scripts/dev.sh test             # mix test
scripts/dev.sh server           # mix phx.server on http://127.0.0.1:4000
scripts/dev.sh psql             # psql -U chat -d lilium_chat_dev
```

- Raw form: `podman compose run --rm app mix <task>` (env `DB_HOSTNAME=postgres` is set by compose; outside compose use `DB_HOSTNAME=localhost`).
- `devcontainer.json` is an equivalent IDE dev container (VS Code / `devcontainer up`) — same images, DB creds, hex/mix cache volumes; dev-only, not production.

## Build & verification

```bash
mix deps.get
mix compile --warnings-as-errors   # required before claiming done
mix test
```

Conformance harness (spec §7 / issue #1) lives in `conformance/` (Node, not Elixir):

```bash
cd conformance && npm test                              # mock self-diff (CI)
npm run conformance -- run --targets worker,worker      # old-Worker self-diff
npm run conformance -- run --targets worker,elixir      # parity gate
```

See `conformance/README.md`.

## Load-bearing invariants (from spec + contract)

- **Wire shape**: 50 HTTP routes + 3 WS protocols + 68 error codes + envelope
  `{error:{code,message,retryable}}` + `X-Request-Id: req_<uuidv7>` — copy
  semantics from old `src/errors.ts` / `src/ids/uuidv7.ts`.
- **Per-channel monotonic UUIDv7 `event_id`** — no global cursor.
- **Reads strictly read-only**, one PG instance (`chat_v2.*` + `public.users`),
  bounded query count, zero per-channel backend fan-out (spec §4).
- **Storage**: business tables in schema `chat_v2` (Repo default prefix);
  `public.users` (profiles) on the same instance, queried with explicit
  `prefix: "public"`.
- **JWT rules** (spec §6.1): `sub` required; `client_id` present →
  `MACHINE_TOKEN_NOT_ALLOWED`; `managed_session` or owner/effective-account
  mismatch → `SESSION_NOT_ALLOWED`; `admin` claim.
- **SigV4 presign** (spec §6.2): sign with bucket in canonical URI, return PUT
  URL **without** the bucket prefix; `Content-Type` + `Cache-Control` in
  signature; 5min TTL.
- **CORS/Origin whitelist**: `config :lilium_chat, :cors, origins` (copied from
  old `src/allowed-origins.ts`).
- **Idempotency**: `command_id` / `Idempotency-Key` ≡ `operation_id`;
  single `chat_v2.idempotency` table (3 old dedup tables merged, spec D10).
- **Rate limiting**: not implemented; `RATE_LIMITED` 429 code kept for
  contract compatibility but never thrown (spec D9).

## Coding style

Elixir/OTP idioms, 2-space indent, `mix format` (`.formatter.exs` present).
Modules `LiliumChat.*` (domain) / `LiliumChatWeb.*` (web).

## Git discipline

- Conventional Commits (`feat:`, `fix:`, …).
- `git add` only files you changed for the task; never `git restore`
  unrelated modifications.
- Do not push or deploy unless explicitly asked.

## Agent skills

### Issue tracker

Issues and tickets live as GitHub issues in `lilium-toolbear/lilium-chat-v2`, driven through the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Five canonical triage roles map 1:1 to default labels: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context layout: one `CONTEXT.md` + `docs/adr/` at the repo root (none exist yet — created lazily by `/domain-modeling` when terms/decisions get resolved). See `docs/agents/domain.md`.
