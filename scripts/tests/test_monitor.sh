#!/usr/bin/env bash
# monitor.sh: the monitor's alerts — model outages and their recovery, the
# classifier spike, a refused review post, a silent review gate, a failing
# backup, harness drift — and the ledger that claims, acknowledges and
# suppresses them; plus the gate's monitor mode and the two hooks that feed it.
# Contract: docs/monitor.md.
. "$(dirname "$0")/helpers.sh"

HOOKS="$REPO_ROOT/scripts/harness/claude-code"

ev() { # <secs-ago> <job> <level> <event> <msg> [run]
  mkdir -p "$WORK/logs"
  jq -nc --arg ts "$(iso_ago "$1")" --arg job "$2" --arg lv "$3" --arg e "$4" --arg m "$5" --arg r "${6:-r1}" \
    '{ts:$ts, run:$r, job:$job, level:$lv, event:$e, msg:$m}' >> "$WORK/logs/events-$(date -u +%Y-%m-%d).jsonl"
}
fail_ev()  { ev "$1" session error api_failure "${2:-server_error}: 503 Bedrock is unable to process your request." "r$1"; }
block_ev() { ev "$1" session warn classifier_block "Bash [${2:-ls}] — Blocked by fast classifier" "${3:-r$1}"; }
# a review heartbeat a minute ago, so the gap check stays quiet
fresh_gate() { ev 60 review info precheck "review gate: nothing to do"; }
mon_case() { new_case "$1"; shift; base_config "$@"; mkdir -p "$WORK/logs"; fresh_gate; }
due() { printf '%s' "$OUT" | jq -r --arg k "$1" '[.alerts_due[] | select(.kind == $k)] | length'; }

# --- nothing logged → idle -------------------------------------------------------
mon_case mon_idle
run_monitor
assert_jq '.mode == "monitor" and .nothing_to_do == true and .alerts_due == []' 'no events, no alert'

# --- model outage: threshold, one alert, claim, ack, suppression ------------------
mon_case mon_model_open
fail_ev 600
run_monitor
assert_jq '[.alerts_due[] | select(.kind == "model_unavailable")] == []' 'one failure stays under the default threshold of 2'
fail_ev 300 rate_limit
run_monitor
assert_jq '.nothing_to_do == false and ([.alerts_due[] | select(.kind == "model_unavailable")] | length == 1)' 'two failures alert'
assert_jq '.alerts_due[0] | .open == true and .count == 2 and .errors.server_error == 1 and .errors.rate_limit == 1' 'the alert carries the classes and is open'
ID="$(printf '%s' "$OUT" | jq -r '.alerts_due[0].id')"
run_monitor
assert_jq '.alerts_due == [] and .suppressed == 0' 'a claimed alert is not emitted again inside its claim'
run_monitor ack "$ID"
assert_jq '.acknowledged == ["'"$ID"'"]' 'ack records the id'
run_monitor
assert_jq '.alerts_due == [] and .suppressed == 1 and any(.logs[]; test("suppressed 1 alert"))' 'a delivered alert is suppressed, and the log line says so'

# --- the claim expires: an unacknowledged alert is due again ---------------------
mon_case mon_claim_expires
fail_ev 600; fail_ev 300
run_monitor
ID="$(printf '%s' "$OUT" | jq -r '.alerts_due[0].id')"
jq --arg id "$ID" '.alerts[$id].claimed = "2020-01-01T00:00:00Z"' "$WORK/MONITOR.json" > "$WORK/m.json" && mv "$WORK/m.json" "$WORK/MONITOR.json"
run_monitor
assert_jq '[.alerts_due[] | select(.id == "'"$ID"'")] | length == 1' 'a session that died before its ack gets the alert again'

