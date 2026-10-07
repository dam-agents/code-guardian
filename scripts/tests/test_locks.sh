#!/usr/bin/env bash
# In-progress lock semantics: fresh lock skips, stale lock takes over — but a
# lock past the TTL whose holder is still logging is left running.
# Contract: docs/review-mechanics.md → Review tracking state, Live holder.
. "$(dirname "$0")/helpers.sh"

SHA1="1111111111111111111111111111111111111111"

# an event <secs> ago from run <run>; <event>/<msg> default to a holder tool call
holder_event() { # <secs-ago> <run> [event] [msg]
  mkdir -p "$WORK/logs"
  jq -nc --arg ts "$(iso_ago "$1")" --arg r "$2" \
    --arg e "${3:-tool_use}" --arg m "${4:-Bash [git diff]}" \
    '{ts:$ts, run:$r, job:"session", level:"debug", event:$e, msg:$m}' \
    >> "$WORK/logs/events-$(date -u +%Y-%m-%d).jsonl"
}

lock_case() { # <case-name> <lock-secs-ago>
  new_case "$1"
  base_config
  mkdir -p "$WORK/logs"
  pr_json 1 "locked PR" '[]' "$SHA1" | open_prs_fx
  add_row 1 "$SHA1" "$(iso_ago "$2")" - in_progress
}

# --- fresh lock → skipped ----------------------------------------------------
lock_case fresh_lock 600
run_preflight review
assert_jq '.reviews_due | length == 0' 'fresh lock not re-emitted'
assert_jq '.logs | any(contains("fresh in_progress lock"))' 'skip logged'

# --- inside the raised TTL → still fresh -------------------------------------
# 45m would have been a takeover under the old 30-min TTL; the point of the
# raise is that a p90 review no longer gets handed to a second job.
lock_case within_ttl 2700
run_preflight review
assert_jq '.reviews_due | length == 0' '45m lock is inside the 50-min TTL'
assert_jq '.logs | any(contains("fresh in_progress lock (45m)"))' 'age reported'

# --- past TTL, no log evidence → takeover ------------------------------------
lock_case stale_lock 3300
run_preflight review
assert_jq '.reviews_due | length == 1' 'stale lock re-emitted'
assert_jq '.reviews_due[0] | .takeover == true and .kind == "first"' 'takeover, kind first (no history file)'

# --- takeover kind: a posted review in the history file, not the file itself ---
lock_case stale_lock_alert_only 3300
printf '# PR #1: locked PR\n<!-- urgent-announced: 2026-09-28T10:00:00Z -->\n' > "$WORK/reviews/pr-1.md"
run_preflight review
assert_jq '.reviews_due[0] | .takeover == true and .kind == "first" and .full == true' 'an alert-only history file is no prior review'
lock_case stale_lock_reviewed 3300
printf '# PR #1: locked PR\n\n## Review at 1111111 — 2026-09-27T10:00:00Z — COMMENT\n\nx\n' > "$WORK/reviews/pr-1.md"
run_preflight review
assert_jq '.reviews_due[0] | .takeover == true and .kind == "re-review" and .full == false' 'a posted review section makes the takeover a re-review'

# --- past TTL, holder still logging → left running ---------------------------
lock_case live_holder 3300
holder_event 3300 aaaa1111 review_step "PR #1 1111111 locked"
holder_event 120  aaaa1111
run_preflight review
assert_jq '.reviews_due | length == 0' 'live holder is not taken over'
assert_jq '.logs | any(contains("holder aaaa1111 active"))' 'holder run id + idle age logged'
assert_jq '[.logs[] | select(contains("stale in_progress lock"))] | length == 0' 'no takeover line'

# --- past TTL, holder quiet beyond the window → takeover ---------------------
# 30 min of silence is well past HOLDER_QUIET_MIN (20): treated as dead.
lock_case quiet_holder 3300
holder_event 3300 bbbb2222 review_step "PR #1 1111111 locked"
holder_event 1800 bbbb2222
run_preflight review
assert_jq '.reviews_due | length == 1' 'holder silent past the window → takeover'
assert_jq '.reviews_due[0].takeover == true' 'takeover flagged'

