#!/usr/bin/env bash
# Shepherd mode: aged-PR nudge, merge-conflict author nudge (approved PRs
# included), approved-and-clean silence.
. "$(dirname "$0")/helpers.sh"

SHA1="1111111111111111111111111111111111111111"

shep_setup() { # [extra config lines…]
  base_config '- slack_notifications: enabled' "$@"
  cat > "$WORK/DEVELOPERS.md" <<'EOF'
# Developers roster

| login | slack_id | name | expertise (seed) | observed areas |
| --- | --- | --- | --- | --- |
| alice | U0AAAAAA | Alice | backend | |
| bob | U0BBBBBB | Bob | frontend | |
EOF
}
approved_fx() { # <pr-number>
  printf '[{"user":{"login":"bob"},"state":"APPROVED","body":""}]' \
    | fx "api repos/acme/widgets/pulls/$1/reviews?per_page=100"
}
dirty_fx() { # <pr-number>
  printf '{"mergeable_state":"dirty"}' | fx "api repos/acme/widgets/pulls/$1"
}

# --- aged unreviewed PR → L1 nudge, no conflict --------------------------------
new_case shepherd_l1
shep_setup
pr_json 1 "old PR" '[]' "$SHA1" | open_prs_fx
run_preflight shepherd
assert_jq '.nudges_due | length == 1' 'one nudge due'
assert_jq '.nudges_due[0] | .level == 1 and .class == "awaiting_review" and .conflict == false and .needs_target_selection == true' 'L1 reviewer nudge without conflict'

# --- merge conflict → author-directed nudge ------------------------------------
new_case shepherd_conflict
shep_setup
pr_json 1 "conflicted PR" '[]' "$SHA1" | open_prs_fx
dirty_fx 1
run_preflight shepherd
assert_jq '.nudges_due | length == 1' 'conflict nudge due'
assert_jq '.nudges_due[0] | .conflict == true and .targets == "alice!" and .needs_target_selection == false' 'author-directed conflict nudge'

# --- approved and clean → silent -----------------------------------------------
new_case shepherd_approved_clean
shep_setup
pr_json 1 "approved PR" '[]' "$SHA1" | open_prs_fx
approved_fx 1
run_preflight shepherd
assert_jq '.nudges_due | length == 0' 'approved clean PR is silent'
assert_file_contains "$WORK/SHEPHERD.md" 'approved' 'ledger records approved state'

# --- approved but conflicted → rebase nudge to the author ----------------------
new_case shepherd_approved_dirty
shep_setup
pr_json 1 "approved conflicted PR" '[]' "$SHA1" | open_prs_fx
approved_fx 1
dirty_fx 1
run_preflight shepherd
assert_jq '.nudges_due | length == 1' 'approved+dirty nudges'
assert_jq '.nudges_due[0] | .conflict == true and .class == "approved" and .targets == "alice!"' 'rebase ask targets the author'

# --- reviews REST faults, GraphQL answers → classified from GraphQL -----------
new_case shepherd_classify_graphql_fallback
shep_setup
pr_json 1 "approved PR" '[]' "$SHA1" | open_prs_fx
fx_fail "api repos/acme/widgets/pulls/1/reviews?per_page=100"
printf '{"data":{"repository":{"pullRequest":{"reviews":{"nodes":[{"state":"APPROVED","body":"","author":{"login":"bob"}}]}}}}}' \
  | fx_graphql_reviews 1
run_preflight shepherd
assert_jq '.nudges_due | length == 0' 'GraphQL-classified approval silences the PR'
assert_file_contains "$WORK/SHEPHERD.md" 'approved' 'ledger records the GraphQL classification'

# --- both reads fault → PR deferred, ledger row untouched ---------------------
new_case shepherd_classify_unavailable
shep_setup
pr_json 1 "unreadable PR" '[]' "$SHA1" | open_prs_fx
cat > "$WORK/SHEPHERD.md" <<EOF
# PR Shepherd Ledger

