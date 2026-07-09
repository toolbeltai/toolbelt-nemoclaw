#!/usr/bin/env bash
# setup.sh — stand up the Toolbelt shared-brain demo on a recent NemoClaw.
#
# Rewritten against VERIFIED mechanics (the original assumed CLI commands/flags that
# don't exist). What changed and why:
#   - Namespace create + dataset adoption: the original used `@toolbeltai/cli namespace
#     create` / `public-assets adopt` — those CLI commands DO NOT EXIST. We use the REST
#     API instead (POST /api/namespace, POST /api/namespace/:id/public-assets), which is
#     verified working and adopts by reference (no data movement).
#   - Agent topology: the original used `nemoclaw sandbox config set --from-file` to apply
#     the whole openclaw.json — config set is KEY/VALUE only. We bake the topology with
#     `nemoclaw onboard --agents agents.yaml` (recent NemoClaw), the supported path.
#   - TOOLBELT_HOST: normalized to include a scheme (a bare host throws "Failed to parse URL").
#   - MCP namespace pinning: set via `config set --key mcp.servers.toolbelt.url` (key/value).
#   - Personas: copied in with `nemoclaw sandbox upload` (the original had no mechanism).
#
# Requires a recent NemoClaw with `onboard --agents` and `sandbox upload`. Check: nemoclaw --version
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$REPO/.env" ] && { set -a; . "$REPO/.env"; set +a; }

: "${NEMOCLAW_SANDBOX_NAME:=toolbelt-shared-brain}"
: "${NEMOCLAW_NON_INTERACTIVE:=1}"
: "${NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE:=1}"
: "${NEMOCLAW_PROVIDER:=build}"
: "${NEMOCLAW_MODEL:=meta/llama-3.3-70b-instruct}"   # non-reasoning; Nemotron reasoning models fail the comms synthesis turn (see STATUS.md)
export NEMOCLAW_NON_INTERACTIVE NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE NEMOCLAW_PROVIDER NEMOCLAW_MODEL
SANDBOX="$NEMOCLAW_SANDBOX_NAME"

# Normalize host: the Toolbelt CLI does `new URL(host + path)`; a scheme-less host throws.
HOST="${TOOLBELT_HOST:-https://app.toolbelt.ai}"
case "$HOST" in http://*|https://*) ;; *) HOST="https://$HOST" ;; esac

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
command -v curl >/dev/null    || die "curl required"
command -v python3 >/dev/null || die "python3 required"
command -v nemoclaw >/dev/null || die "nemoclaw not installed (run the NemoClaw quickstart first)"
# Feature guard: this flow bakes the agent topology with `onboard --agents`. Older CLIs (e.g. 0.0.5x)
# lack that flag and would fail partway through onboard, so fail fast with a clear, actionable message
# rather than checking a version number (feature-detect is robust across the 0.0.x -> 0.1.x bump).
nemoclaw onboard --help 2>&1 | grep -q -- '--agents' \
  || die "this NemoClaw ($(nemoclaw --version 2>/dev/null | head -1)) lacks 'onboard --agents' — update with 'nemoclaw update' (needs a recent NemoClaw)"

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

# --- 1. Toolbelt token (the brain's identity) ---
log "1/6 resolving Toolbelt token"
ONBOARD_NS=""
if [ -z "${TOOLBELT_TOKEN:-}" ]; then
  ob="$(curl -fsS -X POST "$HOST/api/onboard" -H 'content-type: application/json' -d '{}')"
  TOOLBELT_TOKEN="$(printf '%s' "$ob" | jget token)"
  ONBOARD_NS="$(printf '%s' "$ob" | jget namespace.id)"   # onboard also creates a default namespace
  [ -n "$TOOLBELT_TOKEN" ] || die "anonymous onboard failed"
  log "  provisioned anonymous token"
fi
AUTH=(-H "authorization: Bearer $TOOLBELT_TOKEN" -H 'accept: application/json' -H 'content-type: application/json')

