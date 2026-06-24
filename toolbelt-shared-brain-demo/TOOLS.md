# Tools

## OpenClaw built-ins (the coordinator)
- `sessions_spawn` / `subagents` / `agents_list` / `sessions_yield` — `main` delegates to the
  specialists. Leaf agents do not spawn (`maxSpawnDepth: 1`).
- `read`, `exec` — minimal; writes/browser/web/egress tools are denied by profile + `policy.yaml`.

## Toolbelt MCP tools (the shared brain) — provided by the `toolbelt` skill
| Tool | Used by | Purpose |
|---|---|---|
| `toolbelt_context` | watch, exposure | namespace schema + capabilities (call once to learn tables) |
| `toolbelt_sql` | watch, exposure | read-only SQL incl. geospatial (`STXY_CONTAINS`/`ST_INTERSECTS`) + JOINs at scale |
| `toolbelt_timeline` | all | read the shared brain — what other agents recorded |
| `toolbelt_record` | watch, exposure, comms | write a finding to the shared brain (set `occurred_at`; tag `extra.source`) |
| `toolbelt_entity` | comms | fused entity profile (record + relationships + recent timeline) |
| `toolbelt_save` | comms | save the briefing as a document |

Coordination is entirely through `toolbelt_timeline` + `toolbelt_record` — agents never call each
other. The shared namespace is the only channel, and `policy.yaml` allows exactly one external host for
it (`mcp.toolbelt.ai`), plus the Nemotron endpoint.

> Verify the exact MCP-tool permission names (the `mcp__toolbelt__*` entries in `openclaw.json`)
> against what `toolbelt install --client openclaw` writes and against a known-good demo
> (`healthcare-monitor-demo/openclaw.json`) before first run.
