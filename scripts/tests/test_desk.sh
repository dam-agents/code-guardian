#!/usr/bin/env bash
# The Desk (docs/desk.md): the data built from a seeded work/, the server's caller check, roles and
# command set, a job's way from the press to the bell, a question's answer, and the page's command
# set read by the server. Without Node the case reports a skip; CI installs one.
. "$(dirname "$0")/helpers.sh"

new_case desk
if ! command -v node >/dev/null 2>&1; then
  printf 'ok   %s: skipped — no Node\n' "$CASE"
  finish
fi
node "$REPO_ROOT/scripts/desk/dev/seed.mjs" "$WORK" >/dev/null || { printf 'FAIL %s: seed.mjs failed\n' "$CASE"; FAILED=1; finish; }

cat > "$SANDBOX/data.mjs" <<'EOF'
import { execFileSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
const R = process.env.REPO_ROOT, W = process.env.WORK_DIR;
const { build } = await import(join(R, 'scripts/desk/data.mjs'));
const say = (ok, what) => console.log(`${ok ? 'ok  ' : 'FAIL'} desk: ${what}`);
const d = build(W);
say(d.prs.length > 20 && d.reviews.length > 20 && d.findings.length > 5, 'the data has pull requests, reviews and findings');
say(d.reviews.every((r, k) => r.id === `R-${k + 1}`) && d.findings.every((f) => /^F-\d+$/.test(f.id)), 'reviews and findings are numbered in order');
say(d.prs.some((p) => p.status === 'in_progress') && d.runs.some((r) => r.state === 'running'), 'the PR in review and its run show as working');
{ const busy = d.prs.find((p) => p.status === 'in_progress'), live = d.runs.find((r) => r.state === 'running' && r.reviews.some((x) => x.pr === busy?.n));
  say(!!live && live.job === 'review' && live.reviews.find((x) => x.pr === busy.n).phases.length > 0, 'a review whose events name no job is a review run with its phases'); }
say(d.findings.some((f) => f.state === 'fixed') && d.findings.some((f) => f.state === 'open'), 'a finding is followed to fixed over its rounds');
say(d.artifacts.some((a) => a.kind === 'guide' && a.page) && d.artifacts.some((a) => a.id === 'health' && /^https:/.test(a.url)), 'the guides and the health dashboard are pages');
say(!JSON.stringify(d.config).includes('@'), 'the settings name no person');
say(d.health.incidents.every((i) => i.detail === null || typeof i.detail === 'string') && d.health.incidents.some((i) => i.detail === 'Parts: automode-rules'), "an incident's detail object from health.sh is text");
say(d.learnings.some((l) => l.layer === 'memory') && d.learnings.some((l) => l.layer === 'area' && l.scope.length) && d.learnings.some((l) => l.layer === 'lessons') && d.learnings.some((l) => l.archive), 'the learnings come from every layer, with their story from the archive');
say(d.escapes.every((e) => e.learned && e.report) && d.findings.some((f) => f.escapes.length), 'an escape has its report and its class, and pairs with its finding');
say(d.findings.some((f) => f.answers.some((a) => a.kind === 'rule')) && d.findings.some((f) => f.answers.some((a) => a.kind === 'override')), "a finding shows the person's rule and the learned rule that answer it");
EOF
OUT="$(WORK_DIR="$WORK" REPO_ROOT="$REPO_ROOT" node "$SANDBOX/data.mjs" 2>>"$STDERR_LOG")"
printf '%s\n' "$OUT"
grep -q '^FAIL' <<<"$OUT" && FAILED=1

# The routes, on a fixed free port so the server's loopback host check holds.
PORT="$(node -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')"
WORK_DIR="$WORK" CG_DESK_PORT="$PORT" node "$REPO_ROOT/scripts/desk/server.mjs" 2>>"$STDERR_LOG" &
SRV=$!
for _ in $(seq 50); do curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break; sleep 0.1; done
cat > "$SANDBOX/routes.mjs" <<'EOF'
import { execFileSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
const P = process.env.PORT, W = process.env.WORK_DIR, R = process.env.REPO_ROOT;
const say = (ok, what) => console.log(`${ok ? 'ok  ' : 'FAIL'} desk: ${what}`);
const call = async (method, path, body, role = 'owner', email = 'own@example.com', sub = '') => {
  const r = await fetch(`http://127.0.0.1:${P}${path}`, { method, body: body ? JSON.stringify(body) : undefined,
    headers: { 'content-type': 'application/json', ...(role ? { 'x-platform-caller-role': role, ...(email ? { 'x-platform-caller-email': email } : {}), ...(sub ? { 'x-platform-caller-sub': sub } : {}) } : {}) } });
  return { status: r.status, body: await r.json() };
};
const cli = (...a) => execFileSync('node', [join(R, 'scripts/desk/jobs.mjs'), ...a], { env: { ...process.env, WORK_DIR: W }, encoding: 'utf8' });
let r = await call('GET', '/api/me', null, null);
say(r.status === 401, "a request without the relay's caller is refused");
r = await call('GET', '/api/me');
say(r.body.role === 'admin' && r.body.owner === true, 'the owner is an admin');
r = await call('GET', '/api/data');
const hash = r.body.hash;
say(r.status === 200 && r.body.data.prs.length > 20, 'the data comes');
say(r.body.data.runs.every((x) => x.events === null) && r.body.data.reviews.every((x) => x.body === null), 'the data leaves out review text and run steps');
const rid = r.body.data.reviews.find((x) => x.has_body)?.id, sid = r.body.data.runs.at(-1).id;
r = await call('GET', `/api/reviews/${rid}`);
const r2 = await call('GET', `/api/runs/${sid}`);
say(r.status === 200 && r.body.body.length > 20 && r2.status === 200 && r2.body.events.length > 0, 'a review\'s text and a run\'s steps come on their own routes');
r = await call('GET', `/api/data?have=${hash}`);
say(r.body.unchanged === true, 'unchanged data is not sent again');
r = await call('POST', '/api/jobs', { command: 'rm -rf /' });
say(r.status === 400, 'a command outside the page\'s set is refused');
r = await call('POST', '/api/jobs', { command: 'review #1234' }, 'viewer', 'pat@example.com');
say(r.status === 403, 'a viewer gives no work');
r = await call('POST', '/api/people', { email: 'dev@example.com', role: 'developer' });
r = await call('POST', '/api/jobs', { command: 'run audit now' }, 'viewer', 'dev@example.com');
say(r.status === 403, 'a developer does not start an admin\'s run');
r = await call('POST', '/api/jobs', { command: 're-review #1234', label: 'Review again', item: '#1234' }, 'viewer', 'dev@example.com');
say(r.status === 201 && r.body.ping === `do desk job ${r.body.id}`, 'a developer\'s press is a job with its ping');
const id = r.body.id;
const show = JSON.parse(cli('show', id));
say(show.role === 'developer' && show.may === true && !JSON.stringify(show).includes('@'), 'the agent sees the role, never the email');
cli('start', id); writeFileSync(join(W, 'done.txt'), 'Round 2 is posted.'); cli('done', id, join(W, 'done.txt'));
r = await call('GET', '/api/notifications', null, 'viewer', 'dev@example.com');
say(r.body.unread_mine === 1 && r.body.notifications.some((n) => n.mine && /^Done/.test(n.title) && n.who === 'you'), 'the end of the job comes to the bell, as yours');
r = await call('POST', '/api/asks', { text: 'Why changes?', context: { tab: 'prs', item: '#1234' } }, 'viewer', 'pat@example.com');
say(r.status === 201 && r.body.ping === 'answer desk question A-1' && r.body.ping_conversation === 'item.pr-1234', 'a question goes to the page\'s own session');
cli('answer', 'A-1', join(W, 'done.txt'));
r = await call('GET', '/api/asks', null, 'viewer', 'pat@example.com');
say(r.body.asks[0]?.answer?.text === 'Round 2 is posted.', 'the answer comes back to the asker');
r = await call('GET', '/api/asks', null, 'viewer', 'other@example.com');
say(r.body.asks.length === 0, 'another person does not see the question');
r = await call('POST', '/api/asks', { text: 'What does the guide say?', context: { tab: 'pages', item: 'page:guide:1234', pr: 1234, review: 'R-7', guide: 'reviews/pr-artifacts/pr-1234.guide.html' } }, 'viewer', 'pat@example.com');
let q = JSON.parse(cli('ask', r.body.id)).context;
say(q.pr === 1234 && q.review === 'R-7' && q.guide === 'reviews/pr-artifacts/pr-1234.guide.html', 'a question on a guide names its PR, its review and the guide');
r = await call('POST', '/api/asks', { text: 'And now?', context: { tab: 'pages', pr: '1234', review: 'R-7; rm', guide: '../CONFIG.md' } }, 'viewer', 'pat@example.com');
q = JSON.parse(cli('ask', r.body.id)).context;
say(q.pr === null && q.review === null && q.guide === null, 'a PR, review or guide not in its form is left out');
r = await call('POST', '/api/asks', { text: 'Who am I?', context: { tab: 'prs' } }, 'viewer', '', 'sub-123');
r = await call('GET', '/api/asks', null, 'viewer', '', 'sub-123');
const r3 = await call('GET', '/api/asks', null, 'viewer', '', 'sub-456');
say(r.body.asks.length === 1 && r3.body.asks.length === 0, 'a caller without an email keeps their own questions');
r = await call('GET', '/api/artifacts/health/page');
say(r.status === 200 && /<html/i.test(r.body.html), 'a page\'s local copy is served');
r = await call('POST', '/api/settings', { key: 'ci_triage', value: 'enabled' }, 'viewer', 'dev@example.com');
say(r.status === 403, 'only the owner changes a setting');
r = await call('POST', '/api/settings', { key: 'github_repo', value: 'evil/repo' });
say(r.status === 400, 'a key outside the Settings table is refused');
r = await call('POST', '/api/settings', { key: 'auto_merge_max_lines', value: '99999' });
say(r.status === 400, 'a value outside its limits is refused');
r = await call('POST', '/api/settings', { key: 'ci_triage', value: 'enabled' });
const cfg = (await import('node:fs')).readFileSync(join(W, 'CONFIG.md'), 'utf8');
say(r.status === 200 && /^- ci_triage: enabled$/m.test(cfg) && /^- github_repo: acme\/tasklane$/m.test(cfg), "the owner's change is one CONFIG.md bullet");
r = await call('GET', '/api/data');
say(r.body.data.settings.keys.ci_triage.value === 'enabled', 'the data shows the new value at once');
{ const d0 = (await call('GET', '/api/data')).body.data, l = d0.learnings.find((x) => x.file === 'MEMORY.md');
  r = await call('POST', '/api/learnings/remove', { file: l.file, line: l.line }, 'viewer', 'dev@example.com');
  say(r.status === 403, 'only the owner deletes a learning');
  r = await call('POST', '/api/learnings/remove', { file: '../CONFIG.md', line: '- github_repo: acme/tasklane' });
  say(r.status === 400, 'a file outside the learnings is refused');
  r = await call('POST', '/api/learnings/remove', { file: l.file, line: l.line });
  const mem = (await import('node:fs')).readFileSync(join(W, 'MEMORY.md'), 'utf8');
  say(r.status === 200 && !mem.split('\n').includes(l.line) && mem.includes('## Review Style'), "the owner's delete takes out that one line"); }
r = await call('GET', '/api/artifacts/..%2F..%2Fetc/page');
say(r.status === 404, 'only a page the data names is served');
const ph = (await import('node:fs')).readFileSync(join(R, 'scripts/desk/page.html'), 'utf8');
say(ph.includes('const frameDoc =') && ph.includes('scrolling="no"') && ph.includes('e.data?.cgFrame'), 'a kept page strips page scripts, hides inner scrollbar, and reports its own scrollHeight via postMessage');
EOF
OUT="$(PORT="$PORT" WORK_DIR="$WORK" REPO_ROOT="$REPO_ROOT" node "$SANDBOX/routes.mjs" 2>>"$STDERR_LOG")"
kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null
printf '%s\n' "$OUT"
grep -q '^FAIL' <<<"$OUT" && FAILED=1
finish
