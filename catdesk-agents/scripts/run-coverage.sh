#!/usr/bin/env bash
# run-coverage.sh: the on-camera beat. Run it mid-take, after the trigger has written some exposure
# findings. The coverage agent reads them from the shared brain and records its correction to the
# timeline, which the View shows.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
run_agent coverage "coverage-$(date -u +%Y%m%dT%H%M%S)" \
  "Check the exposure findings in the shared brain against what the policies pay and record your corrections now, following your instructions exactly. Be terse, no narration."
