#!/usr/bin/env node
// The Desk server: the Artifact API of the Desk page (docs/desk.md → The server). A Login item starts it
// at every boot (kit.yaml → startupItems), the same pattern as Design Desk's Desk and Quality Inspector's
// dashboard. The page is published once and asks this server for everything it shows:
//   GET  /api/me                   who looks (the platform's verified caller), their role, the share link
//   GET  /api/data?have=h          the Desk data (data.mjs), built again when a source in work/ changes
//   GET  /api/status               what Code Guardian does now: the PR locks, the newest run
//   GET  /api/artifacts/<id>/page  a published page's last local copy, to show on the Desk
//   POST /api/jobs {command,…}     work for Code Guardian, J-<n>, recorded with who pressed; ping `do desk job J-<n>`
//   GET  /api/jobs                 the newest jobs; whose: "you" or a role, never an email
//   GET  /api/asks · POST /api/asks {text, context}   the caller's chat; ping `answer desk question A-<n>`
//   GET  /api/notifications · POST /api/notifications/read {id} · /seen
//   GET  /api/people · POST /api/people {email, role|null}   the roster (an admin's)
// Only the platform relay reaches /api/: it sets x-platform-caller-role/-email/-sub on every request,
// which the page cannot forge. Loopback only. Nothing sent here is executed here: a job is stored as
// data and goes to the agent as the page's message.
import { createServer } from 'node:http';
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, realpathSync } from 'node:fs';
import { dirname, join, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { build, mtime, read, sources } from './data.mjs';
import { answers, asks, jobs as jobsOf, may, people, queue, recordAsk, roleOf, setRole, ROLES, STATES, utc, writeFile } from './lib.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const WORK = process.env.WORK_DIR ?? join(process.env.HOME ?? '/home/agent', 'work');
const PORT = Number(process.env.CG_DESK_PORT || 5555);
const DIR = join(WORK, 'desk');
const JOBS = join(DIR, 'jobs.jsonl'), ASKS = join(DIR, 'asks.jsonl'), ANSWERS = join(DIR, 'answers.jsonl'), PEOPLE = join(DIR, 'PEOPLE.md'), NOTES = join(DIR, 'notes.json');
const MAX_BODY = 64 * 1024;

const log = (level, event, msg) => { try { process.stderr.write(`${new Date().toISOString()} ${level} ${event} ${msg}\n`); } catch { /* ignore */ } };
class Said extends Error { constructor(status, msg) { super(msg); this.status = status; } }

// ------------------------------------------------ the page's commands: the closed set, each work for the agent
// The same list as the page's CMD_RE (scripts/desk/page.html): read from the page itself, so the two never differ.
const PAGE = join(HERE, 'page.html');
let patterns = { at: -1, re: null };
const allowed = (text) => {
  const t = mtime(PAGE);
  if (t !== patterns.at) { const m = String(read(PAGE) ?? '').match(/^const CMD_RE = \/(.+)\/([a-z]*);$/m); try { patterns = { at: t, re: m ? new RegExp(m[1], m[2]) : null }; } catch { patterns = { at: t, re: null }; } }
  return !!patterns.re && patterns.re.test(text);
};

// At most 20 presses or questions in 10 minutes per caller.
const usage = new Map();
function spend(key) {
  const now = Date.now(), list = (usage.get(key) ?? []).filter((t) => now - t < 600e3);
  if (list.length >= 20) throw new Said(429, 'That is 20 messages in 10 minutes. Wait some minutes and try again.');
  list.push(now); usage.set(key, list);
}

// ------------------------------------------------ the data: built again when a source changes
let cache = { key: '', data: null };
function data() {
  const key = createHash('sha1').update(sources(WORK).map((f) => `${f}:${mtime(f)}`).join('|')).digest('hex');
  if (key !== cache.key || Date.now() - (cache.built ?? 0) > 60e3) cache = { key, data: build(WORK), built: Date.now() };
  return cache.data;
}

// What Code Guardian does now, read at the moment of the question: the PRs it holds, the run that logs now.
function status() {
  const d = data(), now = Date.now();
  const busy = d.prs.filter((p) => p.status === 'in_progress').map((p) => ({ pr: p.n, title: p.title, since: p.utc }));
  const live = d.runs.filter((r) => r.state === 'running').map((r) => ({ id: r.id, job: r.job, start: r.start, prs: r.prs }));
  return { utc: utc(), busy, live, last: d.runs.at(-1) ? { id: d.runs.at(-1).id, job: d.runs.at(-1).job, end: d.runs.at(-1).end } : null, ago_min: d.runs.length ? Math.round((now - Date.parse(d.runs.at(-1).end)) / 60e3) : null };
}

// A published page's local copy: only a file the data names, inside work/, an .html file.
function pagePath(rel) {
  if (typeof rel !== 'string' || !rel.endsWith('.html') || rel.includes('\0')) return null;
  try { const real = realpathSync(resolve(WORK, rel)), base = realpathSync(WORK); return real.startsWith(base + sep) ? real : null; } catch { return null; }
}

// ------------------------------------------------ notifications: built from what the server keeps
const readNotes = () => { try { const o = JSON.parse(read(NOTES) ?? '{}'); return o && typeof o === 'object' && !Array.isArray(o) ? o : {}; } catch { return {}; } };
const whose = (role) => `a${role === 'admin' ? 'n' : ''} ${role}`;
const VERDICT_WORD = { APPROVE: 'approved', REQUEST_CHANGES: 'asked for changes', COMMENT: 'commented', RAPID: 'posted a rapid review' };
function notifications(who) {
  const since = new Date(Date.now() - 30 * 864e5).toISOString(), out = [], mine = (e) => !!who.email && e === who.email, d = data();
  for (const j of jobsOf(JOBS)) {
    if (!j.finished || j.finished < since) continue;
    out.push({ id: `job:${j.id}`, utc: j.finished, kind: j.state === 'done' ? 'done' : 'failed', mine: mine(j.email), title: `${j.state === 'done' ? 'Done' : 'Did not work'}: ${j.label || j.command}`, text: j.text, who: mine(j.email) ? 'you' : whose(j.role), item: j.item });
  }
  const asked = new Map(asks(ASKS).filter((r) => mine(r.email)).map((r) => [r.id, r]));
  for (const [id, a] of answers(ANSWERS)) { const q = asked.get(id); if (!q || !a.utc || a.utc < since) continue;
    out.push({ id: `ans:${id}`, utc: a.utc, kind: 'answer', mine: true, title: `${d.bot} answered your question`, text: a.text.slice(0, 300), quote: String(q.text ?? '').slice(0, 160), item: q.context?.item ?? null }); }
  for (const r of d.reviews) { if (r.ts < since) continue;
    const blocking = r.findings.filter((f) => f.status !== 'fixed' && f.severity !== 'suggestion').length;
    out.push({ id: `rev:${r.id}`, utc: r.ts, kind: r.verdict === 'APPROVE' ? 'approved' : r.verdict === 'REQUEST_CHANGES' ? 'changes' : 'review', mine: false,
      title: `${d.bot} ${VERDICT_WORD[r.verdict] || 'reviewed'} on #${r.pr}`, text: blocking ? `${blocking} blocking finding${blocking === 1 ? '' : 's'}` : null, item: r.id }); }
  for (const r of d.runs) if (r.state === 'fail' && r.end >= since) out.push({ id: `run:${r.id}`, utc: r.end, kind: 'failed', mine: false, title: `A ${r.job} run logged ${r.errors} error${r.errors === 1 ? '' : 's'}`, text: r.events.find((e) => e.level === 'error')?.msg ?? null, item: r.id });
  for (const i of d.health.incidents) if (i.first && i.first >= since) out.push({ id: `inc:${i.id}`, utc: i.first, kind: i.open ? 'alert' : 'done', mine: false, title: `${i.open ? 'Incident' : 'Incident closed'}: ${i.kind}`, text: i.detail ?? null, item: `health:${i.id}` });
  const list = out.sort((a, b) => b.utc.localeCompare(a.utc)).slice(0, 60), n = who.email ? readNotes()[who.email] ?? {} : {}, seen = new Set(n.read ?? []);
  const rows = list.map((x) => ({ ...x, unread: !seen.has(x.id) && (!n.seen || x.utc > n.seen) }));
  return { notifications: rows, unread_mine: rows.filter((x) => x.unread && x.mine).length, unread: rows.filter((x) => x.unread).length };
}

// ------------------------------------------------ http
const HOSTS = new Set([`127.0.0.1:${PORT}`, `localhost:${PORT}`, `[::1]:${PORT}`]);
function callerOf(req) {
  const role = req.headers['x-platform-caller-role'];
  if (role !== 'owner' && role !== 'viewer') return null;
  const email = String(req.headers['x-platform-caller-email'] || '').trim().toLowerCase() || null;
  return { role, email, sub: String(req.headers['x-platform-caller-sub'] || ''), access: roleOf(PEOPLE, role, email) };
}
async function body(req) {
  const chunks = []; let n = 0;
  for await (const c of req) { n += c.length; if (n > MAX_BODY) throw new Said(413, 'The message is too long.'); chunks.push(c); }
  if (!n) return {};
  try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { throw new Said(400, 'The body is not JSON.'); }
}
const send = (res, code, obj) => { res.writeHead(code, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' }); res.end(JSON.stringify(obj)); };
const refusal = (access) => (access === 'viewer' ? 'You can read the Desk and ask questions. An admin gives you a role to do more.' : 'Only an admin does this. Ask an admin.');
const clean = (v, n) => (typeof v === 'string' && v.trim() ? v.replace(/[\u0000-\u001f\u007f]/g, ' ').trim().slice(0, n) : null);
// Each page has its own chat session: the open item, else the tab and its page (the platform's key shape).
function conversationOf(c) {
  const whole = c?.item ? `item.${String(c.item).replace(/^#(\d+)$/, 'pr-$1')}` : `page.${c?.page || c?.tab || 'home'}`, slug = whole.replace(/[^A-Za-z0-9._-]+/g, '-');
  return slug === whole && slug.length <= 64 ? slug : `${slug.slice(0, 55)}.${createHash('sha256').update(whole).digest('hex').slice(0, 8)}`;
}

async function route(req, res, url, who) {
  const p = url.pathname.split('/').filter(Boolean), m = req.method;
  if (m === 'GET' && p[1] === 'me') {
    const link = (read(join(DIR, 'artifact.url')) ?? '').trim();
    return send(res, 200, { role: who.access, owner: who.role === 'owner', email: who.email, name: data().bot, version: data().version, link: /^https:\/\/[^\s#]{1,500}$/.test(link) ? link : null });
  }
  if (m === 'GET' && p[1] === 'data') {
    const d = data();
    if (url.searchParams.get('have') === d.hash) return send(res, 200, { hash: d.hash, unchanged: true });
    return send(res, 200, { hash: d.hash, data: d });
  }
  if (m === 'GET' && p[1] === 'status') return send(res, 200, status());
  if (m === 'GET' && p[1] === 'artifacts' && p[2] && p[3] === 'page') {
    const a = data().artifacts.find((x) => x.id === decodeURIComponent(p[2]));
    const f = a && pagePath(a.page);
    if (!f) throw new Said(404, 'No local copy of this page is kept here. Its link opens it.');
    const html = readFileSync(f, 'utf8');
    if (html.length > 6e6) throw new Said(413, 'This page is too large to show here. Its link opens it.');
    return send(res, 200, { id: a.id, html });
  }
  if (m === 'POST' && p[1] === 'jobs' && !p[2]) {
    const b = await body(req), command = typeof b.command === 'string' ? b.command : '';
    if (!command || command.length > 300 || !allowed(command)) throw new Said(400, `This is not work the Desk gives ${data().bot}. Use a button of the page.`);
    if (!may(who.access, command)) throw new Said(403, refusal(who.access));
    spend(who.email || who.sub || who.role);
    const id = queue(JOBS, { command, label: clean(b.label, 80), item: clean(b.item, 200), note: clean(b.note, 1000), role: who.access, platform: who.role, email: who.email }, utc());
    log('info', 'desk_job', `${id} from ${who.access}`);
    return send(res, 201, { id, ping: `do desk job ${id}`, ping_conversation: conversationOf({ item: clean(b.item, 200) }) });
  }
  if (m === 'GET' && p[1] === 'jobs' && !p[2]) return send(res, 200, { jobs: jobsOf(JOBS).slice(-80).reverse().map((j) => ({ id: j.id, utc: j.utc, command: j.command, label: j.label, item: j.item, state: j.state, state_word: STATES[j.state],
    started: j.started, finished: j.finished, text: j.text, mine: !!who.email && j.email === who.email, by: !!who.email && j.email === who.email ? 'you' : whose(j.role) })) });
  if (m === 'GET' && p[1] === 'asks') {
    const ans = answers(ANSWERS);
    return send(res, 200, { asks: asks(ASKS).filter((r) => r.email && r.email === who.email).slice(-60).map(({ id, utc: at, text, context }) => ({ id, utc: at, text, context, answer: ans.get(id) ?? null })) });
  }
  if (m === 'POST' && p[1] === 'asks') {
    const b = await body(req), text = typeof b.text === 'string' ? b.text.trim() : '';
    if (!text || text.length > 2000 || /[\u0000-\u0008\u000b-\u001f\u007f]/.test(text)) throw new Said(400, 'Write a question of at most 2000 letters.');
    spend(who.email || who.sub || who.role);
    const c = b.context && typeof b.context === 'object' ? b.context : {};
    const context = { tab: /^[a-z]{1,20}$/.test(c.tab ?? '') ? c.tab : null, page: /^[a-z]{1,20}(?:\/[a-z-]{1,20})?$/.test(c.page ?? '') ? c.page : null,
      item: typeof c.item === 'string' && c.item.length <= 200 && !/[\u0000-\u001f]/.test(c.item) ? c.item : null, label: clean(c.label, 200) };
    const row = recordAsk(ASKS, who, text, context);
    log('info', 'desk_ask', `${row.id} from ${who.access}`);
    return send(res, 201, { id: row.id, ping: `answer desk question ${row.id}`, ping_conversation: conversationOf(context) });
  }
  if (m === 'GET' && p[1] === 'people' && !p[2]) {
    const list = people(PEOPLE);
    return send(res, 200, { roles: ROLES, people: who.access === 'admin' ? list : [], counts: Object.fromEntries(ROLES.map((r) => [r, list.filter((x) => x.role === r).length])) });
  }
  if (m === 'POST' && p[1] === 'people' && !p[2]) {
    if (who.access !== 'admin') throw new Said(403, 'Only an admin gives people their roles.');
    const b = await body(req); spend(`people:${who.email}`);
    let done; try { done = setRole(PEOPLE, b.email, b.role === null ? null : String(b.role ?? ''), utc()); } catch (e) { throw new Said(400, e.message); }
    log('info', 'desk_people', `role ${done.old ?? '-'} → ${done.role ?? '-'} by=${who.email || '-'}`);
    return send(res, 200, { ok: true, ...done, people: people(PEOPLE) });
  }
  if (m === 'GET' && p[1] === 'notifications' && !p[2]) return send(res, 200, notifications(who));
  if (m === 'POST' && p[1] === 'notifications' && (p[2] === 'read' || p[2] === 'seen') && !p[3]) {
    if (!who.email) return send(res, 200, { ok: true });
    const b = p[2] === 'read' ? await body(req) : {}, notes = readNotes(), mine = notes[who.email] ?? { seen: null, read: [] };
    if (p[2] === 'read') { if (typeof b.id !== 'string' || !/^[a-z]{3}:[A-Za-z0-9:_-]{1,80}$/.test(b.id)) throw new Said(400, 'There is no such notification.'); if (!mine.read.includes(b.id)) mine.read = [...mine.read, b.id].slice(-500); }
    else { mine.seen = utc(); mine.read = []; }
    notes[who.email] = mine; writeFile(NOTES, JSON.stringify(notes));
    return send(res, 200, { ok: true });
  }
  throw new Said(404, `There is no route ${m} ${url.pathname}.`);
}

export const server = createServer(async (req, res) => {
  const url = new URL(req.url, 'http://desk.local');
  try {
    if (!HOSTS.has(String(req.headers.host || ''))) throw new Said(421, 'The Desk server answers only on its loopback address.');
    if (url.pathname === '/health') return send(res, 200, { ok: true, version: data().version, work: existsSync(WORK) });
    if (url.pathname.startsWith('/api/')) {
      const who = callerOf(req);
      if (!who) throw new Said(401, "The Desk server answers only the platform's relay.");
      return await route(req, res, url, who);
    }
    throw new Said(404, 'Not found.');
  } catch (e) {
    const code = e instanceof Said ? e.status : 500;
    if (code >= 500) log('error', 'desk_error', `${req.method} ${url.pathname}: ${e.stack || e}`);
    send(res, code, { error: code >= 500 ? 'Something went wrong on the Desk server. The operator sees it in its log.' : e.message });
  }
});

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  server.listen(PORT, '127.0.0.1', () => log('info', 'desk_start', `listening on 127.0.0.1:${PORT}, work ${WORK}`));
  for (const s of ['SIGTERM', 'SIGINT']) process.on(s, () => server.close(() => process.exit(0)));
}
