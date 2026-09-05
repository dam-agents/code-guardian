#!/usr/bin/env bash
# benchmark-score.sh — deterministic scorer over a fixed manifest and raw
# reviews (docs/benchmark.md). Pure local: no gh, no preflight.
. "$(dirname "$0")/helpers.sh"

SCORE="$REPO_ROOT/scripts/benchmark-score.sh"

write_manifest() {
  cat > "$SANDBOX/manifest.json" <<'EOF'
{"fixture":"fx-test","created":"2026-08-01T00:00:00Z","defects":[
 {"id":"D01","file":"src/auth.ts","line_v1":42,"line_v2":null,"fix_line_v2":42,"class":"security","severity":"critical","summary":"token ==","fixed_in_v2":true,"in_prior_review":true},
 {"id":"D02","file":"src/auth.ts","line_v1":60,"line_v2":58,"class":"correctness","severity":"warning","summary":"off by one","fixed_in_v2":false,"in_prior_review":true},
 {"id":"D03","file":"src/db.ts","line_v1":10,"line_v2":10,"class":"performance","severity":"warning","summary":"n+1","fixed_in_v2":false,"in_prior_review":false},
 {"id":"D04","file":"src/db.ts","line_v1":null,"line_v2":30,"class":"correctness","severity":"critical","summary":"null deref","fixed_in_v2":false,"in_prior_review":false}
]}
EOF
}

run_score() { OUT="$(bash "$SCORE" "$1" "$2" "$SANDBOX/manifest.json")"; }

new_case score_first
write_manifest
cat > "$SANDBOX/first.md" <<'EOF'
## PR #0: Test PR
### Summary
This PR adds auth. It is small.
### Findings
- 🔴 **Critical:** token compared with == (`src/auth.ts:41`)
- 🟡 **Warning:** N+1 query (`src/db.ts:11`)
- 🟡 **Warning:** made-up thing (`src/other.ts:5`)
- 🟢 **Suggestion:** rename helper (`src/auth.ts:80`)
### Verdict
REQUEST_CHANGES — one critical finding is open.

<!-- findings-json: [{"status":"new","severity":"critical","file":"src/auth.ts","line":41,"inline":true,"summary":"token compared with ==","fix":"constant-time compare"},{"status":"new","severity":"warning","file":"src/db.ts","line":11,"inline":true,"summary":"n+1 query","fix":"batch the lookup"},{"status":"new","severity":"warning","file":"src/other.ts","line":5,"inline":false,"summary":"made-up","fix":"none"},{"status":"new","severity":"suggestion","file":"src/auth.ts","line":80,"inline":false,"summary":"rename","fix":null}] -->
<!-- cg:review headRefOid=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa -->
EOF
run_score first "$SANDBOX/first.md"
assert_jq '.gt == 3' 'v1 ground-truth set counts line_v1 defects only'
assert_jq '.tp | length == 2' 'two findings match within the ±3 window'
assert_jq '.fn == ["D02"]' 'the missed defect is named'
assert_jq '.fp | length == 1 and .[0].file == "src/other.ts"' 'the unmatched blocking finding is an FP'
assert_jq '.suggestions_unmatched == 1' 'unmatched suggestions are counted, not FPs'
assert_jq '.precision == 0.667 and .recall == 0.667 and .f1 == 0.667' 'precision/recall/f1'
assert_jq '.recall_critical == 1 and .recall_warning == 0.5' 'per-severity recall'
assert_jq '.severity_accuracy == 1' 'matched severities agree'
assert_jq '[.format.findings_json, .format.marker, .format.sections, .format.fix_lines, .format.verdict_consistent] | all' 'format checks pass'
assert_jq '.length.words_total > 0 and .length.findings == 4' 'length block'
assert_jq '.ste.sentences > 0' 'ste block'

new_case score_first_degraded
write_manifest
cat > "$SANDBOX/plain.md" <<'EOF'
Looks good to me!
EOF
run_score first "$SANDBOX/plain.md"
assert_jq '.format.findings_json == false and .format.marker == false and .format.sections == false' 'missing structure is reported'
assert_jq '.recall == 0 and (.fn | length) == 3' 'an unparseable review scores zero recall'
assert_jq '.format.verdict == "missing"' 'missing verdict is named'

new_case score_verdict_inconsistent
write_manifest
cat > "$SANDBOX/soft.md" <<'EOF'
### Summary
Small change.
### Findings
- 🔴 **Critical:** token compared with == (`src/auth.ts:42`)
### Verdict
APPROVE — fine overall.

<!-- findings-json: [{"status":"new","severity":"critical","file":"src/auth.ts","line":42,"inline":false,"summary":"token ==","fix":"constant-time compare"}] -->
<!-- cg:review headRefOid=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa -->
EOF
run_score first "$SANDBOX/soft.md"
assert_jq '.format.verdict_consistent == false' 'APPROVE over an open critical is flagged'
assert_jq '.recall_critical == 1' 'the finding itself still matches'

