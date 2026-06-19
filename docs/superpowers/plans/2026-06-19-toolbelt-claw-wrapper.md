# toolbelt-claw Wrapper Container Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an OCI image that extends NVIDIA NemoClaw so its OpenClaw agent is Toolbelt-aware out of the box (MCP registered + `@toolbeltai/skills` baked in) and binds to a Toolbelt instance at runtime via a token, onboarding to obtain one when absent.

**Architecture:** Build from NemoClaw source (strategy A2) and inject a Toolbelt MCP config skeleton + skills + `toolbelt-cli` into the blueprint *before* NemoClaw's SHA256-pinning step, so the integrity hash covers our additions. Instance URL and token are runtime env (referenced as `${ENV}` placeholders in the baked config); a thin pre-launch shim resolves the token (provided → persisted → onboarding delegate) and `exec`s NemoClaw's entrypoint unchanged.

**Tech Stack:** Docker (multi-stage, BuildKit), Bash (shim + tests), Node/npm (skills + CLI install, already present in the NemoClaw base), NemoClaw `main`, `@toolbeltai/skills`, `toolbelt-cli`.

**Source of truth:** `docs/superpowers/specs/2026-06-19-toolbelt-claw-wrapper-design.md`. Read it before starting. Risks R1–R6 in §8 of the spec are resolved by Task 1.

---

## File Structure

| Path | Responsibility |
| --- | --- |
| `docs/nemoclaw-findings.md` | Created by Task 1. Records the resolved facts about NemoClaw's build (hash mechanism, skills install, onboarding command, writable state path). Every later task references it. |
| `config/toolbelt-mcp.json` | The Toolbelt MCP server entry merged into `openclaw.json`. URL + token are `${ENV}` references. |
| `bin/onboard-and-start.sh` | Pre-launch shim: validate `TOOLBELT_URL`, resolve token, export binding env, `exec` NemoClaw entrypoint. The only runtime logic we add. |
| `test/shim_test.sh` | Zero-dependency Bash test runner for the shim's token-resolution logic, using injected mock commands. Runs without building the image. |
| `test/smoke.sh` | Builds the image and asserts structure + startup (skills present, MCP skeleton baked, integrity intact, health OK). Requires registry access. |
| `Dockerfile` | A2 build: drive NemoClaw's build, inject MCP skeleton + skills + CLI + shim pre-pinning. |
| `build.sh` | Thin wrapper over `docker build` exposing the build ARGs. |
| `.env.example` | Documents the runtime env file. |
| `.gitignore` | Ignore local `.env`, build scratch. |
| `README.md` | Build args, runtime env file, state-dir mount, egress prerequisite. |

---

## Task 1: Discovery spike — resolve NemoClaw build facts (R1, R3, R5, R6)

This task produces no product code. It resolves the unknowns the rest of the plan depends on and records them in `docs/nemoclaw-findings.md`. Do this first; later tasks cite it.

**Files:**
- Create: `docs/nemoclaw-findings.md`

- [ ] **Step 1: Clone NemoClaw at a pinned ref into scratch**

```bash
SCRATCH="$(mktemp -d)"
git clone --depth 1 https://github.com/NVIDIA/NemoClaw "$SCRATCH/nemoclaw"
cd "$SCRATCH/nemoclaw"
git rev-parse HEAD   # record this commit SHA — it becomes the pinned source ref
```

- [ ] **Step 2: Resolve R1 — where/how `openclaw.json` is integrity-pinned**

```bash
grep -rniE "sha256|integrity|openclaw\.json|CONFIG_SHA|checksum" Dockerfile* scripts/ bin/ 2>/dev/null
```
Record in findings: the exact build step that computes the hash, where the expected hash is stored (ENV var name, or a file), and the **last point in the build before pinning** where files under `/sandbox/.nemoclaw/blueprints/` can still be added/edited. This is the A2 injection point. If no such point exists (pinning happens in the base image, not this Dockerfile), record that A2 is infeasible and the build falls back to A1 (layer + recompute hash).

- [ ] **Step 3: Resolve R3 — how OpenClaw loads skills and MCP servers**

```bash
grep -rniE "skills?|mcp|servers?|blueprint" Dockerfile* config/ blueprints/ 2>/dev/null | head -50
find . -name "openclaw.json" -o -name "*.blueprint*" 2>/dev/null
```
Record: the on-disk skills directory path inside the image, the JSON shape of an MCP server entry in `openclaw.json` (key names for URL and auth header/token), and whether those fields support `${ENV}` interpolation at gateway load (R2). If interpolation is unsupported, record the runtime-config-file fallback location the MCP client reads.

- [ ] **Step 4: Resolve R5 — the headless onboarding command**

```bash
npm view toolbelt-cli 2>/dev/null | sed -n '1,40p'
npx --yes toolbelt-cli@latest --help 2>/dev/null | sed -n '1,60p'
```
Record: the exact non-interactive `toolbelt-cli` subcommand that, given `TOOLBELT_URL` plus some credential, returns a token; how it emits the token (stdout vs. a file path); and what credential env it consumes. If no fully-headless command exists, record that and mark onboarding as local/dev-only — the token-provided path is then the only K8s-supported path.

