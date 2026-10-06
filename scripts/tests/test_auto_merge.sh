#!/usr/bin/env bash
# Auto-merge (docs/auto-merge.md): preflight emits a merge only when every gate
# holds, and `review-pr.sh merge` re-reads the PR and guards the merge by SHA.
. "$(dirname "$0")/helpers.sh"

SHA1="1111111111111111111111111111111111111111"
AM_CFG=('- auto_merge: enabled' '- auto_merge_label: cg-automerge')

# a labeled PR my review of its head approved as a quick check, clean and green
am_setup() { # <case> [extra config lines…]
  new_case "$1"
  base_config "${AM_CFG[@]}" "${@:2}"
  pr_json 1 "small fix" '[{"name":"cg-automerge"}]' "$SHA1" | open_prs_fx
  add_row 1 "$SHA1" "$(iso_ago 3600)" APPROVE done
  am_history quick-check '[]'
  jq -n --arg s "$SHA1" '{state:"open", head:{sha:$s}, mergeable_state:"clean", additions:10, deletions:2,
        changed_files:1, labels:[{name:"cg-automerge"}]}' | fx "api repos/acme/widgets/pulls/1"
  printf '[{"filename":"src/util.ts"}]' | fx "api repos/acme/widgets/pulls/1/files?per_page=100"
  am_reviews '[]'
  jq -n '{total_count:1, check_runs:[{name:"build", status:"completed", conclusion:"success",
        details_url:"", output:{}}]}' | fx "api repos/acme/widgets/commits/$SHA1/check-runs?per_page=100"
}
# the PR's reviews: the bot's own marked approval plus <extra> people's reviews,
# for the marker scan's first page and the auto-merge gate's paginated read
am_reviews() { # <extra-reviews-json>
  local j
  j="$(jq -n --arg s "$SHA1" --argjson x "$1" '[{user:{login:"test-bot"}, state:"APPROVED",
        body:"<!-- cg:review headRefOid=\($s) -->", submitted_at:"2026-07-01T00:00:00Z"}] + $x')"
  printf '%s' "$j" | fx "api repos/acme/widgets/pulls/1/reviews?per_page=100"
  printf '%s' "$j" | fx "api --paginate repos/acme/widgets/pulls/1/reviews?per_page=100"
}
am_history() { # <triage-class> <findings-json> [forced]
  local forced=""; [ -n "${3:-}" ] && forced=",\"forced\":\"$3\""
  printf '# PR #1: small fix\n\n## PR-local overrides\n\n## Review at %s — %s — APPROVE\n\nbody\n\n<!-- findings-json: %s -->\n<!-- review-meta: {"diff_digest":"x","triage":{"class":"%s","minutes":5%s}} -->\n<!-- cg:review headRefOid=%s -->\n\n---\n' \
    "${SHA1:0:7}" "$(iso_ago 3600)" "$2" "$1" "$forced" "$SHA1" > "$WORK/reviews/pr-1.md"
}
am_blocked() { # <log fragment> <description>
  run_preflight review
  assert_jq '(.merges_due | length) == 0' "$2"
  assert_jq "[.logs[] | select(test(\"no auto-merge — $1\"))] | length == 1" 'the gate names its reason'
}

am_setup am_due
run_preflight review
assert_jq '.merges_due == [{number:1, sha:"'"$SHA1"'", method:"squash"}]' 'every gate holds: the merge is due'
assert_jq '.nothing_to_do == false and (.read_set | index("docs/auto-merge.md") != null)' 'a due merge wakes the run and reads its doc'
assert_jq '.config | .auto_merge == "enabled" and .auto_merge_label == "cg-automerge" and .auto_merge_max_lines == 100 and .auto_merge_method == "squash"' \
  'the config object carries the auto-merge keys with their defaults'

new_case am_off_by_default
base_config
pr_json 1 "small fix" '[{"name":"cg-automerge"}]' "$SHA1" | open_prs_fx
add_row 1 "$SHA1" "$(iso_ago 3600)" APPROVE done
run_preflight review
assert_jq '(.merges_due | length) == 0' 'no merge without auto_merge: enabled'

new_case am_no_label_key
base_config '- auto_merge: enabled'
pr_json 1 "small fix" '[]' "$SHA1" | open_prs_fx
run_preflight review
assert_jq '(.merges_due | length) == 0 and ([.logs[] | select(test("without auto_merge_label"))] | length == 1)' 'enabled without a label key stays off and says so'

am_setup am_unlabeled
pr_json 1 "small fix" '[]' "$SHA1" | open_prs_fx
run_preflight review
assert_jq '(.merges_due | length) == 0' 'a PR without the label never merges'

