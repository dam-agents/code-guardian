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
{"ts":"2026-07-01T06:00:00Z","trigger":"scheduled","model":"model-a","definition_version":"3.11.0","judge":"judge-x","judge_model_used":"judge-x",
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
assert_out_contains '>churn</th>' 'per-fixture tables carry the churn column'
assert_out_contains 'filter rows…' 'interactive script embedded'
assert_out_contains 'th.dataset.d' 'sort handler embedded intact'
# column help: every header explains its own value, in the HTML itself
assert_out_absent '<th>' 'no column header ships without its help text'
assert_out_contains 'title="[^"]*higher is better[^"]*">index</th>' 'the index header states the good direction'
assert_out_contains 'title="[^"]*0 is the target[^"]*">churn</th>' 'the churn header states its target value'
assert_out_contains "th.setAttribute('data-tip'" 'the script moves the help text into its own bubble'
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
assert_out_contains '>est \$</th>' 'cost column present'
assert_out_contains '\$30 <span class="d down">▲+26\.7</span>' 'run 3 priced ($30: 1.5M in + 0.3M out) with cost delta vs run 1 (same model); rising cost is the bad direction'
assert_out_contains '1330 <span class="d up">▼-10</span>' 'seconds delta compares vs run 1 (same model), not run 2; falling seconds is the good direction'
assert_out_contains '>hard</th>' 'per-fixture tables carry the recall_hard column'
assert_out_contains '<td class=n>0.5</td>' 'recall_hard value rendered'
model_b_cost="$(printf '%s' "$OUT" | grep 'model-b' | grep -c '\$' || true)"
if [ "$model_b_cost" = "0" ]; then
  printf 'ok   %s: an unpriced model renders no cost, never a guess\n' "$CASE"
else printf 'FAIL %s: model-b row must carry no $ cost\n' "$CASE"; FAILED=1; fi
rm -f "$SANDBOX/bench/results/20260901T060000Z.json" "$SANDBOX/bench-config.md"

new_case report_delta_needs_same_effort
seed_results
# model-a again, but at a recorded effort: run 1 (no effort) is no baseline for
# it; a fourth run at the same effort compares against the third
cat > "$SANDBOX/bench/results/20260901T060000Z.json" <<'EOF2'
{"ts":"2026-09-01T06:00:00Z","trigger":"scheduled","model":"model-a","effort":"low","definition_version":"3.15.0",
 "fixtures":{"ts-api":{"first":{"f1":0.5,"precision":0.6,"recall":0.4,"severity_accuracy":0.8,"fp":[],"seconds":100,"tokens":null},
   "rereview":{"fixed_recall":0.5,"still_recall":0.5,"new_recall":0.5,"false_fixed":0,"churn":0,"late_finds":0,"seconds":100,"tokens":null}}}}
EOF2
OUT="$(bash "$REPORT" "$SANDBOX/bench")"
assert_out_contains 'title="[^"]*reasoning effort[^"]*">effort</th>' 'effort column carries its help text'
assert_out_contains '<td>model-a</td><td>low</td>' 'recorded effort rendered beside the model'
row="$(printf '%s' "$OUT" | grep '<td>3.15.0</td>')"
if printf '%s' "$row" | grep -q '<td class=n>200</td>' && ! printf '%s' "$row" | grep -q 'class="d '; then
  printf 'ok   %s: a run at a new effort carries no delta against an unrecorded-effort run\n' "$CASE"
else printf 'FAIL %s: the low-effort run row must carry no delta: %.300s\n' "$CASE" "$row"; FAILED=1; fi
cat > "$SANDBOX/bench/results/20261001T060000Z.json" <<'EOF2'
{"ts":"2026-10-01T06:00:00Z","trigger":"scheduled","model":"model-a","effort":"low","definition_version":"3.16.0",
 "fixtures":{"ts-api":{"first":{"f1":0.5,"precision":0.6,"recall":0.4,"severity_accuracy":0.8,"fp":[],"seconds":150,"tokens":null},
   "rereview":{"fixed_recall":0.5,"still_recall":0.5,"new_recall":0.5,"false_fixed":0,"churn":0,"late_finds":0,"seconds":100,"tokens":null}}}}
EOF2
OUT="$(bash "$REPORT" "$SANDBOX/bench")"
assert_out_contains '250 <span class="d down">▲+50</span>' 'same model and effort: the delta compares against the previous low-effort run'
OUT="$(bash "$REPORT" index "$SANDBOX/bench")"
assert_jq '.[3].effort == "low" and .[0].effort == null' 'index mode carries effort per run'
# two runs at effort "unknown" never compare: the effort is not known to match
sed -i.bak 's/"effort":"low"/"effort":"unknown"/' "$SANDBOX/bench/results/20260901T060000Z.json" \
  "$SANDBOX/bench/results/20261001T060000Z.json"
OUT="$(bash "$REPORT" "$SANDBOX/bench")"
row="$(printf '%s' "$OUT" | grep '<td>3.16.0</td>')"
if printf '%s' "$row" | grep -q '<td class=n>250</td>' && ! printf '%s' "$row" | grep -q 'class="d '; then
  printf 'ok   %s: a run at effort unknown carries no delta, even against another unknown run\n' "$CASE"
else printf 'FAIL %s: the unknown-effort run row must carry no delta: %.300s\n' "$CASE" "$row"; FAILED=1; fi
rm -f "$SANDBOX/bench/results/"20260901T060000Z.json* "$SANDBOX/bench/results/"20261001T060000Z.json*

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
OUT="$(HOME="$FAKE_HOME" env -u CLAUDE_EFFORT -u PI_REASONING_LEVEL bash "$PROV" "$SANDBOX/bench")"
assert_jq '.definition_version == "9.9.9"' 'checked-out VERSION read'
assert_jq '.prev_version == "3.12.0"' 'prev version from the newest results file'
assert_jq '.skill_sources["doc-drift"] == "abcdef012345"' 'skill cache SHAs shortened to 12 chars'
assert_jq '.memory_sha != null' 'memory hash recorded'
assert_jq '.changes_since_prev == []' 'no git history degrades to an empty change list'
assert_jq '.definition_ref.branch == null' 'no git checkout degrades definition_ref to nulls'
assert_jq '.effort == "unknown"' 'no harness effort degrades to unknown, never null'
OUT="$(HOME="$FAKE_HOME" CLAUDE_EFFORT=medium bash "$PROV" "$SANDBOX/bench")"
assert_jq '.effort == "medium"' 'harness effort recorded'

new_case pi_usage_snapshot_sums_pi_transcripts
# pi transcripts (docs/harness-pi.md): message entries carry message.usage with
# pi's field names; an entry id is unique per file only, so a nested
# subagent's entry with the same id still counts
PSNAP="$REPO_ROOT/scripts/harness/pi/usage-snapshot.sh"
S="$FAKE_HOME/.pi/agent/sessions/--home-agent--"; mkdir -p "$S"
NONCE="pi-nonce-9"
cat > "$S/2026-10-16T09-00-00-000Z_parent.jsonl" <<EOF
{"type":"session","version":3,"id":"parent"}
{"type":"message","id":"a1","timestamp":"2026-10-16T09:00:01Z","message":{"role":"user","content":"begin $NONCE"}}
{"type":"message","id":"a2","timestamp":"2026-10-16T09:00:02Z","message":{"role":"assistant","model":"ibm/aws/claude-opus-5-5","usage":{"input":4,"output":100,"cacheRead":1000,"cacheWrite":50}}}
{"type":"message","id":"a2","timestamp":"2026-10-16T09:00:02Z","message":{"role":"assistant","model":"ibm/aws/claude-opus-5-5","usage":{"input":4,"output":100,"cacheRead":1000,"cacheWrite":50}}}
EOF
cat > "$S/2026-10-16T09-00-05-000Z_child.jsonl" <<EOF
{"type":"message","id":"a2","timestamp":"2026-10-16T09:00:06Z","message":{"role":"user","content":"Print usage-nonce:$NONCE first"}}
{"type":"message","id":"a3","timestamp":"2026-10-16T09:00:07Z","message":{"role":"assistant","model":"ibm/aws/claude-opus-5-5","usage":{"input":2,"output":30,"cacheRead":500,"cacheWrite":5}}}
EOF
OUT="$(HOME="$FAKE_HOME" TMPDIR="$SANDBOX" bash "$PSNAP" "$NONCE")"
assert_jq '.input == 6 and .output == 130 and .msgs == 2' 'pi usage summed across the session and its subagent, duplicate entries deduped'
assert_jq '.cache_read == 1500 and .cache_creation == 55 and .model == "ibm/aws/claude-opus-5-5"' 'pi cache fields and model carried'
OUT="$(HOME="$FAKE_HOME" TMPDIR="$SANDBOX" bash "$PSNAP" "no-such-nonce"; printf 'rc=%s' "$?")"
[ "$OUT" = "rc=0" ] && printf 'ok   %s: no pi transcript match prints nothing, exits 0\n' "$CASE" \
  || { printf 'FAIL %s: expected empty output rc=0, got: %s\n' "$CASE" "$OUT"; FAILED=1; }

new_case phase_uses_the_pi_snapshot_on_pi
S="$FAKE_HOME/.pi/agent/sessions/--home-agent--"; mkdir -p "$S"
printf '{"type":"message","id":"b1","timestamp":"t1","message":{"role":"user","content":"pi-phase-nonce"}}\n' > "$S/x_parent.jsonl"
PH="$REPO_ROOT/scripts/benchmark-phase.sh"
env -u CLAUDECODE PI_CODING_AGENT=true HOME="$FAKE_HOME" TMPDIR="$SANDBOX" \
  bash "$PH" begin "$SANDBOX/ph" probe pi-phase-nonce >/dev/null
printf '{"type":"message","id":"b2","timestamp":"t2","message":{"role":"assistant","usage":{"input":1,"output":40,"cacheRead":0,"cacheWrite":0}}}\n' >> "$S/x_parent.jsonl"
OUT="$(env -u CLAUDECODE PI_CODING_AGENT=true HOME="$FAKE_HOME" TMPDIR="$SANDBOX" \
  bash "$PH" end "$SANDBOX/ph" probe pi-phase-nonce)"
assert_jq '.tokens.output == 40 and .tokens.msgs == 1' 'a pi phase measures tokens from pi transcripts'

new_case provenance_on_pi
mkdir -p "$SANDBOX/bin" "$FAKE_HOME"
printf '#!/bin/sh\necho 1.1.0\n' > "$SANDBOX/bin/pi"; chmod +x "$SANDBOX/bin/pi"
OUT="$(env -u CLAUDECODE -u CLAUDE_EFFORT PI_CODING_AGENT=true PI_REASONING_LEVEL=high \
       PATH="$SANDBOX/bin:$PATH" HOME="$FAKE_HOME" bash "$PROV" "$SANDBOX/bench")"
assert_jq '.harness_version == "pi 1.1.0" and .effort == "high"' 'pi version and thinking level recorded'

new_case report_delta_needs_same_harness
# the same model and effort on another harness is no baseline
mkdir -p "$SANDBOX/bench/results"
cat > "$SANDBOX/bench/results/20260901T060000Z.json" <<'EOF'
{"ts":"2026-09-01T06:00:00Z","trigger":"scheduled","model":"model-a","effort":"medium","definition_version":"9.0.0",
 "harness_version":"2.1.284 (Claude Code)",
 "fixtures":{"ts-api":{"first":{"f1":0.5,"precision":0.5,"recall":0.5,"severity_accuracy":1,"fp":[],"length":{"words_total":500},"seconds":100,"tokens":null,"judge":null},
   "rereview":{"fixed_recall":1,"still_recall":1,"new_recall":1,"false_fixed":0,"churn":0,"late_finds":0,"seconds":100,"tokens":null}}}}
EOF
sed -e 's/2026-09-01T06/2026-10-01T06/' -e 's/2.1.284 (Claude Code)/pi 1.1.0/' -e 's/9.0.0/9.0.1/' \
    -e 's/"seconds":100/"seconds":300/g' \
  "$SANDBOX/bench/results/20260901T060000Z.json" > "$SANDBOX/bench/results/20261001T060000Z.json"
sed -e 's/2026-09-01T06/2026-10-02T06/' -e 's/9.0.0/9.0.2/' -e 's/"seconds":100/"seconds":300/g' \
  "$SANDBOX/bench/results/20260901T060000Z.json" > "$SANDBOX/bench/results/20261002T060000Z.json"
OUT="$(bash "$REPORT" "$SANDBOX/bench")"
row="$(printf '%s' "$OUT" | grep '<td>9.0.1</td>')"
if [ -n "$row" ] && ! printf '%s' "$row" | grep -q 'class="d '; then
  printf 'ok   %s: a pi run carries no delta against a Claude Code run\n' "$CASE"
else printf 'FAIL %s: the pi run row must carry no delta: %.300s\n' "$CASE" "$row"; FAILED=1; fi
row="$(printf '%s' "$OUT" | grep '<td>9.0.2</td>')"
if printf '%s' "$row" | grep -q 'class="d '; then
  printf 'ok   %s: the next Claude Code run compares against the Claude Code run, past the pi one\n' "$CASE"
else printf 'FAIL %s: the Claude Code run row must carry a delta: %.300s\n' "$CASE" "$row"; FAILED=1; fi

new_case pi_subagents_run_every_prompt
SUB="$REPO_ROOT/scripts/harness/pi/subagents.sh"
mkdir -p "$SANDBOX/bin" "$SANDBOX/p"
cat > "$SANDBOX/bin/pi" <<'EOF'
#!/bin/sh
# stub: echo the flags, the session id it sees and the prompt; fail on "FAIL"
printf 'args=%s sid=%s\n' "$*" "${PI_SESSION_ID:-none}"
case "$*" in (*FAIL*) exit 3;; esac
EOF
chmod +x "$SANDBOX/bin/pi"
printf 'review skill a\n' > "$SANDBOX/p/a.prompt"; printf 'FAIL here\n' > "$SANDBOX/p/b.prompt"
OUT="$(PATH="$SANDBOX/bin:$PATH" HOME="$FAKE_HOME" PI_SESSION_ID=parent PI_PROVIDER=platform \
       PI_MODEL=ibm/m PI_REASONING_LEVEL=low bash "$SUB" "$SANDBOX/p" | jq -sc 'sort_by(.name)')"
assert_jq '.[0].name == "a" and .[0].exit == 0 and .[1].name == "b" and .[1].exit == 3' 'one line per prompt with its exit'
REPLY="$(cat "$SANDBOX/p/a.reply")"
case "$REPLY" in
  (*"--provider platform --model ibm/m --thinking low"*"review skill a"*"sid=none"*)
    printf 'ok   %s: session model and thinking passed, own session id, prompt delivered\n' "$CASE" ;;
  (*) printf 'FAIL %s: unexpected nested call: %s\n' "$CASE" "$REPLY"; FAILED=1 ;;
esac
OUT="$(PATH="$SANDBOX/bin:$PATH" bash "$SUB" "$SANDBOX/none" 2>/dev/null; printf 'rc=%s' "$?")"
[ "$OUT" = "rc=2" ] && printf 'ok   %s: a missing prompt dir is a usage error\n' "$CASE" \
  || { printf 'FAIL %s: expected rc=2, got %s\n' "$CASE" "$OUT"; FAILED=1; }

new_case review_window_reads_pi
WIN="$REPO_ROOT/scripts/harness/claude-code/review-window.jq"
cat > "$SANDBOX/pi.jsonl" <<'EOF'
{"type":"message","id":"u0","timestamp":"2026-10-16T08:59:00.000Z","message":{"role":"assistant","usage":{"input":1,"output":1,"cacheRead":900000,"cacheWrite":0},"content":[]}}
{"type":"message","id":"u1","timestamp":"2026-10-16T09:00:01.000Z","message":{"role":"assistant","usage":{"input":10,"output":5,"cacheRead":1000,"cacheWrite":90},"content":[{"type":"toolCall","name":"bash","arguments":{"command":"ls"}},{"type":"toolCall","name":"bash","arguments":{"command":"ls"}}]}}
{"type":"message","id":"r1","timestamp":"2026-10-16T09:00:02.000Z","message":{"role":"toolResult","toolName":"bash","content":[{"type":"text","text":"abcdefghij"}]}}
EOF
OUT="$(jq -nR --arg since 2026-10-16T09:00:00Z -f "$WIN" "$SANDBOX/pi.jsonl")"
assert_jq '.peak_ctx == 1100 and .repeats == 2 and .repeat_tool == "bash" and .max_out == 10' 'the review window reads pi entries from its start on'

new_case pi_subagents_layout_and_skill_step
SUB="$REPO_ROOT/scripts/harness/pi/subagents.sh"
mkdir -p "$SANDBOX/bin" "$SANDBOX/p" "$WORK/logs"
cat > "$SANDBOX/bin/pi" <<'EOF'
#!/bin/sh
printf 'args=%s parent=%s\n' "$*" "${CG_PI_PARENT_SESSION:-none}"
EOF
chmod +x "$SANDBOX/bin/pi"
cat > "$WORK/CONFIG.md" <<'EOF'
- github_repo: acme/widgets

## Review skills

| skill | source | trigger | section |
|-------|--------|---------|---------|
| issue-fit | harness | always | Issue fit |
EOF
printf 'Review skill `issue-fit` for PR #42: read `/tmp/brief.md` and follow it exactly.\n' > "$SANDBOX/p/issue-fit.prompt"
PATH="$SANDBOX/bin:$PATH" HOME="$FAKE_HOME" WORK_DIR="$WORK" PI_SESSION_ID=parent-1 \
  PI_SESSION_FILE="$SANDBOX/sessions/2026_parent-1.jsonl" bash "$SUB" "$SANDBOX/p" >/dev/null
case "$(cat "$SANDBOX/p/issue-fit.reply")" in
  (*"--session-dir $SANDBOX/sessions/2026_parent-1/subagents"*"parent=parent-1"*)
    printf 'ok   %s: nested session under <session>/subagents, parent run named\n' "$CASE" ;;
  (*) printf 'FAIL %s: unexpected nested call: %s\n' "$CASE" "$(cat "$SANDBOX/p/issue-fit.reply")"; FAILED=1 ;;
esac
if cat "$WORK"/logs/events-*.jsonl 2>/dev/null | jq -e 'select(.event == "review_step" and .run == "parent-1" and .msg == "PR #42 skill:issue-fit done")' >/dev/null; then
  printf 'ok   %s: an ended skill subagent logs skill:<name> done under the parent run\n' "$CASE"
else printf 'FAIL %s: no skill step: %s\n' "$CASE" "$(cat "$WORK"/logs/events-*.jsonl 2>/dev/null)"; FAILED=1; fi

new_case pi_install_links_the_extension
PI_INST="$REPO_ROOT/scripts/harness/pi/install.sh"
mkdir -p "$FAKE_HOME/.pi/agent"
OUT="$(HOME="$FAKE_HOME" bash "$PI_INST" --check)"
[ "$OUT" = "pi-extension" ] && printf 'ok   %s: a missing link is named\n' "$CASE" \
  || { printf 'FAIL %s: expected pi-extension, got %s\n' "$CASE" "$OUT"; FAILED=1; }
HOME="$FAKE_HOME" bash "$PI_INST" >/dev/null
if [ "$(readlink "$FAKE_HOME/.pi/agent/extensions/code-guardian.ts")" = "$REPO_ROOT/scripts/harness/pi/extension.ts" ] \
   && [ -z "$(HOME="$FAKE_HOME" bash "$PI_INST" --check)" ]; then
  printf 'ok   %s: install links the extension and the check goes quiet\n' "$CASE"
else printf 'FAIL %s: link not current\n' "$CASE"; FAILED=1; fi
rm -rf "$FAKE_HOME/.pi"
OUT="$(PATH="/usr/bin:/bin" HOME="$FAKE_HOME" bash "$PI_INST" --check; printf 'rc=%s' "$?")"
[ "$OUT" = "rc=0" ] && printf 'ok   %s: without pi the check is silent\n' "$CASE" \
  || { printf 'FAIL %s: expected silence, got %s\n' "$CASE" "$OUT"; FAILED=1; }

new_case reviewer_brief_placeholders_documented
# every placeholder of the reviewer brief has its documented value, so the
# rendered prompt never ships a literal {{...}}
TPL="$REPO_ROOT/scripts/templates/reviewer-brief.md"
missing=""; stray=""
DOC="$(tr '\n' ' ' < "$REPO_ROOT/docs/benchmark.md" | tr -s ' ')"
for ph in $(grep -o '{{[A-Z_]*}}' "$TPL" | sort -u); do
  printf '%s' "$DOC" | grep -qF "\`$ph\` = " || missing="$missing $ph"
done
for ph in $(grep -o '{{[A-Z_]*}}' "$REPO_ROOT/docs/benchmark.md" | sort -u); do
  grep -qF "$ph" "$TPL" || stray="$stray $ph"
done
if [ -n "$(grep -o '{{[A-Z_]*}}' "$TPL")" ] && [ -z "$missing" ] && [ -z "$stray" ]; then
  printf 'ok   %s: every reviewer-brief placeholder has its value in benchmark.md, and no other\n' "$CASE"
else printf 'FAIL %s: placeholders without a value:%s; not in the template:%s\n' "$CASE" "$missing" "$stray"; FAILED=1; fi

finish
