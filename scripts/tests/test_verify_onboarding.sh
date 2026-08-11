#!/usr/bin/env bash
# verify-onboarding.sh: post-onboarding structure verification — green path
# passes, every structural break (missing section, malformed row, missing
# roster, inner .git, version drift, bad enum) FAILs with a fix instruction.
. "$(dirname "$0")/helpers.sh"

SHA1="1111111111111111111111111111111111111111"
TEST_ENV_REPO=""   # what the case exports as $GITHUB_REPO (never the dev's shell)

# fake definition checkout at $FAKE_HOME + matching work/ seeds
seed_home() {
  ( cd "$FAKE_HOME" \
    && git init -q \
    && git config user.email test@example.invalid && git config user.name test \
    && printf '/*\n!/.gitignore\n!/VERSION\n' > .gitignore \
    && printf '9.9.9\n' > VERSION \
    && git add .gitignore VERSION && git commit -qm seed \
    && git checkout -qB main \
    && git remote add origin https://github.com/acme/code-guardian.git )
  date -u +%Y-%m-%dT%H:%M:%SZ > "$FAKE_HOME/.code-guardian-onboarded"
  printf '9.9.9\n' > "$WORK/VERSION"
  printf '# Agent entry point\n' > "$WORK/AGENTS.md"   # ONBOARDING Step 3c
}

seed_memory() {
  {
    printf '# Review Preferences\n\n'
    for s in 'Review Style' 'Focus Areas' 'Ignore List' 'Custom Rules' 'Observed Insights' 'Feedback Log'; do
      printf '## %s\n\n' "$s"
    done
  } > "$WORK/MEMORY.md"
}

seed_lessons() { printf '# Operational Lessons\n' > "$WORK/LESSONS.md"; }

verify_config() { # [extra CONFIG lines…]
  base_config '- definition_repo: acme/code-guardian' "- github_repo: $TEST_REPO" "$@"
}

run_verify() { # [extra env assignments are passed through the environment]
  OUT="$(WORK_DIR="$WORK" HOME="$FAKE_HOME" CLAUDECODE=0 GITHUB_REPO="$TEST_ENV_REPO" \
         bash "$REPO_ROOT/scripts/verify-onboarding.sh" 2>&1)"
  RC=$?
}

# --live in the sandbox: the fake gh serves fixtures, preflight runs against them
run_verify_live() {
  OUT="$(WORK_DIR="$WORK" HOME="$FAKE_HOME" CLAUDECODE=0 GH_HOST="" GITHUB_REPO="$TEST_ENV_REPO" \
         PATH="$T_DIR/bin:$PATH" \
         bash "$REPO_ROOT/scripts/verify-onboarding.sh" --live 2>&1)"
  RC=$?
}

assert_out() { # <grep -E pattern> <description>
  if printf '%s' "$OUT" | grep -Eq "$1"; then
    printf 'ok   %s: %s\n' "$CASE" "$2"
  else
    printf 'FAIL %s: %s (pattern %s)\n     out: %s\n' "$CASE" "$2" "$1" "$OUT"
    FAILED=1
  fi
}

assert_rc() { # <expected> <description>
  if [ "$RC" -eq "$1" ]; then
    printf 'ok   %s: %s\n' "$CASE" "$2"
  else
    printf 'FAIL %s: %s (rc=%s)\n     out: %s\n' "$CASE" "$2" "$RC" "$OUT"
    FAILED=1
  fi
}

assert_not_out() { # <grep -E pattern> <description>
  if printf '%s' "$OUT" | grep -Eq "$1"; then
    printf 'FAIL %s: %s (unexpected match %s)\n     out: %s\n' "$CASE" "$2" "$1" "$OUT"
    FAILED=1
  else
    printf 'ok   %s: %s\n' "$CASE" "$2"
  fi
}

new_case green_path
seed_home; seed_memory; seed_lessons
verify_config
add_row 7 "$SHA1" "2026-07-01T00:00:00Z" APPROVE done
run_verify
assert_rc 0 'clean structure passes'
assert_out '^PASS' 'prints PASS'

new_case missing_work_pointer
seed_home; seed_memory; seed_lessons
verify_config
rm -f "$WORK/AGENTS.md"
run_verify
assert_rc 1 'missing work/AGENTS.md fails'
assert_out 'work-pointer' 'names the harness entry pointer'
assert_out 'Step 3c' 'carries the template location'

new_case missing_memory_section
seed_home; seed_memory; seed_lessons
verify_config
sed -e 's/^## Feedback Log$//' "$WORK/MEMORY.md" > "$WORK/MEMORY.md.tmp" && mv "$WORK/MEMORY.md.tmp" "$WORK/MEMORY.md"
run_verify
assert_rc 1 'missing MEMORY.md section fails'
assert_out "FAIL memory .*Feedback Log" 'names the missing section'
assert_out 'fix:' 'carries a fix instruction'

new_case malformed_reviews_row
seed_home; seed_memory; seed_lessons
verify_config
add_row 8 "deadbeef" "2026-07-01T00:00:00Z" APPROVE done   # short sha
run_verify
assert_rc 1 'short sha fails'
assert_out 'FAIL reviews-rows' 'flags the malformed row'

new_case slack_without_roster
seed_home; seed_memory; seed_lessons
verify_config '- slack_notifications: enabled' '- escalation_owner: alice'
run_verify
assert_rc 1 'slack enabled without roster fails'
assert_out 'FAIL roster' 'flags the missing DEVELOPERS.md'

new_case owner_not_in_roster
seed_home; seed_memory; seed_lessons
verify_config '- slack_notifications: enabled' '- escalation_owner: bob'
{
  printf '| login | slack_id | name | expertise (seed) | observed areas |\n'
  printf '| --- | --- | --- | --- | --- |\n'
  printf '| alice | U0123ABCD | Alice K. | frontend | |\n'
} > "$WORK/DEVELOPERS.md"
run_verify
assert_rc 1 'owner outside the roster fails'
assert_out 'FAIL escalation-owner' 'flags the unresolvable owner'

new_case slack_with_roster
seed_home; seed_memory; seed_lessons
verify_config '- slack_notifications: enabled' '- escalation_owner: alice'
{
  printf '# Developers roster\n\n'
  printf '| login | slack_id | name | expertise (seed) | observed areas |\n'
  printf '| --- | --- | --- | --- | --- |\n'
  printf '| alice | U0123ABCD | Alice K. | frontend | |\n'
} > "$WORK/DEVELOPERS.md"
run_verify
assert_rc 0 'roster + resolvable owner passes'

new_case bullet_roster
seed_home; seed_memory; seed_lessons
verify_config '- slack_notifications: enabled' '- escalation_owner: bob'
{
  printf '# Developer Roster\n\n## Bob\n\n'
  printf -- '- login: `bob`\n- slack_id: `U0999ZZZZ`\n'
} > "$WORK/DEVELOPERS.md"
run_verify
assert_rc 0 'bullet-format roster passes (mirrors preflight parsing)'
assert_out 'ok   escalation-owner' 'owner resolved from bullet pairs'

new_case inner_work_git
seed_home; seed_memory; seed_lessons
verify_config
mkdir -p "$WORK/.git"
run_verify
assert_rc 1 'work/.git fails'
assert_out 'FAIL work-plain' 'flags the inner .git'

new_case version_drift
seed_home; seed_memory; seed_lessons
verify_config
printf '1.0.0\n' > "$WORK/VERSION"
run_verify
assert_rc 1 'adopted != checked-out fails'
assert_out 'FAIL work-version' 'flags the drift'

new_case invalid_enum
seed_home; seed_memory; seed_lessons
verify_config '- slack_notifications: maybe'
run_verify
assert_rc 1 'invalid enum value fails'
assert_out 'FAIL config-slack_notifications' 'names the key'

new_case unexpected_extras_warn_only
seed_home; seed_memory; seed_lessons
verify_config
printf 'x\n' > "$WORK/UNEXPECTED.txt"
run_verify
assert_rc 0 'unknown extras never block'
assert_out 'warn work-layout .*UNEXPECTED.txt' 'extras are listed as a warning'

new_case missing_github_repo
seed_home; seed_memory; seed_lessons
base_config '- definition_repo: acme/code-guardian'     # no github_repo, no env var
run_verify
assert_rc 1 'unresolvable target repo fails'
assert_out 'FAIL config-github_repo' 'names the key'
assert_out "fix: add '- github_repo:" 'carries the fix'

new_case github_repo_from_env_only
seed_home; seed_memory; seed_lessons
base_config '- definition_repo: acme/code-guardian'
TEST_ENV_REPO="$TEST_REPO"; run_verify; TEST_ENV_REPO=""
assert_rc 0 'env var alone never blocks'
assert_out 'warn config-github_repo .*scheduled run' 'warns that fresh runs need the platform env var'

new_case host_prefixed_refs
seed_home; seed_memory; seed_lessons
base_config '- definition_repo: ghe.example.com/acme/code-guardian' \
            '- github_repo: ghe.example.com/acme/widgets'
( cd "$FAKE_HOME" && git remote set-url origin https://ghe.example.com/acme/code-guardian.git )
run_verify
assert_rc 0 'host-prefixed references pass the shape check'
assert_out 'ok   def-origin' 'origin matched against the prefixed reference'

new_case backticked_values
seed_home; seed_memory; seed_lessons
base_config '- definition_repo: `acme/code-guardian`' '- github_repo: `acme/widgets`' \
            '- slack_notifications: `disabled`'
run_verify
assert_rc 0 'markdown-quoted values parse like plain ones'
assert_out 'ok   def-origin' 'quoted definition_repo resolved'

new_case unknown_config_keys
seed_home; seed_memory; seed_lessons
verify_config '- Full name: acme/widgets' '- GitHub username: alice'
run_verify
assert_rc 0 'unknown keys never block on their own'
assert_out "warn config-keys .*'Full name'.*'GitHub username'" 'names every bullet the runtime ignores'

new_case live_green_path
seed_home; seed_memory; seed_lessons
verify_config
{
  printf '\n## Review skills\n\n'
  printf '| skill | source | trigger | section |\n| --- | --- | --- | --- |\n'
  printf '| issue-fit | acme/code-guardian | always | Issue Fit |\n'
  printf '| harness-only | harness | always | Harness |\n'
} >> "$WORK/CONFIG.md"
fx 'api --hostname github.com user --jq .login'                                   <<< 'test-bot'
fx "api --hostname github.com repos/$TEST_REPO --jq .full_name"                   <<< "$TEST_REPO"
fx "api --hostname github.com repos/$TEST_REPO --jq .permissions.push"            <<< 'true'
fx "api --hostname github.com repos/$TEST_REPO/labels?per_page=100 --paginate --jq .[].name" <<< 'cg-rereview'
fx 'api --hostname github.com repos/acme/code-guardian/contents/.agents/skills/issue-fit --jq if type == "array" then (.[0].name // empty) else (.name // empty) end' <<< 'SKILL.md'
fx 'api --hostname github.com repos/acme/code-guardian/branches/main --jq .name'  <<< 'main'
run_verify_live
assert_rc 0 'a reachable environment passes'
assert_out '^PASS \(structure\+live\)' 'reports the live scope'
assert_out 'ok   live-identity' 'token identity matches bot_login'
assert_out 'ok   live-skills — 1 repo-sourced' 'harness rows are not fetched'
assert_out 'ok   live-preflight' 'preflight returns a valid worklist'

new_case live_wrong_identity_and_missing_label
seed_home; seed_memory; seed_lessons
verify_config
fx 'api --hostname github.com user --jq .login'                        <<< 'someone-else'
fx "api --hostname github.com repos/$TEST_REPO --jq .full_name"        <<< "$TEST_REPO"
fx "api --hostname github.com repos/$TEST_REPO --jq .permissions.push" <<< 'true'
fx 'api --hostname github.com repos/acme/code-guardian/branches/main --jq .name' <<< 'main'
run_verify_live
assert_rc 1 'a mismatched token fails'
assert_out "FAIL live-identity .*'someone-else'" 'names the authenticated login'
assert_out 'FAIL live-rereview-label .*cg-rereview' 'flags the missing re-review label'
assert_out 'gh label create' 'carries the create command'

new_case live_identity_without_bot_login
seed_home; seed_memory; seed_lessons
{
  printf -- '- review_marker: cg:review\n'
  printf -- '- definition_repo: acme/code-guardian\n'
  printf -- '- github_repo: %s\n' "$TEST_REPO"
} > "$WORK/CONFIG.md"
fx 'api --hostname github.com user --jq .login' <<< 'someone'
run_verify_live
assert_rc 1 'the required-key check owns the missing bot_login'
assert_out 'FAIL config-bot_login' 'names the missing key once'
assert_not_out 'ok   live-identity' 'no identity is confirmed without the key'

finish