new_case score_rereview
write_manifest
cat > "$SANDBOX/re.md" <<'EOF'
### Summary
Delta re-review.
### Changes since last review
Previous HEAD: aaaaaaa — verdict REQUEST_CHANGES
- ✅ **Fixed:** token compared with == (`src/auth.ts:42`)
- 🔁 **Still present:** off by one (`src/auth.ts:58`)
- 🆕 **New:** null deref (`src/db.ts:31`)
- 🆕 **New:** n+1 query (`src/db.ts:10`)
- 🆕 **New:** invented issue (`src/other.ts:99`)
### Findings
- 🔴 **Critical:** null deref (`src/db.ts:31`)
### Verdict
REQUEST_CHANGES — one critical finding is open.

<!-- findings-json: [{"status":"fixed","severity":"critical","file":"src/auth.ts","line":42,"inline":false,"summary":"token ==","fix":null},{"status":"still","severity":"warning","file":"src/auth.ts","line":58,"inline":false,"summary":"off by one","fix":"fix the bound"},{"status":"new","severity":"critical","file":"src/db.ts","line":31,"inline":true,"summary":"null deref","fix":"guard the null"},{"status":"new","severity":"warning","file":"src/db.ts","line":10,"inline":true,"summary":"n+1","fix":"batch the lookup"},{"status":"new","severity":"warning","file":"src/auth.ts","line":43,"inline":true,"summary":"constant-time compare is slow","fix":"revert to =="},{"status":"new","severity":"warning","file":"src/other.ts","line":99,"inline":false,"summary":"invented","fix":"whatever"}] -->
<!-- cg:review headRefOid=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb -->
EOF
run_score rereview "$SANDBOX/re.md"
assert_jq '.fixed_gt == 1 and .still_gt == 1 and .new_gt == 1' 'ground-truth buckets'
assert_jq '.fixed_recall == 1 and .still_recall == 1 and .new_recall == 1' 'all buckets matched'
assert_jq '.false_fixed == 0' 'no kept defect reported fixed'
assert_jq '.late_finds == 1' 'the v1 defect outside the prior review is a late find'
assert_jq '.churn == 1' 'a blocking finding on a fix site is churn (going in circles)'
assert_jq '.new_fp == 1' 'the invented new finding is an FP, disjoint from churn'
assert_jq '.format.delta_section == true' 'the delta section is present'

new_case score_malformed_findings_json
write_manifest
cat > "$SANDBOX/malformed.md" <<'EOF'
### Summary
X.
### Findings
- 🔴 **Critical:** token compared with == (`src/auth.ts:41`)
### Verdict
REQUEST_CHANGES — open critical.

<!-- findings-json: [{"status":"new","severity":"critical","file":"src/auth.ts","line":"41","fix":"constant-time compare"},"junk-element",{"status":"new","severity":"warning","file":"src/db.ts","line":{"bad":1},"fix":"x"}] -->
<!-- cg:review headRefOid=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa -->
EOF
run_score first "$SANDBOX/malformed.md"
assert_jq '.format.findings_json == true' 'malformed elements degrade, never crash'
assert_jq '.tp | length == 1' 'a string line is coerced and still matches'
assert_jq '.recall_critical == 1' 'the coerced finding scores'

new_case score_correct_fixed_with_null_line
write_manifest
cat > "$SANDBOX/nullfix.md" <<'EOF'
### Summary
Delta re-review.
### Changes since last review
- ✅ **Fixed:** token compared with == (`src/auth.ts`)
- 🔁 **Still present:** off by one (`src/auth.ts:58`)
### Findings
_No new findings at this HEAD._
### Verdict
COMMENT — one warning still open.

<!-- findings-json: [{"status":"fixed","severity":"critical","file":"src/auth.ts","line":null,"inline":false,"summary":"token ==","fix":null},{"status":"still","severity":"warning","file":"src/auth.ts","line":58,"inline":false,"summary":"off by one","fix":"fix the bound"}] -->
<!-- cg:review headRefOid=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb -->
EOF
run_score rereview "$SANDBOX/nullfix.md"
assert_jq '.fixed_recall == 1' 'a line-null fixed claim matches by file'
assert_jq '.false_fixed == 0' 'a correctly-consumed fixed claim is never double-counted as false-fixed'
assert_jq '.still_recall == 1' 'the still claim matches independently'

new_case score_fix_lines_covers_still
write_manifest
cat > "$SANDBOX/stillnofix.md" <<'EOF'
### Summary
Delta re-review.
### Changes since last review
- 🔁 **Still present:** off by one (`src/auth.ts:58`)
### Findings
_No new findings at this HEAD._
### Verdict
COMMENT — one warning still open.

