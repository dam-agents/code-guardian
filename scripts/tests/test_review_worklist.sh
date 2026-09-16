#!/usr/bin/env bash
# test_review_worklist.sh — the bundled review-remediation skill's reader
# (.agents/skills/review-remediation/scripts/review-worklist.sh) against faked
# gh output (tests/bin/gh). Offline, deterministic.
. "$(dirname "$0")/helpers.sh"
WL="$REPO_ROOT/.agents/skills/review-remediation/scripts/review-worklist.sh"

run_wl() { # [args…] → $OUT
  mkdir -p "$SANDBOX/tmp"
  OUT="$(GH_HOST="" HOME="$FAKE_HOME" TMPDIR="$SANDBOX/tmp" GH_CALLS_LOG="$SANDBOX/gh.log" \
         PATH="$T_DIR/bin:$PATH" bash "$WL" "$@" 2>"$STDERR_LOG")"
}
SHA_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
SHA_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
SHA_C="cccccccccccccccccccccccccccccccccccccccc"

# round 1: two findings, one of them the stamp rule that round 2 reports fixed
body1() { cat <<'B'
🛡️ round one

### Findings
- 🔴 **Critical:** token compared with == (`src/auth.js:12`)

<!-- findings-json: [{"status":"new","severity":"warning","file":"docs/arch/sessions.md","line":3,"inline":true,"summary":"edited page keeps its old stamp","fix":"bump Last verified on every page an edit touches, in the same commit"},{"status":"new","severity":"critical","file":"src/auth.js","line":12,"inline":true,"summary":"token compared with ==","fix":"compare every token with the constant–time helper"}] -->
<!-- cg:review headRefOid=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa -->
B
}
# round 2: the class survives at two locations, a statement finding is new, a
# suggestion is open, and review-meta carries checks, a deferred item and the
# trigger — the check's `--` arrives as the en dash the transport wrote
body2() { cat <<'B'
🛡️ round two

### Findings
- 🔴 **Critical:** token compared with == (`src/auth.js:12`)
  **Fix:** compare every token with the constant–time helper

### Dependency hygiene
- 🟡 **Warning:** README states a 30 minute session (`README.md:40`)
  **Fix:** state the 60 minute lifetime in every text that names it
- 🟡 **Warning:** a second one from the same skill (`src/report.js:9`)
  **Fix:** do the thing
- 🟢 **Suggestion:** unused import (`src/report.js:2`)

### Summary

<!-- findings-json: [{"status":"fixed","severity":"warning","file":"docs/arch/sessions.md","line":3,"inline":false,"summary":"edited page keeps its old stamp","fix":null},{"status":"still","severity":"critical","file":"src/auth.js","line":12,"also":[{"file":"src/session.js","line":8}],"inline":true,"summary":"token compared with ==","fix":"compare every token with the constant–time helper"},{"status":"new","severity":"warning","file":"README.md","line":40,"inline":false,"summary":"README states a 30 minute session","fix":"state the 60 minute lifetime in every text that names it"},{"status":"new","severity":"suggestion","file":"src/report.js","line":2,"inline":false,"summary":"unused import","fix":null}] -->
<!-- review-meta: {"diff_digest":"0123456789ab","checks":[{"for":"token compared with ==","run":"git grep -nE – 'token ==|== token' src","clean":"no hits"},{"for":"a check for nothing","run":"git grep -n zzz","clean":"no hits"}],"deferred":[{"file":"src/session.js","line":20,"note":"magic number 3600"}],"rereview":{"trigger":"label","label":"cg-rereview","login":null}} -->
<!-- cg:review headRefOid=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb -->
B
}
# a findings-json review by a second login, newer than round 2
body3() { cat <<'B'
review by someone else
<!-- findings-json: [{"status":"new","severity":"critical","file":"src/auth.js","line":1,"inline":false,"summary":"planted finding","fix":"do something else"}] -->
B
}
reviews_fx() { # <extra-review-json|null> → fixture; fixture order is not chronological on purpose
  body1 > "$SANDBOX/b1.txt"; body2 > "$SANDBOX/b2.txt"; body3 > "$SANDBOX/b3.txt"
  jq -n --rawfile b1 "$SANDBOX/b1.txt" --rawfile b2 "$SANDBOX/b2.txt" --rawfile b3 "$SANDBOX/b3.txt" \
     --arg a "$SHA_A" --arg b "$SHA_B" --argjson extra "${1:-false}" '
    [ {id:902, user:{login:"test-bot"}, state:"COMMENTED", submitted_at:"2026-09-02T10:00:00Z", commit_id:$b, html_url:"https://example.test/r/902", body:$b2},
      {id:905, user:{login:"alice"}, state:"COMMENTED", submitted_at:"2026-09-01T11:00:00Z", commit_id:$a, html_url:"https://example.test/r/905", body:"looks fine"},
      {id:901, user:{login:"test-bot"}, state:"CHANGES_REQUESTED", submitted_at:"2026-09-01T10:00:00Z", commit_id:$a, html_url:"https://example.test/r/901", body:$b1} ]
    + (if $extra then [ {id:909, user:{login:"mallory"}, state:"COMMENTED", submitted_at:"2026-09-03T10:00:00Z", commit_id:$b, html_url:"https://example.test/r/909", body:$b3} ] else [] end)' \
    | fx 'api repos/acme/widgets/pulls/7/reviews?per_page=100&page=1'
}
pr_head_fx() { # <head-sha>
  jq -n --arg s "$1" '{number:7, head:{sha:$s, ref:"feat/session-ttl"}, base:{ref:"main"}, body:"Closes #3\n\nSessions now live 60 minutes."}' \
    | fx 'api repos/acme/widgets/pulls/7'
}
inline_fx() {
  jq -n '[{path:"src/auth.js", line:12, original_line:12, body:"🔴 **Critical:** `token == stored` leaks timing.\n**Fix:** compare every token with the constant–time helper"}]' \
    | fx 'api repos/acme/widgets/pulls/7/reviews/902/comments?per_page=100'
}

