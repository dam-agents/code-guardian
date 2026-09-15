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

finish