# --- 2. select the namespace (the shared brain), then adopt datasets into it ---
# The agents pass an explicit namespace_id on every tool call (setup pins it into the personas),
# so whichever namespace resolves HERE is exactly the shared brain they read and write.
# TOOLBELT_NAMESPACE (optional) picks which one:
#   - a namespace id (UUID) -> used directly
#   - a namespace name      -> resolved to its id, created if it doesn't exist yet
#   - unset                 -> the token's default (the just-onboarded namespace for an anonymous
#                              token, else "Default Workspace", else the oldest namespace)
# The token must own (or have shared access to) the chosen namespace.
log "2/6 selecting namespace + adopting datasets (the shared brain)"

is_uuid() { printf '%s' "$1" | grep -qiE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; }

# Resolve a namespace NAME to its id from the caller's namespace list (empty if not found).
ns_id_by_name() {
  local list
  list="$(curl -fsS "$HOST/api/namespace" "${AUTH[@]}" 2>/dev/null || true)"
  printf '%s' "$list" | NS_WANT="$1" python3 -c 'import sys,json,os
want=os.environ["NS_WANT"]
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
a=d if isinstance(d,list) else (d.get("namespaces") or d.get("data") or [])
m=[n for n in a if (n.get("name") or "")==want]
print((m[0].get("id") or "") if m else "")'
}

NS=""
if [ -n "${TOOLBELT_NAMESPACE:-}" ]; then
  if is_uuid "$TOOLBELT_NAMESPACE"; then
    NS="$TOOLBELT_NAMESPACE"
    log "  using namespace id: $NS"
  else
    NS="$(ns_id_by_name "$TOOLBELT_NAMESPACE")"
    if [ -n "$NS" ]; then
      log "  matched existing namespace '$TOOLBELT_NAMESPACE' -> $NS"
    else
      log "  creating namespace '$TOOLBELT_NAMESPACE'"
      cr="$(curl -fsS -X POST "$HOST/api/namespace" "${AUTH[@]}" -d "{\"name\":\"$TOOLBELT_NAMESPACE\"}" 2>/dev/null || true)"
      NS="$(printf '%s' "$cr" | jget namespace.id)"; [ -n "$NS" ] || NS="$(printf '%s' "$cr" | jget id)"
      [ -n "$NS" ] || die "could not create namespace '$TOOLBELT_NAMESPACE': $(printf '%s' "$cr" | head -c 200)"
      log "  created namespace '$TOOLBELT_NAMESPACE' -> $NS"
    fi
  fi
elif [ -n "$ONBOARD_NS" ]; then
  NS="$ONBOARD_NS"
  log "  using the token's onboard namespace: $NS"
else
  # Pre-existing token, no override: pick the token's default ("Default Workspace", else oldest).
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
  log "  default namespace = $NS"
fi
[ -n "$NS" ] || die "could not resolve a namespace (network? check $HOST, or set TOOLBELT_NAMESPACE)"

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
[ -n "${NEMOCLAW_PROVIDER_KEY:-}" ] || die "NEMOCLAW_PROVIDER_KEY unset (key for provider '$NEMOCLAW_PROVIDER': nvapi-... for build, sk-ant-... for anthropic) — see .env"
# The #976 tool-call patch only matters for the NVIDIA `build` provider (it forces chat-completions
# so Nemotron tool calls parse). For anthropic/openai/etc. it's irrelevant and the onboard.js anchor
# may not exist, so only apply it when actually using the build provider.
if [ "${NEMOCLAW_PROVIDER:-}" = "build" ]; then
  "$REPO/scripts/patch-build-tool-calls.sh" || die "build-provider patch failed"
fi
RENDERED_AGENTS="${TMPDIR:-/tmp}/agents.toolbelt.$$.yaml"
sed "s|__MODEL_REF__|$NEMOCLAW_MODEL|g" "$REPO/agents.yaml" > "$RENDERED_AGENTS"
# onboard bakes the named sandbox; provider/model/key come from NEMOCLAW_* env.
nemoclaw onboard --non-interactive --yes --yes-i-accept-third-party-software --no-gpu \
  --name "$SANDBOX" --agents "$RENDERED_AGENTS"

