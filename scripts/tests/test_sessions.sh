#!/usr/bin/env bash
# Platform sessions (scripts/lib/sessions.sh): the session list judges holds
# and locks first, keeps a busy PR from dispatch, feeds two monitor alerts,
# and carries the HEAD signal — each use on its old rule when the list is
# unknown. Contract: docs/sessions.md.
. "$(dirname "$0")/helpers.sh"

SHA1="1111111111111111111111111111111111111111"
SHA2="2222222222222222222222222222222222222222"
MCP_URL="http://platform.test/mcp"

# the platform endpoint and its stub (tests/bin/curl → MCP mode)
mcp_setup() {
  mkdir -p "$SANDBOX/mcp" "$WORK/logs"
  printf '{"mcpServers":{"platform-outbound":{"type":"http","url":"%s"}}}\n' "$MCP_URL" > "$FAKE_HOME/.mcp.json"
  : > "$SANDBOX/mcp.log"
  export CURL_MCP_URL="$MCP_URL" CURL_MCP_LOG="$SANDBOX/mcp.log" CURL_MCP_DIR="$SANDBOX/mcp"
}
# the list_sessions answer: one `<id> <running> <started-secs-ago|-> <title>` per
# argument; `-` is the null start the platform reports for an unstamped turn
sessions_fx() {
  local a id run ago title out='[]'
  for a in "$@"; do
    read -r id run ago title <<< "$a"
    out="$(printf '%s' "$out" | jq -c --arg id "$id" --argjson r "$run" --arg st "$([ "$ago" = - ] || iso_ago "$ago")" --arg t "$title" \
      '. + [{sessionId:$id, title:$t, type:"schedule", running:$r, runStartedAt:(if $r and $st != "" then $st else null end), lastActivityAt:$st}]')"
  done
  jq -nc --arg t "$(jq -nc --argjson s "$out" '{sessions:$s}')" '{content:[{type:"text", text:$t}]}' \
    > "$SANDBOX/mcp/list_sessions.json"
}
calls() { jq -s --arg t "$1" '[.[] | select(.method == "tools/call" and .params.name == $t)] | length' "$SANDBOX/mcp.log"; }
check_eq() { # <actual> <expected> <description>
  if [ "$1" = "$2" ]; then printf 'ok   %s: %s\n' "$CASE" "$3"
  else printf 'FAIL %s: %s (got %s, want %s)\n' "$CASE" "$3" "$1" "$2"; FAILED=1; fi
}
hold() { # <n> <secs-ago> <run>
  mkdir -p "$WORK/.holds.lock"
  printf '%s\n%s\n' "$(iso_ago "$2")" "$3" > "$WORK/.holds.lock/$1"
}
ev() { # <secs-ago> <run> <event> <msg> [level]
  jq -nc --arg ts "$(iso_ago "$1")" --arg r "$2" --arg e "$3" --arg m "$4" --arg l "${5:-info}" \
    '{ts:$ts, run:$r, job:"review", level:$l, event:$e, msg:$m}' >> "$WORK/logs/events-$(date -u +%Y-%m-%d).jsonl"
}
ic_mention() { # <n>
  local s=$(( $(date -u +%s) - 7*86400 )) since
  since="$(date -u -d "@$s" +%Y-%m-%d 2>/dev/null || date -u -r "$s" +%Y-%m-%d)T00:00:00Z"
  jq -n --argjson n "$1" '[{id:101, user:{login:"alice", type:"User"}, author_association:"MEMBER",
      body:"@test-bot why?", created_at:"2026-08-07T09:00:00Z", html_url:"https://example.test/c/101",
      issue_url:("https://api.github.com/repos/acme/widgets/issues/"+($n|tostring))}]' \
    | fx "api repos/acme/widgets/issues/comments?since=$since&per_page=100&sort=created&direction=desc&page=1"
}

# --- 1. holds: a running session keeps a quiet hold ------------------------
new_case hold_session_running
base_config; mcp_setup
ic_mention 7
hold 7 7200 aaaa1111
sessions_fx "aaaa1111 true 7200 Review PR #7"
run_preflight review
assert_jq '.logs | any(contains("#7: held by run aaaa1111, its session is running"))' 'the running session keeps the hold'
assert_jq '(.mentions_due // []) | length == 0' 'the held PR is left to its session'
check_eq "$(calls list_sessions)" 1 'one list read for the pass'

