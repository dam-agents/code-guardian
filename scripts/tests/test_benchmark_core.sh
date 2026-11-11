#!/usr/bin/env bash
# benchmark-core.sh (core versions: migrate, new-version, memory-sha) and the
# validator's core/adaptive layout, frozen-memory leak check and the optional
# results fields of the core/adaptive redesign. Pure local.
. "$(dirname "$0")/helpers.sh"

CORE="$REPO_ROOT/scripts/benchmark-core.sh"
VALIDATE="$REPO_ROOT/scripts/benchmark-validate.sh"

# a small valid fixture: one defect in src/<slug>.go line 3 of head-v1
mkfix() { # <root> <slug> [author_model]
  local F="$1/$2"
  mkdir -p "$F/base/src" "$F/head-v1/src" "$F/head-v2/src"
  printf 'package main\n\nfunc a() int { return 1 }\n' > "$F/base/src/$2.go"
  printf 'package main\n\nfunc a() int { return limits[%s_index] }\n' "$2" > "$F/head-v1/src/$2.go"
  cp "$F/head-v1/src/$2.go" "$F/head-v2/src/$2.go"
  printf '## Review\nLooks fine.\n' > "$F/prior-review.md"
  printf '{"title":"t"}\n' > "$F/pr.json"
  printf -- '--- a/src/%s.go\n+++ b/src/%s.go\n' "$2" "$2" > "$F/diff-v1.patch"
  : > "$F/diff-v1-v2.patch"
  jq -n --arg s "$2" --arg a "${3:-}" '{fixture: $s, created: "2026-08-01T00:00:00Z",
    defects: [{id: "D01", file: "src/\($s).go", line_v1: 3, line_v2: 3, class: "correctness",
               severity: "warning", summary: "index out of range on \($s) limits",
               fixed_in_v2: false, in_prior_review: false}]}
    + (if $a == "" then {} else {author_model: $a} end)' > "$F/manifest.json"
}

seed_bench() { # <bdir>
  mkdir -p "$1/fixture" "$1/results"
  mkfix "$1/fixture" alpha claude-x-1
  mkfix "$1/fixture" beta
  mkdir -p "$1/fixture/retired/old"
  printf '# Memory\n- prefer small diffs\n' > "$1/../MEMORY.md"
  printf '# Lessons\n- check bounds\n' > "$1/../LESSONS.md"
  printf '# Benchmark results\n<!-- benchmark-dam: x -->\n\n| ts | model |\n|----|-------|\n| 2026-10-01 | m |\n' > "$1/RESULTS.md"
}

new_case core_migrate
B="$WORK/benchmark"; seed_bench "$B"
OUT="$(bash "$CORE" migrate "$B" --author op-model)"
assert_out_contains 'core v1 migrated: 2 fixture(s)' 'the set becomes core version 1'
assert_out_contains 'results-note added' 'the non-comparable line is added'
assert_out_absent '^leak ' 'a clean memory leaks nothing'
OUT="$(cat "$B/fixture/CORE.json")"
assert_jq '.version == 1 and .migrated == true and .bridged_from == null' 'CORE.json version metadata'
assert_jq '.fixtures == ["alpha", "beta"]' 'fixtures = the current slugs (retired/ excluded)'
assert_jq '.author_model == {alpha: "claude-x-1", beta: "op-model"}' 'author from the manifest, else --author'
assert_jq ".memory_sha == \"$(git hash-object "$B/fixture/core-memory/MEMORY.md")\"" 'memory_sha of the frozen copy'
is 'MEMORY.md frozen' "$(cat "$B/fixture/core-memory/MEMORY.md")" "$(cat "$WORK/MEMORY.md")"
is 'LESSONS.md frozen' "$(cat "$B/fixture/core-memory/LESSONS.md")" "$(cat "$WORK/LESSONS.md")"
is 'one line under the header, above the table' \
  "$(sed -n 4p "$B/RESULTS.md" | grep -c 'read the live memory — not comparable with core version 1')" 1
