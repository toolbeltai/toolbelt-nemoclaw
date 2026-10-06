// catdesk-trigger: replays the frozen hero storm into the shared brain on a timer.
//
// The overnight fleet, compressed: exposure findings land first (ground-up loss, insured
// unknown), then the coverage agent's findings trail behind and fill in insured loss. Every
// write goes through Atlas's execute-sql route, so it lands in the Toolbelt namespace, and the
// findings_* materialized views (refresh every 2 s) roll it up for the View.
//
// Writes are upserts keyed on (run, storm, carrier, state, county, phase), and Play resumes from
// whatever is already in catdesk.findings for the run. Kill the process mid-run, start it again,
// press Play: it picks up where it stopped. That is the restart beat.
//
//   TOOLBELT_TOKEN=tb_... bun run server.ts     then open http://localhost:8787

const ATLAS_URL = process.env.ATLAS_URL ?? "https://app.toolbelt.ai";
const TOKEN = process.env.TOOLBELT_TOKEN ?? "";
const NAMESPACE_ID = process.env.NAMESPACE_ID ?? "664f9ed5-a82e-4908-92bb-d5d209f5fb1c";
const STORM_ID = process.env.STORM_ID ?? "Gulf Coast Storm July";
const PORT = Number(process.env.PORT ?? 8787);
const BATCH_SIZE = Number(process.env.BATCH_SIZE ?? 6);
const INTERVAL_MS = Number(process.env.INTERVAL_MS ?? 1500);
// How many exposure batches the coverage agent trails behind.
const COVERAGE_LAG = Number(process.env.COVERAGE_LAG ?? 3);

if (!TOKEN) {
  console.error("TOOLBELT_TOKEN is required (a tb_ API token with write access to the namespace).");
  process.exit(1);
}

type Slice = {
  storm_id: string; state: string; county: string; carrier_id: string; phase: string;
  book_id: string; policies: number; tiv: number; ground_up: number; insured: number;
};

type RunState = {
  runId: string; running: boolean; exposureDone: number; coverageDone: number; total: number;
  startedAt: string | null; lastBatchAt: string | null; error: string | null;
};

let state: RunState = {
  runId: "", running: false, exposureDone: 0, coverageDone: 0, total: 0,
  startedAt: null, lastBatchAt: null, error: null,
};
let stopRequested = false;

// Atlas appends "LIMIT n" to every statement unless limit is 0, which breaks DELETE, so writes pass 0.
async function sql<T = Record<string, unknown>>(statement: string, limit = 10000): Promise<T[]> {
  const res = await fetch(`${ATLAS_URL}/api/query/execute-sql`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${TOKEN}`,
      "Content-Type": "application/json",
      Accept: "application/json",
      // Cloudflare blocks some default client user agents.
      "User-Agent": "catdesk-trigger/1.0",
    },
    body: JSON.stringify({ namespaceId: NAMESPACE_ID, sql: statement, limit }),
  });
  const text = await res.text();
  let body: any;
  try {
    body = JSON.parse(text);
  } catch {
    throw new Error(`Atlas returned non-JSON (HTTP ${res.status}): ${text.slice(0, 200)}`);
  }
  if (!res.ok || body.success === false) {
    const msg = body.error ?? (Array.isArray(body.errors) ? body.errors.join("; ") : JSON.stringify(body.errors));
    throw new Error(`execute-sql failed (HTTP ${res.status}): ${msg}`);
  }
  return body.data as T[];
}

const q = (s: string) => `'${s.replace(/'/g, "''")}'`;
const key = (s: { carrier_id: string; state: string; county: string; phase: string }) =>
  `${s.carrier_id}|${s.state}|${s.county}|${s.phase}`;

async function loadSlices(): Promise<Slice[]> {
  // Storm order: the Jul 21 offices (phase A) first, then Jul 22 to 24 (phase B), state by state.
  return sql<Slice>(
    `SELECT storm_id, state, county, carrier_id, phase, book_id, policies, tiv, ground_up, insured
     FROM catdesk.storm_slices WHERE storm_id = ${q(STORM_ID)}
     ORDER BY phase, state, county, carrier_id`,
  );
}

