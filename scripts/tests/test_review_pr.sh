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
  CLONE_SRC=""   # a case sets it to make the clone fail
  : > "$SANDBOX/gh.log"
}
run_rp() { # <cmd> <n> [args…] → $OUT
  OUT="$(GH_HOST="" WORK_DIR="$WORK" HOME="$FAKE_HOME" TMPDIR="$SANDBOX/tmp" \
         CG_CLONE_URL="${CLONE_SRC:-$FX}" LOG_RUN_ID="$SESSION" GH_CALLS_LOG="$SANDBOX/gh.log" \
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
assert_file_lacks() { # <file> <grep pattern> <description>
  if grep -q -- "$2" "$1" 2>/dev/null; then printf 'FAIL %s: %s (pattern %s found in %s)\n' "$CASE" "$3" "$2" "$1"; FAILED=1
  else printf 'ok   %s: %s\n' "$CASE" "$3"; fi
}
PR_DIR() { printf '%s/tmp/review-pr-1' "$SANDBOX"; }
BUDGET="$(sed -n 's/^SKILL_BUDGET_MIN=\([0-9][0-9]*\).*/\1/p' "$RP")"   # the script's one constant
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
# one diff slice per reviewable file, none for noise (docs/review.md step c)
assert_jq '.files | map(has("diff")) == [false,true,true]' 'a slice per code file, none for the lockfile'
jq -r '.files[] | select(.diff) | .diff' <<<"$OUT" | while read -r d; do head -1 "$d"; done | grep -c '^diff --git' | grep -qx 2 \
  && grep -q '^+NEW6 query()$' "$(jq -r '.files[] | select(.path=="src/alpha.ts") | .diff' <<<"$OUT")" \
  && ! grep -q 'gamma' "$(jq -r '.files[] | select(.path=="src/alpha.ts") | .diff' <<<"$OUT")" \
  && printf 'ok   %s: each slice holds its own file section only\n' "$CASE" || { printf 'FAIL %s: slices wrong\n' "$CASE"; FAILED=1; }
assert_jq '.skills["typescript-engineering"].prompt == "Review skill `typescript-engineering` for PR #1: read `'"$(PR_DIR)"'.ctx/briefs/typescript-engineering.md` and follow it exactly — it holds your whole task."' 'the subagent prompt names skill, PR and brief path'
assert_jq '.skills["doc-drift"].status == "run" and .skills["typescript-engineering"].status == "run" and (.skills["typescript-engineering"].files == ["src/alpha.ts","src/gamma.ts"])' 'always + extension routing; the .yaml lockfile is noise and routes nowhere'
assert_jq '.skills["typescript-engineering"].workdir == "'"$(PR_DIR)"'.s-typescript-engineering"' 'per-skill copy path'
[ -d "$(PR_DIR).s-doc-drift" ] && [ -d "$(PR_DIR).s-typescript-engineering" ] && [ -d "$(PR_DIR).out" ] \
  && printf 'ok   %s: per-skill copies and .out exist\n' "$CASE" || { printf 'FAIL %s: copies/.out missing\n' "$CASE"; FAILED=1; }
# each copy is a worktree of the clone: on the PR branch at the same HEAD, the
# base ref resolving through the shared refs (docs/skills.md → Clone,
# credential helper, cleanup)
W="$(PR_DIR).s-typescript-engineering"
[ -f "$W/.git" ] && [ "$(git -C "$W" symbolic-ref -q --short HEAD)" = b1 ] \
  && [ "$(git -C "$W" rev-parse HEAD)" = "$B1_SHA" ] \
  && [ "$(git -C "$W" diff --name-only origin/main...HEAD | tr '\n' ' ')" = "pnpm-lock.yaml src/alpha.ts src/gamma.ts " ] \
  && printf 'ok   %s: a per-skill copy is a worktree on the PR branch at its HEAD, diffable against the base\n' "$CASE" \
  || { printf 'FAIL %s: per-skill worktree wrong (.git file: %s, branch: %s)\n' "$CASE" \
         "$([ -f "$W/.git" ] && echo yes || echo no)" "$(git -C "$W" symbolic-ref -q --short HEAD 2>&1)"; FAILED=1; }
git -C "$(PR_DIR)" rev-parse --verify -q origin/main >/dev/null && printf 'ok   %s: base ref fetched\n' "$CASE" || { printf 'FAIL %s: origin/main missing in the clone\n' "$CASE"; FAILED=1; }
B="$(PR_DIR).ctx/briefs/typescript-engineering.md"
grep -q 'PR #1' "$B" && grep -q 'typescript-engineering' "$B" && grep -q "$(PR_DIR).s-typescript-engineering" "$B" && grep -q 'src/gamma.ts' "$B" \
  && printf 'ok   %s: brief carries PR, skill, workdir and routed files\n' "$CASE" || { printf 'FAIL %s: brief incomplete\n' "$CASE"; FAILED=1; }
grep -q '{{' "$B" && { printf 'FAIL %s: unreplaced placeholder in brief\n' "$CASE"; FAILED=1; } || printf 'ok   %s: no placeholder left\n' "$CASE"
# no profile: no slice file, and the orientation names no missing path
# (docs/profile.md → Using it)
[ -e "$(PR_DIR).ctx/profile.md" ] && { printf 'FAIL %s: a slice was written without a profile\n' "$CASE"; FAILED=1; } \
  || printf 'ok   %s: no profile, no slice file\n' "$CASE"
assert_file_contains "$B" 'no repository map is available' 'without a profile the brief says no map is available'
assert_file_lacks "$B" 'PROFILE\.md\|profile\.md' 'without a profile the brief names no map path'
[ -n "$BUDGET" ] && assert_file_contains "$B" "Time budget: $BUDGET minutes" 'the brief carries the budget minutes of the script constant'
assert_file_contains "$B" 'again during step 1 before each new file or check' 'the budget is checked during the skill work, not only after it'
assert_file_contains "$(PR_DIR).ctx/briefs/doc-drift.md" 'Scope: the whole clone' 'an always skill scopes the whole clone'
assert_file_lacks "$(PR_DIR).ctx/briefs/doc-drift.md" 'Focus' 'a first review gives an always skill no focus'
assert_file_contains "$(PR_DIR).ctx/context.json" '"looks ok"' 'human comment kept in context'
grep -q 'mine' "$(PR_DIR).ctx/context.json" && { printf 'FAIL %s: own marker comment leaked into context\n' "$CASE"; FAILED=1; } || printf 'ok   %s: own past review dropped from context\n' "$CASE"
jq -e '."src/alpha.ts".right | index(6) != null and index(1) == null' "$(PR_DIR).ctx/hunks.json" >/dev/null && printf 'ok   %s: hunk index has the added line, not line 1\n' "$CASE" || { printf 'FAIL %s: hunk index wrong: %s\n' "$CASE" "$(cat "$(PR_DIR).ctx/hunks.json")"; FAILED=1; }
jq -e '."src/alpha.ts".dependents == ["src/uses-alpha.ts"] and ."src/alpha.ts".changed_lines == [3,4,5,6,7,8,9,10]' "$(PR_DIR).ctx/pack.json" >/dev/null && printf 'ok   %s: context pack lists the dependent and the hunk lines\n' "$CASE" || { printf 'FAIL %s: pack wrong: %s\n' "$CASE" "$(cat "$(PR_DIR).ctx/pack.json")"; FAILED=1; }
# a PR with no sensitive path and no second-look pattern: an empty signal, and
# no block in the brief (docs/review.md → Per-PR review sequence, step b)
assert_jq '.paths.risk == "'"$(PR_DIR)"'.ctx/risk.json"' 'the risk prescan has its path in the prepare output'
jq -e '.paths == [] and .patterns == [] and .truncated == false' "$(PR_DIR).ctx/risk.json" >/dev/null \
  && printf 'ok   %s: a clean PR prescans to an empty signal\n' "$CASE" \
  || { printf 'FAIL %s: risk wrong: %s\n' "$CASE" "$(cat "$(PR_DIR).ctx/risk.json" 2>/dev/null)"; FAILED=1; }
grep -q 'risk prescan' "$B" \
  && { printf 'FAIL %s: an empty signal still wrote a block into the brief\n' "$CASE"; FAILED=1; } \
  || printf 'ok   %s: an empty signal writes no block\n' "$CASE"
[ -f "$(PR_DIR).ctx/added.tsv" ] \
  && { printf 'FAIL %s: the added-line stream outlived the prescan\n' "$CASE"; FAILED=1; } \
  || printf 'ok   %s: the added-line stream is deleted after the prescan\n' "$CASE"

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
# the severity rubric comes from its home in docs/finding-form.md
assert_file_contains "$(PR_DIR).ctx/briefs/doc-drift.md" '^   - 🔴 \*\*Critical\*\* — a reachable path gives a wrong result' \
  'the brief quotes the severity rubric'
assert_file_contains "$(PR_DIR).ctx/briefs/doc-drift.md" '^   - 🟢 \*\*Suggestion\*\* — an improvement' 'the rubric is quoted whole'
grep -q 'Blocking severity\|{{SEVERITY}}' "$(PR_DIR).ctx/briefs/doc-drift.md" \
  && { printf 'FAIL %s: the rubric quote overran or stayed unrendered\n' "$CASE"; FAILED=1; } \
  || printf 'ok   %s: the rubric quote stops at the list\n' "$CASE"

# --- step: heartbeat + event ---------------------------------------------------
run_rp step 1 "fanned out (n=2)"
assert_jq '.outcome == "ok"' 'step ok'
assert_event 'fanned out (n=2)' 'milestone logged'
FO="$(cat "$(PR_DIR).ctx/fanout.ts" 2>/dev/null)"
case "$FO" in (''|*[!0-9]*) printf 'FAIL %s: no fan-out record (%s)\n' "$CASE" "$FO"; FAILED=1;;
  (*) [ $(( $(date -u +%s) - FO )) -lt 120 ] && printf 'ok   %s: the fan-out step records its epoch time\n' "$CASE" \
        || { printf 'FAIL %s: fan-out record not current: %s\n' "$CASE" "$FO"; FAILED=1; };; esac
assert_event 'locked (refresh, fanned out (n=2))' 'lock refresh logged'

# --- context / sweep -----------------------------------------------------------
OUT="$(GH_HOST="" WORK_DIR="$WORK" HOME="$FAKE_HOME" TMPDIR="$SANDBOX/tmp" LOG_RUN_ID="$SESSION" PATH="$T_DIR/bin:$PATH" bash "$RP" context 1 src/alpha.ts 6 2)"
assert_out_contains "in this PR's hunks: yes" 'an added line is in the hunks'
assert_out_contains '     6	NEW6' 'numbered lines printed'
OUT="$(GH_HOST="" WORK_DIR="$WORK" HOME="$FAKE_HOME" TMPDIR="$SANDBOX/tmp" LOG_RUN_ID="$SESSION" PATH="$T_DIR/bin:$PATH" bash "$RP" context 1 src/alpha.ts 1 1)"
assert_out_contains "in this PR's hunks: no" 'an untouched line is pre-existing'
# context prints text, never JSON — pin the contract its usage block states, so a
# future rewrite fails here instead of inside a review that pipes it into jq.
printf '%s' "$OUT" | jq -e . >/dev/null 2>&1 && { printf 'FAIL %s: context returned JSON; docs and callers expect text\n' "$CASE"; FAILED=1; } || printf 'ok   %s: context output is text, not JSON\n' "$CASE"
assert_out_contains '^# src/alpha.ts:1 — lines ' 'context leads with its text header'
run_rp sweep 1 'query\(\)'
assert_jq '.changed_files_hits | length == 2' 'sweep finds both changed-file occurrences'
assert_jq '.untouched_code_hits == 0' 'no untouched occurrences'
# --tree is the claim sweep (docs/review.md → Claim sweep): a stale statement
# sits outside the diff, so the changed-file scope reports it as a bare count and
# only --tree can name it.
run_rp sweep 1 'export const'
assert_jq '(.changed_files_hits | length) == 1 and .untouched_code_hits == 1' 'the changed-file sweep only counts the untouched hit'
run_rp sweep 1 'export const' --tree
assert_jq '.tree_hits | length == 2' 'the claim sweep locates the hit outside the diff too'
assert_jq '.tree_hits | any(contains("src/beta.ts"))' 'the untouched file is named, not counted'
assert_jq '.truncated == false' 'a small sweep is not truncated'

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

# --- the profile slice: the rows the PR touches and the conventions, one file per PR ---
# (docs/profile.md → Using it). The convention file has `## ` headings of its own,
# so a cut of PROFILE.md at the next `## ` would lose its tail.
mk_profile() {
  jq -n '{profile:1, repo:"github.com/acme/widgets", default_branch:"main",
    modules:[{path:"src", name:"widgets-src", kind:"npm", workspace:false, role:"the widget sources", src:"src/package.json"},
             {path:"lib", name:"untouched-lib", kind:"npm", workspace:false, role:"not in this PR", src:"lib/package.json"}],
    docs:[{paths:["src/**"], page:"docs/alpha.md", title:"Alpha & beta", stamp:"blob:1", via:"paths", src:"src/alpha.ts"}],
    decisions:[],
    conventions:[{path:"CLAUDE.md", bytes:61, content:"# Rules\n\n## Style\nIndent with tabs in src/.\n\n## Tests\nRun make test.", src:"CLAUDE.md"}],
    ownership:[{pattern:"src/**", owners:"@acme/core", src:"CODEOWNERS"}],
    checks:{workflows:[], required:[]},
    noise:[{glob:"pnpm-lock.yaml", class:"lockfile", src:"builtin"}],
    history:{days:90, reviews:0, findings:0, fixed:0, still:0, dirs:[], classes:[]},
    notes:[{paths:"src/**", note:"Amounts are integer cents", src:"src/package.json", blob:"0", status:"current"}],
    structure:{doc_roots:[], adr_dirs:[]}}' > "$WORK/PROFILE.json"
  {
    printf -- '---\nprofile: 1\nrepo: github.com/acme/widgets\n---\n\n## Modules (2)\n\n'
    printf '| path | name | kind | workspace | role | src |\n| --- | --- | --- | --- | --- | --- |\n'
    printf '| src | widgets-src | npm | - | the widget sources | src/package.json |\n'
    printf '| lib | untouched-lib | npm | - | not in this PR | lib/package.json |\n\n'
    printf '## Conventions\n\n### CLAUDE.md (61 bytes)\n\n# Rules\n\n## Style\nIndent with tabs in src/.\n\n## Tests\nRun make test.\n\n'
    printf '## Ownership (1)\n\n| pattern | owners | src |\n| --- | --- | --- |\n| src/** | @acme/core | CODEOWNERS |\n\n'
    printf '## Noise (1 globs — never reviewed as code)\n\n| glob | class | src |\n| --- | --- | --- |\n| pnpm-lock.yaml | lockfile | builtin |\n\n'
    printf '## History (90 d · 0 reviews · 0 findings · 0 fixed · 0 still open)\n\n_No findings recorded in the window._\n'
  } > "$WORK/PROFILE.md"
}
setup brief_profile_slice
mk_profile
run_rp prepare 1
SL="$(PR_DIR).ctx/profile.md"
[ -f "$SL" ] && printf 'ok   %s: prepare writes the slice\n' "$CASE" || { printf 'FAIL %s: no slice at %s\n' "$CASE" "$SL"; FAILED=1; }
for sk in doc-drift typescript-engineering; do
  assert_file_contains "$(PR_DIR).ctx/briefs/$sk.md" "read \`$SL\`" "the $sk brief names the slice"
  assert_file_lacks "$(PR_DIR).ctx/briefs/$sk.md" 'PROFILE\.md' "the $sk brief does not send the skill to the whole map"
