#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
assert_eq() { if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $3"; echo "  expected: [$2]"; echo "  actual:   [$1]"; fi; }
assert_rc() { if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $3 (rc exp $2 got $1)"; fi; }

TOOLBELT_SHIM_LIB=1 source "$SCRIPT_DIR/bin/onboard-and-start.sh"

# 1: explicit token wins, no onboarding invoked
work="$(mktemp -d)"
TOOLBELT_TOKEN="tok-explicit" TOOLBELT_STATE_DIR="$work" TOOLBELT_INSTALL_CMD="false" \
  out="$(resolve_token)"; rc=$?
assert_rc "$rc" "0" "explicit rc0"; assert_eq "$out" "tok-explicit" "explicit token verbatim"

# 2: persisted token reused
work="$(mktemp -d)"; printf 'tok-saved' > "$work/token"
TOOLBELT_TOKEN="" TOOLBELT_STATE_DIR="$work" TOOLBELT_INSTALL_CMD="false" \
  out="$(resolve_token)"; rc=$?
assert_rc "$rc" "0" "persisted rc0"; assert_eq "$out" "tok-saved" "persisted token"

# 3: onboarding — mock `toolbelt install` writes a CLI config json; token read+persisted
work="$(mktemp -d)"; cfg="$work/cli-config.json"
TOOLBELT_TOKEN="" TOOLBELT_STATE_DIR="$work" TOOLBELT_CLI_CONFIG="$cfg" \
  TOOLBELT_INSTALL_CMD="printf '{\"token\":\"tok-onboarded\",\"mcpUrl\":\"https://m/mcp\"}' > '$cfg'" \
  out="$(resolve_token)"; rc=$?
assert_rc "$rc" "0" "onboard rc0"; assert_eq "$out" "tok-onboarded" "onboarded token"
assert_eq "$(cat "$work/token")" "tok-onboarded" "onboarded token persisted"

# 4: onboarding failure propagates
work="$(mktemp -d)"
TOOLBELT_TOKEN="" TOOLBELT_STATE_DIR="$work" TOOLBELT_CLI_CONFIG="$work/none.json" \
  TOOLBELT_INSTALL_CMD="false" out="$(resolve_token)"; rc=$?
assert_rc "$rc" "1" "onboard failure propagates"

# 5: url override writes mcp.servers.toolbelt.url, preserves placeholder token
work="$(mktemp -d)"; oc="$work/openclaw.json"
printf '%s' '{"mcp":{"servers":{"toolbelt":{"type":"http","url":"https://mcp.toolbelt.ai/mcp","headers":{"Authorization":"Bearer openshell:resolve:env:TOOLBELT_TOKEN"}}}}}' > "$oc"
TOOLBELT_MCP_URL="https://self.example/mcp" OPENCLAW_CONFIG_PATH="$oc" write_mcp_url; rc=$?
assert_rc "$rc" "0" "url write rc0"
assert_eq "$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).mcp.servers.toolbelt.url)' "$oc")" "https://self.example/mcp" "url overridden"
assert_eq "$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).mcp.servers.toolbelt.headers.Authorization)' "$oc")" "Bearer openshell:resolve:env:TOOLBELT_TOKEN" "token placeholder preserved (off-disk)"

# 6: url override no-op when TOOLBELT_MCP_URL unset
work="$(mktemp -d)"; oc="$work/openclaw.json"
printf '%s' '{"mcp":{"servers":{"toolbelt":{"url":"https://mcp.toolbelt.ai/mcp"}}}}' > "$oc"
before="$(cat "$oc")"
( unset TOOLBELT_MCP_URL; OPENCLAW_CONFIG_PATH="$oc" write_mcp_url ); rc=$?
assert_rc "$rc" "0" "url noop rc0"; assert_eq "$(cat "$oc")" "$before" "file unchanged when no override"

echo "---"; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
