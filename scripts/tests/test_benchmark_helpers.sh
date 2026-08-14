#!/usr/bin/env bash
# benchmark helpers — the accumulated-report generator (benchmark-report.sh),
# the token usage snapshot (usage-snapshot.sh), and the provenance emitter
# (benchmark-provenance.sh). Pure local: no gh.
. "$(dirname "$0")/helpers.sh"

REPORT="$REPO_ROOT/scripts/benchmark-report.sh"
SNAP="$REPO_ROOT/scripts/harness/claude-code/usage-snapshot.sh"
PROV="$REPO_ROOT/scripts/benchmark-provenance.sh"

seed_results() {
  mkdir -p "$SANDBOX/bench/results"
  cat > "$SANDBOX/bench/results/20260701T060000Z.json" <<'EOF'
{"ts":"2026-07-01T06:00:00Z","trigger":"scheduled","model":"model-a","definition_version":"3.11.0",
 "fixtures":{"ts-api":{"first":{"f1":0.72,"precision":0.8,"recall":0.65,"severity_accuracy":0.9,"fp":[{"f":1}],"length":{"words_total":820},"seconds":410,"tokens":{"output":21000},"judge":{"finding_accuracy":4}},
   "rereview":{"fixed_recall":0.8,"still_recall":1,"new_recall":0.7,"false_fixed":0,"churn":0,"late_finds":1,"seconds":300,"tokens":{"output":15000}}},
  "react-ui":{"first":{"f1":0.6,"precision":0.7,"recall":0.55,"severity_accuracy":0.85,"fp":[],"length":{"words_total":700},"seconds":380,"tokens":{"output":18000},"judge":{"finding_accuracy":3}},
   "rereview":{"fixed_recall":1,"still_recall":0.5,"new_recall":0.5,"false_fixed":1,"churn":0,"late_finds":0,"seconds":250,"tokens":{"output":12000}}}}}
EOF
  cat > "$SANDBOX/bench/results/20260801T060000Z.json" <<'EOF'
{"ts":"2026-08-01T06:00:00Z","trigger":"manual","model":"model-b","definition_version":"3.12.0",
 "harness_version":"2.1.34 (Claude Code)","prev_version":"3.11.0",
 "changes_since_prev":["feat(review): sibling sweep for warning-class defects (v3.12.0)","fix(shepherd): cooldown off-by-one (v3.11.1)"],
 "fixtures":{"ts-api":{"first":{"f1":0.85,"precision":0.9,"recall":0.81,"severity_accuracy":1,"fp":[],"length":{"words_total":640},"seconds":300,"tokens":null,"judge":null},
   "rereview":{"fixed_recall":1,"still_recall":1,"new_recall":0.9,"false_fixed":0,"churn":0,"late_finds":0,"seconds":200,"tokens":null}}}}
EOF
}

new_case report_accumulates_runs
seed_results
OUT="$(bash "$REPORT" "$SANDBOX/bench")"
assert_out_contains '2 run(s) on record' 'both runs counted'
assert_out_contains '<td class=n>0.66</td>' 'run 1 avg f1 across fixtures'
assert_out_contains '<td class=n>66000</td>' 'run 1 output tokens summed'
assert_out_contains 'Latest run: 2026-08-01T06:00:00Z' 'latest run named'
assert_out_contains '<td class=n><b>0.769</b></td>' 'run 1 quality index is the baseline (no delta)'
assert_out_contains '<b>0.944</b> (+0.175)' 'run 2 index carries the delta vs run 1'
assert_out_contains '<td class=n>3.5</td>' 'judge column averages all dimensions on its own 1-5 scale'
assert_out_contains 'judge scores never enter it' 'page states the index is judge-free'
assert_out_contains '<td>2.1.34 (Claude Code)</td>' 'harness version column rendered'
assert_out_contains '<h3>3.12.0 — tested 2026-08-01T06:00:00Z (since 3.11.0)</h3>' 'version-change block names versions and run'
assert_out_contains '<th>churn</th>' 'per-fixture tables carry the churn column'
assert_out_contains 'filter rows…' 'interactive script embedded'
assert_out_contains 'th.dataset.d' 'sort handler embedded intact'
assert_out_absent 'src=|href="http|@import|fetch\(' 'page stays self-contained (no external assets)'
if [ "$(printf '%s' "$OUT" | grep -o '<li>' | grep -c '')" = "2" ]; then
  printf 'ok   %s: release-commit subjects listed as bullets\n' "$CASE"
else printf 'FAIL %s: changes bullet list wrong\n' "$CASE"; FAILED=1; fi
if [ "$(printf '%s' "$OUT" | grep -c '<h2>')" = "4" ]; then
  printf 'ok   %s: all-runs table + version changes + one section per fixture\n' "$CASE"
