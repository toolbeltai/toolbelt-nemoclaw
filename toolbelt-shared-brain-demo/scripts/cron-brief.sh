#!/usr/bin/env bash
# cron-brief.sh — scheduled driver for the shared-brain severe-weather brief.
#
# Runs the watch -> exposure -> comms sibling pipeline against an ALREADY-ONBOARDED sandbox
# and saves a timestamped brief artifact to the Toolbelt namespace each tick. Intended for cron.
#
# Prereqs (one time): ./scripts/setup.sh   (onboards the sandbox + seeds the namespace)
# Install (every 30 min): see the crontab line at the bottom of this file.
#
# Each run:
#   - stamps a UTC run id (RUN_TS) used as the saved brief's title,
#   - verifies the sandbox gateway is reachable (skips the tick if it isn't — cron retries),
#   - runs run-brief.sh, logging the full transcript to brief-runs/brief-<RUN_TS>.log.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$REPO/.env" ] && { set -a; . "$REPO/.env"; set +a; }
SB="${NEMOCLAW_SANDBOX_NAME:-toolbelt-shared-brain}"

export RUN_TS="$(date -u +%Y-%m-%dT%H:%MZ)"
LOGDIR="$REPO/brief-runs"; mkdir -p "$LOGDIR"
LOG="$LOGDIR/brief-$RUN_TS.log"

ts() { printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }

# Health gate: only run if the sandbox gateway answers. `nemoclaw list` shows running sandboxes;
# require ours to be present. (A deeper check would exec a no-op, but that can hang on a degraded
# gateway, so we keep the gate light and let run-brief.sh surface any per-turn errors into the log.)
if ! nemoclaw list 2>/dev/null | grep -q "$SB"; then
  ts "sandbox '$SB' not running — skipping this tick (run ./scripts/setup.sh once to onboard)" | tee -a "$LOG"
  exit 0
fi

ts "starting brief run RUN_TS=$RUN_TS" | tee -a "$LOG"
RUN_TS="$RUN_TS" "$REPO/scripts/run-brief.sh" >> "$LOG" 2>&1
rc=$?
ts "finished rc=$rc — artifact: 'Severe-Weather Brief $RUN_TS' (log: $LOG)" | tee -a "$LOG"
exit "$rc"

# ─────────────────────────────────────────────────────────────────────────────
# Install as a cron job (every 30 minutes). Edit your crontab with `crontab -e`
# and add (absolute paths required; cron has a minimal PATH so we set it):
#
#   PATH=/Users/jradonich/.local/bin:/usr/local/bin:/usr/bin:/bin
#   */30 * * * * /Users/jradonich/dev/tool/toolbelt-claw/toolbelt-shared-brain-demo/scripts/cron-brief.sh >> /Users/jradonich/dev/tool/toolbelt-claw/toolbelt-shared-brain-demo/brief-runs/cron.log 2>&1
#
# Notes:
#  - `nemoclaw` must be on cron's PATH (adjust the PATH line to wherever `which nemoclaw` lives).
#  - The sandbox must stay onboarded; if the host reboots, re-run ./scripts/setup.sh.
#  - Each tick writes brief-runs/brief-<UTC>.log and saves a dated brief doc in the namespace.
# ─────────────────────────────────────────────────────────────────────────────
