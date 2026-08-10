#!/usr/bin/env bash
# GitHub progress signal (`review_progress`, docs/review.md): the per-review
# `eta_seconds` derived from past review_step pairs, and the reset of a progress
# status left pending on a PR that turned draft while locked.
. "$(dirname "$0")/helpers.sh"

SHA1="1111111111111111111111111111111111111111"
SHA2="2222222222222222222222222222222222222222"

# a locked→done review_step pair in today's events log
seed_pair() { # <run> <pr> <locked-iso> <done-iso>
  mkdir -p "$WORK/logs"
  local f="$WORK/logs/events-$(date -u +%Y-%m-%d).jsonl" s
  for s in "locked $3" "done $4"; do
    printf '{"ts":"%s","run":"%s","job":"review","level":"info","event":"review_step","msg":"PR #%s abc1234 %s"}\n' \
      "${s#* }" "$1" "$2" "${s%% *}" >> "$f"
  done
}

# --- eta_seconds = median of recent completed reviews ------------------------
new_case eta_median
base_config '- review_progress: enabled'
pr_json 1 "fresh PR" '[]' "$SHA1" | open_prs_fx
seed_pair r1 7 2026-07-28T09:00:00Z 2026-07-28T09:02:00Z   # 120s
seed_pair r2 8 2026-07-28T10:00:00Z 2026-07-28T10:04:00Z   # 240s
seed_pair r3 9 2026-07-28T11:00:00Z 2026-07-28T11:06:00Z   # 360s
run_preflight review
assert_jq '.reviews_due | length == 1' 'first review due'
assert_jq '.reviews_due[0].eta_seconds == 240' 'median of 120/240/360 carried on the entry'
assert_jq '.status_resets_due == []' 'no reset without an abandoned lock'

# --- no samples yet → null, never a fabricated number -----------------------
new_case eta_no_samples
base_config '- review_progress: enabled'
pr_json 1 "fresh PR" '[]' "$SHA1" | open_prs_fx
run_preflight review
assert_jq '.reviews_due[0].eta_seconds == null' 'empty log yields a null ETA'

# --- an incomplete pair is not a duration ------------------------------------
new_case eta_ignores_unfinished
base_config '- review_progress: enabled'
pr_json 1 "fresh PR" '[]' "$SHA1" | open_prs_fx
mkdir -p "$WORK/logs"
printf '{"ts":"2026-07-28T09:00:00Z","run":"r1","job":"review","level":"info","event":"review_step","msg":"PR #7 abc1234 locked"}\n' \
  > "$WORK/logs/events-$(date -u +%Y-%m-%d).jsonl"
seed_pair r2 8 2026-07-28T10:00:00Z 2026-07-28T10:05:00Z   # 300s
run_preflight review
assert_jq '.reviews_due[0].eta_seconds == 300' 'a locked-without-done run is skipped'

# --- feature off: no field at all -------------------------------------------
new_case progress_off_by_default
base_config
pr_json 1 "fresh PR" '[]' "$SHA1" | open_prs_fx
seed_pair r1 7 2026-07-28T09:00:00Z 2026-07-28T09:02:00Z
run_preflight review
assert_jq '.reviews_due[0] | has("eta_seconds") == false' 'missing key = off, no ETA computed'
assert_jq '.status_resets_due == []' 'reset array always present'

new_case progress_unknown_value
base_config '- review_progress: yes'
pr_json 1 "fresh PR" '[]' "$SHA1" | open_prs_fx
run_preflight review
assert_jq '.reviews_due[0] | has("eta_seconds") == false' 'unknown value degrades to off'
assert_jq '.logs | any(contains("review_progress"))' 'the fallback is logged once'

# --- PR turned draft while locked → status reset due ------------------------
new_case reset_on_draft
base_config '- review_progress: enabled'
pr_json 2 "drafted PR" '[]' "$SHA2" | jq '.draft = true' | open_prs_fx
add_row 2 "$SHA2" "$(iso_ago 2700)" - in_progress
run_preflight review
assert_jq '.nothing_to_do == false' 'a due reset is work of its own'
assert_jq '.status_resets_due | length == 1' 'abandoned lock on a draft emits one reset'
assert_jq '.status_resets_due[0] | .number == 2 and .sha == "'"$SHA2"'" and .reason == "draft"' 'reset carries the locked SHA'
assert_jq '.reviews_due == []' 'a draft is never reviewed'
assert_jq '.prunes_due == []' 'an open draft is never pruned'

# --- a lock that is still fresh is running work, not an orphan ---------------
new_case reset_skips_fresh_lock
base_config '- review_progress: enabled'
pr_json 2 "drafted PR" '[]' "$SHA2" | jq '.draft = true' | open_prs_fx
add_row 2 "$SHA2" "$(iso_ago 600)" - in_progress
run_preflight review
assert_jq '.status_resets_due == []' 'fresh lock on a draft is left alone'
assert_jq '.nothing_to_do == true' 'nothing else to do'

# --- feature off → nothing is written back to GitHub ------------------------
new_case reset_needs_the_feature
base_config
pr_json 2 "drafted PR" '[]' "$SHA2" | jq '.draft = true' | open_prs_fx
add_row 2 "$SHA2" "$(iso_ago 2700)" - in_progress
run_preflight review
assert_jq '.status_resets_due == []' 'no reset while the signal is off'

# --- a done row on a draft is not an abandoned lock --------------------------
new_case reset_only_for_locks
base_config '- review_progress: enabled'
pr_json 2 "drafted PR" '[]' "$SHA2" | jq '.draft = true' | open_prs_fx
add_row 2 "$SHA2" "$(iso_ago 2700)" APPROVE done
run_preflight review
assert_jq '.status_resets_due == []' 'only in_progress rows can orphan a status'

finish
