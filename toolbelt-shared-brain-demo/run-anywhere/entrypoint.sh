#!/usr/bin/env sh
# Render config from env, install the Toolbelt skill, run OpenClaw (gateway + the agent team).
set -e
: "${TOOLBELT_NAMESPACE:?set TOOLBELT_NAMESPACE (the shared-brain namespace)}"
: "${MODEL_REF:=nvidia/llama-3.3-nemotron-super-49b-v1}"

# 1. render openclaw.json: fill placeholders + retarget /sandbox/... paths to /root/.openclaw/...
sed -e "s|__TOOLBELT_NAMESPACE__|$TOOLBELT_NAMESPACE|g" \
    -e "s|__TOOLBELT_TOKEN__|${TOOLBELT_TOKEN:-}|g" \
    -e "s|__MODEL_ID__|$MODEL_REF|g" -e "s|__MODEL_REF__|$MODEL_REF|g" \
    -e "s|/sandbox/.openclaw|/root/.openclaw|g" \
    /root/.openclaw/openclaw.template.json > /root/.openclaw/openclaw.json

# 2. point inference at the real Nemotron endpoint (no NemoClaw router here).
#    MODEL_ENDPOINT defaults to NVIDIA's hosted OpenAI-compatible API.
: "${MODEL_ENDPOINT:=https://integrate.api.nvidia.com/v1}"
# (the models.providers.inference.baseUrl in openclaw.json should be MODEL_ENDPOINT; if your build
#  bakes inference.local, sed it here too)
sed -i "s|https://inference.local/v1|$MODEL_ENDPOINT|g" /root/.openclaw/openclaw.json || true

# 3. install the Toolbelt skill bound to the namespace (writes mcp.servers.toolbelt + the skill).
TOOLBELT_TOKEN="${TOOLBELT_TOKEN:-}" TOOLBELT_HOST="${TOOLBELT_HOST:-app.toolbelt.ai}" \
  npx -y @toolbeltai/cli@latest install --client openclaw --namespace "$TOOLBELT_NAMESPACE" || \
  echo "skill install: verify (anonymous onboarding used if TOOLBELT_TOKEN unset)"

# 4. bring up OpenClaw (gateway + daemon). Drive `main` via the TUI/API, or a configured trigger.
#    VERIFY the exact serve/daemon command for your OpenClaw version (onboard --install-daemon, then
#    the gateway stays up; `openclaw tui` or the API drives the agents).
openclaw onboard --install-daemon --non-interactive
exec openclaw gateway
