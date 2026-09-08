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
assert_jq '.prior_findings == []' 'a first review has no prior findings'
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

# --- --help prints the subcommand table, not a guard failure -------------------
OUT="$(bash "$RP" delta 1 --help 2>&1)"
assert_out_contains 'delta <n> <findings.json>' 'a --help anywhere prints the usage'
assert_out_absent 'no prepared state' 'the guard never answers a help request'
OUT="$(bash "$RP" -h 2>&1)"
assert_out_contains 'compose-brief <n>' 'the table names every subcommand'

# --- the brief names the tools' real paths, never a guessed /usr/bin ----------
assert_file_contains "$(PR_DIR).ctx/briefs/doc-drift.md" 'jq. and .gh. do not' \
  'the brief warns that jq and gh are not in /usr/bin'
grep -q '{{TOOL_PATHS}}' "$(PR_DIR).ctx/briefs/doc-drift.md" \
  && { printf 'FAIL %s: TOOL_PATHS left unrendered\n' "$CASE"; FAILED=1; } \
  || printf 'ok   %s: the tool-path line is rendered\n' "$CASE"

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
# context prints text, never JSON — pin the contract its usage block states, so a
# future rewrite fails here instead of inside a review that pipes it into jq.
printf '%s' "$OUT" | jq -e . >/dev/null 2>&1 && { printf 'FAIL %s: context returned JSON; docs and callers expect text\n' "$CASE"; FAILED=1; } || printf 'ok   %s: context output is text, not JSON\n' "$CASE"
assert_out_contains '^# src/alpha.ts:1 — lines ' 'context leads with its text header'
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
assert_jq '(.prior_findings | length) == 2 and (.prior_findings | map(.file) == ["src/alpha.ts","src/beta.ts"]) and .prior_findings[0].line == 5 and .prior_findings[0].summary == "unbounded query"' 'prepare hands the prior findings-json to the review, anchors and wording included'
printf '[{"status":"new","severity":"critical","file":"src/alpha.ts","line":6,"inline":true,"summary":"unbounded query in loop","fix":"add a limit"},{"status":"new","severity":"warning","file":"src/gamma.ts","line":1,"inline":true,"summary":"retry loop without backoff","fix":"add backoff"},{"status":"new","severity":"suggestion","file":"src/alpha.ts","line":7,"inline":false,"summary":"name the constant","fix":null},{"status":"new","severity":"warning","file":"src/uses-alpha.ts","line":1,"inline":true,"summary":"`query` call without a limit","fix":"pass a limit"}]' > "$SANDBOX/cur.json"
run_rp delta 1 "$SANDBOX/cur.json"
assert_jq '.still | length == 1 and .[0].file == "src/alpha.ts" and .[0].prior_line == 5' 'same defect one line down is still present; a shared plain word with an override is no match'
assert_jq '.fixed | length == 1 and .[0].file == "src/beta.ts"' 'a vanished prior finding is fixed'
assert_jq '.new | length == 1 and .[0].summary == "name the constant" and .[0].ambiguous == true' 'a near miss takes its suggestion and is marked ambiguous'
assert_jq '.ambiguous | length == 1 and .[0].current.summary == "name the constant" and .[0].prior.line == 5 and .[0].suggest == "new" and .[0].severity_match == false and .[0].distance == 2' 'the pair the agent settles carries the suggestion and its evidence'
assert_jq '.suppressed | length == 2 and (map(.file) | sort) == ["src/gamma.ts","src/uses-alpha.ts"]' 'overrides suppress by file:line and by the backticked symbol'
assert_jq '.block | contains("✅ **Fixed:** dead export") and contains("🔁 **Still present:** unbounded query") and contains("🆕 **New:** name the constant")' 'the block carries every bucket, the suggestion included'
assert_jq '.annotated == "'"$(PR_DIR)"'.ctx/findings.annotated.json"' 'delta names the annotated findings file'
assert_event 'delta settled (still=1, new=1, fixed=1, ambiguous=1)' 'the delta round is a measurable milestone'
A="$(PR_DIR).ctx/findings.annotated.json"
assert_file_contains "$A" '"status": "still"' 'the annotated array carries the still status'
jq -e 'map(.status) == ["still","new","fixed"] and (map(.file) == ["src/alpha.ts","src/alpha.ts","src/beta.ts"])' "$A" >/dev/null \
  && printf 'ok   %s: annotated keeps the agent order and appends the fixed carryover\n' "$CASE" \
  || { printf 'FAIL %s: annotated wrong: %s\n' "$CASE" "$(cat "$A")"; FAILED=1; }
jq -e '[ .[] | select(.status == "fixed") ] | length == 1 and .[0].fix == null and .[0].inline == false' "$A" >/dev/null \
  && printf 'ok   %s: a fixed carryover carries no fix and no inline comment\n' "$CASE" \
  || { printf 'FAIL %s: fixed carryover wrong\n' "$CASE"; FAILED=1; }
