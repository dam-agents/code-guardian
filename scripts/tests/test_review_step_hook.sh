#!/usr/bin/env bash
# PostToolUse hook (scripts/harness/claude-code/log-review-step.sh): derives
# review_step milestones from the tool calls that perform them.
# Contract: docs/review.md → Progress logging (harness-derived steps).
. "$(dirname "$0")/helpers.sh"

HOOK="$REPO_ROOT/scripts/harness/claude-code/log-review-step.sh"

# feed the hook a PostToolUse payload for a Bash command
run_bash() { # <session> <command>
  jq -nc --arg s "$1" --arg c "$2" \
    '{hook_event_name:"PostToolUse", session_id:$s, tool_name:"Bash",
      tool_input:{command:$c}}' \
    | WORK_DIR="$WORK" bash "$HOOK" >/dev/null 2>&1
}

# feed the hook a PostToolUse payload for a Task (subagent) call
run_task() { # <session> <prompt> [description]
  jq -nc --arg s "$1" --arg p "$2" --arg d "${3:-}" \
    '{hook_event_name:"PostToolUse", session_id:$s, tool_name:"Task",
      tool_input:{prompt:$p, description:$d}}' \
    | WORK_DIR="$WORK" bash "$HOOK" >/dev/null 2>&1
}

# count review_step events whose msg contains <pattern>
count_steps() { # <pattern>
  jq -r 'select(.event=="review_step")|.msg' "$EVENTS" 2>/dev/null \
    | grep -c -- "$1" || true
}

assert_count() { # <pattern> <expected> <description>
  local got; got="$(count_steps "$1")"
  if [ "$got" -eq "$2" ]; then
    printf 'ok   %s: %s\n' "$CASE" "$3"
  else
    printf 'FAIL %s: %s (want %s matching "%s", got %s)\n' \
      "$CASE" "$3" "$2" "$1" "$got"
    FAILED=1
  fi
}

step_case() { # <case-name>
  new_case "$1"
  # the hook derives skill names from CONFIG.md, so the table is part of the fixture
  base_config '- artifact_skill: pr-artifact@acme/skills' '' \
    '## Review skills' '' \
    '| skill | source | trigger | section |' \
    '| --- | --- | --- | --- |' \
    '| doc-drift | acme/skills | always | Documentation Check |' \
    '| typescript-engineering | acme/skills | .ts,.js | TypeScript Review |'
  mkdir -p "$WORK/logs"
  EVENTS="$WORK/logs/events-$(date -u +%Y-%m-%d).jsonl"
  : > "$EVENTS"
  SID="s-$1-$$"
  rm -rf "/tmp/.cg-steps-$SID"
}
cleanup_markers() { rm -rf /tmp/.cg-steps-s-* 2>/dev/null || true; }
trap cleanup_markers EXIT

# --- a skill subagent produces its skill:<name> done step --------------------
step_case skill_from_task
run_task "$SID" "Run the doc-drift skill against PR #42 in /tmp/review-pr-42"
assert_count 'PR #42 skill:doc-drift done' 1 'a Task call logs the skill step'

# --- idempotent: the same skill twice logs once ------------------------------
step_case skill_idempotent
run_task "$SID" "doc-drift on PR #42"
run_task "$SID" "doc-drift on PR #42"
assert_count 'skill:doc-drift done' 1 'a repeated Task call does not double-log'

# --- distinct skills each log once, same PR ----------------------------------
step_case skill_distinct
run_task "$SID" "doc-drift for PR #42"
run_task "$SID" "typescript-engineering for PR #42"
assert_count 'PR #42 skill:' 2 'two different skills log two steps'

# --- distinct PRs are tracked separately -------------------------------------
step_case skill_two_prs
run_task "$SID" "doc-drift for PR #42"
run_task "$SID" "doc-drift for PR #43"
assert_count 'skill:doc-drift done' 2 'the same skill on two PRs logs twice'

# --- a Task with no recognisable PR is ignored -------------------------------
step_case task_no_pr
run_task "$SID" "doc-drift on the working tree"
assert_count 'review_step' 0 'a Task with no PR number logs nothing'

# --- a Task that is not a review skill is ignored ----------------------------
step_case task_not_a_skill
run_task "$SID" "Investigate the flaky test in PR #42"
assert_count 'review_step' 0 'an unrelated subagent logs nothing'

# --- the artifact skill is recognised too ------------------------------------
step_case skill_artifact
run_task "$SID" "pr-artifact for PR #42"
assert_count 'PR #42 skill:pr-artifact done' 1 'the artifact skill logs its step'

# --- a skill this instance has NOT configured logs nothing -------------------
step_case skill_unconfigured
run_task "$SID" "react-ui-engineering for PR #42"
assert_count 'review_step' 0 'a skill absent from the table logs nothing'

# --- no skills table → nothing to derive -------------------------------------
step_case skill_no_table
base_config
run_task "$SID" "doc-drift for PR #42"
assert_count 'review_step' 0 'an instance with no skills table logs no skill step'

# --- header/separator rows are not skill names -------------------------------
step_case skill_table_noise
run_task "$SID" "the skill --- ran for PR #42"
assert_count 'review_step' 0 'table header and separator rows are not skills'

# --- posting a review logs `posted <verdict>` --------------------------------
step_case posted_verdict
run_bash "$SID" 'gh api "repos/$REPO/pulls/42/reviews" -f event=COMMENT -f body=@/tmp/b'
assert_count 'PR #42 posted COMMENT' 1 'a review POST logs the verdict'