- [ ] **Step 5: Resolve R6 — a writable state path under hardening**

From the Dockerfile/base inspection, identify a path the `sandbox` user can write at runtime that is **outside** the immutable blueprint (candidates: a `WORKDIR`, a `VOLUME`, `$HOME` of `sandbox`). Record the chosen default for `TOOLBELT_STATE_DIR`.

- [ ] **Step 6: Write the findings doc and commit**

Write `docs/nemoclaw-findings.md` with one section per resolved item (R1, R2, R3, R5, R6), each stating the concrete answer and the file/command it came from. Include the pinned NemoClaw commit SHA from Step 1 and the final A2-vs-A1 decision.

```bash
git add docs/nemoclaw-findings.md
git commit -m "Document NemoClaw build facts for toolbelt-claw (R1-R6)"
```

> **Decision gate:** If Step 2 concludes A1, then Task 6's Dockerfile uses `FROM ghcr.io/nvidia/nemoclaw/sandbox:<sha>` and adds a hash-recompute step using the mechanism found in Step 2. All other tasks are unchanged. The plan below is written for A2 (the expected outcome) and notes the A1 deviation where it matters.

---

## Task 2: Repo scaffolding

**Files:**
- Create: `.gitignore`, `.env.example`, `README.md` (stub)

- [ ] **Step 1: Create `.gitignore`**

```gitignore
# local runtime env (never commit real tokens)
.env
# build scratch
*.log
.DS_Store
```

- [ ] **Step 2: Create `.env.example`**

```bash
# Toolbelt instance host (optional; @toolbeltai/cli defaults to app.toolbelt.ai).
# Set for self-hosted / edge instances.
TOOLBELT_HOST=app.toolbelt.ai

# Provide a token for the normal path (user already has an account + token).
# Leave unset to trigger anonymous onboarding via `toolbelt install` on first start.
TOOLBELT_TOKEN=

# Optional explicit MCP URL. If set, the shim writes it into the baked MCP entry,
# overriding the build-time default (https://mcp.toolbelt.ai/mcp).
# TOOLBELT_MCP_URL=

# Writable path where an onboarding-obtained token is persisted for reuse.
# Default is baked into the image; override only if you mount elsewhere.
# TOOLBELT_STATE_DIR=/sandbox/.nemoclaw/state/toolbelt

# Inference (provider-agnostic, OpenAI-compatible passthrough — all required)
NEMOCLAW_INFERENCE_BASE_URL=https://your-inference-endpoint/v1
NEMOCLAW_MODEL=your-model-ref
# Provider API key — use the env var name NemoClaw expects (confirm in docs/nemoclaw-findings.md)
# OPENAI_API_KEY=
```

- [ ] **Step 3: Create `README.md` stub**

```markdown
# toolbelt-claw

Toolbelt-aware wrapper image for [NemoClaw](https://github.com/NVIDIA/NemoClaw).

See `docs/superpowers/specs/2026-06-19-toolbelt-claw-wrapper-design.md` for the design.
Build args, runtime env, and the egress prerequisite are documented at the bottom of this file
(filled in by the final task).
```

- [ ] **Step 4: Commit**

```bash
git add .gitignore .env.example README.md
git commit -m "Scaffold toolbelt-claw repo"
```

---

> ⚠️ **SUPERSEDED by "Revised Tasks (post-spike)" at the end of this document.** Task 1's findings (`docs/nemoclaw-findings.md`) corrected the paths, the package name, the MCP shape, and the token mechanism. Implement the revised version.

## Task 3: Onboarding shim — token resolution (TDD)

The shim is pure Bash and fully testable in isolation by injecting mock commands. Build the resolution logic test-first. The shim must be *sourceable* (functions defined, no side effects) when `TOOLBELT_SHIM_LIB=1`, and *executable* (resolve + exec) otherwise, so tests can source it.

**Files:**
- Create: `bin/onboard-and-start.sh`, `test/shim_test.sh`

- [ ] **Step 1: Write the failing test runner**

