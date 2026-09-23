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
assert_out_absent 'head_sha' 'the worklist JSON stays out of the prompt'
if [ -n "$WORKLIST" ] && [ "$(ls -l "$WORKLIST" 2>/dev/null | cut -c5-10)" = "------" ]; then
  printf 'ok   %s: the worklist file is readable by this instance alone\n' "$CASE"
else printf 'FAIL %s: the worklist file is group- or world-readable\n' "$CASE"; FAILED=1; fi

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

new_case precheck_no_mode
base_config
run_precheck ""
assert_rc 2 'a gate registered without a mode never skips a fire'
assert_out_contains 'no mode given' 'and says which modes exist'

# --- a gate that cannot decide starts the session ----------------------------
# preflight printing no JSON (a crash, a truncated write) must never read as
# "nothing to do" — that would silently stop the heartbeat.
new_case precheck_no_json
base_config
mkdir -p "$SANDBOX/scripts/lib"
cp "$REPO_ROOT/scripts/precheck.sh" "$REPO_ROOT/scripts/log.sh" "$SANDBOX/scripts/"
cp "$REPO_ROOT/scripts/lib/toolpath.sh" "$SANDBOX/scripts/lib/"
printf '#!/usr/bin/env bash\nprintf "gh: command not found\\n" >&2\nexit 127\n' > "$SANDBOX/scripts/preflight.sh"
run_precheck review "$SANDBOX/scripts"
assert_rc 2 'no JSON means the gate broke, not that the run is idle'
assert_out_contains 'manually' 'the prompt tells the run to do the work itself'
assert_out_contains 'exit 127' 'and names the exit code preflight left'
assert_out_contains 'command not found' 'and the stderr that explains it'
assert_file_contains "$WORK/logs/events-$(date -u +%Y-%m-%d).jsonl" 'command not found' \
  'the cause also reaches the structured log'

# --- no answer from the API is a broken gate, not an idle tick ---------------
# preflight still prints its JSON, but `error` says it never decided: the fire
# must start the session, with the API's own error text in the prompt
new_case precheck_api_down
base_config
fx_fail 'api repos/acme/widgets/pulls?state=open&per_page=100' 1
fx_err 'api repos/acme/widgets/pulls?state=open&per_page=100' 'HTTP 503: Service Unavailable'
run_precheck review
assert_rc 2 'an API that does not answer never skips the fire'
assert_out_contains 'could not decide' 'the prompt says the gate did not decide'
assert_out_contains 'HTTP 503' 'and carries the API error that explains it'
assert_out_contains 'manually' 'and tells the run to do the work itself'
assert_file_contains "$WORK/logs/events-$(date -u +%Y-%m-%d).jsonl" 'HTTP 503' \
  'the cause also reaches the structured log'

new_case precheck_api_garbage
base_config
printf '<html>gateway error</html>' | fx 'api repos/acme/widgets/pulls?state=open&per_page=100'
run_precheck review
assert_rc 2 'an answer that is not a PR list never reads as idle'

new_case precheck_no_open_prs
base_config
printf '[]' | fx 'api repos/acme/widgets/pulls?state=open&per_page=100'
run_precheck review
assert_rc 1 'an empty PR list is a real answer: the idle fire is skipped'

# --- work is due but the worklist cannot be written --------------------------
# the bookkeeping of this pass is already spent, so the gate must start the
# session (exit 0) and name no path, never skip the fire
new_case precheck_unwritable
base_config
mkdir -p "$SANDBOX/scripts/lib"
cp "$REPO_ROOT/scripts/precheck.sh" "$REPO_ROOT/scripts/log.sh" "$SANDBOX/scripts/"
cp "$REPO_ROOT/scripts/lib/toolpath.sh" "$SANDBOX/scripts/lib/"
printf '#!/usr/bin/env bash\nprintf %%s "{\\"nothing_to_do\\":false,\\"reviews_due\\":[{\\"number\\":7}],\\"logs\\":[\\"1 PR due\\"]}"\n' \
  > "$SANDBOX/scripts/preflight.sh"
mkdir -p "$SANDBOX/tmp"
chmod 500 "$SANDBOX/tmp"
run_precheck review "$SANDBOX/scripts"
chmod 700 "$SANDBOX/tmp"
assert_rc 0 'an unwritable worklist starts the session anyway'
assert_out_absent '^worklist: ' 'and names no path'
assert_out_contains 'could not be written' 'and says why the run recomputes it'
assert_out_contains 'stall alert may be missing' 'and what the spent bookkeeping costs'

# --- the gate cleans up after itself ----------------------------------------
# a skipped fire has no session to sweep its scratch, so the gate does it
new_case precheck_sweep
base_config
pr_json 7 "plain PR" '[]' "$SHA1" | open_prs_fx
mkdir -p "$SANDBOX/tmp"
touch -t 202001010000 "$SANDBOX/tmp/cg-worklist-review-old.json"
: > "$SANDBOX/tmp/cg-worklist-review-fresh.json"
touch -t 202001010000 "$SANDBOX/tmp/cg-files.deadbeef"
touch -t 202001010000 "$SANDBOX/tmp/cg-mentions-ic.deadbeef"
: > "$SANDBOX/tmp/review-pr-9.diff"
run_precheck review
if [ ! -e "$SANDBOX/tmp/cg-worklist-review-old.json" ]; then
  printf 'ok   %s: a worklist past the 3h window is reclaimed\n' "$CASE"
else printf 'FAIL %s: the stale worklist was kept\n' "$CASE"; FAILED=1; fi
if [ ! -e "$SANDBOX/tmp/cg-files.deadbeef" ] && [ ! -e "$SANDBOX/tmp/cg-mentions-ic.deadbeef" ]; then
  printf 'ok   %s: scratch a killed gate left behind is reclaimed too\n' "$CASE"
else printf 'FAIL %s: the preflight scratch of a killed gate was kept\n' "$CASE"; FAILED=1; fi
if [ -e "$SANDBOX/tmp/cg-worklist-review-fresh.json" ]; then
  printf 'ok   %s: a fresh worklist is kept (a live run may still read it)\n' "$CASE"
else printf 'FAIL %s: a fresh worklist was deleted\n' "$CASE"; FAILED=1; fi
if [ -e "$SANDBOX/tmp/review-pr-9.diff" ]; then
  printf 'ok   %s: the sweep touches nothing else in tmp\n' "$CASE"
else printf 'FAIL %s: the sweep deleted a review leftover\n' "$CASE"; FAILED=1; fi

finish
