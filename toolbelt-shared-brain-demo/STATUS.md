# Status — Toolbelt shared-brain demo (NemoClaw)

Snapshot of where this stands, so it can be resumed without re-deriving everything.
Pulled in from a standalone download after a debugging/validation pass on 2026-06-24.

## What this is

A multi-agent NemoClaw/OpenClaw demo: a `main` coordinator spawns specialists
(`watch` / `exposure` / `comms`) that collaborate through a shared Toolbelt namespace
(SQL + timeline + KG over real GPU-scale data), fully inside the OpenShell egress sandbox.
Inference is Nemotron via build.nvidia.com (no GPU). `scripts/setup.sh` stands it up;
`nemoclaw-k8s/` and `run-anywhere/` are the deployment variants.

## OPEN: watch never records + watch turns hang (2026-07-02, on llama)

Two remaining reliability problems found while verifying clean-namespace runs:

1. **`watch` records zero alerts (deterministic).** Verified on a clean namespace (10a81ef4) with a
   real verified-tier token: `watch`'s `toolbelt_sql` call fails 2/2 runs (`calls=1 failures=1`, no
   `{"success":...}` result stored -> it errors at the tool/MCP layer, not a SQL result). Because comms
   counts `alert` events on the timeline, the brief always reports "0 active severe warnings" EVEN
   THOUGH the data has active ones: `exposure`'s query (`... WHERE a.expires > NOW() AND a.severity =
   'Severe' ...`) returns 5 (Paducah KY 271k pop, Twin Cities MN ~$24B insured, La Crosse WI, ...). So
   "0 active" is a WATCH BUG, not a dataset property (correcting the earlier "static snapshot" guess).
   - TRUE ROOT CAUSE (proven, supersedes the multi-line theory): a KINETICA WORKER REQUEST-LIMIT
     EXHAUSTION on the namespace's backing instance. watch's `toolbelt_record` fails with:
       `ResourceExhausted: Worker local total request limit reached (17/16)`
     i.e. all 16 worker request slots are occupied and the new request (17th) is rejected. Confirmed
     PERSISTENT and SERVER-SIDE: reproduces with ZERO client-side overlap (all local processes killed),
     so ~16 requests are stuck/leaked on the worker and not being reclaimed, almost certainly residue of
     this session's many hung/killed run-brief + agent turns. Reads squeak through (direct MCP
     toolbelt_sql returns live warnings), writes/records hit the full worker and fail.
   - So it is NOT the demo code / query / model / multi-line SQL. The query + data + pipeline are proven
     (single-line query via direct MCP returns Des Moines IA / Aberdeen SD / Bismarck ND / La Crosse WI).
     The single-line watch.md change is harmless/kept but was NOT the fix.
   - FIX (server-side / infra): reclaim or time out the stuck worker requests, restart the Kinetica
     instance behind this namespace, or raise the worker request limit (16). Once the worker has free
     slots, watch's toolbelt_record succeeds and the brief populates. AVOID overlapping/concurrent runs
     against one namespace, they saturate (and can leak) the 16-slot worker.
   - Verify the data layer anytime WITHOUT the agent: MCP handshake then tools/call. Recipe: POST
     https://mcp.toolbelt.ai/mcp initialize (grab Mcp-Session-Id header) -> POST
     notifications/initialized -> POST tools/call {name:toolbelt_sql|toolbelt_timeline, arguments:{...}}.
2. **Agent turns hang indefinitely.** Single `watch` turns (and `run-brief.sh`, which starts with
   watch) hang for 20+ min with no output and no error on this host/free-tier; background runs then get
   killed (exit 144). Intermittent: some runs completed earlier, some hang forever. This blocks reliable
   end-to-end verification here. NOT a code bug in the demo, it's runtime/free-tier reliability. Retry,
   or use a paced/less-loaded inference endpoint.
3. `exposure` records only 1 event per run (1 sql + 1 record), not one per warning. Design question:
   decide whether exposure should record per-warning so comms can rank multiple.

Net: the demo's plumbing is verified (provisioning, egress, spawn, namespace correctness), but a
reliable content-rich brief is not reproducible here due to the watch-query bug (fix pending
confirmation) + turn-hang flakiness.

## RESOLVED: model = meta/llama-3.3-70b-instruct (non-reasoning); full brief captured (2026-07-02)

The demo default is now **`meta/llama-3.3-70b-instruct`** on build.nvidia.com (set in `.env.example`,
`.env`, and `setup.sh`; the live gateway was switched with `nemoclaw inference set --provider
nvidia-prod --model meta/llama-3.3-70b-instruct` — no rebuild). It's served from NVIDIA's endpoint so
this stays a NemoClaw/NVIDIA demo, but it is NON-REASONING, which the workload requires.

Why we moved off Nemotron (all evidence-backed this session):
- Nemotron 3 **reasoning** models leak chain-of-thought as the answer on the free build tier.
  `super-120b` degenerated into token salad on the comms synthesis turn; `nano-omni-...-reasoning`
  either dumped reasoning-only output or fell into repetition loops.
- `--thinking off` (OpenClaw CLI flag; accepts off|minimal|low|medium|high) FIXES the tool-calling
  turns (watch, exposure) on the nano — they run clean. But it does NOT fix the free-form synthesis
  turn (comms), which degenerates regardless of --thinking off, bounded timeline read (limit:25),
  a tool-driven/no-enumerate persona, or a bigger maxTokens (8192). Exhausted those levers.
- NemoClaw's `reasoning:false` / `NEMOCLAW_REASONING=false` does NOT force `thinking:false` at
  inference time for the managed NVIDIA provider (that only appears in the onboard probe). And the
  nvapi key is gateway-locked (not in the sandbox), so per-agent NVIDIA model mixing isn't possible
  from inside the sandbox. Hence: one non-reasoning model for the whole pipeline is the clean answer.

VERIFIED on llama-3.3-70b-instruct: watch -> exposure -> comms all run clean, 0 tool failures, no
degeneration. comms calls `toolbelt_save` and persists a correctly-formatted 3-section brief. Captured
example (saved as "Severe-Weather Brief 2026-07-02T14:34Z"):
  Headline — highest-exposure warning: Flood Warning — NWS Chicago IL: ~3.6M residents.
  Exposure — Flood Warning — NWS Chicago IL: ~3.6M residents, ~488K buildings, 18.6K policyholders,
             ~$302B insured.
  Recommended action — prioritize the highest-exposure warning for public alerting and claims staging.
NOTE: comms emits the brief into the toolbelt_save CALL, not the visible reply (finalAssistantVisibleText
is empty) — retrieve the saved document for the text. Also, the "0 active warnings" count in test runs
is a data-freshness artifact of the heavily-polluted test namespace + bounded read; a clean namespace
gives an accurate count.

Kept from the nano investigation: `--thinking off` is baked into `run-brief.sh` (harmless no-op for
the non-reasoning llama; helps if anyone swaps in a reasoning model), and the comms persona now bounds
its timeline read (`limit`: 25) and forbids row enumeration.

## LATEST: re-verified end-to-end on NemoClaw 0.0.70 + moved to Nemotron default (2026-07-01)

Ran the full flow on **NemoClaw 0.0.70** (host CLI upgraded from 0.0.55), macOS Apple M4 Pro,
Nemotron via build.nvidia.com. Result: **the single-agent slice works and tool-calling is clean.**

- **Provider flip (done).** `.env.example` now defaults to `NEMOCLAW_PROVIDER=build` +
  `NEMOCLAW_MODEL=nvidia/nemotron-3-super-120b-a12b` (this is a NemoClaw demo, so it runs on NVIDIA
  by default). Anthropic Haiku is demoted to a documented fallback block. README / DEPLOY.md /
  policy.yaml comments reconciled to match. `setup.sh` defaults + exports `NEMOCLAW_PROVIDER=build`
  so the #976 patch fires on the default path.
- **Version pin removed.** `setup.sh` no longer requires ">= 0.0.67"; it feature-detects
  `onboard --agents` and fails fast with an actionable message if the CLI is too old (the local
  0.0.55 correctly tripped this before the upgrade). A source diff (agent-run) of NemoClaw
  0.0.67 -> 0.0.71 confirmed every CLI verb/flag `setup.sh` uses is intact; nothing breaks.
  (Note: npm `nemoclaw@0.1.0` is an unrelated squat package, NOT NVIDIA's CLI. The real CLI is
  git-tag versioned in the 0.0.7x range; GitHub publishes no Releases.)
- **`watch` verification turn (PASS).** `nemoclaw toolbelt-shared-brain agent --agent watch --json`:
  `toolSummary { calls: 8, tools: [toolbelt__toolbelt_sql, toolbelt__toolbelt_record], failures: 0 }`,
  model `nvidia/nemotron-3-super-120b-a12b`, `stopReason: stop`, `fallbackUsed: false`, 63.4s (no
  hang), result "Recorded 8 severe warnings with mapped areas." So Nemotron issued STRUCTURED MCP
  tool calls (not the #976 raw-text-then-exec-bare-toolname failure) and wrote to the shared brain.
- **Egress hardening (NEW FIX).** `onboard` non-interactively applies its "balanced" policy tier,
  which WIDENED egress with npm/pypi/huggingface/brew/weather/openclaw-pricing — opening
  api.weather.gov, open-meteo, github, openrouter, npm/pypi/hf. That silently broke the demo's core
  "deny-by-default, only the Toolbelt brain is reachable" claim (our `policy-add` only ADDS, it can't
  replace). `setup.sh` step 5 now removes those presets after the skill install (which itself needs
  the npm registry). Verified live after removal: `curl api.weather.gov` and `curl example.com` from
  inside the sandbox both return `CONNECT tunnel failed, response 403` (blocked); `curl
  mcp.toolbelt.ai` returns 401 (reachable — auth, not a policy block). Only the toolbelt-shared-brain
  hosts (mcp/app.toolbelt.ai, build/integrate.api.nvidia.com, api.anthropic.com) remain allowlisted.
- **Patch-necessity is UNSETTLED — do NOT retire the patch scripts on static evidence.** This run
  both applied `patch-build-tool-calls.sh` AND onboard reported "Chat Completions API available", so
  it can't isolate whether the #976 patch is still load-bearing on 0.0.70 or whether the native
  nvidia-prod responses-probe skip now carries it. A source diff suggested both patches may be
  redundant on 0.0.67+, but that CONTRADICTS this repo's own empirical 0.0.67 log (where the patch was
  what made tool calls parse). Settle it with ONE run that skips the patch before removing anything.
  The anchors still match byte-for-byte; keeping the patches is harmless (idempotent no-ops if truly
  redundant).
- **Namespace note.** The token has multiple namespaces; setup seeded `a35d02fb-...` (resolved as
  "Default Workspace"/oldest), not `soccer-match-predictor`. Datasets adopted there.

- **Setup idempotency fix.** The skill install (`npx @toolbeltai/cli`) needs the npm registry. On a
  re-run against an already-hardened sandbox, onboard reuses it and does NOT re-add the balanced-tier
  `npm` preset, so the install 403s. `setup.sh` step 5 now explicitly `policy-add npm` before the
  install (the hardening step removes it again after), so setup is idempotent for fresh AND re-run.
- **Multi-agent spawn flow (PASS — EEXIST truly fixed).** `nemoclaw ... agent --agent main -m "Give
  me the current severe-weather situation brief"` ran clean (114s, no fallback, 0 tool failures, NO
  EEXIST). `main` issued `sessions_spawn` + `sessions_yield`; all three specialists spawned and ran
  (live session files under `/sandbox/.openclaw/agents/{watch,exposure,comms}/sessions/`) and
  collaborated through the shared timeline with the intended division of labor: `exposure` read the
  timeline + ran geo SQL + recorded (3 sql / 3 record / 3 timeline), `comms` read the timeline (3
  timeline) to draft, `main` read the timeline 18+ times to synthesize. The "secure AND multi-agent
  via shared brain" story now works end-to-end on 0.0.70.
  - CAVEAT: a one-shot `agent --agent main` invocation returns `end_turn` with no final brief TEXT —
    main spawns, yields to the children, and the CLI turn returns before main resumes to emit the
    synthesized brief. The timeline shows main WAS synthesizing; the final brief surfaces in the TUI
    or via `run-brief.sh`, not in a scripted one-shot. Harness/UX detail, not a collaboration failure.

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
bypass. Our patch closes (a)+(b) and proves the child reaches the gateway; (c) remains. This is the
precise, high-value upstream report.

