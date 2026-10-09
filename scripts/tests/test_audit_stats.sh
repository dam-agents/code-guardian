#!/usr/bin/env bash
# Audit stats: findings-effectiveness counters (this week's re-review Fixed vs
# Still-present bullets) + shepherd gating without Slack.
. "$(dirname "$0")/helpers.sh"

# --- findings acceptance counters ---------------------------------------------
new_case audit_findings
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
cat > "$WORK/reviews/pr-1.md" <<EOF
# PR #1: open PR

## Review at aaaaaaa — $(iso_ago 432000) — COMMENT

### Summary
first pass

## Review at bbbbbbb — $(iso_ago 172800) — COMMENT

### Changes since last review
- ✅ **Fixed:** null check added (\`src/a.ts:10\`)
- ✅ **Fixed:** race closed (\`src/b.ts:20\`)
- 🔁 **Still present:** unbounded retry (\`src/c.ts:30\`)
EOF
cat > "$WORK/reviews/pr-2.md" <<EOF
# PR #2: ancient PR

## Review at ccccccc — $(iso_ago 1814400) — COMMENT

### Changes since last review
- ✅ **Fixed:** out of the 7-day window (\`src/d.ts:1\`)
EOF
run_preflight audit
assert_jq '.mode == "audit" and .nothing_to_do == false' 'audit emits work'
assert_jq '.stats.findings.fixed == 2 and .stats.findings.still_present == 1' 'only in-window bullets counted'
assert_jq '.stats.reviews.total == 2 and .stats.reviews.re_review == 1' 'review counts sane'

# --- findings acceptance split by severity ------------------------------------
# the same fixed/still counts, keyed by the severity the findings-json line
# carries; a review section without that line stays outside the split
new_case audit_findings_severity
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
cat > "$WORK/reviews/pr-1.md" <<EOF
# PR #1: open PR

## Review at aaaaaaa — $(iso_ago 172800) — COMMENT

### Changes since last review
- ✅ **Fixed:** null check added (\`src/a.ts:10\`)
- 🔁 **Still present:** unbounded retry (\`src/c.ts:30\`)

<!-- findings-json: [{"status":"fixed","severity":"critical","file":"src/a.ts","line":10},{"status":"still","severity":"warning","file":"src/c.ts","line":30}] -->

## Review at bbbbbbb — $(iso_ago 1814400) — COMMENT

<!-- findings-json: [{"status":"still","severity":"critical","file":"src/z.ts","line":1}] -->
EOF
run_preflight audit
assert_jq '.stats.findings.json_reviews == 1' 'only in-window findings-json sections counted'
assert_jq '.stats.findings.by_severity == {critical: {fixed: 1, still: 0}, warning: {fixed: 0, still: 1}}' \
  'fixed/still split per severity'
assert_jq '.stats.findings.fixed == 1 and .stats.findings.still_present == 1' 'bullet counters unchanged'

new_case audit_findings_no_json
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
cat > "$WORK/reviews/pr-1.md" <<EOF
# PR #1: open PR

## Review at aaaaaaa — $(iso_ago 172800) — COMMENT

### Changes since last review
- ✅ **Fixed:** legacy history, no findings-json (\`src/a.ts:10\`)
EOF
run_preflight audit
assert_jq '.stats.findings.json_reviews == 0 and .stats.findings.by_severity == {}' \
  'history without findings-json reports an empty split, not an error'

new_case audit_findings_json_malformed
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
cat > "$WORK/reviews/pr-1.md" <<EOF
# PR #1: open PR

## Review at aaaaaaa — $(iso_ago 172800) — COMMENT

<!-- findings-json: [{"status":"fixed","severity":"critical"} -->

## Review at bbbbbbb — $(iso_ago 86400) — COMMENT

<!-- findings-json: [{"status":"fixed","severity":"warning"}] -->
EOF
run_preflight audit
assert_jq '.stats.findings.by_severity == {warning: {fixed: 1, still: 0}}' \
  'a truncated findings-json line is skipped, the week is still measured'

# --- the ledger carries the week past a prune ---------------------------------
# The bug this replaced: the week was counted from work/reviews/pr-*.md, and
# pruning deletes that file when the PR merges — so a busy week reported only
# the reviews of the PRs that were still open on audit day.
new_case audit_ledger_after_prune
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
ldg() { # <pr> <ts> <kind> <verdict> <findings-json> [<fixed> <still>]
  jq -nc --argjson pr "$1" --arg ts "$2" --arg k "$3" --arg v "$4" --argjson f "$5" \
    --argjson fx "${6:-0}" --argjson sp "${7:-0}" \
    '{src:"ledger", pr:$pr, ts:$ts, sha:"abc1234", kind:$k, verdict:$v,
      bullets:{fixed:$fx, still:$sp}, findings:$f}' >> "$WORK/REVIEW-LEDGER.jsonl"
}
# PR 7 merged and was pruned: no history file left, only its ledger rows
ldg 7 "$(iso_ago 172800)" first    REQUEST_CHANGES '[{"status":"new","severity":"critical"}]'
ldg 7 "$(iso_ago 86400)"  re-review APPROVE '[{"status":"fixed","severity":"critical"}]' 1 0
# PR 8 merged the same week, one review
ldg 8 "$(iso_ago 90000)"  first    COMMENT '[{"status":"new","severity":"warning"}]'
# outside the 7-day window
ldg 9 "$(iso_ago 1814400)" first   APPROVE '[]'
run_preflight audit
assert_jq '.stats.reviews.total == 3 and .stats.reviews.prs == 2' 'pruned PRs keep their reviews in the count'
assert_jq '.stats.reviews.first == 2 and .stats.reviews.re_review == 1' 'the ledger carries the reviewed kind'
assert_jq '.stats.reviews | .approve == 1 and .comment == 1 and .request_changes == 1' 'verdict split from the ledger'
assert_jq '.stats.findings.new == 2 and .stats.findings.new_by_severity == {critical: 1, warning: 1}' 'raised findings from the ledger'
assert_jq '.stats.findings.fixed == 1 and .stats.findings.by_severity == {critical: {fixed: 1, still: 0}}' 'acceptance from the ledger'

# --- a review in both places is counted once ----------------------------------
new_case audit_ledger_dedup
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
TS_DUP="$(iso_ago 86400)"
cat > "$WORK/reviews/pr-1.md" <<EOF
# PR #1: open PR

## Review at aaaaaaa — $TS_DUP — COMMENT

<!-- findings-json: [{"status":"new","severity":"warning"}] -->
EOF
jq -nc --arg ts "$TS_DUP" '{src:"ledger", pr:1, ts:$ts, sha:"aaaaaaa", kind:"re-review",
  verdict:"COMMENT", bullets:{fixed:0, still:0},
  findings:[{status:"new", severity:"warning"}]}' > "$WORK/REVIEW-LEDGER.jsonl"
run_preflight audit
assert_jq '.stats.reviews.total == 1 and .stats.findings.new == 1' 'the same review in both sources counts once'
assert_jq '.stats.reviews.re_review == 1' 'the ledger row wins over the file position'

# --- the two sources of the same week must stay comparable --------------------
new_case audit_ledger_gap
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
mkdir -p "$WORK/logs"
evg() { # <run> <pr> <msg> <secs-ago>
  jq -nc --arg r "$1" --arg m "PR #$2 abc1234 $3" --arg t "$(iso_ago "$4")" \
    '{ts:$t, run:$r, job:"review", level:"info", event:"review_step", msg:$m}' \
    >> "$WORK/logs/events-$(date -u +%Y-%m-%d).jsonl"
}
i=1
while [ "$i" -le 12 ]; do
  evg "r$i" "$((100+i))" locked 7800
  evg "r$i" "$((100+i))" done   7200
  i=$((i+1))
done
run_preflight audit
assert_jq '.stats.reviews.total == 0 and .stats.reviews.duration.n == 12' 'the log measured 12 runs the ledger has no row for'
assert_jq '[.checks[] | select(.id == "review_ledger")] | length == 1 and .[0].status == "warn"' 'the gap between the two sources warns'

# --- review wall-clock (locked -> done) ---------------------------------------
# time-to-first-review = queue wait + this; the median separates the two
new_case audit_review_duration
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
mkdir -p "$WORK/logs"
evd() { # <run> <msg> <secs-ago>
  jq -nc --arg r "$1" --arg m "$2" --arg t "$(iso_ago "$3")" \
    '{ts:$t, run:$r, job:"review", level:"info", event:"review_step", msg:$m}' \
    >> "$WORK/logs/events-$(date -u +%Y-%m-%d).jsonl"
}
evd r1 "PR #10 abc1234 locked" 7800     # 10 min to done
evd r1 "PR #10 abc1234 done"   7200
evd r2 "PR #11 def5678 locked" 7800     # 20 min to done
evd r2 "PR #11 def5678 done"   6600
evd r3 "PR #12 aaa1111 locked" 7800     # never terminal — no duration
evd r4 "sweeping stale clones" 7800     # outside the documented msg shape
run_preflight audit
assert_jq '.stats.reviews.duration.n == 2' 'only locked-and-done pairs measured'
assert_jq '.stats.reviews.duration.median_min == 15' 'median of 10 and 20 minutes'

new_case audit_review_duration_empty
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
run_preflight audit
assert_jq '.stats.reviews.duration == {n: 0, median_min: null}' 'no reviews → unmeasured, not zero'
assert_jq '.stats.reviews.phases | to_entries | all(.value == {n: 0, median_min: null})' 'no reviews → every phase unmeasured too'

# --- millisecond timestamps still parse ----------------------------------------
# log.sh writes `%3N` where date supports it (the pod), so a stat that hands
# `.ts` to fromdateiso8601 raw throws and returns nothing at all.
new_case audit_duration_millis
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
mkdir -p "$WORK/logs"
evm() { # <run> <msg> <secs-ago> — a millisecond-precision ts
  jq -nc --arg r "$1" --arg m "$2" --arg t "$(iso_ago "$3" | sed 's/Z$/.123Z/')" \
    '{ts:$t, run:$r, job:"review", level:"info", event:"review_step", msg:$m}' \
    >> "$WORK/logs/events-$(date -u +%Y-%m-%d).jsonl"
}
evm r1 "PR #10 abc1234 locked" 7800
evm r1 "PR #10 abc1234 done"   7200
run_preflight audit
assert_jq '.stats.reviews.duration == {n: 1, median_min: 10}' 'a millisecond timestamp is measured, not dropped'

# --- review time per phase (stats.reviews.phases) ------------------------------
new_case audit_review_phases
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
mkdir -p "$WORK/logs"
evp() { # <run> <msg> <secs-ago>
  jq -nc --arg r "$1" --arg m "$2" --arg t "$(iso_ago "$3")" \
    '{ts:$t, run:$r, job:"review", level:"info", event:"review_step", msg:$m}' \
    >> "$WORK/logs/events-$(date -u +%Y-%m-%d).jsonl"
}
# a re-review: prepare 1, diff 3, skills 20, delta 15, compose 10, post 2
evp r1 "PR #10 abc1234 locked"                          7800
evp r1 "PR #10 abc1234 cloned"                          7740
evp r1 "PR #10 abc1234 fanned out (n=2)"                7560
evp r1 "PR #10 abc1234 locked (refresh, fanned out (n=2))" 7560
evp r1 "PR #10 abc1234 verified"                        6360
evp r1 "PR #10 abc1234 delta settled (still=2, new=1, fixed=0, ambiguous=1)" 5460
evp r1 "PR #10 abc1234 composed"                        4860
evp r1 "PR #10 abc1234 posted COMMENT"                  4740
evp r1 "PR #10 abc1234 done"                            4740
# a first review: no delta, compose measured from `verified`
evp r2 "PR #11 def5678 locked"           3600
evp r2 "PR #11 def5678 cloned"           3540
evp r2 "PR #11 def5678 fanned out (n=2)" 3480
evp r2 "PR #11 def5678 verified"         2880
evp r2 "PR #11 def5678 composed"         2760
evp r2 "PR #11 def5678 posted APPROVE"   2700
evp r2 "PR #11 def5678 done"             2700
run_preflight audit
assert_jq '.stats.reviews.phases.skills == {n: 2, median_min: 15}' 'the skill phase is bounded by fanned out → verified'
assert_jq '.stats.reviews.phases.delta == {n: 1, median_min: 15}' 'only the re-review has a delta round'
assert_jq '.stats.reviews.phases.compose == {n: 2, median_min: 6}' 'compose falls back to verified where no delta ran'
assert_jq '.stats.reviews.phases.post == {n: 2, median_min: 1}' 'the post is bounded by composed → posted'
assert_jq '.stats.reviews.phases.prepare.n == 2 and .stats.reviews.phases.diff_review.n == 2' 'prepare and the diff review are measured per run'
assert_jq '.stats.reviews.duration == {n: 2, median_min: 33}' 'the total is still locked → done, median of 51 and 15'

# --- shepherd activity: PRs nudged, from the ledger ---------------------------
# SHEPHERD.log's "N nudges due" lines re-count a PR every sweep it stays due;
# the ledger's last_nudge_at is one row per PR actually nudged
new_case audit_nudges_from_ledger
base_config '- slack_notifications: enabled'
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
{
  printf '| PR | eligible_since | reviewers | review_state | nudges | last_nudge_at | level | status |\n'
  printf '|----|----|----|----|----|----|----|----|\n'
  printf '| 22 | %s | bob | awaiting_review | 1 | %s | 2 | watching |\n' "$(iso_ago 500000)" "$(iso_ago 90000)"
  printf '| 23 | %s | bob | awaiting_review | 3 | %s | 4 | held |\n'     "$(iso_ago 900000)" "$(iso_ago 1814400)"
  printf '| 24 | %s | bob | awaiting_review | 0 | - | 1 | watching |\n'  "$(iso_ago 100000)"
} > "$WORK/SHEPHERD.md"
for i in 1 2 3; do
  printf '%s shepherd sweep: 4 open PRs, 3 nudges due\n' "$(iso_ago $((i * 3600)))" >> "$WORK/SHEPHERD.log"
done
run_preflight audit
assert_jq '.stats.nudges == {prs_nudged: 1, prs: ["22"]}' \
  'one PR nudged in the window, not the 9 the sweep log claims'
assert_jq '.stats | has("nudges_claimed") == false' 'the overcounting field is gone'

# --- nudges from the PR facts: a pruned PR still counts ------------------------
new_case audit_nudges_from_facts
base_config '- slack_notifications: enabled'
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
{
  printf '| PR | eligible_since | reviewers | review_state | nudges | last_nudge_at | level | status |\n'
  printf '|----|----|----|----|----|----|----|----|\n'
  printf '| 22 | %s | bob | awaiting_review | 1 | %s | 2 | watching |\n' "$(iso_ago 500000)" "$(iso_ago 90000)"
} > "$WORK/SHEPHERD.md"
{
  jq -nc --arg t "$(iso_ago 90000)" '{pr:22, kind:"nudged", ts:$t, level:2}'
  jq -nc --arg t "$(iso_ago 200000)" '{pr:31, kind:"nudged", ts:$t, level:1}'
  jq -nc --arg t "$(iso_ago 100000)" '{pr:31, kind:"nudged", ts:$t, level:2}'
  jq -nc --arg t "$(iso_ago 1814400)" '{pr:40, kind:"nudged", ts:$t, level:1}'
  printf 'not json\n'
} > "$WORK/PR-EVENTS.jsonl"
run_preflight audit
assert_jq '.stats.nudges == {prs_nudged: 2, prs: ["22", "31"]}' \
  'facts and ledger rows union per PR; a pruned PR counts, an old fact does not'

# --- memory budget names the biggest sections ---------------------------------
new_case audit_memory_sections
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
{
  printf '# Memory\n\n## Custom Rules\n'
  for i in $(seq 1 200); do printf -- '- rule %s\n' "$i"; done
  printf '\n## Observed Insights\n'
  for i in $(seq 1 5); do printf -- '- insight %s\n' "$i"; done
} > "$WORK/MEMORY.md"
run_preflight audit
assert_jq '.checks[] | select(.id == "memory_budget") | .status == "fail" and (.detail | test("biggest sections: Custom Rules 20[0-9]"))' \
  'the over-budget check names where the lines are'

# a rule whose wording never moved to its topic file keeps the budget over,
# whatever the line count (docs/preferences.md → Entry form)
new_case audit_memory_long_line
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
# 120 chars is the bound itself and stays allowed; 121 is past it
{
  printf '# Memory\n\n## Custom Rules\n'
  printf -- '- [2026-07-24 from user] Skip JSDoc findings → memory/style.md\n'
  printf -- '- %s\n' "$(printf 'x%.0s' $(seq 1 118))"
  printf -- '- %s\n' "$(printf 'y%.0s' $(seq 1 119))"
} > "$WORK/MEMORY.md"
run_preflight audit
assert_jq '.checks[] | select(.id == "memory_budget") | .status == "warn" and (.detail | contains("1 past 120 chars"))' \
  'an undistilled line puts the budget over on its own, the 120-char line does not'

new_case audit_memory_within_bounds
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
printf '# Memory\n\n## Custom Rules\n- one rule\n' > "$WORK/MEMORY.md"
run_preflight audit
assert_jq '.checks[] | select(.id == "memory_budget") | .status == "ok" and (.detail | contains("0 past 120 chars"))' \
  'short lines keep the budget green'
assert_jq '.checks[] | select(.id == "memory_budget") | .detail | contains("biggest sections") | not' \
  'a file within bounds is not scanned per section'

# the distilled layer is bounded file by file; the archive is never measured
# (docs/preferences.md → Two layers)
new_case audit_memory_two_layers
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
printf '# Memory\n\n## Custom Rules\n- one rule\n' > "$WORK/MEMORY.md"
mkdir -p "$WORK/memory/archive"
{ printf -- '---\nscope:\n  - src/a/**\n---\n'; for i in $(seq 1 40); do printf -- '- rule %s\n' "$i"; done; } > "$WORK/memory/short.md"
for i in $(seq 1 5000); do printf 'archived detail line %s\n' "$i"; done > "$WORK/memory/archive/short.md"
run_preflight audit
assert_jq '.checks[] | select(.id == "memory_budget") | .status == "ok"' \
  'a 40-line area file is inside the bound, and a 5000-line archive is never counted'
{ printf -- '---\nscope:\n  - src/b/**\n---\n'; for i in $(seq 1 41); do printf -- '- rule %s\n' "$i"; done; } > "$WORK/memory/long.md"
printf '# a reference file\n- no scope\n' > "$WORK/memory/notes.md"
printf -- '---\npaths: [src/c/**]\n---\n- one rule\n' > "$WORK/memory/aliased.md"
run_preflight audit
assert_jq '.checks[] | select(.id == "memory_budget") | .status == "warn" and (.detail | contains("1 over 40 lines or 120 chars (long)") and contains("1 without scope, archive them (notes)"))' \
  'an area file past 40 lines and a file without scope put the budget over'
assert_jq '.checks[] | select(.id == "memory_budget") | .detail | contains("aliased") | not' \
  'a file scoped by `paths:` is loaded by reviews, so it is no unscoped file'
# the pod has no awk: the budget is measured with sed/grep alone
mkdir -p "$SANDBOX/noawk"; printf '#!/bin/sh\nexit 127\n' > "$SANDBOX/noawk/awk"; chmod +x "$SANDBOX/noawk/awk"
OUT="$(GH_HOST="" WORK_DIR="$WORK" HOME="$FAKE_HOME" PATH="$SANDBOX/noawk:$T_DIR/bin:$PATH" \
       bash "$REPO_ROOT/scripts/preflight.sh" memory)"
assert_jq '.area_over == ["long"] and .area_unscoped == ["notes"] and .area_max_lines == 41 and .over_budget' \
  'memory mode prints the budget alone, measured without awk'
for i in $(seq 1 70); do printf -- '- rule %s\n' "$i"; done >> "$WORK/memory/long.md"
run_preflight audit
assert_jq '.checks[] | select(.id == "memory_budget") | .status == "fail"' 'an area file at 1.5x the bound is a fail'
rm -f "$WORK/memory/long.md" "$WORK/memory/notes.md" "$WORK/memory/aliased.md"
{ printf '# Operational Lessons\n\n## 1. Traps\n'; for i in $(seq 1 120); do printf -- '- lesson %s\n' "$i"; done; } > "$WORK/LESSONS.md"
run_preflight audit
assert_jq '.checks[] | select(.id == "memory_budget") | .status == "warn" and (.detail | contains("LESSONS.md 1/10 sections, 123/100 lines"))' \
  'LESSONS.md is bounded by lines, not only by sections'

# --- definition-repo open-issue backlog check ----------------------------------
new_case audit_issue_backlog
base_config '- definition_repo: acme/guardian'
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
fx 'api --hostname github.com repos/acme/guardian/issues?state=open&per_page=100' <<'EOF'
[
 {"number": 31, "title": "[channel request] Heads-up on CRD bumps"},
 {"number": 90, "title": "a PR, not an issue", "pull_request": {"url": "x"}}
]
EOF
run_preflight audit
assert_jq '[.checks[] | select(.id == "definition_issues")] | length == 1' 'backlog check present'
assert_jq '.checks[] | select(.id == "definition_issues") | .status == "warn" and (.detail | contains("1 open issue") and contains("#31"))' 'counts issues only (PRs filtered), lists them'

# --- harness_adapter: every hook must be registered ---------------------------
# settings.json listing only some adapter hooks is a warn naming the missing
# ones (an upgraded instance that never re-ran install.sh).
write_settings() { mkdir -p "$FAKE_HOME/.claude"; cat > "$FAKE_HOME/.claude/settings.json"; }

new_case audit_hooks_partial
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
write_settings <<'EOF'
{"hooks":{"PostToolUseFailure":[{"hooks":[{"command":"/home/agent/scripts/harness/claude-code/log-tool-event.sh"}]}],
          "SessionEnd":[{"hooks":[{"command":"/home/agent/scripts/harness/claude-code/log-session-tokens.sh"}]}]}}
EOF
CLAUDECODE=1 run_preflight audit
assert_jq '.checks[] | select(.id == "harness_adapter") | .status == "warn" and (.detail | contains("enforce-review-completion.sh"))' 'missing Stop hook warns by name'

new_case audit_hooks_complete
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
write_settings <<'EOF'
{"hooks":{"PostToolUseFailure":[{"hooks":[{"command":"/home/agent/scripts/harness/claude-code/log-tool-event.sh"}]}],
          "PostToolUse":[{"hooks":[{"command":"/home/agent/scripts/harness/claude-code/log-review-step.sh"}]}],
          "SessionEnd":[{"hooks":[{"command":"/home/agent/scripts/harness/claude-code/log-session-tokens.sh"}]}],
          "Stop":[{"hooks":[{"command":"/home/agent/scripts/harness/claude-code/enforce-review-completion.sh"}]}]},
 "autoMode":{"environment":["$defaults","[code-guardian] This is an unattended code review agent."]}}
EOF
CLAUDECODE=1 run_preflight audit
assert_jq '.checks[] | select(.id == "harness_adapter") | .status == "warn" and (.detail | contains("tool-deny") and contains("skill-agent"))' 'hooks without the deny list and the review-skill agent warn by part'
# the parts install.sh adds: the deny list and the review-skill agent
ADAPTER="$REPO_ROOT/scripts/harness/claude-code"
DENY_JSON="$(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$ADAPTER/denied-tools.txt" | jq -Rsc 'split("\n") | map(select(length > 0))')"
jq --argjson d "$DENY_JSON" '.permissions.deny = (["Bash(rm -rf *)"] + $d)' "$FAKE_HOME/.claude/settings.json" > "$SANDBOX/s.json" \
  && write_settings < "$SANDBOX/s.json"
mkdir -p "$FAKE_HOME/.claude/agents" && cp "$ADAPTER/agents/review-skill.md" "$FAKE_HOME/.claude/agents/"
CLAUDECODE=1 run_preflight audit
assert_jq '.checks[] | select(.id == "harness_adapter") | .status == "ok"' 'all hooks, auto-mode rules, deny list and agent installed → ok'
echo "stale" >> "$FAKE_HOME/.claude/agents/review-skill.md"
CLAUDECODE=1 run_preflight audit
assert_jq '.checks[] | select(.id == "harness_adapter") | .status == "warn" and (.detail | contains("skill-agent")) and (.detail | contains("tool-deny") | not)' 'a stale agent file warns alone'
cp "$ADAPTER/agents/review-skill.md" "$FAKE_HOME/.claude/agents/"

# the hooks alone, without the [code-guardian] auto-mode rules: install.sh not re-run
HOOKS_ONLY="$(jq 'del(.autoMode)' "$FAKE_HOME/.claude/settings.json")"
printf '%s\n' "$HOOKS_ONLY" | write_settings
CLAUDECODE=1 run_preflight audit
assert_jq '.checks[] | select(.id == "harness_adapter") | .status == "warn" and (.detail | contains("autoMode-rules"))' 'missing auto-mode rules warn'

# rules written before definition_repo was configured lack the tracking-issue rule
new_case audit_hooks_stale_automode
base_config '- definition_repo: acme/guardian'
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
mkdir -p "$FAKE_HOME/.claude/agents" && cp "$ADAPTER/agents/review-skill.md" "$FAKE_HOME/.claude/agents/"
printf '%s\n' "$HOOKS_ONLY" | jq '.autoMode.allow = ["$defaults", "[code-guardian] Uploading a file under work/audit/."]' | write_settings
CLAUDECODE=1 run_preflight audit
assert_jq '.checks[] | select(.id == "harness_adapter") | .status == "warn" and (.detail | contains("autoMode-rules"))' 'rules without the definition repo warn'
printf '%s\n' "$HOOKS_ONLY" | jq '.autoMode.allow = ["$defaults", "[code-guardian] Opening a tracking issue on acme/guardian with gh issue create."]' | write_settings
CLAUDECODE=1 run_preflight audit
assert_jq '.checks[] | select(.id == "harness_adapter") | .status == "ok"' 'rules naming the definition repo → ok'

new_case audit_hooks_missing_step_logger
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
write_settings <<'EOF'
{"hooks":{"PostToolUseFailure":[{"hooks":[{"command":"/home/agent/scripts/harness/claude-code/log-tool-event.sh"}]}],
          "SessionEnd":[{"hooks":[{"command":"/home/agent/scripts/harness/claude-code/log-session-tokens.sh"}]}],
          "Stop":[{"hooks":[{"command":"/home/agent/scripts/harness/claude-code/enforce-review-completion.sh"}]}]}}
EOF
CLAUDECODE=1 run_preflight audit
assert_jq '.checks[] | select(.id == "harness_adapter") | .status == "warn" and (.detail | contains("log-review-step.sh"))' 'missing step-logger hook warns by name'


# --- wasted-review metric (stats.stalls) --------------------------------------
# a run that locked a PR and never reached a terminal step threw its work away;
# classified by cause, and runs still in flight must NOT be counted.
ev() { # <run> <event> <msg> [ts]
  jq -nc --arg r "$1" --arg e "$2" --arg m "$3" --arg t "${4:-$(iso_ago 7200)}" \
    '{ts:$t, run:$r, job:"review", level:"info", event:$e, msg:$m}' \
    >> "$WORK/logs/events-$(date -u +%Y-%m-%d).jsonl"
}

new_case audit_stalls_metric
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
mkdir -p "$WORK/logs"
# r1: locked, then done -> completed, not wasted
ev r1 review_step "PR #10 abc1234 locked"
ev r1 review_step "PR #10 abc1234 done"
ev r1 tokens "input=1 output=1000 cache_read=1 cache_creation=1 msgs=5"
# r2: locked, SessionEnd fired, never terminal -> terminated
ev r2 review_step "PR #11 def5678 locked"
ev r2 review_step "PR #11 def5678 skill:doc-drift done"
ev r2 tokens "input=1 output=5000 cache_read=1 cache_creation=1 msgs=9"
# r3: locked, no tokens event at all -> hard_kill
ev r3 review_step "PR #12 aaa1111 locked"
# r4: explicit abort -> terminal, counts as a clean abort not a stall
ev r4 review_step "PR #13 bbb2222 locked"
ev r4 review_step "PR #13 bbb2222 aborted HEAD-moved"
ev r4 tokens "input=1 output=2000 cache_read=1 cache_creation=1 msgs=6"
# r5: locked seconds ago and still working -> excluded (live, not a stall)
ev r5 review_step "PR #14 ccc3333 locked" "$(iso_ago 60)"
run_preflight audit
assert_jq '.stats.stalls.total == 4' 'live run excluded from the locked-run total'
assert_jq '.stats.stalls.stalled == 2' 'only the two dead unfinished runs count'
assert_jq '.stats.stalls.by_cause.terminated == 1 and .stats.stalls.by_cause.hard_kill == 1' \
  'causes split by whether SessionEnd fired'
assert_jq '.stats.stalls.aborted_clean == 1' 'an explicit abort is a clean outcome, not a stall'
assert_jq '.stats.stalls.wasted_output_tokens == 5000' 'wasted tokens sum only the stalled runs'
assert_jq '.stats.stalls.redone_prs == ["11","12"]' 'redone PRs are the stalled ones only'
assert_jq '.stats.stalls.per_day | length >= 1' 'per-day trend present'

# --- all-green audit: no stalls at all ----------------------------------------
new_case audit_stalls_none
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
mkdir -p "$WORK/logs"
ev r1 review_step "PR #10 abc1234 locked"
ev r1 review_step "PR #10 abc1234 done"
ev r1 tokens "input=1 output=1000 cache_read=1 cache_creation=1 msgs=5"
run_preflight audit
assert_jq '.stats.stalls.stalled == 0' 'a clean week reports zero stalls'
assert_jq '.stats.stalls.wasted_output_tokens == 0' 'nothing wasted'

# --- weekly token totals: one count per run (stats.tokens) -------------------
# the tokens event carries cumulative totals and a resumed session ends twice:
# a run counts its last event alone, an event with no run id counts on its own
new_case audit_tokens_per_run
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
mkdir -p "$WORK/logs"
ev t1 review_step "PR #10 abc1234 locked" "$(iso_ago 7300)"
ev t1 tokens "input=1 output=100 cache_read=1000 cache_creation=10 msgs=5 model=claude-opus-5-5" "$(iso_ago 7200)"
ev t1 tokens "input=2 output=300 cache_read=3000 cache_creation=30 msgs=9 model=claude-opus-5-5" "$(iso_ago 3600)"
ev t2 tokens "input=4 output=50 cache_read=500 cache_creation=5 msgs=2 model=claude-sonnet-5-5"
jq -nc --arg t "$(iso_ago 600)" '{ts:$t, level:"info", event:"tokens", msg:"input=8 output=7 cache_read=6 cache_creation=5 msgs=1"}' \
  >> "$WORK/logs/events-$(date -u +%Y-%m-%d).jsonl"
run_preflight audit
assert_jq '.stats.tokens | .runs == 3 and .input == 14 and .output == 357 and .cache_read == 3506 and .cache_creation == 40' \
  'a run counts its last cumulative event once; an event without a run counts on its own'
assert_jq '.stats.tokens.by_model["claude-opus-5-5"] | .runs == 1 and .output == 300' 'by_model counts the same set'
assert_jq '.stats.tokens.by_model.unknown.runs == 1 and .stats.tokens.by_model["claude-sonnet-5-5"].output == 50' \
  'every model row comes from the deduped set'
assert_jq '.stats.stalls.wasted_output_tokens == 300' 'a stalled run wastes its last cumulative output, not the sum'

# --- log_errors: a zero count is a success line --------------------------------
new_case audit_log_errors_zero_count
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
printf '%s shepherd run: 3 nudges sent, 0 failed\n%s shepherd run: errors=0\n' "$(iso_ago 3600)" "$(iso_ago 3000)" >> "$WORK/SHEPHERD.log"
run_preflight audit
assert_jq '.checks[] | select(.id == "log_errors") | .status == "ok"' 'zero-count lines are not error lines'
printf '%s shepherd run: 1 nudge sent, 10 failed\n' "$(iso_ago 1800)" >> "$WORK/SHEPHERD.log"
run_preflight audit
assert_jq '.checks[] | select(.id == "log_errors") | .status == "warn" and (.detail | test("^1 error-ish log lines.*10 failed$"))' \
  'a non-zero failure count still matches'
printf '%s PR #57 9c1e2a0 failed to post: 422\n%s review post failed: 0f3e2a1 is stale\n' "$(iso_ago 1200)" "$(iso_ago 600)" >> "$WORK/SHEPHERD.log"
run_preflight audit
assert_jq '.checks[] | select(.id == "log_errors") | .status == "warn" and (.detail | test("^3 error-ish log lines.*0f3e2a1 is stale$"))' \
  'a hex token next to a failure word is not a zero count'

# --- wake-ups: the preflight passes that found work, by kind of work ---------
new_case audit_wakeups
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
mkdir -p "$WORK/logs"
ev g1 heartbeat "mode=review nothing_to_do=true reviews=0 nudges=0 mentions=0 artifacts=0 cleanups=0 alerts=0 ci=0 stall=0 housekeeping=0"
ev g2 heartbeat "mode=review nothing_to_do=false reviews=2 nudges=0 mentions=1 artifacts=0 cleanups=0 alerts=0 ci=0 stall=0 housekeeping=0"
ev g3 heartbeat "mode=review nothing_to_do=false reviews=0 nudges=0 mentions=0 artifacts=1 cleanups=0 alerts=0 ci=0 stall=0 housekeeping=0"
ev g4 heartbeat "mode=review nothing_to_do=false reviews=0 nudges=0 mentions=0 artifacts=0 cleanups=0 alerts=0 ci=0 stall=0 housekeeping=1"
ev g5 heartbeat "mode=shepherd nothing_to_do=false reviews=0 nudges=3 mentions=0 artifacts=0 cleanups=0 alerts=0 ci=0 stall=0 housekeeping=0"
# written before the kind keys existed: counted, but names no kind
ev g6 heartbeat "mode=review nothing_to_do=false reviews=0 nudges=0 mentions=0"
# outside the 7-day window
ev g7 heartbeat "mode=review nothing_to_do=false reviews=5 nudges=0 mentions=0" "$(iso_ago 700000)"
run_preflight audit
assert_jq '.stats.wakeups.runs == 5' 'woken runs in the window only, idle ticks excluded'
assert_jq '.stats.wakeups.by_mode == {review: 4, shepherd: 1}' 'wake-ups split by mode'
assert_jq '.stats.wakeups.by_work.reviews == {runs: 1, items: 2}' 'review runs and items'
assert_jq '.stats.wakeups.by_work.mentions.runs == 1 and .stats.wakeups.by_work.artifacts.runs == 1' \
  'a mention reply and an artifact each count as a run'
assert_jq '.stats.wakeups.by_work.nudges.items == 3 and .stats.wakeups.by_work.housekeeping.runs == 1' \
  'nudges and bookkeeping-only runs counted'
assert_jq '.stats.wakeups.unlabelled == 1' 'a legacy event is counted but unlabelled'

# the heartbeats preflight itself writes, read back by the audit: every kind the
# audit counts is a key some writer emits, and no current writer is unlabelled
new_case audit_wakeups_roundtrip
base_config '- survey: enabled' '- benchmark: enabled'
mkdir -p "$WORK/survey"
jq -n '{modules:[{path:"src/api",name:"api"}], noise:[], history:{dirs:[]}}' > "$WORK/PROFILE.json"
run_preflight survey
run_preflight benchmark
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
run_preflight review
run_preflight audit
assert_jq '.stats.wakeups.by_mode == {survey: 1, benchmark: 1, review: 1}' 'each pass with work is a wake-up'
assert_jq '.stats.wakeups.by_work.reviews == {runs: 1, items: 1}
  and .stats.wakeups.by_work.survey.runs == 1 and .stats.wakeups.by_work.benchmark.runs == 1' \
  'each pass counts under its own kind'
assert_jq '.stats.wakeups.unlabelled == 0' 'no current writer is unlabelled'
missing="$(jq -rs --argjson k "$(printf '%s' "$OUT" | jq -c '.stats.wakeups.by_work | keys')" '
  [ .[] | select(.event == "heartbeat") | .msg ] as $m
  | [ $k[] as $x | select(any($m[]; test("(^| )" + $x + "=[0-9]+( |$)")) | not) | $x ] | join(", ")' \
  "$WORK"/logs/events-*.jsonl 2>/dev/null)" || missing="(the query failed)"
[ -z "$missing" ] && printf 'ok   %s: every kind the audit reads is a key a heartbeat writes\n' "$CASE" \
  || { printf 'FAIL %s: kinds no heartbeat writes: %s\n' "$CASE" "$missing"; FAILED=1; }
unread="$(jq -rs --argjson k "$(printf '%s' "$OUT" | jq -c '.stats.wakeups.by_work | keys')" '
  [ .[] | select(.event == "heartbeat") | .msg | scan("([a-z_]+)=") | .[0] ] | unique
  | map(select(. != "mode" and . != "nothing_to_do" and (. as $x | $k | index($x) | not))) | join(", ")' \
  "$WORK"/logs/events-*.jsonl 2>/dev/null)" || unread="(the query failed)"
[ -z "$unread" ] && printf 'ok   %s: every kind a heartbeat writes is a kind the audit reads\n' "$CASE" \
  || { printf 'FAIL %s: heartbeat kinds the audit ignores: %s\n' "$CASE" "$unread"; FAILED=1; }

# --- reaction feedback: 👍/👎 on the bot's comments ----------------------------
new_case audit_reactions
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
fx 'api repos/acme/widgets/pulls/comments?per_page=100&sort=created&direction=desc' <<'EOF'
[
 {"user":{"login":"test-bot"},"html_url":"https://example.test/rc/1","reactions":{"+1":2,"-1":1}},
 {"user":{"login":"alice"},"html_url":"https://example.test/rc/2","reactions":{"+1":9,"-1":9}}
]
EOF
fx 'api repos/acme/widgets/issues/comments?per_page=100&sort=created&direction=desc' <<'EOF'
[
 {"user":{"login":"test-bot"},"html_url":"https://example.test/c/3","reactions":{"+1":1}}
]
EOF
run_preflight audit
assert_jq '.stats.reactions == {up: 3, down: 1, down_urls: ["https://example.test/rc/1"], scanned: 2}' \
  'reactions summed over bot comments only, 👎 URLs listed'

# --- a realistic comment payload still gets scanned ---------------------------
# two pages of real comments are ~768 KB; passed as jq arguments they exceed
# MAX_ARG_STRLEN (128 KiB per single argument on Linux, independent of the much
# larger ARG_MAX) and execve fails, so the scan silently reported zeros on every
# busy week. Sized here to break the argv form on macOS too, so the guard holds
# wherever the suite runs.
new_case audit_reactions_large_payload
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
jq -nc '[range(150) | {user:{login:"test-bot"},
                       html_url:("https://example.test/rc/" + (.|tostring)),
                       body:("x" * 4000),
                       reactions:{"+1":1,"-1":0}}]' \
  | fx 'api repos/acme/widgets/pulls/comments?per_page=100&sort=created&direction=desc'
jq -nc '[range(150) | {user:{login:"alice"},
                       html_url:("https://example.test/c/" + (.|tostring)),
                       body:("y" * 4000),
                       reactions:{"+1":1,"-1":1}}]' \
  | fx 'api repos/acme/widgets/issues/comments?per_page=100&sort=created&direction=desc'
run_preflight audit
assert_jq '.stats.reactions.scanned == 150 and .stats.reactions.up == 150' \
  'a ~1.2 MB payload is scanned, not silently dropped'
assert_jq '[.checks[] | select(.id == "reaction_scan")] | length == 0' \
  'a working scan raises no warn'

# --- an unreadable comment list is unmeasured, not zero ------------------------
new_case audit_reactions_unreadable
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
printf '{"message":"Not Found"}' \
  | fx 'api repos/acme/widgets/pulls/comments?per_page=100&sort=created&direction=desc'
run_preflight audit
assert_jq '.stats.reactions.scanned == null' 'a faulted read reports null, not 0'
assert_jq '.checks[] | select(.id == "reaction_scan") | .status == "warn"' \
  'the dead check warns instead of reporting a clean zero'

# --- heartbeat gap tolerance follows the quiet cadence ------------------------
# A quiet-hour tick legitimately leaves a gap the length of review_interval_quiet;
# the check must scale to it instead of warning on every configured night.
hb() { printf '%s review nothing_to_do=true\n' "$(iso_ago "$1")" >> "$WORK/HEARTBEAT.log"; }

new_case audit_gap_within_quiet_cadence
base_config '- review_interval_quiet: 60'
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
hb 9000; hb 4500; hb 3600   # 75-min gap, then 15 min
run_preflight audit
assert_jq '.checks[] | select(.id == "heartbeats") | .status == "ok"' \
  'a 75-min gap is fine under a 60-min quiet cadence'

new_case audit_gap_beyond_quiet_cadence
base_config '- review_interval_quiet: 60'
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
hb 9600; hb 3600            # 100-min gap — past 1.5x the quiet interval
run_preflight audit
assert_jq '.checks[] | select(.id == "heartbeats") | .status == "warn" and (.detail | contains("100 min"))' \
  'a gap past 1.5x the quiet interval still warns'

# --- raised findings, the awaiting_label backlog and the worklist dump --------
# The trend artifact reads these three (docs/trends.md): findings the week
# raised, the trigger backlog, and preflight's own worklist on disk.
new_case audit_trend_inputs
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
add_row 7 abc1234 "$(iso_ago 900000)" COMMENT awaiting_label
add_row 8 abc5678 "$(iso_ago 200000)" COMMENT awaiting_label
add_row 9 abc9012 "$(iso_ago 100000)" COMMENT done
cat > "$WORK/reviews/pr-1.md" <<EOF
# PR #1: open PR

## Review at aaaaaaa — $(iso_ago 200000) — COMMENT
<!-- findings-json: [{"status":"new","severity":"critical","file":"a.ts","line":1,"summary":"x","fix":"y"},{"status":"new","severity":"suggestion","file":"a.ts","line":9,"summary":"x","fix":null}] -->

## Review at bbbbbbb — $(iso_ago 100000) — COMMENT

### Changes since last review
- ✅ **Fixed:** null check added (\`a.ts:1\`)
<!-- findings-json: [{"status":"fixed","severity":"critical","file":"a.ts","line":1,"summary":"x","fix":null},{"status":"new","severity":"warning","file":"b.ts","line":4,"late":true,"summary":"x","fix":"y"}] -->
EOF
run_preflight audit
assert_jq '.stats.findings.new == 3' 'every status:new finding of the window counted'
assert_jq '.stats.findings.late == 1' 'a new finding an earlier round missed is counted late'
assert_jq '.stats.findings.new_by_severity.critical == 1 and .stats.findings.new_by_severity.warning == 1
           and .stats.findings.new_by_severity.suggestion == 1' 'raised findings split by severity'
assert_jq '.stats.findings.fixed == 1' 'the acceptance counters stay as they were'
assert_jq '.stats.awaiting_label.n == 2 and .stats.awaiting_label.oldest_days == 10'   'the awaiting_label backlog carries its count and the oldest row age'
assert_file_contains "$WORK/audit/last-worklist.json" '"nothing_to_do": false'   'audit mode leaves its worklist on disk for the trend step'
if [ "$(jq -r '.stats.findings.new' "$WORK/audit/last-worklist.json" 2>/dev/null)" = "3" ]; then
  printf 'ok   %s: the dumped worklist is the printed one\n' "$CASE"
else printf 'FAIL %s: dumped worklist does not match the output\n' "$CASE"; FAILED=1; fi

# the trend-currency check: a history that stopped growing is a warn
new_case audit_trend_stalled
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
mkdir -p "$WORK/audit/weeks"
printf '{"week":"2026-W01","source":"audit","stats":{}}\n' > "$WORK/audit/weeks/old.json"
touch -t 202601010000 "$WORK/audit/weeks/old.json" 2>/dev/null || true
run_preflight audit
assert_jq '.checks[] | select(.id == "audit_trend") | .status == "warn"' \
  'a trend history with no recent append warns'

new_case audit_trend_inputs_empty
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
run_preflight audit
assert_jq '.stats.findings.new == 0 and (.stats.findings.new_by_severity | length) == 0'   'a week with no findings-json reports zero raised findings'
assert_jq '.stats.awaiting_label == {n:0, oldest_days:null}' 'an empty backlog has no age'
assert_jq '.checks[] | select(.id == "audit_trend") | .status == "ok"' \
  'a never-appended trend history is not a fault'

# --- shepherd without Slack → nothing_to_do -----------------------------------
new_case shepherd_gated
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
run_preflight shepherd
assert_jq '.nothing_to_do == true' 'shepherd skipped without Slack'
assert_jq '.logs | any(contains("shepherd skipped"))' 'gate logged'

# --- refuted findings: the audit note, counted per source ----------------------
# The note in `### Summary` is the only record of a finding the review settled
# instead of posting (docs/review.md → **PR context**), so the week's noise
# signal is read off it (docs/audit.md → **Refuted findings**).
new_case audit_suppressed_counts
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
cat > "$WORK/reviews/pr-1.md" <<SUPEOF
# PR #1: open PR

## Review at aaaaaaa — $(iso_ago 86400) — COMMENT

### Summary
One pass over the diff. _(Suppressed 2 finding(s) per PR-local overrides: F1,F2. Suppressed 1 finding(s) per PR context: F3. Suppressed 3 finding(s) per in-tree decisions: F4,F5,F6 — docs/architecture/artifact-library.md.)_

## Review at bbbbbbb — $(iso_ago 1814400) — COMMENT

### Summary
Outside the window. _(Suppressed 9 finding(s) per in-tree decisions: F9 — docs/architecture/artifact-library.md.)_
SUPEOF
run_preflight audit
assert_jq '.stats.suppressed.overrides == 2 and .stats.suppressed.context == 1' 'the note is split per source'
assert_jq '.stats.suppressed.decisions == 3 and .stats.suppressed.total == 6' 'only in-window notes counted'
assert_jq '.stats.suppressed.reviews == 1' 'a review without the note is not a measured zero'
# the decisions part names its document; the counts read the same with it
assert_jq '.stats.suppressed.total == 6' 'the document name does not disturb the counts'

# --- review style: the sentence bar on the week's posted reviews ---------------
new_case audit_review_style
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
stel() { # <pr> <ts> <sentences> <over-20> <avg>
  jq -nc --argjson pr "$1" --arg ts "$2" --argjson n "$3" --argjson o "$4" --argjson a "$5" \
    '{src:"ledger", pr:$pr, ts:$ts, sha:"abc1234", kind:"first", verdict:"COMMENT",
      bullets:{fixed:0, still:0}, findings:[],
      ste:{sentences:$n, avg_sentence_words:$a, sentences_over_20:$o}}' >> "$WORK/REVIEW-LEDGER.jsonl"
}
stel 7 "$(iso_ago 86400)" 20 6 18.5
stel 8 "$(iso_ago 90000)" 20 0 12.0
run_preflight audit
assert_jq '.stats.ste.reviews == 2 and .stats.ste.sentences == 40' 'both reviews measured'
assert_jq '.stats.ste.sentences_over_20 == 6 and .stats.ste.over_20_share == 0.15' 'the share is over the whole week'
assert_jq '.stats.ste.avg_sentence_words == 15.3' 'the average is weighted by sentences'
assert_jq '[.checks[] | select(.id == "review_style")] | length == 1 and .[0].status == "ok"' 'at the bar the check passes'