# --- 4. egress policy FIRST (the in-sandbox install must reach app.toolbelt.ai to
#        validate/provision the token; the sandbox is deny-by-default until this) ---
log "4/6 applying egress policy"
nemoclaw "$SANDBOX" policy-add --from-file "$REPO/policy.yaml" --yes

# --- 5. install the Toolbelt skill + MCP server inside the sandbox ---
# The install runs `npx @toolbeltai/cli`, which needs the npm registry. Don't rely on onboard's
# balanced tier having added the `npm` preset: on a re-run against an already-hardened sandbox
# (npm removed by the step below), onboard reuses the sandbox and does NOT re-add it, so the
# install 403s. Explicitly ensure npm egress here; the hardening step then removes it again.
log "5/6 installing Toolbelt skill in sandbox '$SANDBOX'"
nemoclaw "$SANDBOX" policy-add npm --yes >/dev/null 2>&1 || true
nemoclaw "$SANDBOX" exec --no-tty -- env \
  TOOLBELT_TOKEN="$TOOLBELT_TOKEN" TOOLBELT_HOST="$HOST" \
  npx -y @toolbeltai/cli@latest install --client openclaw

# Two in-sandbox openclaw.json edits. The CLI has no host-side `config set`, and in-sandbox
# `openclaw config set` is guarded ("cannot modify config inside the sandbox"); but openclaw.json
# IS writable via exec and the edit survives `recover` (not a rebuild, which is fine for a demo).
#
# 1. tools.toolSearch=false -> expose toolbelt__*/sessions_spawn directly; the compact tool-search
#    surface routes every tool through one call some models can't drive reliably.
log "  disabling tool-search surface"
nemoclaw "$SANDBOX" exec --no-tty -- python3 -c 'import json,pathlib; p=pathlib.Path("/sandbox/.openclaw/openclaw.json"); c=json.loads(p.read_text()); c.setdefault("tools",{})["toolSearch"]=False; p.write_text(json.dumps(c,indent=2)); print("  tools.toolSearch=false")'

# 2. Pin the MCP server URL to /ns/$NS/mcp. `toolbelt install` writes a BARE /mcp url, and the
#    Toolbelt MCP resolves the target namespace with precedence: URL path /ns/<id>/mcp  >  per-call
#    namespace_id arg (no token-default fallback). With a bare url, every write depends on the model
#    passing the right namespace_id UUID on each call — fragile, and it silently drifts to whatever
#    id the model emits. Pinning the url path makes toolbelt_record/save/timeline route to $NS
#    deterministically (URL scope wins), independent of the model. (toolbelt_sql still reads from its
#    namespace_id arg, which the personas pin to $NS; its data is the same by-reference public assets
#    regardless.) We swap only the path, preserving the installer's scheme+host (dev/prod agnostic).
log "  pinning MCP server url to namespace $NS"
nemoclaw "$SANDBOX" exec --no-tty -- python3 -c "import json,pathlib,urllib.parse as U
p=pathlib.Path('/sandbox/.openclaw/openclaw.json'); c=json.loads(p.read_text())
srv=(c.get('mcp',{}).get('servers',{}) or {}).get('toolbelt')
if srv and srv.get('url'):
    u=U.urlsplit(srv['url']); srv['url']=U.urlunsplit((u.scheme,u.netloc,'/ns/$NS/mcp','',''))
    p.write_text(json.dumps(c,indent=2)); print('  mcp url ->',srv['url'])
else:
    print('  WARN: toolbelt MCP server entry not found; url not pinned')"

