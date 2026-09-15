#!/usr/bin/env bash
# The schedule gate (scripts/precheck.sh): an idle fire is skipped with exit 1,
# a fire with work exits 0 and names one readable worklist, and a gate that
# cannot decide exits 2 so the platform starts the session anyway.
. "$(dirname "$0")/helpers.sh"

SHA1="1111111111111111111111111111111111111111"

# --- idle review tick: no session, no output ---------------------------------
new_case precheck_idle
base_config
pr_json 1 "plain PR" '[]' "$SHA1" | open_prs_fx
add_row 1 "$SHA1" "$(iso_ago 3600)" APPROVE done
run_precheck review
assert_rc 1 'nothing to do skips the fire'
if [ -z "$OUT" ]; then printf 'ok   %s: a skipped fire prints nothing\n' "$CASE"
else printf 'FAIL %s: a skipped fire printed: %.200s\n' "$CASE" "$OUT"; FAILED=1; fi
if [ -z "$(ls "$SANDBOX/tmp"/cg-worklist-* 2>/dev/null)" ]; then
  printf 'ok   %s: no worklist file is left behind\n' "$CASE"
else printf 'FAIL %s: a skipped fire wrote a worklist file\n' "$CASE"; FAILED=1; fi
assert_file_contains "$WORK/HEARTBEAT.log" 'nothing_to_do=true' 'the tick is still recorded in HEARTBEAT.log'
assert_file_contains "$WORK/logs/events-$(date -u +%Y-%m-%d).jsonl" '"event":"precheck"' 'and as a precheck event'

# --- work due: exit 0, one worklist, the run reads it ------------------------
new_case precheck_work_due
base_config
pr_json 7 "plain PR" '[]' "$SHA1" | open_prs_fx
run_precheck review
assert_rc 0 'a first review due starts the session'
assert_out_contains '^worklist: ' 'the gate names the worklist path'
assert_out_contains 'reviews_due=1 (#7)' 'the summary says what is due, with the PR number'
assert_out_contains 'do not run preflight.sh again' 'and forbids a second preflight pass'
if [ -n "$WORKLIST" ] && jq -e '.mode == "review" and .nothing_to_do == false and (.reviews_due[0].number == 7)' "$WORKLIST" >/dev/null 2>&1; then
  printf 'ok   %s: the file holds the full worklist\n' "$CASE"
else
  printf 'FAIL %s: worklist %s does not hold the review (%.200s)\n' "$CASE" "${WORKLIST:-<none>}" "$(cat "${WORKLIST:-/dev/null}" 2>/dev/null)"
  FAILED=1
fi
# the payload itself never travels in the prompt — only the summary does
if [ "$(printf '%s' "$OUT" | grep -c 'head_sha') " = "0 " ]; then
  printf 'ok   %s: the worklist JSON stays out of the prompt\n' "$CASE"
else printf 'FAIL %s: the gate printed the worklist itself\n' "$CASE"; FAILED=1; fi

# --- ungated and unknown modes ----------------------------------------------
new_case precheck_audit_ungated
base_config
pr_json 1 "plain PR" '[]' "$SHA1" | open_prs_fx
run_precheck audit
assert_rc 2 'audit is never gated'
assert_out_contains 'preflight.sh" audit' 'and says what the session must run'

new_case precheck_unknown_mode
base_config
run_precheck nonsense
assert_rc 2 'an unknown mode never skips a fire'

# --- a gate that cannot decide starts the session ----------------------------
# preflight printing no JSON (a crash, a truncated write) must never read as
# "nothing to do" — that would silently stop the heartbeat.
new_case precheck_no_json
base_config
mkdir -p "$SANDBOX/scripts/lib"
cp "$REPO_ROOT/scripts/precheck.sh" "$REPO_ROOT/scripts/log.sh" "$SANDBOX/scripts/"
cp "$REPO_ROOT/scripts/lib/toolpath.sh" "$SANDBOX/scripts/lib/"
printf '#!/usr/bin/env bash\nprintf "gh: command not found\\n"\nexit 127\n' > "$SANDBOX/scripts/preflight.sh"
run_precheck review "$SANDBOX/scripts"
assert_rc 2 'no JSON means the gate broke, not that the run is idle'
assert_out_contains 'manually' 'the prompt tells the run to do the work itself'

# --- the gate cleans up after itself ----------------------------------------
# a skipped fire has no session to sweep its scratch, so the gate does it
new_case precheck_sweep
base_config
pr_json 7 "plain PR" '[]' "$SHA1" | open_prs_fx
mkdir -p "$SANDBOX/tmp"
touch -t 202001010000 "$SANDBOX/tmp/cg-worklist-review-old.json"
: > "$SANDBOX/tmp/cg-worklist-review-fresh.json"
: > "$SANDBOX/tmp/review-pr-9.diff"
run_precheck review
if [ ! -e "$SANDBOX/tmp/cg-worklist-review-old.json" ]; then
  printf 'ok   %s: a worklist past the 3h window is reclaimed\n' "$CASE"
else printf 'FAIL %s: the stale worklist was kept\n' "$CASE"; FAILED=1; fi
if [ -e "$SANDBOX/tmp/cg-worklist-review-fresh.json" ]; then
  printf 'ok   %s: a fresh worklist is kept (a live run may still read it)\n' "$CASE"
else printf 'FAIL %s: a fresh worklist was deleted\n' "$CASE"; FAILED=1; fi
if [ -e "$SANDBOX/tmp/review-pr-9.diff" ]; then
  printf 'ok   %s: the sweep touches nothing else in tmp\n' "$CASE"
else printf 'FAIL %s: the sweep deleted a review leftover\n' "$CASE"; FAILED=1; fi

finish
