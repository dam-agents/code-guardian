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

# --- review: the unanchored scan reuses the anchored scan's reviews page -------
new_case review_scan_one_read
base_config
pr_json 7 "reviewed at an older SHA" '[]' "$SHA7" | open_prs_fx
fx 'api repos/acme/widgets/pulls/7/reviews?per_page=100' <<EOF
[{"body":"LGTM\n\n<!-- cg:review headRefOid=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa -->","submitted_at":"$(iso_ago 7200)"}]
EOF
GH_CALLS_LOG="$SANDBOX/calls.log" run_preflight review
assert_jq '.selfheals_due | length == 1 and .[0].sha == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" and .[0].status == "awaiting_label"' \
  'older-SHA marker still found by the unanchored scan'
[ "$(grep -c 'pulls/7/reviews' "$SANDBOX/calls.log")" = "1" ] \
  && printf 'ok   %s: %s\n' "$CASE" 'the reviews page is read once' \
  || { printf 'FAIL %s: reviews page read %s times\n' "$CASE" "$(grep -c 'pulls/7/reviews' "$SANDBOX/calls.log")"; FAILED=1; }

# --- review: a full first page is followed to the marker on the next one -------
# 100 reviews by others fill page 1; the bot's review sits on page 2
others_page() { jq -n '[range(100) | {body: "lgtm", submitted_at: "2026-07-01T00:00:00Z", user: {login: "bob"}}]'; }
new_case review_scan_second_page
base_config
pr_json 7 "long-discussed PR" '[]' "$SHA7" | open_prs_fx
others_page | fx 'api repos/acme/widgets/pulls/7/reviews?per_page=100'
fx 'api repos/acme/widgets/pulls/7/reviews?per_page=100&page=2' <<EOF
[{"body":"LGTM\n\n<!-- cg:review headRefOid=$SHA7 -->","submitted_at":"$(iso_ago 3600)"}]
EOF
run_preflight review
assert_jq '(.selfheals_due | length) == 1 and .selfheals_due[0].number == 7 and .selfheals_due[0].status == "done"' \
  'marker on page 2 → self-heal due'
assert_jq '.reviews_due | length == 0' 'no duplicate first review'

# --- review: a page past the first that fails is unknown, never absent ---------
new_case review_scan_second_page_fails
base_config
pr_json 7 "long-discussed PR" '[]' "$SHA7" | open_prs_fx
others_page | fx 'api repos/acme/widgets/pulls/7/reviews?per_page=100'
fx_fail 'api repos/acme/widgets/pulls/7/reviews?per_page=100&page=2'
run_preflight review
assert_jq '(.reviews_due | length) == 0 and (.selfheals_due | length) == 0' 'nothing decided on a list read in part'
assert_jq '.logs | any(contains("deferred"))' 'deferral surfaced in the logs'

finish