# Harden egress: `onboard` non-interactively applies its "balanced" policy tier, which WIDENS the
# sandbox egress with these presets (npm, pypi, huggingface, brew, weather, openclaw-pricing) —
# opening api.weather.gov, open-meteo, github, openrouter, npm/pypi/hf, etc. That breaks the demo's
# core claim: deny-by-default with ONLY the Toolbelt brain + inference hosts reachable. `policy-add`
# above only ADDS our preset (it can't replace), so we remove the tier's widening presets here. This
# MUST run AFTER the skill install above (that step needs the npm registry). policy-remove is a no-op
# for a preset that isn't applied, so the list is safe even if the tier's contents change.
log "  hardening egress: removing onboard's balanced-tier widening presets (deny-all-except-brain)"
for p in npm pypi huggingface brew weather openclaw-pricing; do
  nemoclaw "$SANDBOX" policy-remove "$p" --yes >/dev/null 2>&1 && log "    removed preset: $p" || true
done
# Show the resulting allowlist so any drift (a new widening preset) is visible in the setup output.
log "  effective egress allowlist (should be only the toolbelt-shared-brain hosts):"
nemoclaw "$SANDBOX" policy-explain 2>/dev/null | grep -iE "\[custom\]|^ *hosts:" | sed 's/^/    /' || true

# --- 6. write personas + recover so OpenClaw reloads config + skill ---
log "6/6 writing personas + recovering gateway"
# CRITICAL: each agent reads <workspace>/AGENTS.md, where <workspace> MUST be a DIRECTORY.
# Do NOT use `nemoclaw upload <persona> /sandbox/.openclaw/workspace-<id>`: upload wrote the
# persona content AS the `workspace-<id>` path (a FILE), not into it. That single bug caused
# every secondary-agent turn to die with `EEXIST: mkdir '/sandbox/.openclaw/workspace-<id>'` —
# OpenClaw's ensureAgentWorkspace does `mkdir(dir, {recursive:true})`, and a recursive mkdir
# STILL throws EEXIST when the path already exists as a non-directory (a file). So for every
# agent we explicitly ensure the workspace is a directory, then write AGENTS.md inside it via
# exec (base64 round-trip avoids newline/quoting issues). main reads /sandbox/.openclaw/workspace;
# specialists read /sandbox/.openclaw/workspace-<id>.
for id in main watch exposure comms; do
  [ -f "$REPO/workspaces/$id.md" ] || continue
  if [ "$id" = "main" ]; then dir="/sandbox/.openclaw/workspace"; else dir="/sandbox/.openclaw/workspace-$id"; fi
  # Pin the resolved namespace id into the persona: the token has multiple namespaces, so the
  # MCP can't auto-resolve a default and the toolbelt tools REQUIRE an explicit namespace_id.
  b64="$(sed "s|__NAMESPACE_ID__|$NS|g" "$REPO/workspaces/$id.md" | base64 | tr -d '\n')"
  # If a prior run left workspace-<id> as a FILE, remove it; then ensure the dir; then write inside.
  nemoclaw "$SANDBOX" exec --no-tty -- sh -c "d='$dir'; [ -f \"\$d\" ] && rm -f \"\$d\"; mkdir -p \"\$d\"; printf %s '$b64' | base64 -d > \"\$d/AGENTS.md\"" \
    && log "  persona -> $dir/AGENTS.md ($id)" \
    || echo "  (write $id persona to $dir failed)"
done
nemoclaw "$SANDBOX" recover

# Let the Toolbelt MCP plugin finish registering before the first agent turn. Without this,
# the FIRST secondary-agent turn races plugin load: its tools.allow is evaluated before
# toolbelt__* are registered ("allowlist contains unknown entries"), so that agent loses its
# toolbelt tools and falls back to a code tool (watch recorded 0 alerts). A short settle wait
# after recover makes the sandbox ready for an immediate run (and for cron-triggered runs).
log "  waiting for Toolbelt MCP to settle (avoids first-turn tool-load race)"
sleep 60

log "Done. namespace=$NS"
log "Connect: nemoclaw $SANDBOX connect   (then: openclaw tui)"
log "Ask main: \"Give me the current severe-weather situation brief.\""
