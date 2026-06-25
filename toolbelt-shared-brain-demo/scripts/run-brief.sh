#!/usr/bin/env bash
# run-brief.sh — drive the shared-brain demo as SIBLING agents (no main->spawn).
#
# Why siblings (this is the PRIMARY orchestration for the demo): NemoClaw's `sessions_spawn`
# (main spawning sub-agents IN the sandbox) is blocked by NemoClaw #5237 — the spawned child must
# dial the gateway over the sandbox's eth0 (loopback is hard-blocked by the OpenShell L7 proxy),
# but a non-loopback in-sandbox client gets no loopback auth-bypass, token auth does not satisfy
# the gateway's mandatory device pairing, and the auto-pair watcher can't approve over that same
# gated connection -> permanent WS 1008. (Full analysis in STATUS.md.) Host-driven turns avoid all
# of this: `nemoclaw <sb> agent --agent <id>` runs EMBEDDED in the gateway (transport: embedded),
# so there is no in-sandbox dial-back and no pairing. This driver therefore invokes each agent as
# its own host-driven turn, in sequence. They never talk to each other; they coordinate through the
# shared Toolbelt timeline (the demo's actual thesis: one shared brain, no agent-to-agent wiring).
# comms produces the final brief.
#
# Usage: ./scripts/run-brief.sh
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$REPO/.env" ] && { set -a; . "$REPO/.env"; set +a; }
SB="${NEMOCLAW_SANDBOX_NAME:-toolbelt-shared-brain}"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# Run one agent turn as a sibling and print its tool activity + visible output.
run_agent() {
  local id="$1" msg="$2"
  log "$id"
  nemoclaw "$SB" agent --agent "$id" --json --session-id "${id}-brief" -m "$msg" 2>&1 \
    | grep -vaE "UNDICI|trace-warnings" \
    | python3 -c '
import sys,json
raw=sys.stdin.read().strip()
try:
    d=json.loads(raw); m=d["result"]["meta"]
except Exception:
    print("  (could not parse turn output)"); print("  "+raw[:300]); sys.exit(0)
ts=m.get("toolSummary") or {}
print("  tools: %s | calls=%s failures=%s" % (",".join(ts.get("tools") or []), ts.get("calls"), ts.get("failures")))
print("  ---")
txt=(m.get("finalAssistantVisibleText") or m.get("finalAssistantRawText") or "").strip()
for line in (txt or "(no visible text)").splitlines():
    print("  "+line)
'
}

run_agent watch    "Use your Toolbelt MCP tools to find the current active Severe/Extreme severe-weather alerts in weather.nws_alerts and record each to the shared timeline. Do not fetch any external data."
run_agent exposure "Read the alerts the watch agent recorded on the shared timeline, then use Toolbelt SQL to estimate who and what is in the path (population via census_blocks_2024, structures via building_footprints), and record your exposure findings to the shared timeline."
run_agent comms    "Read the alerts and exposure findings from the shared timeline and draft a concise severe-weather situation brief (headline hazards, exposure, recommended communication). Save it. Ground every number only in what is on the timeline."

log "Done. The brief is comms's output above (also saved to the namespace)."
