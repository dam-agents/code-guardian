#!/usr/bin/env bash
# Prune detection: verified CLOSED/MERGED rows prune (with artifact ids), and so
# do history files without a row (never an open PR's, never a number with no
# pull request); a closed PR whose row is a RAPID in_progress lock defers the
# prune and emits a closed:true review entry (the owed full review —
# docs/review.md).
. "$(dirname "$0")/helpers.sh"

SHA1="1111111111111111111111111111111111111111"
SHA4="4444444444444444444444444444444444444444"
SHA5="5555555555555555555555555555555555555555"

closed_pr_fx() { # <number> <sha> <merged> [author] [closed_at]
  jq -n --argjson n "$1" --arg sha "$2" --argjson m "$3" --arg a "${4:-dave}" --arg ca "${5:-$(iso_ago 3600)}" \
    '{number:$n, state:"closed", merged:$m, title:"gone PR", closed_at:$ca,
      user:{login:$a}, head:{sha:$sha, ref:("b"+($n|tostring))}}' \
    | fx "api repos/acme/widgets/pulls/$1"
}

# --- done row + closed PR → prune with artifact ids ---------------------------
new_case prune_done
base_config
pr_json 1 "still open" '[]' "$SHA1" | open_prs_fx
add_row 1 "$SHA1" "$(iso_ago 3600)" APPROVE done
add_row 5 "$SHA5" "$(iso_ago 90000)" APPROVE done
closed_pr_fx 5 "$SHA5" false
printf '# PR #5: gone PR\n<!-- artifact-dam: dam_1 -->\n' > "$WORK/reviews/pr-5.md"
run_preflight review
assert_jq '.prunes_due | length == 1' 'one prune due'
assert_jq '.prunes_due[0] | .number == 5 and .state == "CLOSED" and .dam_id == "dam_1" and (has("gist_id") | not)' 'prune carries artifact ids'
assert_jq '.reviews_due | length == 0' 'nothing to review'

# --- a history file without a row: the alert marker of a PR closed before review --
new_case prune_file_without_row
base_config '- urgent_label: urgent' '- slack_notifications: enabled'
pr_json 1 "still open" '[]' "$SHA1" | open_prs_fx
add_row 1 "$SHA1" "$(iso_ago 3600)" APPROVE done
closed_pr_fx 5 "$SHA5" false
printf '# PR #5: gone PR\n<!-- urgent-announced: 2026-09-28T10:00:00Z -->\n' > "$WORK/reviews/pr-5.md"
printf '# PR #1: still open\n' > "$WORK/reviews/pr-1.md"
run_preflight review
assert_jq '.prunes_due | length == 1 and .[0].number == 5 and .[0].state == "CLOSED" and .[0].dam_id == null' 'a history file without a row prunes once its PR is closed'
assert_jq '.reviews_due | length == 0' 'a closed PR without a row owes no review'

# --- a history file without a row for an open PR stays -----------------------
new_case keep_file_without_row_open
base_config
{ pr_json 1 "still open" '[]' "$SHA1"; pr_json 2 "draft PR" '[]' "$SHA5" | jq '.draft = true'; } | open_prs_fx
add_row 1 "$SHA1" "$(iso_ago 3600)" APPROVE done
printf '# PR #2: draft PR\n\n## PR-local overrides\n\n- [2026-09-28 from user] Ignore: x\n' > "$WORK/reviews/pr-2.md"
run_preflight review
assert_jq '.prunes_due | length == 0' 'the history file of an open PR is no prune candidate'

# --- a history file without a row and without a verified state stays ---------
new_case prune_file_without_row_unanswered
base_config
pr_json 1 "still open" '[]' "$SHA1" | open_prs_fx
add_row 1 "$SHA1" "$(iso_ago 3600)" APPROVE done
printf '# PR #5: gone PR\n' > "$WORK/reviews/pr-5.md"
fx_fail 'api repos/acme/widgets/pulls/5'
run_preflight review
assert_jq '.prunes_due | length == 0' 'a history file without a row never prunes without a verified state'

