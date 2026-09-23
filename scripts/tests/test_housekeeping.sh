#!/usr/bin/env bash
# Housekeeping deferral: bookkeeping that nobody waits on never starts a
# session by itself. It rides along with the next run that has work of its own,
# and forces a `housekeeping_only` run past the wait or the item count.
# Contract: docs/runbook.md → The schedule gate.
. "$(dirname "$0")/helpers.sh"

SHA1="1111111111111111111111111111111111111111"
SHA5="5555555555555555555555555555555555555555"
MARKER=".housekeeping-since"

merged_pr_fx() { # <number> <sha>
  jq -n --argjson n "$1" --arg sha "$2" \
    '{number:$n, state:"closed", merged:true, title:"merged PR",
      user:{login:"dave"}, head:{sha:$sha, ref:("b"+($n|tostring))}}' \
    | fx "api repos/acme/widgets/pulls/$1"
}

# a merged PR with a done row — one prune due and nothing else. One reviewed
# PR stays open: an empty open list reads as an API anomaly and skips the scan.
prune_case() { # <case-name>
  new_case "$1"
  base_config
  pr_json 1 "still open" '[]' "$SHA1" | open_prs_fx
  add_row 1 "$SHA1" "$(iso_ago 3600)" APPROVE done
  add_row 5 "$SHA5" "$(iso_ago 90000)" APPROVE done
  merged_pr_fx 5 "$SHA5"
}

# --- a prune alone is deferred, not a session --------------------------------
prune_case hk_defers_prune_alone
run_preflight review
assert_jq '.prunes_due | length == 1' 'the prune is still detected'
assert_jq '.nothing_to_do == true' 'bookkeeping alone does not start a session'
assert_jq 'has("housekeeping_only") == false' 'a deferred batch is not a housekeeping run'
assert_jq '.logs | any(contains("deferred to the next run with work"))' 'the deferral is logged'
assert_file_contains "$WORK/$MARKER" 'T.*Z' 'the wait marker records when the batch started'

# the marker survives the next tick — the wait is cumulative, not per run
FIRST="$(cat "$WORK/$MARKER")"
run_preflight review
assert_jq '.nothing_to_do == true' 'the next tick defers it again'
if [ "$(cat "$WORK/$MARKER")" = "$FIRST" ]; then
  printf 'ok   %s: the wait is not restarted by a later tick\n' "$CASE"
else printf 'FAIL %s: the wait marker was rewritten\n' "$CASE"; FAILED=1; fi

# --- past the wait it forces a bookkeeping-only run --------------------------
prune_case hk_batch_past_wait
printf '%s\n' "$(iso_ago 25200)" > "$WORK/$MARKER"   # 7h, past the 6h wait
run_preflight review
assert_jq '.nothing_to_do == false' 'a batch past the wait starts a run'
assert_jq '.housekeeping_only == true' 'and says the run carries bookkeeping alone'
assert_jq '.prunes_due | length == 1' 'with the pending item in it'
assert_jq '.logs | any(contains("housekeeping batch"))' 'the batch is logged'
assert_jq 'has("config") and has("memory")' 'a housekeeping run still gets the resolved config'

# --- ten pending items force the run whatever the wait says ------------------
new_case hk_batch_by_count
base_config
pr_json 1 "still open" '[]' "$SHA1" | open_prs_fx
add_row 1 "$SHA1" "$(iso_ago 3600)" APPROVE done
for n in 11 12 13 14 15 16 17 18 19 20; do
  add_row "$n" "$SHA5" "$(iso_ago 90000)" APPROVE done
  merged_pr_fx "$n" "$SHA5"
done
run_preflight review
assert_jq '.prunes_due | length == 10' 'every closed row is detected'
assert_jq '.nothing_to_do == false and .housekeeping_only == true' 'the item count forces the batch'

