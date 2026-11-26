#!/usr/bin/env node
// Development only: writes a made-up work/ for the Desk (docs/desk.md → Development), so the page can be
// tuned on realistic amounts of data: about 26 pull requests, 60 reviews, 14 days of runs, health, the
// published pages. Dates are relative to now. Nothing here is real: the repository "acme/tasklane",
// its pull requests and people are invented.
//   node scripts/desk/dev/seed.mjs /tmp/cg-desk-work
//   WORK_DIR=/tmp/cg-desk-work node scripts/desk/dev/harness.mjs 5700 5699   → http://localhost:5700/
import { mkdirSync, rmSync, writeFileSync, appendFileSync } from 'node:fs';
import { join } from 'node:path';

const W = process.argv[2];
if (!W) { console.error('usage: seed.mjs <work dir>'); process.exit(2); }
rmSync(W, { recursive: true, force: true });
for (const d of ['reviews/pr-artifacts', 'logs', 'health', 'audit/weeks', 'survey', 'benchmark', 'desk']) mkdirSync(join(W, d), { recursive: true });

let seed = 11;
const rnd = () => ((seed = (seed * 16807) % 2147483647) / 2147483647);
const pick = (a) => a[Math.floor(rnd() * a.length)];
const NOW = Date.now(), MIN = 60e3, H = 60 * MIN, DAY = 24 * H;
const iso = (t) => new Date(t).toISOString().replace(/\.\d+Z$/, 'Z');
const hex = (n) => Array.from({ length: n }, () => '0123456789abcdef'[Math.floor(rnd() * 16)]).join('');
const put = (f, t) => writeFileSync(join(W, f), t);
const add = (f, t) => appendFileSync(join(W, f), t);

put('VERSION', '15.1.0\n');
put('CONFIG.md', `# Code Guardian configuration

- github_repo: acme/tasklane
- bot_display_name: Code Guardian
- definition_branch: main
- rereview_trigger: label
- rereview_label: code-guardian:rereview
- guide_label: code-guardian:guide
- approve_after_rounds: 3
- active_hours: 07-19
- active_days: 1-5
- review_interval_active: 5
- review_interval_quiet: 60
- log_level: info
- audit_trend: dam
- survey_report: dam
- benchmark_report: dam
- health_dashboard: dam
- agent_manifest: dam
- shepherd_enabled: true
`);
put('MEMORY.md', `# Memory

## Review Style

- [2026-09-02 from user] Keep the summary to three sentences.
- [2026-09-14 from user] Name the test that is missing, not only that one is missing.

## Focus Areas

- [2026-08-20 from user] Permission checks in \`api/projects/\` — every handler checks the member's role.
- [2026-10-03 from review] Date handling: tasks use UTC on the server, local time only in the view.

## Ignore List

- [2026-09-30 from user] Skip JSDoc findings on internal helpers.
- [2026-10-11 from user] Generated files under \`src/gen/\`.

## Custom Rules

- [2026-10-20 from user] A migration that drops a column needs a two-step deploy note.

## Escaped Defect Classes

- [2026-11-04 from escape] Missing pagination guard on list endpoints (E-2).
`);

// ------------------------------------------------ pull requests
const TITLES = ['Add due dates to tasks', 'Fix board drag on Safari', 'Invite members by link', 'Paginate the project list', 'Rename a project keeps its tasks',
  'Store files in object storage', 'Archive finished projects', 'Billing: show the plan in settings', 'Speed up the inbox query', 'Two-factor sign-in',
  'Export a board as CSV', 'Comment mentions notify people', 'Drop the legacy avatar column', 'Dark mode for the board', 'Retry failed webhooks',
  'Search tasks by label', 'Limit uploads to 25 MB', 'Members page shows pending invites', 'Recurring tasks', 'Audit log for admin actions',
  'Fix timezone of due dates', 'Bulk move tasks', 'Rate limit the public API', 'Keyboard shortcuts on the board', 'Remove unused feature flags', 'Upgrade the date library'];