# --- only drafts open, or nothing open: the empty non-draft list still prunes --
new_case prune_drafts_only
base_config
pr_json 2 "draft PR" '[]' "$SHA1" | jq '.draft = true' | open_prs_fx
add_row 5 "$SHA5" "$(iso_ago 90000)" APPROVE done
closed_pr_fx 5 "$SHA5" true
run_preflight review
assert_jq '.prunes_due | length == 1 and .[0].number == 5 and .[0].state == "MERGED"' 'a merged row prunes while every open PR is a draft'

new_case prune_nothing_open
base_config
printf '[]' | fx "api repos/$TEST_REPO/pulls?state=open&per_page=100"
add_row 5 "$SHA5" "$(iso_ago 90000)" APPROVE done
closed_pr_fx 5 "$SHA5" true
run_preflight review
assert_jq '.prunes_due | length == 1 and .[0].number == 5' 'a merged row prunes with no open PR at all'

# --- a carry record or an artifact without history file or row ----------------
new_case prune_carry_only
base_config
pr_json 1 "still open" '[]' "$SHA1" | open_prs_fx
add_row 1 "$SHA1" "$(iso_ago 3600)" APPROVE done
printf '{"sha":"%s","findings":[]}\n' "$SHA5" > "$WORK/reviews/pr-5.carry.json"
mkdir -p "$WORK/reviews/pr-artifacts"; printf '<html>\n' > "$WORK/reviews/pr-artifacts/pr-4.html"
closed_pr_fx 5 "$SHA5" true
closed_pr_fx 4 "$SHA4" false
run_preflight review
assert_jq '[.prunes_due[].number] | sort == [4,5]' 'a leftover carry record or artifact prunes'
printf '{"sha":"%s","findings":[]}\n' "$SHA1" > "$WORK/reviews/pr-1.carry.json"
run_preflight review
assert_jq '[.prunes_due[].number] | index(1) == null' 'an open PR'"'"'s carry record never prunes'

# --- a history file for a number with no pull request: skipped, no warning ----
new_case prune_file_not_a_pr
base_config
pr_json 1 "still open" '[]' "$SHA1" | open_prs_fx
add_row 1 "$SHA1" "$(iso_ago 3600)" APPROVE done
printf '# PR #7: an issue number\n' > "$WORK/reviews/pr-7.md"
# the body real gh prints on stdout for a 404
printf '{"message":"Not Found","status":"404"}\n' | fx 'api repos/acme/widgets/pulls/7'
run_preflight review
assert_jq '.prunes_due | length == 0' 'a number with no pull request never prunes'
assert_jq '.logs | any(contains("PR #7: no pull request with this number"))' 'the skip is logged'
! grep -rqs 'PR #7: state check did not respond' "$WORK/logs" \
  && printf 'ok   %s: %s\n' "$CASE" 'no gh_api warning for a number with no pull request' \
  || { printf 'FAIL %s: gh_api warning written for PR #7\n' "$CASE"; FAILED=1; }

# --- audit: a history file without a row is an orphan only when its PR is not open --
new_case audit_orphan_history
base_config
{ pr_json 1 "still open" '[]' "$SHA1"; pr_json 2 "draft PR" '[]' "$SHA5" | jq '.draft = true'; } | open_prs_fx
add_row 1 "$SHA1" "$(iso_ago 3600)" APPROVE done
printf '# PR #1: still open\n' > "$WORK/reviews/pr-1.md"
printf '# PR #2: draft PR\n\n## PR-local overrides\n\n- [2026-09-28 from user] Ignore: x\n' > "$WORK/reviews/pr-2.md"
run_preflight audit
assert_jq '.checks[] | select(.id == "orphan_history") | .status == "ok"' 'the file of an open draft without a row is no orphan'
printf '# PR #5: gone PR\n' > "$WORK/reviews/pr-5.md"
run_preflight audit
assert_jq '.checks[] | select(.id == "orphan_history") | .status == "warn" and (.detail | startswith("1 "))' 'the file of a PR outside the open list is an orphan'
rm -f "$WORK/reviews/pr-5.md"
printf '{"sha":"%s","findings":[]}\n' "$SHA5" > "$WORK/reviews/pr-5.carry.json"
run_preflight audit
assert_jq '.checks[] | select(.id == "orphan_history") | .status == "warn" and (.detail | startswith("1 ")) and (.detail | endswith("#5"))' 'a carry record alone is an orphan too'

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