# --- a delivered alert stays delivered while its events are retained ------------
# the events log keeps a file 14-21 days (docs/logging.md → Retention), longer
# without the weekly audit: an old outage still in the log never alerts twice
mon_case mon_row_outlives_events
# sent after the outage was over, 14.9 days ago: no recovery notice is due
T1="$(iso_ago 1296600)"; SENT="$(iso_ago 1290000)"
for t in "$T1" "$(iso_ago 1296300)"; do
  jq -nc --arg ts "$t" '{ts:$ts, run:"r-old", job:"session", level:"error", event:"api_failure", msg:"server_error: 503"}' \
    >> "$WORK/logs/events-$(date -u +%Y-%m-%d).jsonl"
done
jq -n --arg id "model:$T1" --arg sent "$SENT" '{alerts: {($id): {kind: "model_unavailable", first: $sent, claimed: $sent, sent: $sent}}}' > "$WORK/MONITOR.json"
run_monitor
assert_jq '.alerts_due == [] and .suppressed == 1' 'an outage sent over 14 days ago, its events still in the log, is not sent again'
if jq -e --arg id "model:$T1" --arg sent "$SENT" '.alerts[$id].sent == $sent' "$WORK/MONITOR.json" >/dev/null 2>&1; then
  printf 'ok   %s: the row stays while its alert is still found\n' "$CASE"
else printf 'FAIL %s: the row of a found alert was pruned\n' "$CASE"; FAILED=1; fi
jq -n --arg old "$SENT" '{alerts: {"model:gone": {kind: "model_unavailable", first: $old, sent: $old}}}' > "$WORK/MONITOR.json"
rm -f "$WORK"/logs/events-*.jsonl; fresh_gate
run_monitor
if ! jq -e '.alerts | has("model:gone")' "$WORK/MONITOR.json" >/dev/null 2>&1; then
  printf 'ok   %s: a row whose alert is no longer found goes after 14 days\n' "$CASE"
else printf 'FAIL %s: an old row of a gone alert was kept\n' "$CASE"; FAILED=1; fi

# --- recovery: once, only after an alert sent while the outage was open ----------
mon_case mon_model_recovered
fail_ev 7800; fail_ev 7500
run_monitor
assert_jq '[.alerts_due[] | select(.kind == "model_unavailable" and .open == false)] | length == 1' 'an outage nobody was told about alerts once, as closed'
assert_jq '[.alerts_due[] | select(.kind == "model_recovered")] == []' 'and needs no recovery notice'
mon_case mon_model_recovered_after_open
fail_ev 7800; fail_ev 7500
ID="model:$(cat "$WORK"/logs/events-*.jsonl | jq -rs '[.[] | select(.event == "api_failure") | .ts] | min')"
jq -n --arg id "$ID" --arg sent "$(iso_ago 7400)" '{alerts: {($id): {kind: "model_unavailable", first: $sent, sent: $sent}}}' > "$WORK/MONITOR.json"
run_monitor
assert_jq '[.alerts_due[] | select(.kind == "model_recovered" and .id == "'"$ID"':recovered")] | length == 1' 'an outage alerted while open gets one recovery notice'
run_monitor ack "$ID:recovered"
run_monitor
assert_jq '.alerts_due == []' 'the recovery notice goes once'

# --- agent-side API errors are not an outage -------------------------------------
mon_case mon_model_agent_errors
ev 600 session error api_failure "invalid_request: prompt too long" r1
ev 300 session error api_failure "max_output_tokens: limit" r2
run_monitor
assert_jq '.alerts_due == []' 'invalid_request and max_output_tokens never alert'

mon_case mon_model_off '- model_alert_threshold: off'
fail_ev 600; fail_ev 300
run_monitor
assert_jq '.alerts_due == [] and .config.model_alert_threshold == 0' 'off disables the model alert'

