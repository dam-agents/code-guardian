#!/usr/bin/env bash
# Prune detection: verified CLOSED/MERGED rows prune (with artifact ids); a
# closed PR whose row is a RAPID in_progress lock defers the prune and emits a
# closed:true review entry (the owed full review — docs/review.md).
. "$(dirname "$0")/helpers.sh"

SHA1="1111111111111111111111111111111111111111"
SHA4="4444444444444444444444444444444444444444"
SHA5="5555555555555555555555555555555555555555"

closed_pr_fx() { # <number> <sha> <merged> [author]
  jq -n --argjson n "$1" --arg sha "$2" --argjson m "$3" --arg a "${4:-dave}" \
    '{number:$n, state:"closed", merged:$m, title:"gone PR",
      user:{login:$a}, head:{sha:$sha, ref:("b"+($n|tostring))}}' \
    | fx "api repos/acme/widgets/pulls/$1"
}

# --- done row + closed PR → prune with artifact ids ---------------------------
new_case prune_done
base_config
pr_json 1 "still open" '[]' "$SHA1" | open_prs_fx
add_row 1 "$SHA1" "$(iso_ago 3600)" APPROVE done
add_row 5 "$SHA5" "$(iso_ago 90000)" APPROVE done
closed_pr_fx 5 "$SHA5" false
printf '# PR #5: gone PR\n<!-- artifact-gist: abc123 -->\n<!-- artifact-dam: dam_1 -->\n' > "$WORK/reviews/pr-5.md"
run_preflight review
assert_jq '.prunes_due | length == 1' 'one prune due'
assert_jq '.prunes_due[0] | .number == 5 and .state == "CLOSED" and .gist_id == "abc123" and .dam_id == "dam_1"' 'prune carries artifact ids'
assert_jq '.reviews_due | length == 0' 'nothing to review'

# --- RAPID lock + merged PR → closed review entry instead of prune ------------
new_case closed_rapid_defers_prune
base_config '- urgent_label: urgent'
pr_json 1 "still open" '[]' "$SHA1" | open_prs_fx
add_row 1 "$SHA1" "$(iso_ago 3600)" APPROVE done
add_row 4 "$SHA4" "$(iso_ago 5400)" RAPID in_progress
closed_pr_fx 4 "$SHA4" true
run_preflight review
assert_jq '.prunes_due | length == 0' 'prune deferred'
assert_jq '.reviews_due | length == 1' 'owed full review emitted'
assert_jq ".reviews_due[0] | .number == 4 and .closed == true and .urgent == true and .kind == \"first\" and .prior.verdict == \"RAPID\" and .head_sha == \"$SHA4\"" 'closed entry shape'

# --- a bot author keeps the REST login, `[bot]` suffix included ---------------
new_case closed_rapid_bot_author
base_config
pr_json 1 "still open" '[]' "$SHA1" | open_prs_fx
add_row 1 "$SHA1" "$(iso_ago 3600)" APPROVE done
add_row 4 "$SHA4" "$(iso_ago 5400)" RAPID in_progress
closed_pr_fx 4 "$SHA4" true 'dependabot[bot]'
run_preflight review
assert_jq '.reviews_due[0].author == "dependabot[bot]"' 'bot login matches the REST form'

# --- the state checks are one batched call, not one call per row -------------
SHA6="6666666666666666666666666666666666666666"
new_case prune_batched
base_config
pr_json 1 "still open" '[]' "$SHA1" | open_prs_fx
add_row 1 "$SHA1" "$(iso_ago 3600)" APPROVE done
add_row 5 "$SHA5" "$(iso_ago 90000)" APPROVE done
add_row 6 "$SHA6" "$(iso_ago 90000)" APPROVE done
closed_pr_fx 5 "$SHA5" false
closed_pr_fx 6 "$SHA6" true
GH_CALLS_LOG="$SANDBOX/calls.log" run_preflight review
assert_jq '[.prunes_due[] | "\(.number):\(.state)"] == ["5:CLOSED", "6:MERGED"]' 'both rows prune, in row order'
[ "$(grep -c 'PruneStates' "$SANDBOX/calls.log")" = "1" ] && ! grep -qE 'pulls/[56]$' "$SANDBOX/calls.log" \
  && printf 'ok   %s: %s\n' "$CASE" 'one batched call, no per-row call' \
  || { printf 'FAIL %s: calls were %s\n' "$CASE" "$(tr '\n' ';' < "$SANDBOX/calls.log" | cut -c1-300)"; FAILED=1; }

# --- a failed batch falls back to the per-row call ----------------------------
new_case prune_batch_failed
base_config
pr_json 1 "still open" '[]' "$SHA1" | open_prs_fx
add_row 1 "$SHA1" "$(iso_ago 3600)" APPROVE done
add_row 5 "$SHA5" "$(iso_ago 90000)" APPROVE done
closed_pr_fx 5 "$SHA5" false
fx_fail 'graphql_prune_states'
GH_CALLS_LOG="$SANDBOX/calls.log" run_preflight review
assert_jq '.prunes_due | length == 1 and .[0].state == "CLOSED"' 'prune still verified per PR'
assert_file_contains "$SANDBOX/calls.log" 'pulls/5$' 'the per-row call answered instead'

# --- a PR the batch leaves unanswered is read per row; the rest are not --------
new_case prune_batch_partial
base_config
pr_json 1 "still open" '[]' "$SHA1" | open_prs_fx
add_row 1 "$SHA1" "$(iso_ago 3600)" APPROVE done
add_row 5 "$SHA5" "$(iso_ago 90000)" APPROVE done
add_row 6 "$SHA6" "$(iso_ago 90000)" APPROVE done
closed_pr_fx 6 "$SHA6" false
printf '{"data":{"repository":{"p5":{"state":"MERGED","headRefOid":"%s","headRefName":"b5","title":"gone PR","author":{"login":"dave"}},"p6":null}}}\n' "$SHA5" \
  > "$GH_FIXTURES/graphql_prune_states"
GH_CALLS_LOG="$SANDBOX/calls.log" run_preflight review
assert_jq '[.prunes_due[] | "\(.number):\(.state)"] == ["5:MERGED", "6:CLOSED"]' 'batch answer and per-row answer both prune'
! grep -q 'pulls/5$' "$SANDBOX/calls.log" && grep -q 'pulls/6$' "$SANDBOX/calls.log" \
  && printf 'ok   %s: %s\n' "$CASE" 'only the unanswered PR is read per row' \
  || { printf 'FAIL %s: calls were %s\n' "$CASE" "$(tr '\n' ';' < "$SANDBOX/calls.log" | cut -c1-300)"; FAILED=1; }

# --- a PR no call can answer is skipped, never pruned -------------------------
new_case prune_unanswered_skipped
base_config
pr_json 1 "still open" '[]' "$SHA1" | open_prs_fx
add_row 1 "$SHA1" "$(iso_ago 3600)" APPROVE done
add_row 5 "$SHA5" "$(iso_ago 90000)" APPROVE done
fx_fail 'api repos/acme/widgets/pulls/5'
run_preflight review
assert_jq '.prunes_due | length == 0' 'no prune without a verified state'

finish
