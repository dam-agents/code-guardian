#!/usr/bin/env bash
# definition-issue.sh (docs/runbook.md → **Definition-repo issues**): the key
# gates every GitHub call, the scan blocks any draft that names this instance
# before anything is sent, and a clean draft is deduplicated, then filed.
. "$(dirname "$0")/helpers.sh"

DEF="acme/guardian"
LIST="api --paginate --hostname github.com repos/$DEF/issues?state=open&per_page=100"
CREATE="api --hostname github.com -X POST repos/$DEF/issues --input -"

# an instance unlike the fixtures' acme/widgets, so every identifying value is
# its own and the placeholders stay placeholders
instance() { # [extra CONFIG lines…] — $TARGET and $URGENT override two values
  {
    printf -- '- github_repo: %s\n' "${TARGET:-globex/payroll-core}"
    printf -- '- work_repo: globex/cg-state\n'
    printf -- '- definition_repo: %s\n' "$DEF"
    printf -- '- bot_login: globex-review-bot\n'
    printf -- '- review_marker: globex:review\n'
    printf -- '- urgent_label: %s\n' "${URGENT:-hotfix-now}"
    printf -- '- human_review_paths: `billing/ledger/*, src/auth/*`\n'
    for l in "$@"; do printf -- '%s\n' "$l"; done
  } > "$WORK/CONFIG.md"
  {
    printf '| login | slack_id | name | expertise (seed) | observed areas |\n'
    printf '| --- | --- | --- | --- | --- |\n'
    printf '| hpatel | U07QX3KD9 | Hana Patel | payments | |\n'
  } > "$WORK/DEVELOPERS.md"
}

body() { printf '%s\n' "$@" > "$SANDBOX/body.md"; }

run_issue() { # <check|file> <title> — $DEF_ROOT runs another copy of the definition
  : > "$SANDBOX/calls.log"
  OUT="$(GH_HOST="" WORK_DIR="$WORK" HOME="$FAKE_HOME" GH_CALLS_LOG="$SANDBOX/calls.log" \
         PATH="$T_DIR/bin:$PATH" bash "${DEF_ROOT:-$REPO_ROOT}/scripts/definition-issue.sh" "$1" "$2" "$SANDBOX/body.md" 2>>"$STDERR_LOG")"
}

no_calls() { # <description>
  if [ -s "$SANDBOX/calls.log" ]; then
    printf 'FAIL %s: %s (gh called: %s)\n' "$CASE" "$1" "$(head -1 "$SANDBOX/calls.log")"; FAILED=1
  else printf 'ok   %s: %s\n' "$CASE" "$1"; fi
}

CLEAN=(
  'Symptom: `scripts/preflight.sh` audit mode counts a skipped tick as an error.'
  'Where: docs/audit.md → task 3; definition version 8.16.1.'
  'Seen 4 times in 7 days, reported by the weekly audit.'
  'Fix: test the `nothing_to_do` key before the counter, as in https://github.com/acme/guardian/blob/main/docs/worklist.md.'
)

# --- the key gates everything ---------------------------------------------------
new_case gate_missing_key
instance
body "${CLEAN[@]}"
run_issue file '[audit] Skipped tick counted as an error'
assert_jq '.outcome == "disabled"' 'a missing key files nothing'
no_calls 'a missing key makes no GitHub call'

new_case gate_disabled
instance '- definition_issues: disabled'
body 'Seen on globex/payroll-core PR #12.'
run_issue file '[audit] Skipped tick counted as an error'
assert_jq '.outcome == "disabled"' 'disabled answers before the scan'
no_calls 'disabled makes no GitHub call'

# --- a clean draft is filed once ------------------------------------------------
new_case clean_filed
instance '- definition_issues: enabled'
body "${CLEAN[@]}"
echo '[]' | fx "$LIST"
jq -n --arg u "https://github.com/$DEF/issues/301" '{number:301, html_url:$u}' | fx "$CREATE"
run_issue check '[audit] Skipped tick counted as an error'
assert_jq '.outcome == "clean"' 'check passes a generic draft, definition-repo link included'
no_calls 'check makes no GitHub call'
run_issue file '[audit] Skipped tick counted as an error'
assert_jq '.outcome == "filed" and (.url | endswith("/issues/301"))' 'a clean draft is filed and its URL returned'
assert_file_contains "$SANDBOX/calls.log" 'POST repos/acme/guardian/issues' 'the issue is created on the definition repo'
assert_file_contains "$SANDBOX/calls.log.input" 'Skipped tick counted as an error' 'the payload carries the title'