# --- GitHub outage: failed gate ticks, the class, recovery on the next good tick --
gh_fail() { ev "$1" review error preflight "could not list open PRs on acme/widgets (API error: ${2:-HTTP 502: Bad Gateway (https://api.github.com/repos/acme/widgets/pulls)})" "g$1"; }
gh_ok()   { ev "$1" review info heartbeat "mode=review nothing_to_do=true reviews=0" "g$1"; }
mon_case mon_github_open
gh_ok 3600; gh_fail 900
run_monitor
assert_jq '[.alerts_due[] | select(.kind == "github_unavailable")] == []' 'one failed tick stays under the default threshold of 2'
gh_fail 600 'gh: Bad credentials (HTTP 401)'
run_monitor
assert_jq '[.alerts_due[] | select(.kind == "github_unavailable")] | length == 1 and .[0].open == true and .[0].count == 2
  and .[0].errors.server_error == 1 and .[0].errors.auth == 1 and .[0].id == "github:\(.[0].first)"' 'two failed ticks alert, open, with their classes'
ID="$(printf '%s' "$OUT" | jq -r '.alerts_due[] | select(.kind == "github_unavailable") | .id')"
run_monitor ack "$ID"
jq --arg id "$ID" --arg t "$(iso_ago 500)" '.alerts[$id].sent = $t' "$WORK/MONITOR.json" > "$WORK/m.json" && mv "$WORK/m.json" "$WORK/MONITOR.json"
gh_fail 300 'dial tcp: lookup api.github.com: i/o timeout'
run_monitor
assert_jq '.alerts_due == [] and .suppressed == 1' 'a third failed tick is the same outage, already reported'
gh_ok 60
run_monitor
assert_jq '[.alerts_due[] | select(.kind == "github_recovered")] | length == 1 and .[0].needs == "'"$ID"'" and .[0].count == 3 and (.[0].minutes | . >= 13 and . <= 15)' 'the next good tick ends it with one recovery notice'
run_monitor ack "$ID:recovered"
run_monitor
assert_jq '.alerts_due == []' 'the recovery notice goes once'

mon_case mon_github_quiet_recovery
gh_fail 900; gh_fail 600; gh_ok 300
run_monitor
assert_jq '([.alerts_due[] | select(.kind == "github_unavailable" and .open == false)] | length == 1)
  and ([.alerts_due[] | select(.kind == "github_recovered")] == [])' 'an outage nobody was told about alerts once, as closed, with no recovery notice'

mon_case mon_github_class_slug
ev 900 review error preflight "could not list open PRs on acme/authentication-api (API error: dial tcp: i/o timeout)" g1
ev 600 review error preflight "could not list open PRs on acme/authentication-api (API error: dial tcp: i/o timeout)" g2
run_monitor
assert_jq '.alerts_due[] | select(.kind == "github_unavailable") | .errors == {"network": 2}' 'the class comes from the API error text, never from the repo slug'

mon_case mon_github_split
gh_fail 900; gh_ok 600; gh_fail 300
run_monitor
assert_jq '[.alerts_due[] | select(.kind | startswith("github"))] == []' 'a good tick between two failures splits them into two single-tick outages'

mon_case mon_github_other_errors
ev 600 review error preflight "target repo unresolved (CONFIG.md github_repo missing)" g1
ev 300 review error preflight "target repo unresolved (CONFIG.md github_repo missing)" g2
ev 200 review warn gh_api "PR #4: state check did not respond — prune skipped this run" g2
run_monitor
assert_jq '.alerts_due == []' 'a config error and a partial API warning are not an outage'

mon_case mon_github_off '- github_alert_threshold: off'
gh_fail 900; gh_fail 600
run_monitor
assert_jq '.alerts_due == [] and .config.github_alert_threshold == 0' 'off disables the GitHub alert'

