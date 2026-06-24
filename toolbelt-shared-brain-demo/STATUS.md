# Status — Toolbelt shared-brain demo (NemoClaw)

Snapshot of where this stands, so it can be resumed without re-deriving everything.
Pulled in from a standalone download after a debugging/validation pass on 2026-06-24.

## What this is

A multi-agent NemoClaw/OpenClaw demo: a `main` coordinator spawns specialists
(`watch` / `exposure` / `comms`) that collaborate through a shared Toolbelt namespace
(SQL + timeline + KG over real GPU-scale data), fully inside the OpenShell egress sandbox.
Inference is Nemotron via build.nvidia.com (no GPU). `scripts/setup.sh` stands it up;
`nemoclaw-k8s/` and `run-anywhere/` are the deployment variants.

## Verified working (end-to-end, on NemoClaw 0.0.67)

- `scripts/setup.sh` runs clean: token -> create namespace + adopt datasets (REST) ->
  `onboard --agents agents.yaml` (topology baked) -> egress policy -> `toolbelt install`
  (MCP server + skill) -> pin MCP URL to the namespace -> upload personas -> recover.
- Datasets are real and queryable in the namespace: `public.census_blocks_2024` (8.2M),
  `weather.nws_alerts` (~950K), `insurance_demo.building_footprints`. All three are curated
  Toolbelt public assets, adopted by reference (no data movement).
- 120b Nemotron (`nvidia/nemotron-3-super-120b-a12b`) runs without crashes.
- MCP server connects + handshakes to the pinned `/ns/<id>/mcp`; the allowed `toolbelt__*`
  tools are correctly surfaced to the specialist agents.
- Deny-by-default egress is enforced live (it blocks `curl wttr.in`): the security story.
- Multi-agent spawn binding works: `subagents.requireAgentId: true` makes `main` spawn the
  specialists as bound agents (they get their own sessions + toolbelt allowlists).

## The one open blocker (model capability)

The specialist model does NOT invoke the MCP tools that are available to it. It runs the
tool name as a shell command (`exec toolbelt_context`) and then hunts (`openclaw mcp list`,
`find ... toolbelt`), producing no query. Confirmed it is NOT config/surfacing/prompt:
the tools are present (policy log keeps the 4 allowed `toolbelt__*` for `watch`), the MCP
server is connected, and an explicit "call as MCP tools, never exec" persona did not change
the behavior. It is a model tool-invocation issue with `nemotron-3-super-120b-a12b` in the
full multi-tool harness.

## Scoped levers to close the last mile (not prompt tuning)

1. A model that reliably drives MCP tool calls in this harness. Check the gateway inference
   API format (`NEMOCLAW_PREFERRED_API`; the healthcare reference demo forces chat-completions
   so tool-call JSON parses) and test models end-to-end in the harness, not just a bare probe.
2. The `toolbelt` skill content (the @toolbeltai/skills `toolbelt` skill): (a) its setup
   detection prompts to onboard whenever the loading agent lacks the MCP tools even though the
   server is configured (hits multi-agent/pre-provisioned setups), and (b) how it teaches tool
   invocation. Fixing it helps every Toolbelt-on-an-agent deployment.
3. Bake-remove the stock `weather` skill at the image level (it ships in the base image, can't
   be removed at runtime, and competes by offering a `curl wttr.in` recipe).

## What was changed vs the original download

- `scripts/setup.sh`: rewritten against verified mechanics (original kept as `setup.orig.sh`).
  The original assumed `@toolbeltai/cli namespace create` / `public-assets adopt` (those CLI
  commands do not exist; we use the REST API), and applied the topology via `config set
  --from-file` (key/value only; we use `onboard --agents`). Also: scheme on `TOOLBELT_HOST`,
  egress applied before install, `app.toolbelt.ai` added to policy, MCP URL pinned to the
  namespace, `tools.toolSearch` disabled, personas uploaded to the paths each agent reads.
- `agents.yaml`: conformed to the documented manifest schema (top-level `defaults`/`main`/
  `agents`; `tools: {profile, allow, deny}`; `maxSpawnDepth` only under `defaults`; no
  `maxConcurrent`/`timeoutSeconds`/`skills`; `main` is the reserved primary; tool perms are
  `toolbelt__*` not `mcp__toolbelt__*`; `requireAgentId: true`).
- `policy.yaml`: added `app.toolbelt.ai` (CLI provisioning host).
- `workspaces/main.md`: told it Toolbelt is already configured, never onboard, delegate by id.
- `.env`: NOT included (held the NVIDIA key + token). Use `.env.example`.

## To run

    cp .env.example .env    # set NEMOCLAW_PROVIDER_KEY (build.nvidia.com); model defaults to a verified one
    ./scripts/setup.sh
    nemoclaw toolbelt-shared-brain connect   # then: openclaw tui
