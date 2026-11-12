#!/usr/bin/env bash
# preflight benchmark mode — gate on `benchmark: enabled`, create_fixture until
# the core set holds 5 simple and 3 complex fixtures, run whenever no run is in
# progress (no time gate: the benchmark has no schedule), the run settings
# (reference model, queue limit, judge panel, decision rule, core version,
# adaptive set), report surface dam | off, purely local (no gh fixtures are
# seeded: the mode must decide without API calls).
. "$(dirname "$0")/helpers.sh"

seed_fixture() { # <slug> [tier]
  mkdir -p "$WORK/benchmark/fixture/$1"
  jq -n --arg f "$1" --arg t "${2:-}" '{fixture: $f, defects: []} + (if $t == "" then {} else {tier: $t} end)' \
    > "$WORK/benchmark/fixture/$1/manifest.json"
}

seed_full_set() {
  for s in ts-api react-ui py-cli infra-ci docs-mixed; do seed_fixture "$s"; done
  for s in billing-service ui-platform deploy-pipeline; do seed_fixture "$s" complex; done
}

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
assert_jq '.benchmark_due.existing == [] and .benchmark_due.min == 5 and .benchmark_due.min_complex == 3' 'empty set, target size per tier named'
assert_jq '.benchmark_due.missing == {simple: 5, complex: 3}' 'every fixture of both tiers is missing'

new_case benchmark_partial_set
base_config '- benchmark: enabled'
seed_fixture ts-api
seed_fixture react-ui
seed_fixture py-cli
mkdir -p "$WORK/benchmark/fixture/broken"   # no manifest — not part of the set
run_preflight benchmark
assert_jq '.benchmark_due.action == "create_fixture"' 'an incomplete set asks for a top-up'
assert_jq '.benchmark_due.existing | length == 3' 'manifest-less directories are not counted'

new_case benchmark_complex_tier_missing
base_config '- benchmark: enabled'
for s in ts-api react-ui py-cli infra-ci docs-mixed; do seed_fixture "$s"; done
seed_fixture billing-service complex
run_preflight benchmark
assert_jq '.benchmark_due.action == "create_fixture"' 'a full simple set without enough complex fixtures asks for a top-up'
assert_jq '.benchmark_due.missing == {simple: 0, complex: 2}' 'only the missing complex fixtures are asked for'
assert_jq '.logs | any(contains("complex 1/3"))' 'the tier counts are logged'

# fake claude for the judge check: `auth status` says what $FAKE_AUTH says
seed_judge_cli() { # <true|false>
  mkdir -p "$SANDBOX/cli"
  printf '#!/usr/bin/env bash\nprintf %s\n' "'{\"loggedIn\": $1}'" > "$SANDBOX/cli/claude"
  chmod +x "$SANDBOX/cli/claude"
  export CG_JUDGE_CLI="$SANDBOX/cli/claude" CG_JUDGE_PI="$SANDBOX/cli/no-pi"
  unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY
}

new_case benchmark_run_due
base_config '- benchmark: enabled' '- benchmark_judge: pinned-judge-model' '- benchmark_report: off'
seed_full_set
seed_judge_cli true
run_preflight benchmark
assert_jq '.benchmark_due.judge_unavailable == null' 'a signed-in judge CLI is ready'
assert_jq '.benchmark_due.action == "run"' 'a full set makes a run due'
assert_jq '.benchmark_due.fixtures | length == 8' 'all eight fixtures of both tiers are carried'
assert_jq '.benchmark_due.judge == "pinned-judge-model"' 'judge key is carried'
assert_jq '.benchmark_due.report == "off"' 'the report surface is carried'
assert_jq '.benchmark_due.last_run == null' 'no prior run recorded'

# the isolation repository check of a due run (docs/benchmark.md → Isolation)
iso_fx() { # <work-repo visibility> <definition visibility>
  printf '{"visibility":"%s"}' "$1" | fx 'api --hostname github.com repos/acme/cg-state'
  printf '{"visibility":"%s"}' "$2" | fx 'api --hostname github.com repos/acme/cg-def'
}
new_case benchmark_run_isolation_ready
base_config '- benchmark: enabled' '- work_repo: acme/cg-state' '- definition_repo: acme/cg-def'
seed_full_set
iso_fx private public
run_preflight benchmark
assert_jq '.benchmark_due.action == "run" and .benchmark_due.isolation_unavailable == null' 'a private backup and a public definition allow isolation'

new_case benchmark_run_public_work_repo
base_config '- benchmark: enabled' '- work_repo: acme/cg-state' '- definition_repo: acme/cg-def'
seed_full_set
iso_fx public public
run_preflight benchmark
assert_jq '.benchmark_due.action == "run"' 'the run stays due'
assert_jq '.benchmark_due.isolation_unavailable | test("work_repo acme/cg-state is public")' 'the run knows before it starts that it cannot be isolated'
assert_jq '.logs | any(contains("benchmark isolation unavailable"))' 'the reason is logged'

