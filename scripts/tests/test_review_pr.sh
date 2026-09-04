#!/usr/bin/env bash
# review-pr.sh (docs/review.md → Per-PR review sequence): prepare gates and
# artefacts, lock heartbeat, context/sweep helpers, skill collection, the
# re-review delta, the rapid post, the review post with its guards, abort.
. "$(dirname "$0")/helpers.sh"

RP="$REPO_ROOT/scripts/review-pr.sh"
GIT_ID=(-c user.name=t -c user.email=t@example.test -c commit.gpgsign=false)
SESSION="test-run-$$"

# fixture repository: main + branch b1 with one edited, one new and one lockfile
mk_repo() {
  FX="$SANDBOX/fx"; mkdir -p "$FX/src"
  git -C "$FX" init -q; git -C "$FX" checkout -q -b main 2>/dev/null || true
  printf 'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\n' > "$FX/src/alpha.ts"
  printf 'export const beta = 1;\n' > "$FX/src/beta.ts"
  printf 'import "./alpha";\n' > "$FX/src/uses-alpha.ts"
  printf 'lockfileVersion: 9\n' > "$FX/pnpm-lock.yaml"
  git -C "$FX" add -A && git -C "$FX" "${GIT_ID[@]}" commit -qm base
  git -C "$FX" checkout -q -b b1
  printf 'l1\nl2\nl3\nl4\nl5\nNEW6 query()\nNEW7\nl6\nl7\nl8\nl9\nl10\n' > "$FX/src/alpha.ts"
  printf 'export const gamma = query();\n' > "$FX/src/gamma.ts"
  printf 'lockfileVersion: 10\n' > "$FX/pnpm-lock.yaml"
  git -C "$FX" add -A && git -C "$FX" "${GIT_ID[@]}" commit -qm change
  B1_SHA="$(git -C "$FX" rev-parse HEAD)"
  git -C "$FX" diff main...b1 > "$SANDBOX/diff.txt"
  git -C "$FX" checkout -q main
}

# the live PR as the API reports it — state/labels/sha are the knobs
pr_fx() { # [state] [labels-json] [sha] [draft]
  jq -n --arg st "${1:-open}" --argjson l "${2:-[]}" --arg sha "${3:-$B1_SHA}" --argjson d "${4:-false}" \
    '{state:$st, merged:($st=="merged"), draft:$d, title:"alpha PR", user:{login:"alice"}, body:"Adds query()",
      head:{sha:$sha, ref:"b1", repo:{full_name:"acme/widgets"}}, base:{ref:"main"}, labels:($l|map({name:.})),
      requested_reviewers:[], additions:3, deletions:1, changed_files:3}' \
    | sed 's/"merged":false/"merged":false/' | fx 'api repos/acme/widgets/pulls/1'
}
ctx_fx() { # PR context: one human comment, one own marker-carrying comment
  printf '%s' '{"body":"Adds query()","author":{"login":"alice"},"comments":[{"author":{"login":"bob"},"body":"looks ok","createdAt":"2026-09-01T00:00:00Z"},{"author":{"login":"test-bot"},"body":"<!-- cg:review headRefOid=0000000000000000000000000000000000000000 --> mine","createdAt":"2026-09-01T00:00:00Z"}],"reviews":[]}' \
    | fx 'pr view 1 --repo acme/widgets --json body,author,comments,reviews'
  fx 'pr diff 1 --repo acme/widgets' < "$SANDBOX/diff.txt"
}
skills_config() { # [extra config lines…]
  base_config "$@" '' '## Review skills' '' \
    '| skill | source | trigger | section |' '| --- | --- | --- | --- |' \
    '| doc-drift | harness | always | Documentation Check |' \
    '| typescript-engineering | harness | .ts,.js,.yaml | TypeScript Review |'
}
setup() { # fresh case with repo, config and open-PR fixtures
  new_case "$1"; mkdir -p "$SANDBOX/tmp"; mk_repo; skills_config "${@:2}"; pr_fx; ctx_fx
  : > "$SANDBOX/gh.log"
}
run_rp() { # <cmd> <n> [args…] → $OUT
  OUT="$(GITHUB_REPO="$TEST_REPO" GH_HOST="" WORK_DIR="$WORK" HOME="$FAKE_HOME" TMPDIR="$SANDBOX/tmp" \
         CG_CLONE_URL="$FX" LOG_RUN_ID="$SESSION" GH_CALLS_LOG="$SANDBOX/gh.log" \
         PATH="$T_DIR/bin:$PATH" bash "$RP" "$@" 2>/dev/null)"
}
events() { cat "$WORK"/logs/events-*.jsonl 2>/dev/null | jq -r 'select(.event=="review_step") | .msg'; }
assert_event() { # <grep pattern> <description>
  if events | grep -q -- "$1"; then printf 'ok   %s: %s\n' "$CASE" "$2"
  else printf 'FAIL %s: %s (no review_step matching %s; have: %s)\n' "$CASE" "$2" "$1" "$(events | tr '\n' ';')"; FAILED=1; fi
}
assert_call() { # <grep pattern> <description> — a gh call was made
  if grep -q -- "$1" "$SANDBOX/gh.log"; then printf 'ok   %s: %s\n' "$CASE" "$2"
  else printf 'FAIL %s: %s (no gh call matching %s)\n' "$CASE" "$2" "$1"; FAILED=1; fi
}
PR_DIR() { printf '%s/tmp/review-pr-1' "$SANDBOX"; }
POST_SLUG() { printf 'api repos/acme/widgets/pulls/1/reviews -X POST --input %s/tmp/review-pr-1.post.json' "$SANDBOX"; }

