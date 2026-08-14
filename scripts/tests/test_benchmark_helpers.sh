#!/usr/bin/env bash
# benchmark helpers — the accumulated-report generator (benchmark-report.sh)
# and the token usage snapshot (usage-snapshot.sh). Pure local: no gh.
. "$(dirname "$0")/helpers.sh"

REPORT="$REPO_ROOT/scripts/benchmark-report.sh"
SNAP="$REPO_ROOT/scripts/harness/claude-code/usage-snapshot.sh"

new_case report_accumulates_runs
mkdir -p "$SANDBOX/bench/results"
cat > "$SANDBOX/bench/results/20260701T060000Z.json" <<'EOF'
{"ts":"2026-07-01T06:00:00Z","trigger":"scheduled","model":"model-a","definition_version":"3.11.0",
 "fixtures":{"ts-api":{"first":{"f1":0.72,"precision":0.8,"recall":0.65,"severity_accuracy":0.9,"fp":[{"f":1}],"length":{"words_total":820},"seconds":410,"tokens":{"output":21000},"judge":{"finding_accuracy":4}},
   "rereview":{"fixed_recall":0.8,"new_recall":0.7,"false_fixed":0,"late_finds":1,"seconds":300,"tokens":{"output":15000}}},
  "react-ui":{"first":{"f1":0.6,"precision":0.7,"recall":0.55,"severity_accuracy":0.85,"fp":[],"length":{"words_total":700},"seconds":380,"tokens":{"output":18000},"judge":{"finding_accuracy":3}},
   "rereview":{"fixed_recall":1,"new_recall":0.5,"false_fixed":1,"late_finds":0,"seconds":250,"tokens":{"output":12000}}}}}
EOF
cat > "$SANDBOX/bench/results/20260801T060000Z.json" <<'EOF'
{"ts":"2026-08-01T06:00:00Z","trigger":"manual","model":"model-b","definition_version":"3.12.0",
 "harness_version":"2.1.34 (Claude Code)","prev_version":"3.11.0",
 "changes_since_prev":["feat(review): sibling sweep for warning-class defects (v3.12.0)","fix(shepherd): cooldown off-by-one (v3.11.1)"],
 "fixtures":{"ts-api":{"first":{"f1":0.85,"precision":0.9,"recall":0.81,"severity_accuracy":1,"fp":[],"length":{"words_total":640},"seconds":300,"tokens":null,"judge":null},
   "rereview":{"fixed_recall":1,"new_recall":0.9,"false_fixed":0,"late_finds":0,"seconds":200,"tokens":null}}}}
EOF
OUT="$(bash "$REPORT" "$SANDBOX/bench")"
assert_jq_out() { :; }   # (report is HTML — assert with grep below)
if printf '%s' "$OUT" | grep -q '2 run(s) on record'; then
  printf 'ok   %s: both runs counted\n' "$CASE"
else printf 'FAIL %s: run count missing\n' "$CASE"; FAILED=1; fi
if printf '%s' "$OUT" | grep -q '<td class=n>0.66</td>'; then
  printf 'ok   %s: run 1 avg f1 across fixtures\n' "$CASE"
else printf 'FAIL %s: run 1 avg f1 wrong\n' "$CASE"; FAILED=1; fi
if printf '%s' "$OUT" | grep -q '<td class=n>66000</td>'; then
  printf 'ok   %s: run 1 output tokens summed\n' "$CASE"
else printf 'FAIL %s: token sum wrong\n' "$CASE"; FAILED=1; fi
if [ "$(printf '%s' "$OUT" | grep -c '<h2>')" = "4" ]; then
  printf 'ok   %s: all-runs table + version changes + one section per fixture\n' "$CASE"
else printf 'FAIL %s: section count wrong\n' "$CASE"; FAILED=1; fi
if printf '%s' "$OUT" | grep -q 'Latest run: 2026-08-01T06:00:00Z'; then
  printf 'ok   %s: latest run named\n' "$CASE"
else printf 'FAIL %s: latest run missing\n' "$CASE"; FAILED=1; fi
missing_tok_row="$(printf '%s' "$OUT" | grep -A1 'model-b' | grep -c '—' || true)"
if [ "$missing_tok_row" -ge 1 ]; then
  printf 'ok   %s: unmeasured tokens render as dashes\n' "$CASE"
else printf 'FAIL %s: missing-token rendering\n' "$CASE"; FAILED=1; fi
if printf '%s' "$OUT" | grep -q '<td>2.1.34 (Claude Code)</td>'; then
  printf 'ok   %s: harness version column rendered\n' "$CASE"
else printf 'FAIL %s: harness version missing\n' "$CASE"; FAILED=1; fi
if printf '%s' "$OUT" | grep -q '<h3>3.12.0 — tested 2026-08-01T06:00:00Z (since 3.11.0)</h3>'; then
  printf 'ok   %s: version-change block names versions and run\n' "$CASE"
else printf 'FAIL %s: version-change heading missing\n' "$CASE"; FAILED=1; fi
if [ "$(printf '%s' "$OUT" | grep -o '<li>' | grep -c '')" = "2" ]; then
  printf 'ok   %s: release-commit subjects listed as bullets\n' "$CASE"
else printf 'FAIL %s: changes bullet list wrong\n' "$CASE"; FAILED=1; fi

new_case report_empty_results
mkdir -p "$SANDBOX/empty/results"
OUT="$(bash "$REPORT" "$SANDBOX/empty")"
if printf '%s' "$OUT" | grep -q '0 run(s) on record'; then
  printf 'ok   %s: empty history renders a valid page\n' "$CASE"
else printf 'FAIL %s: empty history broke the page\n' "$CASE"; FAILED=1; fi

new_case usage_snapshot_sums_own_transcript
mkdir -p "$FAKE_HOME/.claude/projects/p1"
NONCE="bench-test-nonce-42"
cat > "$FAKE_HOME/.claude/projects/p1/session.jsonl" <<EOF
{"type":"user","message":{"content":"run $NONCE please"}}
{"type":"assistant","message":{"id":"m1","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":1000,"cache_creation_input_tokens":10}}}
{"type":"assistant","message":{"id":"m1","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":1000,"cache_creation_input_tokens":10}}}
{"type":"assistant","message":{"id":"m2","usage":{"input_tokens":200,"output_tokens":75}}}
EOF
cat > "$FAKE_HOME/.claude/projects/p1/other.jsonl" <<'EOF'
{"type":"assistant","message":{"id":"x1","usage":{"input_tokens":9999,"output_tokens":9999}}}
EOF
OUT="$(HOME="$FAKE_HOME" bash "$SNAP" "$NONCE")"
assert_jq '.input == 300 and .output == 125 and .msgs == 2' 'usage summed, duplicate message ids deduped'
assert_jq '.cache_read == 1000 and .cache_creation == 10' 'cache fields carried'

new_case usage_snapshot_no_match
OUT="$(HOME="$FAKE_HOME" bash "$SNAP" "no-such-nonce-anywhere"; printf 'rc=%s' "$?")"
if [ "$OUT" = "rc=0" ]; then
  printf 'ok   %s: no transcript match prints nothing, exits 0\n' "$CASE"
else printf 'FAIL %s: expected empty output rc=0, got: %s\n' "$CASE" "$OUT"; FAILED=1; fi

finish
