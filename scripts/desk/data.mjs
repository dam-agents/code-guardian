// data.mjs — the Desk's data: one object built from what Code Guardian keeps in work/ (docs/desk.md →
// The data). Read only; nothing here writes. The server builds it again when a source file changes.
//
//   prs        REVIEWS.md rows + reviews/pr-<n>.md histories + SHEPHERD.md + PR-EVENTS.jsonl
//   reviews    every posted review R-<n>: the ledger rows united with the history sections (one per pr+ts)
//   findings   every finding F-<n>, one per pr+file+summary, followed over the PR's rounds
//   learnings  every rule L-<n> of MEMORY.md, memory/<topic>.md and LESSONS.md, with its archive entry
//   runs       every run S-<n> of the event log (logs/events-*.jsonl), its job, PRs, outcome and tokens
//   artifacts  each published page: review guides, health dashboard, manifest, trends, survey, benchmark
//   health     status.json, incidents, MONITOR.json alerts, the hourly counts of the last 14 days
//   escapes, weeks, schedules, config, ticks (HEARTBEAT.log per day)
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { join } from 'node:path';
import { settingsOf } from './settings.mjs';

export const read = (p) => { try { return readFileSync(p, 'utf8'); } catch { return null; } };
export const mtime = (p) => { try { return statSync(p).mtimeMs; } catch { return 0; } };
const ls = (d) => { try { return readdirSync(d); } catch { return []; } };
export const jsonl = (text) => String(text ?? '').split('\n').filter(Boolean).map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter((x) => x && typeof x === 'object');
const json = (text) => { try { const v = JSON.parse(text ?? ''); return v && typeof v === 'object' ? v : null; } catch { return null; } };
export const tableRows = (text) => String(text ?? '').split('\n').filter((l) => l.startsWith('|')).slice(2).map((l) => l.split('|').slice(1, -1).map((c) => c.trim()));
const dash = (v) => (v && v !== '-' ? v : null);
const ISO = /^\d{4}-\d\d-\d\dT\d\d:\d\d(:\d\d)?(\.\d+)?Z$/;

