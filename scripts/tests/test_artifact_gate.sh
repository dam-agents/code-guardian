#!/usr/bin/env bash
# preflight's artifact gate — the assignee or the artifact label, generate,
# retry_release, and the 24 h backoff after a dam-unavailable skip
# (docs/artifact.md).
. "$(dirname "$0")/helpers.sh"

SHA1="1111111111111111111111111111111111111111"

# ASSIGNEES (default test-bot) and LABELS (default none) set the triggers
artifact_case() { # <case> [history-file line…]
  new_case "$1"; shift
  base_config '- artifact_skill: pr-artifact@acme/skills' '- artifact_label: cg-artifact'
  local who='[{"login":"test-bot"}]'
  pr_json 1 "assigned PR" "${LABELS:-[]}" "$SHA1" | jq --argjson a "${ASSIGNEES:-$who}" '.assignees = $a' | open_prs_fx
  printf '{"sha":"feedfacefeedfacefeedfacefeedfacefeedface"}\n' | fx 'api --hostname github.com repos/acme/skills/commits/HEAD'
  printf '{"tree":[{"type":"blob","path":".agents/skills/pr-artifact/SKILL.md"}]}\n' | fx 'api --hostname github.com repos/acme/skills/git/trees/feedfacefeedfacefeedfacefeedfacefeedface?recursive=1'
  mkdir -p "$WORK/reviews"
  { printf '# PR #1: assigned PR\n'; for l in "$@"; do printf '%s\n' "$l"; done; } > "$WORK/reviews/pr-1.md"
  run_preflight review
}

artifact_case artifact_generate
assert_jq '.artifacts_due == [{number: 1, action: "generate", triggers: ["assignee"]}]' 'an assigned PR without a marker is due for generate'

artifact_case artifact_retry_release '<!-- artifact-dam: dam_1 -->'
assert_jq '.artifacts_due == [{number: 1, action: "retry_release", triggers: ["assignee"]}]' 'a DAM marker turns generate into retry_release'

artifact_case artifact_skip_recent "<!-- artifact-skip: dam-unavailable $(iso_ago 3600) -->"
assert_jq '.artifacts_due | length == 0' 'a dam-unavailable skip within 24 h defers generate'

artifact_case artifact_skip_expired "<!-- artifact-skip: dam-unavailable $(iso_ago 90000) -->"
assert_jq '.artifacts_due == [{number: 1, action: "generate", triggers: ["assignee"]}]' 'a skip older than 24 h makes generate due again'

artifact_case artifact_skip_with_marker "<!-- artifact-skip: dam-unavailable $(iso_ago 3600) -->" '<!-- artifact-dam: dam_1 -->'
assert_jq '.artifacts_due == [{number: 1, action: "retry_release", triggers: ["assignee"]}]' 'a DAM marker wins over a stale skip line'

# --- the artifact label: the trigger a GitHub App bot_login can have -----------
ASSIGNEES='[]' LABELS='[{"name":"cg-artifact"}]' artifact_case artifact_label
assert_jq '.artifacts_due == [{number: 1, action: "generate", triggers: ["label"]}]' 'the artifact label alone is a trigger'

LABELS='[{"name":"cg-artifact"}]' artifact_case artifact_label_and_assignee '<!-- artifact-dam: dam_1 -->'
assert_jq '.artifacts_due == [{number: 1, action: "retry_release", triggers: ["assignee", "label"]}]' 'both triggers are released'

ASSIGNEES='[]' artifact_case artifact_no_trigger
assert_jq '.artifacts_due | length == 0' 'no assignee and no label, no artifact'

finish
