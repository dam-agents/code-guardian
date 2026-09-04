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

new_case audit_memory_within_bounds
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
printf '# Memory\n\n## Custom Rules\n- one rule\n' > "$WORK/MEMORY.md"
run_preflight audit
assert_jq '.checks[] | select(.id == "memory_budget") | .status == "ok" and (.detail | contains("biggest sections") | not)' \
  'a file within bounds is not scanned per section'

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
          "Stop":[{"hooks":[{"command":"/home/agent/scripts/harness/claude-code/enforce-review-completion.sh"}]}]}}
EOF
CLAUDECODE=1 run_preflight audit
assert_jq '.checks[] | select(.id == "harness_adapter") | .status == "ok"' 'all hooks registered → ok'

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

# --- shepherd without Slack → nothing_to_do -----------------------------------
new_case shepherd_gated
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
run_preflight shepherd
assert_jq '.nothing_to_do == true' 'shepherd skipped without Slack'
assert_jq '.logs | any(contains("shepherd skipped"))' 'gate logged'

finish
