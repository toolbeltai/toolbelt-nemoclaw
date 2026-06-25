#!/usr/bin/env bash
# patch-forward-gateway-ws-host.sh — make `nemoclaw onboard` forward
# NEMOCLAW_GATEWAY_WS_HOST into the sandbox container (works around a NemoClaw gap
# related to issue #5237).
#
# Background: #5237 — every `sessions_spawn` child dies with WS `1006` when
# OPENCLAW_GATEWAY_URL points at loopback, because the OpenShell L7 proxy
# hard-blocks loopback dial-backs from the enforced process tree. nemoclaw-start.sh
# already fixes this by deriving the gateway WS host from `hostname -I` (the
# sandbox's eth0, e.g. 10.200.0.2) and exposes a NEMOCLAW_GATEWAY_WS_HOST override.
# BUT in sandboxes where `hostname -I` yields nothing (busybox / no queryable IP),
# the derive falls back to loopback (the broken state), and the override is the only
# escape hatch — except onboard never forwards it into the sandbox.
# sandbox-create-launch.js forwards NEMOCLAW_PROXY_HOST/PORT but not the gateway WS
# host, so the documented knob is unreachable from the host. This adds the forward,
# mirroring the existing PROXY_HOST block. Idempotent. Re-run after `nemoclaw update`.
set -euo pipefail

TARGET="${1:-}"
if [ -z "$TARGET" ]; then
  for c in "$HOME/.nemoclaw/source/dist/lib/onboard/sandbox-create-launch.js" \
           "$HOME/.nemoclaw/source/bin/lib/onboard/sandbox-create-launch.js"; do
    [ -f "$c" ] && { TARGET="$c"; break; }
  done
fi
[ -n "$TARGET" ] && [ -f "$TARGET" ] || { echo "ERROR: cannot find sandbox-create-launch.js under ~/.nemoclaw" >&2; exit 1; }

MARKER="issue #5237: forward NEMOCLAW_GATEWAY_WS_HOST into the sandbox"
if grep -q "$MARKER" "$TARGET"; then
  echo "Already patched: $TARGET"
  exit 0
fi

python3 - "$TARGET" "$MARKER" <<'PY'
import sys, re
from pathlib import Path

path, marker = Path(sys.argv[1]), sys.argv[2]
text = path.read_text()

# Insert right before the extraPlaceholderKeys forward, i.e. after the PROXY_PORT block.
anchor = "    (0, extra_placeholder_keys_1.appendExtraPlaceholderKeysEnvArg)(envArgs, input.extraPlaceholderKeys, url_utils_1.formatEnvAssignment);\n"
idx = text.find(anchor)
if idx == -1:
    raise SystemExit("Could not find the extraPlaceholderKeys anchor; NemoClaw internals may have changed.")

insertion = (
    "    // " + marker + ":\n"
    "    // nemoclaw-start.sh reads NEMOCLAW_GATEWAY_WS_HOST to override the gateway\n"
    "    // dial-back host, but the sandbox only receives explicitly-forwarded env.\n"
    "    // Forward it (validated as a bare host/IP) so the override actually reaches\n"
    "    // the runtime when `hostname -I` can't derive the eth0 address.\n"
    "    const sandboxGatewayWsHost = env.NEMOCLAW_GATEWAY_WS_HOST;\n"
    "    if (sandboxGatewayWsHost && /^[A-Za-z0-9.:_-]+$/.test(sandboxGatewayWsHost)) {\n"
    "        envArgs.push((0, url_utils_1.formatEnvAssignment)(\"NEMOCLAW_GATEWAY_WS_HOST\", sandboxGatewayWsHost));\n"
    "    }\n"
)
path.write_text(text[:idx] + insertion + text[idx:])
PY

echo "Patched (forward NEMOCLAW_GATEWAY_WS_HOST): $TARGET"