# --- prepare: a first review ---------------------------------------------------
setup prepare_first
run_rp prepare 1 --eta 600
assert_jq '.outcome == "ready" and .kind == "first" and .full == true and .clone == "ok" and .head_sha == "'"$B1_SHA"'"' 'ready, first review, cloned'
assert_file_contains "$WORK/REVIEWS.md" "| 1 | $B1_SHA | .* | - | in_progress |" 'lock row written'
assert_event 'PR #1 '"${B1_SHA:0:7}"' locked' 'locked event'
assert_event 'PR #1 '"${B1_SHA:0:7}"' cloned' 'cloned event'
assert_jq '.files | map(.class) == ["lockfile","code","code"]' 'changed files classified'
assert_jq '.files | map(.status) == ["modified","modified","added"]' 'file status read from the diff headers'
assert_jq '.skills["doc-drift"].status == "run" and .skills["typescript-engineering"].status == "run" and (.skills["typescript-engineering"].files == ["src/alpha.ts","src/gamma.ts"])' 'always + extension routing; the .yaml lockfile is noise and routes nowhere'
assert_jq '.skills["typescript-engineering"].workdir == "'"$(PR_DIR)"'.s-typescript-engineering"' 'per-skill copy path'
[ -d "$(PR_DIR).s-doc-drift" ] && [ -d "$(PR_DIR).s-typescript-engineering" ] && [ -d "$(PR_DIR).out" ] \
  && printf 'ok   %s: per-skill copies and .out exist\n' "$CASE" || { printf 'FAIL %s: copies/.out missing\n' "$CASE"; FAILED=1; }
git -C "$(PR_DIR)" rev-parse --verify -q origin/main >/dev/null && printf 'ok   %s: base ref fetched\n' "$CASE" || { printf 'FAIL %s: origin/main missing in the clone\n' "$CASE"; FAILED=1; }
B="$(PR_DIR).ctx/briefs/typescript-engineering.md"
grep -q 'PR #1' "$B" && grep -q 'typescript-engineering' "$B" && grep -q "$(PR_DIR).s-typescript-engineering" "$B" && grep -q 'src/gamma.ts' "$B" \
  && printf 'ok   %s: brief carries PR, skill, workdir and routed files\n' "$CASE" || { printf 'FAIL %s: brief incomplete\n' "$CASE"; FAILED=1; }
grep -q '{{' "$B" && { printf 'FAIL %s: unreplaced placeholder in brief\n' "$CASE"; FAILED=1; } || printf 'ok   %s: no placeholder left\n' "$CASE"
assert_file_contains "$(PR_DIR).ctx/context.json" '"looks ok"' 'human comment kept in context'
grep -q 'mine' "$(PR_DIR).ctx/context.json" && { printf 'FAIL %s: own marker comment leaked into context\n' "$CASE"; FAILED=1; } || printf 'ok   %s: own past review dropped from context\n' "$CASE"
jq -e '."src/alpha.ts".right | index(6) != null and index(1) == null' "$(PR_DIR).ctx/hunks.json" >/dev/null && printf 'ok   %s: hunk index has the added line, not line 1\n' "$CASE" || { printf 'FAIL %s: hunk index wrong: %s\n' "$CASE" "$(cat "$(PR_DIR).ctx/hunks.json")"; FAILED=1; }
jq -e '."src/alpha.ts".dependents == ["src/uses-alpha.ts"] and ."src/alpha.ts".changed_lines == [3,4,5,6,7,8,9,10]' "$(PR_DIR).ctx/pack.json" >/dev/null && printf 'ok   %s: context pack lists the dependent and the hunk lines\n' "$CASE" || { printf 'FAIL %s: pack wrong: %s\n' "$CASE" "$(cat "$(PR_DIR).ctx/pack.json")"; FAILED=1; }

# --- step: heartbeat + event ---------------------------------------------------
run_rp step 1 "fanned out (n=2)"
assert_jq '.outcome == "ok"' 'step ok'
assert_event 'fanned out (n=2)' 'milestone logged'
assert_event 'locked (refresh, fanned out (n=2))' 'lock refresh logged'

