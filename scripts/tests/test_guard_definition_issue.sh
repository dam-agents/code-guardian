#!/usr/bin/env bash
# PreToolUse hook (scripts/harness/claude-code/guard-definition-issue.sh): a
# Bash command that writes an issue on the definition repo by any path other
# than scripts/definition-issue.sh exits 2; everything else passes.
# Rule: docs/runbook.md → Definition-repo issues.
. "$(dirname "$0")/helpers.sh"

HOOK="$REPO_ROOT/scripts/harness/claude-code/guard-definition-issue.sh"

# run the hook for one tool call; exit status lands in $RC, stderr in $ERR
run_hook() { # <tool_name> <command>
  printf '{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"%s","tool_input":{"command":%s}}' \
    "$1" "$(printf '%s' "$2" | jq -Rs .)" \
    | WORK_DIR="$WORK" HOME="$FAKE_HOME" bash "$HOOK" >/dev/null 2>"$SANDBOX/stderr"
  RC=$?
  ERR="$(cat "$SANDBOX/stderr")"
}

assert_rc() { # <expected> <description>
  if [ "$RC" -eq "$1" ]; then printf 'ok   %s: %s\n' "$CASE" "$2"
  else
    printf 'FAIL %s: %s (want exit %s, got %s)\n     stderr: %s\n' "$CASE" "$2" "$1" "$RC" "$(printf '%s' "$ERR" | cut -c1-200)"
    FAILED=1
  fi
}

blocked() { # <command> <description>
  run_hook Bash "$1"; assert_rc 2 "$2"
}
passes() { # <command> <description>
  run_hook Bash "$1"; assert_rc 0 "$2"
}

new_case guard_definition_repo
base_config '- definition_repo: acme/guardian'
blocked 'gh api -X POST repos/acme/guardian/issues --input - < /tmp/issue.json' 'gh api POST to the definition issues'
blocked 'gh api --hostname github.com "repos/acme/guardian/issues" -f title=x -f body=y' 'gh api with fields (an implicit POST)'
blocked 'gh api -X PATCH repos/acme/guardian/issues/4 -f state=closed' 'gh api PATCH on one definition issue'
blocked 'gh api repos/acme/guardian/issues/4/comments -X POST -f body=hi' 'gh api comment on a definition issue'
blocked 'gh api -X POST "repos/$DEFINITION_REPO/issues" --input -' 'a variable named after the definition'
blocked 'gh api -X POST "repos/${DEF_REF#*/}/issues" --input -' 'a braced variable named after the definition'
blocked 'gh issue create --title x --body y' 'gh issue create without --repo'
blocked 'cd "$HOME" && gh issue create -t x -b y' 'gh issue create from the checkout'
blocked 'gh issue create -R acme/guardian --title x' 'gh issue create on the definition repo'
blocked 'gh issue comment 4 --repo github.com/acme/guardian --body hi' 'gh issue comment on the definition repo, host-prefixed'
blocked 'gh api graphql -f query='"'"'mutation { createIssue(input:{repositoryId:"x"}) { issue { id } } }'"'" 'the createIssue mutation'
blocked 'curl -s -X POST -H "Authorization: token $T" https://api.github.com/repos/acme/guardian/issues -d @body.json' 'curl POST to the definition issues'
case "$ERR" in
  (*definition-issue.sh*) printf 'ok   %s: stderr names the script\n' "$CASE";;
  (*) printf 'FAIL %s: stderr does not name the script: %s\n' "$CASE" "$(printf '%s' "$ERR" | cut -c1-200)"; FAILED=1;;
esac

passes 'gh api repos/acme/guardian/issues?state=open&per_page=100' 'reading the definition issues'
passes 'gh api -X POST repos/acme/widgets/issues -f title=x' 'an issue on the target repo'
passes 'gh api "repos/$REPO/issues/12/comments" -X POST -f body=hi' 'a comment on a target PR through $REPO'
passes 'gh issue comment 5 -R acme/widgets --body hi' 'gh issue comment on the target repo'
passes 'gh issue list -R acme/guardian --state open' 'listing definition issues'
passes 'bash "$HOME/scripts/definition-issue.sh" file "[audit] Skipped tick counted as an error" /tmp/body.md' 'the script itself'
passes 'grep -rn createIssue docs/' 'reading about the mutation'
passes 'gh api -X POST repos/acme/guardian/pulls -f title=x -f head=b -f base=main' 'a definition PR is not an issue'
run_hook Read 'gh issue create'; assert_rc 0 'another tool passes'
run_hook Bash ''; assert_rc 0 'an empty command passes'

# --- the definition repo from $HOME's origin when CONFIG.md lacks the key ----------
new_case guard_origin_fallback
base_config
git -C "$FAKE_HOME" init -q && git -C "$FAKE_HOME" remote add origin "git@github.com:acme/guardian.git"
blocked 'gh api -X POST repos/acme/guardian/issues --input -' 'definition repo resolved from origin'
passes 'gh api -X POST repos/acme/widgets/issues --input -' 'the target repo still passes'

# --- no definition repo at all: nothing to guard ----------------------------------
new_case guard_unresolved
base_config
passes 'gh api -X POST repos/acme/guardian/issues --input -' 'unresolved definition repo blocks nothing'
passes 'gh issue create --title x' 'no definition repo, no wall — the script keeps its own gate'

finish