# --- the longest gap a healthy review shows must NOT read as death -----------
# Real runs go up to 16.7 min between events mid-verification; the window sits
# above that on purpose, so a 17-min gap still counts as alive.
lock_case slow_but_alive 3300
holder_event 3300 eeee5555 review_step "PR #1 1111111 locked"
holder_event 1020 eeee5555
run_preflight review
assert_jq '.reviews_due | length == 0' 'a 17m verification gap is not death'

# --- the skill fan-out is silent by construction, not dead -------------------
# Between `fanned out` and `verified` the holder is blocked on its subagents:
# no event, no tree touched. 40 min of that is a healthy review, not a crash.
lock_case fanout_silence 3300
holder_event 3300 dddd4444 review_step "PR #1 1111111 locked"
holder_event 2400 dddd4444 review_step "PR #1 1111111 fanned out (n=4)"
run_preflight review
assert_jq '.reviews_due | length == 0' 'a 40m fan-out silence is not death'
assert_jq '.logs | any(contains("in the skill fan-out"))' 'the log says which phase holds the lock'

# --- the fan-out window is not unbounded -------------------------------------
lock_case fanout_expired 5400
holder_event 5400 dddd4444 review_step "PR #1 1111111 locked"
holder_event 4200 dddd4444 review_step "PR #1 1111111 fanned out (n=4)"
run_preflight review
assert_jq '.reviews_due | length == 1' 'past the fan-out window the lock is taken over'

# --- once the fan-out ends, the ordinary window applies again ----------------
lock_case fanout_over 3300
holder_event 3300 dddd4444 review_step "PR #1 1111111 locked"
holder_event 2400 dddd4444 review_step "PR #1 1111111 fanned out (n=4)"
holder_event 1800 dddd4444 review_step "PR #1 1111111 verified"
run_preflight review
assert_jq '.reviews_due | length == 1' 'silence after verified is death again'

# --- a refreshed lock row never reaches candidate age at all -----------------
# The heartbeat (docs/review.md → Lock heartbeat) rewrites the row, so the age
# preflight measures is the refresh, not the original lock.
lock_case refreshed_row 600
holder_event 2400 ffff6666 review_step "PR #1 1111111 locked"
holder_event 600  ffff6666 review_step "PR #1 1111111 locked (refresh, awaiting skills)"
run_preflight review
assert_jq '.reviews_due | length == 0' 'refreshed row stays fresh'
assert_jq '.logs | any(contains("fresh in_progress lock (10m)"))' 'age measured from the refresh'

# --- another PR's holder must not keep this lock alive -----------------------
lock_case other_pr_holder 3300
holder_event 3300 cccc3333 review_step "PR #7 7777777 locked"
holder_event 60   cccc3333
run_preflight review
assert_jq '.reviews_due | length == 1' "a different PR's live run does not protect this lock"

# --- a holder that already ended its PR holds it no longer --------------------
# its run is still alive on other work, but its newest step on this PR is
# terminal: the row left behind is stale (docs/review-mechanics.md → Live holder)
lock_case ended_holder 3300
holder_event 3300 dddd4444 review_step "PR #1 1111111 locked"
holder_event 300  dddd4444 review_step "PR #1 1111111 done"
holder_event 60   dddd4444 review_step "PR #7 7777777 locked"
run_preflight review
assert_jq '.reviews_due | length == 1' 'a run whose newest step on the PR is terminal does not protect its lock'

# --- a step written as `PR #<n>:` names the PR too ---------------------------
lock_case colon_step_holder 3300
holder_event 3300 eeee5555 review_step "PR #1: 1111111 locked"
holder_event 120  eeee5555
run_preflight review
assert_jq '.reviews_due | length == 0' 'a `PR #<n>:` locked step makes its run the holder'

# --- milestones that only sound final keep the holder -------------------------
# matched like the Stop hook: `rapid posted` and `skill:<name> done` are not done
lock_case rapid_posted_holder 3300
holder_event 3300 aaaa1111 review_step "PR #1 1111111 locked"
holder_event 600  aaaa1111 review_step "PR #1 1111111 rapid posted"
holder_event 120  aaaa1111
run_preflight review
assert_jq '.reviews_due | length == 0' '`rapid posted` is not terminal'
lock_case skill_done_holder 3300
holder_event 3300 aaaa1111 review_step "PR #1 1111111 locked"
holder_event 600  aaaa1111 review_step "PR #1 1111111 skill:security done"
holder_event 120  aaaa1111
run_preflight review
assert_jq '.reviews_due | length == 0' '`skill:<name> done` is not terminal'