new_case duplicate_exists
instance '- definition_issues: enabled'
body "${CLEAN[@]}"
jq -n --arg u "https://github.com/$DEF/issues/77" \
  '[{title:"[audit] Skipped tick counted as an error", html_url:$u}]' | fx "$LIST"
run_issue file '[audit] Skipped tick counted as an error'
assert_jq '.outcome == "exists" and (.url | endswith("/issues/77"))' 'an open issue with the same title is reused'
if grep -q 'POST' "$SANDBOX/calls.log"; then printf 'FAIL %s: a duplicate was created\n' "$CASE"; FAILED=1
else printf 'ok   %s: no second issue\n' "$CASE"; fi

# --- every identifying value blocks, before any call ------------------------------
blocks() { # <rule> <line> [title]
  new_case "blocks_$1"
  instance '- definition_issues: enabled'
  body "${CLEAN[@]}" "$2"
  run_issue file "${3:-[audit] Skipped tick counted as an error}"
  assert_jq '.outcome == "blocked" and any(.hits[]; .rule == "'"$1"'")' "$1 blocks: $2"
  no_calls "$1: nothing reaches GitHub"
}
blocks target_repo   'Seen on globex/payroll-core.'
blocks target_repo   'The payroll-core service failed.'
blocks target_repo   'Owner GLOBEX runs it.'
blocks work_repo     'Backup to cg-state failed.'
blocks bot_login     'Posted as globex-review-bot.'
blocks review_marker 'Marker globex:review missing.'
blocks label         'The hotfix-now label was ignored.'
blocks human_review_paths 'A change under billing/ledger/ was missed.'
blocks roster        'Hana Patel asked for it.'
blocks roster        'Member U07QX3KD9 got no nudge.'
blocks url           'See https://internal.globex.example/wiki/runbook.'
blocks number        'Seen on PR #12.'
blocks number        'Seen on pull/12 and pr-12.'
blocks sha           'Head 3f9a2c4b7d1e8f60 was stale.'
blocks email         'Reported by ops@globex.example.'
blocks mention       'cc @hpatel'
blocks slack_id      'Channel C04ABCD1234 got the alert.'
blocks ipv4          'Runner at 10.20.30.40 timed out.'
blocks credential    'token=ghp_abcdefghijklmnopqrstuvwxyz0123'
blocks target_repo   'body is generic' '[audit] payroll-core reviews stall'
blocks number        'Seen on pull request 12.'
blocks sha           'Head 3f9a2c4 was stale.'
blocks date          'Seen on 2026-10-03.'
blocks date          'Seen at 09:14:55.'
# foreign terms: a path, a host, a product, an identifier, a fenced block —
# none of them a word of the definition
blocks foreign_term  'The file src/billing/ledger.ts was skipped.'
blocks foreign_term  'Runner ci.initech.internal timed out.'
blocks foreign_term  'Stripe rejected the payment.'
blocks foreign_term  'The `invoice_total` field was wrong.'
blocks foreign_term  'A branch named feature/sso-login was reviewed.'
new_case blocks_fenced_block
instance '- definition_issues: enabled'
body "${CLEAN[@]}" '```' 'kubectl rollout status deploy/ledger' '```'
run_issue file '[audit] Skipped tick counted as an error'
assert_jq '.outcome == "blocked" and any(.hits[]; .rule == "foreign_term" and .match == "kubectl")' 'a fenced block of foreign tokens blocks'
no_calls 'fenced block: nothing reaches GitHub'

# the configured repositories and watch rules beyond the target
new_case blocks_config_tables
instance '- definition_issues: enabled' '- artifact_skill: pr-artifact@initech/review-tools' '' \
  '## Review skills' '| skill | source | trigger | section |' '| --- | --- | --- | --- |' \
  '| license-check | initech/skills | always | License Check |' '' \
  '## Watch rules' '| id | watch for | notify | note |' '| --- | --- | --- | --- |' \
  '| ledger-schema | adds a migration | slack:C0123ABCD | asked by hpatel |'