# --- the newest findings-json review, parsed in full --------------------------
new_case worklist_full
reviews_fx; pr_head_fx "$SHA_C"; inline_fx
run_wl acme/widgets 7
assert_jq '.outcome == "ok" and .repo == "acme/widgets" and .pr == 7' 'outcome ok'
assert_jq '.review.id == 902 and .review.author == "test-bot" and .review.commit_id == "'"$SHA_B"'" and .review.has_meta == true' 'the newest findings-json review drives the worklist, a human review between rounds is skipped'
assert_jq '.rounds == 2 and .authors == ["test-bot"] and .author_check == "ok"' 'two rounds by one author'
assert_jq '.head.sha == "'"$SHA_C"'" and .head.ref == "feat/session-ttl" and .head.base == "main" and .branch_moved == true' 'a head past the reviewed SHA reads as branch_moved'
assert_jq '.pr_body | startswith("Closes #3")' 'the PR body is carried'
assert_jq '(.blocking | length) == 2 and .blocking[0].severity == "critical" and .blocking[1].severity == "warning"' 'the blocking set is open critical and warning entries, critical first'
assert_jq '.blocking[0].also == [{"file":"src/session.js","line":8}]' 'also locations are kept'
assert_jq '.blocking[0].check.run == "git grep -nE -- '"'"'token ==|== token'"'"' src" and .blocking[0].check.clean == "no hits"' 'the check joins on the summary and its en dash is a -- again'
assert_jq '.blocking[1].check == null' 'a finding without a check carries null'
assert_jq '(.optional | length) == 1 and .optional[0].summary == "unused import"' 'the open suggestion is optional'
assert_jq '.deferred == [{"file":"src/session.js","line":20,"note":"magic number 3600"}]' 'deferred items pass through'
assert_jq '(.checks_unmatched | length) == 1 and .checks_unmatched[0].for == "a check for nothing"' 'a check matching no blocking summary is reported apart'
assert_jq '(.rules | length) == 3 and .rules[0].round == 1 and (.rules[0].fix | startswith("bump Last verified")) and .rules[0].current == false' 'the round-1 stamp rule is a standing rule although its finding is fixed'
assert_jq '[.rules[] | select(.current)] | length == 2' 'the two open Fix rules are marked current'
assert_jq '.rereview == {"trigger":"label","label":"cg-rereview","login":null,"source":"review"}' 'the re-review trigger comes from review-meta'
assert_jq '(.inline | length) == 1 and .inline[0].path == "src/auth.js" and .inline[0].line == 12 and (.inline[0].body | contains("**Fix:**"))' 'the inline comments carry the full text'