# --- classifier spike: threshold, the day id, the patterns -----------------------
mon_case mon_classifier_spike '- classifier_alert_threshold: 3'
block_ev 900 'cd /home/agent && bash scripts/work-backup.sh persist'
block_ev 600 'cd /home/agent && bash scripts/work-backup.sh persist'
run_monitor
assert_jq '[.alerts_due[] | select(.kind == "classifier_spike")] == []' 'under the threshold, no spike'
block_ev 300 'rm -f reviews/pr-4555.md'
run_monitor
assert_jq '.alerts_due[] | select(.kind == "classifier_spike") | .count == 3 and .id == "classifier:'"$(date -u +%Y-%m-%d)"'" and .top[0].count == 2 and .by_tool.Bash == 3' 'at the threshold: one alert per UTC day with its top pattern'
mon_case mon_classifier_off '- classifier_alert_threshold: 0'
for s in 900 600 300; do block_ev "$s"; done
run_monitor
assert_jq '.alerts_due == []' '0 disables the classifier alerts'

# --- a refused review post alerts, unless the PR was posted after it --------------
mon_case mon_post_blocked
block_ev 900 'cd /home/agent && bash "$HOME/scripts/review-pr.sh" post 4517 --verdict APPROVE --body /tmp/r.md' runA
block_ev 600 'cd /home/agent && bash scripts/review-pr.sh post 4518 --verdict COMMENT --body /tmp/r.md' runB
ev 300 review info review_step "PR #4518 1df8905 posted COMMENT" runB
run_monitor
assert_jq '[.alerts_due[] | select(.kind == "review_post_blocked")] | length == 1 and .[0].pr == 4517 and .[0].id == "post_blocked:runA:4517"' 'the unposted PR alerts, the PR posted later does not'

# a run that retries the refused post is still one alert: one entry per id
mon_case mon_post_blocked_retry
block_ev 900 'bash scripts/review-pr.sh post 4519 --verdict COMMENT --body /tmp/r.md' runC
block_ev 600 'bash scripts/review-pr.sh post 4519 --verdict COMMENT --body /tmp/r2.md' runC
run_monitor
assert_jq '[.alerts_due[] | select(.kind == "review_post_blocked")] | length == 1 and .[0].id == "post_blocked:runC:4519"' 'two refusals of one post in one run are one alert'

# --- the review gate went silent --------------------------------------------------
new_case mon_heartbeat_gap
base_config '- review_interval_quiet: 60'
ev 7200 review info precheck "review gate: nothing to do"
run_monitor
assert_jq '.alerts_due[] | select(.kind == "heartbeat_gap") | .silent_minutes >= 119 and .limit_minutes == 90' 'two silent hours past 1.5 × a 60-minute quiet interval alert'
ev 30 review info heartbeat "mode=review nothing_to_do=true"
run_monitor
assert_jq '.alerts_due == []' 'a new tick clears it'
if ! jq -e '.alerts | to_entries | any(.value.kind == "heartbeat_gap")' "$WORK/MONITOR.json" >/dev/null 2>&1; then
  printf 'ok   %s: a cleared condition leaves the ledger, so its return alerts again\n' "$CASE"
else printf 'FAIL %s: cleared heartbeat_gap row kept\n' "$CASE"; FAILED=1; fi

new_case mon_heartbeat_gap_default
base_config
ev 4200 review info precheck "review gate: nothing to do"
run_monitor
assert_jq '.alerts_due[] | select(.kind == "heartbeat_gap") | .limit_minutes == 60' 'under the default quiet interval, 70 silent minutes pass the one-hour floor'

# --- a backup that keeps failing ----------------------------------------------------
mon_case mon_backup '- work_repo: acme/widgets-state'
ev 30000 session info work_backup "pushed work/ (attempt 1)"
ev 25000 session error work_backup "push to acme/widgets-state failed after 3 attempts — retry next run"
run_monitor
assert_jq '.alerts_due[] | select(.kind == "backup_failing") | .failures == 1' 'a failure no push cleared for 6 hours alerts'
ev 60 session info work_backup "pushed work/ (attempt 1)"
run_monitor
assert_jq '[.alerts_due[] | select(.kind == "backup_failing")] == []' 'the next push clears it'

