#!/usr/bin/env bash
# Agent fixes (docs/agent-fixes.md): preflight emits a fix round only for a
# labeled PR whose current review left blocking findings with a fix, and
# `review-pr.sh fix-start|fix-push` consume the label, mark the head and push
# with a lease. A fixed PR never auto-merges.
. "$(dirname "$0")/helpers.sh"

SHA1="1111111111111111111111111111111111111111"
AF_CFG=('- agent_fixes: enabled' '- agent_fix_label: cg-fix')

af_history() { # <sha> <findings-json>
  printf '# PR #1: x\n\n## PR-local overrides\n\n## Review at %s — %s — REQUEST_CHANGES\n\nbody\n\n<!-- findings-json: %s -->\n<!-- review-meta: {"diff_digest":"x"} -->\n<!-- cg:review headRefOid=%s -->\n\n---\n' \
    "${1:0:7}" "$(iso_ago 3600)" "$2" "$1" > "$WORK/reviews/pr-1.md"
}
WARN_FIX='[{"status":"new","severity":"warning","file":"src/a.ts","line":3,"summary":"x","fix":"bound the retry"}]'
af_setup() { # <case> [extra config…]
  new_case "$1"
  base_config "${AF_CFG[@]}" "${@:2}"
  pr_json 1 "fix me" '[{"name":"cg-fix"}]' "$SHA1" | open_prs_fx
  add_row 1 "$SHA1" "$(iso_ago 3600)" REQUEST_CHANGES done
  af_history "$SHA1" "$WARN_FIX"
  jq -n --arg s "$SHA1" '{state:"open", head:{sha:$s, ref:"b1", repo:{full_name:"acme/widgets"}}, labels:[{name:"cg-fix"}]}' \
    | fx "api repos/acme/widgets/pulls/1"
}

af_setup af_due
run_preflight review
assert_jq '.fixes_due == [{number:1, sha:"'"$SHA1"'", findings:1}]' 'a labeled PR with a fixable finding gets one round'
assert_jq '.read_set | (index("docs/agent-fixes.md") != null) and (index("docs/review.md") != null)' 'the round reads its doc and the style rules'
assert_jq '.config | .agent_fixes == "enabled" and .agent_fix_label == "cg-fix"' 'the config object carries the agent-fix keys'


new_case af_off_by_default
base_config
pr_json 1 "fix me" '[{"name":"cg-fix"}]' "$SHA1" | open_prs_fx
run_preflight review
assert_jq '(.fixes_due | length) == 0' 'no fix without agent_fixes: enabled'

af_setup af_fork
jq -n --arg s "$SHA1" '{state:"open", head:{sha:$s, ref:"b1", repo:{full_name:"someone/widgets"}}}' | fx "api repos/acme/widgets/pulls/1"
run_preflight review
assert_jq '(.fixes_due | length) == 0 and ([.logs[] | select(test("not in the target repository"))] | length == 1)' 'a fork branch is never pushed to'

af_setup af_no_fix_line
af_history "$SHA1" '[{"status":"new","severity":"suggestion","file":"src/a.ts","line":3,"summary":"x","fix":null}]'
run_preflight review
assert_jq '(.fixes_due | length) == 0' 'only blocking findings with a fix start a round'

af_setup af_stale_review
af_history "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$WARN_FIX"
run_preflight review
assert_jq '(.fixes_due | length) == 0' 'a review of an older head never drives a fix'

af_setup af_once_per_head
printf '<!-- agent-fix: %s -->\n' "$SHA1" >> "$WORK/reviews/pr-1.md"
run_preflight review
assert_jq '(.fixes_due | length) == 0' 'one fix round per head'

# --- a fix of mine blocks auto-merge ------------------------------------------
new_case af_blocks_auto_merge
base_config '- auto_merge: enabled' '- auto_merge_label: cg-automerge'
pr_json 1 "fixed" '[{"name":"cg-automerge"}]' "$SHA1" | open_prs_fx
add_row 1 "$SHA1" "$(iso_ago 3600)" APPROVE done
af_history "$SHA1" '[]'
printf '<!-- agent-fix: %s -->\n<!-- agent-fix-pushed: %s -->\n' "2222222222222222222222222222222222222222" "$SHA1" >> "$WORK/reviews/pr-1.md"
run_preflight review
assert_jq '(.merges_due | length) == 0 and ([.logs[] | select(test("carries a fix of mine"))] | length == 1)' 'a PR with my fix waits for a person'

new_case af_unpushed_round_keeps_auto_merge
base_config '- auto_merge: enabled' '- auto_merge_label: cg-automerge'
pr_json 1 "fixed" '[{"name":"cg-automerge"}]' "$SHA1" | open_prs_fx
add_row 1 "$SHA1" "$(iso_ago 3600)" APPROVE done
af_history "$SHA1" '[]'
printf '<!-- agent-fix: %s -->\n' "2222222222222222222222222222222222222222" >> "$WORK/reviews/pr-1.md"
run_preflight review
assert_jq '[.logs[] | select(test("carries a fix of mine"))] | length == 0' 'a round that pushed nothing does not block auto-merge'

