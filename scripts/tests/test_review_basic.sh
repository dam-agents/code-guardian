#!/usr/bin/env bash
# Review-mode basics: first review, same-SHA dedup, trigger cleanup,
# awaiting_label flip, label-gated re-review.
. "$(dirname "$0")/helpers.sh"

SHA1="1111111111111111111111111111111111111111"
SHA2="2222222222222222222222222222222222222222"

# --- first review due --------------------------------------------------------
new_case first_review
base_config
pr_json 1 "plain PR" '[]' "$SHA1" | open_prs_fx
run_preflight review
assert_jq '.nothing_to_do == false' 'run has work'
assert_jq '.reviews_due | length == 1' 'exactly one review due'
assert_jq '.reviews_due[0] | .number == 1 and .kind == "first" and .takeover == false and .urgent == false and .closed == false' 'first review, no flags'

# --- reviewed at live HEAD, no trigger → nothing ----------------------------
new_case same_sha_done
base_config
pr_json 1 "plain PR" '[]' "$SHA1" | open_prs_fx
add_row 1 "$SHA1" "$(iso_ago 3600)" APPROVE done
run_preflight review
assert_jq '.nothing_to_do == true' 'same-SHA dedup holds'

# --- reviewed at live HEAD + label → trigger cleanup, no review --------------
new_case label_cleanup
base_config
pr_json 1 "plain PR" '[{"name":"cg-rereview"}]' "$SHA1" | open_prs_fx
add_row 1 "$SHA1" "$(iso_ago 3600)" APPROVE done
run_preflight review
assert_jq '.reviews_due | length == 0' 'no review on same SHA'
assert_jq '(.label_cleanups_due | length) == 1 and .label_cleanups_due[0].label == true' 'label cleanup due'

# --- new commits without trigger → awaiting_label flip -----------------------
new_case awaiting_flip
base_config
pr_json 1 "plain PR" '[]' "$SHA1" | open_prs_fx
OLD_TS="$(iso_ago 7200)"
add_row 1 "$SHA2" "$OLD_TS" APPROVE done
run_preflight review
assert_jq '.nothing_to_do == true' 'no review without a trigger'
assert_file_contains "$WORK/REVIEWS.md" 'awaiting_label' 'row flipped to awaiting_label'
assert_file_contains "$WORK/REVIEWS.md" "$OLD_TS" 'flip kept the old timestamp'

# --- new commits + label → complete re-review with prior ---------------------
new_case rereview_due
base_config
pr_json 1 "plain PR" '[{"name":"cg-rereview"}]' "$SHA1" | open_prs_fx
add_row 1 "$SHA2" "$(iso_ago 7200)" COMMENT awaiting_label
run_preflight review
assert_jq '.reviews_due | length == 1' 'one re-review due'
assert_jq ".reviews_due[0] | .kind == \"re-review\" and .prior.sha == \"$SHA2\" and .prior.verdict == \"COMMENT\"" 're-review with prior'
assert_jq '.reviews_due[0].full == true' 'label-triggered re-review is complete'

# --- new commits + review request → delta re-review ---------------------------
new_case rereview_request_delta
base_config '- rereview_trigger: review-request'
pr_json 1 "plain PR" '[]' "$SHA1" \
  | jq '.requested_reviewers = [{login:"test-bot"}]' | open_prs_fx
add_row 1 "$SHA2" "$(iso_ago 7200)" COMMENT awaiting_label
run_preflight review
assert_jq '.reviews_due | length == 1' 'request-triggered re-review due'
assert_jq '.reviews_due[0] | .kind == "re-review" and .full == false' 'request-triggered re-review is delta'

# --- first reviews are always full --------------------------------------------
new_case first_full
base_config
pr_json 2 "fresh PR" '[]' "$SHA1" | open_prs_fx
run_preflight review
assert_jq '.reviews_due[0] | .kind == "first" and .full == true' 'first review flagged full'

finish