# --- 1. holds: a running turn with no start from the platform still runs ---
new_case hold_session_running_no_start
base_config; mcp_setup
ic_mention 7
hold 7 7200 aaaa1111
sessions_fx "aaaa1111 true - Review PR #7"
run_preflight review
assert_jq '.logs | any(contains("#7: held by run aaaa1111, its session is running"))' 'a null runStartedAt counts as running'

# --- 1. holds: a null start past the window, from the run's first event ------
new_case hold_session_event_start_overlong
base_config; mcp_setup
ic_mention 7
hold 7 7200 aaaa1111
ev 14400 aaaa1111 tool_use "Bash [gh api]" debug
sessions_fx "aaaa1111 true - Review PR #7"
run_preflight review
assert_jq '.logs | any(contains("its run is quiet — released"))' 'the first event dates the turn; past 180 min the event rule decides'

# --- 1. holds: an ended session frees the hold at once ---------------------
new_case hold_session_idle
base_config; mcp_setup
ic_mention 7
hold 7 300 aaaa1111
ev 60 aaaa1111 tool_use "Bash [gh api]" debug
sessions_fx "aaaa1111 false 600 Review PR #7"
run_preflight review
assert_jq '.logs | any(contains("#7: hold from") and contains("its session has ended — released"))' 'the ended session releases the hold'
assert_jq '[.mentions_due[].number] == [7]' 'the mention is served again'
[ -e "$WORK/.holds.lock/7" ] && { printf 'FAIL %s: the hold file is gone\n' "$CASE"; FAILED=1; } \
  || printf 'ok   %s: the hold file is gone\n' "$CASE"

# --- 1. holds: a session the list does not show → the event rule -----------
new_case hold_session_unknown
base_config; mcp_setup
ic_mention 7
hold 7 300 aaaa1111
ev 60 aaaa1111 tool_use "Bash [gh api]" debug
sessions_fx "bbbb2222 false 600 Review PR #8"
run_preflight review
assert_jq '.logs | any(contains("#7: held by run aaaa1111, last event"))' 'the events keep the hold'

# --- 1. holds: no endpoint → the event rule, no call -----------------------
new_case hold_no_endpoint
base_config; mcp_setup; rm -f "$FAKE_HOME/.mcp.json"
ic_mention 7
hold 7 7200 aaaa1111
sessions_fx "aaaa1111 true 7200 Review PR #7"
run_preflight review
assert_jq '.logs | any(contains("#7: hold from") and contains("its run is quiet — released"))' 'the quiet hold is released by the event rule'
check_eq "$(calls list_sessions)" 0 'no list read'

# --- 1. holds: session_awareness disabled → no call ------------------------
new_case hold_disabled
base_config '- session_awareness: disabled'; mcp_setup
ic_mention 7
hold 7 7200 aaaa1111
sessions_fx "aaaa1111 true 7200 Review PR #7"
run_preflight review
check_eq "$(calls list_sessions)" 0 'the key closes the list'
assert_jq '.config.session_awareness == "disabled"' 'the config object carries the key'

# --- 1. holds: a turn past the window → the event rule ---------------------
new_case hold_session_overlong
base_config; mcp_setup
ic_mention 7
hold 7 7200 aaaa1111
sessions_fx "aaaa1111 true 14400 Review PR #7"
run_preflight review
assert_jq '.logs | any(contains("its run is quiet — released"))' 'a 4 h turn is judged by its events'

# --- 1. locks: past the TTL, the holder's session ended → takeover ---------
new_case lock_session_idle
base_config; mcp_setup
pr_json 1 "locked PR" '[]' "$SHA1" | open_prs_fx
add_row 1 "$SHA1" "$(iso_ago 3300)" - in_progress
ev 3300 aaaa1111 review_step "PR #1 1111111 locked"
ev 120 aaaa1111 tool_use "Bash [git diff]" debug
sessions_fx "aaaa1111 false 3300 Review PR #1"
run_preflight review
assert_jq '.reviews_due[0].takeover == true' 'the ended session gives the lock up'

# --- 1. locks: past the TTL, quiet, the session runs → left running --------
new_case lock_session_running
base_config; mcp_setup
pr_json 1 "locked PR" '[]' "$SHA1" | open_prs_fx
add_row 1 "$SHA1" "$(iso_ago 3300)" - in_progress
ev 3300 aaaa1111 review_step "PR #1 1111111 locked"
ev 1800 aaaa1111 tool_use "Bash [git diff]" debug
sessions_fx "aaaa1111 true 3300 Review PR #1"
run_preflight review
assert_jq '(.reviews_due // []) | length == 0' 'the running session is not taken over'
assert_jq '.logs | any(contains("holder aaaa1111 in a running session — left running"))' 'the reason is logged'