const FILES = ['api/projects/handlers.ts', 'api/tasks/service.ts', 'web/board/Board.tsx', 'api/auth/session.ts', 'api/files/upload.ts', 'web/settings/Billing.tsx',
  'db/migrations/0042_drop_avatar.sql', 'api/inbox/query.ts', 'web/members/Invites.tsx', 'api/webhooks/retry.ts', 'api/search/labels.ts', 'lib/dates.ts'];
const FIND = [
  ['critical', 'token compared with == instead of a constant-time check', 'compare tokens with a constant-time equality helper'],
  ['critical', 'handler does not check the member role before it deletes a project', 'call requireRole(member, "admin") before the delete'],
  ['warning', 'list endpoint has no page size limit', 'cap the page size at 100 and validate the query parameter'],
  ['warning', 'due date is stored in local time', 'convert the date to UTC before the insert'],
  ['warning', 'retry loop has no backoff', 'add an exponential backoff with a cap of 5 tries'],
  ['warning', 'upload size is checked after the file is read into memory', 'check Content-Length before the body is read'],
  ['warning', 'migration drops a column that the old release still reads', 'split the change: stop the reads first, drop the column in the next deploy'],
  ['suggestion', 'the new query is not covered by a test', null],
  ['suggestion', 'the error message does not tell the user what to do', null],
  ['suggestion', 'duplicate date formatting helper', null],
];
const PEOPLE = ['jnovak', 'pkral', 'eva-s', 'mdvorak', 'tomas-b'];
const prs = TITLES.map((title, k) => ({ n: 1180 + k * 3 + Math.floor(rnd() * 3), title, author: pick(PEOPLE), open: k >= 10, opened: NOW - (25 - k) * 0.55 * DAY - rnd() * 6 * H }));
const reviewsRows = [], ledger = [], prEvents = [], shepherd = [], guides = [];
let rcount = 0;
for (const pr of prs) {
  const roundsN = pr.open ? 1 + Math.floor(rnd() * 3) : 1 + Math.floor(rnd() * 3);
  let t = pr.opened + (8 + rnd() * 50) * MIN;
  prEvents.push({ pr: pr.n, kind: 'first_review', ts: iso(t), latency_hours: +((t - pr.opened) / H).toFixed(2), eligible_since: iso(pr.opened) });
  const open = [];
  const pool = FIND.slice().sort(() => rnd() - 0.5).slice(0, Math.floor(rnd() * 4));
  const fileOf = new Map(pool.map((f) => [f, pick(FILES)]));
  let history = `# PR #${pr.n}: ${pr.title}\n`;
  const sections = [];
  let verdict = 'COMMENT', sha = hex(40);
  for (let r = 0; r < roundsN; r++) {
    if (t > NOW - 20 * MIN) break;
    const last = r === roundsN - 1;
    const fs = [];
    for (const f of pool) {
      const was = open.includes(f);
      const fixed = r > 0 && (last ? rnd() < 0.75 : rnd() < 0.4);
      if (r === 0) { fs.push({ status: 'new', f }); open.push(f); }
      else if (was && fixed) { fs.push({ status: 'fixed', f }); open.splice(open.indexOf(f), 1); }
      else if (was) fs.push({ status: 'still', f });
    }
    if (r > 0 && rnd() < 0.25) { const f = pick(FIND.filter((x) => !pool.includes(x))); pool.push(f); fileOf.set(f, pick(FILES)); open.push(f); fs.push({ status: 'new', f, late: rnd() < 0.5 }); }
    const blocking = open.filter((f) => f[0] !== 'suggestion').length;
    verdict = blocking ? 'REQUEST_CHANGES' : open.length ? 'COMMENT' : 'APPROVE';
    if (r + 1 >= 3 && !blocking) verdict = 'APPROVE';
    sha = hex(40);
    const fj = fs.map(({ status, f, late }) => ({ status, severity: f[0], file: fileOf.get(f), line: 10 + Math.floor(rnd() * 200), inline: status !== 'fixed', summary: f[1], fix: status === 'fixed' || f[0] === 'suggestion' ? null : f[2], ...(late ? { late: true } : {}) }));
    const triage = { class: blocking || rnd() < 0.4 ? 'needs-human' : 'quick-check', why: blocking ? 'a blocking finding is open' : 'small change with tests', verified: true, minutes: 5 + Math.floor(rnd() * 25) };
    const body = `## PR #${pr.n}: ${pr.title}\n\n### Summary\n\nThe change ${pr.title.toLowerCase()}. ${blocking ? `${blocking} finding${blocking === 1 ? '' : 's'} must be fixed before merge.` : 'No blocking finding is open.'}\n\n`
      + (r ? `### Changes since last review\n\n- ${fs.filter((x) => x.status === 'fixed').length} fixed, ${fs.filter((x) => x.status === 'still').length} still open\n\n` : '')
      + `### Findings\n\n${fs.length ? fs.map(({ status, f }) => `- ${status === 'fixed' ? '✅ Fixed' : f[0] === 'critical' ? '🔴' : f[0] === 'warning' ? '🟡' : '🟢'} **${f[1]}** — \`${fileOf.get(f)}\`${f[2] && status !== 'fixed' ? `\n  Fix: ${f[2]}.` : ''}`).join('\n') : 'No findings.'}\n\n### Verdict\n\n${verdict}\n\n### For the human reviewer\n\nLook at the error paths in \`${pick(FILES)}\`.\n\n`
      + `<!-- findings-json: ${JSON.stringify(fj)} -->\n<!-- review-meta: ${JSON.stringify({ diff_digest: hex(12), checks: fj.slice(0, 2).map((x) => ({ for: x.summary, run: `git grep -n ${x.file.split('/').pop()}`, clean: 'no hits' })), deferred: [], triage })} -->\n<!-- code-guardian headRefOid=${sha} -->`;
    sections.push(`## Review at ${sha.slice(0, 7)} — ${iso(t)} — ${verdict}\n\n${body}\n\n---\n`);
    ledger.push({ src: 'ledger', pr: pr.n, ts: iso(t), sha: sha.slice(0, 7), kind: r ? 're-review' : 'first', verdict, size: { files: 2 + Math.floor(rnd() * 12), additions: 20 + Math.floor(rnd() * 400), deletions: Math.floor(rnd() * 120) }, def: '15.1.0',
      bullets: { fixed: fs.filter((x) => x.status === 'fixed').length, still: fs.filter((x) => x.status === 'still').length }, suppressed: { overrides: 0, context: 0, decisions: 0, total: 0 },
      ste: { sentences: 9, avg_sentence_words: 12.4, sentences_over_20: 0, v: 2 }, findings: fj.map(({ status, severity, file, line, summary, late }) => ({ status, severity, file, line, summary, ...(late ? { late } : {}) })) });
    pr.last = { t, verdict, sha, triage }; rcount++;
    t += (3 + rnd() * 20) * H;
  }
  if (rnd() < 0.55) { const s = pr.last.sha.slice(0, 7); guides.push(pr); history += `<!-- artifact-guide: dam-${hex(8)} ${s} https://dam.example.com/a/${hex(10)} -->\n`;
    put(`reviews/pr-artifacts/pr-${pr.n}.guide.html`, `<!doctype html><html><head><meta charset="utf-8"><title>Guide #${pr.n}</title><style>body{font:15px/1.5 system-ui;margin:32px;max-width:760px;color:#222}h1{font-size:22px}.c{padding:12px 16px;border-left:4px solid #4a47b8;background:#f3f2fd;border-radius:6px;margin:12px 0}</style></head><body><h1>Review guide — #${pr.n} ${pr.title}</h1><p>Where to start and what matters in this change.</p><div class="c"><b>1. The entry point</b><br>Start in <code>${pick(FILES)}</code>: it decides who may do the action.</div><div class="c"><b>2. The data</b><br>The new column and its migration.</div><div class="c"><b>3. The tests</b><br>What they prove, and the path they miss.</div></body></html>`); }
  history += `\n## PR-local overrides\n\n${rnd() < 0.15 ? `- [2026-11-10 from user] Ignore: ${pool[0] ? `\`${fileOf.get(pool[0])}:12\`` : 'nothing'} — confirmed intentional\n` : ''}\n` + sections.join('\n');
  if (pr.open) put(`reviews/pr-${pr.n}.md`, history);
  if (pr.open) reviewsRows.push(`| ${pr.n} | ${pr.last.sha} | ${iso(pr.last.t)} | ${pr.last.verdict} | ${pr.n % 7 === 0 ? 'awaiting_label' : 'done'} |`);
  if (pr.open && pr.last.verdict !== 'APPROVE') {
    const nudges = Math.floor(rnd() * 3);
    shepherd.push(`| ${pr.n} | ${iso(pr.opened)} | ${pick(PEOPLE)},${pick(PEOPLE)} | ${pick(['waiting', 'commented', 'none'])} | ${nudges} | ${nudges ? iso(NOW - rnd() * DAY) : '-'} | ${nudges ? 'reminder' : '-'} | open |`);
    for (let k = 0; k < nudges; k++) prEvents.push({ pr: pr.n, kind: "nudged", ts: iso(NOW - rnd() * Math.min(2 * DAY, NOW - pr.opened - H)), level: "reminder" });
  }
}
// One PR the agent reviews right now.
const busy = prs.at(-1);
reviewsRows.push(`| ${busy.n + 40} | ${hex(40)} | ${iso(NOW - 6 * MIN)} | - | in_progress |`);
put(`reviews/pr-${busy.n + 40}.md`, `# PR #${busy.n + 40}: Show task count on the project card\n\n## PR-local overrides\n\n`);
put('REVIEWS.md', `| PR | Commit | Timestamp | Verdict | Status |\n| --- | --- | --- | --- | --- |\n${reviewsRows.join('\n')}\n`);
put('REVIEW-LEDGER.jsonl', ledger.map((r) => JSON.stringify(r)).join('\n') + '\n');
put('PR-EVENTS.jsonl', prEvents.sort((a, b) => a.ts.localeCompare(b.ts)).map((r) => JSON.stringify(r)).join('\n') + '\n');
put('SHEPHERD.md', `| PR | eligible_since | reviewers | review_state | nudges | last_nudge_at | level | status |\n| --- | --- | --- | --- | --- | --- | --- | --- |\n${shepherd.join('\n')}\n`);

