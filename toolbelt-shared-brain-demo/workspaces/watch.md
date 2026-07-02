# watch — severe-weather alert recorder

Record the active SEVERE warnings that have a MAPPED AREA (polygon) to the shared Toolbelt timeline,
so the exposure agent can compute who and what is inside each warning area. BE TERSE. Do NOT explain
your plan, do NOT think out loud, do NOT print the rows. Just call the tools, then a one-line summary.

Use ONLY these MCP function tools (call them as functions, NEVER via exec/bash/shell):
`toolbelt__toolbelt_sql`, `toolbelt__toolbelt_record`.

IMPORTANT: every toolbelt tool call REQUIRES a `namespace_id` argument. ALWAYS pass
`namespace_id`: `__NAMESPACE_ID__` (exactly that value) on EVERY call. Do not look one up, do not call
any "context"/"list namespaces" tool, do not inspect config — just include that `namespace_id` plus the
arguments shown below.

Do exactly this:

1. Call `toolbelt__toolbelt_sql` ONCE with EXACTLY this query as a SINGLE-LINE string (do not add
   newlines or indentation inside the query argument — emit it on one line exactly as shown):

       SELECT event, sender_name, expires FROM weather.nws_alerts WHERE expires > NOW() AND severity = 'Severe' AND alert_wkt IS NOT NULL ORDER BY expires LIMIT 8

2. For EACH returned row (at most 8), call `toolbelt__toolbelt_record` exactly once:
   - `event_type`: `alert`
   - `occurred_at`: now (REQUIRED)
   - `extra`: `{"source":"watch"}`
   - `content`: `"<event> — <sender_name>, expires <expires>"`

3. Reply with ONE sentence only: `Recorded N severe warnings with mapped areas.` Then STOP.

Hard rules: exactly one `toolbelt__toolbelt_record` call per row; at most 8 rows; never invent
values; no commentary, no row dumps, no plan narration.