# --- the urgent alert's marker file is no posted review: the owed pass is first --
new_case closed_rapid_alert_only
base_config '- urgent_label: urgent' '- slack_notifications: enabled'
pr_json 1 "still open" '[]' "$SHA1" | open_prs_fx
add_row 1 "$SHA1" "$(iso_ago 3600)" APPROVE done
add_row 4 "$SHA4" "$(iso_ago 5400)" RAPID in_progress
closed_pr_fx 4 "$SHA4" true
printf '# PR #4: gone PR\n<!-- urgent-announced: 2026-09-28T10:00:00Z -->\n' > "$WORK/reviews/pr-4.md"
run_preflight review
assert_jq '.reviews_due[0] | .number == 4 and .closed == true and .kind == "first" and .full == true' 'an alert-only history file keeps the owed pass a full first review'

# --- a bot author keeps the REST login, `[bot]` suffix included ---------------
new_case closed_rapid_bot_author
base_config
pr_json 1 "still open" '[]' "$SHA1" | open_prs_fx
add_row 1 "$SHA1" "$(iso_ago 3600)" APPROVE done
add_row 4 "$SHA4" "$(iso_ago 5400)" RAPID in_progress
closed_pr_fx 4 "$SHA4" true 'dependabot[bot]'
run_preflight review
assert_jq '.reviews_due[0].author == "dependabot[bot]"' 'bot login matches the REST form'

# --- the state checks are one batched call, not one call per row -------------
SHA6="6666666666666666666666666666666666666666"
new_case prune_batched
base_config
pr_json 1 "still open" '[]' "$SHA1" | open_prs_fx
add_row 1 "$SHA1" "$(iso_ago 3600)" APPROVE done
add_row 5 "$SHA5" "$(iso_ago 90000)" APPROVE done
add_row 6 "$SHA6" "$(iso_ago 90000)" APPROVE done
closed_pr_fx 5 "$SHA5" false
closed_pr_fx 6 "$SHA6" true
GH_CALLS_LOG="$SANDBOX/calls.log" run_preflight review
assert_jq '[.prunes_due[] | "\(.number):\(.state)"] == ["5:CLOSED", "6:MERGED"]' 'both rows prune, in row order'
[ "$(grep -c 'PruneStates' "$SANDBOX/calls.log")" = "1" ] && ! grep -qE 'pulls/[56]$' "$SANDBOX/calls.log" \
  && printf 'ok   %s: %s\n' "$CASE" 'one batched call, no per-row call' \
  || { printf 'FAIL %s: calls were %s\n' "$CASE" "$(tr '\n' ';' < "$SANDBOX/calls.log" | cut -c1-300)"; FAILED=1; }

# --- a failed batch falls back to the per-row call ----------------------------
new_case prune_batch_failed
base_config
pr_json 1 "still open" '[]' "$SHA1" | open_prs_fx
add_row 1 "$SHA1" "$(iso_ago 3600)" APPROVE done
add_row 5 "$SHA5" "$(iso_ago 90000)" APPROVE done
closed_pr_fx 5 "$SHA5" false
fx_fail 'graphql_prune_states'
GH_CALLS_LOG="$SANDBOX/calls.log" run_preflight review
assert_jq '.prunes_due | length == 1 and .[0].state == "CLOSED"' 'prune still verified per PR'
assert_file_contains "$SANDBOX/calls.log" 'pulls/5$' 'the per-row call answered instead'