# over the bar, the same week warns
new_case audit_review_style_warn
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
jq -nc --arg ts "$(iso_ago 86400)" \
  '{src:"ledger", pr:7, ts:$ts, sha:"abc1234", kind:"first", verdict:"COMMENT",
    bullets:{fixed:0, still:0}, findings:[],
    ste:{sentences:20, avg_sentence_words:28.0, sentences_over_20:9}}' > "$WORK/REVIEW-LEDGER.jsonl"
run_preflight audit
assert_jq '[.checks[] | select(.id == "review_style")] | .[0].status == "warn"' 'past the bar the check warns'
# the pod has no awk: the share is compared without it
mkdir -p "$SANDBOX/noawk"; printf '#!/bin/sh\nexit 127\n' > "$SANDBOX/noawk/awk"; chmod +x "$SANDBOX/noawk/awk"
PATH="$SANDBOX/noawk:$PATH" run_preflight audit
assert_jq '.stats.ste.over_20_share > 0.15 and ([.checks[] | select(.id == "review_style")] | .[0].status == "warn")' \
  'past the bar the check warns without awk'

# a week whose rows predate the measurement is unmeasured, never a pass
new_case audit_review_style_unmeasured
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
jq -nc --arg ts "$(iso_ago 86400)" \
  '{src:"ledger", pr:7, ts:$ts, sha:"abc1234", kind:"first", verdict:"COMMENT",
    bullets:{fixed:0, still:0}, findings:[]}' > "$WORK/REVIEW-LEDGER.jsonl"