jq -e 'any(.[]; .file == "src/gamma.ts" or .file == "src/uses-alpha.ts")' "$A" >/dev/null \
  && { printf 'FAIL %s: a suppressed finding reached the annotated array\n' "$CASE"; FAILED=1; } \
  || printf 'ok   %s: overrides keep their findings out of the annotated array\n' "$CASE"
assert_jq '.prior_count == 2' 'the prior count is reported'
# A wrong path is a missing file, not malformed JSON: the error must say so, or the
# next run reads "not a JSON array" and looks for a parse bug that is not there.
run_rp delta 1 "$SANDBOX/nope.json"
assert_jq '.outcome == "error" and (.error | contains("does not exist"))' 'a missing findings file is named as missing'
assert_jq '.error | contains("not a JSON array") | not' 'a missing file is not reported as malformed JSON'
printf '{"findings":[]}' > "$SANDBOX/obj.json"
run_rp delta 1 "$SANDBOX/obj.json"
assert_jq '.outcome == "error" and (.error | contains("not a JSON array"))' 'a non-array findings file is still reported as malformed'
run_rp delta 1
assert_jq '.outcome == "error" and (.error | contains("usage: delta"))' 'a missing argument prints the usage'
run_rp abort 1 "reset"

# --- delta: an override hides a finding, it does not fix the defect --------------
setup delta_suppressed_prior
cat > "$WORK/reviews/pr-1.md" <<EOF
# PR #1: alpha PR

## PR-local overrides