Create `test/shim_test.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
assert_eq() { # $1=actual $2=expected $3=msg
  if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "FAIL: $3"; echo "  expected: [$2]"; echo "  actual:   [$1]"; fi
}
assert_rc() { # $1=actual_rc $2=expected_rc $3=msg
  if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "FAIL: $3 (rc expected $2 got $1)"; fi
}

# Load the shim as a library (defines functions, runs nothing).
TOOLBELT_SHIM_LIB=1 source "$SCRIPT_DIR/bin/onboard-and-start.sh"

# --- Test 1: explicit token wins ---
work="$(mktemp -d)"
TOOLBELT_URL="https://x" TOOLBELT_TOKEN="tok-explicit" TOOLBELT_STATE_DIR="$work" \
  TOOLBELT_ONBOARD_CMD="false" \
  out="$(resolve_token)"; rc=$?
assert_rc "$rc" "0" "explicit token resolves rc0"
assert_eq "$out" "tok-explicit" "explicit token returned verbatim"

# --- Test 2: persisted token reused when no explicit token ---
work="$(mktemp -d)"; printf 'tok-saved' > "$work/token"
TOOLBELT_URL="https://x" TOOLBELT_TOKEN="" TOOLBELT_STATE_DIR="$work" \
  TOOLBELT_ONBOARD_CMD="false" \
  out="$(resolve_token)"; rc=$?
assert_rc "$rc" "0" "persisted token resolves rc0"
assert_eq "$out" "tok-saved" "persisted token returned"

# --- Test 3: onboarding delegate invoked + token persisted ---
work="$(mktemp -d)"
TOOLBELT_URL="https://x" TOOLBELT_TOKEN="" TOOLBELT_STATE_DIR="$work" \
  TOOLBELT_ONBOARD_CMD="printf tok-onboarded" \
  out="$(resolve_token)"; rc=$?
assert_rc "$rc" "0" "onboarding resolves rc0"
assert_eq "$out" "tok-onboarded" "onboarded token returned"
assert_eq "$(cat "$work/token")" "tok-onboarded" "onboarded token persisted to state dir"

# --- Test 4: missing TOOLBELT_URL fails fast ---
( unset TOOLBELT_URL; TOOLBELT_TOKEN="t" require_url ) ; rc=$?
assert_rc "$rc" "1" "missing URL fails fast"

# --- Test 5: onboarding failure propagates non-zero ---
work="$(mktemp -d)"
TOOLBELT_URL="https://x" TOOLBELT_TOKEN="" TOOLBELT_STATE_DIR="$work" \
  TOOLBELT_ONBOARD_CMD="false" \
  out="$(resolve_token)"; rc=$?
assert_rc "$rc" "1" "onboarding failure propagates"

echo "---"; echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Run the test, verify it fails**

```bash
chmod +x test/shim_test.sh
bash test/shim_test.sh
```
Expected: fails — `bin/onboard-and-start.sh` does not exist yet (source error), or functions undefined.

- [ ] **Step 3: Implement the shim**

Create `bin/onboard-and-start.sh`:

```bash
#!/usr/bin/env bash
# Apply strict mode ONLY when executed directly. When sourced as a library for
# tests (TOOLBELT_SHIM_LIB=1), leave the caller's shell options untouched —
# otherwise `set -e` would abort the test runner on intended-failure cases.
if [ -z "${TOOLBELT_SHIM_LIB:-}" ]; then
  set -euo pipefail
fi

: "${TOOLBELT_STATE_DIR:=/var/lib/toolbelt-claw}"
: "${NEMOCLAW_START_BIN:=/usr/local/bin/nemoclaw-start}"

require_url() {
  if [ -z "${TOOLBELT_URL:-}" ]; then
    echo "toolbelt-claw: TOOLBELT_URL is required" >&2
    return 1
  fi
}

# Resolve the instance token: explicit env > persisted file > onboarding delegate.
# Prints the token to stdout. Persists onboarded tokens to $TOOLBELT_STATE_DIR/token.
# The onboarding command is built lazily here (not at top level) so sourcing the
# script as a library never dereferences $TOOLBELT_URL under `set -u`.
resolve_token() {
  if [ -n "${TOOLBELT_TOKEN:-}" ]; then
    printf '%s' "$TOOLBELT_TOKEN"; return 0
  fi
  local store="$TOOLBELT_STATE_DIR/token"
  if [ -s "$store" ]; then
    cat "$store"; return 0
  fi
  mkdir -p "$TOOLBELT_STATE_DIR"
  # Default onboarding delegate; overridable for tests. Update the default
  # command string to the exact one from docs/nemoclaw-findings.md (Step 4).
  # Must print the token to stdout and exit 0 on success.
  local cmd="${TOOLBELT_ONBOARD_CMD:-toolbelt-cli login --url \"$TOOLBELT_URL\" --print-token}"
  local tok
  tok="$(eval "$cmd")" || return 1
  [ -n "$tok" ] || { echo "toolbelt-claw: onboarding returned empty token" >&2; return 1; }
  printf '%s' "$tok" > "$store"
  printf '%s' "$tok"
}

main() {
  require_url
  local token
  token="$(resolve_token)"
  # Export the binding the baked MCP skeleton references (${TOOLBELT_URL}/${TOOLBELT_TOKEN}).
  export TOOLBELT_URL
  export TOOLBELT_TOKEN="$token"
  exec "$NEMOCLAW_START_BIN" "$@"
}

# Run only when executed directly; stay inert when sourced as a library (tests).
if [ -z "${TOOLBELT_SHIM_LIB:-}" ]; then
  main "$@"
