#!/usr/bin/env bash
# definition-pr.sh (docs/channel-requests.md → **Draft PR**): the key gates
# every call, the clone stays out of $HOME, open refuses an unbumped VERSION,
# a broken script and a draft or diff that names this instance, and a clean
# change is pushed to channel/<id> and opened as a draft PR. A failed create
# and discard leave no pushed branch that no open PR uses.
. "$(dirname "$0")/helpers.sh"

DEF="acme/guardian"
ID="quiet-hours-per-team"
PRS="api --hostname github.com repos/$DEF/pulls?state=open&head=acme:channel/$ID&per_page=10"
CREATE="api --hostname github.com -X POST repos/$DEF/pulls --input -"
TITLE="feat: quiet hours per team (99.0.0)"

instance() { # [extra CONFIG lines…]
  {
    printf -- '- github_repo: globex/payroll-core\n'
    printf -- '- definition_repo: %s\n' "$DEF"
    printf -- '- bot_login: globex-review-bot\n'
    for l in "$@"; do printf -- '%s\n' "$l"; done
  } > "$WORK/CONFIG.md"
  {
    printf '| login | slack_id | name | expertise (seed) | observed areas |\n'
    printf '| --- | --- | --- | --- | --- |\n'
    printf '| hpatel | U07QX3KD9 | Hana Patel | payments | |\n'
  } > "$WORK/DEVELOPERS.md"
}