OUT="$(bash "$VALIDATE" fixture "$B/fixture"; printf 'rc=%s' "$?")"
assert_out_contains 'ok   core: core version 1, 2 fixture(s)' 'the migrated root validates its CORE.json'
assert_out_contains 'ok   leak_memory\[alpha\]' 'the root mode runs the leak check'
assert_out_absent 'retired|core-memory\]' 'retired/ and core-memory/ are not fixtures'
assert_out_contains 'rc=0' 'the migrated core validates clean'
OUT="$(bash "$CORE" migrate "$B")"
is 'a second migrate changes nothing' "$OUT" 'already core v1'
is 'the line is never added twice' "$(grep -c 'not comparable with core version 1' "$B/RESULTS.md")" 1
rm "$B/fixture/CORE.json"
OUT="$(bash "$CORE" migrate "$B")"
assert_out_contains 'results-note present' 'an interrupted migration re-runs without a second line'

new_case core_migrate_reports_leaks
B="$WORK/benchmark"; seed_bench "$B"
printf -- '- index out of range on beta limits: watch it\n' >> "$WORK/LESSONS.md"
printf -- '- see src/alpha.go:3\n' >> "$WORK/MEMORY.md"
OUT="$(bash "$CORE" migrate "$B")"
assert_out_contains '^leak alpha$' 'a file:line named in the frozen memory is a leak'
assert_out_contains '^leak beta$' 'a defect summary named in the frozen memory is a leak'
[ -d "$B/fixture/alpha" ] && [ -d "$B/fixture/beta" ] && ok 'leaking fixtures are reported, never moved' || bad 'a leaking fixture was moved'
OUT="$(bash "$VALIDATE" fixture "$B/fixture"; printf 'rc=%s' "$?")"
assert_out_contains 'FAIL leak_memory\[beta\]:.*D01(summary).*fix:' 'the validator fails the leak with a fix'
assert_out_contains 'rc=1' 'a leak fails validation'

new_case core_leak_by_code_line_and_adaptive_root
B="$WORK/benchmark"; mkdir -p "$B/fixture/core-memory" "$B/adaptive"
mkfix "$B/adaptive" gamma
printf 'src/gamma.go: func a() int { return limits[gamma_index] } is unchecked\n' > "$B/fixture/core-memory/MEMORY.md"
OUT="$(bash "$VALIDATE" fixture "$B/adaptive"; printf 'rc=%s' "$?")"
assert_out_contains 'FAIL leak_memory\[gamma\]:.*D01(src/gamma.go line)' 'file + defect code line in the memory is a leak, checked from the adaptive root'
printf 'nothing here\n' > "$B/fixture/core-memory/MEMORY.md"
OUT="$(bash "$VALIDATE" fixture "$B/adaptive"; printf 'rc=%s' "$?")"
assert_out_contains 'ok   leak_memory\[gamma\]' 'a clean memory passes'
assert_out_contains 'rc=0' 'the adaptive root validates'

new_case core_manifest_extra_fields
B="$WORK/benchmark"; mkdir -p "$B/fixture" "$B/adaptive"
mkfix "$B/adaptive" delta model-a
jq '.added = "2026-11-01T00:00:00Z" | .source = "escaped-defect"
    | .defects[0].confirmed_by = [{ts: "2026-11-02T00:00:00Z", model: "m"}]' \
  "$B/adaptive/delta/manifest.json" > "$SANDBOX/m" && mv "$SANDBOX/m" "$B/adaptive/delta/manifest.json"
OUT="$(bash "$VALIDATE" fixture "$B/adaptive/delta")"
assert_out_contains 'ok   manifest_extra\[delta\]' 'adaptive added/source/confirmed_by validate'
mkfix "$B/fixture" eps
jq '.added = "yesterday" | .defects[0].confirmed_by = [{ts: "2026-11-02T00:00:00Z", model: "m"}]' \
  "$B/fixture/eps/manifest.json" > "$SANDBOX/m" && mv "$SANDBOX/m" "$B/fixture/eps/manifest.json"
OUT="$(bash "$VALIDATE" fixture "$B/fixture/eps")"
assert_out_contains 'FAIL manifest_extra\[eps\]: added not an ISO timestamp; D01: confirmed_by on a core fixture' 'malformed optional fields fail'

new_case core_json_shape
B="$WORK/benchmark"; seed_bench "$B"
bash "$CORE" migrate "$B" >/dev/null
jq '.fixtures += ["ghost"] | .bridged_from = 3' "$B/fixture/CORE.json" > "$SANDBOX/c" && mv "$SANDBOX/c" "$B/fixture/CORE.json"
OUT="$(bash "$VALIDATE" fixture "$B/fixture"; printf 'rc=%s' "$?")"
assert_out_contains 'FAIL core: bridged_from not null or an earlier version' 'a bad bridged_from fails'
jq '.bridged_from = null' "$B/fixture/CORE.json" > "$SANDBOX/c" && mv "$SANDBOX/c" "$B/fixture/CORE.json"
printf 'changed\n' >> "$B/fixture/core-memory/MEMORY.md"
OUT="$(bash "$VALIDATE" fixture "$B/fixture"; printf 'rc=%s' "$?")"
assert_out_contains 'FAIL core: fixture ghost not in the root; memory_sha does not match core-memory/' 'a missing slug and a changed frozen copy fail'