done
assert_file_contains "$SL" "^# PR #1 .*Full map: \`$WORK/PROFILE.md\` — read it only for a path outside these rows" 'the header names the PR and the full map'
assert_file_contains "$SL" '^- src — widgets-src \[npm\]: the widget sources$' 'a touched module row'
assert_file_contains "$SL" '^- src/\*\* → @acme/core$' 'a touched ownership row'
assert_file_lacks "$SL" 'untouched-lib' 'no row of an untouched module'
assert_file_contains "$SL" '^### CLAUDE.md (61 bytes)$' 'the conventions copy keeps its file heading'
assert_file_contains "$SL" '^Run make test.$' 'the conventions copy is whole past its own ## headings'
assert_file_lacks "$SL" 'History' 'no section the PR does not touch'
assert_file_contains "$SL" '^## Noise (changed files' 'the slice carries the noise files of the PR'
assert_file_contains "$SL" '^- pnpm-lock.yaml \[lockfile\]$' 'a noise file with its class'
assert_file_contains "$SL" '^## Notes (agent-owned' 'the slice carries the agent-owned notes'
assert_file_contains "$SL" '^- src/\*\* — Amounts are integer cents \[current\]$' 'a note row with its status'
# a brief value with `&` arrives unchanged: bash 5.2 expands an unquoted `&` in
# a ${t//…/…} replacement to the matched placeholder
assert_file_contains "$(PR_DIR).ctx/briefs/doc-drift.md" '^- src/\*\* → docs/alpha.md — Alpha & beta (stamp' 'a verify_live row with & reaches the brief unchanged'
assert_file_lacks "$(PR_DIR).ctx/briefs/doc-drift.md" '{{' 'no placeholder left in a brief with &'
run_rp abort 1 "reset"
[ -e "$SL" ] && { printf 'FAIL %s: the slice outlived the abort\n' "$CASE"; FAILED=1; } || printf 'ok   %s: the slice goes with the context directory\n' "$CASE"

# more than five noise files: the slice names their classes, not the paths
setup brief_profile_noise_classes
mk_profile
git -C "$FX" checkout -q b1
for d in a b c d e; do mkdir -p "$FX/$d"; printf 'lockfileVersion: 9\n' > "$FX/$d/pnpm-lock.yaml"; done
git -C "$FX" add -A && git -C "$FX" "${GIT_ID[@]}" commit -qm locks
B1_SHA="$(git -C "$FX" rev-parse HEAD)"
git -C "$FX" diff main...b1 > "$SANDBOX/diff.txt"
git -C "$FX" checkout -q main
pr_fx open '[]' "$B1_SHA"; ctx_fx
run_rp prepare 1
assert_file_contains "$(PR_DIR).ctx/profile.md" '^- 6 files: lockfile$' 'six noise files: the slice names the count and the classes'
assert_file_lacks "$(PR_DIR).ctx/profile.md" '^- a/pnpm-lock.yaml' 'six noise files: no path list'
run_rp abort 1 "reset"

setup brief_profile_disabled '- project_profile: disabled'
mk_profile
run_rp prepare 1
[ -e "$(PR_DIR).ctx/profile.md" ] && { printf 'FAIL %s: a disabled profile still wrote a slice\n' "$CASE"; FAILED=1; } \
  || printf 'ok   %s: a disabled profile writes no slice\n' "$CASE"
assert_file_contains "$(PR_DIR).ctx/briefs/doc-drift.md" 'no repository map is available' 'a disabled profile: the brief says no map is available'
run_rp abort 1 "reset"

# --- collect: the wall-clock budget warns, it never changes a finding ------------
touch_at() { # <epoch> <file>
  touch -t "$(date -d "@$1" +%Y%m%d%H%M.%S 2>/dev/null || date -r "$1" +%Y%m%d%H%M.%S)" "$2"
}
setup collect_budget
run_rp prepare 1
run_rp step 1 "fanned out (n=2)"
printf -- '- 🟢 **Suggestion:** a nit (`src/alpha.ts:6`)\nBudget reached — not checked: src/gamma.ts\n' > "$(PR_DIR).out/doc-drift.txt"
printf -- '- 🟢 **Suggestion:** another nit (`src/gamma.ts:1`)\n' > "$(PR_DIR).out/typescript-engineering.txt"
touch_at $(( $(cat "$(PR_DIR).ctx/fanout.ts") + (BUDGET + 10) * 60 )) "$(PR_DIR).out/typescript-engineering.txt"
run_rp collect 1
assert_jq '.audit_lines == ["PR #1: doc-drift ran (findings=1)", "PR #1: typescript-engineering ran (findings=1, files=2)"]' 'the budget line and the late output leave the findings counts alone'
assert_jq '.form_warnings | any(test("^typescript-engineering: output [0-9]+ min after the fan-out, past the '"$BUDGET"' min budget$"))' 'an output past the budget after the fan-out warns'
assert_jq '.form_warnings | any(startswith("doc-drift: output")) | not' 'an output inside the budget does not warn'
assert_jq '.form_warnings | index("doc-drift: Budget reached — not checked: src/gamma.ts") != null' 'the budget line warns with what was not checked'
assert_jq '.skills["doc-drift"].budget_stopped == true and (.skills["typescript-engineering"] | has("budget_stopped") | not)' 'only the skill with the budget line is recorded as stopped'
run_rp compose-brief 1
assert_out_contains "_Limits: 1 skill(s) stopped at the $BUDGET min time budget: doc-drift\\._" 'the limits line names the skill that stopped at the budget'
assert_out_contains '### Documentation Check' 'a skill stopped at the budget keeps its section'
rm -f "$(PR_DIR).ctx/fanout.ts"
run_rp collect 1
assert_jq '.form_warnings | any(contains("after the fan-out")) | not' 'no fan-out record, no budget check'
run_rp abort 1 "reset"

# --- risk prescan: the sensitive paths and the second-look patterns of the diff ---
setup risk_prescan
git -C "$FX" checkout -q b1
mkdir -p "$FX/src/auth" "$FX/.github/workflows" "$FX/docs"
printf 'export const login = (p) => eval(p);\n' > "$FX/src/auth/session.ts"
printf 'name: ci\non: [push]\njobs: {}\n' > "$FX/.github/workflows/ci.yml"
printf '#!/bin/sh\nrm -rf "$1"\n' > "$FX/src/clean-up.sh"
printf '# notes\neval(x)\n' > "$FX/docs/notes.md"
git -C "$FX" add -A && git -C "$FX" "${GIT_ID[@]}" commit -qm risky
B1_SHA="$(git -C "$FX" rev-parse HEAD)"
git -C "$FX" diff main...b1 > "$SANDBOX/diff.txt"
git -C "$FX" checkout -q main
pr_fx open '[]' "$B1_SHA"; ctx_fx
run_rp prepare 1
assert_jq '.outcome == "ready"' 'ready'
R="$(PR_DIR).ctx/risk.json"
jq -e '[.paths[] | select(.path == "src/auth/session.ts") | .reason] == ["auth"]
   and [.paths[] | select(.path == ".github/workflows/ci.yml") | .reason] == ["ci"]' "$R" >/dev/null \
  && printf 'ok   %s: a changed file in a sensitive area is named with its area\n' "$CASE" \
  || { printf 'FAIL %s: risk paths wrong: %s\n' "$CASE" "$(cat "$R" 2>/dev/null)"; FAILED=1; }
jq -e '[.patterns[] | select(.id == "eval") | {file, line}] == [{file:"src/auth/session.ts", line:1}]
   and [.patterns[] | select(.id == "rm-rf") | .file] == ["src/clean-up.sh"]' "$R" >/dev/null \
  && printf 'ok   %s: an added line with a second-look pattern carries its file and line\n' "$CASE" \
  || { printf 'FAIL %s: risk patterns wrong: %s\n' "$CASE" "$(cat "$R" 2>/dev/null)"; FAILED=1; }
jq -e '[.patterns[] | select(.file == "docs/notes.md")] == [] and .truncated == false' "$R" >/dev/null \
  && printf 'ok   %s: the prescan reads the reviewable classes only\n' "$CASE" \
  || { printf 'FAIL %s: docs class scanned: %s\n' "$CASE" "$(cat "$R" 2>/dev/null)"; FAILED=1; }
B="$(PR_DIR).ctx/briefs/doc-drift.md"
grep -q 'src/auth/session.ts:1 — eval: dynamic code evaluation' "$B" \
  && grep -q 'src/auth/session.ts — sensitive area: auth' "$B" \
  && printf 'ok   %s: the brief carries the prescan\n' "$CASE" \
  || { printf 'FAIL %s: the brief misses the prescan block\n' "$CASE"; FAILED=1; }
grep -q '{{' "$B" && { printf 'FAIL %s: unreplaced placeholder in brief\n' "$CASE"; FAILED=1; } || printf 'ok   %s: no placeholder left\n' "$CASE"
run_rp abort 1 "reset"

# --- the diff walk: headers are read before a section's first @@ only -----------
# A path with a space (git ends its ---/+++ line with a TAB), a deleted file, a
# rename with an edit, a removed SQL comment (the diff line `--- note`) and an
# added line `++ b/src/beta.ts` (the diff line `+++ b/src/beta.ts`).
setup diff_walk_headers
mkdir -p "$FX/docs" "$FX/db"
printf 'intro\n' > "$FX/docs/User Guide.md"
printf 'select 1;\n-- note\nselect 2;\n' > "$FX/db/q.sql"
seq 1 20 > "$FX/src/long.ts"
git -C "$FX" add -A && git -C "$FX" "${GIT_ID[@]}" commit -qm more-base
git -C "$FX" checkout -q b1 && git -C "$FX" "${GIT_ID[@]}" merge -q --no-edit main
printf 'intro\n++ b/src/beta.ts\n' > "$FX/docs/User Guide.md"
printf 'select 1;\nselect 2;\n' > "$FX/db/q.sql"
git -C "$FX" rm -q src/beta.ts
git -C "$FX" mv src/long.ts src/moved.ts && sed -i.bak 's/^5$/five/' "$FX/src/moved.ts" && rm -f "$FX/src/moved.ts.bak"
git -C "$FX" add -A && git -C "$FX" "${GIT_ID[@]}" commit -qm edge
B1_SHA="$(git -C "$FX" rev-parse HEAD)"
git -C "$FX" diff -M main...b1 > "$SANDBOX/diff.txt"
git -C "$FX" checkout -q main
pr_fx open '[]' "$B1_SHA"; ctx_fx
run_rp prepare 1
assert_jq '.outcome == "ready"' 'ready'
assert_jq '[.files[] | {(.path): .status}] | add | ."docs/User Guide.md" == "modified" and ."db/q.sql" == "modified" and ."src/beta.ts" == "removed" and ."src/moved.ts" == "modified" and ."src/alpha.ts" == "modified" and ."src/gamma.ts" == "added"' 'every section listed once with its status'
assert_jq '.files | length == 7' 'no path invented from hunk content'
assert_jq '[.files[] | select(.class != "lockfile") | .diff | type == "string" and length > 0] | all' 'every reviewable file has a slice path'
GUIDE="$(jq -r '.files[] | select(.path == "docs/User Guide.md") | .diff' <<<"$OUT")"
BETA="$(jq -r '.files[] | select(.path == "src/beta.ts") | .diff' <<<"$OUT")"
head -1 "$GUIDE" 2>/dev/null | grep -qx 'diff --git a/docs/User Guide.md b/docs/User Guide.md' \
  && grep -qx '+++ b/src/beta.ts' "$GUIDE" && head -1 "$BETA" 2>/dev/null | grep -qx 'diff --git a/src/beta.ts b/src/beta.ts' \
  && printf 'ok   %s: a header-shaped content line stays in its own slice\n' "$CASE" \
  || { printf 'FAIL %s: slices wrong (guide=%s beta=%s)\n' "$CASE" "$GUIDE" "$BETA"; FAILED=1; }
jq -e '."docs/User Guide.md".right == [1,2] and ."db/q.sql".left == [1,2,3] and ."db/q.sql".right == [1,2]' "$(PR_DIR).ctx/hunks.json" >/dev/null \
  && printf 'ok   %s: the hunk index keys the spaced path without its TAB and counts every content line\n' "$CASE" \
  || { printf 'FAIL %s: hunk index wrong: %s\n' "$CASE" "$(cat "$(PR_DIR).ctx/hunks.json")"; FAILED=1; }
run_rp abort 1 "reset"