// ------------------------------------------------ the event log: 14 days of runs
const ev = (t, run, job, level, event, msg) => add(`logs/events-${iso(t).slice(0, 10)}.jsonl`, JSON.stringify({ ts: iso(t), run, job, level, event, msg }) + '\n');
const tok = (t, run, job, k) => ev(t, run, job, 'info', 'tokens', `input=${Math.round(k * 40000)} output=${Math.round(k * 6000)} cache_read=${Math.round(k * 900000)} cache_creation=${Math.round(k * 30000)} msgs=${Math.round(k * 40)} model=claude-opus-5-5 subagents=${Math.round(k * 3)} secs=${Math.round(k * 400)}`);
let hb = '';
for (const r of ledger) {
  const t = Date.parse(r.ts) - (6 + rnd() * 10) * MIN; if (t < NOW - 14 * DAY) continue;
  const stamp = iso(t).replace(/[-:]/g, '').replace(/Z$/, 'Z'), gate = `review-${stamp}-${1000 + Math.floor(rnd() * 9000)}`, sess = `sess-${hex(12)}`;
  ev(t, gate, 'review', 'info', 'precheck', `review gate: 1 PR to review (#${r.pr})`);
  ev(t + 20e3, sess, 'review', 'info', 'review_step', `PR #${r.pr} [${r.sha}] locked`);
  ev(t + 60e3, sess, 'review', 'info', 'review_step', `PR #${r.pr} [${r.sha}] cloned`);
  ev(t + 3 * MIN, sess, 'review', 'info', 'review_step', `PR #${r.pr} [${r.sha}] fanned out (n=4)`);
  if (rnd() < 0.08) ev(t + 5 * MIN, sess, 'review', 'warn', 'tool_failure', 'gh api returned 502 once; retried');
  ev(Date.parse(r.ts), sess, 'review', 'info', 'review_step', `PR #${r.pr} [${r.sha}] posted ${r.verdict}`);
  ev(Date.parse(r.ts) + 20e3, sess, 'review', 'info', 'review_step', `PR #${r.pr} [${r.sha}] done`);
  tok(Date.parse(r.ts) + 30e3, sess, 'review', 0.6 + rnd());
  hb += `${iso(t)} review nothing_to_do=false prs=${r.pr}\n`;
}
for (let d = 13; d >= 0; d--) {
  for (let q = 0; q < 96; q++) { const t = NOW - d * DAY - q * 15 * MIN; if (t > NOW) continue;
    hb += `${iso(t)} monitor nothing_to_do=${rnd() < 0.93}\n`; hb += `${iso(t + 5 * MIN)} review nothing_to_do=true\n`; }
  for (let k = 0; k < 4; k++) { const t = NOW - d * DAY - k * 6 * H - 2 * H; if (t > NOW) continue; const run = `sess-${hex(12)}`;
    ev(t, run, 'monitor', 'info', 'health', 'tick: services ok');
    if (d === 2 && k === 1) { ev(t + 30e3, run, 'monitor', 'error', 'api_failure', 'model provider answered 529 three times'); ev(t + 40e3, run, 'monitor', 'warn', 'monitor_direct', 'alert model_down sent to the owner'); }
    tok(t + 60e3, run, 'monitor', 0.05); }
  if (d % 7 === 3) { const t = NOW - d * DAY - 5 * H, run = `sess-${hex(12)}`; ev(t, run, 'audit', 'info', 'heartbeat', 'audit start'); ev(t + 30 * MIN, run, 'audit', 'warn', 'audit', 'check 23 warn: fan-out took 41 min'); ev(t + 40 * MIN, run, 'audit', 'info', 'audit', 'weekly report posted to Slack'); tok(t + 41 * MIN, run, 'audit', 2.4); }
  if (d < 12 && d % 1 === 0 && new Date(NOW - d * DAY).getUTCDay() % 6 !== 0) { const t = NOW - d * DAY - 9 * H, run = `sess-${hex(12)}`; ev(t, run, 'shepherd', 'info', 'heartbeat', 'shepherd sweep: 6 open PRs, 2 nudges due'); ev(t + 3 * MIN, run, 'shepherd', 'info', 'nudge', 'nudged 2 reviewers on Slack'); tok(t + 4 * MIN, run, 'shepherd', 0.2); }
}
{ const t = NOW - 3 * DAY - 4 * H, run = `sess-${hex(12)}`; ev(t, run, 'survey', 'info', 'heartbeat', 'survey: area api/auth'); ev(t + 25 * MIN, run, 'survey', 'info', 'survey', 'pass 3: 1 🔴 · 2 🟡 · 4 🟢'); tok(t + 26 * MIN, run, 'survey', 1.8); }
{ const t = NOW - 1 * DAY - 7 * H, run = `sess-${hex(12)}`; ev(t, run, 'review', 'info', 'review_step', `PR #${prs[14].n} [${hex(7)}] locked`); ev(t + 4 * MIN, run, 'review', 'error', 'classifier_block', 'the classifier refused a git command; review aborted'); ev(t + 5 * MIN, run, 'review', 'info', 'review_step', `PR #${prs[14].n} [${hex(7)}] aborted classifier refusal`); }
// The run that works now.
{ const t = NOW - 6 * MIN, run = `sess-${hex(12)}`; ev(t, run, 'review', 'info', 'review_step', `PR #${busy.n + 40} [${hex(7)}] locked`); ev(t + 2 * MIN, run, 'review', 'info', 'review_step', `PR #${busy.n + 40} [${hex(7)}] fanned out (n=4)`); }
put('HEARTBEAT.log', hb.split('\n').sort().join('\n') + '\n');