run_preflight audit
assert_jq '.stats.ste.reviews == 0 and .stats.ste.avg_sentence_words == null' 'an old row carries no style measurement'
assert_jq '[.checks[] | select(.id == "review_style")] | .[0].detail | test("no posted review")' 'the check says unmeasured'

# --- artifacts published (stats.artifacts) ------------------------------------
# counted from the `artifact` outcome events of docs/artifact.md step 6, per PR,
# with preflight's own `generate due` lines as the guard against a generation
# that never logged one
new_case audit_artifacts
base_config '- artifact_skill: pr-artifact@acme/skills'
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
mkdir -p "$WORK/logs"
eva() { # <event> <level> <msg> <secs-ago>
  jq -nc --arg e "$1" --arg l "$2" --arg m "$3" --arg t "$(iso_ago "$4")" \
    '{ts:$t, run:"r1", job:"review", level:$l, event:$e, msg:$m}' \
    >> "$WORK/logs/events-$(date -u +%Y-%m-%d).jsonl"
}
eva artifact  info "PR #10: pr-artifact published → DAM aaa"          172800
eva artifact  info "PR #10: pr-artifact published → DAM aaa"          172700  # same PR twice
eva artifact  info "PR #11: pr-artifact published → DAM bbb"          86400
eva artifact  warn "PR #12: pr-artifact skipped (skill-errored)"      86400
eva preflight info "PR #12: artifact generate due"                    86500
eva artifact  info "PR #13: pr-artifact published → DAM ccc"          1814400 # outside the window
eva preflight info "PR #14: artifact generate due"                    43200   # never reported an outcome
eva preflight info "PR #15: artifact generate due"                    600     # still due, next heartbeat takes it
eva artifact  info "PR #16: artifact unassign retried (ok)"           86400   # neither a publish nor a skip
eva preflight info "PR #17: artifact generate due"                    86500
eva artifact  info "PR #17: pr-artifact published → DAM ddd, 2 redacted" 86400 # outcome word after the skill name
run_preflight audit
assert_jq '.stats.artifacts.generated == 3' 'published events counted once per PR, in-window only'
assert_jq '.stats.artifacts.skipped == 1' 'only the skipped outcome counts as a skip'
assert_jq '.stats.artifacts.unreported == 1' 'a due PR with no outcome event is the only unreported one'
assert_jq '[.checks[] | select(.id == "artifacts")] | .[0].status == "warn"' 'an unlogged generation warns'

