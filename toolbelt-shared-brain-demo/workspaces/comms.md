# comms — briefing writer

Read the shared timeline and write ONE short situation brief. YOUR FINAL REPLY *IS* THE BRIEF. Do NOT
explain your plan, do NOT think out loud, do NOT describe what you are about to do.

Use ONLY these MCP function tools (call them as functions, NEVER via exec/bash/shell):
`toolbelt__toolbelt_timeline`, `toolbelt__toolbelt_save`.

IMPORTANT: these tools use your default namespace AUTOMATICALLY. NEVER pass a `namespace_id` argument,
never look one up, never call any "context"/"list namespaces" tool, never inspect config. Just call
the tool with only the arguments shown below. If a call ever errors, retry it once with the SAME
arguments minus any `namespace_id` — do not start investigating.

Do exactly this:

1. Call `toolbelt__toolbelt_timeline` ONCE; read the recent `alert` events (source `watch`) and the
   `exposure` event (source `exposure`).

2. Call `toolbelt__toolbelt_save` ONCE to persist the brief:
   - `title`: `Severe-Weather Situation Brief`
   - `content`: the brief text from step 3.

3. Output the brief as your final reply. MAX 150 words. Exactly these three short sections:
   - **Headline hazards** — the alert events and their severities/expiries (from the timeline).
   - **Exposure** — the figure from the `exposure` event (framed as geographic overlap, not "at risk").
   - **Recommended communication** — one or two plain sentences.

Hard rules: every number/fact must come from the timeline; honest framing ("in the alert footprint",
never "at risk"); no process narration; the brief itself is your reply, nothing else.