// ------------------------------------------------ health
let hours = '';
for (let h = 14 * 24; h >= 0; h--) { const t = new Date(NOW - h * H); const bad = h > 50 && h < 54;
  hours += JSON.stringify({ h: iso(t).slice(0, 13), gate: 12, gate_err: bad ? 3 : 0, sessions: Math.floor(rnd() * 4), reviews: Math.floor(rnd() * 3), model_fail: bad ? 4 : 0, gh_fail: 0, gh_warn: rnd() < 0.05 ? 1 : 0, classifier: 0, tool_fail: 0, errors: bad ? 3 : 0, warns: Math.floor(rnd() * 2), top_errors: [], pod_boots: 0, backup_err: 0, direct_sent: bad ? 1 : 0, direct_fail: 0 }) + '\n'; }
put('health/hours.jsonl', hours);
put('health/incidents.jsonl', [
  { id: 'I-7', kind: 'model_down', first: iso(NOW - 53 * H), last_seen: iso(NOW - 51 * H), open: false, end: iso(NOW - 50 * H), detail: 'The model provider answered 529 for 3 hours.' },
  { id: 'I-8', kind: 'classifier_refusal', first: iso(NOW - 31 * H), last_seen: iso(NOW - 31 * H), open: false, end: iso(NOW - 30 * H), detail: 'One review stopped on a refused git command.' },
  { id: 'I-9', kind: 'github_slow', first: iso(NOW - 2 * H), last_seen: iso(NOW - 20 * MIN), open: true, end: null, detail: 'GitHub API answers take 4–9 s.' },
].map((x) => JSON.stringify(x)).join('\n') + '\n');
put('health/status.json', JSON.stringify({ ts: iso(NOW - 4 * MIN), tokens_adapter: 'claude-code', services: [
  { key: 'platform', name: 'Platform', state: 'ok', note: 'schedules fire on time' }, { key: 'harness', name: 'Harness', state: 'ok', note: 'claude-code' },
  { key: 'model', name: 'Model', state: 'ok', note: 'claude-opus-5-5' }, { key: 'github', name: 'GitHub', state: 'warn', note: 'API slow: 4–9 s' },
  { key: 'classifier', name: 'Classifier', state: 'ok', note: '' }, { key: 'backup', name: 'Backup', state: 'ok', note: 'last push 38 min ago' }, { key: 'slack', name: 'Slack', state: 'ok', note: '' }], sig: hex(8) }));
