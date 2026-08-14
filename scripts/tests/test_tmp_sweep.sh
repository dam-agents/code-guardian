#!/usr/bin/env bash
# Audit-mode stale-clone sweep: reclaim review-pr-* leftovers of dead sessions
# only — never a live lock's dirs, never a fresh clone, never a lookalike name.
. "$(dirname "$0")/helpers.sh"

assert_path() { # gone|kept <path> <description>
  local want="$1" p="$2" desc="$3" ok=0
  case "$want" in
    gone) [ ! -e "$p" ] && ok=1;;
    kept) [ -e "$p" ] && ok=1;;
  esac
  if [ "$ok" -eq 1 ]; then printf 'ok   %s: %s\n' "$CASE" "$desc"
  else printf 'FAIL %s: %s (%s expected %s)\n' "$CASE" "$desc" "$p" "$want"; FAILED=1; fi
}

new_case tmp_sweep
base_config
pr_json 7 "open PR" '[]' "7777777777777777777777777777777777777777" | open_prs_fx
add_row 8 "8888888888888888888888888888888888888888" "$(iso_ago 60)" RAPID in_progress
TMP_T="$SANDBOX/tmp"; mkdir -p "$TMP_T"
mkdir -p "$TMP_T/review-pr-9" "$TMP_T/review-pr-9.out" "$TMP_T/review-pr-9.s-lint" \
         "$TMP_T/review-pr-8" "$TMP_T/review-pr-10" "$TMP_T/review-pr-x"
# everything but PR #10's fresh clone predates the lock TTL
touch -t 202001010000 "$TMP_T/review-pr-9" "$TMP_T/review-pr-9.out" \
                      "$TMP_T/review-pr-9.s-lint" "$TMP_T/review-pr-8" "$TMP_T/review-pr-x"
TMPDIR="$TMP_T" run_preflight audit
assert_path gone "$TMP_T/review-pr-9"        'stale clone of a dead session reclaimed'
assert_path gone "$TMP_T/review-pr-9.out"    'its .out sidecar reclaimed'
assert_path gone "$TMP_T/review-pr-9.s-lint" 'its per-skill copy reclaimed'
assert_path kept "$TMP_T/review-pr-8"        'live in_progress lock keeps its clone'
assert_path kept "$TMP_T/review-pr-10"       'fresh clone (younger than the TTL) kept'
assert_path kept "$TMP_T/review-pr-x"        'non-numeric name never touched'
assert_jq '.checks[] | select(.id == "tmp_leftovers") | .status == "warn" and (.detail | contains("3 leftover") and contains("3 stale reclaimed"))' \
  'check reports the post-sweep state'

new_case tmp_sweep_clean
base_config
pr_json 7 "open PR" '[]' "7777777777777777777777777777777777777777" | open_prs_fx
TMP_T="$SANDBOX/tmp"; mkdir -p "$TMP_T"
TMPDIR="$TMP_T" run_preflight audit
assert_jq '.checks[] | select(.id == "tmp_leftovers") | .status == "ok"' 'empty tmp → ok'

finish