new_case audit_artifacts_zero
base_config '- artifact_skill: pr-artifact@acme/skills'
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
run_preflight audit
assert_jq '.stats.artifacts == {generated: 0, skipped: 0, unreported: 0}' 'nothing due is a measured zero'
assert_jq '[.checks[] | select(.id == "artifacts")] | .[0].status == "ok"' 'a quiet week passes the check'

new_case audit_artifacts_off
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
run_preflight audit
assert_jq '.stats.artifacts == null' 'the feature off is unmeasured, never a zero'
assert_jq '[.checks[] | select(.id == "artifacts")] | length == 0' 'no check for a feature that is off'

# --- disk: every volume a run writes to (docs/audit.md task 4) -----------------
# work/ and the review clones share one filesystem here, so they report once;
# the backup's tmpfs is too small to re-clone work/ and warns on its own.
TMP_FOR_TEST="${TMPDIR:-/tmp}"
disk_fx() { # <path> <used%> <avail KiB> <mount> [inode%]
  printf 'Pk\t%s\t/dev/x 1000000 1 %s %s%% %s\n' "$1" "$3" "$2" "$4" >> "$CG_TEST_DF"
  [ -n "${5:-}" ] && printf 'Pi\t%s\t/dev/x 1000 1 1 %s%% %s\n' "$1" "$5" "$4" >> "$CG_TEST_DF"
  return 0
}
new_case audit_disk_volumes
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
export CG_TEST_DF="$SANDBOX/df.tsv" WORK_BACKUP_LOCAL="$SANDBOX/shm/cg-work-backup"
mkdir -p "$SANDBOX/shm"; : > "$CG_TEST_DF"
disk_fx "$WORK" 62 4000000 /workspace 3
disk_fx "$TMP_FOR_TEST" 62 4000000 /workspace 3
disk_fx "$SANDBOX/shm" 1 1 /dev/shm
run_preflight audit
assert_jq '.stats.disk.volumes | map(.role) == ["work","backup"]' 'one line per filesystem: the clones share the work volume'
assert_jq '.stats.disk.volumes[0] | .used_pct == 62 and .inode_pct == 3 and .avail_kb == 4000000' 'space, free and inode use recorded'
assert_jq '.stats.disk.work_kb > 0' 'the size of work/ is recorded'
assert_jq '.checks[] | select(.id == "disk") | .status == "warn" and (.detail | test("backup clone may not fit"))' 'a tmpfs under twice work/ warns'

