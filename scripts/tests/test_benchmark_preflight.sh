#!/usr/bin/env bash
# preflight benchmark mode — gate on `benchmark: enabled`, create_fixture when
# no fixture exists, run with the monthly (27-day) gate, purely local (no gh
# fixtures are seeded: the mode must decide without API calls).
. "$(dirname "$0")/helpers.sh"

seed_fixture() { # <id>
  mkdir -p "$WORK/benchmark/fixture/$1"
  printf '{"fixture":"%s","defects":[]}' "$1" > "$WORK/benchmark/fixture/$1/manifest.json"
}

seed_result_row() { # <iso-ts>
  mkdir -p "$WORK/benchmark"
  {
    printf '# Benchmark results\n\n'
    printf '| ts | model | version | fixture | trigger | f1 | sev | fixed | new | words |\n'
    printf '|----|-------|---------|---------|---------|----|-----|-------|-----|-------|\n'
    printf '| %s | m | 3.11.0 | fx-20260701 | scheduled | 0.8 | 1 | 1 | 1 | 900 |\n' "$1"
  } > "$WORK/benchmark/RESULTS.md"
}

new_case benchmark_disabled
base_config
run_preflight benchmark
assert_jq '.nothing_to_do == true' 'missing key gates the run off'
assert_jq 'has("benchmark_due") | not' 'no worklist entry when disabled'
assert_jq '.logs | any(contains("benchmark disabled"))' 'the off state is logged'

new_case benchmark_no_fixture
base_config '- benchmark: enabled'
run_preflight benchmark
assert_jq '.nothing_to_do == false' 'enabled with no fixture is work'
assert_jq '.benchmark_due.action == "create_fixture"' 'create_fixture is due'

new_case benchmark_first_run
base_config '- benchmark: enabled'
seed_fixture fx-20260801
run_preflight benchmark
assert_jq '.benchmark_due.action == "run"' 'run is due once a fixture exists'
assert_jq '.benchmark_due.fixture == "fx-20260801"' 'fixture id is carried'
assert_jq '.benchmark_due.judge == "off"' 'judge defaults to off'
assert_jq '.benchmark_due.last_run == null' 'no prior run recorded'

new_case benchmark_newest_fixture_wins
base_config '- benchmark: enabled' '- benchmark_judge: pinned-judge-model'
seed_fixture fx-20260801
seed_fixture fx-20260901
run_preflight benchmark
assert_jq '.benchmark_due.fixture == "fx-20260901"' 'the newest fixture is picked'
assert_jq '.benchmark_due.judge == "pinned-judge-model"' 'judge key is carried'

new_case benchmark_monthly_gate_holds
base_config '- benchmark: enabled'
seed_fixture fx-20260801
seed_result_row "$(iso_ago 432000)"   # 5 days ago — inside the 27-day floor
run_preflight benchmark
assert_jq '.nothing_to_do == true' 'a recent run gates the month'
assert_jq 'has("benchmark_due") | not' 'no worklist entry while gated'

new_case benchmark_monthly_gate_opens
base_config '- benchmark: enabled'
seed_fixture fx-20260801
seed_result_row "$(iso_ago 2592000)"  # 30 days ago — past the floor
run_preflight benchmark
assert_jq '.benchmark_due.action == "run"' 'a stale last run re-opens the gate'
assert_jq '.benchmark_due.last_run != null' 'the last run timestamp is carried'

finish