async function existing(runId: string): Promise<Map<string, boolean>> {
  // key -> whether coverage has already filled in insured
  const rows = await sql<{ carrier_id: string; state: string; county: string; phase: string; has_insured: number }>(
    `SELECT carrier_id, state, county, phase, CASE WHEN insured IS NULL THEN 0 ELSE 1 END AS has_insured
     FROM catdesk.findings WHERE run_id = ${q(runId)} AND storm_id = ${q(STORM_ID)}`,
  );
  return new Map(rows.map((r) => [key(r), Number(r.has_insured) === 1]));
}

function upsert(runId: string, batch: Slice[], role: "exposure" | "coverage"): string {
  const values = batch.map((s) => {
    const agent = role === "exposure" ? `exposure-${s.carrier_id}` : "coverage";
    const insured = role === "coverage" ? Number(s.insured).toFixed(2) : "NULL";
    const note = role === "coverage" ? q("flood exclusions, wind pool and deductibles applied") : "NULL";
    return `(${q(runId)}, ${q(s.storm_id)}, ${q(s.carrier_id)}, ${q(s.state)}, ${q(s.county)}, ${q(s.phase)}, ${q(s.book_id)},
      ${q(agent)}, ${q(role)}, ${Number(s.policies)}, ${Number(s.tiv).toFixed(2)}, ${Number(s.ground_up).toFixed(2)},
      ${insured}, ${note}, NOW())`;
  });
  return `INSERT INTO catdesk.findings /* KI_HINT_UPDATE_ON_EXISTING_PK */
    (run_id, storm_id, carrier_id, state, county, phase, book_id, agent, agent_role, policies, tiv, ground_up, insured, note, updated_at)
    VALUES ${values.join(",\n")}`;
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// Post to the namespace timeline, the same route toolbelt_record uses, so the View's timeline
// section shows the fleet working. A failed post is logged, never fatal: findings matter more.
async function record(content: string, eventType: string, entityName?: string, extra?: Record<string, unknown>) {
  try {
    const res = await fetch(`${ATLAS_URL}/api/namespace/${NAMESPACE_ID}/timeline`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${TOKEN}`,
        "Content-Type": "application/json",
        Accept: "application/json",
        "User-Agent": "catdesk-trigger/1.0",
      },
      body: JSON.stringify({ content, eventType, entityName, extra, occurredAt: new Date().toISOString() }),
    });
    if (!res.ok) console.error(`[timeline] HTTP ${res.status}: ${(await res.text()).slice(0, 200)}`);
  } catch (err: any) {
    console.error(`[timeline] ${err?.message ?? err}`);
  }
}

const CARRIER_NAMES: Record<string, string> = {
  SMP: "Saltmeadow Property", KBC: "Kettlebrook Commercial", FHM: "Fernhollow Mutual",
  CSC: "Calderstone Casualty", BLP: "Bayou Lantern Property",
};
const describe = (batch: Slice[]) => {
  const carriers = [...new Set(batch.map((s) => CARRIER_NAMES[s.carrier_id] ?? s.carrier_id))];
  const states = [...new Set(batch.map((s) => s.state))];
  return { carriers, states, counties: batch.length };
};

async function play(runId: string) {
  const slices = await loadSlices();
  const done = await existing(runId);
  // Resume: exposure for slices not yet written, coverage for slices without insured.
  const exposureQueue = slices.filter((s) => !done.has(key(s)));
  const coverageQueue = slices.filter((s) => done.get(key(s)) !== true);

  state = {
    runId, running: true, total: slices.length,
    exposureDone: slices.length - exposureQueue.length,
    coverageDone: slices.length - coverageQueue.length,
    startedAt: new Date().toISOString(), lastBatchAt: null, error: null,
  };
  stopRequested = false;
  console.log(`[play] run=${runId} slices=${slices.length} exposure-left=${exposureQueue.length} coverage-left=${coverageQueue.length}`);

  const written = new Set(slices.filter((s) => done.has(key(s))).map(key));
  const resumed = state.exposureDone > 0;
  await record(
    resumed
      ? `Fleet resumed on ${STORM_ID}: ${state.exposureDone} of ${slices.length} slices were already in the shared brain, picking up from there`
      : `Fleet started on ${STORM_ID}: ${slices.length} slices of the book to work through`,
    "fleet", STORM_ID, { runId },
  );
  let tick = 0;
  try {
    while ((exposureQueue.length || coverageQueue.length) && !stopRequested) {
      if (exposureQueue.length) {
        const batch = exposureQueue.splice(0, BATCH_SIZE);
        await sql(upsert(runId, batch, "exposure"), 0);
        batch.forEach((s) => written.add(key(s)));
        state.exposureDone += batch.length;
        const d = describe(batch);
        await record(
          `Exposure agent geo-joined ${d.counties} counties in ${d.states.join(", ")} against the storm polygons for ${d.carriers.join(", ")}`,
          "finding", d.carriers[0], { runId, role: "exposure" },
        );
      }
      // Coverage trails behind and only fills slices exposure has already written.
      if (tick >= COVERAGE_LAG || !exposureQueue.length) {
        const ready = coverageQueue.filter((s) => written.has(key(s))).slice(0, BATCH_SIZE);
        if (ready.length) {
          await sql(upsert(runId, ready, "coverage"), 0);
          const readyKeys = new Set(ready.map(key));
          for (let i = coverageQueue.length - 1; i >= 0; i--) {
            if (readyKeys.has(key(coverageQueue[i]!))) coverageQueue.splice(i, 1);
          }
          state.coverageDone += ready.length;
          const d = describe(ready);
          await record(
            `Coverage agent read exposure findings for ${d.carriers.join(", ")} and applied policy terms (flood exclusions, wind pool, deductibles) to ${d.counties} counties`,
            "correction", d.carriers[0], { runId, role: "coverage" },
          );
        }
      }
      state.lastBatchAt = new Date().toISOString();
      console.log(`[play] exposure ${state.exposureDone}/${state.total}  coverage ${state.coverageDone}/${state.total}`);
      tick++;
      await sleep(INTERVAL_MS);
    }
  } catch (err: any) {
    state.error = err?.message ?? String(err);
    console.error(`[play] ${state.error}`);
  } finally {
    state.running = false;
    console.log(stopRequested ? "[play] stopped" : "[play] finished");
    if (!stopRequested && !state.error) {
      await record(
        `All ${state.total} slices are in the shared brain with insured loss filled in; ready for the morning synthesis`,
        "fleet", STORM_ID, { runId },
      );
    }
  }
}

async function summary(runId: string) {
  if (!runId) return null;
  const rows = await sql(
    `SELECT slices, carriers, policies, tiv, ground_up, insured, recovered, net_retained, last_update
     FROM catdesk.findings_summary WHERE run_id = ${q(runId)} AND storm_id = ${q(STORM_ID)}`,
  );
  return rows[0] ?? null;
}

const PAGE = `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Cat Desk Trigger</title>
<style>
:root{--bg:#fff;--fg:#1d2128;--muted:#5f6b7a;--line:#e3e6ea;--accent:#2563eb}
@media (prefers-color-scheme:dark){:root{--bg:#14171c;--fg:#e8eaee;--muted:#9aa3ae;--line:#2a2f37;--accent:#6b9cff}}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.5 system-ui,-apple-system,sans-serif}
main{max-width:760px;margin:0 auto;padding:32px 16px}
h1{font-size:20px;margin:0 0 4px} p{color:var(--muted);margin:0 0 20px}
.row{display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin-bottom:24px}
input{font:inherit;padding:8px 10px;border:1px solid var(--line);border-radius:8px;background:transparent;color:var(--fg)}
button{font:inherit;padding:8px 14px;border-radius:8px;border:1px solid var(--line);background:transparent;color:var(--fg);cursor:pointer}
button.primary{background:var(--accent);border-color:var(--accent);color:#fff}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px}
.tile{border:1px solid var(--line);border-radius:10px;padding:14px}
.tile b{display:block;font-size:24px;font-variant-numeric:tabular-nums}
.tile span{color:var(--muted);font-size:13px}
#status{color:var(--muted);font-size:13px;margin-top:16px;white-space:pre-wrap}
</style></head><body><main>
<h1>Cat Desk Trigger</h1>
<p>Replays the Jul 21 to 23 Gulf storm into the shared brain. Numbers below are read back from the namespace's roll-up views.</p>
<div class="row"><input id="run" value="take-1" aria-label="Run id">
<button class="primary" onclick="act('play')">Play</button><button onclick="act('stop')">Stop</button><button onclick="act('reset')">Reset run</button></div>
<div class="grid">
<div class="tile"><b id="slices">0</b><span>findings written</span></div>
<div class="tile"><b id="gu">$0</b><span>ground-up loss</span></div>
<div class="tile"><b id="ins">$0</b><span>insured loss</span></div>
<div class="tile"><b id="rec">$0</b><span>reinsurance recovered</span></div>
<div class="tile"><b id="net">$0</b><span>net retained</span></div>
</div><div id="status"></div></main>
<script>
const $=id=>document.getElementById(id);
const usd=v=>{v=Number(v||0);return v>=1e9?'$'+(v/1e9).toFixed(2)+'B':'$'+Math.round(v/1e6)+'M'};
async function act(a){const r=await fetch('/'+a+'?run='+encodeURIComponent($('run').value),{method:'POST'});$('status').textContent=await r.text();refresh()}
async function refresh(){try{const r=await fetch('/status?run='+encodeURIComponent($('run').value));const s=await r.json();const m=s.summary||{};
$('slices').textContent=(m.slices||0)+' / '+(s.state.total||133);$('gu').textContent=usd(m.ground_up);$('ins').textContent=usd(m.insured);
$('rec').textContent=usd(m.recovered);$('net').textContent=usd(m.net_retained);
$('status').textContent=(s.state.running?'Running':'Idle')+' · exposure '+s.state.exposureDone+' · coverage '+s.state.coverageDone+(s.state.error?'\\n'+s.state.error:'')}catch(e){$('status').textContent=String(e)}}
refresh();setInterval(refresh,2000);
</script></body></html>`;

Bun.serve({
  port: PORT,
  async fetch(req) {
    const url = new URL(req.url);
    const runId = (url.searchParams.get("run") ?? "take-1").trim();
    if (!/^[A-Za-z0-9_-]{1,32}$/.test(runId)) return new Response("run must be 1-32 letters, digits, - or _", { status: 400 });
    try {
      if (req.method === "GET" && url.pathname === "/") {
        return new Response(PAGE, { headers: { "Content-Type": "text/html; charset=utf-8" } });
      }
      if (req.method === "GET" && url.pathname === "/status") {
        return Response.json({ state, summary: await summary(runId) });
      }
      if (req.method === "POST" && url.pathname === "/play") {
        if (state.running) return new Response(`Already running ${state.runId}`, { status: 409 });
        play(runId);
        return new Response(`Playing ${runId}`);
      }
      if (req.method === "POST" && url.pathname === "/stop") {
        stopRequested = true;
        return new Response(state.running ? `Stopping ${state.runId}` : "Nothing running");
      }
      if (req.method === "POST" && url.pathname === "/reset") {
        if (state.running) return new Response("Stop the run before resetting it", { status: 409 });
        await sql(`DELETE FROM catdesk.findings WHERE run_id = ${q(runId)}`, 0);
        state = { ...state, runId, exposureDone: 0, coverageDone: 0, error: null };
        return new Response(`Reset ${runId}`);
      }
      return new Response("Not found", { status: 404 });
    } catch (err: any) {
      return new Response(err?.message ?? String(err), { status: 500 });
    }
  },
});
console.log(`catdesk-trigger on http://localhost:${PORT}  (namespace ${NAMESPACE_ID}, storm "${STORM_ID}")`);