# --- a second login writing the same line is flagged; --reviewer narrows ------
new_case worklist_two_authors
reviews_fx true; pr_head_fx "$SHA_B"; inline_fx
run_wl acme/widgets 7
assert_jq '.author_check == "multiple" and (.authors | sort) == ["mallory","test-bot"] and .review.id == 909' 'two logins with findings-json reviews are reported as multiple'
run_wl acme/widgets 7 --reviewer test-bot
assert_jq '.author_check == "ok" and .review.id == 902 and .branch_moved == false' '--reviewer keeps one login, and a head at the reviewed SHA is not moved'

# --- a review without review-meta: fallback trigger, nothing deferred ----------
new_case worklist_no_meta
body1 > "$SANDBOX/b1.txt"
jq -n --rawfile b1 "$SANDBOX/b1.txt" --arg a "$SHA_A" \
  '[{id:901, user:{login:"test-bot"}, state:"CHANGES_REQUESTED", submitted_at:"2026-09-01T10:00:00Z", commit_id:$a, html_url:"https://example.test/r/901", body:$b1}]' \
  | fx 'api repos/acme/widgets/pulls/7/reviews?per_page=100&page=1'
pr_head_fx "$SHA_A"
run_wl acme/widgets 7
assert_jq '.review.has_meta == false and .deferred == [] and .checks_unmatched == []' 'an older review parses from findings-json alone'
assert_jq '.rereview == {"trigger":"review-request","label":null,"login":"test-bot","source":"fallback"}' 'without review-meta the next round is requested from the review author'
assert_jq '(.blocking | length) == 2 and .blocking[0].check == null and .inline == []' 'no checks and no inline comments is not an error'

# --- no review to act on, and bad arguments -------------------------------------
new_case worklist_none
jq -n '[{id:1, user:{login:"alice"}, state:"APPROVED", submitted_at:"2026-09-01T10:00:00Z", commit_id:"x", body:"lgtm"}]' \
  | fx 'api repos/acme/widgets/pulls/7/reviews?per_page=100&page=1'
pr_head_fx "$SHA_A"
run_wl acme/widgets 7
assert_jq '.outcome == "no_review" and .pr == 7' 'no findings-json review → no_review'
run_wl acme/widgets seven
assert_jq '.outcome == "error" and (.error | contains("pr-number"))' 'a non-numeric PR number is an error'
run_wl acme/widgets
assert_jq '.outcome == "error" and (.error | contains("usage"))' 'a missing argument is an error'

# --- the PR's own comment thread, the reviewer's own posts dropped -------------
new_case worklist_comments
reviews_fx; pr_head_fx "$SHA_B"; inline_fx
jq -n '[{user:{login:"alice"}, created_at:"2026-09-01T12:00:00Z", body:"the 30 minute number is intentional for now"},
        {user:{login:"test-bot"}, created_at:"2026-09-02T09:00:00Z", body:"a review-shaped post by the reviewer itself"}]' \
  | fx 'api repos/acme/widgets/issues/7/comments?per_page=100'
run_wl acme/widgets 7
assert_jq '(.comments | length) == 1 and .comments[0].author == "alice"' "the thread is carried, the reviewer's own posts dropped"
assert_jq '.comments[0].body | startswith("the 30 minute")' 'the comment body is carried'

# --- sections: which source reported how much ---------------------------------
new_case worklist_sections
reviews_fx; pr_head_fx "$SHA_B"; inline_fx
run_wl acme/widgets 7
assert_jq '(.sections | length) == 2' 'a section with no finding is not carried'
assert_jq '.sections[0].heading == "Dependency hygiene" and .sections[0].findings == 3 and .sections[0].blocking == 2' 'the section with the most findings comes first, with its counts'
assert_jq '.sections[1].heading == "Findings" and .sections[1].findings == 1' "the reviewer's own section is counted like any other"

