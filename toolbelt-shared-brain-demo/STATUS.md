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

## The tool-invocation blocker — RESOLVED 2026-06-24 (NemoClaw issue #976)

Root cause: the NVIDIA `build` provider routed Nemotron through NVIDIA's `/v1/responses` API,
which has NO server-side tool-call parser for Nemotron. So tool calls came back as raw text,
OpenClaw never saw a structured `tool_call`, and the agent fell back to `exec`-ing the bare
tool name and hunting. This was NOT model capability, config, surfacing, or prompt — every
local provider path (vLLM/NIM/Ollama) already force-fixes it; the `build` path did not.

Fix: `scripts/patch-build-tool-calls.sh` forces `preferredInferenceApi = "openai-completions"`
(the OpenAI Chat Completions API, `/v1/chat/completions`, which DOES parse tool calls) for the
build provider in `~/.nemoclaw/source/dist/lib/onboard.js`, mirroring what NemoClaw's own local
paths do. `setup.sh` runs it before `onboard`. Re-apply after any `nemoclaw update` (edits
installed JS); the API flavor is baked at onboard time, so re-onboard after patching.

Verified end-to-end on NemoClaw 0.0.67 / OpenClaw 2026.5.27 with `nvidia/nemotron-3-super-120b-a12b`:
a single `watch` turn issued real `toolbelt__toolbelt_context` + `toolbelt__toolbelt_sql` MCP
tool calls (toolSummary: 16 calls, 0 failures) and returned grounded data (an active Severe
Fire Weather Watch from NWS Flagstaff AZ, expires 2026-06-26), fully inside the egress sandbox.

## New blocker found 2026-06-24: subagent spawn fails with EEXIST (OpenClaw-internal)

End-to-end status after the fixes below: `setup.sh` stands up the whole stack clean on a fresh
gateway, all four personas deliver, and `main` correctly DELEGATES via `sessions_spawn` (4 calls,
0 failures, no onboard-flail — the persona works). BUT the spawned specialists die immediately:
main reports "watch/exposure/comms all failed with EEXIST: file already exists when trying to
create their workspace directories", and `sessions list` shows NO watch/exposure/comms sessions
were ever created. So the full main -> specialists -> timeline -> synthesis flow does not complete.

Scope: this is OpenClaw-internal (the in-sandbox `openclaw` binary's `sessions_spawn` creates the
subagent's `workspace-<id>` dir, which is already pre-provisioned from the baked manifest /
`provision_agent_workspaces`, so the spawn-time create hits EEXIST). There is no spawn code in the
NemoClaw CLI to patch. Telling evidence: a DIRECT `nemoclaw <sb> agent --agent watch -m ...` turn
works perfectly (real `toolbelt__toolbelt_context` + `toolbelt__toolbelt_sql`, live data) — only
spawn-from-main hits EEXIST. Likely a NemoClaw/OpenClaw multi-agent provisioning bug worth filing
(akin to #976). ISOLATION RESULT (from source, 2026-06-24): `provision_agent_workspaces` in
`scripts/nemoclaw-start.sh` runs at every gateway start and `mkdir -p`s `workspace-<id>` for every
agent in the manifest. Our manifest auto-fills per-agent `workspace` (see `agents-manifest.js`
`fillAgentDefaults`), so those dirs ALWAYS pre-exist at spawn regardless of our persona upload. So
the upload is NOT the cause; it is NemoClaw pre-provisioning the dir that OpenClaw's spawn then
re-creates -> EEXIST. Fix to try next (needs a fresh, non-degraded gateway): keep the per-agent
`workspace` OUT of the baked manifest so ONLY OpenClaw's spawn creates it (requires bypassing the
host-side `fillAgentDefaults` auto-fill), and/or file the bug upstream, and/or try a newer NemoClaw.
NOTE: the in-sandbox `exec`/gateway becomes unreliable (calls hang at 0 output) after a handful of
agent turns in one session; a fresh `destroy` + onboard restores it. That flakiness, not the demo
logic, blocked live confirmation of the spawn fix.

What this means for a demo TODAY: the "Toolbelt on sandboxed Nemotron over real data" story works
via direct specialist invocation; the "secure AND multi-agent collaboration via shared brain" story
is blocked on the spawn EEXIST.

## Option-1 fix attempt EXHAUSTED 2026-06-24: no config lever exists

We tried to stop the workspace dir from pre-existing (so OpenClaw could create it on first turn):
(a) patched the host `fillAgentDefaults` to omit per-agent `workspace`/`agentDir`, and (b) skipped
specialist persona prefill. Result: the BUILD validator (`generate-openclaw-config.mts`) rejects it
with `NEMOCLAW_EXTRA_AGENTS_JSON.agents[0].workspace must be a non-empty string`. So `workspace` is
REQUIRED for secondary agents, NemoClaw always pre-creates `workspace-<id>` at boot, and OpenClaw's
non-idempotent per-turn `mkdir` always EEXITs. There is NO configuration lever on our side to avoid
this. (The patch was reverted; `agents-manifest.js` is back to stock.) Confirmed: it bites BOTH
spawn-from-main AND direct `--agent <id>` invocation once the dir exists.

`scripts/run-brief.sh` is the correct SIBLING orchestration (invoke watch/exposure/comms as direct
sequential turns coordinating via the shared timeline, no main->spawn) and is the way to drive the
demo once the upstream `mkdir` bug is fixed. It currently fails on the same EEXIST.

CONCLUSION: the full multi-agent collaboration is blocked by an upstream OpenClaw bug (non-idempotent
agent-workspace `mkdir`); it is not fixable from our config. File it upstream. The single-agent path
(direct specialist turn, real Toolbelt MCP calls on live data) works and is the demoable slice today.

## Remaining polish (non-blocking)

1. `main` persona upload: `nemoclaw upload` cannot overwrite the existing stock
   `/sandbox/.openclaw/workspace/AGENTS.md` (`mkdir: ... File exists`). Fix in setup.sh: upload
   to a `.new` temp path then `mv -f` via exec (the bare-name specialists upload fine because
   their per-agent AGENTS.md does not pre-exist). The exec-mv hits the auto-mode remote-shell-write
   gate when run by an agent; a human run or an authorized rule clears it.
2. Namespace pin: the `watch` context call resolved namespace `2ed11364…` rather than the
   seeded/pinned `1dd46652…` (still found `weather.nws_alerts` with real data). Confirm whether
   `/ns/<id>/mcp` pinning is honored or the token's default namespace is selected; pin harder if
   needed so agents always hit the seeded brain with the 3 adopted datasets.
3. The `toolbelt` skill content: its setup detection prompts to onboard whenever the loading
   agent lacks the MCP tools even though the server is configured (hits multi-agent setups). See
   `project-toolbelt-skill-setup-misdetect`. Helps every Toolbelt-on-an-agent deployment.
4. Bake-remove the stock `weather` skill at the image level (ships in the base image, competes
   by offering a `curl wttr.in` recipe).

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
