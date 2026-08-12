#!/usr/bin/env bash
# In-progress lock semantics: fresh lock skips, stale lock takes over — but a
# lock past the TTL whose holder is still logging is left running.
# Contract: docs/review.md → Review tracking state, Live holder.
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

# --- a recent event naming the PR keeps it, even without a locked step -------
# Crash-recovery gap: the `locked` event may predate log retention, so an
# unattributable but recent mention of this PR still counts as life.
lock_case unattributed_holder 3300
holder_event 90 dddd4444 tool_use "Bash [gh pr view 1 — PR #1 context]"
run_preflight review
assert_jq '.reviews_due | length == 0' 'recent PR-specific activity protects the lock'

finish
