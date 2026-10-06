# lib.sh: shared helper for the run-*.sh beats. Each agent runs as a host-driven turn, embedded in the
# gateway (no in-sandbox spawn; see NemoClaw #5237 notes in ../toolbelt-shared-brain-demo/STATUS.md).
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$REPO/.env" ] && { set -a; . "$REPO/.env"; set +a; }
SB="${NEMOCLAW_SANDBOX_NAME:-toolbelt-catdesk}"
log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# run_agent <id> <session> <message>: one turn, then the tool summary and the visible reply.
# --thinking off keeps Nemotron's reasoning out of the tool-calling turns.
run_agent() {
  local id="$1" session="$2" msg="$3"
  log "$id"
  nemoclaw "$SB" agent --agent "$id" --json --thinking off --session-id "$session" -m "$msg" 2>&1 \
    | grep -vaE "UNDICI|trace-warnings" \
    | python3 -c '
import sys,json
raw=sys.stdin.read().strip()
try:
    d=json.loads(raw); m=d["result"]["meta"]
except Exception:
    print("  (could not parse turn output)"); print("  "+raw[:400]); sys.exit(0)
ts=m.get("toolSummary") or {}
print("  tools: %s | calls=%s failures=%s" % (",".join(ts.get("tools") or []), ts.get("calls"), ts.get("failures")))
print("  ---")
txt=(m.get("finalAssistantVisibleText") or m.get("finalAssistantRawText") or "").strip()
# Short replies sometimes arrive split mid-word ("Record" / "ed coverage..."); rejoin them.
if len(txt) < 240 and "\n" in txt: txt = "".join(txt.splitlines())
for line in (txt or "(no visible text)").splitlines():
    print("  "+line)
'
}
