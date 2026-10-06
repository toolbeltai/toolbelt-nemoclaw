# catdesk-trigger

Replays the frozen hero storm (Gulf Coast, Jul 21 to 23, 2026) into the Insurance Peril Exposure namespace on a timer, so one button press compresses the overnight fleet into about 30 to 60 seconds of findings landing. It is the controllable live beat from the merged demo spec.

Exposure findings land first (ground-up loss, insured unknown). The coverage agent's findings trail a few batches behind and fill in insured loss. Every write goes through Atlas's `/api/query/execute-sql` route, so it lands in the Toolbelt namespace, and the `catdesk.findings_*` materialized views (refreshed every 2 seconds) roll it up for the View.

## Run

```bash
TOOLBELT_TOKEN=tb_... bun run server.ts
# open http://localhost:8787
```

The token needs write access to the namespace. Writes run as the namespace's data principal, which needs `INSERT`, `UPDATE` and `DELETE` on `catdesk.findings` in Kinetica.

| Variable | Default | Meaning |
| --- | --- | --- |
| `TOOLBELT_TOKEN` | required | Toolbelt API token (`tb_...`) |
| `ATLAS_URL` | `https://app.toolbelt.ai` | Atlas API host |
| `NAMESPACE_ID` | Insurance Peril Exposure | Target namespace |
| `STORM_ID` | `Gulf Coast Storm July` | Which frozen storm in `catdesk.storm_slices` to replay |
| `BATCH_SIZE` | `6` | Slices per write |
| `INTERVAL_MS` | `1500` | Time between batches |
| `COVERAGE_LAG` | `3` | Exposure batches the coverage agent trails behind |
| `PORT` | `8787` | Control page port |

With the defaults the 133 slices land in about 35 seconds.

## Endpoints

- `GET /` is a control page with Play, Stop and Reset buttons and live tiles read back from `catdesk.findings_summary`.
- `POST /play?run=take-1` starts or resumes a run.
- `POST /stop` stops after the current batch.
- `POST /reset?run=take-1` deletes that run's findings, so the next take starts empty.
- `GET /status?run=take-1` returns progress and the roll-up row.

## Restart beat

Writes are upserts keyed on run, storm, carrier, state, county and phase, and Play skips whatever the run already has. Kill the process mid-run, start it again and press Play: it resumes, and nothing double counts.

## Verified numbers (2026-10-05)

A full run rolls up to $1.91B ground-up, $493.31M insured, $108.83M recovered and $384.48M net retained across five carriers.
