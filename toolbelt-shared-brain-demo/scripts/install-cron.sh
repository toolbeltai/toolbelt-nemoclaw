#!/usr/bin/env bash
# install-cron.sh — schedule the shared-brain brief every 30 minutes, portably.
#
# Derives the repo path from this script's own location (no hardcoded paths), so it works from
# whatever directory you cloned into, on macOS or Linux. Idempotent: replaces any prior cron-brief
# entry. Run it AFTER ./scripts/setup.sh has onboarded the sandbox.
#
# Override the schedule:  BRIEF_CRON_SCHEDULE="*/15 * * * *" ./scripts/install-cron.sh
# Remove the job:         ./scripts/install-cron.sh --uninstall
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEDULE="${BRIEF_CRON_SCHEDULE:-*/30 * * * *}"
CRON_CMD="$REPO/scripts/cron-brief.sh >> $REPO/brief-runs/cron.log 2>&1"
LINE="$SCHEDULE $CRON_CMD"

mkdir -p "$REPO/brief-runs"

# Current crontab minus any prior entry for this repo's cron-brief.sh (keeps your other jobs).
current="$(crontab -l 2>/dev/null | grep -vF "$REPO/scripts/cron-brief.sh" || true)"

if [ "${1:-}" = "--uninstall" ]; then
  printf '%s\n' "$current" | grep -v '^$' | crontab - 2>/dev/null || true
  echo "Removed the shared-brain cron entry. Current crontab:"; crontab -l 2>/dev/null || echo "(empty)"
  exit 0
fi

# Sanity: nemoclaw must be installed (cron-brief.sh needs it; it sets PATH itself at runtime).
command -v nemoclaw >/dev/null 2>&1 || echo "WARNING: 'nemoclaw' not on PATH now — ensure it's installed for the cron user." >&2

new="$(printf '%s\n%s\n' "$current" "$LINE" | grep -v '^$')"

echo "Installing cron entry:"
echo "  $LINE"
if printf '%s\n' "$new" | crontab - 2>/dev/null; then
  echo "Installed. Current crontab:"
  crontab -l 2>/dev/null
else
  # Some systems (e.g. macOS without Full Disk Access for the calling process) block programmatic
  # crontab writes. Fall back to writing a file the user can install manually.
  out="$REPO/brief-runs/crontab.proposed"
  printf '%s\n' "$new" > "$out"
  echo "Could not write crontab automatically (permissions?)."
  echo "Install it yourself with:"
  echo "  crontab \"$out\""
  echo "or run 'crontab -e' and add this line:"
  echo "  $LINE"
fi