fi
```

> **A1/R2 deviation:** if `docs/nemoclaw-findings.md` says `openclaw.json` does *not* interpolate `${ENV}`, replace the two `export` lines in `main()` with a step that writes the resolved URL+token into the runtime-config-file location recorded in the findings (still never touching the hash-pinned file). Add a test asserting that file's contents.

- [ ] **Step 4: Run the test, verify it passes**

```bash
bash test/shim_test.sh
```
Expected: `PASS=9 FAIL=0` and exit 0.

- [ ] **Step 5: Commit**

```bash
chmod +x bin/onboard-and-start.sh
git add bin/onboard-and-start.sh test/shim_test.sh
git commit -m "Add onboarding shim with token-resolution tests"
```

---

> ⚠️ **SUPERSEDED by "Revised Tasks (post-spike)" at the end of this document.**

## Task 4: Toolbelt MCP config skeleton

**Files:**
- Create: `config/toolbelt-mcp.json`

> Use the exact JSON shape recorded in `docs/nemoclaw-findings.md` Step 3. The example below assumes a `mcpServers` map with `url` + header auth and `${ENV}` interpolation. Adjust key names to match the findings before writing.

- [ ] **Step 1: Write the skeleton**

```json
{
  "mcpServers": {
    "toolbelt": {
      "type": "http",
      "url": "${TOOLBELT_URL}/mcp",
      "headers": {
        "Authorization": "Bearer ${TOOLBELT_TOKEN}"
      }
    }
  }
}
```

- [ ] **Step 2: Validate it is well-formed JSON**

```bash
node -e 'JSON.parse(require("fs").readFileSync("config/toolbelt-mcp.json","utf8"))' && echo "valid json"
```
Expected: `valid json`.

- [ ] **Step 3: Commit**

```bash
git add config/toolbelt-mcp.json
git commit -m "Add Toolbelt MCP config skeleton"
```

---

## Task 5: build.sh wrapper

**Files:**
- Create: `build.sh`

- [ ] **Step 1: Write the build wrapper**

```bash
#!/usr/bin/env bash
set -euo pipefail

# Build the toolbelt-claw image. Override any ARG via env before invoking.
: "${IMAGE_TAG:=toolbelt-claw:dev}"
: "${BASE_IMAGE:=ghcr.io/nvidia/nemoclaw/sandbox:latest}"
: "${TOOLBELT_SKILLS_VERSION:=latest}"
: "${TOOLBELT_CLI_VERSION:=latest}"
: "${TOOLBELT_MCP_URL:=https://mcp.toolbelt.ai/mcp}"

DOCKER_BUILDKIT=1 docker build \
  --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
  --build-arg "TOOLBELT_SKILLS_VERSION=${TOOLBELT_SKILLS_VERSION}" \
  --build-arg "TOOLBELT_CLI_VERSION=${TOOLBELT_CLI_VERSION}" \
  --build-arg "TOOLBELT_MCP_URL=${TOOLBELT_MCP_URL}" \
  -t "${IMAGE_TAG}" \
  "$(dirname "$0")"
```

- [ ] **Step 2: Verify it parses and shows the command (dry sanity check)**

```bash
chmod +x build.sh
bash -n build.sh && echo "syntax ok"
```
Expected: `syntax ok`.

- [ ] **Step 3: Commit**

```bash
git add build.sh
git commit -m "Add build wrapper exposing image ARGs"
```

---

> ⚠️ **SUPERSEDED by "Revised Tasks (post-spike)" at the end of this document.**

## Task 6: Dockerfile (A2 build)

**Files:**
- Create: `Dockerfile`

> This Dockerfile must inject our files into the blueprint **before** NemoClaw's pinning step (the injection point from `docs/nemoclaw-findings.md` Step 2). The skeleton below is the A2 shape; align the `COPY` destinations, skills dir, and the merge-into-`openclaw.json` step with the findings. If the findings concluded **A1**, base `FROM` the published sandbox image instead and append the hash-recompute command recorded in Step 2 after the merge.

- [ ] **Step 1: Write the Dockerfile**

```dockerfile
# syntax=docker/dockerfile:1
ARG BASE_IMAGE=ghcr.io/nvidia/nemoclaw/sandbox-base:latest
FROM ${BASE_IMAGE}

ARG TOOLBELT_SKILLS_VERSION=latest
ARG TOOLBELT_CLI_VERSION=latest

# 1. Install Toolbelt tooling: skills (agent tool source) + CLI (onboarding delegate).
#    Paths/install method per docs/nemoclaw-findings.md (Step 3 = skills dir, Step 4 = CLI).
RUN npm install -g "@toolbeltai/skills@${TOOLBELT_SKILLS_VERSION}" \
                   "toolbelt-cli@${TOOLBELT_CLI_VERSION}"

# 2. Inject the MCP server skeleton into openclaw.json BEFORE the integrity pinning step.
#    The merge command and blueprint path come from docs/nemoclaw-findings.md (Step 2/3).
COPY config/toolbelt-mcp.json /tmp/toolbelt-mcp.json
# Merge with node (Node 22 is present in the NemoClaw base; python3 may not be).
RUN node -e '\
const fs = require("fs"); \
const bp = "/sandbox/.nemoclaw/blueprints/0.1.0/openclaw.json"; /* confirm path in findings */ \
const cfg = JSON.parse(fs.readFileSync(bp, "utf8")); \
const frag = JSON.parse(fs.readFileSync("/tmp/toolbelt-mcp.json", "utf8")); \
cfg.mcpServers = Object.assign(cfg.mcpServers || {}, frag.mcpServers); \
fs.writeFileSync(bp, JSON.stringify(cfg, null, 2)); \
'