- [2026-09-01 from user] Ignore: retry loop on \`src/gamma.ts:1\` — confirmed intentional

## Review at aaaaaaa — $(iso_ago 7200) — COMMENT

x
<!-- findings-json: [{"status":"new","severity":"warning","file":"src/gamma.ts","line":1,"inline":true,"summary":"retry loop without backoff","fix":"add backoff"}] -->

---
EOF
add_row 1 "0000000000000000000000000000000000000000" "$(iso_ago 7200)" COMMENT awaiting_label
pr_fx open '["cg-rereview"]'
run_rp prepare 1
printf '[{"status":"new","severity":"warning","file":"src/gamma.ts","line":1,"inline":true,"summary":"retry loop without backoff","fix":"add backoff"}]' > "$SANDBOX/cur-sup.json"
run_rp delta 1 "$SANDBOX/cur-sup.json"
assert_jq '.suppressed | length == 1' 'the override suppresses this round report of the finding'
assert_jq '.fixed == []' 'the prior it matches is never announced as fixed'
assert_jq '.still == [] and .new == []' 'a suppressed finding is in no reported bucket'
assert_jq '.block == "### Changes since last review"' 'the block says nothing about it'
run_rp abort 1 "reset"

# --- delta: a merged finding matches on any of its `also` anchors ----------------
setup delta_also
cat > "$WORK/reviews/pr-1.md" <<EOF
# PR #1: alpha PR

## Review at aaaaaaa — $(iso_ago 7200) — COMMENT

x
<!-- findings-json: [{"status":"new","severity":"critical","file":"src/alpha.ts","line":5,"also":[{"file":"src/beta.ts","line":1}],"inline":true,"summary":"unbounded query","fix":"add a limit"}] -->

---
EOF
add_row 1 "0000000000000000000000000000000000000000" "$(iso_ago 7200)" COMMENT awaiting_label
pr_fx open '["cg-rereview"]'
run_rp prepare 1
# the class survives at the second location only: the review now anchors it there
printf '[{"status":"still","severity":"critical","file":"src/beta.ts","line":1,"inline":true,"summary":"unbounded query","fix":"add a limit"}]' > "$SANDBOX/cur-also.json"
run_rp delta 1 "$SANDBOX/cur-also.json"
assert_jq '.still | length == 1 and .[0].file == "src/beta.ts"' 'a prior `also` anchor matches the current primary anchor'
assert_jq '.fixed == [] and .new == []' 'one class at a second location is neither fixed nor new'
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

# --- post: anchors that are not a line of the file they name are nulled ----------
setup post_anchor_check
run_rp prepare 1
printf '### Summary\nAdds query().\n\n### Findings\n- 🔴 **Critical:** unbounded query (`src/alpha.ts:6`)\n\n### Verdict\nREQUEST_CHANGES — fix it\n' > "$SANDBOX/body.md"
# src/alpha.ts is 12 lines on b1: 999 and the `also` 400 cannot exist, src/ghost.ts is not in the clone
printf '[{"status":"new","severity":"critical","file":"src/alpha.ts","line":6,"also":[{"file":"src/alpha.ts","line":400}],"inline":true,"summary":"unbounded query","fix":"add a limit"},{"status":"new","severity":"warning","file":"src/alpha.ts","line":999,"inline":true,"summary":"past the end","fix":"drop it"},{"status":"new","severity":"warning","file":"src/ghost.ts","line":5,"inline":false,"summary":"not in the clone","fix":"keep it"}]' > "$SANDBOX/findings.json"
printf '{"id":78,"html_url":"https://example.test/r/78","state":"CHANGES_REQUESTED"}' | fx "$(POST_SLUG)"
run_rp post 1 --verdict REQUEST_CHANGES --body "$SANDBOX/body.md" --findings "$SANDBOX/findings.json"
assert_jq '.outcome == "posted"' 'a bad anchor never blocks the post'
assert_jq '.anchors_nulled | length == 2' 'both impossible anchors are reported'
assert_jq '[.anchors_nulled[].line] | sort == [400, 999]' 'the reported anchors are the out-of-range ones'
assert_file_contains "$WORK/reviews/pr-1.md" '"summary":"past the end"' 'the finding itself is never dropped'
assert_file_contains "$WORK/reviews/pr-1.md" '"file":"src/alpha.ts","line":null,"inline":false' 'an impossible line is nulled and made summary-only'
assert_file_contains "$WORK/reviews/pr-1.md" '"line":6,"also":\[\]' 'the finding keeps its real anchor and drops the impossible also entry'
assert_file_contains "$WORK/reviews/pr-1.md" '"file":"src/ghost.ts","line":5' 'a file absent from the clone is left alone'

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

# --- compose-brief: this PR's compose contract ------------------------------------
setup compose_brief
cat > "$WORK/MEMORY.md" <<'EOF'
# Memory

## Ignore List

- [2026-09-01 from user] Skip JSDoc findings → memory/style.md

## Feedback Log

- [2026-09-02 from user] the retry finding was right
EOF
cat > "$WORK/reviews/pr-1.md" <<EOF
# PR #1: alpha PR

## PR-local overrides

- [2026-09-01 from user] Ignore: retry loop on \`src/gamma.ts:1\` — confirmed intentional

## Review at aaaaaaa — $(iso_ago 7200) — COMMENT

x
<!-- findings-json: [{"status":"new","severity":"warning","file":"src/beta.ts","line":1,"inline":false,"summary":"dead export","fix":"remove"}] -->

---
EOF
add_row 1 "0000000000000000000000000000000000000000" "$(iso_ago 7200)" COMMENT awaiting_label
pr_fx open '["cg-rereview"]'
run_rp prepare 1
run_rp compose-brief 1
assert_out_contains '## PR #1: alpha PR' 'the body header is rendered, not described'
assert_out_contains '\*\*Author:\*\* alice | \*\*Branch:\*\* b1 → main | \*\*Changes:\*\* +3 −1 (3 files)' 'the header line carries this PR real values'
assert_out_contains 'Previous HEAD: 0000000' 'the re-review line is pre-filled from the prior row'
assert_out_absent 'unknow[^n]' 'a seven-character cut never truncates the fallback'
assert_out_contains '### Documentation Check' 'a skill that ran gets its section, by its configured name'
assert_out_contains '### TypeScript Review' 'every skill that ran gets its section'
assert_out_contains 'complete re-review' 'the label scope comes from the live trigger'
assert_out_contains 'findings-json' 'the findings-json rules are quoted from their home'
assert_out_contains 'Cap 25 inline comments' 'the inline mapping rules are quoted from their home'
assert_out_contains '🟢 budget per review' 'the suggestion budget is quoted from finding-form.md'
assert_out_contains 'Ignore: retry loop on' "this PR's overrides are in the brief"
assert_out_contains 'Skip JSDoc findings' 'the memory rules in force are in the brief'
assert_out_absent 'the retry finding was right' 'the Feedback Log is history, not a rule in force'
assert_out_contains 'findings.annotated.json' 'the brief names the file post takes'
# `collect` decides which sections exist: a skill with no output is skill-errored
mkdir -p "$(PR_DIR).out"; printf -- '- 🟡 **Warning:** x (`src/alpha.ts:6`)\n  **Fix:** y\n' > "$(PR_DIR).out/doc-drift.txt"
run_rp collect 1
run_rp compose-brief 1
assert_out_contains '### Documentation Check' 'the skill with output keeps its section'
assert_out_absent '### TypeScript Review' 'a skill-errored skill gets no section'
assert_out_contains 'no section (audit line only): typescript-engineering (skill-errored)' 'the omitted skill is named with its reason'
run_rp abort 1 "reset"

# a first review: no delta, no prior, and the same rules
setup compose_brief_first
run_rp prepare 1
run_rp compose-brief 1
assert_out_contains 'first review' 'a first review is labelled as one'
assert_out_absent 'Previous HEAD' 'a first review has no changes-since block'
assert_out_contains '"status": "new"' 'a first review posts every finding as new'
assert_out_contains 'none' 'no overrides and no memory read as none'
assert_out_contains 'sections that post: Documentation Check, TypeScript Review' 'the section list names what will post'
run_rp abort 1 "reset"

finish
