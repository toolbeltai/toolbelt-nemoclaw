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

Telling evidence: a DIRECT `nemoclaw <sb> agent --agent watch -m ...` turn works perfectly (real
`toolbelt__toolbelt_context` + `toolbelt__toolbelt_sql`, live data) — only spawn-from-main fails.

CORRECTION 2026-06-24 (this overturns the earlier "conclusive root cause" below): the EEXIST is NOT
a non-idempotent workspace mkdir on either side. Verified from source:
  - NemoClaw `provision_agent_workspaces` (`scripts/nemoclaw-start.sh:4124`) uses `mkdir -p` —
    idempotent, cannot throw EEXIST even when the dir pre-exists.
  - EVERY workspace mkdir in the OpenClaw image (`/usr/local/lib/node_modules/openclaw/dist`) uses
    `{ recursive: true }`: the spawn path `ensureAgentWorkspace` (`workspace-BxBAoMrZ.js:377`), the
    agent-files writers (`agents-BzpFMOeR.js:260,603`), and per-agent `agentDir` (`models-config:979`).
    None can throw EEXIST.
So `main`'s report ("watch/exposure/comms failed with EEXIST creating their workspace directories")
cannot be literally true — it was Nemotron PARAPHRASING a spawn failure we never actually captured.
The real error string is unknown. The earlier isolation conclusion (NemoClaw pre-provisions the dir,
OpenClaw re-creates it non-idempotently) was wrong: both mkdirs are idempotent.

WHAT'S ACTUALLY NEEDED NEXT: capture the REAL openclaw error/stack from a spawn turn (not the model's
summary) before filing anything upstream. A bug report about "non-idempotent mkdir" would be incorrect.

LIVE REPRO 2026-06-24 (fresh onboard, then a DIRECT `nemoclaw <sb> agent --agent watch -m ...` turn):
the watch agent runtime initialized CLEANLY (NemoClaw plugin registered, NVIDIA endpoint wired, tool
policy applied) with NO EEXIST and NO error in `gateway-persistent.log` (only a benign mDNS guard
warning). But the turn then produced 0 bytes of output for ~40 min while the gateway stayed fully
responsive to `exec` (instant). I.e. the agent turn HUNG — it never streamed a result — even though
the gateway was alive and healthy. Killed it manually. So:
  - The "EEXIST / workspace-dir" story is fully debunked (source + live: no such error occurs).
  - The REAL reproducible blocker is a TURN HANG: the `--agent <id>` turn never completes/streams on
    the build->nemotron path, with the gateway otherwise healthy. This is intermittent: earlier in
    this work a watch turn DID complete end-to-end (16 tool calls, live NWS data). So the single-agent
    slice WORKS but is FLAKY — turns sometimes hang with a live gateway.
THIS is what to file upstream (NemoClaw/OpenClaw): "agent turn hangs with no output and no error while
the gateway stays responsive," with evidence: clean init logs, no error, gateway answers exec instantly,
turn never returns. NOT a mkdir bug.

## ROOT CAUSE FOUND 2026-06-25: it IS NemoClaw #5237 (sessions_spawn dial-back), in TWO layers

The spawn failure is the loopback gateway dial-back bug from NemoClaw issue #5237 / PR #5238.
PR #5238 merged into v0.0.65, so our 0.0.67 HAS it — but it does NOT engage here, and even forcing
it past layer 1 reveals an incomplete layer 2. Full chain, all evidence-backed:

LAYER 1 — network (sessions_spawn child can't reach the gateway):
  - PR #5238 moves OPENCLAW_GATEWAY_URL off loopback to the sandbox eth0 (e.g. 10.200.0.2) because the
    OpenShell L7 proxy hard-blocks loopback dial-backs from the enforced process tree (-> WS 1006).
  - It derives the host via `hostname -I` (nemoclaw-start.sh:352). In OUR sandbox `hostname -I` returns
    EMPTY (confirmed on a fresh create), so it falls back to loopback (line 354-355) = the broken state.
  - Its only escape hatch, NEMOCLAW_GATEWAY_WS_HOST, is NOT forwarded into the sandbox by onboard
    (sandbox-create-launch.js forwards NEMOCLAW_PROXY_HOST but not the gateway WS host). So the
    documented override is unreachable from the host. <- gap #1 in PR #5238.
  - OUR FIX (committed): scripts/patch-forward-gateway-ws-host.sh forwards NEMOCLAW_GATEWAY_WS_HOST;
    .env sets it to 10.200.0.2 + pins NEMOCLAW_DASHBOARD_PORT=18888; policy.yaml allowlists the
    dial-back to 10.200.0.2:18888 (base policy only covers 18789/18790 <- gap #1b for custom ports).
  - RESULT: VERIFIED FIXED. GW_URL flipped ws://127.0.0.1:18794 -> ws://10.200.0.2:18888, and the
    gateway log now shows the child CONNECTING from 10.200.0.2 (no more 1006).

LAYER 2 — auth (child reaches the gateway but is rejected):
  - The child now connects from 10.200.0.2 and is rejected with WS 1008
    "pairing required: device is not approved yet" (gateway-persistent.log, peer=10.200.0.2->10.200.0.2:18888).
  - The gateway's zero-config auth/pairing BYPASS is loopback-ONLY: server.impl:527 bypasses when
    isLocalDirectRequest() is true, and isLocalDirectRequest (auth-CbKYHGo4.js:113) IGNORES
    trustedProxies and returns true only for a LOOPBACK socket peer. So a 10.200.0.2 child gets no
    bypass. <- the architectural tension: the L7 proxy blocks loopback dial-back, but the gateway only
    auto-trusts loopback. PR #5238 reconciled the network path but NOT the auth path. <- gap #2.
  - OPENCLAW_GATEWAY_TOKEN IS present in the sandbox env, but the spawn dial-back still hits 1008
    (token not used on that connection, or device-pairing is required independently), and the auto-pair
    watcher did not approve the eth0 device (no [auto-pair] approval line; two 1008s logged).

NET: #5237's fix is incomplete for sandboxes where (a) hostname -I yields nothing, (b) a custom dashboard
port is used, and (c) — even past those — the eth0 dial-back isn't covered by the loopback-only auth
bypass. Our patch closes (a)+(b) and proves the child reaches the gateway; (c) remains and needs either
an OpenClaw change (treat the sandbox's own eth0 as local in isLocalDirectRequest) or the spawn client to
present OPENCLAW_GATEWAY_TOKEN on the dial-back. This is the precise, high-value upstream report.

What this means for a demo TODAY: the "Toolbelt on sandboxed Nemotron over real data" story works
via direct specialist invocation; the "secure AND multi-agent collaboration via shared brain" story
is blocked on the spawn EEXIST.

## Option-1 fix attempt 2026-06-24 (now known to have chased a non-cause)

We tried to stop the workspace dir from pre-existing: (a) patched the host `fillAgentDefaults` to omit
per-agent `workspace`/`agentDir`, (b) skipped specialist persona prefill. The BUILD validator
(`generate-openclaw-config.mts`) rejects an omitted `workspace`
(`NEMOCLAW_EXTRA_AGENTS_JSON.agents[0].workspace must be a non-empty string`), so the attempt failed
to build. (Reverted; `agents-manifest.js` is back to stock.) In light of the CORRECTION above this was
chasing a non-cause anyway: pre-existing dirs don't matter because every workspace mkdir is `mkdir -p`
/ `{recursive:true}` on both sides. So "keep the dir from pre-existing" was never going to be the fix.

`scripts/run-brief.sh` is the correct SIBLING orchestration (invoke watch/exposure/comms as direct
sequential turns coordinating via the shared timeline, no main->spawn) and is the way to drive the demo
regardless. The summary says it also hit "the same EEXIST" — but that too was the model's paraphrase,
not a captured error; needs re-verification with the real error in hand.

CONCLUSION (revised): the multi-agent collaboration does not complete, but the root cause is NOT a
non-idempotent mkdir (source proves both sides use idempotent creates). The actual failure was never
captured — `main` only paraphrased it as "EEXIST." Before filing upstream, reproduce a spawn turn on a
fresh gateway and capture the real openclaw error/stack. The single-agent path (direct specialist turn,
real Toolbelt MCP calls on live data) works and is the demoable slice today.

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