# 3. <PINNING STEP> — re-run NemoClaw's openclaw.json hash-pinning here, per findings Step 2.
#    (A2: the pinning command exists in NemoClaw's build; invoke it now so the hash covers
#     our merged config. A1 fallback: recompute + rewrite the stored hash here.)

# 4. Install the pre-launch shim and make it the entrypoint.
COPY bin/onboard-and-start.sh /usr/local/bin/onboard-and-start.sh
RUN chmod +x /usr/local/bin/onboard-and-start.sh

ENV TOOLBELT_STATE_DIR=/var/lib/toolbelt-claw
RUN mkdir -p /var/lib/toolbelt-claw && chown sandbox:sandbox /var/lib/toolbelt-claw
VOLUME ["/var/lib/toolbelt-claw"]

ENTRYPOINT ["/usr/local/bin/onboard-and-start.sh"]
CMD ["/bin/bash"]
```

- [ ] **Step 2: Lint the Dockerfile**

```bash
docker run --rm -i hadolint/hadolint < Dockerfile || true   # advisory; review warnings
```
Expected: no errors that block build (warnings acceptable).

- [ ] **Step 3: Commit**

```bash
git add Dockerfile
git commit -m "Add A2 Dockerfile injecting Toolbelt MCP, skills, CLI, and shim"
```

> The actual `docker build` is exercised in Task 7 (smoke test), since it requires registry access to the NemoClaw base image.

---

## Task 7: Image smoke test

**Files:**
- Create: `test/smoke.sh`

> Requires Docker and pull access to the NemoClaw base image. If the base image is gated, record that and run this test in an environment that has access (CI with the credential). Onboarding and inference are mocked — no live Toolbelt/provider calls.

- [ ] **Step 1: Write the smoke test**

```bash
#!/usr/bin/env bash
set -euo pipefail
IMAGE_TAG="${IMAGE_TAG:-toolbelt-claw:dev}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "== building =="
IMAGE_TAG="$IMAGE_TAG" bash "$ROOT/build.sh"

echo "== assert skills present =="
# Path from docs/nemoclaw-findings.md Step 3.
docker run --rm --entrypoint sh "$IMAGE_TAG" -c \
  'ls -d "$(npm root -g)/@toolbeltai/skills"' >/dev/null
echo "skills OK"

echo "== assert MCP skeleton baked into openclaw.json =="
docker run --rm --entrypoint sh "$IMAGE_TAG" -c \
  'grep -q "TOOLBELT_URL" /sandbox/.nemoclaw/blueprints/0.1.0/openclaw.json'   # confirm path
echo "MCP skeleton OK"

echo "== assert toolbelt-cli present =="
docker run --rm --entrypoint sh "$IMAGE_TAG" -c 'command -v toolbelt-cli' >/dev/null
echo "cli OK"

echo "== token-provided path: shim binds without onboarding =="
# Onboarding command is forced to fail; with a token provided the shim must not call it.
# NEMOCLAW_START_BIN is overridden to a probe that prints a marker and exits.
docker run --rm \
  -e TOOLBELT_URL="https://example.invalid" \
  -e TOOLBELT_TOKEN="tok-provided" \
  -e TOOLBELT_ONBOARD_CMD="false" \
  -e NEMOCLAW_START_BIN="/bin/sh" \
  --entrypoint /usr/local/bin/onboard-and-start.sh \
  "$IMAGE_TAG" -c 'echo BOUND token=$TOOLBELT_TOKEN' | grep -q "BOUND token=tok-provided"
echo "token-provided path OK"

echo "== onboarding path: delegate invoked, token persisted, reused on restart =="
VOL="$(docker volume create)"
run_onboard() {
  docker run --rm -v "$VOL:/var/lib/toolbelt-claw" \
    -e TOOLBELT_URL="https://example.invalid" \
    -e TOOLBELT_ONBOARD_CMD="printf tok-onboarded" \
    -e NEMOCLAW_START_BIN="/bin/sh" \
    --entrypoint /usr/local/bin/onboard-and-start.sh \
    "$IMAGE_TAG" -c 'echo BOUND token=$TOOLBELT_TOKEN'
}
run_onboard | grep -q "BOUND token=tok-onboarded"
# Second run must reuse the persisted token even if onboarding would now fail.
docker run --rm -v "$VOL:/var/lib/toolbelt-claw" \
  -e TOOLBELT_URL="https://example.invalid" \
  -e TOOLBELT_ONBOARD_CMD="false" \
  -e NEMOCLAW_START_BIN="/bin/sh" \
  --entrypoint /usr/local/bin/onboard-and-start.sh \
  "$IMAGE_TAG" -c 'echo BOUND token=$TOOLBELT_TOKEN' | grep -q "BOUND token=tok-onboarded"
docker volume rm "$VOL" >/dev/null
echo "onboarding path OK"

