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
assert_jq '.stats.findings == {fixed: 2, still_present: 1}' 'only in-window bullets counted'
assert_jq '.stats.reviews.total == 2 and .stats.reviews.re_review == 1' 'review counts sane'

# --- shepherd without Slack → nothing_to_do -----------------------------------
new_case shepherd_gated
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
run_preflight shepherd
assert_jq '.nothing_to_do == true' 'shepherd skipped without Slack'
assert_jq '.logs | any(contains("shepherd skipped"))' 'gate logged'

finish
