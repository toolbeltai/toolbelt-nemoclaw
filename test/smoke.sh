#!/usr/bin/env bash
set -euo pipefail
IMAGE_TAG="${IMAGE_TAG:-toolbelt-claw:dev}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "== building =="
IMAGE_TAG="$IMAGE_TAG" bash "$ROOT/build.sh"

echo "== assert toolbelt CLI present =="
docker run --rm --entrypoint sh "$IMAGE_TAG" -c 'command -v toolbelt' >/dev/null
echo "cli OK"

echo "== assert skills installed under /sandbox/.openclaw/skills =="
docker run --rm --entrypoint sh "$IMAGE_TAG" -c '[ -n "$(ls -A /sandbox/.openclaw/skills 2>/dev/null)" ]'
echo "skills OK"

echo "== assert MCP entry baked (nested mcp.servers, placeholder token) =="
docker run --rm --entrypoint node "$IMAGE_TAG" -e '
const fs=require("fs");
const o=JSON.parse(fs.readFileSync("/sandbox/.openclaw/openclaw.json","utf8"));
const e=o.mcp&&o.mcp.servers&&o.mcp.servers.toolbelt;
if(!e) throw new Error("no mcp.servers.toolbelt entry");
if(e.type!=="http") throw new Error("type not http");
if(!/^https?:\/\//.test(e.url||"")) throw new Error("url not substituted: "+e.url);
if(e.headers.Authorization!=="Bearer openshell:resolve:env:TOOLBELT_TOKEN") throw new Error("auth not placeholder: "+e.headers.Authorization);
'
echo "mcp entry OK"

echo "== token-provided path: shim binds without onboarding =="
docker run --rm \
  -e TOOLBELT_TOKEN="tok-provided" \
  -e TOOLBELT_INSTALL_CMD="false" \
  -e NEMOCLAW_START_BIN="/bin/sh" \
  "$IMAGE_TAG" -c 'echo BOUND token=$TOOLBELT_TOKEN' | grep -q "BOUND token=tok-provided"
echo "token-provided path OK"

echo "== onboarding path: delegate invoked, token persisted, reused on restart =="
VOL="$(docker volume create)"
run_onb() {
  docker run --rm -v "$VOL:/sandbox/.nemoclaw/state/toolbelt" \
    -e TOOLBELT_TOKEN="" \
    -e TOOLBELT_CLI_CONFIG="/tmp/cli.json" \
    -e TOOLBELT_INSTALL_CMD="printf '{\"token\":\"tok-onb\"}' > /tmp/cli.json" \
    -e NEMOCLAW_START_BIN="/bin/sh" \
    "$IMAGE_TAG" -c 'echo BOUND token=$TOOLBELT_TOKEN'
}
run_onb | grep -q "BOUND token=tok-onb"
# second run must reuse the persisted token even if onboarding would now fail
docker run --rm -v "$VOL:/sandbox/.nemoclaw/state/toolbelt" \
  -e TOOLBELT_TOKEN="" \
  -e TOOLBELT_INSTALL_CMD="false" \
  -e NEMOCLAW_START_BIN="/bin/sh" \
  "$IMAGE_TAG" -c 'echo BOUND token=$TOOLBELT_TOKEN' | grep -q "BOUND token=tok-onb"
docker volume rm "$VOL" >/dev/null
echo "onboarding path OK"

# Integrity + health requires the real NemoClaw gateway (OpenShell/GPU substrate).
# Run only where that substrate exists: SMOKE_RUNTIME=1 bash test/smoke.sh
if [ "${SMOKE_RUNTIME:-0}" = "1" ]; then
  echo "== integrity + health (real gateway) =="
  CID="$(docker run -d \
    -e TOOLBELT_TOKEN="tok-provided" \
    -e NEMOCLAW_INFERENCE_BASE_URL="http://127.0.0.1:9/v1" \
    -e NEMOCLAW_MODEL="dummy" \
    "$IMAGE_TAG")"
  ok=0
  for i in $(seq 1 30); do
    if docker exec "$CID" sh -c 'curl -fsS http://127.0.0.1:18789/health' >/dev/null 2>&1; then
      echo "health OK (integrity check passed at startup)"; ok=1; break
    fi
    sleep 2
  done
  docker logs "$CID" | tail -20
  docker rm -f "$CID" >/dev/null
  [ "$ok" = "1" ] || { echo "FAIL: gateway never became healthy"; exit 1; }
fi

echo "ALL SMOKE CHECKS PASSED"
