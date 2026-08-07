#!/usr/bin/env bash
# verify-onboarding.sh: post-onboarding structure verification — green path
# passes, every structural break (missing section, malformed row, missing
# roster, inner .git, version drift, bad enum) FAILs with a fix instruction.
. "$(dirname "$0")/helpers.sh"

SHA1="1111111111111111111111111111111111111111"

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
  base_config '- definition_repo: acme/code-guardian' "$@"
}

run_verify() {
  OUT="$(WORK_DIR="$WORK" HOME="$FAKE_HOME" CLAUDECODE=0 \
         bash "$REPO_ROOT/scripts/verify-onboarding.sh" 2>&1)"
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

new_case green_path
seed_home; seed_memory; seed_lessons
verify_config
add_row 7 "$SHA1" "2026-07-01T00:00:00Z" APPROVE done
run_verify
assert_rc 0 'clean structure passes'
assert_out '^PASS' 'prints PASS'

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

finish