# --- refused dispatches ------------------------------------------------------------
mon_case mon_dispatch_refused
ev 5000 review info dispatch "#7 dispatched to sessions of their own; this run keeps #6"
ev 4000 review warn dispatch_refused "#8, #9: name the model with its provider — kept in this run" ra
ev 1200 review warn dispatch_refused "#9: name the model with its provider — kept in this run" rb
run_monitor
assert_jq '.alerts_due[] | select(.kind == "dispatch_refused") | .count == 2 and .runs == 2 and .prs == 2' 'refusals no accepted dispatch cleared for an hour alert'
ev 60 review info dispatch "#9 dispatched to sessions of their own; this run keeps #6"
run_monitor
assert_jq '[.alerts_due[] | select(.kind == "dispatch_refused")] == []' 'the next accepted dispatch clears it'
mon_case mon_dispatch_refused_young
ev 600 review warn dispatch_refused "#8: the hourly cap is reached — kept in this run"
run_monitor
assert_jq '[.alerts_due[] | select(.kind == "dispatch_refused")] == []' 'a refusal under an hour old waits'
mon_case mon_dispatch_refused_lasting
ev 90000 review warn dispatch_refused "#8: name the model with its provider — kept in this run" ra
ev 1200 review warn dispatch_refused "#9: name the model with its provider — kept in this run" rb
FIRST="$(jq -r 'select(.run == "ra") | .ts' "$WORK"/logs/events-*.jsonl)"
run_monitor
assert_jq '.alerts_due[] | select(.kind == "dispatch_refused") | .id == "dispatch:'"$FIRST"'" and .count == 2' \
  'a refusal that lasts past 24 h keeps the id of its first refusal'
mon_case mon_dispatch_refused_stale
ev 90000 review warn dispatch_refused "#8: name the model with its provider — kept in this run"
run_monitor
assert_jq '[.alerts_due[] | select(.kind == "dispatch_refused")] == []' 'no refusal in 24 h clears it'

# --- GitHub refuses a call with HTTP 403 ------------------------------------------
mon_case mon_github_write_denied
ev 900 review warn progress_status "PR #7: progress write did not succeed (pending: queued) — HTTP 403"
ev 800 review error post_failed "PR #7: review POST did not succeed after retry — gh: Resource not accessible by integration (HTTP 403)"
ev 700 review warn gh_api "HTTP 403: You have exceeded a secondary rate limit"
ev 600 review error preflight "could not list open PRs (API error HTTP 403)"
ev 500 session error tool_failure "Bash [gh api user]: Exit code 1 gh: Resource not accessible by integration (HTTP 403)"
ev 400 session error api_failure "authentication_failed: the proxy refused the model with HTTP 403"
run_monitor
assert_jq '.alerts_due[] | select(.kind == "github_write_denied") | .count == 2 and .by_event == {"progress_status": 1, "post_failed": 1} and .id == "gh_write:'"$(date -u +%Y-%m-%d)"'"' \
  'a 403 alerts once per UTC day; a rate limit, the gate list failure and hook events do not count'

# --- the token's identity changed -------------------------------------------------
mon_case mon_identity_changed
jq -nc --arg t "$(iso_ago 3600)" '{login: "new-app[bot]", kind: "app", checked_at: $t, previous: {login: "old-app[bot]", kind: "app"}, changed_at: $t}' > "$WORK/GITHUB.json"
run_monitor
assert_jq '.alerts_due[] | select(.kind == "github_identity_changed") | .login == "new-app[bot]" and .previous == "old-app[bot]" and .token_kind == "app"' 'a login change in the last 7 days alerts'
jq '.changed_at = "2020-01-01T00:00:00Z"' "$WORK/GITHUB.json" > "$WORK/g.json" && mv "$WORK/g.json" "$WORK/GITHUB.json"
run_monitor
assert_jq '[.alerts_due[] | select(.kind == "github_identity_changed")] == []' 'an older change does not'