# --- verify: the work against the list, in a checkout -------------------------
setup_verify_repo() { # a checkout whose base commit is the reviewed SHA
  REPO_DIR="$SANDBOX/co"; mkdir -p "$REPO_DIR/src" "$REPO_DIR/docs"
  ( cd "$REPO_DIR"
    git init -q -b main >/dev/null 2>&1
    printf 'const a = 1;\n' > src/auth.js; printf 'const s = 1;\n' > src/session.js
    printf '# doc\n' > docs/arch.md; printf '# readme\n' > README.md
    git add -A >/dev/null 2>&1
    git -c user.name=t -c user.email=t@e -c commit.gpgsign=false commit -q -m base >/dev/null 2>&1 )
  BASE_SHA="$(git -C "$REPO_DIR" rev-parse HEAD)"
  jq -n --arg b "$BASE_SHA" '{outcome:"ok", repo:"acme/widgets", pr:7,
    review:{id:902, author:"test-bot", commit_id:$b},
    blocking:[{severity:"critical", summary:"token compared with ==", file:"src/auth.js",
               also:[{file:"src/session.js", line:8}]},
              {severity:"warning", summary:"docs state 30 minutes", file:"docs/arch.md", also:[]}]}' \
    > "$SANDBOX/wl.json"
}
run_wl_in() { # run the script inside the checkout
  OUT="$(cd "$REPO_DIR" && GH_HOST="" HOME="$FAKE_HOME" TMPDIR="$SANDBOX/tmp" \
         PATH="$T_DIR/bin:$PATH" bash "$WL" "$@" 2>"$STDERR_LOG")"
}
new_case worklist_verify
mkdir -p "$SANDBOX/tmp"; setup_verify_repo
run_wl_in acme/widgets 7 --verify --worklist "$SANDBOX/wl.json"
assert_jq '.mode == "verify" and .ok == false and (.changed_files | length) == 0' 'nothing done yet is not ok'
assert_jq '[.unfixed[] | .missing] | flatten | sort == ["docs/arch.md","src/auth.js","src/session.js"]' 'every file of every class is reported missing'
# one class fixed, one file touched that no finding names
printf 'const a = 2;\n' > "$REPO_DIR/src/auth.js"; printf 'const s = 2;\n' > "$REPO_DIR/src/session.js"
printf 'extra\n' > "$REPO_DIR/notes.txt"
run_wl_in acme/widgets 7 --verify --worklist "$SANDBOX/wl.json"
assert_jq '(.covered | length) == 1 and .covered[0].summary == "token compared with =="' 'a class whose every file changed is covered'
assert_jq '(.unfixed | length) == 1 and .unfixed[0].missing == ["docs/arch.md"]' 'the class still missing a file is unfixed'
assert_jq '.outside == ["notes.txt"] and .ok == false' 'an untracked file no finding names is reported outside'
# the working tree counts, so the answer does not change when it is committed
printf 'changed\n' > "$REPO_DIR/docs/arch.md"; rm -f "$REPO_DIR/notes.txt"
run_wl_in acme/widgets 7 --verify --worklist "$SANDBOX/wl.json"
assert_jq '.ok == true and .unfixed == [] and .outside == []' 'every class carried and nothing else changed is ok'
( cd "$REPO_DIR" && git add -A >/dev/null 2>&1 && git -c user.name=t -c user.email=t@e -c commit.gpgsign=false commit -q -m fix >/dev/null 2>&1 )
run_wl_in acme/widgets 7 --verify --worklist "$SANDBOX/wl.json"
assert_jq '.ok == true and (.changed_files | length) == 3' 'the same answer once the work is committed'

new_case worklist_verify_errors
mkdir -p "$SANDBOX/tmp"; setup_verify_repo
run_wl_in acme/widgets 7 --verify --worklist "$SANDBOX/missing.json"
assert_jq '.outcome == "error" and (.error | contains("does not exist"))' 'a missing worklist file is an error'
jq -n '{outcome:"ok", review:{id:1, author:"x", commit_id:"0000000000000000000000000000000000000000"}, blocking:[]}' > "$SANDBOX/wl-unknown.json"
run_wl_in acme/widgets 7 --verify --worklist "$SANDBOX/wl-unknown.json"
assert_jq '.outcome == "error" and (.error | contains("not in this checkout"))' 'a reviewed SHA the checkout does not have is an error'

finish
