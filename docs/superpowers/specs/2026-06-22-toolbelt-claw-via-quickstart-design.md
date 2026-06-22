# toolbelt-claw via the official NemoClaw quickstart — design

**Date:** 2026-06-22
**Status:** Approved direction (supersedes the baked-image design)
**Supersedes:** `2026-06-19-toolbelt-claw-wrapper-design.md` (custom two-stage image)

---

## Why this supersedes the baked-image approach

The original design built a custom image (`FROM` a NemoClaw sandbox, baking in Toolbelt MCP +
skills) and ran it directly. Implementation revealed — and live testing confirmed — that this
fights NemoClaw's design:

- There is **no pullable runtime `sandbox` image**; NemoClaw's CLI builds it locally during
  onboarding. We could build it from source (verified), but…
- The sandbox gateway will not run healthy outside NemoClaw's **OpenShell substrate** (cap-drop,
  Landlock, the managed proxy, the gateway-serve vs exec dispatch). We hit defect after defect
  trying to run our baked image bare.

Running the **official quickstart** instead lets NemoClaw stand up its own substrate, which it
does cleanly. Toolbelt then plugs in through NemoClaw's documented extension points.

## What was proven (live, this session)

Running the official installer **inside a container** (Debian + Docker CLI + the host Docker
socket mounted — the DinD model):

1. `curl … nemoclaw.sh | bash --non-interactive` installs Node, the NemoClaw CLI, and the
   **OpenShell substrate** (host prereqs only: `lsof`, `binutils`).
2. Onboarding preflight fully passes (Docker, DNS, bridge containers, runtime, port).
3. **OpenShell gateway comes up healthy** (`✓ Docker-driver gateway is healthy`; gateway log
   serves `/Health` 200). A real `openshell-…` sandbox container runs on the host.
4. Inference/provider is a first-class onboarding input (`NEMOCLAW_PROVIDER` + the
   `NEMOCLAW_INFERENCE_*` vars, which `dockerfile-patch.js` bakes into the sandbox image).

The only step not completable in the test box is a fully-running agent, because every provider
needs a real inference backend (a local model install, or a validated remote endpoint). That is
a deployment-config concern, not an approach problem.

## How Toolbelt plugs in (the integration point)

NemoClaw exposes the right extension points; Toolbelt decomposes into three concerns:

1. **Egress allowance (preset).** The sandbox network policy is an allowlist of named groups
   (`policies/presets/*.yaml`), each granting specific hosts, selected at onboard via
   `NEMOCLAW_POLICY_PRESETS`. `clawhub.ai` egress is **already permitted** in the base policy for
   skill flows. We add a **`toolbelt` preset** granting egress to the Toolbelt MCP host
   (e.g. `mcp.toolbelt.ai`), supplied through a custom blueprint via `NEMOCLAW_BLUEPRINT_PATH`.

2. **MCP server registration + skills install.** A preset only handles egress; the OpenClaw
   `mcp.servers.toolbelt` entry and the skills are installed by the **Toolbelt CLI**
   (`@toolbeltai/cli`, bin `toolbelt`) run **inside the sandbox** post-onboard:
   `toolbelt install --client openclaw` writes the MCP entry into the sandbox's
   `openclaw.json` (`mcp.servers`) and installs the ClawHub skills into the sandbox skills dir.
   (This is the same effect our baked image produced, achieved through the supported flow.)

   **VERIFIED (2026-06-22):** ran `toolbelt install --client openclaw` (v0.1.5) headless against a
   stock OpenClaw config. It provisioned anonymous credentials, wrote a nested
   `mcp.servers.toolbelt = { type:"http", url:"https://mcp.toolbelt.ai/mcp", headers:{Authorization} }`
   entry, and installed 7 skills (`toolbelt-analyze`, `-entities`, `-find`, `-geo`, `-invite`,
   `-start`, `-stream` + `assets`) into the skills dir. So the post-onboard CLI path is confirmed as
   the integration mechanism; no in-blueprint MCP declaration is needed. In the real flow it runs
   inside the sandbox (via `nemoclaw <name> connect`/exec) so it targets `/sandbox/.openclaw`.

3. **Token.** `toolbelt install` provisions/uses `TOOLBELT_TOKEN` (anonymous onboarding if
   unset; a pre-supplied token for an existing account), persisting it for reuse.

> **Open implementation items:**
> - Confirm whether the MCP entry/skills are better delivered via a custom blueprint
>   (declarative, baked at sandbox build) or post-onboard `nemoclaw <sandbox> connect` +
>   `toolbelt install`. The blueprint route is more reproducible/k8s-friendly; the connect route
>   is simpler to start. Verify the preset schema can also carry an openclaw-plugin/config so the
>   MCP entry can be declared in-blueprint rather than installed after.
> - Confirm the exact Toolbelt MCP host(s) to allowlist in the preset.

## Deliverable (reframed, much lighter)

Not a custom image we maintain. Instead:

- A **`toolbelt` blueprint overlay** (a `presets/toolbelt.yaml` plus any MCP/plugin config),
  pointed to by `NEMOCLAW_BLUEPRINT_PATH`.
- A **thin provisioning script** that runs the official quickstart non-interactively with the
  Toolbelt preset selected, then runs `toolbelt install --client openclaw` against the sandbox.
- Documentation of the required host prereqs (`lsof`, `binutils`, Docker) and the env contract
  (`NEMOCLAW_PROVIDER` + inference vars, `NEMOCLAW_POLICY_PRESETS=toolbelt`,
  `NEMOCLAW_BLUEPRINT_PATH`, `TOOLBELT_TOKEN`).

## Deployment model

- **Host/VM:** run the quickstart directly. Simplest.
- **Container:** run the quickstart inside a container that has Docker access (mounted socket or
  DinD). Proven this session.
- **Kubernetes:** a privileged/DinD-capable pod (or a node-level install) that runs the
  provisioning script; the OpenShell substrate is created by NemoClaw, not hand-built. Real
  inference endpoint via `NEMOCLAW_PROVIDER`/`NEMOCLAW_INFERENCE_BASE_URL`; `TOOLBELT_TOKEN` from
  a Secret. GPU only if the chosen model needs it (not required for liveness).

## Disposition of the baked-image work

The two-stage build (`Dockerfile`, `build.sh`, `bin/onboard-and-start.sh`, `config/`,
`test/`) is **superseded as the primary approach** but kept in-tree as reference: it is verified
to build and its inference-arg wiring and findings docs informed this design. Mark it clearly as
superseded; do not invest further in running it bare.

## Source-of-truth findings

- `docs/nemoclaw-findings.md` — NemoClaw build/config facts.
- `docs/nemoclaw-substrate-findings.md` — substrate/gateway requirements (why bare-run fails).
- This document — the quickstart-based integration.
