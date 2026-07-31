#!/usr/bin/env bash
# Stop hook (scripts/harness/claude-code/enforce-review-completion.sh):
# blocks a stop that leaves a PR locked without a terminal review_step.
# Contract: docs/review.md → Completion enforcement.
. "$(dirname "$0")/helpers.sh"

HOOK="$REPO_ROOT/scripts/harness/claude-code/enforce-review-completion.sh"

# append a review_step event for <run> with <msg>
step() { # <run> <msg>
  jq -nc --arg r "$1" --arg m "$2" \
    '{ts:"2026-07-31T10:00:00Z", run:$r, job:"review", level:"info",
      event:"review_step", msg:$m}' >> "$EVENTS"
}

# run the hook for <run>; exit status lands in $RC
run_hook() { # <run> [stop_hook_active]
  printf '{"hook_event_name":"Stop","session_id":"%s","stop_hook_active":%s}' \
    "$1" "${2:-false}" \
    | WORK_DIR="$WORK" bash "$HOOK" >/dev/null 2>"$SANDBOX/stderr"
  RC=$?
}

assert_rc() { # <expected> <description>
  if [ "$RC" -eq "$1" ]; then
    printf 'ok   %s: %s\n' "$CASE" "$2"
  else
    printf 'FAIL %s: %s (want exit %s, got %s)\n     stderr: %s\n' \
      "$CASE" "$2" "$1" "$RC" "$(cut -c1-200 < "$SANDBOX/stderr")"
    FAILED=1
  fi
}

hook_case() { # <case-name>
  new_case "$1"
  base_config
  mkdir -p "$WORK/logs"
  EVENTS="$WORK/logs/events-$(date -u +%Y-%m-%d).jsonl"
  : > "$EVENTS"
}

# --- locked without a terminal step → blocked --------------------------------
hook_case stop_mid_pipeline
step r1 "PR #10 abc1234 locked"
step r1 "PR #10 abc1234 cloned"
step r1 "PR #10 abc1234 skill:doc-drift done"     # a skill report is not terminal
run_hook r1
assert_rc 2 'mid-pipeline stop refused'
assert_file_contains "$SANDBOX/stderr" 'PR(s) 10' 'stderr names the owed PR'
assert_file_contains "$EVENTS" 'review_incomplete' 'logged a review_incomplete warn'

# --- posted + done → clean stop ----------------------------------------------
hook_case stop_completed
step r1 "PR #10 abc1234 locked"
step r1 "PR #10 abc1234 posted APPROVE"
step r1 "PR #10 abc1234 done"
run_hook r1
assert_rc 0 'completed review stops cleanly'

# --- explicit abort is terminal too ------------------------------------------
hook_case stop_aborted
step r1 "PR #10 abc1234 locked"
step r1 "PR #10 abc1234 aborted HEAD-moved"
run_hook r1
assert_rc 0 'aborted review stops cleanly'

# --- urgent: rapid post alone still owes the full review ---------------------
hook_case stop_rapid_only
step r1 "PR #10 abc1234 locked"
step r1 "PR #10 abc1234 rapid posted"
run_hook r1
assert_rc 2 'rapid preliminary post is not terminal'

# --- mixed: one done, one owed ------------------------------------------------
hook_case stop_partial
step r1 "PR #10 abc1234 locked"
step r1 "PR #10 abc1234 done"
step r1 "PR #11 def5678 locked (takeover)"
run_hook r1
assert_rc 2 'a single unfinished PR still blocks'
assert_file_contains "$SANDBOX/stderr" 'PR(s) 11' 'only the owed PR is named'

# --- another run's stall is not ours -----------------------------------------
hook_case stop_other_run
step r1 "PR #10 abc1234 locked"
step r1 "PR #10 abc1234 done"
step r2 "PR #11 def5678 locked"
run_hook r1
assert_rc 0 "another run's open lock is ignored"

# --- loop guard: already blocked once this turn -------------------------------
hook_case stop_loop_guard
step r1 "PR #10 abc1234 locked"
run_hook r1 true
assert_rc 0 'stop_hook_active suppresses a second block'

# --- nothing locked (prune-only run) → clean stop ----------------------------
hook_case stop_no_locks
step r1 "PR #15: pruned (MERGED) — no artifacts to clean up"
run_hook r1
assert_rc 0 'a run with no locks stops cleanly'

# --- not a deployed instance (no CONFIG.md) → no-op --------------------------
hook_case stop_not_deployed
rm -f "$WORK/CONFIG.md"
step r1 "PR #10 abc1234 locked"
run_hook r1
assert_rc 0 'no CONFIG.md → hook stays out of the way'

finish
