#!/usr/bin/env bash
# Tail the Overeasy backend logs.
#
#   ./scripts/logs.sh              # follow api + worker, noise filtered
#   ./scripts/logs.sh all          # follow every service
#   ./scripts/logs.sh worker 200   # last 200 lines of one service
set -euo pipefail
cd "$(dirname "$0")/.."

SERVICE="${1:-api worker}"
TAIL="${2:-100}"
[ "$SERVICE" = "all" ] && SERVICE=""

# shellcheck disable=SC2086
docker compose logs --follow --tail "$TAIL" $SERVICE \
  | grep --line-buffered -vE "/health/(live|ready)|celery.*ping"
