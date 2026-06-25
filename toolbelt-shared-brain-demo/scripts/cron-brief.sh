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
# cron runs with a minimal PATH; make sure `nemoclaw` (commonly in ~/.local/bin or /usr/local/bin)
# and friends are found on both macOS and Linux. Adjust if your nemoclaw lives elsewhere.
export PATH="$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:${PATH:-}"
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
# Install as a cron job (every 30 minutes): just run ./scripts/install-cron.sh — it derives the
# repo path and schedules this script portably (no hardcoded paths). To do it by hand instead,
# `crontab -e` and add one line (absolute path to THIS script, wherever you cloned the repo):
#
#   */30 * * * * /ABSOLUTE/PATH/TO/scripts/cron-brief.sh >> /ABSOLUTE/PATH/TO/brief-runs/cron.log 2>&1
#
# Notes:
#  - This script sets PATH at the top so cron finds `nemoclaw`; edit that line if yours is elsewhere.
#  - The sandbox must stay onboarded; if the host reboots, re-run ./scripts/setup.sh.
#  - Each tick writes brief-runs/brief-<UTC>.log and saves a dated brief doc in the namespace.
# ─────────────────────────────────────────────────────────────────────────────
