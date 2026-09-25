#!/usr/bin/env bash
# preflight's artifact assignee gate — generate, retry_unassign, and the 24 h
# backoff after a dam-unavailable skip (docs/artifact.md).
. "$(dirname "$0")/helpers.sh"

SHA1="1111111111111111111111111111111111111111"

artifact_case() { # <case> [history-file line…]
  new_case "$1"; shift
  base_config '- artifact_skill: pr-artifact@acme/skills'
  pr_json 1 "assigned PR" '[]' "$SHA1" | jq '.assignees = [{"login":"test-bot"}]' | open_prs_fx
  printf '{"sha":"feedfacefeedfacefeedfacefeedfacefeedface"}\n' | fx 'api --hostname github.com repos/acme/skills/commits/main'
  printf '{"tree":[{"type":"blob","path":".agents/skills/pr-artifact/SKILL.md"}]}\n' | fx 'api --hostname github.com repos/acme/skills/git/trees/main?recursive=1'
  mkdir -p "$WORK/reviews"
  { printf '# PR #1: assigned PR\n'; for l in "$@"; do printf '%s\n' "$l"; done; } > "$WORK/reviews/pr-1.md"
  run_preflight review
}

artifact_case artifact_generate
assert_jq '.artifacts_due == [{number: 1, action: "generate"}]' 'an assigned PR without a marker is due for generate'

artifact_case artifact_retry_unassign '<!-- artifact-dam: dam_1 -->'
assert_jq '.artifacts_due == [{number: 1, action: "retry_unassign"}]' 'a DAM marker turns generate into retry_unassign'

artifact_case artifact_skip_recent "<!-- artifact-skip: dam-unavailable $(iso_ago 3600) -->"
assert_jq '.artifacts_due | length == 0' 'a dam-unavailable skip within 24 h defers generate'

artifact_case artifact_skip_expired "<!-- artifact-skip: dam-unavailable $(iso_ago 90000) -->"
assert_jq '.artifacts_due == [{number: 1, action: "generate"}]' 'a skip older than 24 h makes generate due again'

artifact_case artifact_skip_with_marker "<!-- artifact-skip: dam-unavailable $(iso_ago 3600) -->" '<!-- artifact-dam: dam_1 -->'
assert_jq '.artifacts_due == [{number: 1, action: "retry_unassign"}]' 'a DAM marker wins over a stale skip line'

finish
