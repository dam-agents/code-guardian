#!/usr/bin/env bash
# benchmark helpers — the accumulated-report generator (benchmark-report.sh),
# the token usage snapshot (usage-snapshot.sh), and the provenance emitter
# (benchmark-provenance.sh). Pure local: no gh.
. "$(dirname "$0")/helpers.sh"

REPORT="$REPO_ROOT/scripts/benchmark-report.sh"
SNAP="$REPO_ROOT/scripts/harness/claude-code/usage-snapshot.sh"
PROV="$REPO_ROOT/scripts/benchmark-provenance.sh"
# a live pod/dev CONFIG.md must never leak prices into these cases; the
# price-table case overrides this per call
export BENCH_CONFIG=/dev/null

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
assert_out_contains '<td class="n idx"><b>0.769</b><span class=bar style="width:77%"></span></td>' 'run 1 quality index is the baseline (no delta), bar width tracks the value'
assert_out_contains '<td class="n idx"><b>0.944</b><span class=bar style="width:94%"></span></td>' 'run 2 (a different model) carries NO cross-model delta'
assert_out_absent '0\.944<span class="d ' 'deltas never compare across models'
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

new_case report_same_model_delta_and_cost
seed_results
# a third run repeats model-a: its deltas compare against run 1, skipping the
# model-b run in between; prices enable the est $ column for model-a only
cat > "$SANDBOX/bench/results/20260901T060000Z.json" <<'EOF'
{"ts":"2026-09-01T06:00:00Z","trigger":"scheduled","model":"model-a","definition_version":"3.15.0",
 "fixtures":{"ts-api":{"first":{"f1":0.8,"precision":0.85,"recall":0.75,"recall_hard":0.5,"severity_accuracy":0.9,"fp":[{"f":1}],"length":{"words_total":800},"seconds":400,"tokens":{"input":1000000,"output":200000,"cache_read":0,"cache_creation":0,"msgs":40},"judge":null},
   "rereview":{"fixed_recall":0.8,"still_recall":1,"new_recall":0.7,"false_fixed":0,"churn":0,"late_finds":1,"seconds":300,"tokens":{"input":500000,"output":100000,"cache_read":0,"cache_creation":0,"msgs":20}}},
  "react-ui":{"first":{"f1":0.6,"precision":0.7,"recall":0.55,"severity_accuracy":0.85,"fp":[],"length":{"words_total":700},"seconds":380,"tokens":null,"judge":null},
   "rereview":{"fixed_recall":1,"still_recall":0.5,"new_recall":0.5,"false_fixed":1,"churn":0,"late_finds":0,"seconds":250,"tokens":null}}}}
EOF
cat > "$SANDBOX/bench-config.md" <<'EOF'
## Benchmark model prices

| model substring | input | output | cache_read | cache_write |
|---|---|---|---|---|
| model-a | 10 | 50 | 1 | 12.5 |
EOF
OUT="$(BENCH_CONFIG="$SANDBOX/bench-config.md" bash "$REPORT" "$SANDBOX/bench")"
assert_out_contains '<th>est \$</th>' 'cost column present'
assert_out_contains '\$30 <span class="d down">▲+26\.7</span>' 'run 3 priced ($30: 1.5M in + 0.3M out) with cost delta vs run 1 (same model); rising cost is the bad direction'
assert_out_contains '1330 <span class="d up">▼-10</span>' 'seconds delta compares vs run 1 (same model), not run 2; falling seconds is the good direction'
assert_out_contains '<th>hard</th>' 'per-fixture tables carry the recall_hard column'
assert_out_contains '<td class=n>0.5</td>' 'recall_hard value rendered'
model_b_cost="$(printf '%s' "$OUT" | grep 'model-b' | grep -c '\$' || true)"
if [ "$model_b_cost" = "0" ]; then
  printf 'ok   %s: an unpriced model renders no cost, never a guess\n' "$CASE"
else printf 'FAIL %s: model-b row must carry no $ cost\n' "$CASE"; FAILED=1; fi
rm -f "$SANDBOX/bench/results/20260901T060000Z.json" "$SANDBOX/bench-config.md"

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

new_case usage_snapshot_sums_subagent_transcripts
# a subagent transcript carrying the nonce (its prompt includes it) appears
# AFTER the first snapshot resolved — the delegated-review case: the set of
# matching transcripts grows mid-run, and the sum must grow with it
mkdir -p "$FAKE_HOME/.claude/projects/p1"
NONCE="bench-delegated-nonce-7"
cat > "$FAKE_HOME/.claude/projects/p1/session.jsonl" <<EOF
{"type":"user","message":{"content":"usage-nonce:$NONCE"}}
{"type":"assistant","message":{"id":"m1","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":1000,"cache_creation_input_tokens":10}}}
EOF
OUT="$(HOME="$FAKE_HOME" TMPDIR="$SANDBOX" bash "$SNAP" "$NONCE")"
assert_jq '.output == 50 and .msgs == 1' 'baseline snapshot sees the session transcript only'
cat > "$FAKE_HOME/.claude/projects/p1/subagent.jsonl" <<EOF
{"type":"user","message":{"content":"print usage-nonce:$NONCE first, then review"}}
{"type":"assistant","message":{"id":"s1","usage":{"input_tokens":5000,"output_tokens":900,"cache_read_input_tokens":20000,"cache_creation_input_tokens":300}}}
EOF
OUT="$(HOME="$FAKE_HOME" TMPDIR="$SANDBOX" bash "$SNAP" "$NONCE")"
assert_jq '.input == 5100 and .output == 950 and .msgs == 2' 'a late subagent transcript joins the sum despite the cache'
assert_jq '.cache_read == 21000 and .cache_creation == 310' 'subagent cache usage counted'
if [ "$(grep -c . "$SANDBOX/.bench-usage-$NONCE")" = "2" ]; then
  printf 'ok   %s: cache now unions both transcripts\n' "$CASE"
else printf 'FAIL %s: cache should list 2 transcripts\n' "$CASE"; FAILED=1; fi

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
