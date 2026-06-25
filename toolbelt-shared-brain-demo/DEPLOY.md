# Deploy guide — Toolbelt shared-brain demo

Stand up the multi-agent severe-weather brief on a fresh box (Linux or macOS) from a clone, and
optionally schedule it every 30 minutes.

## What this runs

Three sandboxed agents collaborating through one shared Toolbelt namespace (the "brain"), driven as
sequential host turns (no agent-to-agent spawning):

- **watch** — queries `weather.nws_alerts`, records active Severe/Extreme alerts to the timeline.
- **exposure** — reads those alerts, records a dataset-scale exposure finding.
- **comms** — reads the timeline, writes + saves a short situation brief (the artifact).

See `README.md` for the architecture and `STATUS.md` for the full build history / design decisions.

## Prerequisites (system-level, NOT in the repo)

- **NemoClaw** installed, with `nemoclaw` on PATH (`command -v nemoclaw`).
- **A container runtime** NemoClaw can drive (Docker / Docker Desktop). The sandbox base image is
  pulled from ghcr on first onboard.
- An **inference API key**:
  - Recommended: an **Anthropic** key (`sk-ant-...`) for Claude Haiku — reliable, fast tool-calling.
  - Alternative: an NVIDIA build.nvidia.com key (`nvapi-...`) — see the NVIDIA block in `.env.example`
    (less reliable here; Nemotron is a reasoning MoE that tends to loop on terse tool tasks).
- A **Toolbelt** account is optional — `setup.sh` can provision an anonymous token during install.

## First-time setup

```bash
git clone <repo-url>
cd toolbelt-shared-brain-demo

cp .env.example .env
#   edit .env: set NEMOCLAW_PROVIDER_KEY to your sk-ant-... key
#   (defaults are NEMOCLAW_PROVIDER=anthropic, NEMOCLAW_MODEL=claude-haiku-4-5, heartbeat off)

./scripts/setup.sh
#   onboards the sandbox, applies the deny-by-default egress policy, installs the Toolbelt MCP +
#   skill, resolves + seeds the namespace (adopts the 3 public datasets), pins the resolved
#   namespace_id into the agent personas, and waits for the MCP to settle.
```

Run the pipeline once to confirm:

```bash
./scripts/run-brief.sh
#   watch -> exposure -> comms. comms prints the brief and saves it to the namespace.
#   Expect each agent to report "calls=N failures=0".
```

## Schedule it (every 30 minutes)

```bash
./scripts/install-cron.sh
#   Portable: derives the repo path from its own location, installs an idempotent crontab entry:
#     */30 * * * * <repo>/scripts/cron-brief.sh >> <repo>/brief-runs/cron.log 2>&1
#   Override cadence:   BRIEF_CRON_SCHEDULE="*/15 * * * *" ./scripts/install-cron.sh
#   Remove it:          ./scripts/install-cron.sh --uninstall
```

Each tick:
- runs the pipeline against the already-onboarded sandbox (no re-onboard),
- saves a **dated artifact** to the namespace: `Severe-Weather Brief <UTC>`,
- writes a per-run transcript to `brief-runs/brief-<UTC>.log` (and appends to `brief-runs/cron.log`).

If a host blocks programmatic crontab writes (e.g. macOS without Full Disk Access for the calling
process), `install-cron.sh` writes the line to `brief-runs/crontab.proposed` and prints the manual
`crontab` command. On Linux it installs directly.

## What travels in the repo vs. what's per-machine

| In the repo (committed)                                  | Per-machine (not in the repo)                          |
| -------------------------------------------------------- | ------------------------------------------------------ |
| `scripts/*` (setup, run-brief, cron-brief, install-cron) | `.env` (your keys — gitignored)                        |
| `agents.yaml`, `policy.yaml`, `openclaw.json`            | the crontab entry (installed via `install-cron.sh`)    |
| `workspaces/*.md` (personas, namespace pinned at setup)  | `brief-runs/` (run logs — gitignored)                  |
| `.env.example` (the config template)                     | the onboarded NemoClaw sandbox (state in `~/.nemoclaw`)|

## Operations notes

- **Reboot:** the sandbox is host state. After a reboot (or `nemoclaw destroy`), re-run
  `./scripts/setup.sh`. The cron wrapper has a health gate — it skips ticks (logging a note) while
  the sandbox is down instead of erroring.
- **Keys / rotation:** keys live only in `.env`. Never commit them; `.env` is gitignored. To switch
  providers, edit `.env` and re-run `./scripts/setup.sh`.
- **Namespace:** the token may accumulate multiple namespaces across runs; `setup.sh` always resolves
  the "Default Workspace" (or oldest) and pins that id into the personas, so agents target the seeded
  brain. If you want a clean namespace, create a dedicated Toolbelt token scoped to one namespace.
- **Cost/latency:** on Haiku each run is a handful of short turns (seconds), so every-30-min is cheap.

## Troubleshooting

- `nemoclaw: command not found` in cron → adjust the PATH line at the top of `scripts/cron-brief.sh`
  to wherever `which nemoclaw` reports.
- An agent reports `failures>0` with a namespace error → re-run `./scripts/setup.sh` (it re-pins the
  current namespace_id into the personas).
- watch records 0 alerts right after onboard → the MCP plugin hadn't settled; `setup.sh` already
  waits, but if you re-onboard manually, give it ~60s before the first run.
