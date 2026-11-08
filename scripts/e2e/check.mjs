#!/usr/bin/env node
// Compares what Agent Ledger recorded with what the testbed server actually received.
//
//   node scripts/e2e/check.mjs --since <ms|ISO|-10m> [--expect codex | --expect 1:claude-code,3:codex]
//                              [--testbed http://localhost:4399] [--db path] [--quiet]
//
// For every record save the testbed logged after --since it checks that the ledger has:
// the POST and its status, the form submit (with the same values the server stored), the
// "Saved" toast, and — with --expect — that each of those is attributed to the expected actor
// and sits in a session of that agent. It also lists sessions, detector decisions, gaps,
// recorded events outside any session, and runs the hash-chain check.
// Exit code 1 if any check fails.
import { DatabaseSync } from 'node:sqlite';
import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const args = Object.fromEntries(process.argv.slice(2).reduce((acc, a, i, all) => {
  if (a.startsWith('--')) acc.push([a.slice(2), all[i + 1] && !all[i + 1].startsWith('--') ? all[i + 1] : true]);
  return acc;
}, []));

function parseSince(s) {
  if (!s || s === true) return Date.now() - 10 * 60_000;
  const rel = /^-(\d+)([smh])$/.exec(s);
  if (rel) return Date.now() - Number(rel[1]) * { s: 1e3, m: 6e4, h: 3.6e6 }[rel[2]];
  if (/^\d+$/.test(s)) return Number(s);
  return Date.parse(s);
}

const since = parseSince(args.since);
const testbed = args.testbed || 'http://localhost:4399';
const home = process.env.AGENT_LEDGER_HOME || join(homedir(), 'Library/Application Support/AgentLedger');
const dbPath = args.db || join(home, 'ledger.sqlite');
const expect = parseExpect(args.expect);

function parseExpect(s) {
  if (!s || s === true) return null;
  if (!s.includes(':')) return { all: norm(s) };
  return { byRecord: Object.fromEntries(s.split(',').map((p) => { const [r, a] = p.split(':'); return [Number(r), norm(a)]; })) };
}
function norm(a) { return a === 'human' || a === 'you' ? 'human' : a === 'claude' ? 'claude-code' : a; }
function expectedFor(recordId) { return expect ? (expect.all ?? expect.byRecord?.[recordId] ?? null) : null; }

let failures = 0, warnings = 0;
const out = [];
const pass = (m) => out.push(`  ✅ ${m}`);
const fail = (m) => { failures++; out.push(`  ❌ ${m}`); };
const warn = (m) => { warnings++; out.push(`  ⚠️  ${m}`); };
const info = (m) => out.push(`     ${m}`);
const clock = (t) => new Date(t).toLocaleTimeString('en-US', { hour12: false }) + '.' + String(Math.floor(t % 1000)).padStart(3, '0');

// --- Ground truth from the testbed ---------------------------------------------------------------
let truth;
try {
  truth = await (await fetch(`${testbed}/__log`)).json();
} catch (e) {
  console.error(`Can't reach the testbed at ${testbed}: ${e.message}`);
  process.exit(2);
}
const saves = truth.log.filter((e) => e.t >= since && e.record);

// --- Ledger --------------------------------------------------------------------------------------
const db = new DatabaseSync(dbPath, { readOnly: true });
const events = db.prepare(`
  SELECT e.id, e.src, e.kind, e.cat, e.tab, e.url, e.rec, e.pre, e.observed_at AS t, e.payload,
         (SELECT a.actor FROM attributions a WHERE a.event_id = e.id ORDER BY a.id DESC LIMIT 1) AS actor,
         (SELECT a.label FROM attributions a WHERE a.event_id = e.id ORDER BY a.id DESC LIMIT 1) AS label,
         (SELECT a.reasons FROM attributions a WHERE a.event_id = e.id ORDER BY a.id DESC LIMIT 1) AS reasons,
         (SELECT group_concat(se.session_id) FROM session_events se WHERE se.event_id = e.id) AS sessions
  FROM events e WHERE e.observed_at >= ? ORDER BY e.observed_at, e.id`).all(since - 120_000)
  .map((e) => ({ ...e, p: e.payload ? JSON.parse(e.payload) : {}, sessions: e.sessions ? e.sessions.split(',') : [] }));
