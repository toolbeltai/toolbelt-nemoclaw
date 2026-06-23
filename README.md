# toolbelt-claw

Run a Toolbelt-aware [NemoClaw](https://github.com/NVIDIA/NemoClaw) (OpenClaw) agent: the OpenClaw
agent has the Toolbelt MCP server registered and the Toolbelt skill installed, bound to a Toolbelt
instance via a token.

## Approach

We use NVIDIA's **official quickstart** to stand up NemoClaw, then add Toolbelt through NemoClaw's
documented extension points. We do **not** ship a custom baked image (see "Background" below for
why that approach was dropped).

The install is a **hybrid**, not a single container:

- **On the host:** Node, the `nemoclaw` CLI, the OpenShell binaries, and the OpenShell gateway
  process. The CLI is the control plane.
- **In a Docker container the CLI manages:** the OpenClaw agent itself, in an `openshell/sandbox`
  container. The Toolbelt MCP entry and skill live here.

Toolbelt plugs in through three concerns:

1. **Egress** — a `toolbelt` network-policy preset allowlisting the Toolbelt MCP host
   (`mcp.toolbelt.ai`), selected at onboard via `NEMOCLAW_POLICY_PRESETS`.
2. **MCP + skill** — `toolbelt install --client openclaw`, run **inside the sandbox**, writes the
   nested `mcp.servers.toolbelt` entry into the agent's `openclaw.json` and installs the Toolbelt
   skill.
3. **Token** — `toolbelt install` provisions/uses `TOOLBELT_TOKEN` (anonymous if unset).

## Get started

- **Local dev box:** follow [`docs/local-dev-deploy.md`](docs/local-dev-deploy.md). It covers
  prereqs, the quickstart install + onboard, the in-sandbox Toolbelt install, and the two caveats
  (egress preset, skill version).
- **Design / rationale:** [`docs/superpowers/specs/2026-06-22-toolbelt-claw-via-quickstart-design.md`](docs/superpowers/specs/2026-06-22-toolbelt-claw-via-quickstart-design.md).
- **Verified NemoClaw facts:** [`docs/nemoclaw-findings.md`](docs/nemoclaw-findings.md) and
  [`docs/nemoclaw-substrate-findings.md`](docs/nemoclaw-substrate-findings.md).

Copy `.env.example` to `.env` for the env contract.

## Kubernetes (where this is headed)

The original ask is to run this on a cluster. The installer/CLI + OpenShell substrate **can** be
baked into an image over a fresh base (proven this session). What cannot be baked in is the agent
sandbox container, because the gateway builds and runs it through a Docker daemon at runtime. So
the k8s shape is:

- **Image (build time):** base + Docker CLI + Node + `nemoclaw` CLI + OpenShell substrate +
  `toolbelt` preset/blueprint.
- **Pod (runtime):** privileged / DinD-capable; an entrypoint runs `nemoclaw onboard
  --non-interactive`, the gateway builds + starts the sandbox, then `toolbelt install --client
  openclaw` runs inside it. `TOOLBELT_TOKEN` from a Secret.

This image + entrypoint is not built yet; the host-dev runbook is the validated path today.

## Background (why not a custom baked image)

An earlier approach built a custom two-stage image baking Toolbelt into a NemoClaw sandbox
(`Dockerfile`, `build.sh`, a pre-launch shim). It was removed: NemoClaw publishes no pullable
runtime sandbox image, and the sandbox gateway will not run healthy outside the OpenShell substrate
(cap-drop, Landlock, the managed proxy, the gateway-serve vs exec dispatch). Running the official
quickstart lets NemoClaw build its own substrate, which it does cleanly. The verified findings that
informed this decision are preserved in the `docs/` files above.
