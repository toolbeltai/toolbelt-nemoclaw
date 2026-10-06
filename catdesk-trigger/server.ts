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
let BATCH_SIZE = Number(process.env.BATCH_SIZE ?? 6);
let INTERVAL_MS = Number(process.env.INTERVAL_MS ?? 1500);
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

const PAGE = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Cat Desk Control</title>
<style>
:root{--bg:#0B1221;--panel:#121C31;--panel2:#0f1829;--line:#27334C;--fg:#E7EBF3;--muted:#8A95AB;--accent:#35D7C0;--accent-dim:#1f6f66;--danger:#ff6b6b}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif}
main{max-width:880px;margin:0 auto;padding:28px 18px 60px}
header{display:flex;justify-content:space-between;align-items:flex-start;gap:16px;margin-bottom:22px}
h1{font-size:22px;margin:0;letter-spacing:.2px}
.sub{color:var(--muted);font-size:13px;margin:4px 0 0}
.statuswrap{display:flex;align-items:center;gap:8px;white-space:nowrap;color:var(--muted);font-size:13px}
.dot{width:9px;height:9px;border-radius:50%;background:var(--muted);flex:0 0 auto}
.dot.on{background:var(--accent);animation:pulse 1.4s infinite}
@keyframes pulse{0%{box-shadow:0 0 0 0 rgba(53,215,192,.5)}70%{box-shadow:0 0 0 7px rgba(53,215,192,0)}100%{box-shadow:0 0 0 0 rgba(53,215,192,0)}}
.panel{background:var(--panel);border:1px solid var(--line);border-radius:14px;padding:16px 18px;margin-bottom:14px}
.ctl-row{display:flex;gap:9px;flex-wrap:wrap;align-items:center}
.ctl-row.sub{border-top:1px solid var(--line);padding-top:12px;margin-top:12px}
.lbl{color:var(--muted);font-size:13px;margin-right:4px}
label{color:var(--muted);font-size:13px;display:inline-flex;align-items:center;gap:7px}
input{font:inherit;font-size:14px;padding:8px 10px;border:1px solid var(--line);border-radius:9px;background:var(--panel2);color:var(--fg);min-width:92px}
input#viewurl{min-width:240px;flex:1}
.btn{font:inherit;font-size:14px;padding:9px 15px;border-radius:9px;border:1px solid var(--line);background:var(--panel2);color:var(--fg);cursor:pointer;transition:.12s}
.btn:hover{border-color:var(--accent);color:var(--accent)}
.btn.primary{background:var(--accent);border-color:var(--accent);color:#06221e;font-weight:600}
.btn.primary:hover{filter:brightness(1.08);color:#06221e}
.btn.danger:hover{border-color:var(--danger);color:var(--danger)}
.btn.ghost{padding:8px 13px}
.btn.active{border-color:var(--accent);color:var(--accent);background:rgba(53,215,192,.10)}
.progline{display:flex;justify-content:space-between;align-items:baseline;font-size:13px;color:var(--muted);margin:2px 0 7px}
.progline.sub2{margin-top:14px}
.mono{font-variant-numeric:tabular-nums;color:var(--fg)}
.bar{height:12px;background:var(--panel2);border:1px solid var(--line);border-radius:7px;overflow:hidden}
.bar.thin{height:8px}
.bar i{display:block;height:100%;width:0;background:linear-gradient(90deg,var(--accent-dim),var(--accent));transition:width .5s ease}
.bar.thin i{background:var(--accent-dim)}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:12px;margin-bottom:14px}
.tile{background:var(--panel);border:1px solid var(--line);border-radius:14px;padding:15px 16px}
.tile span{color:var(--muted);font-size:12.5px;display:block;margin-bottom:5px}
.tile b{font-size:27px;font-variant-numeric:tabular-nums;font-weight:650}
.tile.accent{border-color:var(--accent);background:linear-gradient(180deg,rgba(53,215,192,.08),rgba(53,215,192,0))}
.tile.accent b{color:var(--accent)}
.wf-title{font-size:13px;color:var(--muted);margin-bottom:12px}
.wf{display:grid;grid-template-columns:118px 1fr 86px;align-items:center;gap:12px;margin:9px 0}
.wf-lbl{font-size:13px;color:var(--muted)}
.wf-track{height:16px;background:var(--panel2);border-radius:6px;overflow:hidden}
.wf-track i{display:block;height:100%;width:0;border-radius:6px;transition:width .6s ease}
.wf-v{font-size:13px;text-align:right}
#status{color:var(--muted);font-size:12.5px;margin:14px 2px 0;white-space:pre-wrap;min-height:18px}
.foot{display:flex;gap:10px;flex-wrap:wrap;align-items:center}
.link{color:var(--accent);text-decoration:none;font-size:13px}
.link:hover{text-decoration:underline}
</style></head><body><main>
<header>
<div><h1>Catastrophe Response Desk</h1><p class="sub">Gulf storm replay into the shared brain &middot; figures read back live from the namespace roll-ups</p></div>
<div class="statuswrap"><span id="dot" class="dot"></span><span id="phase">Idle</span></div>
</header>

<section class="panel">
<div class="ctl-row">
<label>Run <input id="run" value="take-1" aria-label="Run id"></label>
<button class="btn primary" onclick="act('play',sp())">&#9654; Play full</button>
<button class="btn" onclick="act('stop')">&#9632; Stop</button>
<button class="btn danger" onclick="act('reset')">&#8635; Reset</button>
<button class="btn" onclick="restart()">&#8634; Stop and resume</button>
</div>
<div class="ctl-row sub">
<span class="lbl">Speed</span>
<button class="btn ghost spd" data-s="fast" onclick="setSpeed('fast')">Fast &middot; ~12s</button>
<button class="btn ghost spd" data-s="demo" onclick="setSpeed('demo')">Demo &middot; ~22s</button>
<button class="btn ghost spd" data-s="narrate" onclick="setSpeed('narrate')">Narrate &middot; ~40s</button>
</div>
<div class="ctl-row sub">
<span class="lbl">Fill part way, then stop</span>
<button class="btn ghost" onclick="playTo(0.25)">25%</button>
<button class="btn ghost" onclick="playTo(0.5)">50%</button>
<button class="btn ghost" onclick="playTo(0.75)">75%</button>
<button class="btn ghost" onclick="playTo(1)">100%</button>
</div>
</section>

<section class="panel">
<div class="progline"><span>Findings in the shared brain</span><span id="cnt" class="mono">0 / 133</span></div>
<div class="bar"><i id="barfill"></i></div>
<div class="progline sub2"><span>Coverage applied &middot; insured loss filled in</span><span id="cvg" class="mono">0 / 133</span></div>
<div class="bar thin"><i id="cvgfill"></i></div>
</section>

<section class="grid">
<div class="tile"><span>Ground-up loss</span><b id="gu">$0</b></div>
<div class="tile"><span>Insured loss</span><b id="ins">$0</b></div>
<div class="tile"><span>Reinsurance recovered</span><b id="rec">$0</b></div>
<div class="tile accent"><span>Net retained</span><b id="net">$0</b></div>
</section>

<section class="panel">
<div class="wf-title">Gross to net</div>
<div class="wf"><span class="wf-lbl">Ground-up</span><div class="wf-track"><i id="wf-gu" style="background:#3A4D6B"></i></div><span id="wfv-gu" class="wf-v mono"></span></div>
<div class="wf"><span class="wf-lbl">Insured</span><div class="wf-track"><i id="wf-ins" style="background:#4b7fb0"></i></div><span id="wfv-ins" class="wf-v mono"></span></div>
<div class="wf"><span class="wf-lbl">Recovered</span><div class="wf-track"><i id="wf-rec" style="background:var(--accent-dim)"></i></div><span id="wfv-rec" class="wf-v mono"></span></div>
<div class="wf"><span class="wf-lbl">Net retained</span><div class="wf-track"><i id="wf-net" style="background:var(--accent)"></i></div><span id="wfv-net" class="wf-v mono"></span></div>
</section>

<section class="panel foot">
<label>View URL <input id="viewurl" placeholder="paste the published View link"></label>
<button class="btn" onclick="openView()">Open View &#8599;</button>
<a id="atlaslink" class="link" target="_blank" rel="noopener">Open namespace in Atlas &#8599;</a>
</section>

<div id="status"></div>
</main>
<script>
var $=function(id){return document.getElementById(id)};
function usd(v){v=Number(v||0);if(v>=1e9)return '$'+(v/1e9).toFixed(2)+'B';if(v>=1e6)return '$'+Math.round(v/1e6)+'M';if(v>=1e3)return '$'+Math.round(v/1e3)+'K';return '$'+Math.round(v)}
function getrun(){return ($('run').value||'take-1').trim()}
var target=null,lastTotal=133;
var SPEED={fast:{b:12,i:900},demo:{b:8,i:1200},narrate:{b:5,i:1600}},speed='demo';
function sp(){return '&batch='+SPEED[speed].b+'&interval='+SPEED[speed].i}
function paintSpeed(){var e=document.querySelectorAll('.spd');for(var i=0;i<e.length;i++){e[i].classList.toggle('active',e[i].getAttribute('data-s')===speed)}}
function setSpeed(s){if(SPEED[s]){speed=s;try{localStorage.setItem('catdesk_speed',s)}catch(e){}paintSpeed()}}
try{var a=localStorage.getItem('catdesk_run');if(a)$('run').value=a;var b=localStorage.getItem('catdesk_viewurl');if(b)$('viewurl').value=b;var c=localStorage.getItem('catdesk_speed');if(c&&SPEED[c])speed=c}catch(e){}
$('atlaslink').href='https://app.toolbelt.ai/namespaces/664f9ed5-a82e-4908-92bb-d5d209f5fb1c';
function save(){try{localStorage.setItem('catdesk_run',getrun());localStorage.setItem('catdesk_viewurl',$('viewurl').value)}catch(e){}}
async function post(x,extra){var r=await fetch('/'+x+'?run='+encodeURIComponent(getrun())+(extra||''),{method:'POST'});return await r.text()}
async function act(x,extra){target=null;$('status').textContent=await post(x,extra);refresh()}
async function playTo(frac){var t=lastTotal||133;target=Math.max(1,Math.round(frac*t));$('status').textContent='Filling to '+Math.round(frac*100)+'%  ('+target+' of '+t+' slices), then stopping.\\n'+await post('play',sp());refresh()}
async function restart(){$('status').textContent='Stopping the fleet\\u2026\\n'+await post('stop');var i=0;var h=setInterval(async function(){try{var s=await (await fetch('/status?run='+encodeURIComponent(getrun()))).json();if(!s.state.running|| ++i>25){clearInterval(h);$('status').textContent='Resuming from the shared brain\\u2026\\n'+await post('play',sp());refresh()}}catch(e){clearInterval(h)}},800)}
function openView(){save();var u=$('viewurl').value.trim();if(u){window.open(u,'_blank')}else{$('status').textContent='Paste the published View URL first, then press Open View.'}}
async function refresh(){try{
var s=await (await fetch('/status?run='+encodeURIComponent(getrun()))).json();var m=s.summary||{};var st=s.state||{};
var tot=st.total||133;lastTotal=tot;var ex=st.exposureDone||0,cv=st.coverageDone||0;
$('cnt').textContent=ex+' / '+tot;$('cvg').textContent=cv+' / '+tot;
$('barfill').style.width=(tot?100*ex/tot:0)+'%';$('cvgfill').style.width=(tot?100*cv/tot:0)+'%';
$('gu').textContent=usd(m.ground_up);$('ins').textContent=usd(m.insured);$('rec').textContent=usd(m.recovered);$('net').textContent=usd(m.net_retained);
var gu=Number(m.ground_up||0);function w(v){return (gu>0?100*Number(v||0)/gu:0)+'%'}
$('wf-gu').style.width='100%';$('wf-ins').style.width=w(m.insured);$('wf-rec').style.width=w(m.recovered);$('wf-net').style.width=w(m.net_retained);
$('wfv-gu').textContent=usd(m.ground_up);$('wfv-ins').textContent=usd(m.insured);$('wfv-rec').textContent=usd(m.recovered);$('wfv-net').textContent=usd(m.net_retained);
$('dot').className='dot'+(st.running?' on':'');
$('phase').textContent=st.running?('Running \\u00b7 '+ex+'/'+tot):(ex>0?('Idle \\u00b7 '+ex+' in brain'):'Idle');
if(st.running&&target!==null&&ex>=target){var g=target;target=null;$('status').textContent='Reached '+g+' slices \\u2014 stopping.\\n'+await post('stop')}
else if(st.error){$('status').textContent=st.error}
}catch(e){$('status').textContent=String(e)}}
$('run').addEventListener('change',function(){save();target=null;refresh()});
$('viewurl').addEventListener('change',save);
paintSpeed();refresh();setInterval(refresh,2000);
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
        // Optional per-run pace, from the UI's speed control (clamped).
        const b = Number(url.searchParams.get("batch"));
        if (Number.isFinite(b) && b >= 1 && b <= 20) BATCH_SIZE = Math.floor(b);
        const iv = Number(url.searchParams.get("interval"));
        if (Number.isFinite(iv) && iv >= 200 && iv <= 6000) INTERVAL_MS = Math.floor(iv);
        play(runId);
        return new Response(`Playing ${runId} (batch ${BATCH_SIZE}, every ${INTERVAL_MS}ms)`);
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
