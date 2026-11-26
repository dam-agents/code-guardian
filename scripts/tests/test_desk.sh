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
say(d.findings.some((f) => f.state === 'fixed') && d.findings.some((f) => f.state === 'open'), 'a finding is followed to fixed over its rounds');
say(d.artifacts.some((a) => a.kind === 'guide' && a.page) && d.artifacts.some((a) => a.id === 'health' && /^https:/.test(a.url)), 'the guides and the health dashboard are pages');
say(!JSON.stringify(d.config).includes('@'), 'the settings name no person');
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
const call = async (method, path, body, role = 'owner', email = 'own@example.com') => {
  const r = await fetch(`http://127.0.0.1:${P}${path}`, { method, body: body ? JSON.stringify(body) : undefined,
    headers: { 'content-type': 'application/json', ...(role ? { 'x-platform-caller-role': role, 'x-platform-caller-email': email } : {}) } });
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
say(r.body.unread_mine === 1 && r.body.notifications.some((n) => n.mine && /^Done/.test(n.title)), 'the end of the job comes to the bell');
r = await call('POST', '/api/asks', { text: 'Why changes?', context: { tab: 'prs', item: '#1234' } }, 'viewer', 'pat@example.com');
say(r.status === 201 && r.body.ping === 'answer desk question A-1' && r.body.ping_conversation === 'item.pr-1234', 'a question goes to the page\'s own session');
cli('answer', 'A-1', join(W, 'done.txt'));
r = await call('GET', '/api/asks', null, 'viewer', 'pat@example.com');
say(r.body.asks[0]?.answer?.text === 'Round 2 is posted.', 'the answer comes back to the asker');
r = await call('GET', '/api/asks', null, 'viewer', 'other@example.com');
say(r.body.asks.length === 0, 'another person does not see the question');
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
r = await call('GET', '/api/artifacts/..%2F..%2Fetc/page');
say(r.status === 404, 'only a page the data names is served');
EOF
OUT="$(PORT="$PORT" WORK_DIR="$WORK" REPO_ROOT="$REPO_ROOT" node "$SANDBOX/routes.mjs" 2>>"$STDERR_LOG")"
kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null
printf '%s\n' "$OUT"
grep -q '^FAIL' <<<"$OUT" && FAILED=1
finish
