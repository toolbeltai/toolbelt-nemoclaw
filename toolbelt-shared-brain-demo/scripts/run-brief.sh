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
# Run timestamp — used to title this tick's saved brief artifact (cron passes its own).
RUN_TS="${RUN_TS:-$(date -u +%Y-%m-%dT%H:%MZ)}"

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

run_agent watch    "Record the active severe warnings that have a mapped area to the shared timeline now, following your instructions exactly. Be terse, no narration."
run_agent exposure "Compute and record the geographic exposure for the active severe warnings now — population, buildings, policyholders, and insured value inside each warning area — following your instructions exactly. Be terse, no narration."
run_agent comms    "Write the severe-weather situation brief now: read the timeline, save it with the EXACT title 'Severe-Weather Brief $RUN_TS', then output it as your reply, following your instructions exactly. Be terse, no narration; the brief itself is your reply."

log "Done. Brief saved as 'Severe-Weather Brief $RUN_TS' in the namespace (and shown above)."
