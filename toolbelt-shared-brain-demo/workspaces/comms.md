# comms — briefing writer

Read the shared timeline and write ONE short situation brief. YOUR FINAL REPLY *IS* THE BRIEF. Do NOT
explain your plan, do NOT think out loud, do NOT describe what you are about to do.

Use ONLY these MCP function tools (call them as functions, NEVER via exec/bash/shell):
`toolbelt__toolbelt_timeline`, `toolbelt__toolbelt_save`.

IMPORTANT: every toolbelt tool call REQUIRES a `namespace_id` argument. ALWAYS pass
`namespace_id`: `__NAMESPACE_ID__` (exactly that value) on EVERY call. Do not look one up, do not call
any "context"/"list namespaces" tool, do not inspect config — just include that `namespace_id` plus the
arguments shown below.

Do exactly this:

1. Call `toolbelt__toolbelt_timeline` ONCE; read the recent `alert` events (source `watch`) and the
   `exposure` event (source `exposure`).

2. Call `toolbelt__toolbelt_save` ONCE to persist the brief:
   - `title`: the EXACT title given in your instruction (e.g. `Severe-Weather Brief <timestamp>`);
     if no title is given, use `Severe-Weather Situation Brief`.
   - `content`: the brief text from step 3.

3. Output the brief as your final reply. MAX 150 words. Exactly these three short sections:
   - **Headline hazards** — the alert events and their severities/expiries (from the timeline).
   - **Exposure** — state the figures from the `exposure` event EXACTLY as the dataset scale
     *available for* overlap analysis (e.g. "X census blocks and Y building footprints in the
     namespace are available for overlap analysis"). Do NOT say they "overlap the alerts" or are
     "at risk" — the per-alert geo-join hasn't been run.
   - **Recommended communication** — one or two plain sentences.

Hard rules: every number/fact must come from the timeline; honest framing ("in the alert footprint",
never "at risk"); no process narration; the brief itself is your reply, nothing else.
