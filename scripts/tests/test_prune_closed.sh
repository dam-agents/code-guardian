#!/usr/bin/env bash
# Prune detection: verified CLOSED/MERGED rows prune (with artifact ids); a
# closed PR whose row is a RAPID in_progress lock defers the prune and emits a
# closed:true review entry (the owed full review — docs/review.md).
. "$(dirname "$0")/helpers.sh"

SHA1="1111111111111111111111111111111111111111"
SHA4="4444444444444444444444444444444444444444"
SHA5="5555555555555555555555555555555555555555"

closed_pr_fx() { # <number> <sha> <merged>
  jq -n --argjson n "$1" --arg sha "$2" --argjson m "$3" \
    '{number:$n, state:"closed", merged:$m, title:"gone PR",
      user:{login:"dave"}, head:{sha:$sha, ref:("b"+($n|tostring))}}' \
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

finish