<!-- findings-json: [{"status":"still","severity":"warning","file":"src/auth.ts","line":58,"inline":false,"summary":"off by one","fix":null}] -->
<!-- cg:review headRefOid=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb -->
EOF
run_score rereview "$SANDBOX/stillnofix.md"
assert_jq '.format.fix_lines == false' 'an open still entry without a fix fails the format check'

new_case score_false_fixed
write_manifest
cat > "$SANDBOX/ff.md" <<'EOF'
### Summary
Delta re-review.
### Changes since last review
- ✅ **Fixed:** off by one (`src/auth.ts:60`)
### Findings
_No new findings at this HEAD._
### Verdict
APPROVE — everything resolved.

<!-- findings-json: [{"status":"fixed","severity":"warning","file":"src/auth.ts","line":60,"inline":false,"summary":"off by one","fix":null}] -->
<!-- cg:review headRefOid=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb -->
EOF
run_score rereview "$SANDBOX/ff.md"
assert_jq '.false_fixed == 1' 'a kept defect reported fixed is counted'
assert_jq '.fixed_recall == 0' 'the truly fixed defect went unreported'


# --- also[]: one sibling-swept finding carries every location it names --------

new_case score_first_also_anchors
write_manifest
cat > "$SANDBOX/also.md" <<'EOF'
## PR #0: Test PR
### Summary
One defect class in three places.
### Findings
- 🔴 **Critical:** unsafe compare (`src/auth.ts:42`, `src/auth.ts:60`, `src/db.ts:10`)
  **Fix:** use the constant-time helper everywhere
### Verdict
REQUEST_CHANGES — one class is open.

<!-- findings-json: [{"status":"new","severity":"critical","file":"src/auth.ts","line":42,"also":[{"file":"src/auth.ts","line":60},{"file":"src/db.ts","line":10}],"inline":true,"summary":"unsafe compare","fix":"constant-time helper"}] -->
<!-- cg:review headRefOid=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa -->
EOF
run_score first "$SANDBOX/also.md"
assert_jq '.tp | length == 3' 'a merged finding scores every defect its anchors name'
assert_jq '.fn == []' 'no sibling of a merged finding is counted as missed'
assert_jq '.fp == []' 'a merged finding is not an FP'
assert_jq '.recall == 1 and .precision == 1 and .f1 == 1' 'merged anchors reach full recall without inventing precision'
assert_jq '.severity_accuracy == 0.333' 'one merged finding carries one severity, so it can only match one gt severity'

new_case score_first_also_partial_and_unmatched
write_manifest
cat > "$SANDBOX/also2.md" <<'EOF'
## PR #0: Test PR
### Summary
One real class and one invention.
### Findings
- 🔴 **Critical:** unsafe compare (`src/auth.ts:42`, `src/nowhere.ts:9`)
  **Fix:** use the constant-time helper
- 🟡 **Warning:** invented (`src/other.ts:5`, `src/other.ts:99`)
  **Fix:** none
### Verdict
REQUEST_CHANGES — one critical is open.

<!-- findings-json: [{"status":"new","severity":"critical","file":"src/auth.ts","line":42,"also":[{"file":"src/nowhere.ts","line":9}],"inline":true,"summary":"unsafe compare","fix":"constant-time helper"},{"status":"new","severity":"warning","file":"src/other.ts","line":5,"also":[{"file":"src/other.ts","line":99}],"inline":false,"summary":"invented","fix":"none"}] -->
<!-- cg:review headRefOid=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa -->
EOF
run_score first "$SANDBOX/also2.md"
assert_jq '.tp | length == 1' 'only the anchor that matches scores'
assert_jq '.fp | length == 1' 'a prediction whose anchors all miss is one FP, never one per anchor'
assert_jq '[.fp[].file] == ["src/other.ts"]' 'the FP is the invented finding, not the partially matched one'

new_case score_rereview_also_anchors
write_manifest
cat > "$SANDBOX/rr-also.md" <<'EOF'
## PR #0: Test PR
### Summary
Re-review.
### Changes since last review
- 🆕 **New:** null deref (`src/db.ts:30`)
### Findings
- 🔴 **Critical:** null deref (`src/db.ts:30`, `src/nowhere.ts:7`)
  **Fix:** guard the lookup
### Verdict
REQUEST_CHANGES — one critical is open.

<!-- findings-json: [{"status":"new","severity":"critical","file":"src/db.ts","line":30,"also":[{"file":"src/nowhere.ts","line":7}],"inline":true,"summary":"null deref","fix":"guard the lookup"}] -->
<!-- cg:review headRefOid=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa -->
EOF
run_score rereview "$SANDBOX/rr-also.md"
assert_jq '.new_recall == 1' 'a merged new finding matches its v2 defect on any anchor'
assert_jq '.new_fp == 0' 'a prediction consumed by the new bucket leaves no leftover FP'

finish
