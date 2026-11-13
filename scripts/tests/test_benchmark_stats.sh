#!/usr/bin/env bash
# lib/bench-stats.sh — paired per-defect comparison (McNemar + paired
# bootstrap) and bootstrap intervals over results files. Pure local.
. "$(dirname "$0")/helpers.sh"

STATS="$REPO_ROOT/scripts/lib/bench-stats.sh"

# results file: one fixture per spec "<slug>:<part>:<file>:<n>:<hits>[:nodetail]";
# defect ids D0..D<n-1>, the first <hits> found, one FP per fixture
results() { # <out> <spec>...
  local out="$1"; shift
  printf '%s\n' "$@" | jq -Rn '
    [inputs | split(":") | {s: .[0], part: .[1], file: .[2], n: (.[3] | tonumber),
                            h: (.[4] | tonumber), nodetail: (.[5] == "nodetail")}]
    | {ts: "2026-11-01T00:00:00Z", model: "m",
       fixtures: (map({(.s): ({first: ({
         tp: [range(0; .h) as $i | {id: "D\($i)", file: .file}],
         fn: [range(.h; .n) as $i | "D\($i)"],
         fp: [{file: .file, line: 1, severity: "warning"}]}
         + (if .nodetail then {} else {fn_detail: [range(.h; .n) as $i | {id: "D\($i)", file: .file}]} end)),
         rereview: {churn: 0}}
         + (if .part == "core" then {} else {part: .part} end))}) | add)}' > "$out"
}

new_case stats_paired_exact
results "$SANDBOX/a.json" "api:core:src/A.java:30:25" "ui:adaptive:web/x.py:10:8"
results "$SANDBOX/b.json" "api:core:src/A.java:30:10" "ui:adaptive:web/x.py:10:7"
OUT="$(bash "$STATS" paired "$SANDBOX/a.json" "$SANDBOX/b.json")"
assert_jq '.n_defects == 40 and .only_a == 16 and .only_b == 0 and .both == 17 and .neither == 7' 'overall discordant counts'
assert_jq '.delta_recall == 0.4' 'delta recall over the paired defects'
assert_jq '.mcnemar_p < 0.001 and .verdict == "a_better"' 'a clear gap is significant'
assert_jq '.ci95[0] > 0 and .ci95[1] > .ci95[0]' 'the interval excludes 0'
assert_jq '.parts.core.n_defects == 30 and .parts.adaptive.n_defects == 10' 'per part (absent part = core)'
assert_jq '.parts.adaptive.mcnemar_p == 1 and .parts.adaptive.verdict == "in_noise"' 'one discordant defect is in noise'
assert_jq '.languages.java.only_a == 15 and .languages.python.only_a == 1' 'per language from the defect files'
OUT2="$(bash "$STATS" paired "$SANDBOX/a.json" "$SANDBOX/b.json")"
is 'the same input prints the same output' "$OUT2" "$OUT"
OUT="$(bash "$STATS" paired "$SANDBOX/b.json" "$SANDBOX/a.json")"
assert_jq '.verdict == "b_better" and .delta_recall == -0.4 and .ci95[1] < 0' 'swapping the sides mirrors the verdict'

new_case stats_mcnemar_paths
# 3 vs 0 discordant: exact binomial 2 * 0.5^3 = 0.25
results "$SANDBOX/a.json" "f:core:a.go:10:5"
results "$SANDBOX/b.json" "f:core:a.go:10:2"
OUT="$(bash "$STATS" paired "$SANDBOX/a.json" "$SANDBOX/b.json")"
assert_jq '.only_a == 3 and .mcnemar_p == 0.25' 'small discordant count: exact binomial p'
assert_jq '.verdict == "in_noise"' 'p >= 0.05 is in noise'
# 30 vs 0 discordant (b + c >= 25): chi-square (|30-0|-1)^2/30 = 28.03 → p ≈ 1.2e-7
results "$SANDBOX/a.json" "f:core:a.go:40:35"
results "$SANDBOX/b.json" "f:core:a.go:40:5"
OUT="$(bash "$STATS" paired "$SANDBOX/a.json" "$SANDBOX/b.json")"
assert_jq '.only_a == 30 and .mcnemar_p > 0 and .mcnemar_p < 0.000001' 'large discordant count: chi-square with continuity correction'
# no discordant defect at all
OUT="$(bash "$STATS" paired "$SANDBOX/a.json" "$SANDBOX/a.json")"
assert_jq '.mcnemar_p == 1 and .delta_recall == 0 and .ci95 == [0, 0] and .verdict == "in_noise"' 'identical runs are in noise'

new_case stats_paired_only_shared_defects_and_old_files
results "$SANDBOX/a.json" "f:core:a.ts:10:6" "g:core:b.ts:4:4"
results "$SANDBOX/b.json" "f:core:a.ts:10:6:nodetail"
OUT="$(bash "$STATS" paired "$SANDBOX/a.json" "$SANDBOX/b.json")"
assert_jq '.n_defects == 10' 'a fixture only one side ran is not paired'
assert_jq '.languages.typescript.n_defects == 10' 'a miss on the old side takes its language from the other side'
results "$SANDBOX/a.json" "f:core:a.ts:10:6:nodetail"
OUT="$(bash "$STATS" paired "$SANDBOX/a.json" "$SANDBOX/b.json")"
assert_jq '.languages == null and .n_defects == 10' 'no file names a miss: language pairing is null, the rest stays'
jq -n '{fixtures: {}}' > "$SANDBOX/e.json"
OUT="$(bash "$STATS" paired "$SANDBOX/e.json" "$SANDBOX/b.json")"
assert_jq '.n_defects == 0 and .mcnemar_p == null and .verdict == "in_noise"' 'nothing to pair degrades to in_noise'

new_case stats_ci
results "$SANDBOX/a.json" "api:core:src/A.java:30:25" "ui:adaptive:web/x.py:10:8"
OUT="$(bash "$STATS" ci "$SANDBOX/a.json")"
assert_jq '.n_defects == 40 and .recall == 0.825' 'pooled recall over defects'
assert_jq '.recall_ci95[0] < 0.825 and .recall_ci95[1] > 0.825 and .recall_ci95[1] <= 1' 'recall interval brackets the value'
assert_jq '.n_predictions == 35 and .precision == 0.943' 'precision over tp + fp predictions'
assert_jq '.precision_ci95[0] <= .precision and .precision_ci95[1] <= 1' 'precision interval'
assert_jq '.parts.adaptive.recall == 0.8 and .parts.core.recall == 0.833' 'per part'
assert_jq '.languages.java.n_defects == 30 and .languages.python.precision == 0.889' 'per language'
OUT2="$(bash "$STATS" ci "$SANDBOX/a.json")"
is 'the bootstrap is deterministic' "$OUT2" "$OUT"
results "$SANDBOX/b.json" "api:core:src/A.java:30:25:nodetail"
OUT="$(bash "$STATS" ci "$SANDBOX/b.json")"
assert_jq '.languages == null and .recall == 0.833' 'an old file without fn_detail has no language scope'

new_case stats_functions_and_usage
. "$STATS"
results "$SANDBOX/a.json" "f:core:a.rb:10:5"
OUT="$(bench_ci "$SANDBOX/a.json")"
assert_jq '.recall == 0.5' 'bench_ci works when sourced'
OUT="$(bench_paired "$SANDBOX/a.json" "$SANDBOX/a.json")"
assert_jq '.n_defects == 10' 'bench_paired works when sourced'
bash "$STATS" paired "$SANDBOX/a.json" >/dev/null 2>&1; is 'a missing argument is a usage error' "$?" 2

finish
