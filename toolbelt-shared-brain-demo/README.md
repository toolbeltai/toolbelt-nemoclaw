# Toolbelt Shared-Brain Demo

Zero-to-hero cookbook for a **multi-agent team that collaborates through a shared brain** on NemoClaw
and OpenShell. No GPU required.

A `main` coordinator delegates to specialist subagents with `sessions_spawn` (the OpenClaw multi-agent
pattern). The difference from a typical multi-agent demo: the specialists don't pass results only by
spawning — they read and write a **persistent shared brain** (a [Toolbelt](https://toolbelt.ai)
namespace: SQL tables, documents, a knowledge graph, and a timeline). One agent records a finding;
another reads it on its next turn — durable across runs, with no agent-to-agent wiring. OpenShell
enforces a deny-by-default egress policy, so the only outbound path the agents have is the one
allowlisted endpoint to the Toolbelt brain.

This runs on a standard Linux host with Docker, uses NVIDIA Nemotron via `build.nvidia.com`, and needs
no local GPU.

---

## What this demo shows

- A `main` coordinator that delegates to specialists via `sessions_spawn`.
- Three specialists — `watch`, `exposure`, `comms` — each with its own workspace and restricted tools,
  collaborating over **one shared Toolbelt namespace** instead of a synthetic data script:
  - **watch** queries active severe-weather alerts and records them to the shared timeline.
  - **exposure** reads those alerts and runs a geo join against real population, building, and
    infrastructure data (GPU-accelerated in Kinetica) to compute what's in the path.
  - **comms** reads the exposure findings, pulls the affected entities, and drafts the briefing.
- **Real, grounded data, not a synthetic CLI.** The agents query live public datasets adopted into the
  namespace — NWS active alerts, US Census blocks, US building footprints — through Toolbelt's tools
  (`toolbelt_sql`, `toolbelt_search`, `toolbelt_entity`, `toolbelt_timeline`, `toolbelt_record`).
- **A deny-by-default egress check, live.** Every outbound call is governed by OpenShell policy; the
  only allowed external host is the Toolbelt MCP endpoint. An un-allowlisted lookup returns a
  policy-controlled `403`, not a silent success.
- **A persistent shared brain.** Stop and restart the team and the prior findings are still on the
  timeline — coordination survives the process, unlike spawn-and-return.

All inference runs on Nemotron via build.nvidia.com. The datasets are public (NWS public domain;
Census; building footprints). No synthetic evidence script.

---

## Why a shared brain (vs. the usual multi-agent demo)

Most multi-agent demos coordinate by a coordinator spawning subagents that return results up the call
tree, over data faked by a local script. That works for a single run, but the coordination is
ephemeral and the data isn't real. Toolbelt gives the same `sessions_spawn` team a **real,
GPU-accelerated brain** they collaborate through:

- **Real data** — query actual SQL/geo/graph at scale, not a synthetic CLI.
- **Durable shared memory** — the timeline persists; an agent's finding is available to any other
  agent, this run or next.
- **No wiring** — agents coordinate through the namespace, not point-to-point. That's also why it
  stays inside the sandbox: one allowlisted egress endpoint, no inter-agent network paths.

---

## Architecture

```text
Linux host
  ├── NemoClaw CLI          (nemoclaw, openshell, openclaw)
  ├── OpenShell gateway     (deny-by-default egress; only mcp.toolbelt.ai allowed)
  └── Sandbox: toolbelt-shared-brain
       ├── openclaw.json                 (agents + tools + the Toolbelt MCP server)
       ├── policy.yaml                   (egress allowlist: Toolbelt MCP + build.nvidia.com)
       ├── workspace-main/               (coordinator)
       ├── workspace-watch/              (alerts)
       ├── workspace-exposure/           (geo join — the Kinetica-at-scale step)
       └── workspace-comms/              (briefing)
                         │
                         │ MCP (one allowlisted endpoint)
                         ▼
        Toolbelt namespace = THE SHARED BRAIN
        NWS alerts · Census blocks · building footprints · KG · timeline
```

Subagent flow:
```text
main
  ├── sessions_spawn → watch     → toolbelt_sql (active severe alerts) → toolbelt_record
  ├── sessions_spawn → exposure  → toolbelt_sql (alerts × population/buildings, geo) → toolbelt_record
  └── sessions_spawn → comms     → toolbelt_timeline + toolbelt_entity → drafts the briefing
  (each reads the shared timeline; no agent talks to another directly)
```

---

## Prerequisites

- A Linux host with Docker (the NemoClaw quickstart target). No GPU needed.
- NemoClaw installed via the [official quickstart](https://github.com/NVIDIA/NemoClaw).
- A `build.nvidia.com` API key for Nemotron (set in `.env`).
- A Toolbelt account token (free; anonymous onboarding also works). The setup script adopts the public
  datasets into a fresh namespace for you.

## Setup

```bash
cp .env.example .env          # set NVIDIA_API_KEY + (optional) TOOLBELT_TOKEN
./scripts/setup.sh            # onboard NemoClaw, adopt the datasets, install the Toolbelt skill, apply policy
```
`setup.sh`:
1. Onboards NemoClaw non-interactively (Nemotron provider from `.env`).
2. Creates a Toolbelt namespace and **adopts the public datasets** (NWS alerts, Census blocks,
   building footprints) — this is the shared brain.
3. Installs the Toolbelt skill **inside the sandbox** (`toolbelt install --client openclaw`) — writes
   the `mcp.servers.toolbelt` entry + the skill.
4. Applies `policy.yaml` (egress allowlist) and recovers the gateway.

## Run

```bash
nemoclaw toolbelt-shared-brain connect   # then: openclaw tui
# Ask main:  "Give me the current severe-weather situation brief."
```
Watch `main` spawn `watch` → `exposure` → `comms`, each reading/writing the shared timeline. Then prove
the policy: ask an agent to fetch a non-allowlisted host and see the `403`.

## Files

- `openclaw.json` — agents (`main` + `watch`/`exposure`/`comms`), tool permissions, the Toolbelt MCP server.
- `policy.yaml` — deny-by-default egress; allows the Toolbelt MCP endpoint + build.nvidia.com only.
- `TOOLS.md` — the tools each agent uses.
- `scripts/setup.sh` — provision + adopt datasets + install skill + apply policy.
- `workspaces/*.md` — the persona for each agent.

> The agents provide decision support for a demonstration workflow. Severe-weather data is from NWS
> (public domain); always defer to official NWS guidance for real decisions.
