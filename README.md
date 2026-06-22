# toolbelt-claw

Toolbelt-aware wrapper image for [NemoClaw](https://github.com/NVIDIA/NemoClaw). The OpenClaw
agent inside ships with the Toolbelt MCP server registered and the Toolbelt skills installed, and
binds to a Toolbelt instance at runtime via a token.

## How it works

NVIDIA does not publish a pullable NemoClaw runtime "sandbox" image; the NemoClaw CLI builds it
locally on the host during onboarding (only `sandbox-base` is public). So this is a **two-stage
build**, orchestrated by `build.sh`:

1. **Stage 1:** build NemoClaw's `sandbox` from NemoClaw source at a pinned commit, on top of the
   public `ghcr.io/nvidia/nemoclaw/sandbox-base`.
2. **Stage 2:** layer this wrapper on top of that image.

At build time the wrapper installs
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
./build.sh                       # builds Stage 1 (cached after first run) + Stage 2
IMAGE_TAG=toolbelt-claw:0.1.0 \
TOOLBELT_SKILLS_VERSION=1.0.12 \
TOOLBELT_CLI_VERSION=0.1.6 \
TOOLBELT_MCP_URL=https://mcp.toolbelt.ai/mcp \
./build.sh
```

The first run clones NemoClaw and builds the `sandbox` image (a few minutes); later runs reuse it.

| Env var | Purpose | Default |
|---|---|---|
| `NEMOCLAW_REF` | NemoClaw commit to build Stage 1 from | pinned (see `docs/nemoclaw-findings.md`) |
| `NEMOCLAW_SANDBOX_TAG` | tag for the Stage 1 sandbox image | `nemoclaw-sandbox:local` |
| `NEMOCLAW_SRC` | path to an existing NemoClaw checkout (skips clone) | _(clone)_ |
| `REBUILD_SANDBOX` | `1` to rebuild Stage 1 even if the tag exists | `0` |
| `BASE_IMAGE` | prebuilt sandbox image to layer on; **skips Stage 1** if set | _(Stage 1 output)_ |
| `TOOLBELT_SKILLS_VERSION` | `@toolbeltai/skills` version (floating) | `latest` |
| `TOOLBELT_CLI_VERSION` | `@toolbeltai/cli` version (onboarding delegate) | `latest` |
| `TOOLBELT_MCP_URL` | MCP endpoint baked into the config | `https://mcp.toolbelt.ai/mcp` |

> Stage 1 builds unauthenticated against the public `sandbox-base`. Set `BASE_IMAGE` only if you
> already have a built (or authenticated) NemoClaw `sandbox` image and want to skip Stage 1.

### Inference target (baked at build time)

The inference endpoint and model are baked into `openclaw.json` during Stage 1; they are **not**
read at runtime, so setting them on `docker run` has no effect. Pass them to the build instead.
`build.sh` forwards any of these that you set into NemoClaw's Stage 1 build; unset ones use
NemoClaw's defaults (which point at a placeholder `inference.local`, i.e. not a working model).

| Inference build var | Purpose |
|---|---|
| `NEMOCLAW_INFERENCE_BASE_URL` | OpenAI-compatible endpoint, e.g. `https://your-endpoint/v1` |
| `NEMOCLAW_MODEL` | model id, e.g. `meta/llama-3.3-70b-instruct` |
| `NEMOCLAW_PRIMARY_MODEL_REF` | primary agent model ref, e.g. `inference/meta/llama-3.3-70b-instruct` |
| `NEMOCLAW_PROVIDER_KEY` | provider key/name (default `inference`; e.g. `ollama`) |
| `NEMOCLAW_INFERENCE_API` | API flavor (default `openai-completions`) |

```bash
NEMOCLAW_INFERENCE_BASE_URL=https://your-endpoint/v1 \
NEMOCLAW_MODEL=meta/llama-3.3-70b-instruct \
NEMOCLAW_PRIMARY_MODEL_REF=inference/meta/llama-3.3-70b-instruct \
REBUILD_SANDBOX=1 ./build.sh
```

> Inference auth is handled by NemoClaw's managed proxy, not an API key in the config (the
> provider `apiKey` is intentionally `"unused"`). Changing inference after a first build needs
> `REBUILD_SANDBOX=1` (Stage 1 is cached by tag).

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
- `bash test/smoke.sh`: runs the two-stage build and verifies structure plus onboarding paths
  (needs Docker; Stage 1 pulls the public `sandbox-base`). Verified passing. `SMOKE_RUNTIME=1 bash
  test/smoke.sh` adds a real gateway health check, which requires the full NemoClaw runtime
  substrate (OpenShell sandbox plus real inference) and will not pass under plain Docker.

## Design

See `docs/superpowers/specs/2026-06-19-toolbelt-claw-wrapper-design.md` and the verified build
facts in `docs/nemoclaw-findings.md`.
