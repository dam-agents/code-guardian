#!/usr/bin/env bash
# Project health (docs/audit.md task 36): the weekly audit measures the
# repository — review coverage, PR size, human review latency, conflicts and
# the areas carrying findings — and reports every unmeasured figure as null.
. "$(dirname "$0")/helpers.sh"

ledger_row() { # <pr> <ago-seconds> <kind> [size-json]
  jq -nc --argjson pr "$1" --arg ts "$(iso_ago "$2")" --arg k "$3" \
    --argjson size "${4:-null}" \
    '{src:"ledger", pr:$pr, ts:$ts, sha:"abc1234", kind:$k, verdict:"COMMENT", size:$size,
      bullets:{fixed:0, still:0}, findings:[]}' >> "$WORK/REVIEW-LEDGER.jsonl"
}

merged_fx() { # <json array of {number, merged_at}>
  printf '%s' "$1" | fx 'api repos/acme/widgets/pulls?state=closed&sort=updated&direction=desc&per_page=100'
}

# --- coverage, size, latency and conflicts all measured -----------------------
new_case project_measured
base_config
ledger_row 1 172800 first '{"files":3,"additions":40,"deletions":10}'
ledger_row 2 172800 first '{"files":9,"additions":100,"deletions":20}'
ledger_row 2 86400 re-review '{"files":9,"additions":100,"deletions":20}'
merged_fx "$(jq -nc --arg a "$(iso_ago 172800)" --arg b "$(iso_ago 86400)" \
  '[{number:1, merged_at:$a}, {number:2, merged_at:$b}, {number:3, merged_at:$b}]')"
{ jq -nc --arg ts "$(iso_ago 172800)" '{pr:1, kind:"first_review", ts:$ts, latency_hours:4}'
  jq -nc --arg ts "$(iso_ago 86400)"  '{pr:2, kind:"first_review", ts:$ts, latency_hours:10}'
  jq -nc --arg ts "$(iso_ago 86400)"  '{pr:2, kind:"conflict", ts:$ts}'
} > "$WORK/PR-EVENTS.jsonl"
jq -nc '{history:{dirs:[{dir:"src/api", critical:3, warning:2, still:1},
                        {dir:"src/ui", critical:0, warning:1, still:0},
                        {dir:"docs", critical:0, warning:0, still:0}]}}' > "$WORK/PROFILE.json"
run_preflight audit
assert_jq '.stats.project.coverage | .merged == 3 and .reviewed == 2 and .share == 67' 'coverage counts merged PRs against reviewed ones'
assert_jq '.stats.project.pr_size | .n == 2 and .median_files == 6 and .median_lines == 85' 'PR size is the median of the first reviews only'
assert_jq '.stats.project.human_latency | .n == 2 and .median_hours == 7' 'human latency is the median of the recorded first reviews'
assert_jq '.stats.project.conflicts == 1' 'a PR that hit a conflict is counted once'
assert_jq '(.stats.project.hot_areas | length) == 2 and .stats.project.hot_areas[0].dir == "src/api"' 'the areas with findings are ranked, the empty one dropped'

# --- nothing recorded → null, never zero -------------------------------------
new_case project_unmeasured
base_config
run_preflight audit
assert_jq '.stats.project.coverage | .merged == 0 and .share == null' 'no merged PR leaves the share unmeasured'
assert_jq '.stats.project.pr_size | .n == 0 and .median_files == null' 'no sized review leaves the median unmeasured'
assert_jq '.stats.project.human_latency | .n == 0 and .median_hours == null' 'no recorded review leaves the latency unmeasured'
assert_jq '.stats.project.conflicts == 0 and (.stats.project.hot_areas | length) == 0' 'no conflict and no profile read as empty'

# --- a ledger row written before `size` existed is not counted as zero --------
new_case project_legacy_rows
base_config
ledger_row 1 172800 first
merged_fx "$(jq -nc --arg a "$(iso_ago 172800)" '[{number:1, merged_at:$a}]')"
run_preflight audit
assert_jq '.stats.project.pr_size | .n == 0 and .median_files == null' 'a row without size is left out of the median'
assert_jq '.stats.project.coverage.share == 100' 'the same row still counts towards coverage'

# --- the window bounds every figure ------------------------------------------
new_case project_window
base_config
ledger_row 1 1814400 first '{"files":5,"additions":10,"deletions":1}'
merged_fx "$(jq -nc --arg old "$(iso_ago 1814400)" '[{number:1, merged_at:$old}]')"
jq -nc --arg ts "$(iso_ago 1814400)" '{pr:1, kind:"first_review", ts:$ts, latency_hours:99}' > "$WORK/PR-EVENTS.jsonl"
run_preflight audit
assert_jq '.stats.project.coverage.merged == 0' 'a PR merged before the window is not counted'
assert_jq '.stats.project.human_latency.n == 0' 'a first review before the window is not counted'

finish
