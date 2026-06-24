#!/usr/bin/env bash
# setup.sh — stand up the Toolbelt shared-brain demo on NemoClaw in one command.
#   1. onboard NemoClaw non-interactively (Nemotron via build.nvidia.com from .env)
#   2. create a Toolbelt namespace + adopt the public datasets (the shared brain)
#   3. install the Toolbelt skill inside the sandbox (writes mcp.servers.toolbelt + skill)
#   4. fill openclaw.json placeholders, apply the egress policy, recover the gateway
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$REPO/.env" ] && { set -a; . "$REPO/.env"; set +a; }
: "${NEMOCLAW_SANDBOX_NAME:=toolbelt-shared-brain}"
SANDBOX="$NEMOCLAW_SANDBOX_NAME"
log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# --- 1. install + onboard NemoClaw ---
if command -v nemoclaw >/dev/null 2>&1; then
  log "1/4 onboarding NemoClaw sandbox '$SANDBOX'"; nemoclaw onboard --non-interactive
else
  [ -n "${NEMOCLAW_PROVIDER_KEY:-}" ] || die "NEMOCLAW_PROVIDER_KEY unset (build.nvidia.com key) — see .env"
  log "1/4 installing + onboarding NemoClaw"; curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash -s -- --non-interactive
fi

# --- 2. create namespace + adopt the public datasets (the shared brain) ---
log "2/4 creating Toolbelt namespace + adopting datasets"
TB="npx -y @toolbeltai/cli@latest"
NS=$($TB namespace create "toolbelt-shared-brain" --json 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])') \
  || die "namespace create failed (set TOOLBELT_TOKEN in .env, or check @toolbeltai/cli)"
IFS=';' read -ra ASSETS <<< "${TOOLBELT_PUBLIC_ASSETS:-NWS Active Weather Alerts;US Census Blocks 2024;US Building Footprints}"
for a in "${ASSETS[@]}"; do
  log "  adopting public asset: $a"
  $TB public-assets adopt "$a" --namespace "$NS" || echo "  (adopt '$a' — verify catalog name)"
done

# --- 3. install the Toolbelt skill inside the sandbox ---
log "3/4 installing Toolbelt skill in sandbox '$SANDBOX'"
nemoclaw sandbox exec "$SANDBOX" --no-tty -- env \
  ${TOOLBELT_TOKEN:+TOOLBELT_TOKEN=$TOOLBELT_TOKEN} TOOLBELT_HOST="${TOOLBELT_HOST:-app.toolbelt.ai}" \
  npx -y @toolbeltai/cli@latest install --client openclaw --namespace "$NS"

# --- 4. fill openclaw.json placeholders + apply policy + recover ---
log "4/4 wiring config + egress policy"
RENDERED=/tmp/openclaw.toolbelt.json
sed -e "s|__TOOLBELT_NAMESPACE__|$NS|g" \
    -e "s|__TOOLBELT_TOKEN__|${TOOLBELT_TOKEN:-}|g" \
    -e "s|__MODEL_ID__|${NEMOCLAW_MODEL:-nemotron}|g" \
    -e "s|__MODEL_REF__|${NEMOCLAW_MODEL:-nemotron}|g" \
    "$REPO/openclaw.json" > "$RENDERED"
nemoclaw sandbox config set "$SANDBOX" --from-file "$RENDERED" 2>/dev/null || \
  echo "  (apply $RENDERED to the sandbox's openclaw.json — verify the exact CLI subcommand)"
nemoclaw sandbox policy add "$SANDBOX" --from-file "$REPO/policy.yaml" --yes
nemoclaw sandbox recover "$SANDBOX"

log "Done. namespace=$NS  Connect: nemoclaw $SANDBOX connect  (then: openclaw tui)"
log "Try:  ask main — \"Give me the current severe-weather situation brief.\""
