#!/usr/bin/env bash
# catdesk-demo.sh: run the cat-desk demo end to end with one command.
#
# Clears the shared brain (findings for the run, lessons from earlier takes), replays the Gulf storm
# fleet the way Play does on the trigger page, runs the coverage agent mid-fleet, then the morning
# brief, the cat manager's correction, the lesson approval and the second brief. Open the View to
# watch it fill in.
#
#   ./catdesk-demo.sh                    full take; the lesson is approved through the API
#   ./catdesk-demo.sh --approve wait     pause until a person approves the lesson in Atlas
#   ./catdesk-demo.sh --restart          stop the fleet halfway and resume it (the restart beat)
#   ./catdesk-demo.sh --reset-only       just clear the brain for the next take
#
# First run on a new box: fill in catdesk-agents/.env (see catdesk-agents/README.md). If the
# NemoClaw sandbox does not exist yet, this script runs catdesk-agents/scripts/setup.sh first.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS="$REPO/catdesk-agents"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

for cmd in docker nemoclaw python3 curl; do
  command -v "$cmd" >/dev/null || die "$cmd is not installed (see catdesk-agents/README.md, 'A new box')"
done
docker ps -q >/dev/null 2>&1 || die "Docker is not running"

if [ ! -f "$AGENTS/.env" ]; then
  cp "$AGENTS/.env.example" "$AGENTS/.env"
  chmod 600 "$AGENTS/.env"
  die "created catdesk-agents/.env from the example; set NEMOCLAW_PROVIDER_KEY and TOOLBELT_TOKEN in it, then rerun"
fi
set -a; . "$AGENTS/.env"; set +a
[ -n "${TOOLBELT_TOKEN:-}" ] || die "TOOLBELT_TOKEN is empty in catdesk-agents/.env"
[ -n "${NEMOCLAW_PROVIDER_KEY:-}" ] || die "NEMOCLAW_PROVIDER_KEY is empty in catdesk-agents/.env"

SANDBOX="${NEMOCLAW_SANDBOX_NAME:-toolbelt-catdesk}"
if ! nemoclaw list --json 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); sys.exit(0 if sys.argv[1] in [s.get("name") for s in d.get("sandboxes",[])] else 1)' "$SANDBOX"; then
  log "NemoClaw sandbox '$SANDBOX' not found; running setup (about 10 minutes the first time)"
  "$AGENTS/scripts/setup.sh"
fi

# BUN in .env picks a specific Bun, e.g. an arm64 build when a shared home holds an x86 one.
BUN="${BUN:-$(command -v bun || true)}"
[ -n "$BUN" ] || die "bun is not installed (see catdesk-agents/README.md, 'A new box')"
"$BUN" --version >/dev/null 2>&1 || die "$BUN does not run on this machine ($(uname -m)); install a Bun for it and set BUN in catdesk-agents/.env"

# Default to approving through the API so the take runs unattended.
args=("$@")
case " $* " in *" --approve "*) ;; *) args+=(--approve auto) ;; esac

exec "$BUN" run "$REPO/catdesk-director/director.ts" "${args[@]}"
