#!/usr/bin/env bash
# demo-shared-brain.sh — the "two users, one shared brain" NemoClaw demo.
#
# Stands up TWO separate, sandboxed OpenClaw agents that collaborate through ONE shared
# Toolbelt namespace, with no agent-to-agent connection (the demo's whole point):
#
#   1. Provision two distinct anonymous Toolbelt users (POST /api/onboard x2).
#   2. The OWNER user shares its namespace (read-write) with the PEER user
#      (POST /api/namespace/user-share  ->  .../accept). This shared namespace IS
#      the shared brain: timeline + entity/KG both agents read and write.
#   3. Stand up one NemoClaw sandbox per role via provision.sh, each bound to its own
#      user token. Both can now read/write the shared namespace; neither talks to the other.
#
# Config comes from .env.demo (provider = Nemotron/NVIDIA; role names). See that file.
#
# Usage:
#   ./demo-shared-brain.sh                 # full run (provision users + share + 2 sandboxes)
#   PROVISION_SANDBOXES=0 ./demo-shared-brain.sh   # only provision+share the users; print the
#                                                  # two provision.sh commands to run yourself
#
# VERIFIED against tracked source: the onboard + user-share + accept HTTP contract
# (atlas onboarding/index.ts, namespace/index.ts) and that supplying TOOLBELT_TOKEN makes
# `toolbelt install` bind to an existing user. NOT yet exercised live: running two NemoClaw
# sandboxes by name from one host (onboard creates-or-reuses by NEMOCLAW_SANDBOX_NAME; there
# is no separate `sandbox create`). If your host supports only one sandbox, run each role on
# its own host/VM with PROVISION_SANDBOXES=0 here.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_ENV_FILE="${DEMO_ENV_FILE:-$REPO/.env.demo}"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# Load demo config into our env so provision.sh (and its loader) inherit it.
if [ -f "$DEMO_ENV_FILE" ]; then set -a; . "$DEMO_ENV_FILE"; set +a; fi

HOST="${TOOLBELT_HOST:-https://app.toolbelt.ai}"
OWNER_ROLE="${OWNER_ROLE:-scheduler}"
PEER_ROLE="${PEER_ROLE:-csr}"
PROVISION_SANDBOXES="${PROVISION_SANDBOXES:-1}"

command -v curl >/dev/null 2>&1 || die "curl is required"
command -v node >/dev/null 2>&1 || die "node is required (it is a NemoClaw host prereq)"
[ "$OWNER_ROLE" != "$PEER_ROLE" ] || die "OWNER_ROLE and PEER_ROLE must differ"

# Extract a dotted field from a JSON string: jget '<json>' a.b.c
jget() { node -e 'const o=JSON.parse(process.argv[1]);const v=process.argv[2].split(".").reduce((a,k)=>(a==null?a:a[k]),o);process.stdout.write(v==null?"":String(v))' "$1" "$2"; }

# Provision one anonymous user; prints "<token>\t<namespaceId>". Exits on failure
# (runs in a command-substitution, so set -e in the caller propagates the failure).
onboard_user() {
  local label="$1" resp tok ns
  resp="$(curl -fsS -X POST "$HOST/api/onboard" -H 'content-type: application/json' -d '{}')" \
    || die "onboard ($label) request failed"
  tok="$(jget "$resp" token)"; ns="$(jget "$resp" namespace.id)"
  [ -n "$tok" ] && [ -n "$ns" ] || die "onboard ($label) returned no token/namespace: $resp"
  printf '%s\t%s' "$tok" "$ns"
}

log "Provisioning two anonymous Toolbelt users (rate limit: 5/hour per IP)"
OWNER_OUT="$(onboard_user "$OWNER_ROLE")"; IFS=$'\t' read -r OWNER_TOKEN OWNER_NS <<<"$OWNER_OUT"
PEER_OUT="$(onboard_user "$PEER_ROLE")";   IFS=$'\t' read -r PEER_TOKEN  PEER_NS  <<<"$PEER_OUT"
log "  $OWNER_ROLE -> namespace $OWNER_NS  (this becomes the shared brain)"
log "  $PEER_ROLE  -> namespace $PEER_NS  (its own; also gets access to the shared one)"

log "Sharing $OWNER_ROLE's namespace with $PEER_ROLE (read-write)"
SHARE_RESP="$(curl -fsS -X POST "$HOST/api/namespace/user-share" \
  -H "authorization: Bearer $OWNER_TOKEN" -H 'content-type: application/json' \
  -d "{\"namespaceIds\":[\"$OWNER_NS\"],\"readWrite\":true,\"expiresInDays\":7}")" \
  || die "share-create failed"
SHARE_ID="$(jget "$SHARE_RESP" shareId)"
[ -n "$SHARE_ID" ] || die "share-create returned no shareId: $SHARE_RESP"

log "Accepting the share as $PEER_ROLE"
curl -fsS -X POST "$HOST/api/namespace/user-share/$SHARE_ID/accept" \
  -H "authorization: Bearer $PEER_TOKEN" >/dev/null || die "share-accept failed"

# Print credentials now, so they survive even if sandbox provisioning fails below.
cat <<EOF

  ──────────────────────────────────────────────────────────────
  Shared brain ready. Two users, one namespace.
    shared namespace : $OWNER_NS  (owned by $OWNER_ROLE, shared RW with $PEER_ROLE)
    $OWNER_ROLE token : $OWNER_TOKEN
    $PEER_ROLE token  : $PEER_TOKEN
    share id          : $SHARE_ID
  (Tokens are anonymous, ~72h. Treat as secrets; printed for the demo only.)
  ──────────────────────────────────────────────────────────────
EOF

if [ "$PROVISION_SANDBOXES" = "1" ]; then
  log "Standing up sandbox '$OWNER_ROLE'"
  NEMOCLAW_SANDBOX_NAME="$OWNER_ROLE" TOOLBELT_TOKEN="$OWNER_TOKEN" bash "$REPO/provision.sh"
  log "Standing up sandbox '$PEER_ROLE'"
  NEMOCLAW_SANDBOX_NAME="$PEER_ROLE" TOOLBELT_TOKEN="$PEER_TOKEN" bash "$REPO/provision.sh"
  log "Done. Both agents share namespace $OWNER_NS. Have each agent target it:"
  echo "  nemoclaw $OWNER_ROLE connect   # then in the agent: write to the shared namespace"
  echo "  nemoclaw $PEER_ROLE connect    # reads the same timeline/entities, no wiring"
else
  log "PROVISION_SANDBOXES=0 -> users+share done; run these to stand up the sandboxes:"
  echo "  NEMOCLAW_SANDBOX_NAME=$OWNER_ROLE TOOLBELT_TOKEN=$OWNER_TOKEN ./provision.sh"
  echo "  NEMOCLAW_SANDBOX_NAME=$PEER_ROLE  TOOLBELT_TOKEN=$PEER_TOKEN  ./provision.sh"
fi
