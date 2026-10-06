// catdesk-director: runs one full take of the cat-desk demo, beat by beat, and logs when each beat
// starts and ends so screen capture and narration can sync to it.
//
//   bun run director.ts                    full take, pauses for you to approve the lesson in Atlas
//   bun run director.ts --approve auto     rehearsal: approves the lesson through the API
//   bun run director.ts --no-governance    stop after the first morning brief
//   bun run director.ts --restart          include the restart beat (Stop mid-run, then Play again)
//   bun run director.ts --reset-only       just reset the brain and lessons for the next take
//
// Every step waits on real completion (trigger status, script exit, lesson status), not fixed timers,
// because agent turns vary from about 15 to 60 seconds.
//
// Config comes from ../catdesk-agents/.env (TOOLBELT_TOKEN, TOOLBELT_NAMESPACE), the same file the
// agents use. If the trigger service is not already answering on TRIGGER_URL, the director starts
// ../catdesk-trigger/server.ts itself for the take and stops it at the end.
//
// The video capture in toolbelt-demos (demo-content/insurance-peril-exposure/catdesk/capture.ts)
// runs this file and follows its output.

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const HERE = import.meta.dir;
const AGENTS_DIR = process.env.CATDESK_AGENTS_DIR ?? join(HERE, "..", "catdesk-agents");
const TRIGGER_DIR = join(HERE, "..", "catdesk-trigger");