new_case benchmark_judge_not_signed_in
base_config '- benchmark: enabled' '- benchmark_judge: pinned-judge-model'
seed_full_set
seed_judge_cli false
run_preflight benchmark
assert_jq '.benchmark_due.action == "run" and .benchmark_due.judge == "pinned-judge-model"' 'the run stays due, the judge key stays'
assert_jq '.benchmark_due.judge_unavailable | test("not signed in")' 'the run knows before it starts that the judge cannot answer'
assert_jq '.logs | any(contains("benchmark judge unavailable"))' 'the reason is logged'
ANTHROPIC_AUTH_TOKEN=gateway-token run_preflight benchmark
assert_jq '.benchmark_due.judge_unavailable == null' 'a gateway token in the environment counts as signed in'
CG_JUDGE_CLI="$SANDBOX/cli/none" run_preflight benchmark
assert_jq '.benchmark_due.judge_unavailable | test("no .* CLI")' 'a missing CLI is named'
cp "$SANDBOX/cli/claude" "$SANDBOX/cli/pi"
CG_JUDGE_PI="$SANDBOX/cli/pi" run_preflight benchmark
assert_jq '.benchmark_due.judge_unavailable == null' 'a pi CLI to fall back to makes the judge ready'

new_case benchmark_judge_auto
base_config '- benchmark: enabled' '- benchmark_judge: auto'
seed_full_set
seed_judge_cli true
run_preflight benchmark
assert_jq '.benchmark_due.judge == "auto" and .benchmark_due.judge_unavailable == null' 'auto without a pick asks the run to pick one'
mkdir -p "$WORK/benchmark"
printf '{"model":"acme/judge-a","chosen":"2026-10-01T00:00:00Z","why":"x","replaced":[]}\n' > "$WORK/benchmark/judge.json"
run_preflight benchmark
assert_jq '.benchmark_due.judge == "acme/judge-a"' 'the pinned pick is the judge of the run'

new_case benchmark_defaults
base_config '- benchmark: enabled'
seed_full_set
run_preflight benchmark
assert_jq '.benchmark_due.judge == "off"' 'judge defaults to off'
assert_jq '.benchmark_due.report == "dam"' 'report defaults to dam'

new_case benchmark_legacy_report_value
base_config '- benchmark: enabled' '- benchmark_report: gist,dam'
seed_full_set
run_preflight benchmark
assert_jq '.benchmark_due.report == "dam"' 'a legacy value publishes to dam'
assert_jq '.logs | any(contains("benchmark_report") and contains("publishing to dam"))' 'the legacy value is logged'

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

new_case benchmark_no_time_gate
base_config '- benchmark: enabled'
seed_full_set
seed_result_json "$(iso_ago 432000)" scheduled   # 5 days ago — an old scheduled run
seed_result_json "$(iso_ago 3600)" manual        # 1 hour ago
run_preflight benchmark
assert_jq '.benchmark_due.action == "run"' 'a recent run never holds the next one'
assert_jq '.benchmark_due.last_run != null and (.benchmark_due.last_run | fromdateiso8601) > (now - 7200)' 'the newest run of any trigger is carried'

new_case benchmark_settings_defaults
base_config '- benchmark: enabled'
seed_full_set
run_preflight benchmark
assert_jq '.benchmark_due.reference_model == null' 'no reference model by default'
assert_jq '.benchmark_due.max_parallel == 8' 'queue limit defaults to 8'
assert_jq '.benchmark_due.judge_panel == null' 'no panel without a comma list'
assert_jq '.benchmark_due.decision_rule == "cheapest_not_worse"' 'decision rule default'
assert_jq '.benchmark_due.core_version == null and .benchmark_due.adaptive == []' 'no core version and no adaptive set before the migration'

new_case benchmark_settings_configured
base_config '- benchmark: enabled' '- benchmark_reference_model: acme/model-r' '- benchmark_max_parallel: 3' \
  '- benchmark_judge: acme/judge-a ,  other/judge-b' '- benchmark_decision_rule: cost_cap:2.5'
seed_full_set
mkdir -p "$WORK/benchmark/fixture/retired/old-one" "$WORK/benchmark/fixture/core-memory"
printf '{"fixture":"old-one","defects":[]}' > "$WORK/benchmark/fixture/retired/old-one/manifest.json"
printf '{"version":2,"fixtures":[]}' > "$WORK/benchmark/fixture/CORE.json"
for a in zz-escaped aa-history; do
  mkdir -p "$WORK/benchmark/adaptive/$a"
  printf '{"fixture":"%s","defects":[]}' "$a" > "$WORK/benchmark/adaptive/$a/manifest.json"