| PR | eligible_since | reviewers | review_state | nudges | last_nudge_at | level | status |
|----|----------------|-----------|--------------|--------|---------------|-------|--------|
| 1 | 2026-07-01T00:00:00Z | bob | changes_requested | 2 | $(iso_ago 3600) | 2 | nudging-author |
EOF
fx_fail "api repos/acme/widgets/pulls/1/reviews?per_page=100"
run_preflight shepherd
assert_jq '.nudges_due | length == 0' 'an unclassifiable PR never nudges'
assert_file_contains "$WORK/SHEPHERD.md" 'changes_requested' 'ledger keeps the last known state'
assert_out_absent 'awaiting_review' 'an outage is never recorded as a read answer'

# --- PR facts: appended once, and they outlive the ledger row -----------------
# docs/shepherd.md → **PR facts**: the audit counts project health from this
# file, so a sweep must record the first independent review and any conflict.
new_case shepherd_pr_facts
shep_setup
pr_json 1 "reviewed and conflicted" '[]' "$SHA1" | open_prs_fx
printf '[{"user":{"login":"bob"},"state":"COMMENTED","body":"","submitted_at":"2026-09-10T12:00:00Z"},
         {"user":{"login":"bob"},"state":"APPROVED","body":"","submitted_at":"2026-09-11T12:00:00Z"}]' \
  | fx "api repos/acme/widgets/pulls/1/reviews?per_page=100"
dirty_fx 1
run_preflight shepherd
assert_file_contains "$WORK/PR-EVENTS.jsonl" '"kind":"first_review"' 'the first independent review is recorded'
assert_file_contains "$WORK/PR-EVENTS.jsonl" '2026-09-10T12:00:00Z' 'the earliest review is the one recorded, not the latest'
assert_file_contains "$WORK/PR-EVENTS.jsonl" '"kind":"conflict"' 'the conflict is recorded'
BEFORE="$(grep -c '' "$WORK/PR-EVENTS.jsonl")"
run_preflight shepherd
AFTER="$(grep -c '' "$WORK/PR-EVENTS.jsonl")"
if [ "$BEFORE" = "$AFTER" ]; then printf 'ok   %s: a second sweep appends nothing\n' "$CASE"
else printf 'FAIL %s: the second sweep re-appended (%s -> %s)\n' "$CASE" "$BEFORE" "$AFTER"; FAILED=1; fi

# --- the bot's own review is not a human review -------------------------------
new_case shepherd_pr_facts_bot_excluded
shep_setup
pr_json 1 "only the bot reviewed" '[]' "$SHA1" | open_prs_fx
printf '[{"user":{"login":"test-bot"},"state":"COMMENTED","body":"<!-- cg:review -->","submitted_at":"2026-09-10T12:00:00Z"},
         {"user":{"login":"alice"},"state":"COMMENTED","body":"","submitted_at":"2026-09-11T12:00:00Z"}]' \
  | fx "api repos/acme/widgets/pulls/1/reviews?per_page=100"
run_preflight shepherd
[ -f "$WORK/PR-EVENTS.jsonl" ] && grep -q 'first_review' "$WORK/PR-EVENTS.jsonl" \
  && { printf 'FAIL %s: the bot or the author was counted as a human review\n' "$CASE"; FAILED=1; } \
  || printf 'ok   %s: neither the bot nor the author counts as a human review\n' "$CASE"

# --- ready to land: approved, green, no conflict, no critical of my own -------
# docs/shepherd.md → **Ready to land**
green_fx() { # <sha>
  jq -n --arg n "build" '{total_count:1, check_runs:[{name:$n, status:"completed",
    conclusion:"success", details_url:"", output:{}}]}' \
    | fx "api repos/acme/widgets/commits/$1/check-runs?per_page=100"
}
ready_setup() { # [extra config lines…]
  shep_setup '- merge_ready_nudge: enabled' "$@"
  pr_json 1 "approved PR" '[]' "$SHA1" | open_prs_fx
  approved_fx 1
  green_fx "$SHA1"
}

new_case shepherd_ready_to_land
ready_setup
run_preflight shepherd
assert_jq '(.nudges_due | length) == 1' 'the approved PR is announced'
assert_jq '.nudges_due[0] | .class == "ready_to_land" and .conflict == false' 'the entry carries its own class'
assert_jq '.nudges_due[0] | .targets == "alice!" and .needs_target_selection == false' 'it goes to the author, and picks no reviewer'
assert_jq '.nudges_due[0].row_update.status == "ready-notified"' 'the record marks the PR announced'

