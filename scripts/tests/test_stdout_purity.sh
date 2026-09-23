#!/usr/bin/env bash
# The worklist IS preflight's stdout: every command in a JSON-emitting path
# writes to a file, a variable or /dev/null. A stray line turns the worklist
# into two documents, which the gate reads as `jq -e` on the last one and a
# two-line `.nothing_to_do` — an idle fire would start a session
# (docs/runbook.md → The schedule gate).
#
# `[., inputs]` collects every document jq was given, so `length == 1` is the
# assertion "exactly one JSON document on stdout". The stub `gh` answers an
# unfixtured call with `{}` on stdout, so a lost redirect fails here.
. "$(dirname "$0")/helpers.sh"

SHA1="1111111111111111111111111111111111111111"

# --- idle heartbeat ----------------------------------------------------------
new_case stdout_one_document_idle
base_config
printf '' | open_prs_fx   # no open PR at all
run_preflight review
assert_jq '[., inputs] | length == 1' 'idle stdout is exactly one JSON document'
assert_jq '.nothing_to_do == true' 'and it is the nothing-to-do worklist'

# --- review due: the skill-install path runs `gh auth setup-git` -------------
new_case stdout_one_document_work_due
base_config
pr_json 1 "plain PR" '[]' "$SHA1" | open_prs_fx
run_preflight review
assert_jq '[., inputs] | length == 1' 'work-due stdout is exactly one JSON document'
assert_jq '.reviews_due | length == 1' 'and it is the worklist with the due review'

finish
