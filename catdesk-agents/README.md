# Cat-desk agents

Real NemoClaw agents for the cat-desk demo, running Nemotron in a deny-by-default OpenShell sandbox. Their only outbound paths are the Toolbelt brain and NVIDIA's inference endpoint. They never talk to each other: they coordinate through one Toolbelt namespace (Insurance Peril Exposure (Cat Desk), owned by the `demo` account), which the trigger service (`../catdesk-trigger`) fills with the fleet's findings.

| Beat | Script | Agent | Toolbelt capability it shows |
| --- | --- | --- | --- |
| On camera, mid-take | `scripts/run-coverage.sh` | coverage | Reading another agent's findings from the shared brain and recording a correction to the timeline |
| Morning | `scripts/run-morning.sh` | synthesis | SQL for amounts plus a graph walk for who is connected, then a decision on the timeline and a brief saved as a document the View shows |
| Governance | `scripts/run-correction.sh "<rule>"` | governance | A human correction becomes a proposed lesson; once the owner approves it, the next morning run follows it. This agent's only tool is `toolbelt_lesson_propose` |

## A new box

The demo runs from this repo alone. You need:

- Docker, running
- NemoClaw, installed through NVIDIA's quickstart (a version whose `nemoclaw onboard --help` lists `--agents`)
- Bun, Python 3 and curl
- An NVIDIA `nvapi-` key, for Nemotron on build.nvidia.com
- The `demo` account's Toolbelt API token (`tb_...`). That account owns the namespace (Insurance Peril Exposure (Cat Desk), `664f9ed5-a82e-4908-92bb-d5d209f5fb1c`), so the same token covers the agents, the trigger's writes and lesson approval.

```bash
cp catdesk-agents/.env.example catdesk-agents/.env   # set NEMOCLAW_PROVIDER_KEY and TOOLBELT_TOKEN
./catdesk-demo.sh                                     # from the repo root
```

If a port is taken on the box (onboarding stops with "Port 8080 is not available"), set `NEMOCLAW_GATEWAY_PORT` in `.env` to a free port, and likewise `NEMOCLAW_DASHBOARD_PORT` (default 18789) or `TRIGGER_URL` (default `http://localhost:8787`). Keep them in `.env`: every `nemoclaw` command reads the gateway port, not just onboarding.

If your home directory is on NFS, Docker cannot bind-mount from it, and sandbox creation fails with "error while creating mount source path '.../.local/bin/openshell-sandbox': ... permission denied". Copy that binary to local disk and point NemoClaw at it in `.env`:

```bash
mkdir -p /var/tmp/$USER/openshell && cp ~/.local/bin/openshell-sandbox /var/tmp/$USER/openshell/
echo "NEMOCLAW_OPENSHELL_SANDBOX_BIN=/var/tmp/$USER/openshell/openshell-sandbox" >> catdesk-agents/.env
```

If the box shares its home directory with machines of another architecture, the Bun in `~/.bun` may not run ("cannot execute binary file: Exec format error"). Install one for this machine outside your home and point the script at it:

```bash
curl -fsSL https://bun.sh/install | BUN_INSTALL=/var/tmp/$USER/bun bash
echo "BUN=/var/tmp/$USER/bun/bin/bun" >> catdesk-agents/.env
```

Rerun `./catdesk-demo.sh` after a failed setup rather than `nemoclaw onboard --resume` by hand: the script loads `.env`, so the port and binary overrides apply, and it onboards with `--no-gpu` as the demo expects.

The first run builds the `toolbelt-catdesk` sandbox with `scripts/setup.sh` (onboard, egress policy, Toolbelt install, personas), which takes about 10 minutes. Every run after that goes straight to the take.

### A second user on the same box

Each user gets their own NemoClaw install, gateway and sandbox, but they share one Docker daemon and one namespace. On top of the steps above:

- Use ports that differ from the other user's in `.env`: `NEMOCLAW_GATEWAY_PORT`, `NEMOCLAW_DASHBOARD_PORT`, and `TRIGGER_URL` (each user's take starts the trigger on that port).
- Give the sandbox its own name: `NEMOCLAW_SANDBOX_NAME=toolbelt-catdesk-<you>`.
- Only one take at a time: both write to the same namespace, and each take's reset clears the findings and lessons the other is using.

## A take

`../catdesk-demo.sh` does what Reset and Play do on the trigger page, then runs every agent beat in order (see `../catdesk-director/README.md`). It starts the trigger service for the take if it isn't already running. Open the View to watch it fill in.

```bash
./catdesk-demo.sh                    # full take; the lesson is approved through the API
./catdesk-demo.sh --approve wait     # pause until a person approves the lesson in Atlas
./catdesk-demo.sh --restart          # stop the fleet halfway and resume it
./catdesk-demo.sh --reset-only       # just clear the brain for the next take
```

The beats can also run one at a time: `scripts/run-coverage.sh` about ten seconds after Play, `scripts/run-morning.sh` after the fleet finishes, and `scripts/run-correction.sh "<rule>"` for the lesson.

Run one agent at a time, and never while another heavy job hits the namespace. Overlapping runs have exhausted the backing Kinetica worker's request slots before (see the shared-brain STATUS).

## Model

`nvidia/nemotron-3-super-120b-a12b`, re-verified on 2026-10-06 through the Chat Completions API: clean tool calls, and its reasoning arrives in a separate field instead of leaking into answers. The agents also run with `--thinking off`. The shared-brain demo's old default, `meta/llama-3.3-70b-instruct`, was retired by NVIDIA on 2026-08-26.

## Rules the prompts encode

These were learned building the namespace, and each one fails silently or with a guard error if broken:

- Query the pre-joined views. Toolbelt allows at most 4 joins per SQL query.
- Every SQL query needs a `WHERE`, `GROUP BY`, `LIMIT` or aggregate, or Toolbelt's guard blocks it.
- Cypher on `cat_graph`: one linear path, address nodes with `.NODE`, put `/* KI_HINT_MERGE_GRAPH_INPUTS */` after the graph name, and never aggregate in `RETURN`.
- Use the graph for who is connected and SQL for how much. Toolbelt blocks `GRAPH_TABLE()` aggregation.