new_case audit_disk_full
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
export CG_TEST_DF="$SANDBOX/df.tsv" WORK_BACKUP_LOCAL="$SANDBOX/shm/cg-work-backup"
mkdir -p "$SANDBOX/shm"; : > "$CG_TEST_DF"
disk_fx "$WORK" 96 40000 /workspace
disk_fx "$TMP_FOR_TEST" 70 4000000 /tmpvol 90
run_preflight audit
assert_jq '.checks[] | select(.id == "disk") | .status == "fail" and (.detail | test("work /workspace 96% used")) and (.detail | test("tmp /tmpvol 70% used, 3.8G free, inodes 90%"))' \
  'a volume past 95 % fails, inode use is judged too, and the unread backup volume is named'
assert_jq '.checks[] | select(.id == "disk") | .detail | test("backup unmeasured")' 'a volume df cannot read is unmeasured'

new_case audit_disk_unreported
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
export CG_TEST_DF="$SANDBOX/df.tsv"; : > "$CG_TEST_DF"
run_preflight audit
assert_jq '.checks[] | select(.id == "disk") | .status == "ok" and (.detail | test("not reported on this platform"))' 'no readable volume is unmeasured, never a fault'
assert_jq '.stats.disk.volumes == []' 'an unmeasured disk records no volume'

