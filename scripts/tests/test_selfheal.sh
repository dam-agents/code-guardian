#!/usr/bin/env bash
# Remote-marker self-heal: anchored marker at the live HEAD → done row; an
# older unanchored marker without a trigger → awaiting_label row.
. "$(dirname "$0")/helpers.sh"

SHA1="1111111111111111111111111111111111111111"
SHA2="2222222222222222222222222222222222222222"

reviews_fx() { # <marker sha>
  jq -n --arg sha "$1" \
    '[{body: ("review body\n<!-- cg:review headRefOid=" + $sha + " -->"),
       submitted_at: "2026-07-29T09:00:00Z", user: {login: "test-bot"}}]' \
    | fx 'api repos/acme/widgets/pulls/1/reviews?per_page=100'
}

# --- marker at live HEAD → self-heal done ------------------------------------
new_case selfheal_done
base_config
pr_json 1 "recovered PR" '[]' "$SHA1" | open_prs_fx
reviews_fx "$SHA1"
run_preflight review
assert_jq '.reviews_due | length == 0' 'no duplicate review'
assert_jq '(.selfheals_due | length) == 1 and (.selfheals_due[0] | .status == "done" and .sha == "'"$SHA1"'")' 'self-heal to done'

# --- older marker, no trigger → self-heal awaiting_label ----------------------
new_case selfheal_awaiting
base_config
pr_json 1 "moved-on PR" '[]' "$SHA1" | open_prs_fx
reviews_fx "$SHA2"
run_preflight review
assert_jq '.reviews_due | length == 0' 'no untriggered re-review'
assert_jq '(.selfheals_due | length) == 1 and (.selfheals_due[0] | .status == "awaiting_label" and .sha == "'"$SHA2"'")' 'self-heal to awaiting_label'

finish