put('health/state.json', JSON.stringify({ artifact_id: `dam-${hex(8)}`, share_url: `https://dam.example.com/a/${hex(10)}`, published_at: iso(NOW - 15 * MIN), status_sig: hex(8) }));
put('health/dashboard.html', `<!doctype html><html><head><meta charset="utf-8"><style>body{font:14px system-ui;margin:24px}td{padding:4px 12px}.ok{color:#1f7a4d}.warn{color:#9a6200}</style></head><body><h2>Code Guardian — health</h2><table><tr><td>Model</td><td class="ok">ok</td></tr><tr><td>GitHub</td><td class="warn">slow</td></tr><tr><td>Backup</td><td class="ok">ok</td></tr></table></body></html>`);
put('health/schedules.json', JSON.stringify([
  { name: 'code-guardian-review-active', cron: '*/5 * * * *', enabled: true }, { name: 'code-guardian-monitor-15m', cron: '*/15 * * * *', enabled: true },
  { name: 'code-guardian-shepherd-1h-workdays', cron: '0 7-18 * * 1-5', enabled: true }, { name: 'code-guardian-audit-weekly', cron: '0 7 * * 5', enabled: true },
  { name: 'code-guardian-survey-weekly', cron: '30 3 * * 6', enabled: true }, { name: 'code-guardian-brief-daily', cron: '0 6 * * 1-5', enabled: false }]));
