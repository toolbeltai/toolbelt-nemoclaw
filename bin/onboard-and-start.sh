#!/usr/bin/env bash
# Strict mode only when executed directly; stay inert/clean when sourced for tests.
if [ -z "${TOOLBELT_SHIM_LIB:-}" ]; then
  set -euo pipefail
fi

: "${TOOLBELT_STATE_DIR:=/sandbox/.nemoclaw/state/toolbelt}"
: "${OPENCLAW_CONFIG_PATH:=/sandbox/.openclaw/openclaw.json}"
: "${TOOLBELT_CLI_CONFIG:=${HOME:-/sandbox}/.toolbelt/config.json}"
: "${NEMOCLAW_START_BIN:=/usr/local/bin/nemoclaw-start}"

# Headless onboarding command. Overridable for tests. Runs `toolbelt install`,
# which provisions an anonymous token (or uses $TOOLBELT_TOKEN/$TOOLBELT_HOST) and
# writes it to $TOOLBELT_CLI_CONFIG. --no-skills because skills are baked at build time.
default_install_cmd() {
  printf 'toolbelt install --client openclaw --no-skills'
  [ -n "${TOOLBELT_HOST:-}" ] && printf ' --host %q' "$TOOLBELT_HOST"
}

# Read a top-level string key from a JSON file via node. $1=file $2=key
read_json_key() {
  node -e 'const fs=require("fs");const o=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));const v=o[process.argv[2]];if(v==null){process.exit(3)}process.stdout.write(String(v))' "$1" "$2"
}

# Resolve the instance token: explicit env > persisted > onboarding delegate.
# Prints token to stdout; persists onboarded tokens to $TOOLBELT_STATE_DIR/token.
resolve_token() {
  if [ -n "${TOOLBELT_TOKEN:-}" ]; then printf '%s' "$TOOLBELT_TOKEN"; return 0; fi
  local store="$TOOLBELT_STATE_DIR/token"
  if [ -s "$store" ]; then cat "$store"; return 0; fi
  mkdir -p "$TOOLBELT_STATE_DIR"
  local cmd="${TOOLBELT_INSTALL_CMD:-$(default_install_cmd)}"
  eval "$cmd" >&2 || return 1
  local tok
  tok="$(read_json_key "$TOOLBELT_CLI_CONFIG" token)" || { echo "toolbelt-claw: no token in $TOOLBELT_CLI_CONFIG" >&2; return 1; }
  [ -n "$tok" ] || { echo "toolbelt-claw: empty onboarded token" >&2; return 1; }
  printf '%s' "$tok" > "$store"
  printf '%s' "$tok"
}

# Optionally override the baked MCP url (non-secret). No-op unless TOOLBELT_MCP_URL set.
# Never touches the Authorization header (token stays a placeholder, off-disk).
write_mcp_url() {
  [ -n "${TOOLBELT_MCP_URL:-}" ] || return 0
  node -e 'const fs=require("fs");const p=process.argv[1];const url=process.argv[2];const o=JSON.parse(fs.readFileSync(p,"utf8"));o.mcp=o.mcp||{};o.mcp.servers=o.mcp.servers||{};o.mcp.servers.toolbelt=o.mcp.servers.toolbelt||{};o.mcp.servers.toolbelt.url=url;fs.writeFileSync(p,JSON.stringify(o,null,2))' "$OPENCLAW_CONFIG_PATH" "$TOOLBELT_MCP_URL"
}

main() {
  local token
  token="$(resolve_token)"
  export TOOLBELT_TOKEN="$token"   # resolves the baked `openshell:resolve:env:TOOLBELT_TOKEN` placeholder
  write_mcp_url
  exec "$NEMOCLAW_START_BIN" "$@"
}

if [ -z "${TOOLBELT_SHIM_LIB:-}" ]; then main "$@"; fi