## LAYER 2 fully diagnosed 2026-06-25: token auth CANNOT fix it; the auto-pair watcher is deadlocked

Pursued the "make the child authenticate with the token instead of bypassing pairing" path (option 2).
Conclusively DEAD END, with these tested facts:
  - OPENCLAW_GATEWAY_TOKEN in the sandbox MATCHES gateway.auth.token (sha256 prefix equal). The child
    HAS the right credential.
  - Presenting that exact token via `openclaw ... --token <tok>` STILL fails with WS 1008
    "pairing required: device is not approved yet" — over BOTH ws://10.200.0.2:18888 AND
    ws://127.0.0.1:18888. So token auth does NOT bypass device pairing.
  - Why loopback didn't help either: in this OpenShell sandbox, in-sandbox clients reach the gateway
    THROUGH the bridge, so the gateway never sees a true-loopback socket peer. isLocalDirectRequest
    (auth-CbKYHGo4.js) only returns true for a loopback peer, so its bypass can NEVER fire for an
    in-sandbox client. => device pairing is MANDATORY for every in-sandbox gateway client here.
  - The mechanism that is SUPPOSED to make this work — the auto-pair watcher (nemoclaw-start.sh
    start_auto_pair, logs to /tmp/auto-pair.log) — is started unconditionally but approves NOTHING:
    /tmp/auto-pair.log is empty and no [auto-pair] approved lines exist, despite many pending child
    pairing requests (8231e39f, fd2ef670, 48d7bf0a, ...). Strong inference: the watcher itself now
    dials OPENCLAW_GATEWAY_URL=eth0 to run `openclaw devices approve`, which ALSO requires pairing/creds
    -> it can't authenticate to issue approvals -> the whole pairing flow is deadlocked. I.e. pointing
    OPENCLAW_GATEWAY_URL at eth0 for EVERY in-sandbox client (to fix 1006) broke the watcher's own
    approval path. (Also note onboard sets NEMOCLAW_DISABLE_DEVICE_AUTH=1 for instant dashboard access,
    but that disable is controlUi/loopback-scoped and does NOT cover the non-loopback WS dial-back.)