put('MONITOR.json', JSON.stringify({ alerts: { 'github_slow:2026': { kind: 'github_slow', first: iso(NOW - 2 * H), claimed: null, sent: iso(NOW - 110 * MIN) } }, direct: [] }));

// ------------------------------------------------ audit, escapes, the other pages
for (let w = 12; w >= 1; w--) { const t = NOW - w * 7 * DAY; const wk = `2026-W${String(48 - w).padStart(2, '0')}`;
  put(`audit/weeks/${iso(t).replace(/:/g, '')}.json`, JSON.stringify({ ts: iso(t), week: wk, since: iso(t - 7 * DAY), source: 'audit', definition_version: `14.${12 - w}.0`,
    stats: { reviews: { total: 18 + Math.floor(rnd() * 14), approve: 6 + Math.floor(rnd() * 6), request_changes: 5 + Math.floor(rnd() * 5) }, findings: { critical: Math.floor(rnd() * 4), warning: 6 + Math.floor(rnd() * 8), acceptance: +(0.6 + rnd() * 0.3).toFixed(2) }, tokens: { cost_usd: +(18 + rnd() * 20).toFixed(2) } },
    checks: { ok: 30 + Math.floor(rnd() * 4), warn: Math.floor(rnd() * 3), fail: w === 5 ? 1 : 0 } })); }