// CONFIG.md bullets, as common.sh cfg() reads them: a trailing # comment and one layer of quotes go.
export function config(work) {
  const out = {};
  for (const l of String(read(join(work, 'CONFIG.md')) ?? '').split('\n')) {
    const m = /^- ([a-z_][a-z0-9_.]{0,60}):[ \t]*(.*?)[ \t]*$/.exec(l); if (!m) continue;
    out[m[1]] = m[2].replace(/[ \t]+#.*$/, '').replace(/^(['"`])(.*)\1$/, '$2');
  }
  return out;
}
// The keys a person may read on the page; nothing that names a secret, a token or a person's contact.
const CONFIG_SHOWN = /^(github_repo|bot_display_name|definition_branch|rereview_trigger|rereview_label|rereview_delta_label|urgent_label|auto_merge_label|agent_fix_label|guide_label|approve_after_rounds|active_hours|active_days|review_interval_active|review_interval_quiet|log_level|audit_trend|survey_report|benchmark_report|health_dashboard|agent_manifest|shepherd_enabled|slack_notifications|review_guide|auto_merge|agent_fixes|escapes|survey_enabled|brief_enabled|[a-z_]+_(enabled|threshold|days|hours|minutes|max|min|cap))$/;

// The two hidden payloads of a posted review (review-mechanics.md): the last of each in a text.
const payload = (body, name) => { const all = [...String(body ?? '').matchAll(new RegExp(`<!-- ${name}: (.*?) -->`, 'g'))]; return all.length ? json(all.at(-1)[1]) : null; };
const findingsOf = (body) => { const f = payload(body, 'findings-json'); return Array.isArray(f) ? f.filter((x) => x && typeof x === 'object') : []; };

// reviews/pr-<n>.md: the title, the guide marker, the PR-local overrides, one section per round.
export function history(text) {
  const t = String(text ?? '');
  const title = /^# PR #\d+: (.*)$/m.exec(t)?.[1]?.trim() ?? null;
  const g = /<!-- artifact-guide: (\S+) (\S+) (\S+) -->/.exec(t);
  const ov = /## PR-local overrides\n([\s\S]*?)(?=\n## |$)/.exec(t)?.[1] ?? '';
  const overrides = ov.split('\n').filter((l) => /^- /.test(l)).map((l) => l.slice(2).trim()).slice(0, 50);
  const parts = t.split(/^## Review at /m).slice(1);
  const rounds = parts.map((p) => {
    const head = /^(\S+) — (\S+) — (\S+)\s*$/m.exec(p.split('\n')[0]) ?? [];
    const body = p.split('\n').slice(1).join('\n').replace(/\n---\s*(\n<!-- [a-z-]+(?::[^>]*)? -->\s*)*$/m, '').trim();
    return { sha: head[1] ?? null, ts: head[2] ?? null, verdict: head[3] ?? null, body, guide_owed: /<!-- guide-owed -->/.test(p), guide_seen: /<!-- guide-label-seen -->/.test(p) };
  }).filter((r) => ISO.test(r.ts ?? ''));
  const urgent = /<!-- urgent-announced: (\S+) -->/.exec(t)?.[1] ?? null;
  return { title, urgent, guide: g ? { id: g[1], sha: g[2], url: /^https:\/\//.test(g[3]) ? g[3] : null } : null, overrides, rounds };
}

// A review body as a person reads it: the hidden lines out, at most 24k letters.
const visible = (body) => String(body ?? '').replace(/<!--[\s\S]*?-->/g, '').trim().slice(0, 24000);
const VERDICT_RE = /^(APPROVE|COMMENT|REQUEST_CHANGES|RAPID)$/;

// One run of the event log: its id, its job, when, what it did. A gated fire logs under the gate's id
// (CG_RUN_ID, "<mode>-<stamp>-<pid>") and its session under the session's: the gate's events join the
// session's run of the same job that starts within 3 minutes after them (logging.md).
// The price table of work/CONFIG.md (`## Benchmark model prices`, per million tokens), as
// scripts/lib/prices.sh reads it: the longest cell the model id contains prices it; a cell that ends
// in a digit does not price a later version ("claude-opus-5" leaves "claude-opus-5-5" unpriced).
function pricesOf(work) {
  const text = String(read(join(work, 'CONFIG.md')) ?? ''), at = text.search(/^##\s+Benchmark model prices\s*$/m);
  if (at < 0) return [];
  const out = [];
  for (const l of text.slice(at).split('\n').slice(1)) {
    if (/^##\s/.test(l)) break;
    const c = l.split('|').map((x) => x.trim()); if (c.length < 6) continue;
    const [m, i, o, cr, cw] = [c[1].replace(/\s*\[.*\]$/, ''), +c[2], +c[3], +c[4], +c[5]];
    if (m && ![i, o, cr, cw].some((x) => Number.isNaN(x)) && c[2] !== '') out.push({ m, i, o, cr, cw });
  }
  return out;
}
function usd(prices, t) {
  if (!t?.model) return null;
  const has = (p) => { const k = t.model.indexOf(p.m); if (k < 0) return false; return !(/\d$/.test(p.m) && /^-\d{1,2}(?!\d)/.test(t.model.slice(k + p.m.length))); };
  const p = prices.filter(has).sort((a, b) => b.m.length - a.m.length)[0];
  return p ? Math.round(((t.input * p.i + t.output * p.o + t.cache_read * p.cr + t.cache_creation * p.cw) / 1e6) * 100) / 100 : null;
}
const median = (xs) => { const v = xs.filter((x) => Number.isFinite(x)).sort((a, b) => a - b); return v.length ? v[Math.floor((v.length - 1) / 2)] : null; };

// The phases of one PR's review in a run, from its review_step milestones (review.md → Progress
// logging) and the skills' finish times from skill_timing. While the skills run, the log knows only
// how many run side by side; their names and times come when they are collected.
const PHASES = [['prepare', 'Get ready', 'locked'], ['diff', 'Read the change', 'cloned'], ['skills', 'Skills', 'fanned'], ['compose', 'Write the review', 'verified'], ['post', 'Post', 'composed']];
const MILESTONES = ['locked', 'cloned', 'fanned', 'verified', 'composed', 'posted', 'done'];
function phasesOf(ev, running) {
  const per = new Map();
  for (const e of ev) {
    const m = /^PR #(\d+)(?: \[(\w+)\])? (.*)$/.exec(e.msg ?? ''); if (!m) continue;
    const x = per.get(+m[1]) ?? { pr: +m[1], sha: m[2] || null, at: {}, skills: [], n: null, verdict: null, aborted: null };
    const step = m[3], t = e.ts;
    if (e.event === 'review_step') {
      if (step === 'locked') x.at.locked ??= t;
      else if (/^cloned/.test(step)) x.at.cloned ??= t;
      else if (/^fanned out/.test(step)) { x.at.fanned ??= t; x.n = +(/n=(\d+)/.exec(step)?.[1] ?? 0) || null; }
      else if (/^verified/.test(step)) x.at.verified ??= t;
      else if (/^composed/.test(step)) x.at.composed ??= t;
      else if (/^posted/.test(step)) { x.at.posted ??= t; x.verdict = step.split(' ')[1] ?? null; }
      else if (/^done/.test(step)) x.at.done ??= t;
      else if (/^aborted/.test(step)) { x.at.aborted ??= t; x.aborted = step.replace(/^aborted\s*/, ''); }
      if (!x.sha && m[2]) x.sha = m[2];
    } else if (e.event === 'skill_timing') {
      for (const [, name, sec] of step.matchAll(/([\w.-]+?)(?:\.txt)?=(\d+)/g)) x.skills.push({ name, end: new Date(+sec * 1000).toISOString() });
    }
    per.set(x.pr, x);
  }
  return [...per.values()].filter((x) => x.at.locked).map((x) => {
    const stop = x.at.aborted ?? null;
    const phases = PHASES.map(([key, label, from], k) => {
      const start = x.at[from] ?? null;
      const later = MILESTONES.slice(MILESTONES.indexOf(from) + 1).filter((m) => key !== 'post' || m !== 'posted' || !x.at.done);
      let end = key === 'post' ? (x.at.done ?? x.at.posted ?? null) : (later.map((m) => x.at[m]).find(Boolean) ?? null);
      if (!end && start && stop) end = stop;
      const state = !start ? (running && !stop && !x.at.posted ? 'next' : 'skipped') : end ? (stop && end === stop && !x.at.posted ? 'stopped' : 'done') : running ? 'running' : 'stopped';
      return { key, label, start, end, state };
    }).filter((p) => p.state !== 'skipped');
    const fan = x.at.fanned;
    const skills = x.skills.length ? x.skills.map((s) => ({ ...s, start: fan, secs: fan ? Math.max(0, Math.round((Date.parse(s.end) - Date.parse(fan)) / 1000)) : null }))
      : null;
    return { pr: x.pr, sha: x.sha, start: x.at.locked, end: x.at.done ?? x.at.posted ?? stop ?? null, verdict: x.verdict, aborted: x.aborted, parallel: x.n ?? (skills ? skills.length : null), phases, skills };
  });
}

function runsOf(work, now, prices = []) {
  const files = ls(join(work, 'logs')).filter((f) => /^events-\d{4}-\d\d-\d\d\.jsonl$/.test(f)).sort();
  const by = new Map();
  for (const f of files) for (const e of jsonl(read(join(work, 'logs', f)))) {
    if (typeof e.run !== 'string' || !e.run || !ISO.test(e.ts ?? '')) continue;
    const r = by.get(e.run) ?? { run: e.run, job: e.job || 'session', events: [] };
    r.events.push(e); if (e.job && r.job === 'session') r.job = e.job; by.set(e.run, r);
  }
  let list = [...by.values()].map((r) => { r.events.sort((a, b) => a.ts.localeCompare(b.ts)); r.start = r.events[0].ts; r.end = r.events.at(-1).ts; return r; });
  // Only a precheck that found nothing: a tick, not a run (the ticks chart counts them).
  list = list.filter((r) => !r.events.every((e) => e.event === 'precheck' && /nothing to do/.test(e.msg ?? '')));
  list.sort((a, b) => a.start.localeCompare(b.start));
  const gates = list.filter((r) => /^[a-z]+-\d{8}T?\d{4,6}Z?-\d+$/.test(r.run) && r.events.every((e) => ['precheck', 'heartbeat', 'dispatch', 'worklist'].includes(e.event)));
  for (const g of gates) {
    const s = list.find((r) => r !== g && r.job === g.job && !gates.includes(r) && r.start >= g.start && Date.parse(r.start) - Date.parse(g.end) < 180e3);
    if (s) { s.events = [...g.events, ...s.events]; s.start = g.start; s.gate = g.run; g.merged = true; }
  }
  list = list.filter((r) => !r.merged);
  return list.map((r, k) => {
    const ev = r.events, prs = new Set(), posted = [], aborted = [];
    let tok = null;
    for (const e of ev) {
      const m = /PR #(\d+)/.exec(e.msg ?? ''); if (m) prs.add(+m[1]);
      if (e.event === 'review_step') {
        const p = /PR #(\d+) \[(\w+)\] posted (\w+)/.exec(e.msg ?? ''); if (p) posted.push({ pr: +p[1], sha: p[2], verdict: p[3] });
        const a = /PR #(\d+) \[(\w+)\] aborted (.*)/.exec(e.msg ?? ''); if (a) aborted.push({ pr: +a[1], why: a[3] });
      }
      if (e.event === 'tokens') {
        const kv = Object.fromEntries(String(e.msg ?? '').split(/\s+/).map((x) => x.split('=')).filter((x) => x.length === 2));
        tok = { input: +kv.input || 0, output: +kv.output || 0, cache_read: +kv.cache_read || 0, cache_creation: +kv.cache_creation || 0, model: kv.model || null, secs: +kv.secs || null, subagents: +kv.subagents || 0 };
      }
    }
    const errors = ev.filter((e) => e.level === 'error'), warns = ev.filter((e) => e.level === 'warn');
    const quiet = now - Date.parse(r.end);
    const ended = ev.some((e) => /^(run_end|session_end)$/.test(e.event) || (e.event === 'review_step' && /\b(done|aborted)\b/.test(e.msg ?? ''))) || tok || quiet > 20 * 60e3;
    const state = !ended ? 'running' : errors.length ? 'fail' : warns.length || aborted.length ? 'look' : 'pass';
    return { id: `S-${k + 1}`, run: r.run, gate: r.gate ?? null, job: r.job, start: r.start, end: r.end, secs: Math.round((Date.parse(r.end) - Date.parse(r.start)) / 1000),
      state, prs: [...prs].sort((a, b) => a - b).slice(0, 40), posted, aborted, tokens: tok, cost_usd: usd(prices, tok), errors: errors.length, warns: warns.length,
      reviews: r.job === 'review' ? phasesOf(ev, state === 'running') : [],
      events: ev.slice(-160).map((e) => ({ ts: e.ts, level: e.level, event: e.event, msg: String(e.msg ?? '').slice(0, 400) })), count: ev.length };
  });
}

// The published pages and where each keeps its link (artifact.md, persistence.md).
function artifactsOf(work, prs) {
  const out = [];
  const marker = (text, name) => /<!-- ([a-z-]+)-dam: (\S+) -->/.exec(String(text ?? '').match(new RegExp(`<!-- ${name}-dam: \\S+ -->`))?.[0] ?? '')?.[2] ?? null;
  const page = (rel) => (mtime(join(work, rel)) ? rel : null);
  for (const p of prs) if (p.guide) out.push({ id: `guide:${p.n}`, kind: 'guide', title: 'Review guide', pr: p.n, dam: p.guide.id, url: p.guide.url, sha: p.guide.sha,
    utc: p.guide_utc ?? null, page: page(`reviews/pr-artifacts/pr-${p.n}.guide.html`), state: p.state === 'open' ? 'live' : 'closed' });
  const hs = json(read(join(work, 'health', 'state.json')));
  if (hs || mtime(join(work, 'health', 'dashboard.html'))) out.push({ id: 'health', kind: 'health', title: 'Health dashboard', dam: hs?.artifact_id ?? null, url: /^https:\/\//.test(hs?.share_url ?? '') ? hs.share_url : null,
    utc: hs?.published_at ?? null, error: hs?.last_error ?? null, page: page('health/dashboard.html'), state: hs?.last_error ? 'error' : 'live' });
  const mp = json(read(join(work, 'manifest-publish.json')));
  if (mp || mtime(join(work, 'manifest.json'))) out.push({ id: 'manifest', kind: 'manifest', title: 'Public interface card', dam: mp?.id ?? null, url: /^https:\/\//.test(mp?.shareUrl ?? '') ? mp.shareUrl : null,
    utc: mtime(join(work, 'manifest-publish.json')) ? new Date(mtime(join(work, 'manifest-publish.json'))).toISOString() : null, page: null, json: page('manifest.json'), state: 'live' });
  const one = (id, kind, title, rel, html) => { const t = read(join(work, rel)); if (t == null && !mtime(join(work, html))) return;
    out.push({ id, kind, title, dam: marker(t, kind === 'trends' ? 'audit-trend' : kind), url: null, utc: mtime(join(work, html)) ? new Date(mtime(join(work, html))).toISOString() : null, page: page(html), state: 'live' }); };
  one('trends', 'trends', 'Weekly trends', 'audit/TRENDS.md', 'audit/report.html');
  one('survey', 'survey', 'Security survey', 'survey/LEDGER.md', 'survey/report.html');
  one('benchmark', 'benchmark', 'Benchmark report', 'benchmark/RESULTS.md', 'benchmark/report.html');
  return out;
}

// What Code Guardian learned (preferences.md → Two layers, escapes.md): every rule line of MEMORY.md,
// of the area files work/memory/<topic>.md and of LESSONS.md, with its tag parsed, and the archive
// entry its `→ archive/<file>` names, read under the same tag.
const TAG_RE = /^- \[([^\]]{1,120})\] (.*)$/;
function archiveEntry(work, file, tag) {
  if (!/^[\w.-]{1,60}\.md$/.test(file ?? '')) return null;
  const text = String(read(join(work, 'memory', 'archive', file)) ?? ''); if (!text || !tag) return null;
  const ls = text.split('\n'), at = ls.findIndex((l) => /^#{1,4} /.test(l) && l.includes(tag)); if (at < 0) return null;
  const end = ls.findIndex((l, k) => k > at && /^#{1,4} /.test(l));
  return ls.slice(at + 1, end < 0 ? undefined : end).join('\n').trim().slice(0, 3000) || null;
}
function learningsOf(work) {
  const out = [];
  const take = (layer, file, text, scope) => {
    let sec = null;
    for (const l of String(text ?? '').split('\n')) {
      const h = /^## (.+)$/.exec(l); if (h) { sec = h[1].trim(); continue; }
      if (!/^- /.test(l) || out.length >= 400) continue;
      const m = TAG_RE.exec(l), tag = m?.[1] ?? null, body = (m?.[2] ?? l.slice(2)).trim();
      const ref = / → archive\/([\w.-]+\.md)\s*$/.exec(body);
      const from = tag ? (/^escape\b/.test(tag) ? 'escape' : /from ([^\],]+)/.exec(tag)?.[1]?.trim() ?? null) : null;
      out.push({ id: `L-${out.length + 1}`, layer, file, line: l.slice(0, 600), section: sec, scope, tag, date: tag?.match(/\d{4}-\d\d-\d\d/)?.[0] ?? null, from,
        pr: +(tag?.match(/PR #(\d+)/)?.[1] ?? body.match(/PR #(\d+)/)?.[1] ?? 0) || null, seen: +(tag?.match(/seen (\d+)×/)?.[1] ?? 0) || null,
        text: (ref ? body.slice(0, ref.index) : body).slice(0, 400), archive_ref: ref?.[1] ?? null, archive: ref ? archiveEntry(work, ref[1], tag) : null });
    }
  };
  take('memory', 'MEMORY.md', read(join(work, 'MEMORY.md')), null);
  for (const f of ls(join(work, 'memory')).filter((x) => /^[\w.-]+\.md$/.test(x)).sort()) {
    const t = String(read(join(work, 'memory', f)) ?? ''), fm = /^---\n([\s\S]*?)\n---/.exec(t)?.[1] ?? '';
    const scope = /(?:scope|paths):\s*\[([^\]]*)\]/.exec(fm)?.[1]?.split(',').map((x) => x.trim().replace(/^['"]|['"]$/g, '')).filter(Boolean) ?? [];
    take('area', `memory/${f}`, t.replace(/^---\n[\s\S]*?\n---/, ''), scope);
  }
  take('lessons', 'LESSONS.md', read(join(work, 'LESSONS.md')), null);
  return out;
}

const SEVERITY = { critical: 3, warning: 2, suggestion: 1 };

export function build(work, now = Date.now()) {
  const cfg = config(work);
  const repo = cfg.github_repo || null;
  // ------------------------------------------------ reviews and PRs
  const rows = new Map(tableRows(read(join(work, 'REVIEWS.md'))).filter(([n]) => /^\d+$/.test(n ?? '')).map(([n, sha, ts, verdict, status]) => [+n, { sha: dash(sha), ts: dash(ts), verdict: dash(verdict), status: dash(status) }]));
  const hist = new Map(ls(join(work, 'reviews')).map((f) => /^pr-(\d+)\.md$/.exec(f)).filter(Boolean).map((m) => [+m[1], history(read(join(work, 'reviews', m[0])))]));
  const ledger = jsonl(read(join(work, 'REVIEW-LEDGER.jsonl'))).filter((r) => Number.isInteger(r.pr) && ISO.test(r.ts ?? ''));
  const byKey = new Map();
  for (const r of ledger) byKey.set(`${r.pr}|${r.ts}`, { pr: r.pr, ts: r.ts, sha: r.sha ?? null, kind: r.kind ?? null, verdict: r.verdict ?? null, size: r.size ?? null, def: r.def ?? null, bullets: r.bullets ?? null, suppressed: r.suppressed ?? null, ste: r.ste ?? null, findings: Array.isArray(r.findings) ? r.findings : [], body: null, meta: null });
  for (const [pr, h] of hist) h.rounds.forEach((x, k) => {
    const key = `${pr}|${x.ts}`, had = byKey.get(key) ?? { pr, ts: x.ts, sha: x.sha, kind: k ? 're-review' : 'first', verdict: x.verdict, findings: [] };
    const f = findingsOf(x.body); if (f.length || !had.findings.length) had.findings = f.length ? f : had.findings;
    had.body = visible(x.body); had.meta = payload(x.body, 'review-meta'); had.guide_owed = x.guide_owed; had.verdict = had.verdict || x.verdict; byKey.set(key, had);
  });
  const reviews = [...byKey.values()].sort((a, b) => a.ts.localeCompare(b.ts) || a.pr - b.pr).map((r, k) => ({ id: `R-${k + 1}`, ...r, verdict: VERDICT_RE.test(r.verdict ?? '') ? r.verdict : 'COMMENT' }));
  const roundsOf = (n) => reviews.filter((r) => r.pr === n);

  // ------------------------------------------------ shepherd and PR events
  const shep = new Map(tableRows(read(join(work, 'SHEPHERD.md'))).filter(([n]) => /^\d+$/.test(n ?? '')).map(([n, since, reviewers, state, nudges, last, level, status]) =>
    [+n, { eligible_since: dash(since), reviewers: dash(reviewers)?.split(/[,\s]+/).filter(Boolean) ?? [], review_state: dash(state), nudges: +nudges || 0, last_nudge_at: dash(last), level: dash(level), status: dash(status) }]));
  const events = jsonl(read(join(work, 'PR-EVENTS.jsonl'))).filter((e) => Number.isInteger(e.pr) && ISO.test(e.ts ?? ''));

  // ------------------------------------------------ findings: one per pr+file+summary, over the rounds
  const fmap = new Map();
  for (const r of reviews) for (const f of r.findings) {
    if (!f.summary && !f.file) continue;
    const key = `${r.pr}|${f.file ?? ''}|${String(f.summary ?? '').toLowerCase().replace(/\s+/g, ' ').trim()}`;
    const x = fmap.get(key) ?? { key, pr: r.pr, file: f.file ?? null, line: f.line ?? null, summary: f.summary ?? '', fix: null, severity: f.severity ?? 'suggestion', also: [], first: r.ts, rounds: [] };
    x.rounds.push({ review: r.id, ts: r.ts, sha: r.sha, status: f.status ?? 'new' });
    x.last = r.ts; x.status = f.status ?? 'new'; x.line = f.line ?? x.line; if (f.fix) x.fix = f.fix; if (Array.isArray(f.also)) x.also = f.also.slice(0, 10);
    if ((SEVERITY[f.severity] ?? 0) > (SEVERITY[x.severity] ?? 0)) x.severity = f.severity;
    if (f.late) x.late = true; if (f.escape) x.escape = f.escape; if (typeof f.inline === 'boolean') x.inline = f.inline;
    fmap.set(key, x);
  }
  const lastReview = new Map(); for (const r of reviews) lastReview.set(r.pr, r);
  const open = (n) => rows.has(n);
  const learnings = learningsOf(work);
  const findings = [...fmap.values()].sort((a, b) => a.first.localeCompare(b.first) || a.key.localeCompare(b.key)).map((f, k) => {
    const lr = lastReview.get(f.pr), inLast = lr && f.rounds.at(-1).review === lr.id;
    const over = (hist.get(f.pr)?.overrides ?? []).find((o) => f.file && o.includes(`${f.file}${f.line ? `:${f.line}` : ''}`));
    const state = over ? 'dismissed' : f.status === 'fixed' ? 'fixed' : !inLast ? 'gone' : open(f.pr) ? 'open' : 'left';
    // The answers to it: a person's rule for this PR that names its file, and a learned rule (a dispute
    // resolution, a preference) that names its file or its PR.
    const answers = [
      ...(hist.get(f.pr)?.overrides ?? []).filter((o) => f.file && o.includes(f.file)).map((o) => { const m = TAG_RE.exec(`- ${o}`);
        return { kind: 'override', text: (m?.[2] ?? o).replace(/^Ignore:\s*/, '').slice(0, 400), date: m?.[1]?.match(/\d{4}-\d\d-\d\d/)?.[0] ?? null, from: /from ([^\],]+)/.exec(m?.[1] ?? '')?.[1]?.trim() ?? null, exact: o === over }; }),
      ...learnings.filter((l) => l.from !== 'escape' && ((f.file && l.text.includes(f.file)) || l.pr === f.pr)).map((l) => ({ kind: 'rule', id: l.id, text: l.text, date: l.date, from: l.from })),
    ].slice(0, 8);
    return { id: `F-${k + 1}`, ...f, state, override: over ?? null, answers };
  });

  // ------------------------------------------------ PRs: the open ones (a REVIEWS.md row) and the closed ones of the ledger
  const nums = new Set([...rows.keys(), ...hist.keys(), ...reviews.map((r) => r.pr)]);
  const prs = [...nums].map((n) => {
    const row = rows.get(n), h = hist.get(n), rs = roundsOf(n), last = rs.at(-1), fs = findings.filter((f) => f.pr === n);
    const ev = events.filter((e) => e.pr === n);
    const triage = last?.meta?.triage ?? null;
    return { n, title: h?.title ?? null, state: row ? 'open' : 'closed', sha: row?.sha ?? last?.sha ?? null, status: row?.status ?? null, verdict: row?.verdict && row.verdict !== '-' ? row.verdict : last?.verdict ?? null,
      utc: row?.ts ?? last?.ts ?? null, rounds: rs.length, reviews: rs.map((r) => r.id), first: rs[0]?.ts ?? null, guide: h?.guide ?? null, guide_owed: !!rs.at(-1)?.guide_owed,
      overrides: h?.overrides ?? [], shepherd: shep.get(n) ?? null, events: ev.slice(-40), triage,
      size: last?.size ?? null, open_findings: fs.filter((f) => f.state === 'open').length, blocking: fs.filter((f) => f.state === 'open' && f.severity !== 'suggestion').length,
      latency_h: ev.find((e) => e.kind === 'first_review')?.latency_hours ?? null,
      for_human: /### For the human reviewer\n([\s\S]*?)(?=\n### |$)/.exec(last?.body ?? '')?.[1]?.trim().slice(0, 4000) || null,
      // urgent (review-urgent.md): the Slack alert's marker, or a rapid review on the PR
      urgent: row ? (h?.urgent ?? (row.verdict === 'RAPID' || rs.some((r) => r.verdict === 'RAPID') ? row.ts ?? true : null)) : null };
  }).sort((a, b) => String(b.utc ?? '').localeCompare(String(a.utc ?? '')) || b.n - a.n);
  for (const p of prs) if (p.guide) { const r = reviews.filter((x) => x.pr === p.n && x.sha && p.guide.sha && p.guide.sha.startsWith(String(x.sha).slice(0, 7))).at(-1); p.guide_utc = r?.ts ?? null; }

  // ------------------------------------------------ runs, artifacts, health and the rest
  const prices = pricesOf(work);
  const runs = runsOf(work, now, prices);
  // What a finished review usually takes: each phase, each skill, the whole run and its cost — the
  // estimate a running review is drawn against.
  const doneRv = runs.filter((r) => r.job === 'review' && r.state !== 'running').slice(-40);
  const span = (a, b) => (a && b ? (Date.parse(b) - Date.parse(a)) / 1000 : NaN);
  const typical = { priced: prices.length > 0, phases: {}, skills: {}, secs: median(doneRv.filter((r) => r.posted.length).map((r) => r.secs)), cost_usd: median(doneRv.filter((r) => r.posted.length).map((r) => r.cost_usd ?? NaN)), runs: doneRv.length };
  for (const [key] of PHASES) typical.phases[key] = median(doneRv.flatMap((r) => r.reviews).flatMap((x) => x.phases.filter((p) => p.key === key && p.state === 'done').map((p) => span(p.start, p.end))));
  const names = new Set(doneRv.flatMap((r) => r.reviews.flatMap((x) => (x.skills ?? []).map((s) => s.name))));
  for (const n of names) typical.skills[n] = median(doneRv.flatMap((r) => r.reviews.flatMap((x) => (x.skills ?? []).filter((s) => s.name === n).map((s) => s.secs))));
  const artifacts = artifactsOf(work, prs);
  const since14 = new Date(now - 14 * 864e5).toISOString().slice(0, 13);
  const hours = jsonl(read(join(work, 'health', 'hours.jsonl'))).filter((h) => typeof h.h === 'string' && h.h >= since14);
  const mon = json(read(join(work, 'MONITOR.json')));
  // health.sh writes an incident's detail as an object of its counts and parts ({parts: ["automode-rules"]}): the page shows text
  const said = (v) => (Array.isArray(v) ? v.map(said).join(', ') : v && typeof v === 'object' ? Object.entries(v).map(([k, x]) => `${k} ${said(x)}`).join(', ') : String(v ?? ''));
  const detailText = (d) => (d == null || typeof d === 'string' ? d ?? null
    : Object.entries(d).filter(([, v]) => v != null).map(([k, v]) => `${{ pr: 'PR', prs: 'PRs' }[k] ?? k.replace(/_/g, ' ').replace(/^./, (c) => c.toUpperCase())}: ${said(v)}`).join('; ') || null);
  const health = { status: json(read(join(work, 'health', 'status.json'))),
    incidents: jsonl(read(join(work, 'health', 'incidents.jsonl'))).slice(-60).map((i) => ({ ...i, detail: detailText(i.detail) })),
    alerts: Object.entries(mon?.alerts ?? {}).map(([id, a]) => ({ id, kind: a?.kind ?? null, first: a?.first ?? null, claimed: a?.claimed ?? null, sent: a?.sent ?? null })), hours };
  const ticks = {};
  for (const l of String(read(join(work, 'HEARTBEAT.log')) ?? '').split('\n').slice(-6000)) {
    const m = /^(\d{4}-\d\d-\d\d)T\S+ (\w+) nothing_to_do=(\w+)/.exec(l); if (!m) continue;
    const d = (ticks[m[1]] ??= { day: m[1], idle: 0, work: 0 }); if (m[3] === 'true') d.idle++; else d.work++;
  }
  const weeks = ls(join(work, 'audit', 'weeks')).filter((f) => f.endsWith('.json')).sort().slice(-26).map((f) => json(read(join(work, 'audit', 'weeks', f)))).filter(Boolean)
    .map((w) => ({ week: w.week ?? null, ts: w.ts ?? null, version: w.definition_version ?? null, checks: w.checks ?? null, stats: w.stats ?? null }));
  const audit = String(read(join(work, 'AUDIT.log')) ?? '').split('\n').map((l) => /^(\S+) ok=(\d+) warn=(\d+) red=(\d+)/.exec(l)).filter(Boolean).map((m) => ({ ts: m[1], ok: +m[2], warn: +m[3], red: +m[4] })).slice(-26);
  // An escaped defect, with its report from the archive (escapes.md → step 4) and the class it taught.
  const escArchive = String(read(join(work, 'memory', 'archive', 'escapes.md')) ?? '');
  const escapes = jsonl(read(join(work, 'ESCAPES.jsonl'))).slice(-200).map((e, k) => {
    const cls = learnings.find((l) => l.from === 'escape' && ((e.pr && l.pr === e.pr) || (e.class && l.text.toLowerCase().includes(String(e.class).toLowerCase()))));
    let report = cls?.archive ?? null;
    if (!report && e.pr && escArchive) { const ls2 = escArchive.split('\n'), at = ls2.findIndex((l) => /^#{1,4} /.test(l) && l.includes(`PR #${e.pr}`)); if (at >= 0) { const end = ls2.findIndex((l, j) => j > at && /^#{1,4} /.test(l)); report = ls2.slice(at + 1, end < 0 ? undefined : end).join('\n').trim().slice(0, 3000) || null; } }
    return { id: `E-${k + 1}`, ...e, report, learned: cls?.id ?? null };
  });
  for (const f of findings) f.escapes = escapes.filter((e) => e.pr === f.pr && (!Array.isArray(e.paths) || !e.paths.length || (f.file && e.paths.includes(f.file)))).map((e) => e.id);
  const sch = json(read(join(work, 'health', 'schedules.json')));
  const schedules = (Array.isArray(sch) ? sch : sch?.schedules ?? sch?.list ?? []).filter((s) => s && typeof s.name === 'string')
    .map((s) => ({ name: s.name, cron: s.cron ?? s.schedule ?? null, enabled: s.enabled !== false, last: s.last_run ?? s.lastRun ?? null }));
  const shown = Object.fromEntries(Object.entries(cfg).filter(([k]) => CONFIG_SHOWN.test(k)));
  // What Code Guardian follows (MEMORY.md, preferences.md): each section's rule lines, as written.
  const memory = [];
  let sec = null;
  for (const l of String(read(join(work, 'MEMORY.md')) ?? '').split('\n')) {
    const h = /^## (.+)$/.exec(l); if (h) { sec = { name: h[1].trim(), rules: [] }; memory.push(sec); continue; }
    if (sec && /^- /.test(l) && sec.rules.length < 60) { const m = /^- \[(\d{4}-\d\d-\d\d)(?: from ([a-z-]+))?\] (.*)$/.exec(l); sec.rules.push(m ? { date: m[1], from: m[2] ?? null, text: m[3].slice(0, 300) } : { date: null, from: null, text: l.slice(2, 302) }); }
  }
  const data = { repo, repo_url: repo && /^[\w.-]+\/[\w.-]+$/.test(repo) ? `https://github.com/${repo}` : null, bot: cfg.bot_display_name || 'Code Guardian', version: String(read(join(work, 'VERSION')) ?? '').trim() || null,
    labels: { rereview: cfg.rereview_label || 'code-guardian:rereview', guide: cfg.guide_label || null },
    prs, reviews, findings, runs, review_typical: typical, settings: settingsOf(work), artifacts, health, ticks: Object.values(ticks).slice(-30), weeks, audit, escapes, schedules, config: shown, memory: memory.filter((s) => s.rules.length), learnings };
  data.hash = createHash('sha256').update(JSON.stringify(data)).digest('hex').slice(0, 16);
  return data;
}

// The files the data comes from: a change of any of them builds the data again.
export function sources(work) {
  const files = ['CONFIG.md', 'VERSION', 'MEMORY.md', 'REVIEWS.md', 'REVIEW-LEDGER.jsonl', 'SHEPHERD.md', 'PR-EVENTS.jsonl', 'MONITOR.json', 'HEARTBEAT.log', 'AUDIT.log', 'ESCAPES.jsonl',
    'manifest-publish.json', 'manifest.json', 'health/state.json', 'health/status.json', 'health/incidents.jsonl', 'health/hours.jsonl', 'health/schedules.json',
    'audit/TRENDS.md', 'survey/LEDGER.md', 'benchmark/RESULTS.md', 'LESSONS.md'];
  const dirs = ['reviews', 'logs', 'audit/weeks', 'reviews/pr-artifacts', 'memory', 'memory/archive'];
  return [...files.map((f) => join(work, f)), ...dirs.flatMap((d) => [join(work, d), ...ls(join(work, d)).map((f) => join(work, d, f))])];
}
