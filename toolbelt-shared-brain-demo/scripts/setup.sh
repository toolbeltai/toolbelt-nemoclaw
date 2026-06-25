#!/usr/bin/env bash
# setup.sh — stand up the Toolbelt shared-brain demo on NemoClaw (>= 0.0.67).
#
# Rewritten against VERIFIED mechanics (the original assumed CLI commands/flags that
# don't exist). What changed and why:
#   - Namespace create + dataset adoption: the original used `@toolbeltai/cli namespace
#     create` / `public-assets adopt` — those CLI commands DO NOT EXIST. We use the REST
#     API instead (POST /api/namespace, POST /api/namespace/:id/public-assets), which is
#     verified working and adopts by reference (no data movement).
#   - Agent topology: the original used `nemoclaw sandbox config set --from-file` to apply
#     the whole openclaw.json — config set is KEY/VALUE only. We bake the topology with
#     `nemoclaw onboard --agents agents.yaml` (NemoClaw >= 0.0.67), the supported path.
#   - TOOLBELT_HOST: normalized to include a scheme (a bare host throws "Failed to parse URL").
#   - MCP namespace pinning: set via `config set --key mcp.servers.toolbelt.url` (key/value).
#   - Personas: copied in with `nemoclaw sandbox upload` (the original had no mechanism).
#
# Requires NemoClaw >= 0.0.67 (for `onboard --agents` / `sandbox upload`). Check: nemoclaw --version
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$REPO/.env" ] && { set -a; . "$REPO/.env"; set +a; }

: "${NEMOCLAW_SANDBOX_NAME:=toolbelt-shared-brain}"
: "${NEMOCLAW_NON_INTERACTIVE:=1}"
: "${NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE:=1}"
: "${NEMOCLAW_MODEL:=nvidia/nemotron-3-super-120b-a12b}"
export NEMOCLAW_NON_INTERACTIVE NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE
SANDBOX="$NEMOCLAW_SANDBOX_NAME"

# Normalize host: the Toolbelt CLI does `new URL(host + path)`; a scheme-less host throws.
HOST="${TOOLBELT_HOST:-https://app.toolbelt.ai}"
case "$HOST" in http://*|https://*) ;; *) HOST="https://$HOST" ;; esac

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
command -v curl >/dev/null    || die "curl required"
command -v python3 >/dev/null || die "python3 required"
command -v nemoclaw >/dev/null || die "nemoclaw not installed (run the NemoClaw quickstart first)"

