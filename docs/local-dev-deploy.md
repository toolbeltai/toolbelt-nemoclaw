# Local Dev Deploy: NemoClaw + Toolbelt on your own box

How to stand up a Toolbelt-aware NemoClaw (OpenClaw) agent on a developer machine, using
NVIDIA's official quickstart plus the Toolbelt setup. This is the supported path; it replaces
the earlier custom-image approach (see "Background" at the bottom).

## Architecture (what installs where)

It is a **hybrid** install, not a single container:

- **On the host (your box):** Node.js, the `nemoclaw` CLI (`~/.local/bin/nemoclaw`, source in
  `~/.nemoclaw/`), the OpenShell binaries, and the OpenShell **gateway process**. State lives in
  `~/.nemoclaw/` and `~/.local/state/nemoclaw/`.
- **In a Docker container (on your box's Docker):** the agent itself. OpenClaw runs inside an
  `openshell/sandbox-from:*` sandbox container that the CLI builds and manages. The Toolbelt MCP
  entry and skills live here.

The CLI is the control plane on your host; the agent is the isolated container it manages. Run the
quickstart **directly on the host** — do NOT run the CLI inside a container (that forces
Docker-in-Docker and is only relevant to a headless/k8s packaging).

## Prerequisites (one-time)

1. **Docker installed and running**, with **>=16 GB RAM** allocated. (Onboarding warns about OOM
   on the sandbox build below ~9 GB.)
2. **Host tools:** `lsof` and `strings`.
   - macOS: both already present (allocate RAM in Docker Desktop settings).
   - Debian/Ubuntu: `sudo apt-get install -y lsof binutils`
3. An inference provider. This runbook uses **Anthropic + Claude Haiku** (cheap, fast). You need an
   Anthropic API key with a **non-zero credit balance** (a $0 balance fails provider validation
   with HTTP 400).

## Step 1: Install and onboard

**Interactive (simplest locally):**
```bash
curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash
# In the wizard: choose Anthropic, paste your key, pick model claude-haiku-4-5.
```

**Non-interactive (scriptable):**
```bash
curl -fsSL https://www.nvidia.com/nemoclaw.sh | \
  NEMOCLAW_NON_INTERACTIVE=1 \
  NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1 \
  NEMOCLAW_PROVIDER=anthropic \
  ANTHROPIC_API_KEY="$(cat ~/.anthropic_key)" \
  NEMOCLAW_MODEL=claude-haiku-4-5 \
  NEMOCLAW_SANDBOX_NAME=toolbelt \
  bash -s -- --non-interactive
```

What happens (the 8 onboarding steps): preflight checks, start the OpenShell gateway, validate the
provider against the live endpoint, set the inference route, build the sandbox image, create and
start the sandbox. The first run builds the sandbox image (a few minutes on a well-resourced box);
later runs reuse the Docker layer cache and are fast.

**Known stop points and fixes:**
- `Port 8080 not available` -> something else holds the gateway port. Re-run with
  `NEMOCLAW_GATEWAY_PORT=<free-port>`.
- `credit balance is too low (HTTP 400)` -> the key is valid but the Anthropic account has no
  credits. Add credits and re-run.
- Third-party notice in non-interactive mode -> include
  `NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1` (or `--yes-i-accept-third-party-software`).

## Step 2: Add Toolbelt (inside the sandbox)

The agent reads `/sandbox/.openclaw/openclaw.json` inside the sandbox, so Toolbelt must be installed
**in the sandbox**, not on the host:
```bash
nemoclaw toolbelt connect          # open a shell in the sandbox named "toolbelt"
# then, inside the sandbox:
npx -y @toolbeltai/cli@latest install --client openclaw
```
This provisions a Toolbelt token (anonymous unless `TOOLBELT_TOKEN` is set), writes a nested
`mcp.servers.toolbelt` entry (`https://mcp.toolbelt.ai/mcp`) into the agent's `openclaw.json`, and
installs the Toolbelt skills.

## Step 3: Use it

```bash
openclaw tui                       # or reconnect: nemoclaw toolbelt connect
```

## Two caveats to handle

1. **Live MCP egress.** The sandbox network policy is an allowlist. ClawHub is already permitted
   (so the install + skills work), but the agent's **live** MCP calls to `mcp.toolbelt.ai` are
   blocked until that host is allowlisted via a `toolbelt` blueprint **preset** (selected with
   `NEMOCLAW_POLICY_PRESETS=toolbelt`, supplied via `NEMOCLAW_BLUEPRINT_PATH`). Without it, the
   agent runs but cannot reach Toolbelt at runtime.
2. **Skills version drift.** `@toolbeltai/cli@0.1.6` pins `@toolbeltai/skills` at `^0.2.0`, which
   resolves to `0.2.5` and installs the **old 7 skills**, not the consolidated single `toolbelt`
   skill (which ships in `@toolbeltai/skills` 1.x, latest `1.0.12`). A `^0.2.0` range cannot cross
   to 1.x. **Fix:** bump the CLI's dependency to `^1.0.0` and republish `@toolbeltai/cli`; then
   `toolbelt install` installs just `toolbelt`.

## Build-speed tips (local iteration)

- The sandbox build is a **one-time, cached** cost per NemoClaw/OpenClaw version. Do not
  `docker system prune` the build cache between deploys; reuse the same daemon and sandbox name.
- Give Docker **>=16 GB RAM + several CPUs** (biggest single win for `npm ci`/`tsc`).
- The `lkg` build may rebuild `sandbox-base` locally (it requires glibc >= 2.39 and rejects an
  incompatible published base). Pinning `NEMOCLAW_INSTALL_TAG` to a release with a compatible
  published `sandbox-base` skips that extra build.
- Run **natively on the host**, not in nested Docker. Native Linux is fastest.

## To verify on first real run

These were not exercisable in the constrained test environment and should be confirmed on a real
box during the first deploy:
- The exact in-sandbox command to run `toolbelt install` (shell via `nemoclaw <name> connect`
  vs. a one-shot exec subcommand).
- The `toolbelt` egress preset contents (host + ports for `mcp.toolbelt.ai`).
- An end-to-end agent turn through Haiku that calls a Toolbelt tool.

## Background (why not the custom image)

An earlier approach built a custom two-stage image baking Toolbelt into a NemoClaw sandbox
(`Dockerfile`, `build.sh`, `bin/onboard-and-start.sh`). It is **superseded**: NemoClaw publishes no
pullable runtime image, and the sandbox gateway will not run healthy outside the OpenShell substrate.
Those files remain as verified reference only. Use this quickstart-based runbook for deploys. See
`docs/superpowers/specs/2026-06-22-toolbelt-claw-via-quickstart-design.md` and
`docs/nemoclaw-substrate-findings.md`.
