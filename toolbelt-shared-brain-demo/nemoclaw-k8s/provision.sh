#!/usr/bin/env bash
# In-container provision (the demo's flow, namespace pre-created out of band):
#   1. onboard NemoClaw non-interactively  -> the gateway BUILDS the OpenShell sandbox
#   2. install the Toolbelt skill in the sandbox, bound to $TOOLBELT_NAMESPACE
#   3. render openclaw.json (the agent team) from env + apply to the sandbox
#   4. apply the egress policy + recover the gateway
set -euo pipefail
cd /opt/demo
: "${NEMOCLAW_SANDBOX_NAME:=toolbelt}"; SANDBOX="$NEMOCLAW_SANDBOX_NAME"
: "${TOOLBELT_NAMESPACE:?TOOLBELT_NAMESPACE required (create + adopt datasets out of band; see k8s/README)}"
: "${NEMOCLAW_MODEL:=nvidia/llama-3.3-nemotron-super-49b-v1}"
log(){ printf '\n==> %s\n' "$*"; }

log "onboard NemoClaw (gateway builds the OpenShell sandbox)"
nemoclaw onboard --non-interactive

log "install Toolbelt skill in sandbox '$SANDBOX' (namespace $TOOLBELT_NAMESPACE)"
nemoclaw sandbox exec "$SANDBOX" --no-tty -- env \
  ${TOOLBELT_TOKEN:+TOOLBELT_TOKEN=$TOOLBELT_TOKEN} TOOLBELT_HOST="${TOOLBELT_HOST:-app.toolbelt.ai}" \
  npx -y @toolbeltai/cli@latest install --client openclaw --namespace "$TOOLBELT_NAMESPACE"

log "render + apply the agent-team openclaw.json"
sed -e "s|__TOOLBELT_NAMESPACE__|$TOOLBELT_NAMESPACE|g" \
    -e "s|__TOOLBELT_TOKEN__|${TOOLBELT_TOKEN:-}|g" \
    -e "s|__MODEL_ID__|$NEMOCLAW_MODEL|g" -e "s|__MODEL_REF__|$NEMOCLAW_MODEL|g" \
    openclaw.template.json > /tmp/openclaw.json
# Copy the four personas + config into the sandbox workspaces, then set config.
# VERIFY exact subcommands for your NemoClaw version (sandbox cp / config set).
nemoclaw sandbox cp "$SANDBOX" /tmp/openclaw.json /sandbox/.openclaw/openclaw.json 2>/dev/null || \
  echo "  (apply /tmp/openclaw.json into the sandbox's openclaw.json — verify subcommand)"
for p in main watch exposure comms; do
  nemoclaw sandbox cp "$SANDBOX" "workspaces/$p.md" "/sandbox/.openclaw/workspace-$p/AGENTS.md" 2>/dev/null || true
done

log "apply egress policy + recover"
nemoclaw sandbox policy add "$SANDBOX" --from-file ./policy.yaml --yes
nemoclaw sandbox recover "$SANDBOX"
log "provisioned. sandbox=$SANDBOX namespace=$TOOLBELT_NAMESPACE"