# --- a PR the batch leaves unanswered is read per row; the rest are not --------
new_case prune_batch_partial
base_config
pr_json 1 "still open" '[]' "$SHA1" | open_prs_fx
add_row 1 "$SHA1" "$(iso_ago 3600)" APPROVE done
add_row 5 "$SHA5" "$(iso_ago 90000)" APPROVE done
add_row 6 "$SHA6" "$(iso_ago 90000)" APPROVE done
closed_pr_fx 6 "$SHA6" false
printf '{"data":{"repository":{"p5":{"state":"MERGED","headRefOid":"%s","headRefName":"b5","title":"gone PR","author":{"login":"dave"}},"p6":null}}}\n' "$SHA5" \
  > "$GH_FIXTURES/graphql_prune_states"
GH_CALLS_LOG="$SANDBOX/calls.log" run_preflight review
assert_jq '[.prunes_due[] | "\(.number):\(.state)"] == ["5:MERGED", "6:CLOSED"]' 'batch answer and per-row answer both prune'
! grep -q 'pulls/5$' "$SANDBOX/calls.log" && grep -q 'pulls/6$' "$SANDBOX/calls.log" \
  && printf 'ok   %s: %s\n' "$CASE" 'only the unanswered PR is read per row' \
  || { printf 'FAIL %s: calls were %s\n' "$CASE" "$(tr '\n' ';' < "$SANDBOX/calls.log" | cut -c1-300)"; FAILED=1; }

# --- a PR no call can answer is skipped, never pruned -------------------------
new_case prune_unanswered_skipped
base_config
pr_json 1 "still open" '[]' "$SHA1" | open_prs_fx
add_row 1 "$SHA1" "$(iso_ago 3600)" APPROVE done
add_row 5 "$SHA5" "$(iso_ago 90000)" APPROVE done
fx_fail 'api repos/acme/widgets/pulls/5'
run_preflight review
assert_jq '.prunes_due | length == 0' 'no prune without a verified state'

# --- audit: a row for a closed PR is a warn only once its prune is overdue ---
new_case audit_closed_rows
base_config
pr_json 1 "still open" '[]' "$SHA1" | open_prs_fx
add_row 1 "$SHA1" "$(iso_ago 3600)" APPROVE done
add_row 5 "$SHA5" "$(iso_ago 90000)" APPROVE done
closed_pr_fx 5 "$SHA5" false dave "$(iso_ago 7200)"
run_preflight audit
assert_jq '.checks[] | select(.id == "closed_rows") | .status == "ok" and (.detail | contains("1 closed PR row(s) wait"))' \
  'a PR closed hours ago waits for the next run with work — no warn'
closed_pr_fx 5 "$SHA5" false dave "$(iso_ago 300000)"
run_preflight audit
assert_jq '.checks[] | select(.id == "closed_rows") | .status == "warn" and (.detail | contains("never pruned: #5"))' \
  'a PR closed days ago and still in REVIEWS.md is a stuck prune'
fx_fail 'api repos/acme/widgets/pulls/5'
run_preflight audit
assert_jq '.checks[] | select(.id == "closed_rows") | .status == "warn" and (.detail | contains("unreadable"))' \
  'an unreadable close time is a warn with its reason'
jq -n --arg sha "$SHA5" '{number:5, state:"open", merged:false, title:"reopened PR", closed_at:null,
  user:{login:"dave"}, head:{sha:$sha, ref:"b5"}}' | fx 'api repos/acme/widgets/pulls/5'
rm -f "$GH_FIXTURES/$(fx_for 'api repos/acme/widgets/pulls/5').rc"
run_preflight audit
assert_jq '.checks[] | select(.id == "closed_rows") | .status == "ok"' \
  'a PR still open but outside the open list is no ghost and no API fault'

finish