body "${CLEAN[@]}" 'The ledger-schema watch fired; see initech/skills and initech/review-tools.'
run_issue file '[audit] Skipped tick counted as an error'
assert_jq '.outcome == "blocked" and any(.hits[]; .rule == "watch_rule") and any(.hits[]; .rule == "skill_source") and any(.hits[]; .rule == "artifact_skill")' 'watch-rule ids and the skill and artifact repositories block'
no_calls 'config tables: nothing reaches GitHub'

new_case title_prefix
instance '- definition_issues: enabled'
body "${CLEAN[@]}"
run_issue file 'Skipped tick counted as an error'
assert_jq '.outcome == "error"' 'a title without the kind prefix is refused'
no_calls 'a refused title makes no call'

new_case definition_terms_pass
instance '- definition_issues: enabled'
body "${CLEAN[@]}" 'Reproduction: set `review_model` to `default`, then run `bash "$HOME/scripts/preflight.sh" audit`.' \
  '```' 'bash scripts/harness/claude-code/install.sh --check' '```' 'VERSION 8.17.0; see docs/runbook.md → Audit run.'
run_issue check '[audit] Audit run reports the model as a mismatch'
assert_jq '.outcome == "clean"' 'definition paths, keys, commands and words pass the foreign-term scan'

new_case placeholders_pass
instance '- definition_issues: enabled'
body "${CLEAN[@]}" 'Reproduction: target acme/widgets, member alice with Slack id U0123ABCD.'
run_issue check '[channel request] Per-team quiet hours'
assert_jq '.outcome == "clean"' 'the documentation placeholders pass'

# a target whose name extends the definition's keeps its whole reference
new_case target_extends_definition
TARGET=acme/guardian-web instance '- definition_issues: enabled'
body "${CLEAN[@]}" 'Seen on acme/guardian-web only.'
run_issue check '[audit] Skipped tick counted as an error'
assert_jq '.outcome == "blocked" and any(.hits[]; .rule == "target_repo" and .match == "acme/guardian-web")' 'acme/guardian-web is not the definition acme/guardian'

# a one-word instance value that is a word of the definition does not block it
new_case definition_word_as_value
TARGET=globex/docs URGENT=urgent instance '- definition_issues: enabled'
body "${CLEAN[@]}" 'Proposed fix: name the label by its key, `urgent_label`.'
run_issue check '[audit] Skipped tick counted as an error'
assert_jq '.outcome == "clean"' 'docs/audit.md and `urgent_label` pass under target globex/docs and label urgent'
body "${CLEAN[@]}" 'Seen on globex/docs.'
run_issue check '[audit] Skipped tick counted as an error'
assert_jq '.outcome == "blocked" and any(.hits[]; .rule == "target_repo" and .match == "globex/docs")' 'the slug globex/docs still blocks'

# the vocabulary is the tracked definition: an untracked file adds no word
new_case vocabulary_tracked_only
instance '- definition_issues: enabled'
COPY="$SANDBOX/definition"
mkdir -p "$COPY"
cp -R "$REPO_ROOT/docs" "$REPO_ROOT/scripts" "$REPO_ROOT/.agents" "$REPO_ROOT"/*.md "$REPO_ROOT"/*.yaml "$REPO_ROOT/VERSION" "$COPY/"
git -C "$COPY" init -q && git -C "$COPY" add -A
mkdir -p "$COPY/.agents/skills/zz"
printf 'The Initech importer reads src/billing/ledger.ts.\n' > "$COPY/.agents/skills/zz/SKILL.md"
printf 'Initech: src/billing/ledger.ts\n' > "$COPY/NOTES.md"
body "${CLEAN[@]}" 'The Initech importer in `src/billing/ledger.ts` fails.'
DEF_ROOT="$COPY" run_issue check '[audit] Skipped tick counted as an error'
assert_jq '.outcome == "blocked" and any(.hits[]; .rule == "foreign_term" and .match == "initech")' 'a word of an untracked file is foreign'

# --- the resolved key travels in the worklist's config object -------------------
SHA="1111111111111111111111111111111111111111"
new_case config_default_disabled
base_config
pr_json 1 "a new PR" '[]' "$SHA" | open_prs_fx
run_preflight review
assert_jq '.config.definition_issues == "disabled"' 'a missing key resolves to disabled'

new_case config_enabled
base_config '- definition_issues: enabled'
pr_json 1 "a new PR" '[]' "$SHA" | open_prs_fx
run_preflight review
assert_jq '.config.definition_issues == "enabled"' 'the opt-in travels in the config object'

finish