new_case audit_disk_backup_shared
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
export CG_TEST_DF="$SANDBOX/df.tsv" WORK_BACKUP_LOCAL="$SANDBOX/shm/cg-work-backup"
mkdir -p "$SANDBOX/shm"; : > "$CG_TEST_DF"
disk_fx "$WORK" 62 4000000 /workspace 3
disk_fx "$SANDBOX/shm" 62 1 /workspace 3
run_preflight audit
assert_jq '.stats.disk.volumes | map(.role) == ["work"]' 'a backup on the work volume adds no second volume'
assert_jq '.checks[] | select(.id == "disk") | .status == "warn" and (.detail | test("backup shares /workspace — under twice work/"))' \
  'the backup fit is judged on a shared volume too'
unset CG_TEST_DF WORK_BACKUP_LOCAL

# --- verdict shift against the recorded weeks (docs/audit.md task 24) ----------
# The baseline is read from work/audit/weeks/, never recounted; the week is the
# ledger. Labels from 2020 sort before any current ISO week.
base_weeks() { # <approve of 15, per week> [<first_approve of 10>]
  mkdir -p "$WORK/audit/weeks"
  for w in 01 02 03 04; do
    jq -n --arg w "2020-W$w" --argjson a "$1" --argjson fa "${2:-null}" \
      '{ts:"2020-01-01T00:00:00Z", week:$w, source:"audit", definition_version:"9.1.0",
        stats:{reviews:({total:15, first:10, re_review:5, approve:$a, comment:(15 - $a), request_changes:0, defs:["9.1.0"]}
                        + (if $fa == null then {} else {first_approve:$fa, first_request_changes:0} end))},
        checks:{ok:1, warn:0, fail:0}, extras:{}}' > "$WORK/audit/weeks/2020W$w.json"
  done
}
week_ledger() { # <approve> <comment> — first reviews, written by 9.9.0
  local i=0
  while [ "$i" -lt "$(( $1 + $2 ))" ]; do
    v=APPROVE; [ "$i" -ge "$1" ] && v=COMMENT
    jq -nc --argjson pr "$((100 + i))" --arg ts "$(iso_ago $((3600 + i * 60)))" --arg v "$v" \
      '{src:"ledger", pr:$pr, ts:$ts, sha:"abc1234", kind:"first", verdict:$v, def:"9.9.0",
        bullets:{fixed:0, still:0}, findings:[]}' >> "$WORK/REVIEW-LEDGER.jsonl"
    i=$((i + 1))
  done
}

