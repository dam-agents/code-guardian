#!/usr/bin/env bash
# In-progress lock semantics: fresh lock skips, stale lock (>30 min) takes over.
. "$(dirname "$0")/helpers.sh"

SHA1="1111111111111111111111111111111111111111"

# --- fresh lock → skipped ----------------------------------------------------
new_case fresh_lock
base_config
pr_json 1 "locked PR" '[]' "$SHA1" | open_prs_fx
add_row 1 "$SHA1" "$(iso_ago 600)" - in_progress
run_preflight review
assert_jq '.reviews_due | length == 0' 'fresh lock not re-emitted'
assert_jq '.logs | any(contains("fresh in_progress lock"))' 'skip logged'

# --- stale lock → takeover ---------------------------------------------------
new_case stale_lock
base_config
pr_json 1 "stuck PR" '[]' "$SHA1" | open_prs_fx
add_row 1 "$SHA1" "$(iso_ago 2700)" - in_progress
run_preflight review
assert_jq '.reviews_due | length == 1' 'stale lock re-emitted'
assert_jq '.reviews_due[0] | .takeover == true and .kind == "first"' 'takeover, kind first (no history file)'

finish