# --- 1. locks: inside the TTL, the holder's session ended → takeover -------
new_case lock_fresh_session_idle
base_config; mcp_setup
pr_json 1 "locked PR" '[]' "$SHA1" | open_prs_fx
add_row 1 "$SHA1" "$(iso_ago 600)" - in_progress
ev 600 aaaa1111 review_step "PR #1 1111111 locked"
sessions_fx "aaaa1111 false 600 Review PR #1"
run_preflight review
assert_jq '.reviews_due[0].takeover == true' 'a fresh lock of an ended session is taken over'
assert_jq '.logs | any(contains("its holder'"'"'s session has ended"))' 'the reason is logged'

# --- 4. signals: a new HEAD under a running review → one signal ------------
new_case signal_new_head
base_config; mcp_setup
pr_json 1 "locked PR" '[]' "$SHA2" | open_prs_fx
add_row 1 "$SHA1" "$(iso_ago 600)" - in_progress
hold 1 600 aaaa1111
sessions_fx "aaaa1111 true 600 Review PR #1"
run_preflight review
check_eq "$(calls send_session_message)" 1 'one signal'
check_eq "$(jq -rs '[.[] | select(.params.name == "send_session_message")][0].params.arguments.sessionId' "$SANDBOX/mcp.log")" aaaa1111 'to the holder session'
check_eq "$(jq -rs '[.[] | select(.params.name == "send_session_message")][0].params.arguments.text' "$SANDBOX/mcp.log")" \
  'code-guardian signal: PR #1 has a new head commit 2222222. Your review of PR #1 is at 1111111. Read docs/sessions.md → **Signals** before your next step.' 'the fixed template'
assert_jq '.logs | any(contains("PR #1: head moved to 2222222 — signal sent"))' 'the signal is logged'
run_preflight review
check_eq "$(calls send_session_message)" 1 'no second signal for the same head'

# --- 4. signals: a call with no answer is recorded, not sent again -----------
new_case signal_unknown_outcome
base_config; mcp_setup
pr_json 1 "locked PR" '[]' "$SHA2" | open_prs_fx
add_row 1 "$SHA1" "$(iso_ago 600)" - in_progress
hold 1 600 aaaa1111
sessions_fx "aaaa1111 true 600 Review PR #1"
touch "$SANDBOX/mcp/hang-send_session_message"
run_preflight review
assert_jq '.logs | any(contains("PR #1: head moved to 2222222 — signal to run aaaa1111 sent, its outcome unknown"))' 'the unknown outcome is logged as such'
run_preflight review
check_eq "$(calls send_session_message)" 1 'no second signal after an unknown outcome'

# --- 4. signals: same HEAD, or an ended session → no signal ----------------
new_case signal_none
base_config; mcp_setup
pr_json 1 "locked PR" '[]' "$SHA2" | open_prs_fx
add_row 1 "$SHA1" "$(iso_ago 600)" - in_progress
hold 1 600 aaaa1111
sessions_fx "aaaa1111 false 600 Review PR #1"
run_preflight review
check_eq "$(calls send_session_message)" 0 'an idle session gets nothing'
new_case signal_same_head
base_config; mcp_setup
pr_json 1 "locked PR" '[]' "$SHA1" | open_prs_fx
add_row 1 "$SHA1" "$(iso_ago 600)" - in_progress
hold 1 600 aaaa1111
sessions_fx "aaaa1111 true 600 Review PR #1"
run_preflight review
check_eq "$(calls send_session_message)" 0 'the same HEAD gets nothing'

# --- 2. dispatch: a PR a running session serves stays with the run ---------
new_case dispatch_busy_pr
base_config; mcp_setup
WL="$SANDBOX/cg-worklist-review-x.json"
jq -n '{mode:"review", nothing_to_do:false,
  reviews_due:[{number:9, kind:"first"}, {number:7, kind:"first"}, {number:8, kind:"first"}],
  mentions_due:[], ci_failures_due:[], merges_due:[], fixes_due:[], urgent_alerts_due:[],
  selfheals_due:[], label_cleanups_due:[], prunes_due:[], status_resets_due:[],
  logs:[], config:{}, read_set:["docs/review.md"]}' > "$WL"
