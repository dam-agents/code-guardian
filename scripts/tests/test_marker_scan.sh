#!/usr/bin/env bash
# Marker scan outcomes: a failed gh call is "unknown" (__api_error__), never
# "marker absent" — state_drift degrades to warn, the review decision defers.
. "$(dirname "$0")/helpers.sh"

SHA7="7777777777777777777777777777777777777777"

# --- audit: marker present at the row SHA -> state_drift ok --------------------
new_case drift_marker_ok
base_config
pr_json 7 "healthy PR" '[]' "$SHA7" | open_prs_fx
add_row 7 "$SHA7" "$(iso_ago 3600)" COMMENT done
fx 'api repos/acme/widgets/pulls/7/reviews?per_page=100' <<EOF
[{"body":"LGTM\n\n<!-- cg:review headRefOid=$SHA7 -->","submitted_at":"$(iso_ago 3600)"}]
EOF
run_preflight audit
assert_jq '.checks[] | select(.id == "state_drift") | .status == "ok"' 'verified marker → ok'

# --- audit: endpoints answer, marker genuinely absent -> still a fail ----------
new_case drift_real
base_config
pr_json 7 "drifted PR" '[]' "$SHA7" | open_prs_fx
add_row 7 "$SHA7" "$(iso_ago 3600)" COMMENT done
run_preflight audit
assert_jq '.checks[] | select(.id == "state_drift") | .status == "fail" and (.detail | contains("#7"))' \
  'verified-absent marker keeps failing'

# --- audit: the scan itself fails -> unverifiable warn, not a drift fail -------
new_case drift_api_error
base_config
pr_json 7 "unreachable PR" '[]' "$SHA7" | open_prs_fx
add_row 7 "$SHA7" "$(iso_ago 3600)" COMMENT done
fx_fail 'api repos/acme/widgets/pulls/7/reviews?per_page=100'
fx_fail 'api repos/acme/widgets/issues/7/comments?per_page=100'
run_preflight audit
assert_jq '.checks[] | select(.id == "state_drift") | .status == "warn" and (.detail | contains("unverifiable"))' \
  'failed scan degrades to warn'

# --- review: no local row + failed scan -> deferred, never a blind review ------
new_case review_scan_deferred
base_config
pr_json 7 "new PR" '[]' "$SHA7" | open_prs_fx
fx_fail 'api repos/acme/widgets/pulls/7/reviews?per_page=100'
fx_fail 'api repos/acme/widgets/issues/7/comments?per_page=100'
run_preflight review
assert_jq '.reviews_due | length == 0' 'no review scheduled on a failed scan'
assert_jq '.selfheals_due | length == 0' 'no self-heal invented on a failed scan'
assert_jq '.logs | any(contains("deferred"))' 'deferral surfaced in the logs'

# --- review: gh_get retry — one transient failure still yields the marker ------
new_case review_scan_retry
base_config
pr_json 7 "flaky PR" '[]' "$SHA7" | open_prs_fx
fx 'api repos/acme/widgets/pulls/7/reviews?per_page=100' <<EOF
[{"body":"LGTM\n\n<!-- cg:review headRefOid=$SHA7 -->","submitted_at":"$(iso_ago 3600)"}]
EOF
fx_fail_once 'api repos/acme/widgets/pulls/7/reviews?per_page=100'
run_preflight review
assert_jq '(.selfheals_due | length) == 1 and .selfheals_due[0].number == 7' \
  'marker found on the retry → self-heal due'
assert_jq '.reviews_due | length == 0' 'no duplicate review scheduled'

finish