CONCLUSION (final): the spawn failure IS NemoClaw #5237, and PR #5238's fix is incomplete in a deep,
architectural way for sandboxes where loopback-to-gateway is proxy-blocked:
  - Layer 1 (network): children must dial eth0 (we fixed delivery of that). VERIFIED working.
  - Layer 2 (auth): an eth0 (non-loopback) in-sandbox client gets NO loopback bypass, token auth does
    NOT bypass mandatory device pairing, and the auto-pair watcher can't approve over the same
    non-loopback URL -> no working auth path for spawned/in-sandbox children.
Neither of our non-invasive levers closes layer 2: token auth is insufficient (tested), and the only
remaining local fixes are (i) patch isLocalDirectRequest to treat the sandbox's own eth0 as local
(an auth-weakening change; correctly blocked by the agent's security guard pending explicit operator
approval), or (ii) an upstream NemoClaw/OpenClaw fix. RECOMMEND: file the upstream report. The proper
upstream fix is for NemoClaw to give the auto-pair watcher (and/or spawned children) a privileged
approval/auth path that does not depend on a pairing-gated non-loopback connection — e.g. a unix-socket
or loopback-from-gateway-context approval channel, or have token auth satisfy the gateway for the
sandbox's own bridge address.

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

## ACTUAL ROOT CAUSE 2026-06-25 (SUPERSEDES the #5237 analysis above)