echo "ALL SMOKE CHECKS PASSED"
```

- [ ] **Step 2: Run the smoke test (in an environment with base-image access)**

```bash
chmod +x test/smoke.sh
bash test/smoke.sh
```
Expected: ends with `ALL SMOKE CHECKS PASSED`.

- [ ] **Step 2b: Integrity + health check (gated — requires NemoClaw runtime substrate)**

The structural and shim-path checks above run anywhere with Docker. Asserting that NemoClaw's
**runtime integrity check passes** over our merged config (spec §7.3) and that the gateway is
**healthy** (spec §7.6) requires actually starting `nemoclaw-start`, which needs the
OpenShell/GPU substrate NemoClaw targets. Run this in that environment (e.g. a GPU CI runner),
not on a plain dev box. Insert this block into `test/smoke.sh` **immediately before** the final
`echo "ALL SMOKE CHECKS PASSED"` line, behind a flag:

```bash
if [ "${SMOKE_RUNTIME:-0}" = "1" ]; then
  echo "== integrity + health (real gateway) =="
  CID="$(docker run -d \
    -e TOOLBELT_URL="https://example.invalid" \
    -e TOOLBELT_TOKEN="tok-provided" \
    -e NEMOCLAW_INFERENCE_BASE_URL="http://127.0.0.1:9/v1" \
    -e NEMOCLAW_MODEL="dummy" \
    "$IMAGE_TAG")"
  # Poll the documented healthcheck endpoint for up to 60s.
  for i in $(seq 1 30); do
    if docker exec "$CID" sh -c 'curl -fsS http://127.0.0.1:18789/health' >/dev/null 2>&1; then
      echo "health OK (integrity check passed at startup)"; ok=1; break
    fi
    sleep 2
  done
  docker logs "$CID" | tail -20
  docker rm -f "$CID" >/dev/null
  [ "${ok:-0}" = "1" ] || { echo "FAIL: gateway never became healthy"; exit 1; }
fi
```

Run it where the substrate exists:

```bash
SMOKE_RUNTIME=1 bash test/smoke.sh
```
Expected: ends with `health OK (integrity check passed at startup)` then `ALL SMOKE CHECKS PASSED`.

> If the integrity check rejects the merged config at startup, Task 1/Task 6 got the pinning step wrong — return to `docs/nemoclaw-findings.md` Step 2 rather than disabling the check.

- [ ] **Step 3: Commit**

```bash
git add test/smoke.sh
git commit -m "Add image smoke test for structure, onboarding, and gated runtime health"
```

---

> ⚠️ **The runtime env table below is SUPERSEDED** — use the corrected env contract from "Revised Tasks (post-spike)" (`TOOLBELT_HOST`/`TOOLBELT_TOKEN`/`TOOLBELT_MCP_URL`, state dir `/sandbox/.nemoclaw/state/toolbelt`, CLI `@toolbeltai/cli`). The structure of this task (write the README) is otherwise unchanged.

## Task 8: Finalize README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Replace the stub with full docs**

```markdown
# toolbelt-claw

