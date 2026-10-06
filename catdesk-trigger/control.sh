#!/usr/bin/env bash
# One-command spin-up for the cat-desk control room.
# Reads the token from ../catdesk-agents/.env so you don't paste it, starts the
# trigger server, and opens the browser. Ctrl-C stops it.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENVF="$HERE/../catdesk-agents/.env"
[ -f "$ENVF" ] && { set -a; . "$ENVF"; set +a; }
: "${TOOLBELT_TOKEN:?set TOOLBELT_TOKEN in catdesk-agents/.env (a tb_ token with write access)}"
export NAMESPACE_ID="${NAMESPACE_ID:-${TOOLBELT_NAMESPACE:-664f9ed5-a82e-4908-92bb-d5d209f5fb1c}}"
# Pick the first free port from PORT (default 8787) upward, so a stray server never blocks us.
PORT="${PORT:-8787}"
while lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; do
  echo "port $PORT is busy, trying $((PORT+1))"; PORT=$((PORT+1))
done
export PORT
URL="http://localhost:$PORT"
echo "Cat-desk control room -> $URL   (namespace $NAMESPACE_ID)"
( sleep 1.3; command -v open >/dev/null 2>&1 && open "$URL" >/dev/null 2>&1 || true ) &
exec bun run "$HERE/server.ts"
