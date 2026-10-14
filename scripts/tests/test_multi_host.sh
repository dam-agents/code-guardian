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
printf '{"sha":"feedfacefeedfacefeedfacefeedfacefeedface"}\n' | fx 'api --hostname github.com repos/acme/skills/commits/HEAD'
printf '{"tree":[{"type":"blob","path":".agents/skills/pub/SKILL.md"}]}\n' | fx 'api --hostname github.com repos/acme/skills/git/trees/feedfacefeedfacefeedfacefeedfacefeedface?recursive=1'
printf '{"sha":"beefbeefbeefbeefbeefbeefbeefbeefbeefbeef"}\n' | fx 'api --hostname github.example.com repos/acme/skills/commits/HEAD'
printf '{"tree":[{"type":"blob","path":".agents/skills/ent/SKILL.md"},{"type":"blob","path":".agents/skills/ent/ref.md"}]}\n' \
  | fx 'api --hostname github.example.com repos/acme/skills/git/trees/beefbeefbeefbeefbeefbeefbeefbeefbeefbeef?recursive=1'
run_preflight review
assert_jq '.skills.pub == "installed (1 files)"' 'default-host skill installs from github.com'
assert_jq '.skills.ent == "installed (2 files)"' 'host-prefixed skill installs from its own host'

# --- one install is one snapshot: the default branch's HEAD SHA is the ref of
# the tree listing and of every file fetch (docs/skills.md → Installation) -----
SRC_SHA="cafecafecafecafecafecafecafecafecafecafe"
snap_case() { # <case>
  new_case "$1"
  {
    printf -- '- github_repo: %s\n' "$TEST_REPO"
    printf -- '- bot_login: test-bot\n- review_marker: cg:review\n\n'
    printf '## Review skills\n\n| skill | source | trigger | section |\n| --- | --- | --- | --- |\n'
    printf '| snap | acme/skills | always | Snap |\n'
  } > "$WORK/CONFIG.md"
  pr_json 1 "plain PR" '[]' "$SHA1" | open_prs_fx
}
snap_case skill_source_snapshot
printf '{"sha":"%s"}\n' "$SRC_SHA" | fx 'api --hostname github.com repos/acme/skills/commits/HEAD'
printf '{"tree":[{"type":"blob","path":".agents/skills/snap/SKILL.md"}]}\n' \
  | fx "api --hostname github.com repos/acme/skills/git/trees/$SRC_SHA?recursive=1"
printf '# snap at the snapshot\n' \
  | fx "api --hostname github.com repos/acme/skills/contents/.agents/skills/snap/SKILL.md?ref=$SRC_SHA -H Accept: application/vnd.github.raw"
GH_CALLS_LOG="$SANDBOX/calls.log" run_preflight review
assert_jq '.skills.snap == "installed (1 files)"' 'the skill installs from the HEAD snapshot'
assert_file_contains "$FAKE_HOME/.claude/skills/snap/SKILL.md" '^# snap at the snapshot$' 'every file is fetched at the snapshot SHA'
assert_file_contains "$FAKE_HOME/.claude/skills/.cache/snap.sha" "^$SRC_SHA\$" 'the cache holds the snapshot SHA'
assert_file_contains "$SANDBOX/calls.log" "repos/acme/skills/git/trees/$SRC_SHA?recursive=1" 'the tree is listed at the snapshot SHA'
grep -E 'repos/acme/skills/.*(/main|=main|trees/HEAD|ref=HEAD)' "$SANDBOX/calls.log" >/dev/null \
  && { printf 'FAIL %s: a source call named main or HEAD past commits/HEAD\n' "$CASE"; FAILED=1; } \
  || printf 'ok   %s: no main ref anywhere\n' "$CASE"
run_preflight audit
assert_jq '.checks[] | select(.id == "skill_snap") | .status == "ok" and .detail == "installed and current"' 'the audit compares the cache with commits/HEAD'

snap_case skill_source_no_sha
fx_fail 'api --hostname github.com repos/acme/skills/commits/HEAD'
printf '{"tree":[{"type":"blob","path":".agents/skills/snap/SKILL.md"}]}\n' \
  | fx 'api --hostname github.com repos/acme/skills/git/trees/HEAD?recursive=1'
run_preflight review
assert_jq '.skills.snap == "installed (1 files)"' 'an unreadable SHA installs from HEAD'
[ -e "$FAKE_HOME/.claude/skills/.cache/snap.sha" ] \
  && { printf 'FAIL %s: a cache SHA was written without a snapshot SHA\n' "$CASE"; FAILED=1; } \
  || printf 'ok   %s: no cache SHA without a snapshot SHA\n' "$CASE"

# --- the artifact publishes to DAM on any target host -----------------------
new_case artifact_due_other_host
TEST_REF="github.example.com/acme/widgets"
base_config '- artifact_skill: pr-artifact@acme/skills'
pr_json 1 "assigned PR" '[]' "$SHA1" | jq '.assignees = [{"login":"test-bot"}]' | open_prs_fx
printf '{"sha":"feedfacefeedfacefeedfacefeedfacefeedface"}\n' | fx 'api --hostname github.com repos/acme/skills/commits/HEAD'
printf '{"tree":[{"type":"blob","path":".agents/skills/pr-artifact/SKILL.md"}]}\n' | fx 'api --hostname github.com repos/acme/skills/git/trees/feedfacefeedfacefeedfacefeedfacefeedface?recursive=1'
run_preflight review
assert_jq '.artifacts_due | length == 1' 'the artifact is due off github.com'
assert_jq '.config | has("artifact_targets") | not' 'the worklist carries no artifact surface key'

finish