const sessions = db.prepare(`SELECT * FROM sessions WHERE last_activity_at >= ? OR started_at >= ? ORDER BY started_at`).all(since, since);
const sessionTabs = db.prepare(`SELECT * FROM session_tabs WHERE session_id = ?`);
const sessionById = Object.fromEntries(sessions.map((s) => [s.id, s]));
const recent = events.filter((e) => e.t >= since);

function actorOf(e) {
  return e.actor ? `${e.actor.replace(/^agent:/, '')} (${e.label})` : 'no attribution';
}
function checkActor(what, e, want) {
  if (!want) { info(`${what}: ${actorOf(e)}`); return; }
  const got = e.actor?.replace(/^agent:/, '');
  if (got === want) pass(`${what}: ${actorOf(e)}`);
  else fail(`${what}: expected ${want}, got ${actorOf(e)}${e.reasons ? ' — ' + JSON.parse(e.reasons).join('; ') : ''}`);
  const agents = e.sessions.map((s) => sessionById[s]?.agent ?? '?');
  if (want !== 'human' && want !== 'unknown' && !agents.includes(want)) fail(`${what} is not in a ${want} session (sessions: ${e.sessions.join(', ') || 'none'})`);
}

const sameValue = (a, b) => String(a ?? '').trim() === String(b ?? '').trim();

console.log(`Agent Ledger end-to-end check since ${new Date(since).toLocaleString()}`);
console.log(`Testbed: ${saves.length} save(s). Ledger: ${recent.length} event(s), ${sessions.length} session(s).\n`);

// --- Per-save checks -----------------------------------------------------------------------------
const usedRequests = new Set();
for (const save of saves) {
  const id = Number(save.path.split('/').pop());
  const want = expectedFor(id);
  out.push(`Save of record ${id} at ${clock(save.t)} by "${save.user}"${want ? ` — expecting ${want}` : ''}`);
  // The server logs only successful saves; match the nearest successful POST not already used.
  const req = events
    .filter((e) => e.cat === 'net.request' && e.url?.endsWith(save.path) && e.p.method === 'POST' && Math.abs(e.t - save.t) < 5000 &&
      e.p.status >= 200 && e.p.status < 300 && !usedRequests.has(e.id))
    .sort((a, b) => Math.abs(a.t - save.t) - Math.abs(b.t - save.t))[0];
  if (!req) { fail('save request not recorded'); out.push(''); continue; }
  usedRequests.add(req.id);
  if (req.p.status === 200) pass(`POST ${save.path} → ${req.p.status} recorded`); else fail(`request recorded with status ${req.p.status}`);
  checkActor('request', req, want);

  const submit = [...events].reverse().find((e) => e.cat === 'form.submit' && e.tab === req.tab && e.t <= req.t + 500 && req.t - e.t < 10_000);
  if (!submit) fail('form submit not recorded');
  else {
    const fields = Object.fromEntries((submit.p.fields || []).map((f) => [f.field?.nameAttr || f.field?.id, f]));
    const mismatches = [];
    for (const key of ['title', 'summary', 'status', 'tags', 'featured']) {
      const f = fields[key];
      if (!f) continue;
      const v = key === 'featured' ? (f.value?.checked ?? f.value?.value) : f.value?.value;
      const stored = save.record[key];
      if (key === 'featured' ? Boolean(v) !== Boolean(stored) && v !== undefined : !sameValue(v, stored)) mismatches.push(`${key}: ledger "${v}" vs server "${stored}"`);
    }
    if (mismatches.length) fail(`submitted values differ from what the server stored: ${mismatches.join('; ')}`);
    else pass(`submit recorded; its field values match what the server stored`);
    checkActor('submit', submit, want);
  }

  // Changes made since the previous submit in this tab.
  const prevSubmit = submit && [...events].reverse().find((e) => e.cat === 'form.submit' && e.tab === req.tab && e.t < submit.t - 1);
  const from = prevSubmit ? prevSubmit.t : req.t - 180_000;
  const changes = events.filter((e) => (e.cat === 'field.change' || e.cat === 'edit.change') && e.tab === req.tab && e.t > from && e.t <= req.t);
  if (changes.length) {
    pass(`${changes.length} field change(s): ` + changes.map((c) => `${c.p.target?.nameAttr || c.p.target?.id}: "${c.p.before?.value ?? (c.p.before?.checked)}" → "${c.p.after?.value ?? c.p.after?.checked}"`).join('; '));
    for (const c of changes) checkActor(`change of ${c.p.target?.nameAttr || c.p.target?.id}`, c, want);
  } else warn('no field change events before the save (fields may have been set without input events)');

  const toast = events.find((e) => e.cat === 'page.alert' && e.tab === req.tab && e.t >= req.t - 200 && e.t - req.t < 8000 && /^Saved/.test(e.p.text || ''));
  if (toast) { pass(`toast recorded: "${toast.p.text}"`); checkActor('toast', toast, want); }
  else fail('"Saved" toast not recorded');
  out.push('');
}