jget() { python3 -c 'import sys,json
try: d=json.loads(sys.stdin.read(),strict=False)
except Exception: sys.exit(0)
v=d
for k in sys.argv[1].split("."):
    if isinstance(v,list): v=v[0] if v else None
    v=(v or {}).get(k) if isinstance(v,dict) else None
print(v if v is not None else "")' "$1"; }

# Curated public-asset ids (stable). Override via env if the catalog changes.
: "${ASSET_NWS:=3e130e46-d9d3-4125-8e91-a91a89d3de42}"      # NWS Active Weather Alerts
: "${ASSET_CENSUS:=48712868-6148-4b35-a040-753429865205}"  # US Census Blocks 2024
: "${ASSET_BUILDINGS:=11110bc2-4082-4117-aefc-bde076bab370}" # US Building Footprints

# --- 1. Toolbelt token + its default namespace (the brain's identity) ---
log "1/6 resolving Toolbelt token + default namespace"
NS=""
if [ -z "${TOOLBELT_TOKEN:-}" ]; then
  ob="$(curl -fsS -X POST "$HOST/api/onboard" -H 'content-type: application/json' -d '{}')"
  TOOLBELT_TOKEN="$(printf '%s' "$ob" | jget token)"
  NS="$(printf '%s' "$ob" | jget namespace.id)"   # onboard returns the token's default namespace
  [ -n "$TOOLBELT_TOKEN" ] || die "anonymous onboard failed"
  log "  provisioned anonymous token (default namespace from onboard)"
fi
AUTH=(-H "authorization: Bearer $TOOLBELT_TOKEN" -H 'accept: application/json' -H 'content-type: application/json')

# --- 2. resolve the token's DEFAULT namespace, then adopt datasets into IT ---
# The Toolbelt MCP resolves the namespace from the TOKEN (its default); a /ns/<id>/ URL
# path is NOT honored, so the agents always read/write the token's default namespace.
# We therefore seed THAT namespace (no new namespace, no URL pin) so the shared brain the
# agents use is exactly the one we populate. Default = the auto-created "Default Workspace",
# falling back to the oldest namespace.
log "2/6 resolving default namespace + adopting datasets (the shared brain)"
if [ -z "$NS" ]; then
  for try in 1 2 3; do
    list="$(curl -fsS "$HOST/api/namespace" "${AUTH[@]}" 2>/dev/null || true)"
    NS="$(printf '%s' "$list" | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
a=d if isinstance(d,list) else (d.get("namespaces") or d.get("data") or [])
if not a: sys.exit(0)
dw=[n for n in a if (n.get("name") or "")=="Default Workspace"]
pick=dw[0] if dw else sorted(a,key=lambda n:n.get("createdAt") or "")[0]
print(pick.get("id") or "")' || true)"
    [ -n "$NS" ] && break
    sleep 3
  done
fi
[ -n "$NS" ] || die "could not resolve the default namespace (network? check $HOST)"
log "  default namespace = $NS"

for pair in "NWS Active Weather Alerts=$ASSET_NWS" "US Census Blocks 2024=$ASSET_CENSUS" "US Building Footprints=$ASSET_BUILDINGS"; do
  name="${pair%%=*}"; aid="${pair##*=}"
  out="$(curl -sS -X POST "$HOST/api/namespace/$NS/public-assets" "${AUTH[@]}" -d "{\"publicAssetId\":\"$aid\"}" 2>/dev/null || true)"
  ok="$(printf '%s' "$out" | jget asset.name)"
  [ -n "$ok" ] && log "  adopted: $ok" || echo "  adopt '$name': $(printf '%s' "$out" | head -c 160)"
done

# --- 3. onboard NemoClaw with the agent topology baked in ---
# IMPORTANT (NemoClaw issue #976): patch the build provider to force chat-completions
# BEFORE onboard, so Nemotron tool calls come back structured (not raw text the agent
# then tries to exec). The API flavor is baked at onboard time.
log "3/6 patching build provider for tool-calling, then onboarding (Nemotron from .env)"
[ -n "${NEMOCLAW_PROVIDER_KEY:-}" ] || die "NEMOCLAW_PROVIDER_KEY unset (build.nvidia.com key) — see .env"
"$REPO/scripts/patch-build-tool-calls.sh" || die "build-provider patch failed"
# issue #5237: onboard doesn't forward NEMOCLAW_GATEWAY_WS_HOST into the sandbox, so the
# gateway dial-back host can't be overridden when `hostname -I` can't derive eth0 (it then
# falls back to loopback, which the L7 proxy blocks -> every sessions_spawn child gets 1006).
# This patch adds the forward; we set NEMOCLAW_GATEWAY_WS_HOST=10.200.0.2 (the sandbox bridge).
"$REPO/scripts/patch-forward-gateway-ws-host.sh" || die "gateway-ws-host forward patch failed"
RENDERED_AGENTS="${TMPDIR:-/tmp}/agents.toolbelt.$$.yaml"
sed "s|__MODEL_REF__|$NEMOCLAW_MODEL|g" "$REPO/agents.yaml" > "$RENDERED_AGENTS"
# v0.0.67 CLI: onboard bakes the named sandbox; provider/model/key come from NEMOCLAW_* env.
nemoclaw onboard --non-interactive --yes --yes-i-accept-third-party-software --no-gpu \
  --name "$SANDBOX" --agents "$RENDERED_AGENTS"

# --- 4. egress policy FIRST (the in-sandbox install must reach app.toolbelt.ai to
#        validate/provision the token; the sandbox is deny-by-default until this) ---
log "4/6 applying egress policy"
nemoclaw "$SANDBOX" policy-add --from-file "$REPO/policy.yaml" --yes

# --- 5. install the Toolbelt skill + MCP server inside the sandbox ---
log "5/6 installing Toolbelt skill in sandbox '$SANDBOX'"
nemoclaw "$SANDBOX" exec --no-tty -- env \
  TOOLBELT_TOKEN="$TOOLBELT_TOKEN" TOOLBELT_HOST="$HOST" \
  npx -y @toolbeltai/cli@latest install --client openclaw

# Disable the tool-search surface. We do NOT pin the MCP url to a /ns/<id>/ path: the
# Toolbelt MCP ignores that path and resolves the namespace from the token's default
# (which step 2 seeded), so the installer's bare /mcp url already points the agents at the
# shared brain. v0.0.67 has no host-side `config set`, and in-sandbox `openclaw config set`
# is guarded ("cannot modify config inside the sandbox"); but openclaw.json IS writable via
# exec and the edit survives `recover` (not a rebuild, which is fine for a demo).
#   - tools.toolSearch=false -> expose toolbelt__*/sessions_spawn directly; the compact
#     tool-search surface routes every tool through one call Nemotron can't drive.
log "  disabling tool-search surface"
nemoclaw "$SANDBOX" exec --no-tty -- python3 -c 'import json,pathlib; p=pathlib.Path("/sandbox/.openclaw/openclaw.json"); c=json.loads(p.read_text()); c.setdefault("tools",{})["toolSearch"]=False; p.write_text(json.dumps(c,indent=2)); print("  tools.toolSearch=false")'

# --- 6. upload personas + recover so OpenClaw reloads config + skill ---
log "6/6 uploading personas + recovering gateway"
# `nemoclaw upload <src> <dest>` does `mkdir -p <dest>` and drops <src> into it by basename
# (dest is always a DIRECTORY). So to write `<dir>/AGENTS.md`, stage the persona as a file
# literally named AGENTS.md and upload it to the parent workspace DIRECTORY. tar extract
# overwrites an existing file (this is how main's stock AGENTS.md gets replaced). No exec needed.
# main (the reserved primary) reads /sandbox/.openclaw/workspace; specialists read workspace-<id>.
STAGE="${TMPDIR:-/tmp}/persona.$$"; mkdir -p "$STAGE"
for id in main watch exposure comms; do
  [ -f "$REPO/workspaces/$id.md" ] || continue
  if [ "$id" = "main" ]; then dir="/sandbox/.openclaw/workspace"; else dir="/sandbox/.openclaw/workspace-$id"; fi
  if [ "$id" = "main" ]; then
    # main's workspace ships a stock AGENTS.md and `upload` (tar extract) refuses to
    # overwrite an existing file. A redirect write truncates/overwrites cleanly, so write
    # the persona via exec, passing the content base64-encoded (single token, no newline
    # issues). The agent data dir is writable via exec and the edit survives `recover`.
    b64="$(base64 < "$REPO/workspaces/$id.md" | tr -d '\n')"
    nemoclaw "$SANDBOX" exec --no-tty -- sh -c "printf %s '$b64' | base64 -d > '$dir/AGENTS.md'" \
      && log "  persona -> $dir/AGENTS.md ($id, via exec write)" \
      || echo "  (write $id persona to $dir failed)"
  else
    # Specialists' workspace-<id> has no pre-existing AGENTS.md, so a direct upload is fine.
    # `upload <src> <dir>` drops <src> into <dir> by basename, so stage the file as AGENTS.md.
    cp "$REPO/workspaces/$id.md" "$STAGE/AGENTS.md"
    nemoclaw "$SANDBOX" upload "$STAGE/AGENTS.md" "$dir" \
      && log "  persona -> $dir/AGENTS.md ($id)" \
      || echo "  (upload $id persona to $dir failed — verify workspace path for your OpenClaw version)"
  fi
done
rm -rf "$STAGE"
nemoclaw "$SANDBOX" recover

log "Done. namespace=$NS"
log "Connect: nemoclaw $SANDBOX connect   (then: openclaw tui)"
log "Ask main: \"Give me the current severe-weather situation brief.\""
