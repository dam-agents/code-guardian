#!/usr/bin/env bash
# Multi-host repo references: `[<host>/]<owner>/<repo>` for the target repo and
# every skill source; the artifact feature is independent of the target host.
. "$(dirname "$0")/helpers.sh"

SHA1="1111111111111111111111111111111111111111"

# --- host-prefixed target ref: API paths keep the bare slug -------------------
new_case host_prefixed_target
TEST_REF="github.example.com/acme/widgets"
base_config
pr_json 1 "plain PR" '[]' "$SHA1" | open_prs_fx
run_preflight review
assert_jq '.reviews_due | length == 1' 'a host-prefixed target resolves to the bare slug for API paths'

# --- skill sources resolve per host ------------------------------------------
new_case skill_source_hosts
{
  printf -- '- github_repo: %s\n' "$TEST_REPO"
  printf -- '- bot_login: test-bot\n- review_marker: cg:review\n\n'
  printf '## Review skills\n\n'
  printf '| skill | source | trigger | section |\n'
  printf '| --- | --- | --- | --- |\n'
  printf '| pub | acme/skills | always | Public |\n'
  printf '| ent | github.example.com/acme/skills | always | Enterprise |\n'
} > "$WORK/CONFIG.md"
pr_json 1 "plain PR" '[]' "$SHA1" | open_prs_fx
printf '{"sha":"feedfacefeedfacefeedfacefeedfacefeedface"}\n' | fx 'api --hostname github.com repos/acme/skills/commits/main'
printf '{"tree":[{"type":"blob","path":".agents/skills/pub/SKILL.md"}]}\n' | fx 'api --hostname github.com repos/acme/skills/git/trees/main?recursive=1'
printf '{"sha":"beefbeefbeefbeefbeefbeefbeefbeefbeefbeef"}\n' | fx 'api --hostname github.example.com repos/acme/skills/commits/main'
printf '{"tree":[{"type":"blob","path":".agents/skills/ent/SKILL.md"},{"type":"blob","path":".agents/skills/ent/ref.md"}]}\n' \
  | fx 'api --hostname github.example.com repos/acme/skills/git/trees/main?recursive=1'
run_preflight review
assert_jq '.skills.pub == "installed (1 files)"' 'default-host skill installs from github.com'
assert_jq '.skills.ent == "installed (2 files)"' 'host-prefixed skill installs from its own host'

# --- the artifact publishes to DAM on any target host -----------------------
new_case artifact_due_other_host
TEST_REF="github.example.com/acme/widgets"
base_config '- artifact_skill: pr-artifact@acme/skills'
pr_json 1 "assigned PR" '[]' "$SHA1" | jq '.assignees = [{"login":"test-bot"}]' | open_prs_fx
printf '{"sha":"feedfacefeedfacefeedfacefeedfacefeedface"}\n' | fx 'api --hostname github.com repos/acme/skills/commits/main'
printf '{"tree":[{"type":"blob","path":".agents/skills/pr-artifact/SKILL.md"}]}\n' | fx 'api --hostname github.com repos/acme/skills/git/trees/main?recursive=1'
run_preflight review
assert_jq '.artifacts_due | length == 1' 'the artifact is due off github.com'
assert_jq '.config | has("artifact_targets") | not' 'the worklist carries no artifact surface key'

finish