# --- per-skill checkout fallbacks: a copy when `git worktree add` fails, the
# clone itself when the copy fails too, and the brief names the checkout the
# skill gets (docs/skills.md → Clone, credential helper, cleanup) ---------------
shim_dir() { # <fail-cp:0|1> → a PATH dir whose git refuses `worktree add`
  local d="$SANDBOX/shim"
  mkdir -p "$d"
  printf '#!/usr/bin/env bash\ncase " $* " in (*" worktree add "*) exit 128;; esac\nexec %q "$@"\n' "$(command -v git)" > "$d/git"
  [ "$1" = 1 ] && printf '#!/usr/bin/env bash\ncase "$*" in (*review-pr-1.s-*) exit 1;; esac\nexec %q "$@"\n' "$(command -v cp)" > "$d/cp"
  chmod +x "$d"/*
  printf '%s' "$d"
}
setup prepare_checkout_copy
P0="$PATH"; PATH="$(shim_dir 0):$P0"; run_rp prepare 1; PATH="$P0"
W="$(PR_DIR).s-typescript-engineering"; B="$(PR_DIR).ctx/briefs/typescript-engineering.md"
assert_jq '.outcome == "ready" and .skills["typescript-engineering"].workdir == "'"$W"'"' 'a refused worktree falls back to a copy'
[ -d "$W/.git" ] && [ "$(git -C "$W" rev-parse HEAD)" = "$B1_SHA" ] \
  && printf 'ok   %s: the copy holds its own .git at the PR HEAD\n' "$CASE" \
  || { printf 'FAIL %s: copy wrong (.git directory: %s)\n' "$CASE" "$([ -d "$W/.git" ] && echo yes || echo no)"; FAILED=1; }
grep -qF "\`$W\`" "$B" && printf 'ok   %s: the brief names the copy\n' "$CASE" || { printf 'FAIL %s: the brief does not name the copy\n' "$CASE"; FAILED=1; }
run_rp abort 1 "reset"

setup prepare_checkout_clone
P0="$PATH"; PATH="$(shim_dir 1):$P0"; run_rp prepare 1; PATH="$P0"
B="$(PR_DIR).ctx/briefs/typescript-engineering.md"
assert_jq '.outcome == "ready" and ([.skills[] | select(.status == "run") | .workdir] == ["'"$(PR_DIR)"'", "'"$(PR_DIR)"'"])' 'a refused copy leaves each skill the clone itself'
ls -d "$(PR_DIR)".s-* >/dev/null 2>&1 \
  && { printf 'FAIL %s: a failed checkout left a directory behind\n' "$CASE"; FAILED=1; } \
  || printf 'ok   %s: no partial checkout is left\n' "$CASE"
grep -qF "\`$(PR_DIR)\`" "$B" && ! grep -qF "$(PR_DIR).s-" "$B" \
  && printf 'ok   %s: the brief names the clone, never a missing checkout\n' "$CASE" \
  || { printf 'FAIL %s: the brief does not name the clone\n' "$CASE"; FAILED=1; }
run_rp abort 1 "reset"

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

# --- the PR hold: prepare takes it, and leaves a PR another live run holds -----
setup prepare_hold
hold_owner() { sed -n 2p "$WORK/.holds.lock/1" 2>/dev/null; }
mkdir -p "$WORK/.holds.lock"
printf '%s\n%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" other-run > "$WORK/.holds.lock/1"
run_rp prepare 1 --on-demand
assert_jq '.outcome == "stand_down" and (.reason | contains("another run holds this PR"))' 'an on-demand review leaves a PR another run holds'
[ "$(hold_owner)" = other-run ] && printf 'ok   %s: %s\n' "$CASE" 'the other run keeps its hold' \
  || { printf 'FAIL %s: hold owner %s\n' "$CASE" "$(hold_owner)"; FAILED=1; }
[ -f "$WORK/REVIEWS.md" ] && grep -q '^| 1 |' "$WORK/REVIEWS.md" \
  && { printf 'FAIL %s: a lock row was written\n' "$CASE"; FAILED=1; } || printf 'ok   %s: %s\n' "$CASE" 'no lock row is written'
rm -f "$WORK/.holds.lock/1"
run_rp prepare 1 --on-demand
assert_jq '.outcome == "ready"' 'a free PR is prepared'
[ "$(hold_owner)" = "$SESSION" ] && printf 'ok   %s: %s\n' "$CASE" 'prepare takes the hold for its run' \
  || { printf 'FAIL %s: hold owner %s\n' "$CASE" "$(hold_owner)"; FAILED=1; }
run_rp abort 1 "reset"
run_rp release 1
mkdir -p "$(PR_DIR)"
run_rp prepare 1 --on-demand
assert_jq '.outcome == "stand_down"' 'a live holder still stands the run down'
[ -z "$(hold_owner)" ] && printf 'ok   %s: %s\n' "$CASE" 'the hold it took is given back' \
  || { printf 'FAIL %s: hold owner %s\n' "$CASE" "$(hold_owner)"; FAILED=1; }
rm -rf "$(PR_DIR)"

# --- live holder: a fresh tree stands down, a dead run's leftover is reclaimed ----
setup prepare_holder
mkdir -p "$(PR_DIR)"
run_rp prepare 1
assert_jq '.outcome == "stand_down"' 'a recent tree means a live holder'
touch -t 202001010000 "$(PR_DIR)"
run_rp prepare 1
assert_jq '.outcome == "ready"' 'an old tree with no events is reclaimed'
run_rp abort 1 "reset"
# another run's events: a terminal step is not life, a mid-pipeline step of a
# run that locked the PR is
foreign_step() { # <msg> — a review_step by a different run, now
  mkdir -p "$WORK/logs"
  jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg m "$1" \
    '{ts:$ts, run:"other-run", job:"review", level:"info", event:"review_step", msg:$m}' >> "$WORK/logs/events-$(date -u +%Y-%m-%d).jsonl"
}
foreign_step "PR #1 abc1234 done"; foreign_step "PR #1 abc1234 posted COMMENT"; foreign_step "PR #1 abc1234 aborted HEAD moved"
run_rp prepare 1
assert_jq '.outcome == "ready"' 'another run finishing this PR minutes ago does not hold it'
run_rp abort 1 "reset"
foreign_step "PR #1 abc1234 locked"; foreign_step "PR #1 abc1234 fanned out (n=2)"
run_rp prepare 1
assert_jq '.outcome == "stand_down"' 'another run mid-pipeline on this PR holds it'
# liveness is that run's NEWEST step, not the presence of a non-terminal one:
# the milestones a review logged on the way must not outlive its own abort,
# or a dead run keeps blocking its PR for the rest of the quiet window
foreign_step "PR #1 abc1234 verified"; foreign_step "PR #1 abc1234 composed"
foreign_step "PR #1 abc1234 aborted HEAD moved"
run_rp prepare 1
assert_jq '.outcome == "ready"' "a run's own milestones do not outlive its terminal step"
run_rp abort 1 "reset"
# a live fan-out is never displaced: `skill:<name> done` is the adapter's step
# for a finished skill, not a finished run — and it carries no sha token
foreign_step "PR #1 fanned out (n=2)"; foreign_step "PR #1 skill:doc-drift done"
run_rp prepare 1
assert_jq '.outcome == "stand_down"' 'skill:<name> done is not a terminal run step'
# the fan-out is silent by construction: 40 minutes of it is a healthy review
foreign_step_ago() { # <secs-ago> <msg>
  mkdir -p "$WORK/logs"
  jq -nc --arg ts "$(iso_ago "$1")" --arg m "$2" \
    '{ts:$ts, run:"other-run", job:"review", level:"info", event:"review_step", msg:$m}' >> "$WORK/logs/events-$(date -u +%Y-%m-%d).jsonl"
}
setup prepare_holder_fanout
foreign_step_ago 2700 "PR #1 abc1234 locked"
foreign_step_ago 2400 "PR #1 abc1234 fanned out (n=2)"
run_rp prepare 1
assert_jq '.outcome == "stand_down"' 'a 40m fan-out silence still holds the PR'
setup prepare_holder_fanout_expired
foreign_step_ago 4500 "PR #1 abc1234 locked"
foreign_step_ago 4200 "PR #1 abc1234 fanned out (n=2)"
run_rp prepare 1
assert_jq '.outcome == "ready"' 'past the fan-out window the PR is free'
run_rp abort 1 "reset"
setup prepare_holder_fanout_over
foreign_step_ago 2700 "PR #1 abc1234 locked"
foreign_step_ago 2400 "PR #1 abc1234 fanned out (n=2)"
foreign_step_ago 1800 "PR #1 abc1234 verified"
run_rp prepare 1
assert_jq '.outcome == "ready"' 'silence after verified is death again'
run_rp abort 1 "reset"
# only a run that locked the PR holds it: a taker that stood down holds nothing,
# whatever step text it logged — a chain of them would keep a dead holder alive
# and starve the PR while the schedule fires
run_step_ago() { # <run> <secs-ago> <msg>
  mkdir -p "$WORK/logs"
  jq -nc --arg ts "$(iso_ago "$2")" --arg r "$1" --arg m "$3" \
    '{ts:$ts, run:$r, job:"review", level:"info", event:"review_step", msg:$m}' >> "$WORK/logs/events-$(date -u +%Y-%m-%d).jsonl"
}
setup prepare_holder_standdown_chain
run_step_ago dead-holder 4500 "PR #1 abc1234 locked"
run_step_ago dead-holder 4200 "PR #1 abc1234 fanned out (n=2)"
run_step_ago taker-a 900 "PR #1 abc1234 stand_down (live holder)"
run_step_ago taker-b 300 "PR #1 abc1234 stood down (live holder)"
run_rp prepare 1
assert_jq '.outcome == "ready"' 'a chain of stand-downs does not hold the PR, whatever their text'
run_rp abort 1 "reset"
# liveness is the holder's newest event of any kind, as preflight judges it: a
# run whose turn ended after the fan-out logged its stop, so the fan-out window
# no longer applies — preflight hands the PR over and prepare must not stand down
run_event_ago() { # <run> <secs-ago> <event> <msg>
  mkdir -p "$WORK/logs"
  jq -nc --arg ts "$(iso_ago "$2")" --arg r "$1" --arg e "$3" --arg m "$4" \
    '{ts:$ts, run:$r, job:"review", level:"info", event:$e, msg:$m}' >> "$WORK/logs/events-$(date -u +%Y-%m-%d).jsonl"
}
setup prepare_holder_stopped_after_fanout
run_step_ago stopped 3300 "PR #1 abc1234 locked"
run_step_ago stopped 3300 "PR #1 abc1234 fanned out (n=4)"
run_event_ago stopped 3210 hold "PR #1: released at stop"
run_rp prepare 1
assert_jq '.outcome == "ready"' 'a holder quiet since its stop is dead inside the fan-out window'
run_rp abort 1 "reset"
setup prepare_holder_fanout_newest
run_step_ago fanning 2700 "PR #1 abc1234 locked"
run_step_ago fanning 2400 "PR #1 abc1234 fanned out (n=2)"
run_step_ago fanning 2400 "PR #1 abc1234 locked (refresh, fanned out (n=2))"
run_rp prepare 1
assert_jq '.outcome == "stand_down"' 'a fan-out lock refresh as the newest event keeps the fan-out window'
setup prepare_holder_old_lock
run_step_ago holder 4500 "PR #1 abc1234 locked"
run_step_ago holder 300 "PR #1 skill:doc-drift done"
run_rp prepare 1
assert_jq '.outcome == "stand_down"' 'a lock older than the scan window still names the holder'

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
assert_jq '.skills["doc-drift"].status == "run" and .skills["doc-drift"].files == []' 'an always skill still runs, unrestricted'
DD="$(PR_DIR).ctx/briefs/doc-drift.md"
assert_file_contains "$DD" 'Scope: the whole clone (an `always` skill). Focus' 'an always skill keeps the whole clone and gets a focus'
assert_file_contains "$DD" '^- src/gamma.ts$' 'the focus lists the range'
assert_file_lacks "$DD" '^- src/alpha.ts$' 'the focus holds the range only'
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

# a range that leaves the PR's own diff untouched holds base-branch merges only
# (docs/review-rereview.md → Re-review output)
diff_dg() { { if command -v sha256sum >/dev/null 2>&1; then sha256sum
    elif command -v shasum >/dev/null 2>&1; then shasum -a 256
    else cksum; fi; } < "$SANDBOX/diff.txt" 2>/dev/null | tr -dc '0-9a-f' | cut -c1-12; }
mk_meta_history() { # <marker-sha> <digest>
  printf '# PR #1: alpha PR\n\n## Review at %s — %s — COMMENT\n\nx\n<!-- review-meta: {"diff_digest":"%s","checks":[],"deferred":[]} -->\n<!-- cg:review headRefOid=%s -->\n' \
    "${1:0:7}" "$(iso_ago 7200)" "$2" "$1" > "$WORK/reviews/pr-1.md"
}
ahead_fx() { jq -n '{status:"ahead", files:[{filename:"src/gamma.ts", patch:"@@ -0,0 +1 @@\n+export const gamma = query();"}]}' \
  | fx "api repos/acme/widgets/compare/$PRIOR...$B1_SHA"; }

setup delta_own_change
PRIOR="1111111111111111111111111111111111111111"
mk_meta_history "$PRIOR" "$(diff_dg)"
add_row 1 "$PRIOR" "$(iso_ago 7200)" COMMENT awaiting_label
pr_fx open '[]'; ahead_fx
run_rp prepare 1 --on-demand
assert_jq '.delta.own_change == false' 'an unchanged PR diff marks the range as base merges only'
# steps c and d are skipped, so `composed` is the one milestone verify asks for
run_rp step 1 composed
printf '### Summary\n%s\n\n### Verdict\nCOMMENT — ok\n' "$(cat "$(PR_DIR).ctx/limits.txt" 2>/dev/null)" > "$SANDBOX/body.md"; printf '[]' > "$SANDBOX/findings.json"
printf '{"id":82,"html_url":"https://example.test/r/82","state":"COMMENTED"}' | fx "$(POST_SLUG)"
run_rp post 1 --verdict COMMENT --body "$SANDBOX/body.md" --findings "$SANDBOX/findings.json"
assert_jq '.outcome == "posted"' 'the base-merges-only round posts'
run_rp verify 1
assert_jq '.checks[] | select(.check == "milestones") | .status == "ok"' 'a base-merges-only round needs no fan-out or verified milestone'

setup delta_own_change_moved
PRIOR="1111111111111111111111111111111111111111"
mk_meta_history "$PRIOR" "0123456789ab"
add_row 1 "$PRIOR" "$(iso_ago 7200)" COMMENT awaiting_label
pr_fx open '[]'; ahead_fx
run_rp prepare 1 --on-demand
assert_jq '.delta.own_change == true' 'a changed PR diff keeps the normal delta round'
run_rp abort 1 "reset"

setup delta_own_change_absent
PRIOR="1111111111111111111111111111111111111111"
printf '# PR #1: alpha PR\n\n## Review at 1111111 — %s — COMMENT\n\nx\n<!-- cg:review headRefOid=%s -->\n' \
  "$(iso_ago 7200)" "$PRIOR" > "$WORK/reviews/pr-1.md"
add_row 1 "$PRIOR" "$(iso_ago 7200)" COMMENT awaiting_label
pr_fx open '[]'; ahead_fx
run_rp prepare 1 --on-demand
assert_jq '.delta.own_change == true' 'a review older than review-meta keeps the normal delta round'
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
assert_event 'delta settled (still=1, new=1, fixed=1, ambiguous=1, late=0)' 'the delta round is a measurable milestone'
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
assert_jq '.ambiguous[0].index == 2 and .ambiguous[0].settled == "new"' 'an ambiguous pair names the index --settle takes'
run_rp delta 1 "$SANDBOX/cur.json" --settle 2=still
assert_jq '.ambiguous[0].settled == "still" and (.still | length) == 2 and (.new | length) == 0' 'one --settle rerun moves the pair to still'
assert_jq '.block | contains("🔁 **Still present:** name the constant") and (contains("🆕") | not)' 'the rerun rebuilds the block'
jq -e 'map(.status) == ["still","still","fixed"]' "$A" >/dev/null \
  && printf 'ok   %s: the rerun rewrites the annotated statuses\n' "$CASE" \
  || { printf 'FAIL %s: annotated after --settle wrong: %s\n' "$CASE" "$(cat "$A")"; FAILED=1; }
run_rp delta 1 "$SANDBOX/cur.json" --settle 0=new
assert_jq '.outcome == "error" and (.error | contains("no ambiguous pair at index 0"))' 'a --settle on a settled finding is refused'
run_rp delta 1 "$SANDBOX/cur.json" --settle 2=maybe
assert_jq '.outcome == "error" and (.error | contains("<index>=still|new"))' 'a --settle value other than still|new is refused'
run_rp delta 1 "$SANDBOX/cur.json" --settle 2==still
assert_jq '.outcome == "error" and (.error | contains("<index>=still|new"))' 'a --settle value with a second = is refused'
run_rp delta 1 "$SANDBOX/cur.json" --settle 02=still
assert_jq '.outcome == "ok" and .ambiguous[0].settled == "still" and (.new | length) == 0' 'a --settle index with a leading zero settles that index'
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
# a suppressed near miss: not offered for settling, and its prior stays open
printf '[{"status":"new","severity":"suggestion","file":"src/gamma.ts","line":2,"inline":false,"summary":"unchecked error return","fix":null}]' > "$SANDBOX/cur-sup-amb.json"
run_rp delta 1 "$SANDBOX/cur-sup-amb.json"
assert_jq '(.suppressed | length) == 1 and .ambiguous == [] and .fixed == []' 'a suppressed ambiguous pair is not listed and fixes nothing'
run_rp delta 1 "$SANDBOX/cur-sup-amb.json" --settle 0=new
assert_jq '.outcome == "error" and (.error | contains("no ambiguous pair at index 0"))' 'a --settle on a suppressed pair is refused'
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

# --- delta: a new finding outside the range since the prior review is late ------
late_history() { # <marker-sha>
  cat > "$WORK/reviews/pr-1.md" <<EOF
# PR #1: alpha PR

## Review at ${1:0:7} — $(iso_ago 7200) — COMMENT

x
<!-- findings-json: [{"status":"new","severity":"warning","file":"src/gamma.ts","line":40,"inline":true,"summary":"stale header","fix":"drop it"}] -->
<!-- cg:review headRefOid=$1 -->

---
EOF
}
setup delta_late
PRIOR="1111111111111111111111111111111111111111"
late_history "$PRIOR"
add_row 1 "$PRIOR" "$(iso_ago 7200)" COMMENT awaiting_label
pr_fx open '["cg-rereview"]'
jq -n '{status:"ahead", files:[{filename:"src/alpha.ts", patch:"@@ -4,3 +4,4 @@\n a\n+b @@ -30,2 +30,2 @@\n c\n d"}, {filename:"docs/a.md", patch:"@@ -1 +1 @@\n-x\n+y"}]}' \
  | fx "api repos/acme/widgets/compare/$PRIOR...$B1_SHA"
run_rp prepare 1
jq -e '.known == true and .files["src/alpha.ts"] == [[4,7]] and .files["docs/a.md"] == [[1,1]]' "$(PR_DIR).ctx/age.json" >/dev/null \
  && printf 'ok   %s: a complete re-review still ages its findings against the range, hunk headers only at a line start\n' "$CASE" \
  || { printf 'FAIL %s: age.json wrong: %s\n' "$CASE" "$(cat "$(PR_DIR).ctx/age.json")"; FAILED=1; }
printf '[{"status":"new","severity":"critical","file":"src/alpha.ts","line":6,"inline":true,"summary":"unbounded query","fix":"add a limit"},{"status":"new","severity":"critical","file":"src/beta.ts","line":1,"inline":true,"summary":"capability outside the policy","fix":"drop the capability"},{"status":"new","severity":"warning","file":"src/beta.ts","line":9,"also":[{"file":"src/alpha.ts","line":4}],"inline":true,"summary":"missing guard","fix":"guard it"},{"status":"new","severity":"suggestion","file":"src/delta.ts","line":null,"inline":false,"summary":"name the constant","fix":null}]' > "$SANDBOX/cur-late.json"
run_rp delta 1 "$SANDBOX/cur-late.json"
assert_jq '(.new | length) == 4 and (.late | map(.index)) == [1,3] and .age_known == true' 'a finding with no anchor in the range is late, any anchor in a hunk keeps it new'
assert_jq '.block | contains("🆕 **New:** unbounded query") and contains("🔎 **Missed earlier:** capability outside the policy (`src/beta.ts:1`) — present at `1111111`") and (contains("🆕 **New:** capability") | not)' 'the block names a late finding as missed earlier, with the prior SHA'
assert_jq '.fixed | length == 1' 'a prior the round no longer reports is fixed as before'
assert_event 'late=2)' 'the delta event counts the late findings'
A="$(PR_DIR).ctx/findings.annotated.json"
jq -e 'map(.status) == ["new","new","new","new","fixed"] and map(.late // false) == [false,true,false,true,false]' "$A" >/dev/null \
  && printf 'ok   %s: annotated keeps status new and flags the late ones\n' "$CASE" \
  || { printf 'FAIL %s: annotated wrong: %s\n' "$CASE" "$(cat "$A")"; FAILED=1; }
run_rp delta 1 "$SANDBOX/cur-late.json" --fresh 1
assert_jq '(.late | map(.index)) == [3] and (.block | contains("🆕 **New:** capability outside the policy"))' '--fresh clears a late finding the range causes from elsewhere'
jq -e '.[1] | has("late") | not' "$A" >/dev/null \
  && printf 'ok   %s: a cleared finding carries no late flag\n' "$CASE" \
  || { printf 'FAIL %s: --fresh left the flag: %s\n' "$CASE" "$(cat "$A")"; FAILED=1; }
run_rp delta 1 "$SANDBOX/cur-late.json" --fresh 7
assert_jq '.outcome == "error" and (.error | contains("no late finding at index 7"))' 'a --fresh on an index that is not a finding is refused'
run_rp delta 1 "$SANDBOX/cur-late.json" --fresh 0
assert_jq '.outcome == "error" and (.error | contains("no late finding at index 0"))' 'a --fresh on a new finding that is not late is refused'
run_rp delta 1 "$SANDBOX/cur-late.json" --fresh x
assert_jq '.outcome == "error" and (.error | contains("--fresh takes a finding index"))' 'a --fresh value that is not an index is refused'
run_rp abort 1 "reset"

# a range that is not whole (force-pushed away) cannot age a finding: nothing is late
setup delta_late_unknown
PRIOR="1111111111111111111111111111111111111111"
late_history "$PRIOR"
add_row 1 "$PRIOR" "$(iso_ago 7200)" COMMENT awaiting_label
pr_fx open '["cg-rereview"]'
jq -n '{status:"diverged", files:[]}' | fx "api repos/acme/widgets/compare/$PRIOR...$B1_SHA"
run_rp prepare 1
printf '[{"status":"new","severity":"critical","file":"src/beta.ts","line":1,"inline":true,"summary":"capability outside the policy","fix":"drop the capability"}]' > "$SANDBOX/cur-late2.json"
run_rp delta 1 "$SANDBOX/cur-late2.json"
assert_jq '.late == [] and .age_known == false and (.block | contains("🔎") | not)' 'an unknown range keeps every unmatched finding new'
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
printf '{"checks":[{"for":"unbounded query","run":"grep -rn query src/","clean":"no hits"}],"deferred":[{"file":"src/beta.ts","line":1,"note":"pre–existing"}]}' > "$SANDBOX/meta.json"
run_rp post 1 --verdict REQUEST_CHANGES --body "$SANDBOX/body.md" --findings "$SANDBOX/findings.json" --comments "$SANDBOX/comments.json" --meta "$SANDBOX/meta.json"
assert_jq '.outcome == "posted" and .review_id == 77 and .verdict == "REQUEST_CHANGES"' 'review posted'
assert_jq '.moved_to_summary | length == 1 and .[0].line == 1 and .[0].reason == "line not in a diff hunk"' 'the comment outside the hunks moved to the summary'
assert_jq '.label_removed == true and .counts == {critical:1, warning:1, suggestion:0}' 'label removed, counts reported'
assert_call '-X DELETE repos/acme/widgets/issues/1/labels/cg-rereview' 'label DELETE issued'
assert_call 'statuses/'"$B1_SHA"' -f state=success' 'terminal progress status'
assert_file_contains "$WORK/REVIEWS.md" "| 1 | $B1_SHA | .* | REQUEST_CHANGES | done |" 'done row'
assert_file_contains "$WORK/reviews/pr-1.md" "^## Review at ${B1_SHA:0:7} — .* — REQUEST_CHANGES" 'history appended'
assert_file_contains "$WORK/REVIEW-LEDGER.jsonl" '"pr":1,"ts":".*","sha":"'"${B1_SHA:0:7}"'"' 'ledger row appended with the review'
assert_file_contains "$WORK/REVIEW-LEDGER.jsonl" '"verdict":"REQUEST_CHANGES"' 'ledger row carries the verdict'
assert_file_contains "$WORK/REVIEW-LEDGER.jsonl" '"findings":\[{"status":"new","severity":"critical"},{"status":"new","severity":"warning"}\]' 'ledger row carries the findings, status and severity only'
assert_file_contains "$WORK/reviews/pr-1.md" '### Findings not anchorable inline' 'moved comment carried in the posted body'
assert_file_contains "$WORK/reviews/pr-1.md" '"file":"src/alpha.ts","line":1,"inline":false' 'findings-json patched for the moved anchor'
assert_file_contains "$WORK/reviews/pr-1.md" "<!-- cg:review headRefOid=$B1_SHA -->" 'marker line in the posted body'
assert_file_contains "$WORK/reviews/pr-1.md" '<!-- review-meta: {"diff_digest":"[0-9a-f]' 'review-meta carries the digest post computes'
assert_file_contains "$WORK/reviews/pr-1.md" '"checks":\[{"for":"unbounded query"' 'review-meta carries the checks the agent composed'
assert_file_contains "$WORK/reviews/pr-1.md" '"deferred":\[{"file":"src/beta.ts"' 'review-meta carries the dropped suggestions'
assert_file_contains "$WORK/reviews/pr-1.md" '"rereview":{"trigger":"label","label":"cg-rereview","login":null}' 'review-meta carries the re-review trigger for the fix round'
grep -q 'review-meta' "$SANDBOX/body.md" && { printf 'FAIL %s: review-meta reached the composed body\n' "$CASE"; FAILED=1; } || printf 'ok   %s: review-meta is never part of the rendered review\n' "$CASE"
assert_event 'posted REQUEST_CHANGES' 'posted event'
assert_event "${B1_SHA:0:7} done" 'done event'

# --- post: a pull request this account opened gets the verdict as a COMMENT -----
own_pr_fx() { # the live PR opened by the GitHub App the token acts as
  local f; f="$GH_FIXTURES/$(fx_for 'api repos/acme/widgets/pulls/1')"
  jq '.user.login = "acme-app[bot]"' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}
setup post_own_pr
seed_identity 'acme-app[bot]'
pr_fx open; own_pr_fx
run_rp prepare 1
printf '### Summary\nx\n### Verdict\nREQUEST_CHANGES — fix it\n' > "$SANDBOX/body.md"
printf '[{"status":"new","severity":"critical","file":"src/alpha.ts","line":6,"inline":false,"summary":"q","fix":"f"}]' > "$SANDBOX/findings.json"
printf '{"id":81,"html_url":"https://example.test/r/81","state":"COMMENTED"}' | fx "$(POST_SLUG)"
run_rp post 1 --verdict REQUEST_CHANGES --body "$SANDBOX/body.md" --findings "$SANDBOX/findings.json"
assert_jq '.outcome == "posted" and .verdict == "REQUEST_CHANGES" and .event == "COMMENT"' 'the verdict stays, the event is a comment'
jq -e -s 'any(.[]; .event == "COMMENT" and (.body | contains("**Verdict: REQUEST_CHANGES.** This account opened the pull request.")))' "$SANDBOX/gh.log.input" >/dev/null \
  && printf 'ok   %s: the body names the verdict GitHub did not take\n' "$CASE" \
  || { printf 'FAIL %s: payload %s\n' "$CASE" "$(cat "$SANDBOX/gh.log.input" 2>/dev/null)"; FAILED=1; }
[ "$(grep -c 'reviews -X POST' "$SANDBOX/gh.log")" -eq 1 ] && printf 'ok   %s: one POST, no retry\n' "$CASE" \
  || { printf 'FAIL %s: POST count %s\n' "$CASE" "$(grep -c 'reviews -X POST' "$SANDBOX/gh.log")"; FAILED=1; }
assert_file_contains "$WORK/REVIEWS.md" "| 1 | $B1_SHA | .* | REQUEST_CHANGES | done |" 'the row keeps the verdict'

# --- the same refusal without an identity cache: the one retry is a COMMENT -----
# gh prints the refusal in the error body on stdout; stderr has the message only
own_pr_422_fx() {
  fx_fail_once "$(POST_SLUG)" 1
  fx_err "$(POST_SLUG)" 'gh: Unprocessable Entity (HTTP 422)'
  fx_out "$(POST_SLUG)" '{"message":"Unprocessable Entity","errors":["Review Can not approve your own pull request"],"status":"422"}'
}
setup post_own_pr_422
pr_fx open; own_pr_fx
run_rp prepare 1
printf '### Summary\nx\n### Verdict\nAPPROVE — fine\n' > "$SANDBOX/body.md"
printf '[]' > "$SANDBOX/findings.json"
printf '{"id":82,"html_url":"https://example.test/r/82","state":"COMMENTED"}' | fx "$(POST_SLUG)"
own_pr_422_fx
run_rp post 1 --verdict APPROVE --body "$SANDBOX/body.md" --findings "$SANDBOX/findings.json"
assert_jq '.outcome == "posted" and .verdict == "APPROVE" and .event == "COMMENT"' 'the refusal turns the retry into a comment'
jq -e -s '[.[] | .event] == ["APPROVE", "COMMENT"]' "$SANDBOX/gh.log.input" >/dev/null \
  && printf 'ok   %s: first APPROVE, then COMMENT\n' "$CASE" \
  || { printf 'FAIL %s: events %s\n' "$CASE" "$(jq -c -s '[.[] | .event]' "$SANDBOX/gh.log.input" 2>/dev/null)"; FAILED=1; }

# --- a pull request someone else opened keeps the verdict as the event ----------
setup post_other_author
seed_identity 'acme-app[bot]'
pr_fx open
run_rp prepare 1
printf '### Summary\nx\n### Verdict\nAPPROVE — fine\n' > "$SANDBOX/body.md"
printf '[]' > "$SANDBOX/findings.json"
printf '{"id":83,"html_url":"https://example.test/r/83","state":"APPROVED"}' | fx "$(POST_SLUG)"
run_rp post 1 --verdict APPROVE --body "$SANDBOX/body.md" --findings "$SANDBOX/findings.json"
assert_jq '.outcome == "posted" and .event == "APPROVE"' 'an App reviewing another author approves'

# --- post: the delta label is a trigger the post removes ------------------------
setup post_delta_label '- rereview_delta_label: cg-delta'
pr_fx open '["cg-delta"]'
run_rp prepare 1
printf '### Summary\nx\n### Verdict\nCOMMENT\n' > "$SANDBOX/body.md"
printf '[]' > "$SANDBOX/findings.json"
printf '{"id":79,"html_url":"https://example.test/r/79","state":"COMMENTED"}' | fx "$(POST_SLUG)"
run_rp post 1 --verdict COMMENT --body "$SANDBOX/body.md" --findings "$SANDBOX/findings.json"
assert_jq '.outcome == "posted" and .label_removed == true' 'the delta label counts as the removed trigger'
assert_call '-X DELETE repos/acme/widgets/issues/1/labels/cg-delta' 'the delta label DELETE issued'
grep -q 'labels/cg-rereview' "$SANDBOX/gh.log" \
  && { printf 'FAIL %s: a label that is not on the PR was deleted\n' "$CASE"; FAILED=1; } \
  || printf 'ok   %s: only the labels on the PR are removed\n' "$CASE"
assert_file_contains "$WORK/reviews/pr-1.md" '"rereview":{"trigger":"label","label":"cg-rereview","login":null,"delta_label":"cg-delta"}' 'review-meta names the delta label for the fix round'
ls -d "$SANDBOX"/tmp/review-pr-1* >/dev/null 2>&1 && { printf 'FAIL %s: leftovers after post\n' "$CASE"; FAILED=1; } || printf 'ok   %s: clone, copies, diff, ctx removed\n' "$CASE"

# --- post: a token of another login removes the served review request -----------
req_fx() { # the live PR requests a review from bot_login
  local f; f="$GH_FIXTURES/$(fx_for 'api repos/acme/widgets/pulls/1')"
  jq '.requested_reviewers = [{login:"test-bot"}]' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}
setup post_request_app_token '- rereview_trigger: both'
seed_identity 'acme-app[bot]'
pr_fx open; req_fx
run_rp prepare 1
printf '### Summary\nx\n### Verdict\nCOMMENT\n' > "$SANDBOX/body.md"
printf '[]' > "$SANDBOX/findings.json"
printf '{"id":84,"html_url":"https://example.test/r/84","state":"COMMENTED"}' | fx "$(POST_SLUG)"
run_rp post 1 --verdict COMMENT --body "$SANDBOX/body.md" --findings "$SANDBOX/findings.json"
assert_jq '.outcome == "posted"' 'the App token posts the review'
grep -qF -- '-X DELETE repos/acme/widgets/pulls/1/requested_reviewers -f reviewers[]=test-bot' "$SANDBOX/gh.log" \
  && printf 'ok   %s: the review request of bot_login is removed\n' "$CASE" \
  || { printf 'FAIL %s: no request removal in %s\n' "$CASE" "$(tr '\n' ';' < "$SANDBOX/gh.log")"; FAILED=1; }
# the token is bot_login: GitHub clears the request when the review posts
setup post_request_user_token '- rereview_trigger: both'
seed_identity test-bot
pr_fx open; req_fx
run_rp prepare 1
printf '### Summary\nx\n### Verdict\nCOMMENT\n' > "$SANDBOX/body.md"
printf '[]' > "$SANDBOX/findings.json"
printf '{"id":85,"html_url":"https://example.test/r/85","state":"COMMENTED"}' | fx "$(POST_SLUG)"
run_rp post 1 --verdict COMMENT --body "$SANDBOX/body.md" --findings "$SANDBOX/findings.json"
assert_jq '.outcome == "posted"' 'the user token posts the review'
grep -q 'requested_reviewers' "$SANDBOX/gh.log" \
  && { printf 'FAIL %s: bot_login removed a request its own review clears\n' "$CASE"; FAILED=1; } \
  || printf 'ok   %s: no request removal when the token is bot_login\n' "$CASE"

# --- post: triage passes through, and human_review_paths forces needs-human -------
# docs/review-mechanics.md → Summary body format (`triage`)
triage_post() { # <case> <meta-json> [config line]
  setup "$1" ${3:+"$3"}
  pr_fx open '["cg-rereview"]'
  run_rp prepare 1
  printf '### Summary\nx\n\n### Verdict\nAPPROVE — ok\n' > "$SANDBOX/body.md"; printf '[]' > "$SANDBOX/findings.json"
  printf '{"id":78,"html_url":"https://example.test/r/78","state":"APPROVED"}' | fx "$(POST_SLUG)"
  printf '%s' "$2" > "$SANDBOX/meta.json"
  run_rp post 1 --verdict APPROVE --body "$SANDBOX/body.md" --findings "$SANDBOX/findings.json" --meta "$SANDBOX/meta.json"
  assert_jq '.outcome == "posted"' 'review posted'
}
triage_post post_triage_quick '{"triage":{"class":"quick-check","why":null,"verified":"tests, error paths","minutes":5}}'
assert_file_contains "$WORK/reviews/pr-1.md" '"triage":{"class":"quick-check","why":null,"verified":"tests, error paths","minutes":5}' 'the triage call reaches review-meta as written'

triage_post post_triage_forced '{"triage":{"class":"quick-check","minutes":5}}' '- human_review_paths: `docs/*`, src/al*'
assert_file_contains "$WORK/reviews/pr-1.md" '"triage":{"class":"needs-human",.*"forced":"src/alpha.ts (src/al\*)"' 'a file under human_review_paths forces needs-human and names the match'

triage_post post_triage_unknown_class '{"triage":{"class":"skip","minutes":"soon"}}'
assert_file_contains "$WORK/reviews/pr-1.md" '"triage":{"class":"needs-human","why":null,"verified":null,"minutes":null}' 'an unknown class reads as needs-human and a non-number minutes as null'

triage_post post_triage_absent '{"checks":[]}'
grep -q '"triage"' "$WORK/reviews/pr-1.md" && { printf 'FAIL %s: a review without a triage call grew one\n' "$CASE"; FAILED=1; } || printf 'ok   %s: no triage call, no triage key\n' "$CASE"

# --- verify: the self-check's mechanical lines after post / abort ----------------
setup verify_posted
run_rp verify 1
assert_jq '.outcome == "not_locked"' 'a PR this run never locked has nothing to verify'
OUT="$(env -u CLAUDE_CODE_SESSION_ID -u CG_RUN_ID GH_HOST="" WORK_DIR="$WORK" HOME="$FAKE_HOME" TMPDIR="$SANDBOX/tmp" LOG_RUN_ID="" \
       PATH="$T_DIR/bin:$PATH" bash "$RP" verify 1 2>/dev/null)"
assert_jq '.outcome == "error" and (.error | contains("no run id"))' 'without a run id verify refuses, never not_locked'
# an earlier lock cycle of this run: its collect does not count for the next one
run_rp prepare 1; run_rp step 1 "fanned out (n=2)"; run_rp collect 1; run_rp abort 1 "restart"
run_rp prepare 1
run_rp step 1 "fanned out (n=2)"
run_rp verify 1
assert_jq '.outcome == "issues" and (.checks[] | select(.check == "terminal") | .status == "fail" and (.detail | contains("fanned out")))' 'mid-pipeline: no terminal step, the last step named'
assert_jq '.checks[] | select(.check == "cleanup") | .status == "fail"' 'mid-pipeline: temp paths still there'
run_rp step 1 verified; run_rp step 1 composed
printf '### Summary\nx\n\n### Verdict\nCOMMENT — ok\n' > "$SANDBOX/body.md"; printf '[]' > "$SANDBOX/findings.json"
printf '{"id":79,"html_url":"https://example.test/r/79","state":"COMMENTED"}' | fx "$(POST_SLUG)"
run_rp post 1 --verdict COMMENT --body "$SANDBOX/body.md" --findings "$SANDBOX/findings.json"
assert_jq '.outcome == "posted"' 'posted'
# a torn line in an older events file is skipped, never the end of the read
printf '{"ts":"2000-01-01T00:00:00Z","run":"x","ms\n' > "$WORK/logs/events-2000-01-01.jsonl"
run_rp verify 1
assert_jq '[.checks[] | select(.status == "ok") | .check] == ["terminal","milestones","row","history","ledger","cleanup"]' 'a posted review passes terminal, milestones, row, history, ledger and cleanup'
assert_jq '.outcome == "issues" and ([.checks[] | select(.status == "fail") | .check] == ["skill_timing"])' 'a fan-out without collect in its own lock cycle is the one failure'
setup verify_collected
run_rp prepare 1
run_rp step 1 "fanned out (n=2)"
run_rp collect 1
assert_jq '.skills | map(.status) == ["skill-errored","skill-errored"]' 'every skill errored'
run_rp step 1 verified; run_rp step 1 composed
printf '### Summary\nx\n\n### Verdict\nCOMMENT — ok\n' > "$SANDBOX/body.md"; printf '[]' > "$SANDBOX/findings.json"
printf '{"id":80,"html_url":"https://example.test/r/80","state":"COMMENTED"}' | fx "$(POST_SLUG)"
run_rp post 1 --verdict COMMENT --body "$SANDBOX/body.md" --findings "$SANDBOX/findings.json"
run_rp verify 1
assert_jq '.outcome == "ok" and (.checks[] | select(.check == "skill_timing") | .status == "ok")' 'a collect whose skills all errored still counts as run'
setup verify_aborted
run_rp prepare 1
run_rp abort 1 "test abort"
run_rp verify 1
assert_jq '.outcome == "ok" and ([.checks[].check] == ["terminal","row","cleanup"])' 'an abort verifies the terminal step, the released lock and the cleanup'
add_row 1 "$B1_SHA" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" - awaiting_label
run_rp verify 1
assert_jq '.outcome == "issues" and (.checks[] | select(.check == "row") | .status == "fail" and (.detail | contains("not older than the lock")))' 'a row written after the lock is no released lock'

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
run_rp verify 1
assert_jq '.outcome == "ok" and (.checks[] | select(.check == "row") | .detail | contains("prior row restored"))' 'verify accepts the restored prior row of an aborted re-review'

# --- post: a marker already on GitHub → duplicate, row self-healed ----------------
setup post_duplicate
run_rp prepare 1
printf '[{"id":5,"state":"COMMENTED","user":{"login":"test-bot"},"submitted_at":"2026-09-02T10:00:00Z","body":"old <!-- cg:review headRefOid=%s -->"}]' "$B1_SHA" | fx 'api repos/acme/widgets/pulls/1/reviews?per_page=100'
printf '### Summary\nx\n' > "$SANDBOX/body.md"; printf '[]' > "$SANDBOX/findings.json"
run_rp post 1 --verdict COMMENT --body "$SANDBOX/body.md" --findings "$SANDBOX/findings.json"
assert_jq '.outcome == "duplicate"' 'duplicate detected before posting'
assert_file_contains "$WORK/REVIEWS.md" "| 1 | $B1_SHA | 2026-09-02T10:00:00Z | SEE-GITHUB | done |" 'row self-healed with the GitHub timestamp'

# --- post: the marker past the first 100 reviews is still found -------------------
setup post_duplicate_second_page
run_rp prepare 1
jq -n '[range(100) | {id: ., state: "COMMENTED", user: {login: "bob"}, submitted_at: "2026-09-01T10:00:00Z", body: "lgtm"}]' \
  | fx 'api repos/acme/widgets/pulls/1/reviews?per_page=100'
printf '[{"id":105,"state":"COMMENTED","user":{"login":"test-bot"},"submitted_at":"2026-09-02T10:00:00Z","body":"old <!-- cg:review headRefOid=%s -->"}]' "$B1_SHA" \
  | fx 'api repos/acme/widgets/pulls/1/reviews?per_page=100&page=2'
printf '### Summary\nx\n' > "$SANDBOX/body.md"; printf '[]' > "$SANDBOX/findings.json"
run_rp post 1 --verdict COMMENT --body "$SANDBOX/body.md" --findings "$SANDBOX/findings.json"
assert_jq '.outcome == "duplicate"' 'the marker on page 2 is a duplicate'
grep -q 'pulls/1/reviews -X POST' "$SANDBOX/gh.log" && { printf 'FAIL %s: a review was posted\n' "$CASE"; FAILED=1; } || printf 'ok   %s: nothing posted\n' "$CASE"

# --- a row written with padded cells is rewritten in place, never duplicated ------
setup row_padded
printf '|  1  | 0000000000000000000000000000000000000000 | %s | COMMENT | awaiting_label |\n' "$(iso_ago 7200)" >> "$WORK/REVIEWS.md"
run_rp prepare 1
assert_file_contains "$WORK/REVIEWS.md" "| 1 | $B1_SHA | .* | - | in_progress |" 'the lock replaces the padded row'
[ "$(grep -cE '^\| *1 *\|' "$WORK/REVIEWS.md")" = 1 ] && printf 'ok   %s: one row for the PR\n' "$CASE" \
  || { printf 'FAIL %s: %s rows for the PR\n' "$CASE" "$(grep -cE '^\| *1 *\|' "$WORK/REVIEWS.md")"; FAILED=1; }
run_rp abort 1 "reset"

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
fx_err "$(POST_SLUG)" 'gh: Unprocessable Entity (HTTP 422)'
fx_out "$(POST_SLUG)" '{"message":"Unprocessable Entity","errors":[{"resource":"PullRequestReviewComment","field":"line","code":"invalid","message":"line must be part of the diff"}]}'
run_rp post 1 --verdict REQUEST_CHANGES --body "$SANDBOX/body.md" --findings "$SANDBOX/findings.json" --comments "$SANDBOX/comments.json"
assert_jq '.outcome == "posted" and .review_id == 78' 'second POST succeeds'
assert_jq '.moved_to_summary | length == 1 and .[0].reason == "422 line not in diff"' 'inline comments moved after the 422'
[ "$(grep -c 'reviews -X POST' "$SANDBOX/gh.log")" -eq 2 ] && printf 'ok   %s: exactly one retry\n' "$CASE" || { printf 'FAIL %s: POST count %s\n' "$CASE" "$(grep -c 'reviews -X POST' "$SANDBOX/gh.log")"; FAILED=1; }

# --- progress channel: a GitHub App token writes a check run ------------------
setup progress_check_run '- review_progress: enabled'
seed_identity 'acme-app[bot]'
pr_fx open '["cg-rereview"]'
run_rp prepare 1
assert_call 'POST repos/acme/widgets/check-runs' 'an App token writes a check run'
grep -q "statuses/$B1_SHA" "$SANDBOX/gh.log" \
  && { printf 'FAIL %s: a commit status was written beside the check run\n' "$CASE"; FAILED=1; } \
  || printf 'ok   %s: no commit status\n' "$CASE"
jq -e -s --arg s "$B1_SHA" 'any(.[]; .name == "cg:review" and .head_sha == $s and .status == "in_progress")' \
  "$SANDBOX/gh.log.input" >/dev/null \
  && printf 'ok   %s: the run is named review_marker and in progress\n' "$CASE" \
  || { printf 'FAIL %s: check run body %s\n' "$CASE" "$(cat "$SANDBOX/gh.log.input" 2>/dev/null)"; FAILED=1; }
run_rp abort 1 "reset"

# --- a refused check run falls back to a commit status --------------------------
setup progress_fallback '- review_progress: enabled'
seed_identity 'acme-app[bot]'
fx_fail 'api -X POST repos/acme/widgets/check-runs --input -' 1
run_rp progress 1 "$B1_SHA" success "review abandoned - resumes when the PR is ready"
assert_jq '.outcome == "written"' 'the fallback write succeeds'
assert_call "statuses/$B1_SHA -f state=success" 'the status channel took over'

# --- a user token writes a commit status; an open run is updated, not doubled ---
setup progress_user_status '- review_progress: enabled'
seed_identity test-bot
run_rp progress 1 "$B1_SHA" success "review abandoned - resumes when the PR is ready"
assert_jq '.outcome == "written"' 'the status reset row is written'
assert_call "statuses/$B1_SHA -f state=success" 'a user token writes a commit status'
setup progress_patch_open_run '- review_progress: enabled' '- rereview_delta_label: cg-delta'
seed_identity 'acme-app[bot]'
printf '{"check_runs":[{"id":55,"status":"in_progress","app":{"slug":"acme-app"},"output":{"summary":"- `10:00Z` queued"}}]}' \
  | fx "api repos/acme/widgets/commits/$B1_SHA/check-runs?check_name=cg%3Areview&filter=latest"
run_rp progress 1 "$B1_SHA" success "done" "https://example.test/r/9"
assert_call 'PATCH repos/acme/widgets/check-runs/55' 'the open run is completed in place'
jq -e -s 'any(.[]; (.output.summary | startswith("- `10:00Z` queued\n- `") and endswith("Z` done — [open](https://example.test/r/9)"))
               and .conclusion == "success" and (.completed_at | length) > 0)' "$SANDBOX/gh.log.input" >/dev/null \
  && printf 'ok   %s: the summary keeps the timeline and links the review\n' "$CASE" \
  || { printf 'FAIL %s: check run body %s\n' "$CASE" "$(cat "$SANDBOX/gh.log.input" 2>/dev/null)"; FAILED=1; }
jq -e -s 'any(.[]; (.output.text | contains("`cg-rereview` to get a full review") and contains("`cg-delta` to get a review of the changes")
                and contains("`@test-bot please re-review`")))' "$SANDBOX/gh.log.input" >/dev/null \
  && printf 'ok   %s: the text says how to request the next round\n' "$CASE" \
  || { printf 'FAIL %s: check run text %s\n' "$CASE" "$(cat "$SANDBOX/gh.log.input" 2>/dev/null)"; FAILED=1; }
setup progress_other_app_run '- review_progress: enabled'
seed_identity 'acme-app[bot]'
printf '{"check_runs":[{"id":56,"status":"in_progress","app":{"slug":"other-app"}}]}' \
  | fx "api repos/acme/widgets/commits/$B1_SHA/check-runs?check_name=cg%3Areview&filter=latest"
run_rp progress 1 "$B1_SHA" pending "queued"
assert_call 'POST repos/acme/widgets/check-runs' 'a run of another App is left alone and a new run is created'
grep -q 'check-runs/56' "$SANDBOX/gh.log" \
  && { printf 'FAIL %s: the other App'"'"'s run was patched\n' "$CASE"; FAILED=1; } \
  || printf 'ok   %s: the other App'"'"'s run is not patched\n' "$CASE"
jq -e -s 'any(.[]; .status == "in_progress" and (.started_at | length) > 0 and (.output.text | contains("@acme-app please re-review") | not))' "$SANDBOX/gh.log.input" >/dev/null \
  && printf 'ok   %s: a new run starts now\n' "$CASE" \
  || { printf 'FAIL %s: check run body %s\n' "$CASE" "$(cat "$SANDBOX/gh.log.input" 2>/dev/null)"; FAILED=1; }

# --- an unreadable token login adopts no run: it creates its own ---------------
setup progress_unknown_identity '- review_progress: enabled'
printf '{"check_runs":[{"id":57,"status":"in_progress","app":{"slug":"acme-app"}}]}' \
  | fx "api repos/acme/widgets/commits/$B1_SHA/check-runs?check_name=cg%3Areview&filter=latest"
fx_fail "api -X POST repos/acme/widgets/statuses/$B1_SHA -f state=success -f context=cg:review -f description=done" 1
run_rp progress 1 "$B1_SHA" success "done"
assert_call 'POST repos/acme/widgets/check-runs' 'the refused status falls back to a run of its own'
grep -q 'check-runs/57' "$SANDBOX/gh.log" \
  && { printf 'FAIL %s: an open run was patched without a known login\n' "$CASE"; FAILED=1; } \
  || printf 'ok   %s: no open run is adopted without a known login\n' "$CASE"
# the created run names its App: the next update completes that run, not a third one
setup progress_learns_identity '- review_progress: enabled'
fx_fail "api -X POST repos/acme/widgets/statuses/$B1_SHA -f state=pending -f context=cg:review -f description=queued" 1
fx_fail "api -X POST repos/acme/widgets/statuses/$B1_SHA -f state=success -f context=cg:review -f description=done" 1
printf '{"id":58,"status":"in_progress","app":{"slug":"acme-app"}}' | fx 'api -X POST repos/acme/widgets/check-runs --input -'
run_rp progress 1 "$B1_SHA" pending "queued"
jq -e '.login == "acme-app[bot]" and .kind == "app"' "$WORK/GITHUB.json" >/dev/null 2>&1 \
  && printf 'ok   %s: the created run names the token login\n' "$CASE" \
  || { printf 'FAIL %s: GITHUB.json %s\n' "$CASE" "$(cat "$WORK/GITHUB.json" 2>/dev/null)"; FAILED=1; }
printf '{"check_runs":[{"id":58,"status":"in_progress","app":{"slug":"acme-app"}}]}' \
  | fx "api repos/acme/widgets/commits/$B1_SHA/check-runs?check_name=cg%3Areview&filter=latest"
run_rp progress 1 "$B1_SHA" success "done"
assert_call 'PATCH repos/acme/widgets/check-runs/58' 'the next update completes the run it created'

# --- review_progress off: the subcommand writes nothing -------------------------
setup progress_disabled
run_rp progress 1 "$B1_SHA" success "x"
assert_jq '.outcome == "disabled"' 'nothing written without review_progress'

# --- post: closed at post time — discard without criticals, issue path with ------
setup post_closed
run_rp prepare 1
pr_fx closed
printf '### Summary\nx\n' > "$SANDBOX/body.md"
printf '[{"status":"new","severity":"warning","file":"src/alpha.ts","line":6,"inline":false,"summary":"w","fix":"f"}]' > "$SANDBOX/findings.json"
run_rp post 1 --verdict COMMENT --body "$SANDBOX/body.md" --findings "$SANDBOX/findings.json"
assert_jq '.outcome == "closed_discarded" and .scope == "critical"' 'no criticals → discarded'
grep -qE '^\| *1 \|' "$WORK/REVIEWS.md" && { printf 'FAIL %s: lock left after closed discard\n' "$CASE"; FAILED=1; } || printf 'ok   %s: lock released\n' "$CASE"
pr_fx open
run_rp prepare 1
pr_fx closed
printf '[{"status":"new","severity":"critical","file":"src/alpha.ts","line":6,"inline":false,"summary":"c","fix":"f"}]' > "$SANDBOX/findings.json"
run_rp post 1 --verdict REQUEST_CHANGES --body "$SANDBOX/body.md" --findings "$SANDBOX/findings.json"
assert_jq '.outcome == "closed_findings" and .scope == "critical" and (.findings | length == 1) and .existing_issue == null and (.issue_marker | contains(":issue headRefOid=")) and (.issue_title | contains("closed PR #1"))' 'criticals reported for the issue'
run_rp post 1 --verdict REQUEST_CHANGES --body "$SANDBOX/body.md" --findings "$SANDBOX/findings.json" --closed-issue 9
assert_jq '.outcome == "closed_filed" and .issue == 9' 'finalized against the issue'
assert_file_contains "$WORK/REVIEWS.md" "| 1 | $B1_SHA | .* | REQUEST_CHANGES | done |" 'done row after the issue'
assert_file_contains "$WORK/reviews/pr-1.md" '_Delivered as issue #9 — PR closed before posting._' 'history note'

# --- post: closed, the issue an alias filed earlier is found -------------------
setup post_closed_alias
seed_identity 'acme-app[bot]'
run_rp prepare 1
pr_fx closed
printf '### Summary\nx\n' > "$SANDBOX/body.md"
printf '[{"status":"new","severity":"critical","file":"src/alpha.ts","line":6,"inline":false,"summary":"c","fix":"f"}]' > "$SANDBOX/findings.json"
jq -nc --arg m "<!-- cg:review:issue headRefOid=$B1_SHA -->" '[{number:12, body:("x\n" + $m)}]' \
  | fx 'api --paginate repos/acme/widgets/issues?state=all&per_page=100&creator=acme-app%5Bbot%5D'
run_rp post 1 --verdict REQUEST_CHANGES --body "$SANDBOX/body.md" --findings "$SANDBOX/findings.json"
assert_jq '.outcome == "closed_findings" and .existing_issue == 12' 'an issue the alias created dedups the next one'

# --- rapid: urgent phase 1 -------------------------------------------------------
setup rapid_case '- urgent_label: urgent'
pr_fx open '["urgent"]'
run_rp prepare 1
assert_jq '.urgent == true' 'urgent flagged'
printf '### Critical findings\n- 🔴 **Critical:** q (`src/alpha.ts:6`)\n' > "$SANDBOX/rapid.md"
run_rp rapid 1 --body "$SANDBOX/rapid.md"
assert_jq '.outcome == "error"' 'a rapid post without a verdict is refused'
# a rapid approval of an earlier HEAD stands; a human approval is never touched
printf '[{"id":60,"state":"APPROVED","user":{"login":"test-bot"},"body":"r <!-- cg:review:rapid headRefOid=0000000000000000000000000000000000000000 -->"},{"id":61,"state":"APPROVED","user":{"login":"bob"},"body":"lgtm"}]' | fx 'api repos/acme/widgets/pulls/1/reviews?per_page=100'
printf '{"id":70,"html_url":"https://example.test/r/70","state":"CHANGES_REQUESTED"}' | fx "$(POST_SLUG)"
run_rp rapid 1 --verdict REQUEST_CHANGES --body "$SANDBOX/rapid.md"
assert_jq '.outcome == "posted" and .phase == "rapid" and .verdict == "REQUEST_CHANGES" and .review_id == 70' 'rapid preliminary posted'
jq -se 'last | .event == "REQUEST_CHANGES"' "$SANDBOX/gh.log.input" >/dev/null \
  && printf 'ok   %s: the rapid payload carries its verdict\n' "$CASE" || { printf 'FAIL %s: rapid payload event wrong\n' "$CASE"; FAILED=1; }
assert_jq '.dismissed_approval == 60' 'a critical at the new HEAD revokes the earlier rapid approval'
assert_call 'reviews/60/dismissals -X PUT' 'dismissal call issued'
grep -q 'reviews/61/dismissals' "$SANDBOX/gh.log" && { printf 'FAIL %s: a human approval was dismissed\n' "$CASE"; FAILED=1; } || printf 'ok   %s: a human approval stays\n' "$CASE"
assert_file_contains "$WORK/REVIEWS.md" "| 1 | $B1_SHA | .* | RAPID | in_progress |" 'RAPID lock row'
assert_event 'rapid posted' 'rapid event'
printf '[{"id":70,"state":"CHANGES_REQUESTED","user":{"login":"test-bot"},"body":"r <!-- cg:review:rapid headRefOid=%s -->"}]' "$B1_SHA" | fx 'api repos/acme/widgets/pulls/1/reviews?per_page=100'
run_rp rapid 1 --verdict REQUEST_CHANGES --body "$SANDBOX/rapid.md"
assert_jq '.outcome == "already_posted"' 'rapid dedup by its own marker'
run_rp abort 1 "reset"

# --- rapid on a pull request this account opened: a COMMENT ----------------------
setup rapid_own_pr '- urgent_label: urgent'
seed_identity 'acme-app[bot]'
pr_fx open '["urgent"]'; own_pr_fx
run_rp prepare 1
printf '### Critical findings\nNone.\n' > "$SANDBOX/rapid.md"
printf '{"id":71,"html_url":"https://example.test/r/71","state":"COMMENTED"}' | fx "$(POST_SLUG)"
run_rp rapid 1 --verdict APPROVE --body "$SANDBOX/rapid.md"
assert_jq '.outcome == "posted" and .verdict == "APPROVE" and .event == "COMMENT"' 'a rapid approval of the own PR is a comment'
jq -se 'last | .event == "COMMENT" and (.body | startswith("> **Verdict: APPROVE.**"))' "$SANDBOX/gh.log.input" >/dev/null \
  && printf 'ok   %s: the rapid body names the verdict\n' "$CASE" || { printf 'FAIL %s: rapid payload %s\n' "$CASE" "$(tail -1 "$SANDBOX/gh.log.input")"; FAILED=1; }
run_rp abort 1 "reset"
# without an identity cache, the refusal in the error body turns the retry into a COMMENT
setup rapid_own_pr_422 '- urgent_label: urgent'
pr_fx open '["urgent"]'; own_pr_fx
run_rp prepare 1
printf '### Critical findings\nNone.\n' > "$SANDBOX/rapid.md"
printf '{"id":73,"html_url":"https://example.test/r/73","state":"COMMENTED"}' | fx "$(POST_SLUG)"
own_pr_422_fx
run_rp rapid 1 --verdict APPROVE --body "$SANDBOX/rapid.md"
assert_jq '.outcome == "posted" and .verdict == "APPROVE" and .event == "COMMENT"' 'the refused rapid approval is retried as a comment'
run_rp abort 1 "reset"

# --- rapid approval, then a full review below APPROVE revokes it -------------------
setup rapid_approve '- urgent_label: urgent'
pr_fx open '["urgent"]'
run_rp prepare 1
printf '### Critical findings\n_None found at rapid-review depth._\n' > "$SANDBOX/rapid.md"
printf '{"id":72,"html_url":"https://example.test/r/72","state":"APPROVED"}' | fx "$(POST_SLUG)"
run_rp rapid 1 --verdict APPROVE --body "$SANDBOX/rapid.md"
assert_jq '.outcome == "posted" and .verdict == "APPROVE" and .dismissed_approval == null' 'rapid approval posted'
jq -se 'last | .event == "APPROVE"' "$SANDBOX/gh.log.input" >/dev/null \
  && printf 'ok   %s: the rapid payload approves\n' "$CASE" || { printf 'FAIL %s: rapid payload event wrong\n' "$CASE"; FAILED=1; }
grep -q 'dismissals' "$SANDBOX/gh.log" && { printf 'FAIL %s: a rapid approval dismissed something\n' "$CASE"; FAILED=1; } || printf 'ok   %s: a rapid approval dismisses nothing\n' "$CASE"
printf '[{"id":72,"state":"APPROVED","user":{"login":"test-bot"},"body":"r <!-- cg:review:rapid headRefOid=%s -->"}]' "$B1_SHA" | fx 'api repos/acme/widgets/pulls/1/reviews?per_page=100'
printf '### Summary\nx\n' > "$SANDBOX/body.md"
printf '[{"status":"new","severity":"warning","file":"src/alpha.ts","line":6,"inline":false,"summary":"w","fix":"f"}]' > "$SANDBOX/findings.json"
printf '{"id":73,"html_url":"https://example.test/r/73","state":"COMMENTED"}' | fx "$(POST_SLUG)"
run_rp post 1 --verdict COMMENT --body "$SANDBOX/body.md" --findings "$SANDBOX/findings.json"
assert_jq '.outcome == "posted" and .dismissed_approval == 72' 'a first review below APPROVE revokes the rapid approval'
assert_call 'reviews/72/dismissals -X PUT' 'dismissal call issued'

# --- merged on a rapid approval: warnings are filed with the criticals ------------
setup rapid_merged '- urgent_label: urgent'
pr_fx open '["urgent"]'
run_rp prepare 1
printf '[{"id":72,"state":"APPROVED","user":{"login":"test-bot"},"body":"r <!-- cg:review:rapid headRefOid=%s -->"}]' "$B1_SHA" | fx 'api repos/acme/widgets/pulls/1/reviews?per_page=100'
pr_fx merged '["urgent"]'
printf '### Summary\nx\n' > "$SANDBOX/body.md"
printf '[{"status":"new","severity":"warning","file":"src/alpha.ts","line":6,"inline":false,"summary":"w","fix":"f"},{"status":"new","severity":"suggestion","file":"src/alpha.ts","line":7,"inline":false,"summary":"s","fix":"f"}]' > "$SANDBOX/findings.json"
run_rp post 1 --verdict COMMENT --body "$SANDBOX/body.md" --findings "$SANDBOX/findings.json"
assert_jq '.outcome == "closed_findings" and .scope == "blocking" and (.findings | map(.severity) == ["warning"]) and (.issue_title | contains("rapid approval"))' 'the warning is filed, the suggestion is not'
run_rp post 1 --verdict COMMENT --body "$SANDBOX/body.md" --findings "$SANDBOX/findings.json" --closed-issue 12
assert_jq '.outcome == "closed_filed" and .issue == 12' 'finalized against the issue'

# --- closed without a merge, or a rapid approval of an older HEAD: criticals only ---
setup rapid_closed '- urgent_label: urgent'
pr_fx open '["urgent"]'
run_rp prepare 1
printf '[{"id":72,"state":"APPROVED","user":{"login":"test-bot"},"body":"r <!-- cg:review:rapid headRefOid=%s -->"}]' "$B1_SHA" | fx 'api repos/acme/widgets/pulls/1/reviews?per_page=100'
pr_fx closed '["urgent"]'
printf '### Summary\nx\n' > "$SANDBOX/body.md"
printf '[{"status":"new","severity":"warning","file":"src/alpha.ts","line":6,"inline":false,"summary":"w","fix":"f"}]' > "$SANDBOX/findings.json"
run_rp post 1 --verdict COMMENT --body "$SANDBOX/body.md" --findings "$SANDBOX/findings.json"
assert_jq '.outcome == "closed_discarded" and .scope == "critical"' 'a PR closed without a merge files no warning'
pr_fx open '["urgent"]'
run_rp prepare 1
printf '[{"id":71,"state":"APPROVED","user":{"login":"test-bot"},"body":"r <!-- cg:review:rapid headRefOid=0000000000000000000000000000000000000000 -->"}]' | fx 'api repos/acme/widgets/pulls/1/reviews?per_page=100'
pr_fx merged '["urgent"]'
run_rp post 1 --verdict COMMENT --body "$SANDBOX/body.md" --findings "$SANDBOX/findings.json"
assert_jq '.outcome == "closed_discarded" and .scope == "critical"' 'a rapid approval of an older HEAD files no warning'

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
run_rp verify 1
assert_jq '[.checks[] | select(.check == "history" or .check == "ledger") | .status] == ["ok","ok"]' 'verify finds this cycle'"'"'s history section and ledger row'
# only the prior review at this SHA left: it predates the lock
printf '# PR #1: alpha PR\n\n## Review at %s — 2026-09-02T10:00:00Z — COMMENT\n\nx\n' "${B1_SHA:0:7}" > "$WORK/reviews/pr-1.md"
printf '{"src":"ledger","pr":1,"ts":"2026-09-02T10:00:00Z","sha":"%s"}\n' "${B1_SHA:0:7}" > "$WORK/REVIEW-LEDGER.jsonl"
run_rp verify 1
assert_jq '[.checks[] | select(.check == "history" or .check == "ledger") | .status] == ["fail","fail"]' 'the prior review at the same SHA does not stand in for this cycle'

# --- takeover of a dead run's lock: no usable prior, abort deletes the row ---------
setup takeover_case
printf '# PR #1: alpha PR\n\n## Review at aaaaaaa — %s — COMMENT\n\nx\n' "$(iso_ago 90000)" > "$WORK/reviews/pr-1.md"
add_row 1 "$B1_SHA" "$(iso_ago 7200)" - in_progress
pr_fx open '["cg-rereview"]'
run_rp prepare 1
assert_jq '.outcome == "ready" and .kind == "re-review" and .prior == null' 'a taken-over lock carries no prior'
run_rp abort 1 "dead run"
grep -qE '^\| *1 \|' "$WORK/REVIEWS.md" && { printf 'FAIL %s: row kept after abort without a prior\n' "$CASE"; FAILED=1; } || printf 'ok   %s: row deleted for self-heal\n' "$CASE"

# --- a history file without a posted review is a first review ----------------------
# The urgent alert writes its marker before the first review exists (docs/review.md
# → Urgent PRs — rapid-first delivery); the re-review gate would skip it forever.
setup urgent_announced_first '- urgent_label: hotfix' '- slack_notifications: enabled'
pr_fx open '["hotfix"]'
printf '# PR #1: alpha PR\n<!-- urgent-announced: 2026-09-28T10:00:00Z -->\n' > "$WORK/reviews/pr-1.md"
run_rp prepare 1
assert_jq '.outcome == "ready" and .kind == "first" and .full == true and .urgent == true' 'an alert-only history file prepares a first review'
printf '### Summary\nx\n' > "$SANDBOX/body.md"; printf '[]' > "$SANDBOX/findings.json"
printf '{"id":82,"html_url":"https://example.test/r/82","state":"COMMENTED"}' | fx "$(POST_SLUG)"
run_rp post 1 --verdict COMMENT --body "$SANDBOX/body.md" --findings "$SANDBOX/findings.json"
assert_jq '.outcome == "posted"' 'the first review posts'
assert_file_contains "$WORK/reviews/pr-1.md" '<!-- urgent-announced: 2026-09-28T10:00:00Z -->' 'the alert marker survives the post'
assert_file_contains "$WORK/REVIEW-LEDGER.jsonl" '"kind":"first"' 'the ledger records a first review'
run_rp prepare 1
assert_jq '.outcome == "skip" and .reason == "re-review trigger withdrawn"' 'after the post the file holds a review: a re-review needs its trigger'

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

# --- a GitHub App bot_login that another agent shares: only the marked approval goes
setup post_dismiss_shared_app
sed -i.bak 's/^- bot_login: test-bot$/- bot_login: acme-app[bot]/' "$WORK/CONFIG.md"
printf '# PR #1: alpha PR\n\n## Review at aaaaaaa — %s — APPROVE\n\nx\n' "$(iso_ago 7200)" > "$WORK/reviews/pr-1.md"
add_row 1 "0000000000000000000000000000000000000000" "$(iso_ago 7200)" APPROVE awaiting_label
pr_fx open '["cg-rereview"]'
run_rp prepare 1
printf '[{"id":5,"state":"APPROVED","user":{"login":"acme-app[bot]"},"body":"ok <!-- cg:review headRefOid=0000000000000000000000000000000000000000 -->"},{"id":6,"state":"APPROVED","user":{"login":"acme-app[bot]"},"body":"ok <!-- other:review headRefOid=0000000000000000000000000000000000000000 -->"}]' | fx 'api repos/acme/widgets/pulls/1/reviews?per_page=100'
printf '### Summary\nx\n' > "$SANDBOX/body.md"; printf '[]' > "$SANDBOX/findings.json"
printf '{"id":79,"html_url":"https://example.test/r/79","state":"COMMENTED"}' | fx "$(POST_SLUG)"
run_rp post 1 --verdict COMMENT --body "$SANDBOX/body.md" --findings "$SANDBOX/findings.json"
assert_jq '.outcome == "posted" and .dismissed_approval == 5' 'the approval with this marker is dismissed'
grep -q 'reviews/6/dismissals' "$SANDBOX/gh.log" \
  && { printf 'FAIL %s: the approval of another agent on the same App login was dismissed\n' "$CASE"; FAILED=1; } \
  || printf 'ok   %s: the approval of another agent on the same App login stays\n' "$CASE"

# --- carried first review: a HEAD move keeps the work, not the narrative ---------
setup carry_write
pr_fx open '[]'
run_rp prepare 1
assert_jq '.carry == null' 'a first review with no carry says so'
printf '### Summary\nx\n' > "$SANDBOX/body.md"
printf '[{"status":"new","severity":"critical","file":"src/alpha.ts","line":6,"inline":true,"summary":"unbounded query","fix":"add a limit"},{"status":"new","severity":"warning","file":"src/gamma.ts","line":1,"inline":false,"summary":"dead export","fix":"remove"}]' > "$SANDBOX/findings.json"
# HEAD moved between the lock and the post
pr_fx open '[]' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
run_rp post 1 --verdict COMMENT --body "$SANDBOX/body.md" --findings "$SANDBOX/findings.json"
assert_jq '.outcome == "aborted" and (.reason | contains("HEAD moved")) and .carried == true' 'the abort reports the work as carried'
C="$WORK/reviews/pr-1.carry.json"
jq -e --arg s "$B1_SHA" '.sha == $s and .hops == 1 and (.findings | length) == 2' "$C" >/dev/null \
  && printf 'ok   %s: the carry holds the reviewed SHA and its findings\n' "$CASE" \
  || { printf 'FAIL %s: carry wrong: %s\n' "$CASE" "$(cat "$C" 2>/dev/null)"; FAILED=1; }
[ -f "$WORK/reviews/pr-1.md" ] \
  && { printf 'FAIL %s: unpublished work reached the published history\n' "$CASE"; FAILED=1; } \
  || printf 'ok   %s: the published history stays empty\n' "$CASE"
grep -qE '^\| *1 *\|' "$WORK/REVIEWS.md" \
  && { printf 'FAIL %s: the lock row survived the abort\n' "$CASE"; FAILED=1; } \
  || printf 'ok   %s: the first-review lock row is released\n' "$CASE"

# --- the next review picks the carry up as its range -----------------------------
setup carry_use
cat > "$WORK/reviews/pr-1.carry.json" <<EOF
{"sha":"0000000000000000000000000000000000000000","ts":"$(iso_ago 3600)","hops":1,
 "findings":[{"status":"new","severity":"critical","file":"src/alpha.ts","line":6,"inline":true,"summary":"unbounded query","fix":"add a limit"}]}
EOF
jq -n '{status:"ahead", files:[{filename:"src/gamma.ts", patch:"@@ -0,0 +1 @@\n+x"}]}' \
  | fx 'api repos/acme/widgets/compare/0000000000000000000000000000000000000000...'"$B1_SHA"
run_rp prepare 1
assert_jq '.kind == "first"' 'a carry never makes the review a re-review'
assert_jq '.carry.reachable == true and .carry.hops == 1 and (.carry.files == ["src/gamma.ts"])' 'the carry resolves to the range since its SHA'
assert_jq '(.carry.findings | length) == 1 and .carry.findings[0].summary == "unbounded query"' 'the carried findings come with it'
assert_jq '.skills["typescript-engineering"].files == ["src/gamma.ts"]' 'extension skills route from the carry range'
assert_jq '.skills["doc-drift"].status == "run"' 'an always skill still runs over the whole clone'
assert_file_contains "$(PR_DIR).ctx/briefs/doc-drift.md" '^- src/gamma.ts$' 'an always skill gets the carry range as its focus'
assert_file_lacks "$(PR_DIR).ctx/briefs/doc-drift.md" '^- src/alpha.ts$' 'the focus holds the carry range only'
assert_jq '.prior_findings == []' 'the carry is not a published prior'
run_rp abort 1 "reset"

# --- an unusable carry is dropped, never silently trusted ------------------------
setup carry_diverged
cat > "$WORK/reviews/pr-1.carry.json" <<EOF
{"sha":"0000000000000000000000000000000000000000","ts":"$(iso_ago 3600)","hops":1,"kind":"first",
 "findings":[{"status":"new","severity":"warning","file":"src/alpha.ts","line":6,"inline":true,"summary":"unbounded query","fix":"add a limit"}]}
EOF
jq -n '{status:"diverged", files:[]}' \
  | fx 'api repos/acme/widgets/compare/0000000000000000000000000000000000000000...'"$B1_SHA"
run_rp prepare 1
assert_jq '.carry == null' 'a range that is not ahead drops the carry'
[ -f "$WORK/reviews/pr-1.carry.json" ] \
  && { printf 'FAIL %s: the unusable carry file was kept\n' "$CASE"; FAILED=1; } \
  || printf 'ok   %s: the unusable carry file is deleted\n' "$CASE"
run_rp abort 1 "reset"

setup carry_hop_limit
cat > "$WORK/reviews/pr-1.carry.json" <<EOF
{"sha":"0000000000000000000000000000000000000000","ts":"$(iso_ago 3600)","hops":4,"findings":[]}
EOF
run_rp prepare 1
assert_jq '.carry == null' 'a carry past the hop limit is not used'
[ -f "$WORK/reviews/pr-1.carry.json" ] \
  && { printf 'FAIL %s: the over-hop carry file was kept\n' "$CASE"; FAILED=1; } \
  || printf 'ok   %s: the over-hop carry file is deleted\n' "$CASE"
run_rp abort 1 "reset"

# --- an ahead range that changed nothing keeps the carry -------------------------
setup carry_empty_range
cat > "$WORK/reviews/pr-1.carry.json" <<EOF
{"sha":"0000000000000000000000000000000000000000","ts":"$(iso_ago 3600)","hops":1,
 "findings":[{"status":"new","severity":"critical","file":"src/alpha.ts","line":6,"inline":true,"summary":"unbounded query","fix":"add a limit"}]}
EOF
jq -n '{status:"ahead", files:[]}' \
  | fx 'api repos/acme/widgets/compare/0000000000000000000000000000000000000000...'"$B1_SHA"
run_rp prepare 1
assert_jq '.carry.reachable == true and (.carry.files == []) and (.carry.findings | length) == 1' \
  'a commit and its revert leave the carried findings current, with an empty range'
assert_jq '.skills["typescript-engineering"].files == ["src/alpha.ts","src/gamma.ts"]' \
  'an empty range routes the skills over the whole PR, not over nothing'
run_rp abort 1 "reset"

# --- the PR closing mid-review clears the carry ----------------------------------
setup carry_cleared_on_close
cat > "$WORK/reviews/pr-1.carry.json" <<EOF
{"sha":"0000000000000000000000000000000000000000","ts":"$(iso_ago 3600)","hops":1,"findings":[]}
EOF
jq -n '{status:"ahead", files:[{filename:"src/gamma.ts", patch:"@@ -0,0 +1 @@\n+x"}]}' \
  | fx 'api repos/acme/widgets/compare/0000000000000000000000000000000000000000...'"$B1_SHA"
run_rp prepare 1
printf '### Summary\nx\n' > "$SANDBOX/body.md"; printf '[]' > "$SANDBOX/findings.json"
pr_fx closed '[]'
run_rp post 1 --verdict COMMENT --body "$SANDBOX/body.md" --findings "$SANDBOX/findings.json"
assert_jq '.outcome == "closed_discarded"' 'a closed PR posts no review'
[ -f "$WORK/reviews/pr-1.carry.json" ] \
  && { printf 'FAIL %s: the carry outlived the PR\n' "$CASE"; FAILED=1; } \
  || printf 'ok   %s: a closed PR clears the carry\n' "$CASE"

# --- a published review supersedes the carry -------------------------------------
setup carry_cleared_on_post
cat > "$WORK/reviews/pr-1.carry.json" <<EOF
{"sha":"0000000000000000000000000000000000000000","ts":"$(iso_ago 3600)","hops":1,"findings":[]}
EOF
jq -n '{status:"ahead", files:[{filename:"src/gamma.ts", patch:"@@ -0,0 +1 @@\n+x"}]}' \
  | fx 'api repos/acme/widgets/compare/0000000000000000000000000000000000000000...'"$B1_SHA"
run_rp prepare 1
printf '### Summary\nx\n' > "$SANDBOX/body.md"; printf '[]' > "$SANDBOX/findings.json"
printf '{"id":81,"html_url":"https://example.test/r/81","state":"COMMENTED"}' | fx "$(POST_SLUG)"
run_rp post 1 --verdict COMMENT --body "$SANDBOX/body.md" --findings "$SANDBOX/findings.json"
assert_jq '.outcome == "posted"' 'the review posts'
[ -f "$WORK/reviews/pr-1.carry.json" ] \
  && { printf 'FAIL %s: the carry outlived the review it fed\n' "$CASE"; FAILED=1; } \
  || printf 'ok   %s: publishing clears the carry\n' "$CASE"


# --- the mid-review phase guards -------------------------------------------------
# docs/review.md → Guarding a running review
setup guard_clean
run_rp prepare 1
run_rp guard 1
assert_jq '.outcome == "ok" and .phase == "guard"' 'an unmoved HEAD lets the review run on'
[ -d "$(PR_DIR)" ] || { printf 'FAIL %s: the clone was cleaned up by a passing guard\n' "$CASE"; FAILED=1; }
run_rp collect 1
assert_jq '.outcome == "ok"' 'collect guards without stopping an unmoved review'
run_rp abort 1 "reset"

setup guard_moved
run_rp prepare 1
pr_fx open '[]' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
run_rp guard 1
assert_jq '.outcome == "head_moved" and .phase == "guard" and .restart == true and .carried == false' \
  'a commit mid-review stops the run and offers the restart'
assert_jq '.reason | contains("HEAD moved")' 'the reason names the move'
grep -qE '^\| *1 *\|' "$WORK/REVIEWS.md" \
  && { printf 'FAIL %s: the lock row survived the guard\n' "$CASE"; FAILED=1; } \
  || printf 'ok   %s: the guard releases the lock\n' "$CASE"
[ -d "$(PR_DIR)" ] \
  && { printf 'FAIL %s: the clone survived the guard\n' "$CASE"; FAILED=1; } \
  || printf 'ok   %s: the guard deletes the clone\n' "$CASE"
jq -e '.hops == 1 and .kind == "first" and (.findings | length) == 0' "$WORK/reviews/pr-1.carry.json" >/dev/null \
  && printf 'ok   %s: a move before the first finding carries the counters alone\n' "$CASE" \
  || { printf 'FAIL %s: bookkeeping carry wrong: %s\n' "$CASE" "$(cat "$WORK/reviews/pr-1.carry.json" 2>/dev/null)"; FAILED=1; }

# the same run gets one restart, not an endless chase
jq -n '{status:"ahead", files:[{filename:"src/gamma.ts", patch:"@@ -0,0 +1 @@\n+x"}]}' \
  | fx "api repos/acme/widgets/compare/$B1_SHA...aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
run_rp prepare 1
pr_fx open '[]' "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
run_rp guard 1
assert_jq '.outcome == "head_moved" and .restart == false' 'the second move in one run spends no restart'
assert_jq '.next | contains("next heartbeat")' 'it hands the PR to the heartbeat'

# `delta` holds a complete set, so its guard carries the findings
setup guard_delta_carries
printf '# PR #1: alpha PR\n\n## Review at aaaaaaa — %s — COMMENT\n\nx\n' "$(iso_ago 7200)" > "$WORK/reviews/pr-1.md"
add_row 1 "0000000000000000000000000000000000000000" "$(iso_ago 7200)" COMMENT awaiting_label
pr_fx open '["cg-rereview"]'
run_rp prepare 1
printf '[{"status":"new","severity":"critical","file":"src/alpha.ts","line":6,"inline":true,"summary":"unbounded query","fix":"add a limit"}]' > "$SANDBOX/findings.json"
pr_fx open '["cg-rereview"]' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
run_rp delta 1 "$SANDBOX/findings.json"
assert_jq '.outcome == "head_moved" and .phase == "delta" and .carried == true' 'the delta guard carries the round it was handed'
jq -e '(.findings | length) == 1 and .findings[0].summary == "unbounded query" and .kind == "re-review"' "$WORK/reviews/pr-1.carry.json" >/dev/null \
  && printf 'ok   %s: the carry holds them\n' "$CASE" \
  || { printf 'FAIL %s: carry wrong: %s\n' "$CASE" "$(cat "$WORK/reviews/pr-1.carry.json" 2>/dev/null)"; FAILED=1; }

# collect and compose-brief guard on their own
setup guard_collect
run_rp prepare 1
pr_fx open '[]' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
run_rp collect 1
assert_jq '.outcome == "head_moved" and .phase == "collect"' 'collect stops a review whose HEAD moved'

setup guard_compose
run_rp prepare 1
pr_fx open '[]' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
run_rp compose-brief 1
assert_jq '.outcome == "head_moved" and .phase == "compose"' 'compose-brief stops a review whose HEAD moved'

# --- a bookkeeping-only carry is kept, and is never a review scope ---------------
setup carry_bookkeeping
cat > "$WORK/reviews/pr-1.carry.json" <<EOF
{"sha":"0000000000000000000000000000000000000000","ts":"$(iso_ago 3600)","hops":1,"kind":"first","run":"other","findings":[]}
EOF
run_rp prepare 1
assert_jq '.carry == null' 'a carry with no findings is no starting point'
assert_jq '.skills["typescript-engineering"].files == ["src/alpha.ts","src/gamma.ts"]' \
  'the review runs at full scope, not over a phantom range'
[ -f "$WORK/reviews/pr-1.carry.json" ] \
  || { printf 'FAIL %s: the hop counter was thrown away\n' "$CASE"; FAILED=1; }
run_rp abort 1 "reset"

# --- a carry never crosses kinds --------------------------------------------------
setup carry_kind_mismatch
printf '# PR #1: alpha PR\n\n## Review at aaaaaaa — %s — COMMENT\n\nx\n' "$(iso_ago 7200)" > "$WORK/reviews/pr-1.md"
add_row 1 "0000000000000000000000000000000000000000" "$(iso_ago 7200)" COMMENT awaiting_label
cat > "$WORK/reviews/pr-1.carry.json" <<EOF
{"sha":"0000000000000000000000000000000000000000","ts":"$(iso_ago 3600)","hops":1,"kind":"first",
 "findings":[{"status":"new","severity":"warning","file":"src/alpha.ts","line":6,"inline":true,"summary":"x","fix":"y"}]}
EOF
pr_fx open '["cg-rereview"]'
run_rp prepare 1
assert_jq '.kind == "re-review" and .carry == null' "a first review's carry is not a re-review's starting point"
[ -f "$WORK/reviews/pr-1.carry.json" ] \
  && { printf 'FAIL %s: the cross-kind carry was kept\n' "$CASE"; FAILED=1; } \
  || printf 'ok   %s: the cross-kind carry is dropped\n' "$CASE"
run_rp abort 1 "reset"

# --- a re-review carries its work too ---------------------------------------------
setup carry_rereview
printf '# PR #1: alpha PR\n\n## Review at aaaaaaa — %s — COMMENT\n\nx\n' "$(iso_ago 7200)" > "$WORK/reviews/pr-1.md"
add_row 1 "0000000000000000000000000000000000000000" "$(iso_ago 7200)" COMMENT awaiting_label
pr_fx open '["cg-rereview"]'
run_rp prepare 1
printf '### Summary\nx\n' > "$SANDBOX/body.md"
printf '[{"status":"new","severity":"warning","file":"src/gamma.ts","line":1,"inline":false,"summary":"dead export","fix":"remove"}]' > "$SANDBOX/findings.json"
pr_fx open '["cg-rereview"]' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
run_rp post 1 --verdict COMMENT --body "$SANDBOX/body.md" --findings "$SANDBOX/findings.json"
assert_jq '.outcome == "aborted" and .carried == true' "a re-review's work is carried, not thrown away"
jq -e --arg s "$B1_SHA" '.sha == $s and .kind == "re-review" and (.findings | length) == 1' "$WORK/reviews/pr-1.carry.json" >/dev/null \
  && printf 'ok   %s: the carry records the kind that wrote it\n' "$CASE" \
  || { printf 'FAIL %s: re-review carry wrong: %s\n' "$CASE" "$(cat "$WORK/reviews/pr-1.carry.json" 2>/dev/null)"; FAILED=1; }
assert_file_contains "$WORK/REVIEWS.md" '| 1 | 0000000000000000000000000000000000000000 | .* | COMMENT | awaiting_label |' 'the prior row is restored'

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
assert_out_contains 'cd "\$HOME" && bash' 'post runs from HOME, never from the directory it deletes'
assert_out_contains 'review-pr-1.ctx/body.md' 'the payload files are named by absolute path in the context directory'
assert_out_contains 'never by the exit status' 'post is judged by its outcome'
assert_out_contains 'post [0-9]* .* --findings [^ ]*review-pr-1.ctx/findings.annotated.json' 'a re-review posts the file delta annotated'
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
assert_out_contains 'post [0-9]* .* --findings [^ ]*review-pr-1.ctx/findings.json' 'a first review posts its own findings list'
assert_out_contains 'none' 'no overrides and no memory read as none'
assert_out_contains 'sections that post: Documentation Check, TypeScript Review' 'the section list names what will post'
assert_out_absent 'triage is forced' 'no human_review_paths, no forced triage'
run_rp abort 1 "reset"

# a changed file under human_review_paths: the brief says the triage is forced
setup compose_brief_forced '- human_review_paths: `docs/*`, src/al*'
run_rp prepare 1
run_rp compose-brief 1
assert_out_contains 'triage is forced to `needs-human`: `src/alpha.ts (src/al\*)`' 'the brief names the file that forces needs-human'
run_rp abort 1 "reset"

# a file moved out of a human_review_paths glob still forces needs-human
setup compose_brief_forced_rename '- human_review_paths: src/lo*'
seq 1 20 > "$FX/src/long.ts"
git -C "$FX" add -A && git -C "$FX" "${GIT_ID[@]}" commit -qm more-base
git -C "$FX" checkout -q b1 && git -C "$FX" "${GIT_ID[@]}" merge -q --no-edit main
git -C "$FX" mv src/long.ts src/moved.ts && git -C "$FX" "${GIT_ID[@]}" commit -qm move
B1_SHA="$(git -C "$FX" rev-parse HEAD)"
git -C "$FX" diff -M main...b1 > "$SANDBOX/diff.txt"
git -C "$FX" checkout -q main
pr_fx open '[]' "$B1_SHA"; ctx_fx
run_rp prepare 1
run_rp compose-brief 1
assert_out_contains 'triage is forced to `needs-human`: `src/long.ts (src/lo\*)`' 'a pure rename out of the glob still forces needs-human'
run_rp abort 1 "reset"

# --- compose-brief: the conversation that moved since the lock --------------------
# docs/review.md → Guarding a running review
setup compose_refresh
run_rp prepare 1
# same HEAD, edited description, one comment that landed after the lock
jq -n --arg sha "$B1_SHA" '{state:"open", merged:false, draft:false, title:"alpha PR", user:{login:"alice"},
  body:"Adds query() — bounded on purpose, see below",
  head:{sha:$sha, ref:"b1", repo:{full_name:"acme/widgets"}}, base:{ref:"main"}, labels:[],
  requested_reviewers:[], additions:3, deletions:1, changed_files:3}' | fx 'api repos/acme/widgets/pulls/1'
printf '%s' '{"body":"Adds query() — bounded on purpose, see below","author":{"login":"alice"},"comments":[{"author":{"login":"bob"},"body":"looks ok","createdAt":"2026-09-01T00:00:00Z"},{"author":{"login":"carol"},"body":"the limit is enforced upstream","createdAt":"'"$(iso_ago -3600)"'"}],"reviews":[]}' \
  | fx 'pr view 1 --repo acme/widgets --json body,author,comments,reviews'
run_rp compose-brief 1
assert_out_contains 'the description was edited' 'compose-brief names the edited description'
assert_out_contains '1 new comment(s)/review(s)' 'compose-brief counts what landed after the lock'
CTXF="$(PR_DIR).ctx/context.json"
jq -e '.body | contains("bounded on purpose")' "$CTXF" >/dev/null \
  && printf 'ok   %s: the refreshed body reached the context pack\n' "$CASE" \
  || { printf 'FAIL %s: context.json still holds the locked body\n' "$CASE"; FAILED=1; }
jq -e '[.comments[] | select(.author == "carol")] | length == 1' "$CTXF" >/dev/null \
  && printf 'ok   %s: the new comment reached the context pack\n' "$CASE" \
  || { printf 'FAIL %s: the new comment is missing from context.json\n' "$CASE"; FAILED=1; }
jq -e '(.inline | type) == "array"' "$CTXF" >/dev/null \
  && printf 'ok   %s: the inline threads survive the refresh\n' "$CASE" \
  || { printf 'FAIL %s: the refresh dropped the inline threads\n' "$CASE"; FAILED=1; }
run_rp abort 1 "reset"

# a quiet conversation says nothing at all
setup compose_refresh_quiet
run_rp prepare 1
run_rp compose-brief 1
assert_out_absent 'the description was edited' 'an unchanged description is not mentioned'
assert_out_absent 'new comment\(s\)' 'no new comments, no section'
run_rp abort 1 "reset"

# --- compose-brief: the header counts come from the later read --------------------
# GitHub computes a PR's diff counts asynchronously, so `prepare` can lock a
# partial set into the header (docs/review.md → Guarding a running review)
setup compose_counts_race
jq -n --arg sha "$B1_SHA" '{state:"open", merged:false, draft:false, title:"alpha PR", user:{login:"alice"},
  body:"Adds query()", head:{sha:$sha, ref:"b1", repo:{full_name:"acme/widgets"}}, base:{ref:"main"},
  labels:[], requested_reviewers:[], additions:0, deletions:0, changed_files:0}' \
  | fx 'api repos/acme/widgets/pulls/1'
run_rp prepare 1
assert_jq '.changes.additions == 0' 'prepare locks the counts GitHub had at the time'
pr_fx open '[]'   # GitHub finished counting: +3 −1 over 3 files, same HEAD
run_rp compose-brief 1
assert_out_contains '\*\*Changes:\*\* +3 −1 (3 files)' 'the header reports the counts at compose time'
run_rp abort 1 "reset"

# --- compose-brief: the review states what it could not read ---------------------
# docs/review.md → Output format (first reviews)
setup compose_limits_quiet
run_rp prepare 1
run_rp compose-brief 1
assert_out_absent '_Limits:' 'a run with nothing to report prints no limits line'
[ -f "$(PR_DIR).ctx/limits.txt" ] \
  && { printf 'FAIL %s: a limits file was written with nothing to report\n' "$CASE"; FAILED=1; } \
  || printf 'ok   %s: no limits file with nothing to report\n' "$CASE"
# one skill without output is skill-errored: its section is gone, the line says so
mkdir -p "$(PR_DIR).out"; printf -- '- ✅ No findings.\n' > "$(PR_DIR).out/doc-drift.txt"
run_rp collect 1
run_rp compose-brief 1
assert_out_contains '_Limits: 1 skill(s) did not run: typescript-engineering\._' 'the line counts and names the skill that did not run'
assert_out_absent 'the clone failed' 'a clone that worked is not reported as a limit'
assert_out_contains 'refuses a body without it' 'the brief says the line is mandatory'
run_rp abort 1 "reset"

# a failed clone reaches the reader, and `post` refuses a body that drops the line
setup compose_limits_clone
CLONE_SRC="$SANDBOX/no-such-repo"
run_rp prepare 1
assert_jq '.outcome == "ready" and .clone == "failed"' 'the clone did not succeed'
run_rp compose-brief 1
assert_out_contains '_Limits: the clone failed — findings come from the diff only\.' 'the failed clone is stated as a fact'
assert_out_contains '2 skill(s) did not run: doc-drift, typescript-engineering\.' 'every clone-failed skill is named in the same line'
assert_file_contains "$(PR_DIR).ctx/limits.txt" '^_Limits: the clone failed' 'the facts are stored for post'
printf '### Summary\nAdds query().\n\n### Verdict\nCOMMENT\n' > "$SANDBOX/body.md"
printf '[]' > "$SANDBOX/findings.json"
printf '{"id":91,"html_url":"https://example.test/r/91","state":"COMMENTED"}' | fx "$(POST_SLUG)"
run_rp post 1 --verdict COMMENT --body "$SANDBOX/body.md" --findings "$SANDBOX/findings.json"
assert_jq '.outcome == "error" and (.error | test("limits line"))' 'post refuses a body that drops the limits line'
grep -q 'pulls/1/reviews -X POST' "$SANDBOX/gh.log" \
  && { printf 'FAIL %s: the refused post still reached GitHub\n' "$CASE"; FAILED=1; } \
  || printf 'ok   %s: nothing was posted\n' "$CASE"
assert_file_contains "$WORK/REVIEWS.md" '| 1 | .* | in_progress |' 'the lock survives the refusal'
{ printf '### Summary\nAdds query().\n'; cat "$(PR_DIR).ctx/limits.txt"; printf '\n### Verdict\nCOMMENT\n'; } > "$SANDBOX/body.md"
run_rp post 1 --verdict COMMENT --body "$SANDBOX/body.md" --findings "$SANDBOX/findings.json"
assert_jq '.outcome == "posted"' 'the body that carries the line posts'
assert_file_contains "$WORK/reviews/pr-1.md" '_Limits: the clone failed' 'the posted body states the limit'

# --- post: the ledger row carries the style and refutation measurements --------
# docs/review-mechanics.md → **Review ledger**: the week's noise and style numbers are
# read off these two fields, so a posted review must write both.
setup post_measurements
pr_fx open '[]'
run_rp prepare 1
printf '### Summary\nAdds query(). _(Suppressed 1 finding(s) per PR context: F1. Suppressed 2 finding(s) per in-tree decisions: F2,F3 — docs/architecture/artifact-library.md.)_\n\n### Verdict\nAPPROVE\n' > "$SANDBOX/body.md"
printf '[]' > "$SANDBOX/findings.json"
printf '{"id":78,"html_url":"https://example.test/r/78","state":"APPROVED"}' | fx "$(POST_SLUG)"
run_rp post 1 --verdict APPROVE --body "$SANDBOX/body.md" --findings "$SANDBOX/findings.json"
assert_jq '.outcome == "posted"' 'review posted'
assert_file_contains "$WORK/REVIEW-LEDGER.jsonl" '"suppressed":{"overrides":0,"context":1,"decisions":2,"total":3}' 'the ledger row counts the audit note per source'
assert_file_contains "$WORK/REVIEW-LEDGER.jsonl" '"ste":{"sentences":[0-9]' 'the ledger row carries the sentence measurement'

# --- ci: the rollup a triage reads (docs/ci-triage.md) -------------------------
setup ci_rollup
add_row 1 "$B1_SHA" "2026-09-01T00:00:00Z" COMMENT done
jq -n --arg sha "$B1_SHA" '{total_count:2, check_runs:[
    {name:"build", status:"completed", conclusion:"failure",
     details_url:"https://github.com/acme/widgets/actions/runs/9/job/42",
     output:{title:"build failed", summary:"tsc: cannot find name query", text:""}},
    {name:"lint", status:"completed", conclusion:"success", details_url:"", output:{}}]}' \
  | fx "api repos/acme/widgets/commits/$B1_SHA/check-runs?per_page=100"
printf 'line one\nline two\nerror TS2304: cannot find name query\n' \
  | fx "api repos/acme/widgets/actions/jobs/42/logs"
run_rp ci 1
assert_jq '.outcome == "ci" and .terminal == true' 'a completed rollup is terminal'
assert_jq '(.failing | length) == 1 and .failing[0].name == "build"' 'only the failing check is returned'
assert_jq '.failing[0].evidence_source == "log"' 'the job log is the evidence'
EV="$(printf '%s' "$OUT" | jq -r '.failing[0].evidence')"
assert_file_contains "$EV" 'error TS2304' 'the evidence file holds the log tail'

# --- ci: a running check holds the triage, and costs no log fetch --------------
setup ci_running
add_row 1 "$B1_SHA" "2026-09-01T00:00:00Z" COMMENT done
jq -n '{total_count:1, check_runs:[{name:"build", status:"in_progress", conclusion:null,
        details_url:"https://github.com/acme/widgets/actions/runs/9/job/42", output:{}}]}' \
  | fx "api repos/acme/widgets/commits/$B1_SHA/check-runs?per_page=100"
run_rp ci 1
assert_jq '.terminal == false and (.failing | length) == 0' 'a running rollup returns no evidence'
grep -q 'actions/jobs/42/logs' "$SANDBOX/gh.log" \
  && { printf 'FAIL %s: a running rollup fetched a log\n' "$CASE"; FAILED=1; } \
  || printf 'ok   %s: no log fetched while a check still runs\n' "$CASE"

# --- ci: the check run's own output is the fallback evidence -------------------
setup ci_output_evidence
add_row 1 "$B1_SHA" "2026-09-01T00:00:00Z" COMMENT done
jq -n '{total_count:1, check_runs:[{name:"e2e", status:"completed", conclusion:"failure",
        details_url:"https://ci.example.com/7",
        output:{title:"e2e failed", summary:"login spec timed out", text:""}}]}' \
  | fx "api repos/acme/widgets/commits/$B1_SHA/check-runs?per_page=100"
run_rp ci 1
assert_jq '.failing[0].evidence_source == "output"' 'a check outside Actions falls back to its output'
EV="$(printf '%s' "$OUT" | jq -r '.failing[0].evidence')"
assert_file_contains "$EV" 'login spec timed out' 'the output text is the evidence'

finish
