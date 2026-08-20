#!/usr/bin/env bash
# lilium-chat-v2 dev environment (podman).
#
# The host has no Elixir toolchain — all Elixir work runs in the
# elixir:1.20-otp-29 container (docker-compose.yml).
#
# Usage:
#   scripts/dev.sh up [postgres|app]   # start services (default: all)
#   scripts/dev.sh down                # stop + remove containers
#   scripts/dev.sh logs [svc]          # tail logs (default: all)
#   scripts/dev.sh deps                # mix deps.get
#   scripts/dev.sh setup               # create + migrate dev DB
#   scripts/dev.sh server              # start app (mix phx.server) on :4000
#   scripts/dev.sh test [mix args...]  # run mix test
#   scripts/dev.sh psql                # psql shell into the dev DB
set -euo pipefail
cd "$(dirname "$0")/.."

cmd="${1:-help}"
shift || true

case "$cmd" in
  up)
    podman compose up -d "${1:-}"
    ;;
  down)
    podman compose down
    ;;
  logs)
    podman compose logs -f "${1:-}"
    ;;
  deps)
    podman compose run --rm app mix deps.get
    ;;
  setup)
    podman compose up -d postgres
    podman compose run --rm app mix ecto.setup
    ;;
  server)
    podman compose up -d postgres
    podman compose up app
    ;;
  test)
    podman compose up -d postgres
    podman compose run --rm app mix test "$@"
    ;;
  psql)
    podman compose exec postgres psql -U chat -d lilium_chat_dev
    ;;
  help | *)
    sed -n '2,17p' "$0" | sed 's/^# \{0,2\}//'
    ;;
esac