new_case audit_verdict_shift
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
base_weeks 6 3
week_ledger 11 1
run_preflight audit
assert_jq '.stats.reviews | .first_approve == 11 and .first_request_changes == 0 and .defs == ["9.9.0"]' 'the week counts first-review verdicts and the definitions behind them'
assert_jq '.checks[] | select(.id == "verdict_shift") | .status == "warn"' 'APPROVE 92 % against 40 % warns'
assert_jq '.checks[] | select(.id == "verdict_shift") | .detail | test("all reviews: APPROVE 92% of 12 this week vs 40% of 60 in 2020-W01…2020-W04")' 'the detail names both shares and the baseline weeks'
assert_jq '.checks[] | select(.id == "verdict_shift") | .detail | test("first reviews: APPROVE 92% of 12 this week vs 30% of 40")' 'first reviews are compared on their own'
assert_jq '.checks[] | select(.id == "verdict_shift") | .detail | test("definition this week: 9.9.0, before: 9.1.0")' 'the detail names the definitions on both sides'

new_case audit_verdict_steady
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
base_weeks 6
week_ledger 5 7
run_preflight audit
assert_jq '.checks[] | select(.id == "verdict_shift") | .status == "ok" and (.detail | test("no significant shift"))' 'a share inside the noise passes'
assert_jq '.checks[] | select(.id == "verdict_shift") | .detail | test("first reviews") | not' 'weeks without first-review counts are no first-review baseline'

new_case audit_verdict_few
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
base_weeks 6
week_ledger 3 0
run_preflight audit
assert_jq '.checks[] | select(.id == "verdict_shift") | .status == "ok" and (.detail | test("too few reviews"))' 'a quiet week is not compared'

new_case audit_verdict_no_history
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
week_ledger 11 1
run_preflight audit
assert_jq '.checks[] | select(.id == "verdict_shift") | .status == "ok" and (.detail | test("no earlier week on record"))' 'without trend history the check waits for it'

# --- session records for the trend's run figures (docs/trends.md → Runs) -------
new_case audit_sessions
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
mkdir -p "$WORK/logs"
sev() { # <run> <job> <event> <msg> <ago>
  jq -nc --arg r "$1" --arg j "$2" --arg e "$3" --arg m "$4" --arg t "$(iso_ago "$5")" \
    '{ts:$t, run:$r, job:$j, level:"info", event:$e, msg:$m}' \
    >> "$WORK/logs/events-$(date -u +%Y-%m-%d).jsonl"
}
sev s1 review review_step "PR #4 abc1234 locked" 7200
sev s1 review review_step "PR #4 abc1234 posted APPROVE" 7000
sev s1 session tokens "input=10 output=2000 cache_read=500 cache_creation=30 msgs=20 model=claude-opus-5 subagents=0 secs=420" 6900
sev s2 shepherd preflight "sweep" 3600
sev s2 shepherd tokens "input=1 output=100 cache_read=5 cache_creation=7 msgs=2 model=claude-opus-5 subagents=0" 3420
sev s3 review review_step "PR #5 locked" 600
sev s4 review tokens "usage unavailable" 300
run_preflight audit
assert_jq '.stats.sessions | length == 2' 'only finished sessions (a tokens event) are recorded'
assert_file_contains "$WORK/logs/events-$(date -u +%Y-%m-%d).jsonl" '"event":"sessions_unparsed".*left out of stats.sessions: s4' \
  'a tokens event the audit cannot read names its run in a warn'
assert_jq '.stats.sessions[] | select(.job == "review") | .min == 7 and .reviews == 1 and .output == 2000 and .model == "claude-opus-5"' 'the transcript wall time wins; posted PRs and tokens are kept'
assert_jq '.stats.sessions[] | select(.job == "shepherd") | .min == 3' 'without secs the run spans its own events'

# --- session models against review_model (docs/audit.md task 5) ---------------
sm_runs() { # review on opus, shepherd on sonnet, a direct session on haiku
  mkdir -p "$WORK/logs"
  sev m1 review tokens "input=1 output=1 cache_read=1 cache_creation=1 msgs=1 model=claude-opus-5-5 subagents=0 secs=60" 3000
  sev m2 shepherd tokens "input=1 output=1 cache_read=1 cache_creation=1 msgs=1 model=claude-sonnet-5-5 subagents=0 secs=60" 2000
  sev m3 session tokens "input=1 output=1 cache_read=1 cache_creation=1 msgs=1 model=claude-haiku-4-5 subagents=0 secs=60" 1000
}
new_case audit_session_models_off
base_config '- review_model: opus'
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
sm_runs
run_preflight audit
assert_jq '.checks[] | select(.id == "session_models") | .status == "warn" and (.detail | test("^1 run\\(s\\) off review_model opus: shepherd claude-sonnet-5-5 ×1$"))' \
  'a scheduled run on another model warns; a direct session is left out'

new_case audit_session_models_match
base_config '- review_model: Opus'
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
mkdir -p "$WORK/logs"
sev m1 review tokens "input=1 output=1 cache_read=1 cache_creation=1 msgs=1 model=claude-opus-5-5 subagents=0" 3000
sev m2 audit tokens "input=1 output=1 cache_read=1 cache_creation=1 msgs=1 model=claude-opus-5-5 subagents=0" 2000
run_preflight audit
assert_jq '.checks[] | select(.id == "session_models") | .status == "ok" and .detail == "2 scheduled run(s), all on Opus"' \
  'runs whose model id contains the configured name match, case aside'

new_case audit_session_models_default
base_config '- review_model: Default'
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
sm_runs
run_preflight audit
assert_jq '.checks[] | select(.id == "session_models") | .status == "warn" and (.detail | test("^review_model is default")) and (.detail | test("review claude-opus-5-5 ×1, shepherd claude-sonnet-5-5 ×1"))' \
  'without a pinned model, in any letter case, the week names what each job ran on'

new_case audit_session_models_none
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
run_preflight audit
assert_jq '.checks[] | select(.id == "session_models") | .status == "ok"' 'a week without recorded runs has nothing to compare'

