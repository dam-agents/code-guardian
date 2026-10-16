#!/usr/bin/env bash
# benchmark-judge.sh — the pinned judge call, its model check and its reply
# parsing — and the two readers that trust only its output: the results
# validator (judge_pinned) and the report's judge columns. The claude CLI is a
# stub that prints a canned reply. Pure local: no gh.
. "$(dirname "$0")/helpers.sh"

JUDGE="$REPO_ROOT/scripts/benchmark-judge.sh"
VALIDATE="$REPO_ROOT/scripts/benchmark-validate.sh"
REPORT="$REPO_ROOT/scripts/benchmark-report.sh"
export BENCH_CONFIG=/dev/null

# fake claude: records its argv and stdin, prints $FAKE_REPLY
seed_cli() { # <reply json>
  mkdir -p "$SANDBOX/cli" "$SANDBOX/in"
  printf '%s' "$1" > "$SANDBOX/cli/reply.json"
  cat > "$SANDBOX/cli/claude" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$SANDBOX/cli/argv"
cat > "$SANDBOX/cli/stdin"
cp "\$(sed -n '/--system-prompt-file/{n;p;}' "$SANDBOX/cli/argv")" "$SANDBOX/cli/brief" 2>/dev/null
cat "$SANDBOX/cli/reply.json"
STUB
  chmod +x "$SANDBOX/cli/claude"
  export CG_JUDGE_CLI="$SANDBOX/cli/claude"
  printf -- '- 🔴 **Critical:** token compared with ==\n' > "$SANDBOX/in/review.md"
  printf '{"defects":[]}\n' > "$SANDBOX/in/manifest.json"
  printf '{"tp":[],"fp":[],"fn":[],"churn":0}\n' > "$SANDBOX/in/scorer.json"
  printf 'prior review text\n' > "$SANDBOX/in/prior.md"
}
reply() { # <model> <result text>
  jq -cn --arg m "$1" --arg r "$2" '{type:"result", is_error:false, result:$r,
    usage:{input_tokens:900, output_tokens:120, cache_read_input_tokens:0, cache_creation_input_tokens:0},
    modelUsage:{($m):{}}}'
}
SIX='{"finding_accuracy":4,"category_accuracy":5,"fix_quality":3,"fp_defensibility":5,"clarity":4,"language":4,"notes":"fix too narrow"}'
run_first() { OUT="$(bash "$JUDGE" first "$1" "$SANDBOX/in/review.md" "$SANDBOX/in/manifest.json" "$SANDBOX/in/scorer.json")"; }

new_case judge_ok_pins_model_and_isolates_the_call
seed_cli "$(reply claude-opus-5-20260401 "$SIX")"
run_first claude-opus-5
assert_jq '.status == "ok" and .judge.fix_quality == 3 and .judge.notes == "fix too narrow"' 'scores parsed'
assert_jq '.judge_model_used == "claude-opus-5-20260401"' 'the model comes from modelUsage, not from the reply text'
assert_jq '.tokens.input == 900 and .tokens.output == 120' 'judge tokens reported'
OUT="$(cat "$SANDBOX/cli/argv")"
assert_out_contains '^claude-opus-5$' 'the pinned model is passed with --model'
assert_out_contains '^--strict-mcp-config$' 'no MCP servers'
assert_out_contains 'disableAllHooks' 'no hooks'
assert_out_contains '^--no-session-persistence$' 'no saved session'
OUT="$(cat "$SANDBOX/cli/stdin")"
assert_out_contains '^## MANIFEST' 'manifest reaches the judge'
assert_out_absent 'PRIOR REVIEW' 'a first review gets no prior review'
OUT="$(cat "$SANDBOX/cli/brief")"
assert_out_absent 'loop_risk|\{\{' 'first brief: no loop_risk, no placeholder left'

new_case judge_rereview_needs_loop_risk
seed_cli "$(reply claude-opus-5 "$SIX")"
OUT="$(bash "$JUDGE" rereview claude-opus-5 "$SANDBOX/in/review.md" "$SANDBOX/in/manifest.json" "$SANDBOX/in/scorer.json" "$SANDBOX/in/prior.md")"
assert_jq '.status == "failed" and .judge == null' 'a re-review reply without loop_risk is refused'
OUT="$(cat "$SANDBOX/cli/brief")"
assert_out_contains '"loop_risk": 0' 'rereview brief asks for loop_risk'
seed_cli "$(reply claude-opus-5 "$(printf '%s' "$SIX" | jq -c '. + {loop_risk: 5}')")"
OUT="$(bash "$JUDGE" rereview claude-opus-5 "$SANDBOX/in/review.md" "$SANDBOX/in/manifest.json" "$SANDBOX/in/scorer.json" "$SANDBOX/in/prior.md")"
assert_jq '.status == "ok" and .judge.loop_risk == 5' 'loop_risk kept'
OUT="$(cat "$SANDBOX/cli/stdin")"
assert_out_contains '^## PRIOR REVIEW' 'prior review reaches the judge'

new_case judge_wrong_model_is_a_mismatch
seed_cli "$(reply claude-opus-5-5 "$SIX")"
run_first claude-opus-5
assert_jq '.status == "mismatch" and .judge == null and .judge_model_used == "claude-opus-5-5"' 'claude-opus-5-5 never passes for claude-opus-5'