# --- context / sweep -----------------------------------------------------------
OUT="$(GITHUB_REPO="$TEST_REPO" GH_HOST="" WORK_DIR="$WORK" HOME="$FAKE_HOME" TMPDIR="$SANDBOX/tmp" PATH="$T_DIR/bin:$PATH" bash "$RP" context 1 src/alpha.ts 6 2)"
assert_out_contains "in this PR's hunks: yes" 'an added line is in the hunks'
assert_out_contains '     6	NEW6' 'numbered lines printed'
OUT="$(GITHUB_REPO="$TEST_REPO" GH_HOST="" WORK_DIR="$WORK" HOME="$FAKE_HOME" TMPDIR="$SANDBOX/tmp" PATH="$T_DIR/bin:$PATH" bash "$RP" context 1 src/alpha.ts 1 1)"
assert_out_contains "in this PR's hunks: no" 'an untouched line is pre-existing'
run_rp sweep 1 'query\(\)'
assert_jq '.changed_files_hits | length == 2' 'sweep finds both changed-file occurrences'
assert_jq '.untouched_code_hits == 0' 'no untouched occurrences'

# --- collect: audit lines, form warnings, skill_timing ---------------------------
printf -- '- 🔴 **Critical:** unbounded query (`src/alpha.ts:6`)\n  **Fix:** add a limit\n- 🟡 **Warning:** no fix here (`src/gamma.ts:1`)\n' > "$(PR_DIR).out/doc-drift.txt"
run_rp collect 1
assert_jq '.audit_lines == ["PR #1: doc-drift ran (findings=2)", "PR #1: typescript-engineering skipped (skill-errored)"]' 'audit lines per configured skill'
assert_jq '.form_warnings | any(contains("1 blocking finding(s) without a **Fix:** line"))' 'missing Fix line reported'
cat "$WORK"/logs/events-*.jsonl | jq -e 'select(.event=="skill_timing") | .msg | test("doc-drift.txt=[0-9]+")' >/dev/null && printf 'ok   %s: skill_timing event\n' "$CASE" || { printf 'FAIL %s: no skill_timing event\n' "$CASE"; FAILED=1; }

# --- abort releases a first-review lock and cleans up -----------------------------
run_rp abort 1 "test abort"
assert_jq '.outcome == "aborted"' 'abort reported'
grep -qE '^\| *1 \|' "$WORK/REVIEWS.md" && { printf 'FAIL %s: row not deleted on first-review abort\n' "$CASE"; FAILED=1; } || printf 'ok   %s: first-review abort deletes the row\n' "$CASE"
assert_event 'aborted test abort' 'abort event'
ls -d "$SANDBOX"/tmp/review-pr-1* >/dev/null 2>&1 && { printf 'FAIL %s: leftovers after abort\n' "$CASE"; FAILED=1; } || printf 'ok   %s: no leftovers after abort\n' "$CASE"

# --- prepare gates ---------------------------------------------------------------
setup prepare_gates
pr_fx open '[]' "$B1_SHA" true
run_rp prepare 1
assert_jq '.outcome == "skip" and .reason == "draft"' 'draft skipped'
pr_fx closed
run_rp prepare 1
assert_jq '.outcome == "skip" and (.reason | contains("CLOSED"))' 'closed PR skipped for pruning'
pr_fx open
printf '# PR #1: alpha PR\n\n## Review at aaaaaaa — %s — COMMENT\n\nx\n' "$(iso_ago 7200)" > "$WORK/reviews/pr-1.md"
add_row 1 "0000000000000000000000000000000000000000" "$(iso_ago 7200)" COMMENT awaiting_label
run_rp prepare 1
assert_jq '.outcome == "skip" and .reason == "re-review trigger withdrawn"' 're-review without a trigger skipped'
run_rp prepare 1 --on-demand
assert_jq '.outcome == "ready" and .kind == "re-review" and .full == false and .prior.sha == "0000000000000000000000000000000000000000"' 'on-demand re-review runs delta scope with the prior'
run_rp abort 1 "reset"
assert_file_contains "$WORK/REVIEWS.md" '| 1 | 0000000000000000000000000000000000000000 | .* | COMMENT | awaiting_label |' 're-review abort restores awaiting_label with the prior'
pr_fx open '["cg-rereview"]'
run_rp prepare 1
assert_jq '.outcome == "ready" and .kind == "re-review" and .full == true' 'label-triggered re-review is complete scope'
run_rp abort 1 "reset"

