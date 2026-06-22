#!/usr/bin/env bash
set -euo pipefail

# Build the toolbelt-claw image.
#
# NemoClaw publishes no prebuilt runtime "sandbox" image (ghcr.io/.../sandbox is
# gated and is built locally by the NemoClaw CLI during onboarding). Only
# `sandbox-base` is public. So this is a TWO-STAGE build:
#   Stage 1: build NemoClaw's sandbox from source (FROM the public sandbox-base).
#   Stage 2: layer our Toolbelt wrapper (skills + MCP entry + shim) on top.
#
# Override any value via env before invoking. Set BASE_IMAGE to skip Stage 1
# entirely (e.g. if you already have a built/authenticated sandbox image).
: "${IMAGE_TAG:=toolbelt-claw:dev}"
: "${NEMOCLAW_SANDBOX_TAG:=nemoclaw-sandbox:local}"
: "${NEMOCLAW_REPO:=https://github.com/NVIDIA/NemoClaw}"
# Pinned in docs/nemoclaw-findings.md. Override to track a different NemoClaw.
: "${NEMOCLAW_REF:=4d33291df934819e3e913b64e14348f14e80cbf4}"
: "${NEMOCLAW_SRC:=}"            # path to an existing NemoClaw checkout; empty = clone
: "${REBUILD_SANDBOX:=0}"        # 1 = rebuild Stage 1 even if the tag already exists
: "${TOOLBELT_SKILLS_VERSION:=latest}"
: "${TOOLBELT_CLI_VERSION:=latest}"
: "${TOOLBELT_MCP_URL:=https://mcp.toolbelt.ai/mcp}"

HERE="$(cd "$(dirname "$0")" && pwd)"

# BASE_IMAGE for the wrapper defaults to the Stage 1 output. If the caller sets
# BASE_IMAGE explicitly, Stage 1 is skipped and that image is used directly.
explicit_base=0
if [ -n "${BASE_IMAGE:-}" ]; then explicit_base=1; else BASE_IMAGE="$NEMOCLAW_SANDBOX_TAG"; fi

build_sandbox() {
  if [ "$explicit_base" = "1" ]; then
    echo ">> BASE_IMAGE set explicitly ($BASE_IMAGE); skipping NemoClaw source build."
    return 0
  fi
  if [ "$REBUILD_SANDBOX" != "1" ] && docker image inspect "$NEMOCLAW_SANDBOX_TAG" >/dev/null 2>&1; then
    echo ">> Stage 1: reusing existing $NEMOCLAW_SANDBOX_TAG (set REBUILD_SANDBOX=1 to force)."
    return 0
  fi

  local src="$NEMOCLAW_SRC" cleanup=0
  if [ -z "$src" ]; then
    src="$(mktemp -d)"; cleanup=1
    echo ">> Stage 1: cloning NemoClaw $NEMOCLAW_REF into $src"
    git clone --no-checkout --filter=tree:0 "$NEMOCLAW_REPO" "$src"
    git -C "$src" checkout "$NEMOCLAW_REF"
  else
    echo ">> Stage 1: using NemoClaw checkout at $src"
  fi

  echo ">> Stage 1: building $NEMOCLAW_SANDBOX_TAG from NemoClaw source (FROM public sandbox-base)"
  DOCKER_BUILDKIT=1 docker build -t "$NEMOCLAW_SANDBOX_TAG" -f "$src/Dockerfile" "$src"

  [ "$cleanup" = "1" ] && rm -rf "$src"
}

build_wrapper() {
  echo ">> Stage 2: building $IMAGE_TAG (FROM $BASE_IMAGE)"
  DOCKER_BUILDKIT=1 docker build \
    --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
    --build-arg "TOOLBELT_SKILLS_VERSION=${TOOLBELT_SKILLS_VERSION}" \
    --build-arg "TOOLBELT_CLI_VERSION=${TOOLBELT_CLI_VERSION}" \
    --build-arg "TOOLBELT_MCP_URL=${TOOLBELT_MCP_URL}" \
    -t "${IMAGE_TAG}" \
    "$HERE"
}

build_sandbox
build_wrapper
echo ">> Done: $IMAGE_TAG"