# --- review-pr.sh fix-start / fix-push -----------------------------------------
RP="$REPO_ROOT/scripts/review-pr.sh"
mk_origin() { # a bare origin with branch b1 → $ORIGIN, its head → $HEAD_SHA
  local src="$SANDBOX/src"; ORIGIN="$SANDBOX/origin.git"
  git init -q -b main "$src"; printf 'a\n' > "$src/a.ts"
  git -C "$src" add -A; git -C "$src" -c user.name=t -c user.email=t@t commit -q -m init
  git -C "$src" checkout -q -b b1; printf 'retry()\n' >> "$src/a.ts"
  git -C "$src" -c user.name=t -c user.email=t@t commit -q -am change
  git clone -q --bare "$src" "$ORIGIN"; HEAD_SHA="$(git -C "$src" rev-parse HEAD)"
}
rp_fix_setup() { # <case>
  new_case "$1"; base_config "${AF_CFG[@]}"; mk_origin
  af_history "$HEAD_SHA" "$WARN_FIX"
  jq -n --arg s "$HEAD_SHA" '{state:"open", head:{sha:$s, ref:"b1", repo:{full_name:"acme/widgets"}}, labels:[{name:"cg-fix"}]}' \
    | fx "api repos/acme/widgets/pulls/1"
}
run_fix_cmd() { # <cmd> [args…]
  : > "$SANDBOX/gh.log"
  OUT="$(GH_HOST="" WORK_DIR="$WORK" HOME="$FAKE_HOME" TMPDIR="$SANDBOX" GH_CALLS_LOG="$SANDBOX/gh.log" \
         CG_CLONE_URL="$ORIGIN" PATH="$T_DIR/bin:$PATH" bash "$RP" "$1" 1 "${@:2}" 2>/dev/null)"
}

rp_fix_setup rp_fix_round
run_fix_cmd fix-start --sha "$HEAD_SHA"
assert_jq '.outcome == "ready" and .branch == "b1"' 'the round starts on the head branch'
CLONE="$(printf '%s' "$OUT" | jq -r '.clone')"
grep -q -- '-X DELETE repos/acme/widgets/issues/1/labels/cg-fix' "$SANDBOX/gh.log" \
  && printf 'ok   %s: the label is consumed\n' "$CASE" || { printf 'FAIL %s: the label was not removed\n' "$CASE"; FAILED=1; }
assert_file_contains "$WORK/reviews/pr-1.md" "<!-- agent-fix: $HEAD_SHA -->" 'the head is marked before any change'
printf 'bounded_retry()\n' > "$CLONE/a.ts"
run_fix_cmd fix-push
assert_jq '.outcome == "pushed"' 'the fix is pushed'
NEW="$(printf '%s' "$OUT" | jq -r '.sha')"
assert_file_contains "$WORK/reviews/pr-1.md" "<!-- agent-fix-pushed: $NEW -->" 'the pushed fix is marked'
[ "$(git -C "$ORIGIN" rev-parse b1)" = "$NEW" ] && printf 'ok   %s: the branch carries the fix\n' "$CASE" \
  || { printf 'FAIL %s: origin b1 is not the fix commit\n' "$CASE"; FAILED=1; }
[ "$(git -C "$ORIGIN" log -1 --format=%s b1)" = "Fix review findings (Code Guardian)" ] && printf 'ok   %s: committed with the fixed message\n' "$CASE" \
  || { printf 'FAIL %s: unexpected commit message\n' "$CASE"; FAILED=1; }
[ -d "$CLONE" ] && { printf 'FAIL %s: the fix clone was left behind\n' "$CASE"; FAILED=1; } || printf 'ok   %s: the clone is removed\n' "$CASE"

rp_fix_setup rp_fix_lease
run_fix_cmd fix-start --sha "$HEAD_SHA"
CLONE="$(printf '%s' "$OUT" | jq -r '.clone')"
# someone pushes to the branch while the fix is in progress
OTHER="$SANDBOX/other"; git clone -q --branch b1 "$ORIGIN" "$OTHER"
printf 'theirs\n' >> "$OTHER/a.ts"; git -C "$OTHER" -c user.name=o -c user.email=o@o commit -q -am theirs; git -C "$OTHER" push -q origin b1
printf 'mine\n' > "$CLONE/a.ts"
run_fix_cmd fix-push
assert_jq '.outcome == "rejected"' 'a branch that moved rejects the push'
[ "$(git -C "$ORIGIN" log -1 --format=%s b1)" = "theirs" ] && printf 'ok   %s: their commit survives\n' "$CASE" \
  || { printf 'FAIL %s: the lease did not hold\n' "$CASE"; FAILED=1; }

rp_fix_setup rp_fix_moved
run_fix_cmd fix-start --sha "1111111111111111111111111111111111111111"
assert_jq '.outcome == "skipped" and .reason == "the head moved"' 'a moved head never starts a round'
grep -q -- '-X DELETE' "$SANDBOX/gh.log" && { printf 'FAIL %s: label consumed for a skipped round\n' "$CASE"; FAILED=1; } \
  || printf 'ok   %s: a skipped round keeps the label\n' "$CASE"

rp_fix_setup rp_fix_nothing
run_fix_cmd fix-start --sha "$HEAD_SHA"
run_fix_cmd fix-push
assert_jq '.outcome == "nothing"' 'no change, no commit'

rp_fix_setup rp_fix_abort
run_fix_cmd fix-start --sha "$HEAD_SHA"
CLONE="$(printf '%s' "$OUT" | jq -r '.clone')"
printf 'broken\n' > "$CLONE/a.ts"
run_fix_cmd fix-push --abort
assert_jq '.outcome == "aborted"' 'an aborted round pushes nothing'
grep -q 'agent-fix-pushed' "$WORK/reviews/pr-1.md" && { printf 'FAIL %s: an aborted round left the pushed marker\n' "$CASE"; FAILED=1; } \
  || printf 'ok   %s: no pushed marker without a push\n' "$CASE"
[ "$(git -C "$ORIGIN" rev-parse b1)" = "$HEAD_SHA" ] && printf 'ok   %s: the branch is untouched\n' "$CASE" \
  || { printf 'FAIL %s: an aborted round changed the branch\n' "$CASE"; FAILED=1; }

finish