// Read the agents' .env without overriding anything already set in the environment.
const envFile = join(AGENTS_DIR, ".env");
if (existsSync(envFile)) {
  for (const line of readFileSync(envFile, "utf8").split("\n")) {
    const m = line.match(/^\s*([A-Z_][A-Z0-9_]*)=(.*)$/);
    if (m && process.env[m[1]!] === undefined) process.env[m[1]!] = m[2]!.trim().replace(/^["']|["']$/g, "");
  }
}

const TRIGGER_URL = process.env.TRIGGER_URL ?? "http://localhost:8787";
const ATLAS_URL = process.env.ATLAS_URL ?? process.env.TOOLBELT_HOST ?? "https://app.toolbelt.ai";
const NAMESPACE_ID = process.env.NAMESPACE_ID ?? process.env.TOOLBELT_NAMESPACE ?? "664f9ed5-a82e-4908-92bb-d5d209f5fb1c";
const RUN_ID = process.env.RUN_ID ?? "take-1";
// Lesson approval and cleanup are owner-only. The namespace's owner is the account behind the
// agents' TOOLBELT_TOKEN, so that token is the default; OWNER_TOKEN or OWNER_TOKEN_FILE override it.
const OWNER_TOKEN_FILE = process.env.OWNER_TOKEN_FILE ?? join(homedir(), ".toolbelt_demo_token");
const COVERAGE_DELAY_S = Number(process.env.COVERAGE_DELAY_S ?? 10);
const CORRECTION =
  process.env.CORRECTION ??
  "Always flag any reinsurer with a negative rating outlook for a credit review in the brief, with what it owes.";
// Lessons this director created, so the next reset deletes only those.
const STATE_FILE = join(HERE, ".director-state.json");

const args = new Set(process.argv.slice(2));
const argValue = (name: string, fallback: string) => {
  const i = process.argv.indexOf(name);
  return i > 0 && process.argv[i + 1] ? process.argv[i + 1]! : fallback;
};
const APPROVE = argValue("--approve", "wait"); // wait | auto
const GOVERNANCE = !args.has("--no-governance");
const RESTART = args.has("--restart");
const RESET_ONLY = args.has("--reset-only");

// ---------------------------------------------------------------- beat log

type Beat = { beat: string; startedAt: string; endedAt?: string; seconds?: number; detail?: string };
const beats: Beat[] = [];
const t0 = Date.now();
const stamp = () => `+${((Date.now() - t0) / 1000).toFixed(1).padStart(6)}s`;
const say = (msg: string) => console.log(`\x1b[2m${stamp()}\x1b[0m  ${msg}`);

// One plain sentence per beat, printed under its heading so a live run explains itself. The line has
// no timestamp, so capture.ts never streams it into the agent terminal clip.
const ABOUT: Record<string, string> = {
  preflight: "Checking that the trigger service, the Toolbelt token, Docker and the agents' NemoClaw sandbox are all reachable.",
  reset: "Clearing the shared namespace: deleting this run's findings and the lessons earlier takes created, the same as Reset on the trigger page.",
  "fleet runs": "Replaying the Gulf storm, the same as Play: exposure findings land in the namespace in batches and the coverage pass trails behind, filling in insured loss.",
  "coverage agent (on camera)": "The coverage agent (Nemotron in NemoClaw) reads the exposure findings other agents left in the namespace and records its corrections to the timeline.",
  "restart beat": "Stopping the fleet halfway, then starting it again: it resumes from what is already in the namespace instead of starting over.",
  "morning brief": "The synthesis agent reads the namespace with SQL for amounts and the graph for who is connected, records a decision, and saves the morning brief.",
  "cat manager correction": "A cat manager's correction goes to the governance agent, whose only tool is proposing a lesson; the lesson stays a draft until the owner approves it.",
  "lesson approval": APPROVE === "auto"
    ? "Approving the draft lesson through the Atlas API, standing in for the namespace owner."
    : "Waiting for the namespace owner to approve the draft lesson in Atlas (namespace > Lessons).",
  "morning brief, following the lesson": "The synthesis agent writes the next brief; the approved lesson now comes back with its tool results and the brief follows it.",
};

async function beat<T>(name: string, fn: () => Promise<T>, detail?: (r: T) => string): Promise<T> {
  const b: Beat = { beat: name, startedAt: new Date().toISOString() };
  beats.push(b);
  console.log(`\n\x1b[1;36m▶ ${name}\x1b[0m`);
  if (ABOUT[name]) console.log(`  \x1b[3m${ABOUT[name]}\x1b[0m`);
  const result = await fn();
  b.endedAt = new Date().toISOString();
  b.seconds = Math.round((Date.parse(b.endedAt) - Date.parse(b.startedAt)) / 100) / 10;
  if (detail) b.detail = detail(result);
  say(`done in ${b.seconds}s${b.detail ? `: ${b.detail}` : ""}`);
  // Machine-readable end marker; beats can nest, so capture.ts matches ends by name.
  console.log(`■ ${name}`);
  return result;
}

function saveLog() {
  const dir = join(HERE, "runs");
  if (!existsSync(dir)) mkdirSync(dir);
  const file = join(dir, `take-${new Date(t0).toISOString().replace(/[:.]/g, "-")}.json`);
  writeFileSync(file, JSON.stringify({ runId: RUN_ID, startedAt: new Date(t0).toISOString(), beats }, null, 2));
  console.log(`\nBeat log: ${file}`);
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// ---------------------------------------------------------------- trigger service

async function trigger(method: "GET" | "POST", path: string) {
  const res = await fetch(`${TRIGGER_URL}${path}${path.includes("?") ? "&" : "?"}run=${RUN_ID}`, { method });
  const text = await res.text();
  if (!res.ok && !(res.status === 409 && path === "/stop")) throw new Error(`trigger ${path}: HTTP ${res.status} ${text}`);
  try { return JSON.parse(text); } catch { return text; }
}

type TriggerStatus = { state: { running: boolean; exposureDone: number; coverageDone: number; total: number; error: string | null } };

async function waitForFleet(until: (s: TriggerStatus["state"]) => boolean, label: string) {
  // Progress at most every 5 seconds, plus the final state, so a live run stays readable.
  let last = "";
  let lastAt = 0;
  for (;;) {
    const s = (await trigger("GET", "/status")) as TriggerStatus;
    if (s.state.error) throw new Error(`trigger error: ${s.state.error}`);
    const line = `${label}: ${s.state.exposureDone} of ${s.state.total} exposure findings written, ${s.state.coverageDone} with insured loss filled in`;
    const done = until(s.state);
    if (line !== last && (done || Date.now() - lastAt >= 5000)) { say(line); last = line; lastAt = Date.now(); }
    if (done) return s.state;
    await sleep(1000);
  }
}

// ---------------------------------------------------------------- Atlas lessons (owner-only)

const ownerToken = () =>
  process.env.OWNER_TOKEN || process.env.TOOLBELT_TOKEN || readFileSync(OWNER_TOKEN_FILE, "utf8").trim();

async function atlas(method: string, path: string) {
  const res = await fetch(`${ATLAS_URL}/api/namespace/${NAMESPACE_ID}${path}`, {
    method,
    headers: { Authorization: `Bearer ${ownerToken()}`, Accept: "application/json", "User-Agent": "catdesk-director/1.0" },
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`atlas ${method} ${path}: HTTP ${res.status} ${text.slice(0, 200)}`);
  return text ? JSON.parse(text) : null;
}

type Lesson = { id: string; title: string; status: "active" | "draft" | "disabled"; createdAt: string };
const listLessons = async () => (await atlas("GET", "/lessons")) as Lesson[];

const loadState = (): { createdLessonIds: string[] } =>
  existsSync(STATE_FILE) ? JSON.parse(readFileSync(STATE_FILE, "utf8")) : { createdLessonIds: [] };
const saveState = (s: { createdLessonIds: string[] }) => writeFileSync(STATE_FILE, JSON.stringify(s, null, 2));

// ---------------------------------------------------------------- agent scripts

async function runScript(script: string, ...scriptArgs: string[]): Promise<string> {
  const proc = Bun.spawn([join(AGENTS_DIR, "scripts", script), ...scriptArgs], { cwd: AGENTS_DIR, stdout: "pipe", stderr: "pipe" });
  const [out, err] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text()]);
  const code = await proc.exited;
  const clean = (out + err).replace(/\x1b\[[0-9;]*m/g, "");
  // Echo the agent's tool summary and reply (the indented lines), not the separator.
  for (const line of clean.split("\n")) {
    const text = line.trim();
    if (line.startsWith("  ") && text && text !== "---") say(`  ${text}`);
  }
  if (code !== 0) throw new Error(`${script} exited ${code}`);
  if (/failures=[1-9]/.test(clean) || /could not parse turn output/.test(clean)) throw new Error(`${script}: the agent turn failed (see output above)`);
  return clean;
}

// ---------------------------------------------------------------- the take

// The trigger service this director started, if it was not already running.
let ownTrigger: ReturnType<typeof Bun.spawn> | null = null;

async function ensureTrigger() {
  const up = async () => fetch(`${TRIGGER_URL}/status`).then((r) => r.ok, () => false);
  if (await up()) return "already running";
  if (new URL(TRIGGER_URL).hostname !== "localhost") throw new Error(`the trigger at ${TRIGGER_URL} is not answering`);
  if (!process.env.TOOLBELT_TOKEN) throw new Error(`TOOLBELT_TOKEN is not set (put it in ${envFile})`);
  ownTrigger = Bun.spawn([process.execPath, "run", join(TRIGGER_DIR, "server.ts")], {
    env: { ...process.env, NAMESPACE_ID, PORT: new URL(TRIGGER_URL).port || "8787" },
    stdout: "ignore",
    stderr: "inherit",
  });
  for (let i = 0; i < 40; i++) {
    if (await up()) return "started for this take";
    await sleep(250);
  }
  throw new Error("the trigger service did not start");
}

async function preflight() {
  const triggerNote = await ensureTrigger();
  const s = (await trigger("GET", "/status")) as TriggerStatus;
  if (s.state.running) throw new Error("the trigger is mid-run; press Stop or wait for it to finish");
  await listLessons(); // proves the owner token works
  const proc = Bun.spawn(["docker", "ps", "-q"], { stdout: "pipe", stderr: "pipe" });
  if ((await proc.exited) !== 0) throw new Error("Docker is not answering; start Docker");
  const sandbox = process.env.NEMOCLAW_SANDBOX_NAME ?? "toolbelt-catdesk";
  const status = Bun.spawn(["nemoclaw", sandbox, "status"], { stdout: "pipe", stderr: "pipe" });
  if ((await status.exited) !== 0) throw new Error(`NemoClaw sandbox '${sandbox}' is not up; run ../catdesk-agents/scripts/setup.sh`);
  return `trigger ${triggerNote}; owner token, Docker and sandbox '${sandbox}' all answer`;
}

async function reset() {
  await trigger("POST", "/stop");
  await trigger("POST", "/reset");
  const state = loadState();
  const lessons = await listLessons();
  let deleted = 0, disabled = 0;
  for (const l of lessons) {
    if (state.createdLessonIds.includes(l.id)) {
      await atlas("DELETE", `/lessons/${l.id}`);
      deleted++;
    } else if (l.status === "active") {
      // Not ours: disable rather than delete, so it can be re-enabled in Atlas.
      await atlas("POST", `/lessons/${l.id}/disable`);
      disabled++;
    }
  }
  saveState({ createdLessonIds: [] });
  return `findings cleared; ${deleted} director lessons deleted, ${disabled} other active lessons disabled`;
}

async function fleetAndCoverage() {
  await trigger("POST", "/play");
  say(`Play pressed; coverage agent starts in ${COVERAGE_DELAY_S}s`);
  await sleep(COVERAGE_DELAY_S * 1000);
  // The coverage agent is light (one query, three records), so it runs while the fleet writes.
  const coverage = beat("coverage agent (on camera)", () => runScript("run-coverage.sh"), () => "corrections recorded");
  if (RESTART) {
    await waitForFleet((s) => s.exposureDone >= Math.floor(s.total / 2), "fleet");
    await beat("restart beat", async () => {
      await trigger("POST", "/stop");
      await waitForFleet((s) => !s.running, "stopping");
      await sleep(3000);
      await trigger("POST", "/play");
      return "stopped mid-run and resumed";
    }, (r) => r);
  }
  await coverage;
  const final = await waitForFleet((s) => !s.running && s.coverageDone >= s.total && s.total > 0, "fleet");
  return `${final.total} findings in the shared brain`;
}

async function morning() {
  const out = await runScript("run-morning.sh");
  const m = out.match(/Saved (catdesk_brief_\S+?) and recorded/);
  return m ? `saved ${m[1]}` : "brief saved";
}

async function correctionAndApproval() {
  const before = new Set((await listLessons()).map((l) => l.id));
  await beat("cat manager correction", () => runScript("run-correction.sh", CORRECTION), () => "lesson proposed");
  const draft = (await listLessons())
    .filter((l) => !before.has(l.id) && l.status === "draft")
    .sort((a, b) => b.createdAt.localeCompare(a.createdAt))[0];
  if (!draft) throw new Error("no new draft lesson appeared after the correction");
  const state = loadState();
  saveState({ createdLessonIds: [...state.createdLessonIds, draft.id] });

  await beat("lesson approval", async () => {
    if (APPROVE === "auto") {
      await atlas("POST", `/lessons/${draft.id}/enable`);
      return "approved through the API (rehearsal)";
    }
    console.log(`\n  \x1b[1;33mApprove the draft lesson "${draft.title}" in Atlas (namespace > Lessons). Waiting...\x1b[0m`);
    for (;;) {
      const l = (await listLessons()).find((x) => x.id === draft.id);
      if (!l) throw new Error("the draft lesson was deleted instead of approved");
      if (l.status === "active") return "approved by a person in Atlas";
      await sleep(2000);
    }
  }, (r) => r);
}

async function main() {
  console.log(`catdesk-director  namespace=${NAMESPACE_ID}  run=${RUN_ID}  approve=${APPROVE}  governance=${GOVERNANCE}  restart=${RESTART}`);
  try {
    await beat("preflight", preflight, (r) => r);
    await beat("reset", reset, (r) => r);
    if (RESET_ONLY) return;
    await beat("fleet runs", fleetAndCoverage, (r) => r);
    await beat("morning brief", morning, (r) => r);
    if (GOVERNANCE) {
      await correctionAndApproval();
      await beat("morning brief, following the lesson", morning, (r) => r);
    }
    console.log(`\n\x1b[1;32mTake complete.\x1b[0m Every step went through the one namespace: findings, corrections, two briefs and an approved lesson. Reload the View to see the final state.`);
  } catch (err: any) {
    console.error(`\n\x1b[1;31mTake stopped: ${err?.message ?? err}\x1b[0m`);
    process.exitCode = 1;
  } finally {
    saveLog();
    if (ownTrigger) {
      ownTrigger.kill();
      await ownTrigger.exited;
    }
  }
}

await main();