new_case core_new_version
B="$WORK/benchmark"; seed_bench "$B"
bash "$CORE" migrate "$B" >/dev/null
mkdir -p "$SANDBOX/staged"; mkfix "$SANDBOX/staged" alpha; mkfix "$SANDBOX/staged" zeta new-author
printf '%s run-1\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$B/.run-lock"
OUT="$(bash "$CORE" new-version "$B" "$SANDBOX/staged" 2>&1; printf 'rc=%s' "$?")"
assert_out_contains 'refused: live run lock' 'a live run lock refuses'
assert_out_contains 'rc=1' 'refusal exits 1'
[ -f "$B/fixture/alpha/manifest.json" ] && ok 'nothing moved under the lock' || bad 'moved under the lock'
printf '2020-01-01T00:00:00Z run-1\n' > "$B/.run-lock"
printf -- '- see src/zeta.go:3\n' >> "$WORK/MEMORY.md"
OUT="$(bash "$CORE" new-version "$B" "$SANDBOX/staged" 2>&1; printf 'rc=%s' "$?")"
assert_out_contains 'FAIL leak_memory\[zeta\]' 'the staged set is leak-checked against the new frozen copy'
assert_out_contains 'refused: the staged set fails validation' 'a failing staged set is refused'
[ -f "$B/fixture/CORE.json" ] && [ ! -e "$B/fixture/retired/core-v1" ] && ok 'nothing moved on a failing set' || bad 'moved on a failing set'
printf '# Memory\n' > "$WORK/MEMORY.md"
OUT="$(bash "$CORE" new-version "$B" "$SANDBOX/staged" 2>&1; printf 'rc=%s' "$?")"
assert_out_contains 'core v2 installed: 2 fixture(s), core v1 retired to retired/core-v1' 'the staged set becomes version 2'
for p in alpha beta CORE.json core-memory/MEMORY.md; do
  [ -e "$B/fixture/retired/core-v1/$p" ] && ok "retired/core-v1/$p kept" || bad "retired/core-v1/$p missing"
done
OUT="$(cat "$B/fixture/CORE.json")"
assert_jq '.version == 2 and .bridged_from == 1 and .migrated == false' 'version 2 bridges from 1'
assert_jq '.fixtures == ["alpha", "zeta"] and .author_model.zeta == "new-author" and .author_model.alpha == "unknown"' 'new slugs and authors'
is 'a fresh frozen copy' "$(cat "$B/fixture/core-memory/MEMORY.md")" '# Memory'
[ -d "$B/fixture/retired/old" ] && ok 'older retired fixtures stay' || bad 'retired/old lost'
OUT="$(bash "$VALIDATE" fixture "$B/fixture"; printf 'rc=%s' "$?")"
assert_out_contains 'rc=0' 'the new core validates'
mkdir -p "$SANDBOX/s2"; mkfix "$SANDBOX/s2" omega
mkdir -p "$B/fixture/retired/core-v2"
OUT="$(bash "$CORE" new-version "$B" "$SANDBOX/s2" 2>&1; printf 'rc=%s' "$?")"
assert_out_contains 'refused: .*retired/core-v2 exists' 'an existing retired version is never overwritten'
rmdir "$B/fixture/retired/core-v2"; rm -rf "$B/fixture/retired/core-v1"
OUT="$(bash "$CORE" new-version "$WORK/none" "$SANDBOX/s2" 2>&1; printf 'rc=%s' "$?")"
assert_out_contains 'run benchmark-core.sh migrate first' 'no CORE.json → migrate first'