# a bare remote whose main is this definition's tracked text
remote() {
  REMOTE="$SANDBOX/remote.git"; SEED="$SANDBOX/seed"
  git init -q --bare "$REMOTE"
  mkdir -p "$SEED"
  cp -R "$REPO_ROOT/docs" "$REPO_ROOT/scripts" "$REPO_ROOT/.agents" "$REPO_ROOT"/*.md "$REPO_ROOT"/*.yaml "$REPO_ROOT/VERSION" "$SEED/"
  rm -rf "$SEED/scripts/tests"
  git -C "$SEED" init -q -b main && git -C "$SEED" add -A \
    && git -C "$SEED" -c user.name=t -c user.email=t@t commit -q -m seed \
    && git -C "$SEED" push -q "$REMOTE" main 2>/dev/null
}

body() { printf '%s\n' "$@" > "$SANDBOX/body.md"; }

run_pr() { # <args…>
  : > "$SANDBOX/calls.log"
  OUT="$(GH_HOST="" WORK_DIR="$WORK" HOME="$FAKE_HOME" TMPDIR="$SANDBOX" CG_CLONE_URL="$REMOTE" \
         GH_CALLS_LOG="$SANDBOX/calls.log" PATH="$T_DIR/bin:$PATH" \
         bash "$REPO_ROOT/scripts/definition-pr.sh" "$@" 2>>"$STDERR_LOG")"
}

bump() { # <version>
  printf '%s\n' "$1" > "$CLONE/VERSION"
  { printf '# Changelog\n\n## %s — 2026-11-05\n**Upgrade:** Nothing — docs are re-read per run.\n\n' "$1"
    sed -n '/^## /,$p' "$CLONE/CHANGELOG.md"; } > "$SANDBOX/cl" && mv "$SANDBOX/cl" "$CLONE/CHANGELOG.md"
}

CLEAN_BODY=(
  'Adds per-team quiet hours to `docs/shepherd.md`.'
  'Draft from a channel request. A person reviews and merges it.'
)

# --- the key gates everything -----------------------------------------------------
new_case gate_missing_key
instance; REMOTE="$SANDBOX/none.git"
run_pr prepare "$ID"
assert_jq '.outcome == "disabled"' 'a missing key prepares nothing'
[ -s "$SANDBOX/calls.log" ] && { printf 'FAIL %s: gh called while disabled\n' "$CASE"; FAILED=1; } \
  || printf 'ok   %s: no GitHub call while disabled\n' "$CASE"

new_case bad_id
instance '- channel_definition_prs: enabled'; REMOTE="$SANDBOX/none.git"
run_pr prepare 'Quiet Hours'
assert_jq '.outcome == "error" and (.error | contains("kebab-case"))' 'an id that is not a slug is refused'

# --- the full round -----------------------------------------------------------------
new_case round_opened
instance '- channel_definition_prs: enabled'; remote
run_pr prepare "$ID"
assert_jq '.outcome == "ready" and (.dir | endswith("/cg-defpr-quiet-hours-per-team")) and .branch == "channel/quiet-hours-per-team"' 'the clone is ready under TMPDIR on channel/<id>'
CLONE="$SANDBOX/cg-defpr-$ID"
[ "$(git -C "$CLONE" config user.name)" = "Code Guardian" ] && printf 'ok   %s: the bot is the git identity\n' "$CASE" \
  || { printf 'FAIL %s: git identity not set\n' "$CASE"; FAILED=1; }

body "${CLEAN_BODY[@]}"
run_pr open "$ID" "$TITLE" "$SANDBOX/body.md"
assert_jq '.outcome == "nothing"' 'an unchanged clone opens nothing'

printf '\nPer-team quiet hours hold the nudges.\n' >> "$CLONE/docs/shepherd.md"
run_pr open "$ID" "$TITLE" "$SANDBOX/body.md"
assert_jq '.outcome == "invalid" and (.reason | contains("VERSION"))' 'an unbumped VERSION is invalid'

bump 99.0.0
printf 'if then\n' > "$CLONE/scripts/broken.sh"
run_pr open "$ID" "$TITLE" "$SANDBOX/body.md"
assert_jq '.outcome == "invalid" and (.reason | contains("scripts/broken.sh"))' 'a script that fails bash -n is invalid'
rm -f "$CLONE/scripts/broken.sh"

body "${CLEAN_BODY[@]}" 'Asked for globex/payroll-core.'
run_pr open "$ID" "$TITLE" "$SANDBOX/body.md"
assert_jq '.outcome == "blocked" and any(.hits[]; .where == "pr" and .rule == "target_repo")' 'a body that names the target repo is blocked'

body "${CLEAN_BODY[@]}"
printf 'Ask U07QX3KD9 first.\n' >> "$CLONE/docs/shepherd.md"
run_pr open "$ID" "$TITLE" "$SANDBOX/body.md"
assert_jq '.outcome == "blocked" and any(.hits[]; .where == "diff" and .rule == "roster")' 'a diff that names a roster Slack id is blocked'
[ -z "$(git ls-remote --heads "$REMOTE" "channel/$ID")" ] && printf 'ok   %s: nothing pushed while blocked\n' "$CASE" \
  || { printf 'FAIL %s: a blocked draft was pushed\n' "$CASE"; FAILED=1; }

git -C "$CLONE" reset -q && git -C "$CLONE" checkout -q -- docs/shepherd.md
printf '\nThe `payroll-bridge` module holds the nudges.\nSee https://wiki.globex.example/quiet.\n' >> "$CLONE/docs/shepherd.md"
run_pr open "$ID" "$TITLE" "$SANDBOX/body.md"
assert_jq '.outcome == "blocked" and any(.hits[]; .where == "diff" and .rule == "foreign_term" and .match == "payroll-bridge")' 'a diff that names a module the definition never wrote is blocked'
assert_jq 'any(.hits[]; .where == "diff" and .rule == "url" and (.match | contains("wiki.globex.example")))' 'a diff that links a URL the definition lacks is blocked'

git -C "$CLONE" reset -q && git -C "$CLONE" checkout -q -- docs/shepherd.md
printf '\nPer-team quiet hours (`quiet_hours_per_team`) hold the nudges.\n' >> "$CLONE/docs/shepherd.md"
jq -n --arg u "https://github.com/$DEF/pull/77" '{number:77, html_url:$u}' | fx "$CREATE"
run_pr open "$ID" "$TITLE" "$SANDBOX/body.md"
assert_jq '.outcome == "opened" and (.url | endswith("/pull/77"))' 'a clean change is opened and its URL returned'
assert_file_contains "$SANDBOX/calls.log.input" '"draft":true' 'the PR is a draft'
assert_file_contains "$SANDBOX/calls.log.input" '"head":"channel/quiet-hours-per-team"' 'the PR comes from channel/<id>'
[ -n "$(git ls-remote --heads "$REMOTE" "channel/$ID")" ] && printf 'ok   %s: the branch is pushed\n' "$CASE" \
  || { printf 'FAIL %s: the branch is not on the remote\n' "$CASE"; FAILED=1; }
[ "$(git --git-dir="$REMOTE" log -1 --format=%s "channel/$ID")" = "$TITLE" ] && printf 'ok   %s: the commit carries the title\n' "$CASE" \
  || { printf 'FAIL %s: commit message differs\n' "$CASE"; FAILED=1; }
[ ! -d "$CLONE" ] && printf 'ok   %s: the clone is removed after the PR\n' "$CASE" \
  || { printf 'FAIL %s: the clone is left behind\n' "$CASE"; FAILED=1; }

# --- a failed create deletes the pushed branch again ---------------------------------
new_case create_failed
instance '- channel_definition_prs: enabled'; remote
run_pr prepare "$ID"
CLONE="$SANDBOX/cg-defpr-$ID"
printf '\nPer-team quiet hours hold the nudges.\n' >> "$CLONE/docs/shepherd.md"
bump 99.0.0
body "${CLEAN_BODY[@]}"
fx_fail "$CREATE"
run_pr open "$ID" "$TITLE" "$SANDBOX/body.md"
assert_jq '.outcome == "error" and (.error | contains("deleted again"))' 'a failed create answers error'
[ -z "$(git ls-remote --heads "$REMOTE" "channel/$ID")" ] && printf 'ok   %s: the pushed branch is deleted again\n' "$CASE" \
  || { printf 'FAIL %s: the branch stays after a failed create\n' "$CASE"; FAILED=1; }
run_pr discard "$ID"
assert_jq '.outcome == "discarded"' 'discard after a failed create answers'

# --- an earlier request with the same id ------------------------------------------------
new_case exists_pr
instance '- channel_definition_prs: enabled'; remote
jq -n --arg u "https://github.com/$DEF/pull/70" '[{number:70, html_url:$u}]' | fx "$PRS"
run_pr prepare "$ID"
assert_jq '.outcome == "exists" and (.url | endswith("/pull/70"))' 'an open PR from channel/<id> is returned'

new_case exists_branch
instance '- channel_definition_prs: enabled'; remote
git -C "$SEED" push -q "$REMOTE" "main:refs/heads/channel/$ID" 2>/dev/null
run_pr prepare "$ID"
assert_jq '.outcome == "exists"' 'a pushed channel/<id> branch blocks a second prepare'

new_case discard
instance '- channel_definition_prs: enabled'; remote
run_pr prepare "$ID"
printf 'work in progress\n' > "$SANDBOX/cg-defpr-$ID/WIP"
run_pr prepare "$ID"
assert_jq '.outcome == "exists" and (.reason | contains("in use"))' 'a second prepare leaves a clone in use alone'
[ -f "$SANDBOX/cg-defpr-$ID/WIP" ] && printf 'ok   %s: the work in the clone survives\n' "$CASE" \
  || { printf 'FAIL %s: the clone was replaced\n' "$CASE"; FAILED=1; }
run_pr discard "$ID"
assert_jq '.outcome == "discarded"' 'discard answers'
[ ! -d "$SANDBOX/cg-defpr-$ID" ] && printf 'ok   %s: the clone is gone\n' "$CASE" \
  || { printf 'FAIL %s: the clone is left behind\n' "$CASE"; FAILED=1; }

new_case discard_stale_branch
instance '- channel_definition_prs: enabled'; remote
git -C "$SEED" push -q "$REMOTE" "main:refs/heads/channel/$ID" 2>/dev/null
run_pr discard "$ID"
assert_jq '.outcome == "discarded" and (has("url") | not)' 'discard answers with no PR'
[ -z "$(git ls-remote --heads "$REMOTE" "channel/$ID")" ] && printf 'ok   %s: a branch no open PR uses is deleted\n' "$CASE" \
  || { printf 'FAIL %s: the stale branch stays\n' "$CASE"; FAILED=1; }
run_pr prepare "$ID"
assert_jq '.outcome == "ready"' 'the id is free again after discard'

new_case discard_open_pr
instance '- channel_definition_prs: enabled'; remote
git -C "$SEED" push -q "$REMOTE" "main:refs/heads/channel/$ID" 2>/dev/null
jq -n --arg u "https://github.com/$DEF/pull/70" '[{number:70, html_url:$u}]' | fx "$PRS"
run_pr discard "$ID"
assert_jq '.outcome == "discarded" and (.url | endswith("/pull/70"))' 'discard names the open PR'
[ -n "$(git ls-remote --heads "$REMOTE" "channel/$ID")" ] && printf 'ok   %s: the branch of an open PR stays\n' "$CASE" \
  || { printf 'FAIL %s: the branch of an open PR was deleted\n' "$CASE"; FAILED=1; }

# --- the resolved key travels in the worklist's config object -------------------
SHA="1111111111111111111111111111111111111111"
new_case config_default_disabled
base_config
pr_json 1 "a new PR" '[]' "$SHA" | open_prs_fx
run_preflight review
assert_jq '.config.channel_definition_prs == "disabled"' 'a missing key resolves to disabled'

new_case config_enabled
base_config '- channel_definition_prs: enabled'
pr_json 1 "a new PR" '[]' "$SHA" | open_prs_fx
run_preflight review
assert_jq '.config.channel_definition_prs == "enabled"' 'the opt-in travels in the config object'

finish