# --- said once: a row already marked stays silent -----------------------------
approved_at_fx() { # <pr-number> <submitted-at>
  jq -nc --arg ts "$2" '[{user:{login:"bob"}, state:"APPROVED", body:"", submitted_at:$ts}]' \
    | fx "api repos/acme/widgets/pulls/$1/reviews?per_page=100"
}

new_case shepherd_ready_once
ready_setup
approved_at_fx 1 "$(iso_ago 86400)"   # the approval the message already covered
printf '| 1 | %s | - | approved | 1 | %s | 1 | ready-notified |\n' "$(iso_ago 172800)" "$(iso_ago 7200)" >> "$WORK/SHEPHERD.md"
run_preflight shepherd
assert_jq '(.nudges_due | length) == 0' 'an announced PR is never announced twice'
assert_file_contains "$WORK/SHEPHERD.md" 'ready-notified' 'the row keeps the mark while the PR stays approved'

# --- a second approval is a new landing moment --------------------------------
new_case shepherd_ready_second_approval
ready_setup
approved_at_fx 1 "$(iso_ago 3600)"    # approved again, after the message went out
printf '| 1 | %s | - | approved | 1 | %s | 1 | ready-notified |\n' "$(iso_ago 172800)" "$(iso_ago 7200)" >> "$WORK/SHEPHERD.md"
run_preflight shepherd
assert_jq '(.nudges_due | length) == 1' 'an approval newer than the mark is announced again'
assert_jq '.nudges_due[0] | .class == "ready_to_land" and .targets == "alice!"' 'the second announcement is the same shape'

# --- a running check holds it, a failing one cancels it -----------------------
new_case shepherd_ready_ci_running
ready_setup
jq -n '{total_count:1, check_runs:[{name:"build", status:"in_progress", conclusion:null,
        details_url:"", output:{}}]}' | fx "api repos/acme/widgets/commits/$SHA1/check-runs?per_page=100"
run_preflight shepherd
assert_jq '(.nudges_due | length) == 0' 'a running rollup is not green yet'
assert_jq '[.logs[] | select(test("checks still running"))] | length == 1' 'the wait says why'

new_case shepherd_ready_ci_failed
ready_setup
jq -n '{total_count:1, check_runs:[{name:"build", status:"completed", conclusion:"failure",
        details_url:"", output:{}}]}' | fx "api repos/acme/widgets/commits/$SHA1/check-runs?per_page=100"
run_preflight shepherd
assert_jq '(.nudges_due | length) == 0' 'a red rollup is never ready to land'

# --- my own open critical suppresses it --------------------------------------
new_case shepherd_ready_own_critical
ready_setup
printf '## Review at aaaaaaa\n\n<!-- findings-json: [{"severity":"critical","status":"new","summary":"unbounded retry"}] -->\n' \
  > "$WORK/reviews/pr-1.md"
run_preflight shepherd
assert_jq '(.nudges_due | length) == 0' 'an open critical of mine blocks the announcement'
assert_jq '[.logs[] | select(test("open critical"))] | length == 1' 'the reason is logged'
assert_jq '[.logs[] | select(test("checks still running|CI failed"))] | length == 0' 'the rollup is not read for a PR my own critical blocks'

new_case shepherd_ready_critical_fixed
ready_setup
printf '## Review at aaaaaaa\n\n<!-- findings-json: [{"severity":"critical","status":"fixed","summary":"unbounded retry"}] -->\n' \
  > "$WORK/reviews/pr-1.md"
run_preflight shepherd
assert_jq '(.nudges_due | length) == 1' 'a critical the author fixed no longer blocks it'

# --- off by default -----------------------------------------------------------
new_case shepherd_ready_disabled
shep_setup
pr_json 1 "approved PR" '[]' "$SHA1" | open_prs_fx
approved_fx 1
green_fx "$SHA1"
run_preflight shepherd
assert_jq '(.nudges_due | length) == 0' 'no announcement without the key'

finish