// --- Failed changes (the server logs only successful saves) --------------------------------------
const failedReqs = recent.filter((e) => e.cat === 'net.request' && e.p.mutating && (e.p.status >= 400 || e.p.error));
if (failedReqs.length) {
  out.push('Failed requests');
  for (const r of failedReqs) {
    const msg = events.find((a) => a.cat === 'page.alert' && a.tab === r.tab && a.t >= r.t - 200 && a.t - r.t < 8000);
    info(`${clock(r.t)} ${r.p.method} ${new URL(r.url).pathname} → ${r.p.status ?? r.p.error} by ${actorOf(r)}` +
      (msg ? `; page said "${msg.p.text}" (${actorOf(msg)})` : '; no page message recorded'));
  }
  out.push('');
}

// --- Sessions ------------------------------------------------------------------------------------
out.push('Sessions');
for (const s of sessions) {
  const tabs = sessionTabs.all(s.id);
  const evs = recent.filter((e) => e.sessions.includes(s.id));
  const kinds = {};
  for (const e of evs) kinds[e.kind] = (kinds[e.kind] || 0) + 1;
  out.push(`  ${s.id}  ${s.agent}  ${s.state}  attribution=${s.attribution} coverage=${s.coverage}`);
  info(`started ${clock(s.started_at)}: ${s.start_reason}`);
  if (s.task_label) info(`label: ${s.task_label.replace(/\s+/g, ' ').slice(0, 140)}`);
  info(`tabs: ${tabs.map((t) => `${t.tab} (${t.evidence}${t.unbound_at ? ', unbound' : ''})`).join('; ') || 'none'}`);
  info(`events: ${Object.entries(kinds).map(([k, n]) => `${k} ${n}`).join(', ') || 'none'}`);
  const actors = {};
  for (const e of evs.filter((e) => e.kind === 'observed_effect')) actors[actorOf(e)] = (actors[actorOf(e)] || 0) + 1;
  if (Object.keys(actors).length) info(`observed effects by actor: ${Object.entries(actors).map(([k, n]) => `${k} ×${n}`).join(', ')}`);
}
if (!sessions.length) info('none');
out.push('');

// --- Decisions, gaps, leaks ----------------------------------------------------------------------
const decisions = recent.filter((e) => e.cat === 'detector.decision');
const gaps = recent.filter((e) => e.kind === 'gap');
out.push('Detector decisions and gaps');
for (const d of decisions) info(`${clock(d.t)} ${d.p.decision}: ${(d.p.reasons || []).join('; ')}`);
for (const g of gaps) info(`${clock(g.t)} ${g.cat}${g.tab ? ' tab ' + g.tab : ''}${g.p.reason ? ': ' + g.p.reason : ''}`);
if (!decisions.length && !gaps.length) info('none');

const orphans = recent.filter((e) => e.kind === 'observed_effect' && e.sessions.length === 0);
if (orphans.length) warn(`${orphans.length} observed effect(s) stored outside any session: ${[...new Set(orphans.map((o) => o.cat))].join(', ')}`);
else pass('every stored browser effect belongs to a session');

const ledgerctl = ['/Volumes/RAID4/Projects/chrome extension/mac/dist/Agent Ledger.app/Contents/Helpers/ledgerctl',
  '/Applications/Agent Ledger.app/Contents/Helpers/ledgerctl'].find(existsSync);
if (ledgerctl) {
  try {
    const v = execFileSync(ledgerctl, ['verify'], { encoding: 'utf8', env: process.env }).trim();
    if (/ok|verified|intact/i.test(v)) pass(`hash chain: ${v.split('\n')[0]}`); else fail(`hash chain: ${v}`);
  } catch (e) { fail(`hash chain check failed: ${(e.stdout || e.message).toString().trim()}`); }
}

console.log(out.join('\n'));
console.log(`\n${failures ? `❌ ${failures} failed` : '✅ all checks passed'}${warnings ? `, ${warnings} warning(s)` : ''}`);
process.exit(failures ? 1 : 0);
