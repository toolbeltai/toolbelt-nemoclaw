#!/usr/bin/env bash
# run-morning.sh: the morning beat. Run it after a full take. The synthesis agent reads the shared
# brain (SQL for amounts, the graph for who is connected), records a decision, and saves a brief that
# the View's brief section picks up.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
NAME="catdesk_brief_$(date -u +%Y%m%dT%H%M)"
run_agent synthesis "synthesis-$(date -u +%Y%m%dT%H%M%S)" \
  "Write the morning brief now and save it with the EXACT name '$NAME', following your instructions exactly. Be terse, no narration."
log "Done. Brief saved as '$NAME'; reload the View to see it."