put('AUDIT.log', `${iso(NOW - 4 * DAY)} ok=33 warn=2 red=0 sent=slack\n`);
put('audit/TRENDS.md', `# Trends\n<!-- audit-trend-dam: dam-${hex(8)} -->\n`);
put('audit/report.html', `<!doctype html><html><head><meta charset="utf-8"><style>body{font:14px system-ui;margin:24px}</style></head><body><h2>Weekly trends</h2><p>Reviews per week stay between 18 and 31. Acceptance of findings went up from 61 % to 82 %.</p></body></html>`);
put('survey/LEDGER.md', `| area | path | last_surveyed | passes | findings |\n| --- | --- | --- | --- | --- |\n| auth | api/auth | ${iso(NOW - 3 * DAY)} | 3 | 7 |\n<!-- survey-dam: dam-${hex(8)} -->\n`);
put('survey/report.html', `<!doctype html><html><head><meta charset="utf-8"><style>body{font:14px system-ui;margin:24px}</style></head><body><h2>Security survey — api/auth</h2><p>🔴 1 · 🟡 2 · 🟢 4. The session cookie is not marked Secure on the staging host.</p></body></html>`);
put('benchmark/RESULTS.md', `| ts | model | version | fixture | trigger | f1 | sev | fixed | new | words | sec | out-tok |\n| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |\n| ${iso(NOW - 9 * DAY)} | claude-opus-5-5 | 15.0.0 | core | manual | 0.71 | 0.82 | 0.9 | 0.6 | 410 | 512 | 9100 |\n<!-- benchmark-dam: dam-${hex(8)} -->\n`);
put('manifest.json', JSON.stringify({ name: 'Code Guardian', version: '15.1.0' }));
put('manifest-publish.json', JSON.stringify({ id: `dam-${hex(8)}`, shareUrl: `https://dam.example.com/a/${hex(10)}` }));
put('ESCAPES.jsonl', [
  { key: 'e1', env: 'production', source: 'slack', pr: prs[3].n, confidence: 'high', review: 'missed', class: 'missing pagination guard', rule: 'list endpoints cap the page size', recurrence: 1, paths: ['api/projects/handlers.ts'], at: iso(NOW - 6 * DAY), note: 'The project list timed out for a large customer.' },
  { key: 'e2', env: 'staging', source: 'slack', pr: prs[6].n, confidence: 'medium', review: 'found-not-fixed', class: 'timezone of stored dates', rule: 'store dates in UTC', recurrence: 2, paths: ['lib/dates.ts'], at: iso(NOW - 2 * DAY), note: 'Due dates moved by one day for users in UTC-5.' },
].map((x) => JSON.stringify(x)).join('\n') + '\n');
put('desk/artifact.url', 'https://dam.example.com/a/desk-demo\n');
console.log(`${W}: ${prs.length} PRs, ${rcount} reviews, ${guides.length} guides`);
