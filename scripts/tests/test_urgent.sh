#!/usr/bin/env bash
# urgent_label: entry flagging + urgent-first ordering + one-time Slack alert
# (emitted only under slack_notifications: enabled, deduped by the
# urgent-announced marker).
. "$(dirname "$0")/helpers.sh"

SHA1="1111111111111111111111111111111111111111"
SHA2="2222222222222222222222222222222222222222"
SHA3="3333333333333333333333333333333333333333"

open_three() {
  { pr_json 1 "plain PR" '[]' "$SHA1"
    pr_json 2 "urgent PR" '[{"name":"urgent"}]' "$SHA2" bob
    pr_json 3 "another plain PR" '[]' "$SHA3"
  } | open_prs_fx
}

# --- urgent flag + ordering, alerts off without Slack ------------------------
new_case urgent_ordering
base_config '- urgent_label: urgent'
open_three
run_preflight review
assert_jq '.reviews_due | length == 3' 'three reviews due'
assert_jq '.reviews_due[0] | .number == 2 and .urgent == true' 'urgent PR ordered first'
assert_jq '[.reviews_due[1,2].number] == [1,3]' 'non-urgent keep stable order'
assert_jq '.urgent_alerts_due | length == 0' 'no alert while Slack disabled'

# --- Slack enabled → alert due once ------------------------------------------
new_case urgent_alert
base_config '- urgent_label: urgent' '- slack_notifications: enabled'
open_three
run_preflight review
assert_jq '.urgent_alerts_due | length == 1' 'one alert due'
assert_jq '.urgent_alerts_due[0] | .number == 2 and .author == "bob" and (.url | length > 0)' 'alert carries PR data'

# --- announced marker present → no repeat alert -------------------------------
new_case urgent_alert_deduped
base_config '- urgent_label: urgent' '- slack_notifications: enabled'
open_three
printf '# PR #2: urgent PR\n<!-- urgent-announced: 2026-07-30T10:00:00Z -->\n' > "$WORK/reviews/pr-2.md"
run_preflight review
assert_jq '.urgent_alerts_due | length == 0' 'marker suppresses the alert'

# --- urgent_label unset → feature fully off ----------------------------------
new_case urgent_off
base_config '- slack_notifications: enabled'
open_three
run_preflight review
assert_jq '[.reviews_due[].urgent] | all(. == false)' 'no urgent flags without the key'
assert_jq '.urgent_alerts_due | length == 0' 'no alerts without the key'

finish
