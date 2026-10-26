#!/usr/bin/env bash
# Daily brief (docs/brief.md): the gate is deterministic — keys, weekend, the
# window from BRIEF.log, and the merged PRs in it.
. "$(dirname "$0")/helpers.sh"

CLOSED='api repos/acme/widgets/pulls?state=closed&sort=updated&direction=desc&per_page=100'
merged_fx() { # <merged_at>
  jq -n --arg m "$1" \
    '[{number:7, title:"Add export", user:{login:"alice"}, merged_at:$m, html_url:"https://example.test/pr/7"},
      {number:8, title:"Closed only", user:{login:"bob"}, merged_at:null, html_url:"https://example.test/pr/8"}]' \
    | fx "$CLOSED"
}
weekday() { [ "$(date -u +%u)" -lt 6 ]; }

new_case brief_disabled
base_config '- slack_notifications: enabled'
merged_fx "$(iso_ago 3600)"
run_preflight brief
assert_jq '.nothing_to_do == true and (.brief_due | not)' 'no brief without daily_brief'

new_case brief_needs_slack
base_config '- daily_brief: enabled'
merged_fx "$(iso_ago 3600)"
run_preflight brief
assert_jq '.nothing_to_do == true' 'no brief without Slack notifications'

if weekday; then
  new_case brief_due
  base_config '- daily_brief: enabled' '- slack_notifications: enabled' '- brief_language: Czech'
  merged_fx "$(iso_ago 3600)"
  run_preflight brief
  assert_jq '.nothing_to_do == false' 'a merged PR makes the brief due'
  assert_jq '.brief_due | .language == "Czech" and (.prs | length == 1) and .prs[0].number == 7 and .prs[0].author == "alice"' 'merged PRs only, with the language'

  new_case brief_default_language
  base_config '- daily_brief: enabled' '- slack_notifications: enabled'
  merged_fx "$(iso_ago 3600)"
  run_preflight brief
  assert_jq '.brief_due.language == "English"' 'the language defaults to English'

  new_case brief_window
  base_config '- daily_brief: enabled' '- slack_notifications: enabled'
  merged_fx "$(iso_ago 7200)"
  printf '%s\n' "$(iso_ago 3600)" > "$WORK/BRIEF.log"
  run_preflight brief
  assert_jq '.nothing_to_do == true' 'a PR merged before the last brief is not repeated'

  new_case brief_api_error
  base_config '- daily_brief: enabled' '- slack_notifications: enabled'
  fx_fail "$CLOSED"
  OUT="$(GH_HOST="" WORK_DIR="$WORK" HOME="$FAKE_HOME" PATH="$T_DIR/bin:$PATH" bash "$REPO_ROOT/scripts/preflight.sh" brief 2>/dev/null)"
  assert_jq '.error != null' 'a failed read is an error, never an empty window'
else
  new_case brief_weekend
  base_config '- daily_brief: enabled' '- slack_notifications: enabled'
  merged_fx "$(iso_ago 3600)"
  run_preflight brief
  assert_jq '.nothing_to_do == true' 'the weekend sends nothing; Monday covers it'
fi

new_case brief_config_object
base_config '- daily_brief: enabled' '- brief_language: German'
pr_json 1 "a new PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
run_preflight review
assert_jq '.config.daily_brief == "enabled" and .config.brief_language == "German"' 'the keys travel in the config object'

finish