The EEXIST was REAL all along and the root cause is OURS, not upstream. On a clean stock onboard,
EVERY secondary-agent turn (spawn AND host-driven sibling) fails fast with:
  `EEXIST: file already exists, mkdir '/sandbox/.openclaw/workspace-<id>'`
Filesystem check showed why: `/sandbox/.openclaw/workspace-watch|exposure|comms` existed as FILES
(914-1251 bytes = the persona markdown), while `workspace` (main's) was a proper directory.

Mechanism: `setup.sh` delivered specialist personas with
  `nemoclaw upload <persona> /sandbox/.openclaw/workspace-<id>`
which wrote the persona content AS the `workspace-<id>` path (a FILE), instead of into it as
`workspace-<id>/AGENTS.md`. Then OpenClaw's `ensureAgentWorkspace` runs `mkdir(dir,{recursive:true})`
for that agent's workspace — and a recursive mkdir STILL throws EEXIST when the path already exists as
a NON-directory. So the agent's own workspace-provisioning tripped on our mis-placed file.

Why this misled the whole investigation:
  - Nemotron's original "EEXIST creating workspace dirs" report was ACCURATE, not a fabrication. The
    earlier "it's a paraphrase / mkdir is idempotent" correction was WRONG — it missed that recursive
    mkdir throws on a non-directory.
  - The entire #5237 (1006/1008 pairing) detour was self-inflicted: changing OPENCLAW_GATEWAY_URL to
    eth0 made spawn fail EARLIER at the auth layer (1008), masking the underlying EEXIST. #5237's gaps
    are real but were never our actual blocker for the demo.

THE FIX (ours, simple): write each persona as `<workspace>/AGENTS.md` with <workspace> guaranteed to be
a directory. setup.sh step 6 now does this for ALL agents via exec (rm any stray file -> mkdir -p the
dir -> base64-write AGENTS.md inside). No `nemoclaw upload` for personas. No gateway/port/auth changes
needed. The sibling driver (run-brief.sh) then drives watch->exposure->comms as host-driven turns.

## To run

    cp .env.example .env    # set NEMOCLAW_PROVIDER_KEY (build.nvidia.com); model defaults to a verified one
    ./scripts/setup.sh
    nemoclaw toolbelt-shared-brain connect   # then: openclaw tui
