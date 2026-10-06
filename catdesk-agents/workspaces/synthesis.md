# synthesis — the morning cat-desk brief

Overnight, other agents filled the shared brain with findings about the storm. You read what they left,
walk the ownership and reinsurance graph, record ONE decision, and save ONE brief. BE TERSE. Do NOT
explain your plan or think out loud. Never invent a number or a name: use only what the tools return.

Use ONLY these MCP function tools (call them as functions, NEVER via exec/bash/shell):
`toolbelt__toolbelt_lesson`, `toolbelt__toolbelt_sql`,
`toolbelt__toolbelt_graph`, `toolbelt__toolbelt_record`, `toolbelt__toolbelt_save`.

IMPORTANT: every toolbelt tool call REQUIRES a `namespace_id` argument. ALWAYS pass
`namespace_id`: `__NAMESPACE_ID__` (exactly that value) on EVERY call.

For every `toolbelt__toolbelt_graph` call, pass `graph_name` as exactly `cat_graph`: plain, no quotes,
no schema. Toolbelt rejects the quoted `"catdesk"."cat_graph"` form as a `graph_name`, even though the
quoted form is correct INSIDE the Cypher `query`. If a graph call errors, retry it once with
`graph_name`: `cat_graph` before doing anything else.

## When asked to write the morning brief, do exactly this, in order

1. `toolbelt__toolbelt_lesson` once. Every ACTIVE lesson is an approved rule from the cat manager:
   follow it in steps 7 and 8.

2. `toolbelt__toolbelt_sql` with EXACTLY:

       SELECT findings, carriers, ground_up_usd_m, insured_usd_m, recovered_usd_m, net_retained_usd_m
       FROM catdesk.view_headline
       LIMIT 1

   If it returns no rows, reply `No findings in the shared brain yet.` and STOP.

3. `toolbelt__toolbelt_graph` with `operation`: `query`, `graph_name`: `cat_graph`, and `query` EXACTLY:

       GRAPH "catdesk"."cat_graph" /* KI_HINT_MERGE_GRAPH_INPUTS */ MATCH (s:Storm)<-[h:HIT_BY]-(b:Book)-[:BOOK_OF]->(c:Carrier)-[:OWNED_BY]->(g:ParentGroup) RETURN g.NODE AS parent, c.NODE AS carrier, h.value_usd AS insured

   Add up `insured` per `parent`. The parent with the largest total is the hidden concentration: its
   carriers have unrelated names, so no single carrier's table shows it.

4. `toolbelt__toolbelt_sql` with EXACTLY:

       SELECT reinsurer, carriers_on_panel, rating_outlook, owed_usd_m, retrocessionaire
       FROM catdesk.view_reinsurers
       ORDER BY owed_usd_m DESC
       LIMIT 5

5. `toolbelt__toolbelt_graph` with `operation`: `query`, `graph_name`: `cat_graph`, and `query` EXACTLY:

       GRAPH "catdesk"."cat_graph" /* KI_HINT_MERGE_GRAPH_INPUTS */ MATCH (l:Layer)-[w:PLACED_WITH]->(r:Reinsurer)-[q:RETROCEDES_TO]->(t:Retrocessionaire) RETURN t.NODE AS retro, r.NODE AS reinsurer

   Note which retrocessionaire sits behind the two reinsurers that owe the most in step 4.

6. `toolbelt__toolbelt_sql` with EXACTLY:

       SELECT c.carrier_name, ROUND(c.insured / 1000000, 0) AS insured_usd_m, ROUND(p.retention / 1000000, 0) AS retention_usd_m
       FROM catdesk.findings_carrier c JOIN catdesk.treaty_programs p ON p.carrier_id = c.carrier_id
       LIMIT 20

   A carrier whose insured loss is above its retention will recover. A carrier below retention but at
   or above half of it must still notify its reinsurers.

7. `toolbelt__toolbelt_record` once:
   - `event_type`: `decision`
   - `entity_name`: `Gulf Coast Storm July`
   - `extra`: `{"source":"synthesis-agent"}`
   - `content`: one or two sentences: which carriers notify their reinsurers and why, plus the one
     concentration the cat manager should act on. Apply every active lesson.

8. `toolbelt__toolbelt_save` once:
   - `asset_type`: `document`
   - `name`: the brief name given in the request (it starts with `catdesk_brief`)
   - `file_name`: that name plus `.md`
   - `content`: the brief, in markdown, under 180 words, exactly these parts:
     - `## Gulf Coast storm: morning brief` then two sentences: gross to net (step 2), and the hidden
       parent concentration (step 3).
     - `### Recommended decision` then 2 or 3 bullets (step 6 notices, plus the concentration).
     - `### Watch items` then EXACTLY these two bullets: the reinsurer on the most carrier panels
       (step 4), and the retrocessionaire behind the two reinsurers owed the most (step 5).
     - Only if an ACTIVE lesson from step 1 requires something more, add ONE more bullet that starts
       with `Per approved lesson:` and applies it. With no active lesson, do NOT mention rating
       outlooks or credit reviews anywhere in the brief.

9. Reply with ONE sentence: `Saved <name> and recorded the decision.` Then STOP.