# --- harness drift from install.sh --check -----------------------------------------
mon_case mon_harness
mkdir -p "$FAKE_HOME/.claude"; echo '{}' > "$FAKE_HOME/.claude/settings.json"
run_monitor
assert_jq '.alerts_due[] | select(.kind == "harness_drift") | (.parts | index("hooks")) and (.parts | index("automode-rules"))' 'an empty settings file names hooks and rules'
WORK_DIR="$WORK" HOME="$FAKE_HOME" CLAUDECODE=1 bash "$HOOKS/install.sh" >/dev/null 2>&1
run_monitor
assert_jq '[.alerts_due[] | select(.kind == "harness_drift")] == []' 'a re-install clears it'

# --- pi installed, its extension not linked --------------------------------------
mon_case mon_harness_pi
mkdir -p "$FAKE_HOME/.pi/agent"
run_monitor
assert_jq '.alerts_due[] | select(.kind == "harness_drift") | .parts == ["pi-extension"]' 'an unlinked pi extension is drift'
HOME="$FAKE_HOME" bash "$REPO_ROOT/scripts/harness/pi/install.sh" >/dev/null 2>&1
run_monitor
assert_jq '[.alerts_due[] | select(.kind == "harness_drift")] == []' 'linking it clears the drift'

# --- a configured benchmark judge the host cannot run -------------------------------
mon_case mon_judge_unavailable '- benchmark: enabled' '- benchmark_judge: claude-opus-5'
mkdir -p "$SANDBOX/cli"
printf '#!/usr/bin/env bash\nprintf %s\n' "'{\"loggedIn\": false}'" > "$SANDBOX/cli/claude"; chmod +x "$SANDBOX/cli/claude"
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY
export CG_JUDGE_PI="$SANDBOX/cli/no-pi"
CG_JUDGE_CLI="$SANDBOX/cli/claude" run_monitor
assert_jq '.alerts_due[] | select(.kind == "judge_unavailable") | .id == "judge:claude-opus-5" and .cause == "not_signed_in"' 'a signed-out judge CLI alerts'
CG_JUDGE_CLI="$SANDBOX/cli/none" run_monitor
assert_jq '[.alerts_due[] | select(.kind == "judge_unavailable")] == []' 'the claimed alert is not due again within the claim window'
printf '#!/usr/bin/env bash\nprintf %s\n' "'{\"loggedIn\": true}'" > "$SANDBOX/cli/claude"
CG_JUDGE_CLI="$SANDBOX/cli/claude" run_monitor
assert_jq '[.alerts_due[] | select(.kind == "judge_unavailable")] == []' 'signing in clears it'
CG_JUDGE_CLI="$SANDBOX/cli/none" run_monitor
assert_jq '.alerts_due[] | select(.kind == "judge_unavailable") | .cause == "no_cli"' 'a missing CLI is its own cause'
cp "$SANDBOX/cli/claude" "$SANDBOX/cli/pi"
CG_JUDGE_CLI="$SANDBOX/cli/none" CG_JUDGE_PI="$SANDBOX/cli/pi" run_monitor
assert_jq '[.alerts_due[] | select(.kind == "judge_unavailable")] == []' 'a pi CLI to fall back to clears it'

# --- the gate's monitor mode ---------------------------------------------------------
mon_case mon_gate_idle
run_precheck monitor
assert_rc 1 'an idle monitor tick starts no session'
mon_case mon_gate_due
fail_ev 600; fail_ev 300
run_precheck monitor
assert_rc 0 'a due alert starts the session'
assert_out_contains 'alerts_due=1' 'the prompt names the due alerts'
assert_out_contains 'do not run monitor.sh again' 'and names the one-shot script'

# --- the hooks that feed it ------------------------------------------------------------
new_case mon_hooks
base_config
mkdir -p "$WORK/logs"
jq -nc '{hook_event_name:"PermissionDenied", session_id:"s-1", tool_name:"Bash",
         tool_input:{command:"bash scripts/review-pr.sh post 7 --verdict APPROVE"}, reason:"Blocked by fast classifier"}' \
  | WORK_DIR="$WORK" bash "$HOOKS/log-permission-denied.sh"
