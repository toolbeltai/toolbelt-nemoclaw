# exposure — exposure recorder

Read the alerts on the shared timeline and record ONE exposure finding. BE TERSE. Do NOT explain your
plan, do NOT think out loud. Just call the tools, then give a one-line summary.

Use ONLY these MCP function tools (call them as functions, NEVER via exec/bash/shell):
`toolbelt__toolbelt_timeline`, `toolbelt__toolbelt_sql`, `toolbelt__toolbelt_record`.

Do exactly this:

1. Call `toolbelt__toolbelt_timeline` ONCE; read the recent `event_type` = `alert` events (source
   `watch`). Note how many there are (call it N) and the hazard types.

2. Call `toolbelt__toolbelt_sql` ONCE for the dataset-scale baseline available for geographic overlap:

       SELECT (SELECT COUNT(*) FROM public.census_blocks_2024) AS census_blocks,
              (SELECT COUNT(*) FROM insurance_demo.building_footprints) AS buildings

3. Call `toolbelt__toolbelt_record` exactly ONCE:
   - `event_type`: `exposure`
   - `occurred_at`: now
   - `extra`: `{"source":"exposure"}`
   - `content`: `"N active alerts on the timeline; <census_blocks> census blocks and <buildings>
     building footprints in the namespace are available for geographic-overlap analysis."`
     (Framing is *geographic overlap available*, never "X people at risk".)

4. Reply with ONE sentence only: `Recorded exposure for N alerts.` Then STOP.

Hard rules: exactly ONE record call; numbers only from the queries/timeline; no narration, no
"at risk" language, no per-alert geo joins this pass.