step_case posted_approve
run_bash "$SID" 'gh api repos/acme/widgets/pulls/7/reviews --field event=APPROVE'
assert_count 'PR #7 posted APPROVE' 1 'APPROVE is captured'

# --- a dedup READ of the same path must NOT log a post -----------------------
step_case posted_not_a_read
run_bash "$SID" 'gh api "repos/$REPO/pulls/42/reviews" --jq ".[] | .body"'
assert_count 'posted' 0 'a GET/read of the reviews path is not a post'

step_case posted_not_explicit_get
run_bash "$SID" 'gh api --method GET "repos/$REPO/pulls/42/reviews" -f event=COMMENT'
assert_count 'posted' 0 'an explicit --method GET is not a post'

# --- cloning the PR working dir logs `cloned` --------------------------------
step_case cloned_step
run_bash "$SID" 'git clone --depth 50 --single-branch -b feat https://x@github.com/a/b /tmp/review-pr-42'
assert_count 'PR #42 cloned' 1 'the PR clone logs the cloned step'

step_case cloned_idempotent
run_bash "$SID" 'git clone --depth 1 https://x/y /tmp/review-pr-42'
run_bash "$SID" 'git clone --depth 1 https://x/y /tmp/review-pr-42'
assert_count 'cloned' 1 'a repeated clone does not double-log'

# --- an ordinary Bash command logs nothing -----------------------------------
step_case bash_noise
run_bash "$SID" 'cd /tmp/review-pr-42 && git diff origin/main...HEAD | head -50'
assert_count 'review_step' 0 'an ordinary command logs no milestone'

# --- not a deployed instance (no CONFIG.md) → no-op --------------------------
step_case not_deployed
rm -f "$WORK/CONFIG.md"
run_task "$SID" "doc-drift for PR #42"
if [ ! -s "$EVENTS" ]; then
  printf 'ok   %s: no CONFIG.md → hook stays out of the way\n' "$CASE"
else
  printf 'FAIL %s: logged despite missing CONFIG.md\n' "$CASE"; FAILED=1
fi

# --- a different session re-emits (markers are per-run) ----------------------
step_case per_session
run_task "$SID" "doc-drift for PR #42"
SID2="$SID-b"; rm -rf "/tmp/.cg-steps-$SID2"
run_task "$SID2" "doc-drift for PR #42"
assert_count 'skill:doc-drift done' 2 'a new session logs its own steps'

# --- the REVIEWS.md row write derives locked / refresh / done -----------------
SHA="1111111111111111111111111111111111111111"
TS="2026-09-03T06:12:41Z"
step_case locked_from_row_write
run_bash "$SID" "printf '| 42 | $SHA | $TS | - | in_progress |\n' >> work/REVIEWS.md"
assert_count 'PR #42 1111111 locked' 1 'an in_progress row write logs locked'
run_bash "$SID" "sed -E \"s#^\| *42 \|.*#| 42 | $SHA | $TS | - | in_progress |#\" work/REVIEWS.md > work/REVIEWS.md.tmp && mv work/REVIEWS.md.tmp work/REVIEWS.md"
assert_count 'locked (refresh)' 1 'a later in_progress write is a lock refresh, not a second lock'
assert_count 'PR #42 1111111 locked$' 1 'locked itself stays logged once'
run_bash "$SID" "sed -E \"s#^\| *42 \|.*#| 42 | $SHA | $TS | APPROVE | done |#\" work/REVIEWS.md > work/REVIEWS.md.tmp && mv work/REVIEWS.md.tmp work/REVIEWS.md"
assert_count 'PR #42 1111111 done' 1 'the done row write logs done'

# --- releasing a lock this run took without a done is an abort ---------------
step_case aborted_from_awaiting_restore
run_bash "$SID" "printf '| 42 | $SHA | $TS | - | in_progress |\n' >> work/REVIEWS.md"
run_bash "$SID" "sed -E \"s#^\| *42 \|.*#| 42 | $SHA | $TS | COMMENT | awaiting_label |#\" work/REVIEWS.md > work/REVIEWS.md.tmp && mv work/REVIEWS.md.tmp work/REVIEWS.md"
assert_count 'PR #42 1111111 aborted (lock released)' 1 'an awaiting_label restore after a lock logs an abort'

step_case aborted_from_row_delete
run_bash "$SID" "printf '| 42 | $SHA | $TS | - | in_progress |\n' >> work/REVIEWS.md"
run_bash "$SID" "sed -i '/^| 42 |/d' work/REVIEWS.md"
assert_count 'PR #42 aborted (lock released)' 1 'deleting a locked row logs an abort'

# --- a prune (row delete without a lock this run) logs nothing ----------------
step_case prune_delete_not_an_abort
run_bash "$SID" "grep -v '^| 42 |' work/REVIEWS.md > work/REVIEWS.md.tmp && mv work/REVIEWS.md.tmp work/REVIEWS.md"
assert_count 'review_step' 0 'a row deletion without a lock in this run is not an abort'

# --- a preflight-style awaiting_label row on a PR never locked here is silent --
step_case awaiting_without_lock
run_bash "$SID" "printf '| 42 | $SHA | $TS | COMMENT | awaiting_label |\n' >> work/REVIEWS.md"
assert_count 'review_step' 0 'an awaiting_label row without a lock in this run logs nothing'

finish