jq -nc '{hook_event_name:"PermissionDenied", session_id:"s-1", tool_name:"Agent",
         tool_input:{subagent_type:"review-skill", description:"issue-fit on PR 7", prompt:"long"}, reason:"Blocked"}' \
  | WORK_DIR="$WORK" bash "$HOOKS/log-permission-denied.sh"
jq -nc '{hook_event_name:"StopFailure", session_id:"s-2", error:"server_error", error_details:"503 no healthy upstream"}' \
  | WORK_DIR="$WORK" bash "$HOOKS/log-api-failure.sh"
EVENTS="$WORK/logs/events-$(date -u +%Y-%m-%d).jsonl"
OUT="$(jq -sc . "$EVENTS")"
assert_jq 'any(.[]; .event == "classifier_block" and .level == "warn" and .run == "s-1" and .msg == "Bash [bash scripts/review-pr.sh post 7 --verdict APPROVE] — Blocked by fast classifier")' 'PermissionDenied logs the command and the reason'
assert_jq 'any(.[]; .event == "classifier_block" and (.msg | startswith("Agent [review-skill: issue-fit on PR 7]")))' 'an Agent refusal names the subagent type, not the prompt'
assert_jq 'any(.[]; .event == "api_failure" and .level == "error" and .msg == "server_error: 503 no healthy upstream")' 'StopFailure logs the class and the detail'
rm -f "$WORK/CONFIG.md"
jq -nc '{hook_event_name:"StopFailure", session_id:"s-3", error:"server_error"}' | WORK_DIR="$WORK" bash "$HOOKS/log-api-failure.sh"
if ! grep -q '"run":"s-3"' "$EVENTS"; then printf 'ok   %s: no CONFIG.md, no event\n' "$CASE"
else printf 'FAIL %s: a hook logged without CONFIG.md\n' "$CASE"; FAILED=1; fi

# --- api_failure classes: one list for the docs and every adapter -----------------
# docs/monitor.md → The api_failure classes is the list; the pi extension's
# errorClass() returns every class of it and no other, and the monitor's
# routing names only classes of it
new_case api_failure_classes
DOC_CLASSES="$(tr '\n' ' ' < "$REPO_ROOT/docs/monitor.md" \
  | sed -n 's/.*\*\*The `api_failure` classes\*\* are the `error` values of Claude Code.s `StopFailure` hook: \([^.]*\)\..*/\1/p' \
  | grep -oE '`[a-z_]+`' | tr -d '`' | sort -u | tr '\n' ' ')"
PI_CLASSES="$(sed -n '/^function errorClass/,/^}/p' "$REPO_ROOT/scripts/harness/pi/extension.ts" \
  | grep -oE 'return "[a-z_]+"' | sed 's/return "//; s/"$//' | sort -u | tr '\n' ' ')"
HINT_CLASSES="$(sed -n '/def model_hint:/,/ end;/p' "$REPO_ROOT/scripts/monitor-direct.sh" \
  | grep -oE '"[a-z_]+"' | tr -d '"' | sort -u)"
if [ -n "$DOC_CLASSES" ] && [ "$DOC_CLASSES" = "$PI_CLASSES" ]; then
  printf 'ok   %s: the pi errorClass() returns exactly the classes of docs/monitor.md\n' "$CASE"
else printf 'FAIL %s: docs/monitor.md classes [%s] differ from the pi errorClass() [%s]\n' "$CASE" "$DOC_CLASSES" "$PI_CLASSES"; FAILED=1; fi
stray=""
for c in $HINT_CLASSES; do case " $DOC_CLASSES" in (*" $c "*) ;; (*) stray="$stray $c";; esac; done
if [ -n "$HINT_CLASSES" ] && [ -z "$stray" ]; then printf 'ok   %s: the monitor routing names only listed classes\n' "$CASE"
else printf 'FAIL %s: monitor-direct.sh routes unlisted classes:%s\n' "$CASE" "${stray:- (no classes found)}"; FAILED=1; fi

finish