# --- live holder: a fresh tree stands down, a dead run's leftover is reclaimed ----
setup prepare_holder
mkdir -p "$(PR_DIR)"
run_rp prepare 1
assert_jq '.outcome == "stand_down"' 'a recent tree means a live holder'
touch -t 202001010000 "$(PR_DIR)"
run_rp prepare 1
assert_jq '.outcome == "ready"' 'an old tree with no events is reclaimed'
run_rp abort 1 "reset"
# another run's events: a terminal step is not life, a mid-pipeline step is
foreign_step() { # <msg> — a review_step by a different run, now
  mkdir -p "$WORK/logs"
  jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg m "$1" \
    '{ts:$ts, run:"other-run", job:"review", level:"info", event:"review_step", msg:$m}' >> "$WORK/logs/events-$(date -u +%Y-%m-%d).jsonl"
}
foreign_step "PR #1 abc1234 done"; foreign_step "PR #1 abc1234 posted COMMENT"; foreign_step "PR #1 abc1234 aborted HEAD moved"
run_rp prepare 1
assert_jq '.outcome == "ready"' 'another run finishing this PR minutes ago does not hold it'
run_rp abort 1 "reset"
foreign_step "PR #1 abc1234 fanned out (n=2)"
run_rp prepare 1
assert_jq '.outcome == "stand_down"' 'another run mid-pipeline on this PR holds it'

# --- delta range: extension skills route from the changes since the prior review ---
setup delta_routing
PRIOR="1111111111111111111111111111111111111111"
mk_history() { # <marker-sha>
  printf '# PR #1: alpha PR\n\n## Review at %s — %s — COMMENT\n\nx\n<!-- cg:review headRefOid=%s -->\n' \
    "${1:0:7}" "$(iso_ago 7200)" "$1" > "$WORK/reviews/pr-1.md"
}
mk_history "$PRIOR"
add_row 1 "$PRIOR" "$(iso_ago 7200)" COMMENT awaiting_label
pr_fx open '[]'
jq -n '{status:"ahead", files:[{filename:"src/gamma.ts", patch:"@@ -0,0 +1 @@\n+export const gamma = query();"}]}' \
  | fx "api repos/acme/widgets/compare/$PRIOR...$B1_SHA"
run_rp prepare 1 --on-demand
assert_jq '.delta.reachable == true and .delta.status == "ahead" and (.delta.files == ["src/gamma.ts"])' 'prepare resolves the delta range from the last review marker'
assert_jq '.skills["typescript-engineering"].files == ["src/gamma.ts"]' 'an extension skill routes from the range, not the whole PR diff'
assert_jq '.skills["doc-drift"].status == "run"' 'an always skill is unaffected by the range'
run_rp abort 1 "reset"

# an unreachable range (force-pushed away) falls back to the whole PR diff
setup delta_routing_unreachable
PRIOR="1111111111111111111111111111111111111111"
printf '# PR #1: alpha PR\n\n## Review at 1111111 — %s — COMMENT\n\nx\n<!-- cg:review headRefOid=%s -->\n' \
  "$(iso_ago 7200)" "$PRIOR" > "$WORK/reviews/pr-1.md"
add_row 1 "$PRIOR" "$(iso_ago 7200)" COMMENT awaiting_label
pr_fx open '[]'
jq -n '{status:"diverged", files:[]}' | fx "api repos/acme/widgets/compare/$PRIOR...$B1_SHA"
run_rp prepare 1 --on-demand
assert_jq '.delta.reachable == false and .delta.status == "diverged"' 'an unreachable range is reported as such'
assert_jq '(.skills["typescript-engineering"].files | length) == 2' 'an unreachable range routes skills from the whole PR diff'
run_rp abort 1 "reset"

# --- delta against the prior findings-json + overrides ---------------------------
setup delta_case
cat > "$WORK/reviews/pr-1.md" <<EOF
# PR #1: alpha PR

## PR-local overrides

