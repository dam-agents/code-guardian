// lib.mjs — the Desk's own records under work/desk/ (docs/desk.md → Records). Each file is written by
// the Desk server for a press on the page, or by scripts/desk/jobs.mjs for the agent's answer.
//   jobs.jsonl     work a person gave Code Guardian: {id J-<n>, utc, event queued|started|done|failed, …}
//   asks.jsonl     the page's chat: {id A-<n>, utc, role, email, text, context}
//   answers.jsonl  Code Guardian's answers: {id A-<n>, utc, text}
//   PEOPLE.md      the roster: | email | role | changed_utc |
//   notes.json     per email: which notifications the person read
import { appendFileSync, mkdirSync, renameSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import { read, jsonl } from './data.mjs';

const append = (file, row) => { mkdirSync(dirname(file), { recursive: true }); appendFileSync(file, `${JSON.stringify(row)}\n`, { mode: 0o600 }); };
export const writeFile = (f, text) => { mkdirSync(dirname(f), { recursive: true }); writeFileSync(`${f}.tmp`, text, { mode: 0o600 }); renameSync(`${f}.tmp`, f); };
export const utc = () => new Date().toISOString().replace(/\.\d+Z$/, 'Z');

// ------------------------------------------------ jobs J-<n>: a job's state is its last event
export const JOB_RE = /^J-\d{1,6}$/;
export const STATES = { queued: 'Waiting', started: 'Working', done: 'Done', failed: 'Did not work' };
export function jobs(file) {
  const m = new Map();
  for (const r of jsonl(read(file))) {
    if (!JOB_RE.test(r.id ?? '') || !['queued', 'started', 'done', 'failed'].includes(r.event)) continue;
    if (r.event === 'queued') { if (!m.has(r.id)) m.set(r.id, { id: r.id, utc: r.utc, command: r.command, label: r.label ?? null, item: r.item ?? null, note: r.note ?? null, role: r.role, platform: r.platform, email: r.email ?? null, state: 'queued', started: null, finished: null, text: null }); continue; }
    const j = m.get(r.id); if (!j) continue;
    j.state = r.event;
    if (r.event === 'started') j.started = r.utc; else { j.finished = r.utc; j.text = typeof r.text === 'string' ? r.text.slice(0, 2000) : null; }
  }
  return [...m.values()];
}
export function queue(file, job, now) {
  const id = `J-${jobs(file).length + 1}`;
  append(file, { id, utc: now, event: 'queued', command: job.command, label: job.label ?? null, item: job.item ?? null, ...(job.note ? { note: job.note } : {}), role: job.role, platform: job.platform, email: job.email ?? null });
  return id;
}
export function step(file, id, event, text, now) {
  const j = jobs(file).find((x) => x.id === id);
  if (!j) throw new Error(`no job ${id}`);
  const from = { started: ['queued'], done: ['started'], failed: ['queued', 'started'] }[event];
  if (!from) throw new Error(`no step ${event}`);
  if (!from.includes(j.state)) throw new Error(`${id} is ${j.state}, not ${from.join(' or ')}`);
  append(file, { id, utc: now, event, ...(text ? { text: String(text).slice(0, 2000) } : {}) });
  return { id, state: event };
}

// ------------------------------------------------ roles: the owner is an admin; anyone not in the roster a viewer
export const ROLES = ['admin', 'developer', 'viewer'];
export const EMAIL_RE = /^[a-z0-9._%+-]{1,64}@[a-z0-9.-]{1,190}\.[a-z]{2,24}$/;
// What only an admin starts: a schedule's work out of turn and a publish of a whole-instance page.
export const ADMIN_ONLY = [/^run (audit|survey|benchmark|monitor|brief) now$/, /^republish (health|manifest|trends|survey|benchmark)$/];
const HEAD = '| email | role | changed_utc |';
export function people(file) {
  const m = new Map();
  for (const l of String(read(file) ?? '').split('\n').filter((x) => x.startsWith('|')).slice(2)) {
    const [email, role, at] = l.split('|').slice(1, -1).map((x) => x.trim());
    if (EMAIL_RE.test(email ?? '') && ROLES.includes(role)) m.set(email, { email, role, utc: at && at !== '-' ? at : null });
  }
  return [...m.values()];
}
export function roleOf(file, platformRole, email) {
  if (platformRole === 'owner') return 'admin';
  const e = String(email ?? '').trim().toLowerCase();
  return (e && people(file).find((p) => p.email === e)?.role) || 'viewer';
}
export function may(role, command) {
  if (role === 'admin') return true;
  if (role !== 'developer') return false;
  return !ADMIN_ONLY.some((re) => re.test(String(command ?? '')));
}
export function setRole(file, email, role, now) {
  const e = String(email ?? '').trim().toLowerCase();
  if (!EMAIL_RE.test(e)) throw new Error('Write an email address, like pat@example.com.');
  if (role !== null && !ROLES.includes(role)) throw new Error(`A role is one of ${ROLES.join(', ')}.`);
  const list = people(file), old = list.find((p) => p.email === e)?.role ?? null;
  const kept = list.filter((p) => p.email !== e);
  if (role !== null) kept.push({ email: e, role, utc: now });
  if (kept.length > 200) throw new Error('The roster holds at most 200 people.');
  writeFile(file, `${HEAD}\n| --- | --- | --- |\n${kept.map((p) => `| ${p.email} | ${p.role} | ${p.utc ?? '-'} |`).join('\n')}${kept.length ? '\n' : ''}`);
  return { email: e, old, role };
}

// ------------------------------------------------ the chat
export const asks = (file) => jsonl(read(file)).filter((a) => /^A-\d+$/.test(a.id ?? ''));
export function recordAsk(file, who, text, context) {
  const row = { id: `A-${asks(file).length + 1}`, utc: utc(), role: who.access, email: who.email, text, context };
  append(file, row);
  return row;
}
export const answers = (file) => new Map(jsonl(read(file)).filter((a) => /^A-\d+$/.test(a.id ?? '') && typeof a.text === 'string').map((a) => [a.id, { text: a.text.slice(0, 6000), utc: a.utc ?? null }]));
export function answer(file, id, text, now) {
  if (!/^A-\d{1,6}$/.test(id ?? '')) throw new Error(`no question ${id}`);
  const t = String(text ?? '').trim(); if (!t) throw new Error('the answer is empty');
  append(file, { id, utc: now, text: t.slice(0, 6000) });
  return { id };
}