done
mkdir -p "$WORK/benchmark/adaptive/no-manifest"
run_preflight benchmark
assert_jq '.benchmark_due.reference_model == "acme/model-r"' 'the reference model is carried'
assert_jq '.benchmark_due.max_parallel == 3' 'the queue limit is carried'
assert_jq '.benchmark_due.judge_panel == ["acme/judge-a", "other/judge-b"]' 'a comma list is the judge panel, trimmed'
assert_jq '.benchmark_due.decision_rule == "cost_cap:2.5"' 'a cost cap rule is carried'
assert_jq '.benchmark_due.core_version == 2' 'the core version comes from CORE.json'
assert_jq '.benchmark_due.fixtures | length == 8' 'retired/ and core-memory/ are not core fixtures'
assert_jq '.benchmark_due.adaptive == ["aa-history", "zz-escaped"]' 'the adaptive set lists every adaptive fixture with a manifest'

new_case benchmark_panel_is_the_served_one
# short config names resolve to the served ids; a member the host does not
# serve leaves the panel, and the entry carries the one-family note
base_config '- benchmark: enabled' '- benchmark_judge: opus, gemini'
seed_full_set
mkdir -p "$SANDBOX/cli"
printf '#!/bin/sh\nprintf %s\n' "'{\"loggedIn\": true}'" > "$SANDBOX/cli/claude"; chmod +x "$SANDBOX/cli/claude"
printf 'claude-opus-5-5\nclaude-sonnet-5-5\n' > "$SANDBOX/models"
CG_JUDGE_CLI="$SANDBOX/cli/claude" CG_JUDGE_PI="$SANDBOX/cli/no-pi" CG_JUDGE_MODELS="$SANDBOX/models" run_preflight benchmark
assert_jq '.benchmark_due.judge_panel == ["claude-opus-5-5"]' 'judge_panel holds the served id, not the configured name'
assert_jq '.benchmark_due.judge == .benchmark_due.judge_panel[0]' 'judge is the first panel member'
assert_jq '.benchmark_due.panel_note == "one family only"' 'a one-member panel carries its note'

new_case benchmark_settings_invalid
base_config '- benchmark: enabled' '- benchmark_max_parallel: many' '- benchmark_decision_rule: fastest'
for s in ts-api react-ui; do seed_fixture "$s"; done
run_preflight benchmark
assert_jq '.benchmark_due.action == "create_fixture"' 'the settings ride on create_fixture too'
assert_jq '.benchmark_due.max_parallel == 8' 'an invalid queue limit reads as 8'
assert_jq '.benchmark_due.decision_rule == "cheapest_not_worse"' 'an unknown rule reads as the default'
assert_jq '[.logs[] | select(contains("benchmark_max_parallel"))] | length == 1' 'the invalid queue limit is logged once'
assert_jq '.logs | any(contains("benchmark_decision_rule"))' 'the unknown rule is logged'

# --- the resolved keys travel in the worklist's config object ----------------
new_case benchmark_config_object_defaults
base_config '- benchmark: enabled'
pr_json 1 "a new PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
run_preflight review
assert_jq '.config.benchmark_reference_model == null and .config.benchmark_max_parallel == 8' 'reference model and queue limit defaults'
assert_jq '.config.benchmark_decision_rule == "cheapest_not_worse"' 'decision rule default'

new_case benchmark_config_object_set
base_config '- benchmark: enabled' '- benchmark_reference_model: acme/model-r' '- benchmark_max_parallel: 4' '- benchmark_decision_rule: best_quality'
pr_json 1 "a new PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
run_preflight review
assert_jq '.config.benchmark_reference_model == "acme/model-r" and .config.benchmark_max_parallel == 4' 'the configured values travel'
assert_jq '.config.benchmark_decision_rule == "best_quality"' 'the configured rule travels'

new_case audit_fixture_check_runs_the_roots
# the weekly integrity check validates the core and adaptive roots: a stale
# CORE.json (a listed slug gone from the root) fails it
base_config '- benchmark: enabled'
seed_full_set
jq -n '{version:1, created:"2026-11-01T00:00:00Z", migrated:true, memory_sha:null,
        fixtures:["gone-slug"], author_model:{"gone-slug":"unknown"}, bridged_from:null}' \
  > "$WORK/benchmark/fixture/CORE.json"
run_preflight audit
assert_jq '.checks[] | select(.id == "benchmark_fixtures") | .status == "fail" and (.detail | contains("core"))' \
  'a stale CORE.json fails the audit fixture check'

finish