am_setup am_not_approved
sed -i.bak 's/| APPROVE | done |/| COMMENT | done |/' "$WORK/REVIEWS.md"
am_blocked 'no APPROVE of mine' 'a COMMENT verdict never merges'

am_setup am_needs_human
am_history needs-human '[]'
am_blocked 'my triage is not a quick check' 'a needs-human triage never merges'

am_setup am_forced
am_history quick-check '[]' 'src/util.ts (src/*)'
am_blocked 'my triage is not a quick check' 'a forced triage never merges'

am_setup am_open_warning
am_history quick-check '[{"status":"new","severity":"warning","summary":"x"}]'
am_blocked 'my review has open blocking findings' 'an open warning never merges'

am_setup am_not_clean
jq -n --arg s "$SHA1" '{state:"open", head:{sha:$s}, mergeable_state:"blocked", additions:10, deletions:2, changed_files:1}' \
  | fx "api repos/acme/widgets/pulls/1"
am_blocked 'GitHub reports mergeable_state blocked' 'branch protection still decides'

am_setup am_too_big '- auto_merge_max_lines: 5'
am_blocked 'more than 5 changed lines' 'the size cap holds'

am_setup am_workflow_file
printf '[{"filename":".github/workflows/ci.yml"}]' | fx "api repos/acme/widgets/pulls/1/files?per_page=100"
am_blocked 'changes .github/workflows/ci.yml' 'a .github file never merges'

am_setup am_workflow_moved_out
printf '[{"filename":"ci.yml","previous_filename":".github/workflows/ci.yml","status":"renamed"}]' \
  | fx "api repos/acme/widgets/pulls/1/files?per_page=100"
am_blocked 'changes .github/workflows/ci.yml' 'a file moved out of .github never merges'

am_setup am_human_path '- human_review_paths: migrations/*, src/u*'
am_blocked 'changes src/util.ts \\(human_review_paths\\)' 'a human_review_paths file never merges'

am_setup am_ci_red
jq -n '{total_count:1, check_runs:[{name:"build", status:"completed", conclusion:"failure", details_url:"", output:{}}]}' \
  | fx "api repos/acme/widgets/commits/$SHA1/check-runs?per_page=100"
am_blocked 'a check failed' 'a red rollup never merges'

am_setup am_has_hooks
jq -n --arg s "$SHA1" '{state:"open", head:{sha:$s}, mergeable_state:"has_hooks", additions:10, deletions:2, changed_files:1}' \
  | fx "api repos/acme/widgets/pulls/1"
run_preflight review
assert_jq '(.merges_due | length) == 1' 'has_hooks counts as clean'

am_setup am_changes_requested
am_reviews '[{"user":{"login":"bob"},"state":"CHANGES_REQUESTED","body":"no"}]'
am_blocked 'a person requested changes' "a person's open change request never merges"

am_setup am_changes_then_approved
am_reviews '[{"user":{"login":"bob"},"state":"CHANGES_REQUESTED","body":"no"},{"user":{"login":"bob"},"state":"APPROVED","body":"ok"}]'
run_preflight review
assert_jq '(.merges_due | length) == 1' 'a change request its author later approved no longer blocks'

# gh --paginate prints one array per page: the latest review sits on the last one
am_setup am_changes_on_page_two
printf '[{"user":{"login":"bob"},"state":"APPROVED","body":"ok"}]\n[{"user":{"login":"bob"},"state":"CHANGES_REQUESTED","body":"no"}]\n' \
  | fx "api --paginate repos/acme/widgets/pulls/1/reviews?per_page=100"
am_blocked 'a person requested changes' 'a change request on a later page of reviews never merges'

am_setup am_reviews_unreadable
fx_fail "api --paginate repos/acme/widgets/pulls/1/reviews?per_page=100"
am_blocked 'the reviews could not be read' 'unreadable reviews never merge'

am_setup am_reviewed_this_run
mention_on_pr1
run_preflight review
assert_jq '(.mentions_due | length) == 1 and (.merges_due | length) == 0' 'a PR this run answers first is not merged in the same run'
assert_jq '[.logs[] | select(test("no auto-merge — this run reviews or answers it first"))] | length == 1' 'and the log says why'

am_setup am_failed_before
printf '<!-- auto-merge-failed: %s -->\n' "$SHA1" >> "$WORK/reviews/pr-1.md"
am_blocked 'a merge of this head already failed' 'a refused head is never tried again'