# --- any live holder keeps the lock, not only the last one to lock ------------
lock_case second_holder_alive 3300
holder_event 3200 aaaa1111 review_step "PR #1 1111111 locked"
holder_event 3000 bbbb2222 review_step "PR #1 1111111 locked"
holder_event 60   aaaa1111
run_preflight review
assert_jq '.reviews_due | length == 0' 'the earlier holder is alive, so the lock stays'
assert_jq '.logs | any(contains("holder aaaa1111 active"))' 'the live holder is named'

# --- a recent event naming the PR keeps it, even without a locked step -------
# Crash-recovery gap: the `locked` event may predate log retention, so an
# unattributable but recent mention of this PR still counts as life.
lock_case unattributed_holder 3300
holder_event 90 dddd4444 tool_use "Bash [gh pr view 1 — PR #1 context]"
run_preflight review
assert_jq '.reviews_due | length == 0' 'recent PR-specific activity protects the lock'

# --- the fallback ignores a run that ended the PR -----------------------------
lock_case unattributed_ended 3300
holder_event 600 dddd4444 review_step "PR #1 1111111 composed"
holder_event 90  dddd4444 review_step "PR #1 1111111 done"
run_preflight review
assert_jq '.reviews_due | length == 1' 'a recent terminal step is no sign of life'

# --- review mode stops with an error without lib/holds.sh ---------------------
lock_case holds_lib_missing 3300
mkdir -p "$SANDBOX/scripts"
cp "$REPO_ROOT"/scripts/*.sh "$SANDBOX/scripts/"
cp -R "$REPO_ROOT/scripts/lib" "$SANDBOX/scripts/"
rm "$SANDBOX/scripts/lib/holds.sh"
REPO_ROOT="$SANDBOX" run_preflight review
assert_jq '.error | contains("lib/holds.sh unreadable")' 'the error names the missing lib'
assert_jq '.reviews_due == null' 'and no lock is taken over'

# --- REVIEWS.md has one writer at a time (lib/common.sh → with_state_lock) ----
# concurrent runs rewrite the file in place; twenty read-modify-write writers
# racing on it keep every row
new_case state_lock_concurrent_writers
F="$WORK/REVIEWS.md"
(
  . "$REPO_ROOT/scripts/lib/common.sh"
  add_row_held() { { cat "$F"; printf '| %s | sha | ts | - | done |\n' "$1"; } > "$F.$$.$1.tmp" && mv "$F.$$.$1.tmp" "$F"; }
  for n in $(seq 1 20); do with_state_lock "$F" add_row_held "$n" & done
  wait
)
rows="$(grep -cE '^\| [0-9]+ \|' "$F")"
if [ "$rows" = 20 ]; then printf 'ok   %s: twenty concurrent writers keep twenty rows\n' "$CASE"
else printf 'FAIL %s: twenty concurrent writers left %s rows\n' "$CASE" "$rows"; FAILED=1; fi
if [ -e "$F.lock" ]; then printf 'FAIL %s: the lock is left behind\n' "$CASE"; FAILED=1
else printf 'ok   %s: the lock is given back\n' "$CASE"; fi

new_case state_lock_dead_writer
F="$WORK/REVIEWS.md"; mkdir "$F.lock"
s=$(( $(date +%s) - 300 ))
touch -t "$(date -d "@$s" +%Y%m%d%H%M 2>/dev/null || date -r "$s" +%Y%m%d%H%M)" "$F.lock"
start=$(date +%s)
( . "$REPO_ROOT/scripts/lib/common.sh"; with_state_lock "$F" true )
if [ $(( $(date +%s) - start )) -lt 5 ] && [ ! -e "$F.lock" ]; then
  printf 'ok   %s: a dead writer'"'"'s lock is broken at once\n' "$CASE"
else printf 'FAIL %s: a dead writer'"'"'s lock held the write\n' "$CASE"; FAILED=1; fi

finish