- [2026-09-01 from user] Ignore: retry loop on \`src/gamma.ts:1\` — confirmed intentional
- [2026-09-01 from user] Ignore: unbounded logging in \`src/alpha.ts\` — accepted
- [2026-09-01 from user] Ignore: \`query\` in \`src/uses-alpha.ts\` — thin wrapper

## Review at aaaaaaa — $(iso_ago 7200) — COMMENT

x
<!-- findings-json: [{"status":"new","severity":"critical","file":"src/alpha.ts","line":5,"inline":true,"summary":"unbounded query","fix":"add a limit"},{"status":"new","severity":"warning","file":"src/beta.ts","line":1,"inline":false,"summary":"dead export","fix":"remove"}] -->

---
EOF
add_row 1 "0000000000000000000000000000000000000000" "$(iso_ago 7200)" COMMENT awaiting_label
pr_fx open '["cg-rereview"]'
run_rp prepare 1
printf '[{"status":"new","severity":"critical","file":"src/alpha.ts","line":6,"inline":true,"summary":"unbounded query in loop","fix":"add a limit"},{"status":"new","severity":"warning","file":"src/gamma.ts","line":1,"inline":true,"summary":"retry loop without backoff","fix":"add backoff"},{"status":"new","severity":"suggestion","file":"src/alpha.ts","line":7,"inline":false,"summary":"name the constant","fix":null},{"status":"new","severity":"warning","file":"src/uses-alpha.ts","line":1,"inline":true,"summary":"`query` call without a limit","fix":"pass a limit"}]' > "$SANDBOX/cur.json"
run_rp delta 1 "$SANDBOX/cur.json"
assert_jq '.still | length == 1 and .[0].file == "src/alpha.ts" and .[0].prior_line == 5' 'same defect one line down is still present; a shared plain word with an override is no match'
assert_jq '.fixed | length == 1 and .[0].file == "src/beta.ts"' 'a vanished prior finding is fixed'
assert_jq '.new | length == 0' 'nothing is new without the agent deciding the near miss'
assert_jq '.ambiguous | length == 1 and .[0].current.summary == "name the constant" and .[0].prior.line == 5' 'a dissimilar finding near a prior one is left to the agent'
assert_jq '.suppressed | length == 2 and (map(.file) | sort) == ["src/gamma.ts","src/uses-alpha.ts"]' 'overrides suppress by file:line and by the backticked symbol'
assert_jq '.block | contains("✅ **Fixed:** dead export") and contains("🔁 **Still present:** unbounded query")' 'block skeleton rendered'
run_rp abort 1 "reset"

# --- post: success path with an eligible and an ineligible inline comment --------
setup post_success '- review_progress: enabled'
pr_fx open '["cg-rereview"]'
run_rp prepare 1
assert_call 'statuses/'"$B1_SHA"' -f state=pending' 'progress status written at lock'
printf '### Summary\nAdds query().\n\n### Findings\n- 🔴 **Critical:** unbounded query (`src/alpha.ts:6`)\n\n### Verdict\nREQUEST_CHANGES — fix it\n' > "$SANDBOX/body.md"
printf '[{"status":"new","severity":"critical","file":"src/alpha.ts","line":6,"inline":true,"summary":"unbounded query","fix":"add a limit"},{"status":"new","severity":"warning","file":"src/alpha.ts","line":1,"inline":true,"summary":"stale header","fix":"drop it"}]' > "$SANDBOX/findings.json"
jq -nc '[{path:"src/alpha.ts",line:6,side:"RIGHT",body:"🔴 **Critical:** unbounded query\n**Fix:** add a limit"},{path:"src/alpha.ts",line:1,side:"RIGHT",body:"🟡 **Warning:** stale header\n**Fix:** drop it"}]' > "$SANDBOX/comments.json"
printf '{"id":77,"html_url":"https://example.test/r/77","state":"CHANGES_REQUESTED"}' | fx "$(POST_SLUG)"
run_rp post 1 --verdict REQUEST_CHANGES --body "$SANDBOX/body.md" --findings "$SANDBOX/findings.json" --comments "$SANDBOX/comments.json"
assert_jq '.outcome == "posted" and .review_id == 77 and .verdict == "REQUEST_CHANGES"' 'review posted'
assert_jq '.moved_to_summary | length == 1 and .[0].line == 1 and .[0].reason == "line not in a diff hunk"' 'the comment outside the hunks moved to the summary'
assert_jq '.label_removed == true and .counts == {critical:1, warning:1, suggestion:0}' 'label removed, counts reported'
assert_call '-X DELETE repos/acme/widgets/issues/1/labels/cg-rereview' 'label DELETE issued'
assert_call 'statuses/'"$B1_SHA"' -f state=success' 'terminal progress status'
assert_file_contains "$WORK/REVIEWS.md" "| 1 | $B1_SHA | .* | REQUEST_CHANGES | done |" 'done row'
assert_file_contains "$WORK/reviews/pr-1.md" "^## Review at ${B1_SHA:0:7} — .* — REQUEST_CHANGES" 'history appended'
assert_file_contains "$WORK/reviews/pr-1.md" '### Findings not anchorable inline' 'moved comment carried in the posted body'
assert_file_contains "$WORK/reviews/pr-1.md" '"file":"src/alpha.ts","line":1,"inline":false' 'findings-json patched for the moved anchor'
assert_file_contains "$WORK/reviews/pr-1.md" "<!-- cg:review headRefOid=$B1_SHA -->" 'marker line in the posted body'
assert_event 'posted REQUEST_CHANGES' 'posted event'
assert_event "${B1_SHA:0:7} done" 'done event'
ls -d "$SANDBOX"/tmp/review-pr-1* >/dev/null 2>&1 && { printf 'FAIL %s: leftovers after post\n' "$CASE"; FAILED=1; } || printf 'ok   %s: clone, copies, diff, ctx removed\n' "$CASE"

# --- post: HEAD moved → abort, re-review restores awaiting_label ------------------
setup post_head_moved
printf '# PR #1: alpha PR\n\n## Review at aaaaaaa — %s — COMMENT\n\nx\n' "$(iso_ago 7200)" > "$WORK/reviews/pr-1.md"
add_row 1 "0000000000000000000000000000000000000000" "$(iso_ago 7200)" COMMENT awaiting_label
pr_fx open '["cg-rereview"]'
run_rp prepare 1
pr_fx open '["cg-rereview"]' "ffffffffffffffffffffffffffffffffffffffff"
printf '### Summary\nx\n' > "$SANDBOX/body.md"; printf '[]' > "$SANDBOX/findings.json"
run_rp post 1 --verdict APPROVE --body "$SANDBOX/body.md" --findings "$SANDBOX/findings.json"
assert_jq '.outcome == "aborted" and (.reason | contains("HEAD moved"))' 'moved HEAD aborts the post'
assert_file_contains "$WORK/REVIEWS.md" '| 1 | 0000000000000000000000000000000000000000 | .* | COMMENT | awaiting_label |' 'awaiting_label restored from the prior'
assert_event 'aborted HEAD moved' 'abort event with reason'
grep -q 'reviews -X POST' "$SANDBOX/gh.log" && { printf 'FAIL %s: a review was posted despite the moved HEAD\n' "$CASE"; FAILED=1; } || printf 'ok   %s: nothing posted\n' "$CASE"

# --- post: a marker already on GitHub → duplicate, row self-healed ----------------
setup post_duplicate
run_rp prepare 1
printf '[{"id":5,"state":"COMMENTED","user":{"login":"test-bot"},"submitted_at":"2026-09-02T10:00:00Z","body":"old <!-- cg:review headRefOid=%s -->"}]' "$B1_SHA" | fx 'api repos/acme/widgets/pulls/1/reviews?per_page=100'
printf '### Summary\nx\n' > "$SANDBOX/body.md"; printf '[]' > "$SANDBOX/findings.json"
run_rp post 1 --verdict COMMENT --body "$SANDBOX/body.md" --findings "$SANDBOX/findings.json"
assert_jq '.outcome == "duplicate"' 'duplicate detected before posting'
assert_file_contains "$WORK/REVIEWS.md" "| 1 | $B1_SHA | 2026-09-02T10:00:00Z | SEE-GITHUB | done |" 'row self-healed with the GitHub timestamp'

# --- post: the dedup check unreadable after its retry → abort, lock released -------
setup post_dedup_unreadable
run_rp prepare 1
fx_fail 'api repos/acme/widgets/pulls/1/reviews?per_page=100' 1
fx_fail 'api repos/acme/widgets/issues/1/comments?per_page=100' 1
printf '### Summary\nx\n' > "$SANDBOX/body.md"; printf '[]' > "$SANDBOX/findings.json"
run_rp post 1 --verdict COMMENT --body "$SANDBOX/body.md" --findings "$SANDBOX/findings.json"
assert_jq '.outcome == "aborted" and (.reason | contains("dedup unreadable"))' 'no post when the marker check cannot be read'
grep -q '^| 1 |' "$WORK/REVIEWS.md" && { printf 'FAIL %s: lock row left behind\n' "$CASE"; FAILED=1; } || printf 'ok   %s: first-review lock released\n' "$CASE"
grep -q 'pulls/1/reviews -X POST' "$SANDBOX/gh.log" && { printf 'FAIL %s: a review was posted\n' "$CASE"; FAILED=1; } || printf 'ok   %s: nothing posted\n' "$CASE"

# --- post: 422 on inline lines → retry with every comment in the summary ----------
setup post_422
run_rp prepare 1
printf '### Summary\nx\n### Findings\n- 🔴 **Critical:** q (`src/alpha.ts:6`)\n' > "$SANDBOX/body.md"
printf '[{"status":"new","severity":"critical","file":"src/alpha.ts","line":6,"inline":true,"summary":"q","fix":"f"}]' > "$SANDBOX/findings.json"
jq -nc '[{path:"src/alpha.ts",line:6,side:"RIGHT",body:"🔴 **Critical:** q\n**Fix:** f"}]' > "$SANDBOX/comments.json"
printf '{"id":78,"html_url":"https://example.test/r/78","state":"CHANGES_REQUESTED"}' | fx "$(POST_SLUG)"
fx_fail_once "$(POST_SLUG)" 1
fx_err "$(POST_SLUG)" '{"message":"Unprocessable Entity","errors":[{"resource":"PullRequestReviewComment","field":"line","code":"invalid","message":"line must be part of the diff"}]}'
run_rp post 1 --verdict REQUEST_CHANGES --body "$SANDBOX/body.md" --findings "$SANDBOX/findings.json" --comments "$SANDBOX/comments.json"
assert_jq '.outcome == "posted" and .review_id == 78' 'second POST succeeds'
assert_jq '.moved_to_summary | length == 1 and .[0].reason == "422 line not in diff"' 'inline comments moved after the 422'
[ "$(grep -c 'reviews -X POST' "$SANDBOX/gh.log")" -eq 2 ] && printf 'ok   %s: exactly one retry\n' "$CASE" || { printf 'FAIL %s: POST count %s\n' "$CASE" "$(grep -c 'reviews -X POST' "$SANDBOX/gh.log")"; FAILED=1; }

# --- post: closed at post time — discard without criticals, issue path with ------
setup post_closed
run_rp prepare 1
pr_fx closed
printf '### Summary\nx\n' > "$SANDBOX/body.md"
printf '[{"status":"new","severity":"warning","file":"src/alpha.ts","line":6,"inline":false,"summary":"w","fix":"f"}]' > "$SANDBOX/findings.json"
run_rp post 1 --verdict COMMENT --body "$SANDBOX/body.md" --findings "$SANDBOX/findings.json"
assert_jq '.outcome == "closed_discarded"' 'no criticals → discarded'
grep -qE '^\| *1 \|' "$WORK/REVIEWS.md" && { printf 'FAIL %s: lock left after closed discard\n' "$CASE"; FAILED=1; } || printf 'ok   %s: lock released\n' "$CASE"
pr_fx open
run_rp prepare 1
pr_fx closed
printf '[{"status":"new","severity":"critical","file":"src/alpha.ts","line":6,"inline":false,"summary":"c","fix":"f"}]' > "$SANDBOX/findings.json"
run_rp post 1 --verdict REQUEST_CHANGES --body "$SANDBOX/body.md" --findings "$SANDBOX/findings.json"
assert_jq '.outcome == "closed_criticals" and (.criticals | length == 1) and .existing_issue == null and (.issue_marker | contains(":issue headRefOid="))' 'criticals reported for the issue'
run_rp post 1 --verdict REQUEST_CHANGES --body "$SANDBOX/body.md" --findings "$SANDBOX/findings.json" --closed-issue 9
assert_jq '.outcome == "closed_filed" and .issue == 9' 'finalized against the issue'
assert_file_contains "$WORK/REVIEWS.md" "| 1 | $B1_SHA | .* | REQUEST_CHANGES | done |" 'done row after the issue'
assert_file_contains "$WORK/reviews/pr-1.md" '_Delivered as issue #9 — PR closed before posting._' 'history note'

# --- rapid: urgent phase 1 -------------------------------------------------------
setup rapid_case '- urgent_label: urgent'
pr_fx open '["urgent"]'
run_rp prepare 1
assert_jq '.urgent == true' 'urgent flagged'
printf '### Critical findings\n- 🔴 **Critical:** q (`src/alpha.ts:6`)\n' > "$SANDBOX/rapid.md"
printf '{"id":70,"html_url":"https://example.test/r/70","state":"COMMENTED"}' | fx "$(POST_SLUG)"
run_rp rapid 1 --body "$SANDBOX/rapid.md"
assert_jq '.outcome == "posted" and .phase == "rapid" and .review_id == 70' 'rapid preliminary posted'
assert_file_contains "$WORK/REVIEWS.md" "| 1 | $B1_SHA | .* | RAPID | in_progress |" 'RAPID lock row'
assert_event 'rapid posted' 'rapid event'
printf '[{"id":70,"state":"COMMENTED","user":{"login":"test-bot"},"body":"r <!-- cg:review:rapid headRefOid=%s -->"}]' "$B1_SHA" | fx 'api repos/acme/widgets/pulls/1/reviews?per_page=100'
run_rp rapid 1 --body "$SANDBOX/rapid.md"
assert_jq '.outcome == "already_posted"' 'rapid dedup by its own marker'
run_rp abort 1 "reset"

# --- on-demand: no trigger needed at prepare or post; same-SHA ask is a skip ------
setup ondemand_case
printf '# PR #1: alpha PR\n\n## Review at aaaaaaa — %s — COMMENT\n\nx\n' "$(iso_ago 7200)" > "$WORK/reviews/pr-1.md"
add_row 1 "0000000000000000000000000000000000000000" "$(iso_ago 7200)" COMMENT awaiting_label
run_rp prepare 1 --on-demand
assert_jq '.outcome == "ready" and .on_demand == true' 'on-demand prepare without a trigger'
printf '### Summary\nx\n' > "$SANDBOX/body.md"; printf '[]' > "$SANDBOX/findings.json"
printf '{"id":80,"html_url":"https://example.test/r/80","state":"COMMENTED"}' | fx "$(POST_SLUG)"
run_rp post 1 --verdict COMMENT --body "$SANDBOX/body.md" --findings "$SANDBOX/findings.json"
assert_jq '.outcome == "posted"' 'on-demand post is not read as a withdrawn trigger'
run_rp prepare 1 --on-demand
assert_jq '.outcome == "skip" and (.reason | contains("already reviewed at"))' 'an on-demand ask for the reviewed HEAD is a skip'

# --- description-only re-review: the prior marker at this SHA is not a duplicate ---
setup description_only
printf '# PR #1: alpha PR\n\n## Review at %s — 2026-09-02T10:00:00Z — COMMENT\n\nx\n<!-- findings-json: [] -->\n' "${B1_SHA:0:7}" > "$WORK/reviews/pr-1.md"
add_row 1 "$B1_SHA" "2026-09-02T10:00:00Z" COMMENT done
pr_fx open '["cg-rereview"]'
printf '[{"id":5,"state":"COMMENTED","user":{"login":"test-bot"},"submitted_at":"2026-09-02T10:00:00Z","body":"old <!-- cg:review headRefOid=%s -->"}]' "$B1_SHA" | fx 'api repos/acme/widgets/pulls/1/reviews?per_page=100'
run_rp prepare 1
assert_jq '.outcome == "ready" and .kind == "re-review" and .prior.sha == "'"$B1_SHA"'" and .prior.status == "done"' 'same-SHA re-review prepared with its done prior'
run_rp abort 1 "checking the restore"
assert_file_contains "$WORK/REVIEWS.md" "| 1 | $B1_SHA | 2026-09-02T10:00:00Z | COMMENT | done |" 'abort restores the done row, not awaiting_label'
run_rp prepare 1
printf '### Summary\ndescription edited, no new commits\n' > "$SANDBOX/body.md"; printf '[]' > "$SANDBOX/findings.json"
printf '{"id":81,"html_url":"https://example.test/r/81","state":"COMMENTED"}' | fx "$(POST_SLUG)"
run_rp post 1 --verdict COMMENT --body "$SANDBOX/body.md" --findings "$SANDBOX/findings.json"
assert_jq '.outcome == "posted" and .review_id == 81' 'the older marker at this SHA is the prior, not a duplicate'
[ "$(grep -c '^## Review at' "$WORK/reviews/pr-1.md")" -eq 2 ] && printf 'ok   %s: second review appended\n' "$CASE" || { printf 'FAIL %s: history count\n' "$CASE"; FAILED=1; }

# --- takeover of a dead run's lock: no usable prior, abort deletes the row ---------
setup takeover_case
printf '# PR #1: alpha PR\n\n## Review at aaaaaaa — %s — COMMENT\n\nx\n' "$(iso_ago 90000)" > "$WORK/reviews/pr-1.md"
add_row 1 "$B1_SHA" "$(iso_ago 7200)" - in_progress
pr_fx open '["cg-rereview"]'
run_rp prepare 1
assert_jq '.outcome == "ready" and .kind == "re-review" and .prior == null' 'a taken-over lock carries no prior'
run_rp abort 1 "dead run"
grep -qE '^\| *1 \|' "$WORK/REVIEWS.md" && { printf 'FAIL %s: row kept after abort without a prior\n' "$CASE"; FAILED=1; } || printf 'ok   %s: row deleted for self-heal\n' "$CASE"

# --- re-entrant prepare for the same run; path guard on context --------------------
setup reentrant_case
run_rp prepare 1
run_rp prepare 1
assert_jq '.outcome == "ready" and .resumed == true' 'a second prepare by the same run resumes instead of standing down'
[ "$(events | grep -c ' locked$')" -eq 1 ] && printf 'ok   %s: one locked event\n' "$CASE" || { printf 'FAIL %s: locked logged %s times\n' "$CASE" "$(events | grep -c ' locked$')"; FAILED=1; }
run_rp context 1 ../../etc/passwd 1
assert_jq '.outcome == "error"' 'a path outside the clone is refused'
run_rp abort 1 "reset"

# --- post: re-review below APPROVE dismisses the stale approval -------------------
setup post_dismiss
printf '# PR #1: alpha PR\n\n## Review at aaaaaaa — %s — APPROVE\n\nx\n' "$(iso_ago 7200)" > "$WORK/reviews/pr-1.md"
add_row 1 "0000000000000000000000000000000000000000" "$(iso_ago 7200)" APPROVE awaiting_label
pr_fx open '["cg-rereview"]'
run_rp prepare 1
printf '[{"id":5,"state":"APPROVED","user":{"login":"test-bot"},"body":"ok <!-- cg:review headRefOid=0000000000000000000000000000000000000000 -->"}]' | fx 'api repos/acme/widgets/pulls/1/reviews?per_page=100'
printf '### Summary\nx\n' > "$SANDBOX/body.md"; printf '[]' > "$SANDBOX/findings.json"
printf '{"id":79,"html_url":"https://example.test/r/79","state":"COMMENTED"}' | fx "$(POST_SLUG)"
run_rp post 1 --verdict COMMENT --body "$SANDBOX/body.md" --findings "$SANDBOX/findings.json"
assert_jq '.outcome == "posted" and .dismissed_approval == 5' 'stale approval dismissed'
assert_call 'reviews/5/dismissals -X PUT' 'dismissal call issued'

finish