Toolbelt-aware wrapper image for [NemoClaw](https://github.com/NVIDIA/NemoClaw). The OpenClaw
agent inside ships with the Toolbelt MCP server registered and `@toolbeltai/skills` installed.
The image binds to a Toolbelt instance at runtime.

## Build

```bash
./build.sh                       # uses defaults
IMAGE_TAG=toolbelt-claw:0.1.0 \
TOOLBELT_SKILLS_VERSION=1.2.3 \
TOOLBELT_CLI_VERSION=1.0.0 \
./build.sh
```

| Build ARG | Purpose | Default |
| --- | --- | --- |
| `BASE_IMAGE` | NemoClaw sandbox base | `ghcr.io/nvidia/nemoclaw/sandbox-base:latest` |
| `TOOLBELT_SKILLS_VERSION` | `@toolbeltai/skills` version (floating) | `latest` |
| `TOOLBELT_CLI_VERSION` | `toolbelt-cli` version (onboarding delegate) | `latest` |

## Run

```bash
docker run --env-file .env -v toolbelt-claw-state:/var/lib/toolbelt-claw toolbelt-claw:dev
```

Copy `.env.example` to `.env` and fill it in.

| Runtime env | Purpose | Required |
| --- | --- | --- |
| `TOOLBELT_URL` | Toolbelt instance base URL | yes |
| `TOOLBELT_TOKEN` | instance token; if set, used directly (normal path) | no |
| `TOOLBELT_STATE_DIR` | writable path for an onboarded token | defaulted to `/var/lib/toolbelt-claw` |
| `NEMOCLAW_INFERENCE_BASE_URL` | OpenAI-compatible inference endpoint | yes |
| `NEMOCLAW_MODEL` | model ref | yes |
| inference API key | provider key (see name in `docs/nemoclaw-findings.md`) | yes |

If `TOOLBELT_TOKEN` is omitted, the container onboards via `toolbelt-cli` on first start and
persists the token to `TOOLBELT_STATE_DIR`. Mount that path on a volume so restarts reuse it.

## Prerequisites

**Egress:** NemoClaw forces outbound through a managed L7 proxy. The Toolbelt instance host must
be allowed through the proxy / network policy for both the MCP connection and onboarding. In
Kubernetes this is handled by the deployment spec (out of scope here).

## Tests

- `bash test/shim_test.sh` — shim token-resolution logic (no Docker needed).
- `bash test/smoke.sh` — builds the image and verifies structure + onboarding paths (needs base-image pull access).

## Design

See `docs/superpowers/specs/2026-06-19-toolbelt-claw-wrapper-design.md` and
`docs/nemoclaw-findings.md`.
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "Document build args, runtime env, and prerequisites"
```

---

## Revised Tasks (post-spike) — AUTHORITATIVE for Tasks 3, 4, 6

Task 1's findings (`docs/nemoclaw-findings.md`) and the chosen **placeholder** runtime
approach supersede the original Tasks 3, 4, 6. Corrected facts:

- Pinned/loaded config: **`/sandbox/.openclaw/openclaw.json`** (= `OPENCLAW_CONFIG_PATH`). Runtime integrity check is a **no-op unless "shields up"**, so runtime/build edits boot cleanly; **no re-pin needed** for the default image.
- MCP entry is **nested under `mcp.servers.<name>`** (NOT flat `mcpServers`): `{ "type":"http", "url":"…", "headers":{ "Authorization":"Bearer …" } }`.
- Skills dir: **`/sandbox/.openclaw/skills`**.
- CLI package: **`@toolbeltai/cli`** (bin `toolbelt`), NOT `toolbelt-cli`. Headless onboarding: `toolbelt install --client openclaw` provisions an anonymous token via `POST /api/onboard`, writes it to **`~/.toolbelt/config.json`** (key `token`, mode 0600) — NOT stdout.
- State dir default: **`/sandbox/.nemoclaw/state/toolbelt`**.
- **Token mechanism (placeholder):** bake `headers.Authorization = "Bearer openshell:resolve:env:TOOLBELT_TOKEN"` at build. NemoClaw resolves it from the `TOOLBELT_TOKEN` env var at start (whitelisted for Bearer headers in `credential-filter.ts`), so the literal token never lands in `openclaw.json`. The non-secret `url` is baked (build ARG `TOOLBELT_MCP_URL`, default `https://mcp.toolbelt.ai/mcp`) and optionally overridden at runtime by the shim (placeholder-in-url is unconfirmed).

### Task 3 (revised): Onboarding shim — token resolution + url override (TDD)

**Files:** Create `bin/onboard-and-start.sh`, `test/shim_test.sh`.

The shim resolves `TOOLBELT_TOKEN` and exports it (so the baked placeholder resolves),
optionally writes the MCP `url`, then `exec`s NemoClaw's entrypoint. It is sourceable as a
library when `TOOLBELT_SHIM_LIB=1` (defines functions, runs nothing). All external commands and
paths are overridable via env so tests inject mocks. Token parsing uses `node` (present in base).

- [ ] **Step 1: Write the failing test** — `test/shim_test.sh`:

```bash
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
```

- [ ] **Step 2: Run, verify it fails** — `bash test/shim_test.sh` → fails (script missing).

- [ ] **Step 3: Implement `bin/onboard-and-start.sh`:**

```bash
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
# writes it to $TOOLBELT_CLI_CONFIG. Update the default to the exact verified
# invocation; --no-skills because skills are baked at build time.
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
```

- [ ] **Step 4: Run, verify pass** — `bash test/shim_test.sh` → `PASS=11 FAIL=0`.

- [ ] **Step 5: Commit** — `chmod +x bin/onboard-and-start.sh && git add bin/onboard-and-start.sh test/shim_test.sh && git commit -m "Add onboarding shim with token-resolution and url-override tests"`

> Verify during implementation: the exact `toolbelt install --client openclaw` flags and that it writes the token to `$TOOLBELT_CLI_CONFIG` (`~/.toolbelt/config.json`). Adjust `default_install_cmd`/`TOOLBELT_CLI_CONFIG` if the verified behavior differs. Do NOT change the test contract (mocks define the interface).

### Task 4 (revised): Toolbelt MCP config skeleton

**Files:** Create `config/toolbelt-mcp.json`.

- [ ] **Step 1: Write the nested skeleton** (url is a build-substituted placeholder, token is the NemoClaw env placeholder):

```json
{
  "mcp": {
    "servers": {
      "toolbelt": {
        "type": "http",
        "url": "__TOOLBELT_MCP_URL__",
        "headers": {
          "Authorization": "Bearer openshell:resolve:env:TOOLBELT_TOKEN"
        }
      }
    }
  }
}
```

- [ ] **Step 2: Validate JSON** — `node -e 'JSON.parse(require("fs").readFileSync("config/toolbelt-mcp.json","utf8"))' && echo "valid json"`.
- [ ] **Step 3: Commit** — `git add config/toolbelt-mcp.json && git commit -m "Add nested mcp.servers Toolbelt MCP skeleton with token placeholder"`

### Task 6 (revised): Dockerfile (derived build)

**Files:** Create `Dockerfile`.

Derived build: `FROM` the published NemoClaw sandbox image, install skills + CLI, merge the MCP
entry into `/sandbox/.openclaw/openclaw.json` (substituting the `url`), re-pin `.config-hash`
(cheap; keeps `shields up` valid), install the shim as entrypoint.

- [ ] **Step 1: Write the Dockerfile:**

```dockerfile
# syntax=docker/dockerfile:1
# Confirm the exact published runtime image tag; fall back to building from source
# at the pinned SHA (docs/nemoclaw-findings.md) if no published runtime image exists.
ARG BASE_IMAGE=ghcr.io/nvidia/nemoclaw/sandbox:latest
FROM ${BASE_IMAGE}

ARG TOOLBELT_SKILLS_VERSION=latest
ARG TOOLBELT_CLI_VERSION=latest
ARG TOOLBELT_MCP_URL=https://mcp.toolbelt.ai/mcp

USER root

# 1. Toolbelt tooling: CLI (onboarding delegate) globally; skills into OpenClaw's skills dir.
RUN npm install -g "@toolbeltai/cli@${TOOLBELT_CLI_VERSION}"
# Install skills into /sandbox/.openclaw/skills. Confirm the @toolbeltai/skills package
# layout and copy its skill folders into the skills dir (per docs/nemoclaw-findings.md R3).
RUN npm pack "@toolbeltai/skills@${TOOLBELT_SKILLS_VERSION}" --pack-destination /tmp \
    && tar -xzf /tmp/toolbeltai-skills-*.tgz -C /tmp \
    && mkdir -p /sandbox/.openclaw/skills \
    && cp -r /tmp/package/skills/* /sandbox/.openclaw/skills/ \
    && chown -R sandbox:sandbox /sandbox/.openclaw/skills

# 2. Merge the MCP entry into the loaded config, substituting the url ARG.
COPY config/toolbelt-mcp.json /tmp/toolbelt-mcp.json
RUN node -e '\
const fs=require("fs"); \
const cfgPath="/sandbox/.openclaw/openclaw.json"; \
const cfg=JSON.parse(fs.readFileSync(cfgPath,"utf8")); \
const frag=JSON.parse(fs.readFileSync("/tmp/toolbelt-mcp.json","utf8").replace("__TOOLBELT_MCP_URL__", process.env.TOOLBELT_MCP_URL)); \
cfg.mcp=cfg.mcp||{}; cfg.mcp.servers=Object.assign(cfg.mcp.servers||{}, frag.mcp.servers); \
fs.writeFileSync(cfgPath, JSON.stringify(cfg,null,2)); \
' \
    && rm -f /tmp/toolbelt-mcp.json

# 3. Re-pin the integrity hash so `shields up` stays valid (no-op-safe otherwise).
RUN sha256sum /sandbox/.openclaw/openclaw.json > /sandbox/.openclaw/.config-hash \
    && chmod 660 /sandbox/.openclaw/.config-hash \
    && chown sandbox:sandbox /sandbox/.openclaw/.config-hash

# 4. State dir for persisted onboarded tokens (sandbox-owned, durable).
RUN mkdir -p /sandbox/.nemoclaw/state/toolbelt && chown -R sandbox:sandbox /sandbox/.nemoclaw/state/toolbelt
ENV TOOLBELT_STATE_DIR=/sandbox/.nemoclaw/state/toolbelt

# 5. Pre-launch shim becomes the entrypoint; it execs the original nemoclaw-start.
COPY bin/onboard-and-start.sh /usr/local/bin/onboard-and-start.sh
RUN chmod +x /usr/local/bin/onboard-and-start.sh

ENTRYPOINT ["/usr/local/bin/onboard-and-start.sh"]
CMD ["/bin/bash"]
```

> `TOOLBELT_MCP_URL` must be passed as a build ARG into the `node` merge env. In `build.sh`
> (Task 5) add `--build-arg TOOLBELT_MCP_URL` and, in the Dockerfile merge `RUN`, prefix with the
> ARG via `ENV TOOLBELT_MCP_URL=${TOOLBELT_MCP_URL}` or pass it inline. Confirm the published
> runtime image tag and the `@toolbeltai/skills` package layout during implementation; if the
> skills tarball has no `skills/` dir, inspect the package and adjust the copy path.

- [ ] **Step 2: Lint** — `docker run --rm -i hadolint/hadolint < Dockerfile || true` (warnings OK).
- [ ] **Step 3: Commit** — `git add Dockerfile && git commit -m "Add derived Dockerfile: skills, CLI, MCP merge, re-pin, shim entrypoint"`

> Task 5 (build.sh) must add `TOOLBELT_MCP_URL` to its ARGs. Task 7 (smoke test) assertions
> change: skills at `/sandbox/.openclaw/skills`; MCP entry under `.mcp.servers.toolbelt` in
> `/sandbox/.openclaw/openclaw.json` with `Authorization` == `Bearer openshell:resolve:env:TOOLBELT_TOKEN`;
> CLI bin is `toolbelt`. The token-provided / onboarding shim-path tests use `NEMOCLAW_START_BIN`
> and `TOOLBELT_INSTALL_CMD` overrides as in Task 3.

## Out of scope (future specs)
- Kubernetes manifests: Deployment/ConfigMap/Secret, GPU scheduling, a PVC for `TOOLBELT_STATE_DIR`, and the egress/network-policy allowance for the Toolbelt instance host (likely a Helm values contribution to `toolbelt-devops/`).
- CI auto-release wiring consistent with the workspace release pattern.