# --- review-pr.sh merge ---------------------------------------------------------
RP="$REPO_ROOT/scripts/review-pr.sh"
run_merge() {
  : > "$SANDBOX/gh.log"
  OUT="$(GH_HOST="" WORK_DIR="$WORK" HOME="$FAKE_HOME" TMPDIR="$SANDBOX" GH_CALLS_LOG="$SANDBOX/gh.log" \
         PATH="$T_DIR/bin:$PATH" bash "$RP" merge 1 --sha "$SHA1" 2>/dev/null)"
}
MERGE_SLUG="api -X PUT repos/acme/widgets/pulls/1/merge -f sha=$SHA1 -f merge_method=squash"

am_setup rp_merge_ok
printf '{"merged":true,"sha":"abc"}' | fx "$MERGE_SLUG"
run_merge
assert_jq '.outcome == "merged" and .method == "squash"' 'merged with the configured method'
grep -q "sha=$SHA1" "$SANDBOX/gh.log" && printf 'ok   %s: the merge is guarded by the head SHA\n' "$CASE" \
  || { printf 'FAIL %s: no SHA guard on the merge call\n' "$CASE"; FAILED=1; }

am_setup rp_merge_moved
jq -n '{state:"open", head:{sha:"2222222222222222222222222222222222222222"}, labels:[{name:"cg-automerge"}]}' \
  | fx "api repos/acme/widgets/pulls/1"
run_merge
assert_jq '.outcome == "skipped" and .reason == "the head moved"' 'a moved head is never merged'
grep -q -- '-X PUT' "$SANDBOX/gh.log" && { printf 'FAIL %s: merge called after the head moved\n' "$CASE"; FAILED=1; } \
  || printf 'ok   %s: no merge call after the head moved\n' "$CASE"

am_setup rp_merge_verdict_changed
sed -i.bak 's/| APPROVE | done |/| REQUEST_CHANGES | done |/' "$WORK/REVIEWS.md"
run_merge
assert_jq '.outcome == "skipped" and (.reason | contains("not a done APPROVE"))' 'a verdict changed since preflight withdraws the merge'

am_setup rp_merge_draft
jq -n --arg s "$SHA1" '{state:"open", draft:true, head:{sha:$s}, labels:[{name:"cg-automerge"}]}' | fx "api repos/acme/widgets/pulls/1"
run_merge
assert_jq '.outcome == "skipped" and .reason == "the PR is a draft"' 'a draft is never merged'

am_setup rp_merge_base_moved
fx_fail "$MERGE_SLUG"; fx_err "$MERGE_SLUG" 'HTTP 405: Base branch was modified. Review and try the merge again.'
run_merge
assert_jq '.outcome == "error"' 'a base branch that moved under the call is retried, not refused'

am_setup rp_merge_unlabeled
jq -n --arg s "$SHA1" '{state:"open", head:{sha:$s}, labels:[]}' | fx "api repos/acme/widgets/pulls/1"
run_merge
assert_jq '.outcome == "skipped" and .reason == "the label is gone"' 'a removed label withdraws the consent'

am_setup rp_merge_refused
fx_fail "$MERGE_SLUG"; fx_err "$MERGE_SLUG" 'HTTP 405: Required approving review is missing'
run_merge
assert_jq '.outcome == "failed" and (.reason | contains("405"))' 'a GitHub refusal is reported'
assert_file_contains "$WORK/reviews/pr-1.md" "<!-- auto-merge-failed: $SHA1 -->" 'the refused head is marked'

am_setup rp_merge_rate_limited
fx_fail "$MERGE_SLUG"; fx_err "$MERGE_SLUG" 'API rate limit exceeded for installation (HTTP 403)'
run_merge
assert_jq '.outcome == "error"' 'a rate limit is an error, not a refusal'
grep -q 'auto-merge-failed' "$WORK/reviews/pr-1.md" && { printf 'FAIL %s: a rate limit marked the head\n' "$CASE"; FAILED=1; } \
  || printf 'ok   %s: a rate limit leaves the head to retry\n' "$CASE"

am_setup rp_merge_transport
fx_fail "$MERGE_SLUG"; fx_err "$MERGE_SLUG" 'connection reset'
run_merge
assert_jq '.outcome == "error"' 'a transport fault is an error'
grep -q 'auto-merge-failed' "$WORK/reviews/pr-1.md" && { printf 'FAIL %s: a transport fault marked the head\n' "$CASE"; FAILED=1; } \
  || printf 'ok   %s: a transport fault leaves the head to retry\n' "$CASE"

new_case rp_merge_disabled
base_config
run_merge
assert_jq '.outcome == "skipped"' 'merge refuses without auto_merge: enabled'

finish
