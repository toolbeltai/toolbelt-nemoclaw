#!/usr/bin/env bash
# patch-build-tool-calls.sh — work around NemoClaw issue #976 for the NVIDIA `build` provider.
#
# The build provider resolves its inference API from an endpoint probe, which for the NVIDIA
# build endpoint selects NVIDIA's /v1/responses API. That API does NOT run a server-side
# tool-call parser for Nemotron, so tool calls come back as raw text instead of structured
# tool_calls; OpenClaw never sees a real tool call and the agent ends up exec'ing the bare
# tool name. The local provider paths (vLLM / NIM / Ollama) already force chat completions
# for this exact reason; the build path does not. This forces it too.
#
# `openai-completions` in NemoClaw == the OpenAI Chat Completions API (/v1/chat/completions),
# which DOES parse tool calls. Idempotent. Re-run after every `nemoclaw update` (it edits
# installed JS). After patching, `nemoclaw sandbox destroy` + re-onboard — the API flavor is
# baked at onboard time.
set -euo pipefail

TARGET="${1:-}"
if [ -z "$TARGET" ]; then
  for c in "$HOME/.nemoclaw/source/dist/lib/onboard.js" "$HOME/.nemoclaw/source/bin/lib/onboard.js"; do
    [ -f "$c" ] && { TARGET="$c"; break; }
  done
fi
[ -n "$TARGET" ] && [ -f "$TARGET" ] || { echo "ERROR: cannot find NemoClaw onboard.js (looked under ~/.nemoclaw)" >&2; exit 1; }

MARKER="issue #976: force chat completions for build provider tool-calling"
if grep -q "$MARKER" "$TARGET"; then
  echo "Already patched: $TARGET"
  exit 0
fi

python3 - "$TARGET" "$MARKER" <<'PY'
import sys
from pathlib import Path

path, marker = Path(sys.argv[1]), sys.argv[2]
text = path.read_text()

# The build provider block assigns the probed API; we override it to chat completions.
anchor = "        state.preferredInferenceApi = buildValidation.preferredInferenceApi;\n"
idx = text.find(anchor)
if idx == -1:
    raise SystemExit("Could not find the build-provider preferredInferenceApi assignment. "
                     "NemoClaw internals may have changed; re-check onboard.js.")

insertion = (
    "        // " + marker + ":\n"
    "        // NVIDIA /v1/responses has no server-side tool-call parser for Nemotron, so\n"
    "        // tool calls leak as raw text. Force /v1/chat/completions which parses them.\n"
    "        state.preferredInferenceApi = \"openai-completions\";\n"
)
after = idx + len(anchor)
path.write_text(text[:after] + insertion + text[after:])
PY

echo "Patched (forced chat completions for build provider): $TARGET"
