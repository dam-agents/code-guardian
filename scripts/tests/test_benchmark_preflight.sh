#!/usr/bin/env bash
# preflight benchmark mode — gate on `benchmark: enabled`, create_fixture until
# the set holds 5 fixtures, run with the monthly (27-day) gate fed by
# scheduled results only, gist surface dropped off github.com, purely local
# (no gh fixtures are seeded: the mode must decide without API calls).
. "$(dirname "$0")/helpers.sh"

seed_fixture() { # <slug>
  mkdir -p "$WORK/benchmark/fixture/$1"
  printf '{"fixture":"%s","defects":[]}' "$1" > "$WORK/benchmark/fixture/$1/manifest.json"
}

seed_full_set() { for s in ts-api react-ui py-cli infra-ci docs-mixed; do seed_fixture "$s"; done; }

seed_result_json() { # <iso-ts> <trigger>
  mkdir -p "$WORK/benchmark/results"
  printf '{"ts":"%s","trigger":"%s","model":"m","definition_version":"3.11.0","fixtures":{}}' \
    "$1" "$2" > "$WORK/benchmark/results/$(printf '%s' "$1" | tr -d ':-').json"
}

new_case benchmark_disabled
base_config
run_preflight benchmark
assert_jq '.nothing_to_do == true' 'missing key gates the run off'
assert_jq 'has("benchmark_due") | not' 'no worklist entry when disabled'
assert_jq '.logs | any(contains("benchmark disabled"))' 'the off state is logged'

new_case benchmark_no_config_at_all
# CONFIG.md absent entirely: the mode degrades to nothing_to_do before any
# repo resolution (the block sits ahead of the gh fallback)
run_preflight benchmark
assert_jq '.nothing_to_do == true' 'missing CONFIG degrades to nothing_to_do'

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
assert_jq '.benchmark_due.report == "gist,dam"' 'report surfaces are carried on github.com'
assert_jq '.benchmark_due.last_run == null' 'no prior run recorded'

new_case benchmark_defaults
base_config '- benchmark: enabled'
seed_full_set
run_preflight benchmark
assert_jq '.benchmark_due.judge == "off"' 'judge defaults to off'
assert_jq '.benchmark_due.report == "gist"' 'report defaults to gist'

new_case benchmark_gist_dropped_off_github
TEST_REF="github.example.com/acme/widgets"
base_config '- benchmark: enabled' '- benchmark_report: gist,dam'
seed_full_set
run_preflight benchmark
assert_jq '.benchmark_due.report == "dam"' 'gist is dropped on a non-github.com host'
assert_jq '.logs | any(contains("gist dropped"))' 'the drop is logged'

new_case benchmark_gist_only_off_github
TEST_REF="github.example.com/acme/widgets"
base_config '- benchmark: enabled'
seed_full_set
run_preflight benchmark
assert_jq '.benchmark_due.report == "off"' 'no reachable surface degrades to off'

new_case benchmark_live_run_lock_holds
base_config '- benchmark: enabled'
seed_full_set
mkdir -p "$WORK/benchmark"
printf '%s other-nonce\n' "$(iso_ago 3600)" > "$WORK/benchmark/.run-lock"   # 1h-old sibling
run_preflight benchmark
assert_jq '.nothing_to_do == true' 'a live run lock blocks a second run'
assert_jq '.logs | any(contains("already in progress"))' 'the sibling is named in the logs'

new_case benchmark_stale_run_lock_taken_over
base_config '- benchmark: enabled'
seed_full_set
mkdir -p "$WORK/benchmark"
printf '%s dead-nonce\n' "$(iso_ago 90000)" > "$WORK/benchmark/.run-lock"   # 25h-old crash leftover
run_preflight benchmark
assert_jq '.benchmark_due.action == "run"' 'a stale lock does not block forever'
assert_jq '.logs | any(contains("stale benchmark run lock"))' 'the takeover is logged'

new_case benchmark_segmented_ledger_gates
base_config '- benchmark: enabled'
seed_full_set
mkdir -p "$WORK/benchmark"
touch "$WORK/benchmark/.run-notes-20260816T190527Z.md"   # fresh — run paused between segments
run_preflight benchmark
assert_jq '.nothing_to_do == true' 'a fresh segmented-run ledger gates the tick'
assert_jq '.logs | any(contains("segmented benchmark run in progress"))' 'the pause is named in the logs'

new_case benchmark_abandoned_ledger_overridden
base_config '- benchmark: enabled'
seed_full_set
mkdir -p "$WORK/benchmark"
touch -t 202601010000 "$WORK/benchmark/.run-notes-20260101T000000Z.md"   # >7d — abandoned
run_preflight benchmark
assert_jq '.benchmark_due.action == "run"' 'an abandoned ledger does not gate forever'
assert_jq '.logs | any(contains("stale segmented-run notes"))' 'the staleness is logged'

new_case benchmark_monthly_gate_holds
base_config '- benchmark: enabled'
seed_full_set
seed_result_json "$(iso_ago 432000)" scheduled   # 5 days ago — inside the floor
run_preflight benchmark
assert_jq '.nothing_to_do == true' 'a recent scheduled run gates the month'
assert_jq 'has("benchmark_due") | not' 'no worklist entry while gated'

new_case benchmark_manual_never_feeds_gate
base_config '- benchmark: enabled'
seed_full_set
seed_result_json "$(iso_ago 432000)" manual      # 5 days ago, manual
run_preflight benchmark
assert_jq '.benchmark_due.action == "run"' 'a manual run never moves the scheduled cadence'
assert_jq '.benchmark_due.last_run == null' 'gate sees no scheduled run yet'

new_case benchmark_monthly_gate_opens
base_config '- benchmark: enabled'
seed_full_set
seed_result_json "$(iso_ago 2592000)" scheduled  # 30 days ago — past the floor
run_preflight benchmark
assert_jq '.benchmark_due.action == "run"' 'a stale scheduled run re-opens the gate'
assert_jq '.benchmark_due.last_run != null' 'the last scheduled timestamp is carried'

finish