else printf 'FAIL %s: section count wrong\n' "$CASE"; FAILED=1; fi
missing_tok_row="$(printf '%s' "$OUT" | grep -A1 'model-b' | grep -c '—' || true)"
if [ "$missing_tok_row" -ge 1 ]; then
  printf 'ok   %s: unmeasured tokens render as dashes\n' "$CASE"
else printf 'FAIL %s: missing-token rendering\n' "$CASE"; FAILED=1; fi

new_case report_index_mode
seed_results
OUT="$(bash "$REPORT" index "$SANDBOX/bench")"
assert_jq 'length == 2 and .[0].index == 0.769 and .[1].index == 0.944' 'index mode prints per-run indexes as JSON'
assert_jq '.[0].fixtures["ts-api"] == 0.843' 'per-fixture index carried'
assert_jq '.[1].seconds == 500' 'run seconds carried for summaries'

new_case report_tolerates_corrupt_file
seed_results
printf '{broken' > "$SANDBOX/bench/results/corrupt.json"
OUT="$(bash "$REPORT" "$SANDBOX/bench")"
assert_out_contains '2 run(s) on record' 'a corrupt results file is skipped, history survives'
assert_out_contains 'Latest run: 2026-08-01T06:00:00Z' 'the valid runs still render'

new_case report_empty_results
mkdir -p "$SANDBOX/empty/results"
OUT="$(bash "$REPORT" "$SANDBOX/empty")"
assert_out_contains '0 run(s) on record' 'empty history renders a valid page'

new_case usage_snapshot_sums_own_transcript
mkdir -p "$FAKE_HOME/.claude/projects/p1"
NONCE="bench-test-nonce-42"
cat > "$FAKE_HOME/.claude/projects/p1/session.jsonl" <<EOF
{"type":"user","message":{"content":"run $NONCE please"}}
{"type":"assistant","message":{"id":"m1","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":1000,"cache_creation_input_tokens":10}}}
{"type":"assistant","message":{"id":"m1","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":1000,"cache_creation_input_tokens":10}}}
{"type":"assistant","message":{"id":"m2","usage":{"input_tokens":200,"output_tokens":75}}}
EOF
OUT="$(HOME="$FAKE_HOME" TMPDIR="$SANDBOX" bash "$SNAP" "$NONCE")"
assert_jq '.input == 300 and .output == 125 and .msgs == 2' 'usage summed, duplicate message ids deduped'
assert_jq '.cache_read == 1000 and .cache_creation == 10' 'cache fields carried'
if [ -f "$SANDBOX/.bench-usage-$NONCE" ]; then
  printf 'ok   %s: transcript path cached per nonce\n' "$CASE"
else printf 'FAIL %s: nonce cache not written\n' "$CASE"; FAILED=1; fi
OUT="$(HOME="$FAKE_HOME" TMPDIR="$SANDBOX" bash "$SNAP" "$NONCE")"
assert_jq '.output == 125' 'second snapshot serves from the cached path'

new_case usage_snapshot_no_match
OUT="$(HOME="$FAKE_HOME" TMPDIR="$SANDBOX" bash "$SNAP" "no-such-nonce-anywhere"; printf 'rc=%s' "$?")"
if [ "$OUT" = "rc=0" ]; then
  printf 'ok   %s: no transcript match prints nothing, exits 0\n' "$CASE"
else printf 'FAIL %s: expected empty output rc=0, got: %s\n' "$CASE" "$OUT"; FAILED=1; fi

new_case provenance_best_effort
seed_results
mkdir -p "$FAKE_HOME/.claude/skills/.cache" "$FAKE_HOME/work"
printf 'abcdef0123456789abcdef0123456789abcdef01' > "$FAKE_HOME/.claude/skills/.cache/doc-drift.sha"
printf '# mem\n' > "$FAKE_HOME/work/MEMORY.md"
printf '9.9.9\n' > "$FAKE_HOME/VERSION"
OUT="$(HOME="$FAKE_HOME" bash "$PROV" "$SANDBOX/bench")"
assert_jq '.definition_version == "9.9.9"' 'checked-out VERSION read'
assert_jq '.prev_version == "3.12.0"' 'prev version from the newest results file'
assert_jq '.skill_sources["doc-drift"] == "abcdef012345"' 'skill cache SHAs shortened to 12 chars'
assert_jq '.memory_sha != null' 'memory hash recorded'
assert_jq '.changes_since_prev == []' 'no git history degrades to an empty change list'
assert_jq '.definition_ref.branch == null' 'no git checkout degrades definition_ref to nulls'

finish