sessions_fx "cccc3333 true 120 Review PR #7" "dddd4444 true 120 Review PRs #8, #12" "eeee5555 false 120 Review PR #8"
OUT="$(WORK_DIR="$WORK" HOME="$FAKE_HOME" LOG_RUN_ID=run-leader1 PATH="$T_DIR/bin:$PATH" \
       bash "$REPO_ROOT/scripts/dispatch.sh" plan "$WL" 2>>"$STDERR_LOG")"
assert_jq '[.dispatch[].number] == [8]' 'PR #7 is not dispatched; a shared or idle title does not count'
grep -q '"event":"dispatch_skipped".*PR #7: a running session already works on it' "$WORK"/logs/events-*.jsonl \
  && printf 'ok   %s: the skip is logged\n' "$CASE" || { printf 'FAIL %s: the skip is logged\n' "$CASE"; FAILED=1; }
rm -f "$SANDBOX"/cg-worklist-review-x-*; : > "$SANDBOX/mcp.log"
jq '.config.session_awareness = "disabled"' "$WL" > "$WL.tmp" && mv "$WL.tmp" "$WL"
OUT="$(WORK_DIR="$WORK" HOME="$FAKE_HOME" LOG_RUN_ID=run-leader1 PATH="$T_DIR/bin:$PATH" \
       bash "$REPO_ROOT/scripts/dispatch.sh" plan "$WL" 2>>"$STDERR_LOG")"
assert_jq '[.dispatch[].number] == [7, 8]' 'disabled dispatches every PR after the first'
check_eq "$(calls list_sessions)" 0 'disabled reads no list'

# --- 3. monitor: an idle tick reads no list ------------------------------------
new_case monitor_idle_no_call
base_config; mcp_setup
ev 60 review-x info precheck "review gate: nothing to do"
sessions_fx "ffff6666 true 14400 Review PR #3"
OUT="$(WORK_DIR="$WORK" HOME="$FAKE_HOME" PATH="$T_DIR/bin:$PATH" bash "$REPO_ROOT/scripts/monitor.sh" 2>>"$STDERR_LOG")"
check_eq "$(calls list_sessions)" 0 'no hold and no lost dispatch: no list read'

# --- 3. monitor: a null start is dated by the run's first event --------------
new_case monitor_overrun_event_start
base_config; mcp_setup
ev 60 review-x info precheck "review gate: nothing to do"
ev 14400 ffff6666 tool_use "Bash [gh api]" debug
sessions_fx "ffff6666 true - Review PR #3"
hold 3 14400 ffff6666
OUT="$(WORK_DIR="$WORK" HOME="$FAKE_HOME" PATH="$T_DIR/bin:$PATH" bash "$REPO_ROOT/scripts/monitor.sh" 2>>"$STDERR_LOG")"
assert_jq '[.alerts_due[] | select(.kind == "session_overrun") | .session] == ["ffff6666"]' 'the overrun alerts from the event start'

# --- 3. monitor: an overlong review turn and a lost dispatch ---------------
new_case monitor_session_alerts
base_config; mcp_setup
ev 60 review-x info precheck "review gate: nothing to do"
sessions_fx "ffff6666 true 14400 Review PR #3" "abcd1234 true 14400 Audit agent health 2026-10-24" "aaaa1111 true 600 Review PR #4"
hold 3 14400 ffff6666
ev 3600 run-leader1 dispatch "#5, #6 dispatched to sessions of their own; this run keeps #4"
ev 3000 aaaa2222 hold "PR #5: held by this run"
OUT="$(WORK_DIR="$WORK" HOME="$FAKE_HOME" PATH="$T_DIR/bin:$PATH" bash "$REPO_ROOT/scripts/monitor.sh" 2>>"$STDERR_LOG")"
assert_jq '[.alerts_due[] | select(.kind == "session_overrun") | .session] == ["ffff6666"]' 'only the review session past 180 min alerts'
assert_jq '[.alerts_due[] | select(.kind == "dispatch_lost") | .prs] == [[6]]' 'the PR no session took alerts'
new_case monitor_dispatch_lost_busy
base_config; mcp_setup
ev 60 review-x info precheck "review gate: nothing to do"
sessions_fx "aaaa1111 true 600 Review PR #6"
ev 3600 run-leader1 dispatch "#6 dispatched to sessions of their own; this run keeps #4"
OUT="$(WORK_DIR="$WORK" HOME="$FAKE_HOME" PATH="$T_DIR/bin:$PATH" bash "$REPO_ROOT/scripts/monitor.sh" 2>>"$STDERR_LOG")"
assert_jq '[(.alerts_due // [])[] | select(.kind == "dispatch_lost")] | length == 0' 'a running session for the PR is no loss'

finish
