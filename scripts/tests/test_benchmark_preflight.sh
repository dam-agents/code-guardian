#!/usr/bin/env bash
# preflight benchmark mode — gate on `benchmark: enabled`, create_fixture until
# the set holds 5 fixtures, run with the monthly (27-day) gate, purely local
# (no gh fixtures are seeded: the mode must decide without API calls).
. "$(dirname "$0")/helpers.sh"

seed_fixture() { # <slug>
  mkdir -p "$WORK/benchmark/fixture/$1"
  printf '{"fixture":"%s","defects":[]}' "$1" > "$WORK/benchmark/fixture/$1/manifest.json"
}

seed_full_set() { for s in ts-api react-ui py-cli infra-ci docs-mixed; do seed_fixture "$s"; done; }

seed_result_row() { # <iso-ts>
  mkdir -p "$WORK/benchmark"
  {
    printf '# Benchmark results\n\n'
    printf '| ts | model | version | fixture | trigger | f1 | sev | fixed | new | words | sec | out-tok |\n'
    printf '|----|-------|---------|---------|---------|----|-----|-------|-----|-------|-----|---------|\n'
    printf '| %s | m | 3.11.0 | ts-api | scheduled | 0.8 | 1 | 1 | 1 | 900 | 500 | 21000 |\n' "$1"
  } > "$WORK/benchmark/RESULTS.md"
}

new_case benchmark_disabled
base_config
run_preflight benchmark
assert_jq '.nothing_to_do == true' 'missing key gates the run off'
assert_jq 'has("benchmark_due") | not' 'no worklist entry when disabled'
assert_jq '.logs | any(contains("benchmark disabled"))' 'the off state is logged'

new_case benchmark_no_fixtures
base_config '- benchmark: enabled'
run_preflight benchmark
assert_jq '.nothing_to_do == false' 'enabled with no fixtures is work'
assert_jq '.benchmark_due.action == "create_fixture"' 'create_fixture is due'
assert_jq '.benchmark_due.existing == [] and .benchmark_due.min == 5' 'empty set, target size named'

new_case benchmark_partial_set
base_config '- benchmark: enabled'
seed_fixture ts-api
seed_fixture react-ui
seed_fixture py-cli
mkdir -p "$WORK/benchmark/fixture/broken"   # no manifest — not part of the set
run_preflight benchmark
assert_jq '.benchmark_due.action == "create_fixture"' 'an incomplete set asks for a top-up'
assert_jq '.benchmark_due.existing | length == 3' 'manifest-less directories are not counted'

new_case benchmark_run_due
base_config '- benchmark: enabled' '- benchmark_judge: pinned-judge-model' '- benchmark_report: gist,dam'
seed_full_set
run_preflight benchmark
assert_jq '.benchmark_due.action == "run"' 'a full set makes a run due'
assert_jq '.benchmark_due.fixtures | length == 5' 'all five fixtures are carried'
assert_jq '.benchmark_due.judge == "pinned-judge-model"' 'judge key is carried'
assert_jq '.benchmark_due.report == "gist,dam"' 'report surfaces are carried'
assert_jq '.benchmark_due.last_run == null' 'no prior run recorded'

new_case benchmark_defaults
base_config '- benchmark: enabled'
seed_full_set
run_preflight benchmark
assert_jq '.benchmark_due.judge == "off"' 'judge defaults to off'
assert_jq '.benchmark_due.report == "gist"' 'report defaults to gist'

new_case benchmark_monthly_gate_holds
base_config '- benchmark: enabled'
seed_full_set
seed_result_row "$(iso_ago 432000)"   # 5 days ago — inside the 27-day floor
run_preflight benchmark
assert_jq '.nothing_to_do == true' 'a recent run gates the month'
assert_jq 'has("benchmark_due") | not' 'no worklist entry while gated'

new_case benchmark_monthly_gate_opens
base_config '- benchmark: enabled'
seed_full_set
seed_result_row "$(iso_ago 2592000)"  # 30 days ago — past the floor
run_preflight benchmark
assert_jq '.benchmark_due.action == "run"' 'a stale last run re-opens the gate'
assert_jq '.benchmark_due.last_run != null' 'the last run timestamp is carried'

finish