# --- findings density and missed-earlier share (docs/audit.md task 28) ---------
base_weeks_findings() { # <findings per week> <late per week> — 15 sized first reviews, 1500 lines
  mkdir -p "$WORK/audit/weeks"
  for w in 01 02 03 04; do
    jq -n --arg w "2020-W$w" --argjson f "$1" --argjson l "$2" \
      '{ts:"2020-01-01T00:00:00Z", week:$w, source:"audit", definition_version:"9.1.0",
        stats:{reviews:{total:15, first:15, re_review:0, approve:5, comment:10, request_changes:0, defs:["9.1.0"]},
               findings:{new:$f, late:$l, density:{reviews:15, findings:$f, lines:1500}}},
        checks:{ok:1, warn:0, fail:0}, extras:{}}' > "$WORK/audit/weeks/2020W$w.json"
  done
}
sized_ledger() { # <reviews> <new findings each> <late findings each> — 100 lines per PR
  local i=0
  while [ "$i" -lt "$1" ]; do
    jq -nc --argjson pr "$((200 + i))" --arg ts "$(iso_ago $((3600 + i * 60)))" \
      --argjson nf "$2" --argjson nl "$3" \
      '{src:"ledger", pr:$pr, ts:$ts, sha:"abc1234", kind:"first", verdict:"COMMENT", def:"9.9.0",
        size:{files:2, additions:90, deletions:10}, bullets:{fixed:0, still:0},
        findings:([range($nf) | {status:"new", severity:"warning"}] + [range($nl) | {status:"new", severity:"warning", late:true}])}' \
      >> "$WORK/REVIEW-LEDGER.jsonl"
    i=$((i + 1))
  done
}

new_case audit_findings_density_drop
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
base_weeks_findings 45 2
sized_ledger 10 0 0
jq -nc --arg ts "$(iso_ago 3000)" '{src:"ledger", pr:299, ts:$ts, sha:"abc1234", kind:"first", verdict:"APPROVE",
  size:{files:1, additions:5000, deletions:0}, bullets:{fixed:0, still:0}, findings:[{status:"new", severity:"warning"}]}' \
  >> "$WORK/REVIEW-LEDGER.jsonl"
run_preflight audit
assert_jq '.stats.findings.density == {reviews: 11, findings: 1, lines: 2000}' 'sized first reviews counted, one PR capped at 1000 lines'
assert_jq '.checks[] | select(.id == "findings_shift") | .status == "warn" and (.detail | test("0.05 findings per 100 changed lines this week \\(11 first reviews, 2000 lines\\) vs 3 in 2020-W01…2020-W04"))' \
  'findings per changed line far under the baseline warn'

new_case audit_findings_density_steady
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
base_weeks_findings 45 2
sized_ledger 10 3 0
run_preflight audit
assert_jq '.checks[] | select(.id == "findings_shift") | .status == "ok" and (.detail | test("no significant shift"))' 'the same density passes'
assert_jq '.checks[] | select(.id == "late_shift") | .status == "ok" and (.detail | test("missed earlier: 0 of 30 raised findings"))' 'no missed finding is no rise'

new_case audit_late_rise
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
base_weeks_findings 45 2
sized_ledger 10 2 1
run_preflight audit
assert_jq '.stats.findings.late == 10 and .stats.findings.new == 30' 'late findings counted among the raised ones'
assert_jq '.checks[] | select(.id == "late_shift") | .status == "warn" and (.detail | test("missed earlier: 10 of 30 raised findings \\(33%\\) this week vs 8 of 180 \\(4%\\)"))' \
  'a missed-earlier share far over the baseline warns'

# --- an APPROVE a person overruled (docs/audit.md task 24) ---------------------
new_case audit_approve_overruled
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
jq -nc --arg ts "$(iso_ago 86400)" '{src:"ledger", pr:7, ts:$ts, sha:"abc1234", kind:"first", verdict:"APPROVE", bullets:{fixed:0, still:0}, findings:[]}' >> "$WORK/REVIEW-LEDGER.jsonl"
jq -nc --arg ts "$(iso_ago 80000)" '{src:"ledger", pr:8, ts:$ts, sha:"def5678", kind:"first", verdict:"APPROVE", bullets:{fixed:0, still:0}, findings:[]}' >> "$WORK/REVIEW-LEDGER.jsonl"
jq -nc --arg ts "$(iso_ago 70000)" '{src:"ledger", pr:9, ts:$ts, sha:"9999999", kind:"first", verdict:"APPROVE", bullets:{fixed:0, still:0}, findings:[]}' >> "$WORK/REVIEW-LEDGER.jsonl"
jq -n --arg at "$(iso_ago 3600)" --arg early "$(iso_ago 90000)" '[
  {state:"CHANGES_REQUESTED", user:{login:"carol", type:"User"}, commit_id:"0000000aaaa", submitted_at:$at},
  {state:"CHANGES_REQUESTED", user:{login:"bob", type:"User"}, commit_id:"abc1234ffff", submitted_at:$early},
  {state:"CHANGES_REQUESTED", user:{login:"alice", type:"User"}, commit_id:"abc1234ffff", submitted_at:$at}]' \
  | fx 'api repos/acme/widgets/pulls/7/reviews?per_page=100'
jq -n --arg at "$(iso_ago 3600)" '[{state:"CHANGES_REQUESTED", user:{login:"lint[bot]", type:"Bot"}, commit_id:"def5678ffff", submitted_at:$at}]' \
  | fx 'api repos/acme/widgets/pulls/8/reviews?per_page=100'
jq -n --arg m "$(iso_ago 7200)" '[
  {number:20, title:"Revert \"Add cache\"", body:"Reverts acme/widgets#9", merged_at:$m},
  {number:21, title:"Revert \"Old thing\"", body:"Reverts acme/widgets#3", merged_at:$m},
  {number:22, title:"Fix", body:"Reverts nothing", merged_at:$m}]' \
  | fx 'api repos/acme/widgets/pulls?state=closed&sort=updated&direction=desc&per_page=100'
run_preflight audit
assert_jq '.stats.overruled.changes_requested == [{pr: 7, by: "alice", at: .stats.overruled.changes_requested[0].at}]' \
  'only a person, on the approved commit, after the APPROVE, overrules it'
assert_jq '.stats.overruled.reverted == [{pr: 9, by_pr: 20}]' 'a merged revert of an approved PR counts; one of a PR never approved does not'
assert_jq '.stats.overruled | .approved_prs == 3 and .scanned == 3' 'every approved PR of the week is read'
assert_jq '.checks[] | select(.id == "approve_overruled") | .status == "warn" and (.detail | test("#7 changes requested by alice on the approved commit; #9 reverted by #20"))' \
  'each overruled APPROVE is named'

new_case audit_approve_kept
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
jq -nc --arg ts "$(iso_ago 86400)" '{src:"ledger", pr:7, ts:$ts, sha:"abc1234", kind:"first", verdict:"APPROVE", bullets:{fixed:0, still:0}, findings:[]}' >> "$WORK/REVIEW-LEDGER.jsonl"
run_preflight audit
assert_jq '.checks[] | select(.id == "approve_overruled") | .status == "ok" and (.detail | test("1 approved PRs"))' 'an APPROVE nobody overruled passes'

new_case audit_approve_unread
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
jq -nc --arg ts "$(iso_ago 86400)" '{src:"ledger", pr:7, ts:$ts, sha:"abc1234", kind:"first", verdict:"APPROVE", bullets:{fixed:0, still:0}, findings:[]}' >> "$WORK/REVIEW-LEDGER.jsonl"
fx_fail 'api repos/acme/widgets/pulls/7/reviews?per_page=100'
fx_fail 'api repos/acme/widgets/pulls?state=closed&sort=updated&direction=desc&per_page=100'
run_preflight audit
assert_jq '.stats.overruled | .scanned == 0 and .unread == ["7"] and .reverts_read == false' 'what could not be read is recorded'
assert_jq '.checks[] | select(.id == "approve_overruled") | .status == "warn" and (.detail | test("reviews unreadable for #7")) and (.detail | test("reverts not checked"))' \
  'an unread scan warns instead of passing'

# --- the approved PRs are read in batches of 50, at most 200 -------------------
new_case audit_approve_batched
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
ts="$(iso_ago 86400)"
jq -nc --arg ts "$ts" 'range(1; 206) | {src:"ledger", pr:., ts:$ts, sha:"abc1234", kind:"first", verdict:"APPROVE", bullets:{fixed:0, still:0}, findings:[]}' \
  >> "$WORK/REVIEW-LEDGER.jsonl"
jq -n --arg at "$(iso_ago 3600)" '[{state:"CHANGES_REQUESTED", user:{login:"alice", type:"User"}, commit_id:"abc1234ffff", submitted_at:$at}]' \
  | fx 'api repos/acme/widgets/pulls/170/reviews?per_page=100'
fx_fail 'api repos/acme/widgets/pulls/42/reviews?per_page=100'
GH_CALLS_LOG="$SANDBOX/calls.log" run_preflight audit
assert_jq '.stats.overruled | .approved_prs == 205 and .scanned == 199 and .unread == ["42"]' \
  '200 PRs read, a PR the answer leaves null is unread'
assert_jq '.stats.overruled.changes_requested == [{pr: 170, by: "alice", at: .stats.overruled.changes_requested[0].at}]' \
  'a change request in a later batch is found'
assert_jq '.checks[] | select(.id == "approve_overruled") | .detail | test("5 approved PR\\(s\\) past the 200-PR cap not read")' \
  'the PRs past the cap are named'
if [ "$(grep -c '^api graphql -F query=@' "$SANDBOX/calls.log")" = 4 ] && ! grep -q 'pulls/[0-9]*/reviews' "$SANDBOX/calls.log"; then
  printf 'ok   %s: four GraphQL calls, the query in a file, no per-PR REST call\n' "$CASE"
else printf 'FAIL %s: calls: %s\n' "$CASE" "$(grep -c 'graphql' "$SANDBOX/calls.log")"; FAILED=1; fi

finish
