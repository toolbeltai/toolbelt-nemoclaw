# toolbelt-claw

Toolbelt-aware wrapper image for [NemoClaw](https://github.com/NVIDIA/NemoClaw). The OpenClaw
agent inside ships with the Toolbelt MCP server registered and the Toolbelt skills installed, and
binds to a Toolbelt instance at runtime via a token.

## How it works

The image is a derived build on top of NVIDIA's NemoClaw sandbox. At build time it installs
`@toolbeltai/cli` and the Toolbelt skills, and bakes an `mcp.servers.toolbelt` entry into
OpenClaw's config whose auth header is the NemoClaw placeholder
`Bearer openshell:resolve:env:TOOLBELT_TOKEN` (so the literal token never lands on disk). A
pre-launch shim (`bin/onboard-and-start.sh`) resolves the token and exports it before handing off
to NemoClaw's entrypoint:

1. If `TOOLBELT_TOKEN` is set, it is used (the normal path: a user who already has a token).
2. Else if a token was previously persisted to the state dir, it is reused.
3. Else the shim onboards anonymously via `toolbelt install --client openclaw` and persists the
   resulting token for reuse.

## Build

```bash
./build.sh                       # uses defaults
IMAGE_TAG=toolbelt-claw:0.1.0 \
TOOLBELT_SKILLS_VERSION=1.0.12 \
TOOLBELT_CLI_VERSION=0.1.6 \
TOOLBELT_MCP_URL=https://mcp.toolbelt.ai/mcp \
./build.sh
```

| Build ARG | Purpose | Default |
|---|---|---|
| `BASE_IMAGE` | NemoClaw sandbox image | `ghcr.io/nvidia/nemoclaw/sandbox:latest` |
| `TOOLBELT_SKILLS_VERSION` | `@toolbeltai/skills` version (floating) | `latest` |
| `TOOLBELT_CLI_VERSION` | `@toolbeltai/cli` version (onboarding delegate) | `latest` |
| `TOOLBELT_MCP_URL` | MCP endpoint baked into the config | `https://mcp.toolbelt.ai/mcp` |

> Pulling `ghcr.io/nvidia/nemoclaw/sandbox` may require GHCR authentication for the
> nvidia/nemoclaw org.

## Run

```bash
docker run --env-file .env -v toolbelt-claw-state:/sandbox/.nemoclaw/state/toolbelt toolbelt-claw:dev
```

Copy `.env.example` to `.env` and fill it in.

| Runtime env | Purpose | Required |
|---|---|---|
| `TOOLBELT_TOKEN` | instance token; if set, used directly (normal path) | no* |
| `TOOLBELT_HOST` | instance host for onboarding (CLI default `app.toolbelt.ai`) | no |
| `TOOLBELT_MCP_URL` | override the baked MCP URL at runtime | no |
| `TOOLBELT_STATE_DIR` | writable path for a persisted onboarded token | defaulted to `/sandbox/.nemoclaw/state/toolbelt` |
| `NEMOCLAW_INFERENCE_BASE_URL` | OpenAI-compatible inference endpoint | yes |
| `NEMOCLAW_MODEL` | model ref | yes |
| inference API key | provider key (see name in `docs/nemoclaw-findings.md`) | yes |

*If `TOOLBELT_TOKEN` is omitted, the container onboards anonymously on first start and persists
the token to `TOOLBELT_STATE_DIR`. Mount that path on a volume so restarts reuse it. Binding a
token to a real account uses the interactive `toolbelt claim` flow, which is not headless.

## Prerequisites

**Egress:** NemoClaw forces outbound through a managed L7 proxy. The Toolbelt instance host must
be allowed through the proxy and network policy for both the MCP connection and onboarding. In
Kubernetes this is handled by the deployment spec (out of scope here).

## Tests

- `bash test/shim_test.sh`: shim token-resolution and url-override logic (no Docker needed).
- `bash test/smoke.sh`: builds the image and verifies structure plus onboarding paths (needs
  Docker and base-image pull access). `SMOKE_RUNTIME=1 bash test/smoke.sh` adds a real gateway
  integrity and health check (needs the NemoClaw runtime substrate).

## Design

See `docs/superpowers/specs/2026-06-19-toolbelt-claw-wrapper-design.md` and the verified build
facts in `docs/nemoclaw-findings.md`.
