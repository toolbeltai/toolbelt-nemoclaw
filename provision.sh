#!/usr/bin/env bash
# provision.sh — stand up a Toolbelt-aware NemoClaw (OpenClaw) sandbox in one command.
#
# Chains the four steps from docs/local-dev-deploy.md:
#   1. install + onboard NemoClaw non-interactively (provider from NEMOCLAW_* env)
#   2. apply our egress preset (policy/toolbelt-egress.yaml) to the sandbox
#   3. install Toolbelt inside the sandbox (MCP entry + skill)
#   4. recover the gateway so OpenClaw reloads the new config + skill
#
# Config comes from .env (see .env.example). This same flow is what a k8s entrypoint runs.
#
# Usage:
#   ./provision.sh                 # full run, sourcing ./.env
#   SKIP_ONBOARD=1 ./provision.sh  # sandbox already onboarded; do steps 2-4 only
#
# All commands are verified against tracked upstream NemoClaw:
#   nemoclaw sandbox policy add <name> --from-file <f> --yes
#   nemoclaw sandbox exec <name> --no-tty -- <cmd...>
#   nemoclaw sandbox recover <name>
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EGRESS_PRESET="$REPO/policy/toolbelt-egress.yaml"

# --- Load config -----------------------------------------------------------
# Load .env WITHOUT clobbering vars already set in the environment, so an inline
# override wins, e.g.  NEMOCLAW_SANDBOX_NAME=scheduler ./provision.sh
# (lets you stand up multiple sandboxes from one .env). Precedence: inline env > .env.
if [ -f "$REPO/.env" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line#export }                        # tolerate a leading `export `
    case "$line" in ''|\#*) continue ;; esac    # skip blanks and comments
    key=${line%%=*}; key=${key// /}             # key = text before first =, no spaces
    case "$line" in *=*) ;; *) continue ;; esac # skip lines without =
    case "$key" in ''|*[!A-Za-z0-9_]*) continue ;; esac  # valid identifier only
    [ -n "${!key+x}" ] && continue              # already set in env -> inline wins
    val=${line#*=}
    case "$val" in                              # strip one layer of surrounding quotes
      \"*\") val=${val#\"}; val=${val%\"} ;;
      \'*\') val=${val#\'}; val=${val%\'} ;;
    esac
    export "$key=$val"
  done < "$REPO/.env"
fi

# Sensible non-interactive defaults; .env / inline env win.
: "${NEMOCLAW_NON_INTERACTIVE:=1}"
: "${NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE:=1}"
: "${NEMOCLAW_SANDBOX_NAME:=toolbelt}"
: "${TOOLBELT_CLI_REF:=latest}"
export NEMOCLAW_NON_INTERACTIVE NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE NEMOCLAW_SANDBOX_NAME

# The Toolbelt CLI builds request URLs with `new URL(host + path)`, which throws on a
# scheme-less host. Normalize so TOOLBELT_HOST=app.toolbelt.ai still works.
if [ -n "${TOOLBELT_HOST:-}" ]; then
  case "$TOOLBELT_HOST" in
    http://*|https://*) ;;
    *) TOOLBELT_HOST="https://$TOOLBELT_HOST" ;;
  esac
  export TOOLBELT_HOST
fi

SANDBOX="$NEMOCLAW_SANDBOX_NAME"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ -f "$EGRESS_PRESET" ] || die "egress preset not found: $EGRESS_PRESET"

# --- Step 1: install + onboard --------------------------------------------
if [ "${SKIP_ONBOARD:-0}" = "1" ]; then
  log "Step 1/4: skipping onboard (SKIP_ONBOARD=1)"
  command -v nemoclaw >/dev/null 2>&1 || die "nemoclaw not installed but SKIP_ONBOARD=1"
elif command -v nemoclaw >/dev/null 2>&1; then
  log "Step 1/4: nemoclaw present; onboarding sandbox '$SANDBOX'"
  nemoclaw onboard --non-interactive
else
  log "Step 1/4: installing + onboarding NemoClaw (provider: ${NEMOCLAW_PROVIDER:-unset})"
  [ -n "${NEMOCLAW_PROVIDER:-}" ] || die "NEMOCLAW_PROVIDER unset; set it in .env (see .env.example)"
  curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash -s -- --non-interactive
fi

# --- Step 2: egress preset -------------------------------------------------
log "Step 2/4: applying Toolbelt egress preset to '$SANDBOX'"
nemoclaw sandbox policy add "$SANDBOX" --from-file "$EGRESS_PRESET" --yes

# --- Step 3: install Toolbelt inside the sandbox ---------------------------
log "Step 3/4: installing Toolbelt in sandbox '$SANDBOX'"
install_cmd=(npx -y "@toolbeltai/cli@${TOOLBELT_CLI_REF}" install --client openclaw)
# Forward token/host into the sandbox if provided (anonymous onboarding if unset).
# Note: passing the token as an arg is fine for local dev; a k8s entrypoint should
# inject it via the sandbox environment instead of argv.
env_prefix=(env)
[ -n "${TOOLBELT_TOKEN:-}" ] && env_prefix+=("TOOLBELT_TOKEN=$TOOLBELT_TOKEN")
[ -n "${TOOLBELT_HOST:-}" ]  && env_prefix+=("TOOLBELT_HOST=$TOOLBELT_HOST")
if [ "${#env_prefix[@]}" -gt 1 ]; then
  nemoclaw sandbox exec "$SANDBOX" --no-tty -- "${env_prefix[@]}" "${install_cmd[@]}"
else
  nemoclaw sandbox exec "$SANDBOX" --no-tty -- "${install_cmd[@]}"
fi

# --- Step 4: recover so OpenClaw reloads config + skill --------------------
log "Step 4/4: recovering gateway so OpenClaw picks up the MCP server + skill"
nemoclaw sandbox recover "$SANDBOX"

log "Done. Connect with: nemoclaw $SANDBOX connect  (then: openclaw tui)"
