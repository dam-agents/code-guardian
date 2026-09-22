#!/usr/bin/env bash
# CI failure triage detection (docs/ci-triage.md): a posted review at the live
# HEAD whose rollup turned red is due; a running rollup, a green one, a marker
# already written, a stale review and the disabled key are not.
. "$(dirname "$0")/helpers.sh"

SHA="1111111111111111111111111111111111111111"

runs_fx() { # <status> <conclusion> [name]
  jq -n --arg st "$1" --arg c "$2" --arg n "${3:-build}" \
    '{total_count:1, check_runs:[{name:$n, status:$st,
      conclusion:(if $c == "-" then null else $c end),
      details_url:"https://github.com/acme/widgets/actions/runs/9/job/42",
      output:{title:"failed", summary:"step 3 failed", text:""}}]}' \
    | fx "api repos/acme/widgets/commits/$SHA/check-runs?per_page=100"
}

reviewed() { # [age-seconds]
  base_config '- ci_triage: enabled'
  pr_json 1 "a reviewed PR" '[]' "$SHA" | open_prs_fx
  add_row 1 "$SHA" "$(iso_ago "${1:-7200}")" "COMMENT" "done"
}

# --- terminal and failing → triage due ---------------------------------------
new_case ci_failed
reviewed
runs_fx completed failure
run_preflight review
assert_jq '(.ci_failures_due | length) == 1' 'one triage due'
assert_jq '.ci_failures_due[0] | .number == 1 and .sha == "'"$SHA"'" and .checks == ["build"]' 'entry names the PR, SHA and check'
assert_jq '.nothing_to_do == false' 'a due triage is work'
assert_jq '.config.ci_triage == "enabled"' 'the resolved key travels in the config object'

# --- still running → nothing --------------------------------------------------
new_case ci_running
reviewed
runs_fx in_progress -
run_preflight review
assert_jq '(.ci_failures_due | length) == 0' 'a running rollup is not triaged'

# --- green → nothing ----------------------------------------------------------
new_case ci_green
reviewed
runs_fx completed success
run_preflight review
assert_jq '(.ci_failures_due | length) == 0' 'a passing rollup is not triaged'

# --- cancelled is not a failure ----------------------------------------------
new_case ci_cancelled
reviewed
runs_fx completed cancelled
run_preflight review
assert_jq '(.ci_failures_due | length) == 0' 'a cancelled check is not a failure'

# --- marker already written → once per SHA ------------------------------------
new_case ci_marker
reviewed
runs_fx completed failure
printf 'body\n<!-- ci-triage: %s -->\n' "$SHA" > "$WORK/reviews/pr-1.md"
run_preflight review
assert_jq '(.ci_failures_due | length) == 0' 'a marked SHA is never triaged twice'

# --- past the 24 h window → stale news ----------------------------------------
new_case ci_stale
reviewed 108000
runs_fx completed failure
run_preflight review
assert_jq '(.ci_failures_due | length) == 0' 'a review older than the window is not triaged'

# --- disabled key → the rollup is never read ----------------------------------
new_case ci_disabled
base_config
pr_json 1 "a reviewed PR" '[]' "$SHA" | open_prs_fx
add_row 1 "$SHA" "$(iso_ago 7200)" "COMMENT" "done"
runs_fx completed failure
GH_CALLS_LOG="$SANDBOX/calls.log" run_preflight review
assert_jq '(.ci_failures_due | length) == 0' 'disabled by default'
assert_file_contains "$SANDBOX/calls.log" '^' 'gh was called at all'
grep -q "commits/$SHA/check-runs" "$SANDBOX/calls.log" \
  && { printf '  FAIL: the rollup was read although ci_triage is off\n'; FAILED=1; } \
  || printf '  ok: no rollup call when the key is off\n'

# --- the older commit-status API is the fallback ------------------------------
new_case ci_legacy_status
reviewed
jq -n '{total_count:0, check_runs:[]}' | fx "api repos/acme/widgets/commits/$SHA/check-runs?per_page=100"
jq -n '{state:"failure", statuses:[{context:"jenkins/pr", state:"failure",
        target_url:"https://ci.example.com/7", description:"3 tests failed"}]}' \
  | fx "api repos/acme/widgets/commits/$SHA/status"
run_preflight review
assert_jq '(.ci_failures_due | length) == 1 and .ci_failures_due[0].checks == ["jenkins/pr"]' 'commit statuses are read when no check run exists'

finish
