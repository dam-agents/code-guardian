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

finish
