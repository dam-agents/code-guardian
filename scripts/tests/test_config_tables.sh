#!/usr/bin/env bash
# CONFIG table parsing (v2.1.0 regression): the `## Review skills` table must
# stop at the next `## ` heading — Watch-rules rows must never be installed as
# skills.
. "$(dirname "$0")/helpers.sh"

SHA1="1111111111111111111111111111111111111111"

new_case skills_table_bounded
{
  printf -- '- github_repo: %s\n' "$TEST_REPO"
  printf -- '- bot_login: test-bot\n- review_marker: cg:review\n- rereview_label: cg-rereview\n\n'
  printf '## Review skills\n\n'
  printf '| skill | source | trigger | section |\n'
  printf '| --- | --- | --- | --- |\n'
  printf '| foo | acme/skills | always | Foo Review |\n\n'
  printf '## Watch rules\n\n'
  printf '| id | watch for | notify | note |\n'
  printf '| --- | --- | --- | --- |\n'
  printf '| db-migration | touches a migration | chat | test row |\n'
} > "$WORK/CONFIG.md"
pr_json 1 "plain PR" '[]' "$SHA1" | open_prs_fx
printf '{"sha":"feedfacefeedfacefeedfacefeedfacefeedface"}\n' | fx 'api --hostname github.com repos/acme/skills/commits/main'
printf '{"tree":[{"type":"blob","path":".agents/skills/foo/SKILL.md"}]}\n' | fx 'api --hostname github.com repos/acme/skills/git/trees/main?recursive=1'
run_preflight review
assert_jq '.reviews_due | length == 1' 'review due triggers the install'
assert_jq '.skills | keys == ["foo"]' 'only the skills table installs'
assert_jq '.skills.foo == "installed (1 files)"' 'skill installed from fixture tree'

# --- skills install side by side; the result keeps the table order ------------
new_case skills_parallel_order
{
  printf -- '- github_repo: %s\n' "$TEST_REPO"
  printf -- '- bot_login: test-bot\n- review_marker: cg:review\n- rereview_label: cg-rereview\n\n'
  printf '## Review skills\n\n'
  printf '| skill | source | trigger | section |\n'
  printf '| --- | --- | --- | --- |\n'
  printf '| zeta | acme/skills | always | Zeta |\n'
  printf '| alpha | acme/other | always | Alpha |\n'
  printf '| zeta | acme/other | always | Zeta again |\n\n'
} > "$WORK/CONFIG.md"
pr_json 1 "plain PR" '[]' "$SHA1" | open_prs_fx
for r in skills other; do
  printf '{"sha":"feedfacefeedfacefeedfacefeedfacefeedface"}\n' | fx "api --hostname github.com repos/acme/$r/commits/main"
done
printf '{"tree":[{"type":"blob","path":".agents/skills/zeta/SKILL.md"}]}\n' | fx 'api --hostname github.com repos/acme/skills/git/trees/main?recursive=1'
printf '{"tree":[{"type":"blob","path":".agents/skills/alpha/SKILL.md"},{"type":"blob","path":".agents/skills/alpha/a.md"},{"type":"blob","path":".agents/skills/zeta/SKILL.md"},{"type":"blob","path":".agents/skills/zeta/z.md"}]}\n' \
  | fx 'api --hostname github.com repos/acme/other/git/trees/main?recursive=1'
run_preflight review
assert_jq '.skills | keys_unsorted == ["zeta", "alpha"]' 'first position of each skill kept'
assert_jq '.skills.zeta == "installed (2 files)" and .skills.alpha == "installed (2 files)"' 'a repeated skill installs from its last source'
[ -f "$FAKE_HOME/.claude/skills/zeta/z.md" ] \
  && printf 'ok   %s: %s\n' "$CASE" 'installed files come from the last source' \
  || { printf 'FAIL %s: zeta/z.md missing\n' "$CASE"; FAILED=1; }

finish