# --- real work carries the bookkeeping along ---------------------------------
new_case hk_rides_along
base_config
pr_json 7 "new PR" '[]' "$SHA1" | open_prs_fx
add_row 5 "$SHA5" "$(iso_ago 90000)" APPROVE done
merged_pr_fx 5 "$SHA5"
run_preflight review
assert_jq '(.reviews_due | length) == 1 and (.prunes_due | length) == 1' 'both are in one worklist'
assert_jq '.nothing_to_do == false' 'the review starts the run'
assert_jq 'has("housekeeping_only") == false' 'a run with real work is not a housekeeping run'
assert_jq '.logs | any(contains("ride along"))' 'the free ride is logged'

# --- nothing pending clears the wait -----------------------------------------
new_case hk_marker_cleared
base_config
pr_json 1 "plain PR" '[]' "$SHA1" | open_prs_fx
add_row 1 "$SHA1" "$(iso_ago 3600)" APPROVE done
printf '%s\n' "$(iso_ago 25200)" > "$WORK/$MARKER"
run_preflight review
assert_jq '.nothing_to_do == true' 'an idle tick stays idle'
if [ ! -e "$WORK/$MARKER" ]; then
  printf 'ok   %s: an empty batch removes the wait marker\n' "$CASE"
else printf 'FAIL %s: the wait marker outlived its batch\n' "$CASE"; FAILED=1; fi

# --- tier 1 is never deferred ------------------------------------------------
# a mention is work a person waits on: it starts the run at once, whatever the
# housekeeping clock says
new_case hk_tier1_never_waits
base_config
pr_json 1 "still open" '[]' "$SHA1" | open_prs_fx
add_row 1 "$SHA1" "$(iso_ago 3600)" APPROVE done
add_row 5 "$SHA5" "$(iso_ago 90000)" APPROVE done
merged_pr_fx 5 "$SHA5"
MS="$(printf '%sT00:00:00Z' "$(date -u -d "@$(( $(date -u +%s) - 7*86400 ))" +%Y-%m-%d 2>/dev/null \
     || date -u -r "$(( $(date -u +%s) - 7*86400 ))" +%Y-%m-%d)")"
jq -n '[{id:101, user:{login:"alice", type:"User"}, body:"@test-bot what about the retry?",
         created_at:"2026-08-07T09:00:00Z", html_url:"https://example.test/c/101",
         issue_url:"https://api.github.com/repos/acme/widgets/issues/1"}]' \
  | fx "api repos/$TEST_REPO/issues/comments?since=$MS&per_page=100&sort=created&direction=desc&page=1"
run_preflight review
assert_jq '(.mentions_due | length) == 1 and (.prunes_due | length) == 1' 'a mention and a pending prune'
assert_jq '.nothing_to_do == false and (has("housekeeping_only") == false)' 'a mention starts the run at once'

# --- a shepherd sweep never touches the review heartbeat's clock -------------
new_case hk_shepherd_leaves_the_clock
base_config '- slack_notifications: enabled'
printf '[]' | fx "api repos/$TEST_REPO/pulls?state=open&per_page=100"
printf '%s\n' "$(iso_ago 3600)" > "$WORK/$MARKER"
BEFORE="$(cat "$WORK/$MARKER")"
run_preflight shepherd
assert_jq '.mode == "shepherd"' 'the sweep ran'
if [ "$(cat "$WORK/$MARKER" 2>/dev/null)" = "$BEFORE" ]; then
  printf 'ok   %s: the review batch keeps its wait\n' "$CASE"
else printf 'FAIL %s: the shepherd sweep reset the review wait marker\n' "$CASE"; FAILED=1; fi

# --- the gate agrees with the worklist ---------------------------------------
prune_case hk_gate_skips_deferred
run_precheck review
assert_rc 1 'a deferred batch skips the fire'
assert_file_contains "$WORK/HEARTBEAT.log" 'nothing_to_do=true' 'and is still recorded as a tick'

prune_case hk_gate_starts_the_batch
printf '%s\n' "$(iso_ago 25200)" > "$WORK/$MARKER"
run_precheck review
assert_rc 0 'a due batch starts the session'
assert_out_contains 'housekeeping_only' 'and the prompt says the short read set applies'
assert_out_contains 'prunes_due=1 (#5)' 'with the pending item named'

finish
