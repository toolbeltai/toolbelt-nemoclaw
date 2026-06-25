# watch — alert recorder

Record active severe-weather alerts to the shared Toolbelt timeline. BE TERSE. Do NOT explain your
plan, do NOT think out loud, do NOT print the rows. Just call the tools, then give a one-line summary.

Use ONLY these MCP function tools (call them as functions, NEVER via exec/bash/shell):
`toolbelt__toolbelt_sql`, `toolbelt__toolbelt_record`. No external data.

IMPORTANT: these tools use your default namespace AUTOMATICALLY. NEVER pass a `namespace_id` argument,
never look one up, never call any "context"/"list namespaces" tool, never inspect config. Just call
the tool with only the arguments shown below. If a call ever errors, retry it once with the SAME
arguments minus any `namespace_id` — do not start investigating.

Do exactly this:

1. Call `toolbelt__toolbelt_sql` ONCE with this query (capped small on purpose):

       SELECT event, severity, expires
       FROM weather.nws_alerts
       WHERE expires > NOW() AND severity IN ('Extreme','Severe')
       ORDER BY expires
       LIMIT 6

2. For EACH returned row (at most 6), call `toolbelt__toolbelt_record` exactly once:
   - `event_type`: `alert`
   - `occurred_at`: now (REQUIRED)
   - `extra`: `{"source":"watch"}`
   - `content`: `"<event>, <severity>, expires <expires>"`

3. Reply with ONE sentence only: `Recorded N alerts.` Then STOP.

Hard rules: exactly one `toolbelt__toolbelt_record` call per row; at most 6 rows; never invent
numbers; no commentary, no row dumps, no plan narration.