new_case judge_reply_shapes
seed_cli "$(reply claude-opus-5 "Here you go: \`\`\`json
$SIX
\`\`\`")"
run_first claude-opus-5
assert_jq '.status == "ok" and .judge.clarity == 4' 'a fenced object is cut out'
seed_cli "$(reply claude-opus-5 "Scores — here: \`\`\`json
$(printf '%s' "$SIX" | jq -c '.notes = "fix too narrow — 🔴 one line"')
\`\`\`")"
run_first claude-opus-5
assert_jq '.status == "ok" and .judge.notes == "fix too narrow — 🔴 one line"' 'a fenced object with non-ASCII text is cut out on code points'
seed_cli "$(reply claude-opus-5 "$(printf '%s' "$SIX" | jq -c '.clarity = 7')")"
run_first claude-opus-5
assert_jq '.status == "failed" and .judge == null' 'a score outside 1-5 is refused'
seed_cli "$(reply claude-opus-5 "$(printf '%s' "$SIX" | jq -c '.clarity = 3.5')")"
run_first claude-opus-5
assert_jq '.status == "failed"' 'a non-integer score is refused'
seed_cli '{"type":"result","is_error":true,"result":"There is an issue with the selected model","usage":{},"modelUsage":{}}'
run_first claude-opus-5
assert_jq '.status == "failed" and (.reason | test("selected model"))' 'a CLI error is reported'
seed_cli 'not json'
run_first claude-opus-5
assert_jq '.status == "failed" and .judge == null' 'a non-JSON reply is refused'

new_case judge_off_and_unavailable
seed_cli "$(reply claude-opus-5 "$SIX")"
run_first off
assert_jq '.status == "off" and .judge == null' 'off runs nothing'
CG_JUDGE_CLI="$SANDBOX/nope" run_first claude-opus-5
assert_jq '.status == "unavailable" and .judge == null' 'no CLI is unavailable, never a fallback'
OUT="$(bash "$JUDGE" first claude-opus-5 /nonexistent "$SANDBOX/in/manifest.json" "$SANDBOX/in/scorer.json" 2>&1; printf 'rc=%s' "$?")"
assert_out_contains 'rc=2' 'missing input is a usage error'

# results validator: judge scores need the pinned judge
results() { # <judge> <judge_model_used|null> <first judge json>
  jq -n --arg j "$1" --argjson u "$2" --argjson fj "$3" '{ts:"2026-10-16T06:00:00Z", trigger:"manual",
    model:"glm-5-3", effort:"medium", definition_version:"9.7.0", judge:$j, judge_model_used:$u,
    fixtures:{"ts-api":{first:{fp:[], seconds:1, tokens:null, judge:$fj},
                        rereview:{churn:0, seconds:1, tokens:null, judge:null}}}}'
}
new_case validate_judge_pinned
mkdir -p "$SANDBOX/r"
results claude-opus-5 '"glm-5-3"' "$SIX" > "$SANDBOX/r/self.json"
OUT="$(bash "$VALIDATE" results "$SANDBOX/r/self.json"; printf 'rc=%s' "$?")"
assert_out_contains 'FAIL judge_pinned: judge is claude-opus-5, but glm-5-3 scored' 'a self-judged run is rejected'
assert_out_contains 'rc=1' 'and stops the run'
results claude-opus-5 null "$SIX" > "$SANDBOX/r/nouse.json"
OUT="$(bash "$VALIDATE" results "$SANDBOX/r/nouse.json")"
assert_out_contains 'FAIL judge_pinned: .*judge_model_used is missing' 'scores without judge_model_used are rejected'
results claude-opus-5 '"claude-opus-5-20260401"' "$SIX" > "$SANDBOX/r/ok.json"
OUT="$(bash "$VALIDATE" results "$SANDBOX/r/ok.json"; printf 'rc=%s' "$?")"
assert_out_contains 'ok   judge_pinned' 'the pinned judge passes'
assert_out_contains 'rc=0' 'clean'
results off null null > "$SANDBOX/r/off.json"
OUT="$(bash "$VALIDATE" results "$SANDBOX/r/off.json"; printf 'rc=%s' "$?")"
assert_out_contains 'rc=0' 'no judge, no scores: clean'

# report: judge cells only from a pinned judge
new_case report_hides_self_judged_scores
mkdir -p "$SANDBOX/bench/results"
results claude-opus-5 '"claude-opus-5"' "$SIX" > "$SANDBOX/bench/results/a.json"
results claude-opus-5 '"glm-5-3"' "$(printf '%s' "$SIX" | jq -c 'with_entries(if .key == "notes" then . else .value = 3 end)')" \
  | jq '.ts = "2026-10-17T06:00:00Z"' > "$SANDBOX/bench/results/b.json"
OUT="$(bash "$REPORT" "$SANDBOX/bench")"
assert_out_contains '<td class=n>4.167</td>' 'the pinned run shows its judge average'
assert_out_absent '<td class=n>3</td>' 'the self-judged scores never render'
assert_out_contains 'a run that its own tested model judged shows a dash' 'the header says why'

finish