new_case core_memory_sha_shared_with_provenance
mkdir -p "$FAKE_HOME/work" "$SANDBOX/bench"
printf '# mem\n' > "$FAKE_HOME/work/MEMORY.md"
is 'memory-sha is git hash-object of MEMORY.md' "$(bash "$CORE" memory-sha "$FAKE_HOME/work")" "$(git hash-object "$FAKE_HOME/work/MEMORY.md")"
OUT="$(HOME="$FAKE_HOME" bash "$REPO_ROOT/scripts/benchmark-provenance.sh" "$SANDBOX/bench")"
assert_jq ".memory_sha == \"$(git hash-object "$FAKE_HOME/work/MEMORY.md")\"" 'provenance prints the same memory_sha'
is 'no MEMORY.md → empty' "$(bash "$CORE" memory-sha "$SANDBOX/none")" ''

new_case results_new_optional_fields
base() { jq -n '{ts: "2026-11-11T06:00:00Z", trigger: "manual", model: "anthropic/claude-x[1m]", effort: "high",
  definition_version: "15.0.0", isolation: "platform-subagent", judge: "off",
  fixtures: {alpha: {first: {fp: [], tier: "simple", difficulty: {easy: {tp: 1, gt: 1}, hard: {tp: 0, gt: 0}},
                             seconds: 1, tokens: null, judge: null},
                     rereview: {churn: 0, seconds: 1, tokens: null, judge: null}}}}'; }
mkdir -p "$SANDBOX/r"
base > "$SANDBOX/r/20261111T060000Z.json"
OUT="$(bash "$VALIDATE" results --stored "$SANDBOX/r/20261111T060000Z.json"; printf 'rc=%s' "$?")"
assert_out_contains 'rc=0' 'an old-shape file still passes'
F="$SANDBOX/r/20261111T060000Z--anthropic_claude-x_1m_.json"
base | jq '. + {run_id: "20261111T060000Z", models: ["anthropic/claude-x[1m]", "m2"], reference_model: "m2",
  core_version: 1, memory_source: "core-frozen", judge: "j-a", judge_panel: ["j-a", "j-b"], judge_model_used: "j-a,j-b", judge_reason: "timeout",
  author_models: {alpha: "unknown"},
  recommendation: {rule: "cheapest_not_worse", text: "no change", cites: ["core recall 0.8"], confidence: "medium"},
  comparison: {"anthropic/claude-x[1m]|m2": {n_defects: 10, only_a: 1, only_b: 0, both: 5, neither: 4,
     mcnemar_p: 1, delta_recall: 0.1, ci95: [0, 0.3], verdict: "in_noise"}}}
  | .fixtures.alpha += {part: "core"}
  | .fixtures.alpha.first += {languages: {go: {tp: 1, gt: 1}}, fn_detail: [],
      judge: {finding_accuracy: 4, panel: [{model: "j-a", harness: "claude", scores: {}, status: "ok"}],
              disagreement: 1, fp_class: [{file: "a.go", line: 3, class: "defensible"}]}}
  | .fixtures.alpha.rereview += {languages: {}}' > "$F"
OUT="$(bash "$VALIDATE" results --stored "$F"; printf 'rc=%s' "$?")"
assert_out_contains 'ok   run_extra' 'the new run fields validate'
assert_out_contains 'ok   fixture_extra' 'the new fixture fields validate'
assert_out_contains 'ok   filename' 'the per-model file name matches'
assert_out_contains 'ok   judge_pinned' 'panel scores pass the pinned-judge check'
assert_out_contains 'rc=0' 'a multi-model per-model file validates'
jq '.memory_source = "core-frozen" | .core_version = null | .judge = "j-b"
    | .recommendation.confidence = "sure" | .comparison = {"x": {verdict: "maybe"}}
    | .fixtures.alpha.part = "extra" | .fixtures.alpha.first.languages = {go: 1}
    | .fixtures.alpha.first.judge.fp_class = [{file: "a.go", class: "odd"}]
    | .run_id = "20261111T070000Z" | .model = "other"' "$F" > "$SANDBOX/r/bad--x.json"
OUT="$(bash "$VALIDATE" results --stored "$SANDBOX/r/bad--x.json"; printf 'rc=%s' "$?")"
assert_out_contains 'FAIL run_extra:.*core-frozen without core_version.*judge is not the first judge_panel member.*recommendation not.*comparison not' 'malformed run fields fail'
assert_out_contains 'FAIL fixture_extra:.*part not core | adaptive.*first.languages malformed.*fp_class malformed' 'malformed fixture fields fail'
assert_out_contains 'FAIL filename: model slug x is not other; ts bad is not run_id' 'a per-model name that does not match fails'
assert_out_contains 'rc=1' 'malformed new fields fail the file'

finish
