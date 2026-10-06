#!/usr/bin/env bash
# run-correction.sh: the governance beat. The cat manager gives one correction; the governance agent,
# whose only tool is lesson_propose, turns it into a proposed lesson. After the owner approves it in Atlas, the next run-morning.sh follows it.
#   ./scripts/run-correction.sh "Always flag any reinsurer with a negative rating outlook for a credit review in the brief."
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[ -n "${1:-}" ] || { echo "usage: $0 \"<the correction>\""; exit 1; }
run_agent governance "correction-$(date -u +%Y%m%dT%H%M%S)" "Cat manager correction: $1"
log "Approve the draft lesson in Atlas (namespace > Lessons), then rerun ./scripts/run-morning.sh."
