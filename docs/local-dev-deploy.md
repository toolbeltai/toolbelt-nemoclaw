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
quickstart **directly on the host**. Do NOT run the CLI inside a container (that forces
Docker-in-Docker and is only relevant to a headless/k8s packaging).

## Prerequisites (one-time)

1. **Docker installed and running**, with **>=16 GB RAM** allocated. (Onboarding warns about OOM
   on the sandbox build below ~9 GB.)
2. **Host tools:** `lsof` and `strings`.
   - macOS: both already present (allocate RAM in Docker Desktop settings).
   - Debian/Ubuntu: `sudo apt-get install -y lsof binutils`
3. An inference provider. Selection is **provider-agnostic** (see "Choosing a provider" below). The
   examples here use **Anthropic + Claude Haiku** (cheap, fast); that key needs a **non-zero credit
   balance** (a $0 balance fails provider validation with HTTP 400).

### Choosing a provider

NemoClaw selects the inference backend from three env vars, so you never edit a brand-specific key
name to switch providers:

| Var | Purpose |
|---|---|
| `NEMOCLAW_PROVIDER` | which backend: `anthropic`, `openai`, `gemini`, `build` (NVIDIA), `nim`, `ollama`, `vllm`, `custom` (any OpenAI-compatible endpoint), `anthropiccompatible` |
| `NEMOCLAW_MODEL` | model id for that provider (e.g. `claude-haiku-4-5`, `gpt-5.4`, `meta/llama-3.3-70b-instruct`) |
| `NEMOCLAW_PROVIDER_KEY` | the API key. This is a **universal alias**: NemoClaw applies it to whichever provider you select, so the brand-specific vars (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, ...) are not required. (Those still work if you prefer them; `NEMOCLAW_PROVIDER_KEY` only fills in when the specific one is unset.) Local providers `ollama`/`vllm` need no key. |

For a `custom` / `anthropiccompatible` endpoint also set `NEMOCLAW_ENDPOINT_URL`
(e.g. `https://openrouter.ai/api/v1`) and optionally `NEMOCLAW_PREFERRED_API`
(`openai-completions`, the default, or `chat-completions`).

## One command (recommended)

`provision.sh` chains all four steps below (install + onboard, apply egress preset, install Toolbelt
in the sandbox, recover the gateway), reading config from `.env`:
```bash
cp .env.example .env        # then fill in NEMOCLAW_PROVIDER / NEMOCLAW_MODEL / NEMOCLAW_PROVIDER_KEY
./provision.sh
# already onboarded? do only steps 2-4:
SKIP_ONBOARD=1 ./provision.sh
```
The steps below document what it does (and the manual path if you want to run them one at a time).

## Step 1: Install and onboard

**Interactive (simplest locally):**
```bash
curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash
# In the wizard: choose your provider, paste your key, pick a model.
```

**Non-interactive (scriptable):** set the three provider vars and onboard. To switch providers,
change only these values, not the variable names:
```bash
curl -fsSL https://www.nvidia.com/nemoclaw.sh | \
  NEMOCLAW_NON_INTERACTIVE=1 \
  NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1 \
  NEMOCLAW_PROVIDER=anthropic \
  NEMOCLAW_MODEL=claude-haiku-4-5 \
  NEMOCLAW_PROVIDER_KEY="$(cat ~/.provider_key)" \
  NEMOCLAW_SANDBOX_NAME=toolbelt \
  bash -s -- --non-interactive
```

Switching to, say, OpenAI is just `NEMOCLAW_PROVIDER=openai NEMOCLAW_MODEL=gpt-5.4` with the same
`NEMOCLAW_PROVIDER_KEY`. For an OpenAI-compatible endpoint, add `NEMOCLAW_PROVIDER=custom` and
`NEMOCLAW_ENDPOINT_URL=https://your-endpoint/v1`. Local providers (`ollama`, `vllm`) omit the key.

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

## Step 2: Allow Toolbelt egress (on the host)

The sandbox network policy is an allowlist. ClawHub is already permitted by the stock base policy
(so skill installs work), but the agent's **live** MCP calls to `mcp.toolbelt.ai` are blocked until
that host is allowlisted. Apply our version-controlled egress preset to the running sandbox; this
does **not** require forking NemoClaw's blueprint:
```bash
nemoclaw toolbelt policy-add --from-file ./policy/toolbelt-egress.yaml --yes
# (use --dry-run first to preview the merged policy)
```
NemoClaw merges the preset's `network_policies` entries onto the sandbox's live policy by name.
The preset is `policy/toolbelt-egress.yaml` in this repo (the source of truth) — do not hand-drop a
preset into the local NemoClaw checkout, which only works on a mutated checkout and is not
reproducible.

