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
