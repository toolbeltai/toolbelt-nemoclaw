# Cat-desk director

Runs one full take of the cat-desk demo, beat by beat, and logs when each beat starts and ends. `../catdesk-demo.sh` wraps it with prerequisite checks; the video capture in `toolbelt-demos` (`demo-content/insurance-peril-exposure/catdesk/capture.ts`) runs it directly and follows its output.

Every step waits on real completion (the trigger's status, an agent script's exit, a lesson's status) rather than fixed timers, because agent turns vary from about 15 to 60 seconds.

## Beats

1. **Preflight:** starts the trigger service (`../catdesk-trigger`) if nothing answers on `TRIGGER_URL`, then checks the owner token, Docker and the NemoClaw sandbox.
2. **Reset:** stops and resets the trigger run, deletes the lessons previous takes created, and disables any other active lesson (reversible in Atlas).
3. **Fleet runs:** presses Play; after `COVERAGE_DELAY_S` seconds the coverage agent runs while the fleet keeps writing. With `--restart`, it also stops the fleet halfway and resumes it.
4. **Morning brief:** the synthesis agent records a decision and saves the brief.
5. **Cat manager correction:** the governance agent proposes the correction as a lesson.
6. **Lesson approval:** waits for a person to approve it in Atlas, or approves it through the API with `--approve auto`.
7. **Morning brief, following the lesson:** the new brief applies the approved rule.

A trigger service the director started is stopped when the take ends.

## Run

```bash
bun run director.ts                    # full take; pauses for you to approve the lesson in Atlas
bun run director.ts --approve auto     # unattended: approves the lesson through the API
bun run director.ts --restart          # include the restart beat
bun run director.ts --no-governance    # stop after the first morning brief
bun run director.ts --reset-only       # just reset for the next take
```

Config comes from `../catdesk-agents/.env`; anything already set in the environment wins.

| Variable | Default | Meaning |
| --- | --- | --- |
| `TOOLBELT_TOKEN` | from `.env` | Token for the trigger's writes and, by default, the owner-only lesson calls |
| `TOOLBELT_NAMESPACE` / `NAMESPACE_ID` | from `.env` | The shared namespace |
| `OWNER_TOKEN` / `OWNER_TOKEN_FILE` | `TOOLBELT_TOKEN` | Override when the namespace owner is a different account than the agents' token |
| `TRIGGER_URL` | `http://localhost:8787` | The trigger service |
| `RUN_ID` | `take-1` | Trigger run id; the View does not filter by run, so keep one |
| `COVERAGE_DELAY_S` | `10` | Seconds after Play before the coverage agent runs |
| `CORRECTION` | the negative-outlook rule | The cat manager's correction |

Beat logs go to `runs/take-<timestamp>.json`. Lessons the director created are tracked in `.director-state.json`, so the next reset deletes only those. Both are gitignored.