## Step 3: Install Toolbelt (inside the sandbox)

The agent reads `/sandbox/.openclaw/openclaw.json` inside the sandbox, so Toolbelt must be installed
**in the sandbox**, not on the host:
```bash
nemoclaw toolbelt connect          # open a shell in the sandbox named "toolbelt"
# then, inside the sandbox:
npx -y @toolbeltai/cli@latest install --client openclaw
```
This provisions a Toolbelt token (anonymous unless `TOOLBELT_TOKEN` is set), writes a nested
`mcp.servers.toolbelt` entry (`https://mcp.toolbelt.ai/mcp`) into the agent's `openclaw.json`, and
installs the consolidated `toolbelt` skill (the CLI reports `Installed 1 skills`).

On success the CLI prints `! Restart OpenClaw to pick up the new MCP server and skills.` This is
**required** — the running agent won't see the new `mcp.servers.toolbelt` entry or the skill until it
restarts. Recover the gateway from the host:
```bash
nemoclaw toolbelt recover          # restart the "toolbelt" sandbox so OpenClaw reloads config + skills
```

> **Troubleshooting — provisioning fails with `✗ fetch failed`:** that is a network-policy block
> (no HTTP status = blocked connection, not an API error), not a restart issue. The CLI provisions
> against `https://app.toolbelt.ai`; confirm Step 2's egress preset (which allowlists that host) was
> applied to this sandbox, then retry.

## Step 4: Use it

```bash
openclaw tui                       # or reconnect: nemoclaw toolbelt connect
```

## Demo: two users, one shared brain

`demo-shared-brain.sh` stands up two separate, sandboxed agents that collaborate through one shared
Toolbelt namespace, with no agent-to-agent connection. It provisions two distinct anonymous users,
has the first share its namespace (read-write) with the second, then runs `provision.sh` once per
role. Config (Nemotron/NVIDIA provider, role names) comes from `.env.demo`:
```bash
cp .env.demo .env.demo.local && $EDITOR .env.demo.local   # set NEMOCLAW_PROVIDER_KEY, confirm model
DEMO_ENV_FILE=./.env.demo.local ./demo-shared-brain.sh
# users + share only (run the two provision.sh yourself):
PROVISION_SANDBOXES=0 ./demo-shared-brain.sh
```
The shared namespace is the brain: one agent writes to the timeline / entity graph, the other reads
it. The Toolbelt user-provisioning and sharing HTTP flow is verified against source (and run live).
Running **two** sandboxes on one host is supported per NVIDIA's docs ("Multiple sandboxes can coexist
on the same host"; each `onboard` registers a new sandbox with its own dashboard port 18789-18799 —
there is no separate `sandbox create`):
<https://docs.nvidia.com/nemoclaw/latest/user-guide/openclaw/manage-sandboxes/lifecycle>. Still
unexercised end to end: the runtime coordination (both agents pointed at the shared namespace) and
that the chosen Nemotron model supports tool-calling — without it the MCP server cannot be used.

## Caveat to handle

**Skill version drift.** Older `@toolbeltai/cli` (0.1.6) pinned `@toolbeltai/skills` at `^0.2.0`,
which resolves to `0.2.x` and installs the **old 7 skills**, not the consolidated single `toolbelt`
skill (which ships in `@toolbeltai/skills` 1.x). The CLI dependency is now `^1.0.0` on `main`;
the republish is pending the `@toolbeltai/cli` 0.1.7 release. Until that publishes, pin a known-good
version explicitly (`npx -y @toolbeltai/cli@0.1.7 ...` once released) so `toolbelt install` installs
just the `toolbelt` skill.

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
- The exact in-sandbox command to run `toolbelt install` (one-shot exec:
  `nemoclaw <name> exec --no-tty -- npx -y @toolbeltai/cli@latest install --client openclaw`).
- That `nemoclaw <name> policy-add --from-file ./policy/toolbelt-egress.yaml --yes` merges cleanly
  and the agent then reaches `mcp.toolbelt.ai` at runtime (the preset format is verified against
  upstream; the live apply + reachability is what to confirm).
- An end-to-end agent turn through Haiku that calls a Toolbelt tool.

## Background (why not the custom image)

An earlier approach built a custom two-stage image baking Toolbelt into a NemoClaw sandbox
(a `Dockerfile`, `build.sh`, and a pre-launch shim). It is **superseded**: NemoClaw publishes no
pullable runtime image, and the sandbox gateway will not run healthy outside the OpenShell substrate.
Those files have been removed; the verified findings that informed the decision are preserved in the
docs. Use this quickstart-based runbook for deploys. See
`docs/superpowers/specs/2026-06-22-toolbelt-claw-via-quickstart-design.md` and
`docs/nemoclaw-substrate-findings.md`.
