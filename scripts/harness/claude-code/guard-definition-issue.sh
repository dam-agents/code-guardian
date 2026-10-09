#!/usr/bin/env bash
# Claude Code harness adapter — PreToolUse (Bash) hook: refuses a command that
# writes an issue on the definition repo by any path other than
# scripts/definition-issue.sh (registered by install.sh; contract:
# docs/logging.md → Harness adapters; the rule: docs/runbook.md →
# Definition-repo issues).
#
# The definition repo can be public while the target repo is private, so the
# only issue the agent files there is the anonymous one that script gates and
# scans first. This hook makes the rule mechanical: a Bash command that
# creates, comments on or edits an issue of the definition repo through gh,
# the GitHub API or curl exits 2, and the model reads the reason on stderr.
# It matches the definition repo's reference as work/CONFIG.md (or $HOME's
# origin) resolves it and a shell variable whose name contains DEF
# (`$DEFINITION_REPO`, `$DEF_REF`); a `gh issue` write without a repository
# flag (gh would resolve the checkout under $HOME — the definition repo); and
# the createIssue GraphQL mutation. Everything else passes, the target repo's
# issues and comments included.
#
# Anything unexpected (no jq, no definition repo, another tool) exits 0 — the
# script keeps its own gate and scan; this hook only adds the wall around it.
set -u
INPUT="$(cat 2>/dev/null || true)"
[ -z "$INPUT" ] && exit 0
# resolve shimmed tools before the jq guard and the first jq call (this hook
# fires per Bash call, so the shim tax dominates it) — ../../lib/toolpath.sh
. "$(cd "$(dirname "$0")/../.." && pwd)/lib/toolpath.sh" 2>/dev/null || true
command -v jq >/dev/null 2>&1 || exit 0

[ "$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)" = "Bash" ] || exit 0
CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null | tr '\n\t' '  ')"
[ -n "$CMD" ] || exit 0
# the cheap test first: every write below names an issue
case "$CMD" in (*[iI][sS][sS][uU][eE]*) ;; (*) exit 0;; esac

HOME_DIR="${HOME:-/home/agent}"
CONFIG="${WORK_DIR:-$HOME_DIR/work}/CONFIG.md"
. "$(cd "$(dirname "$0")/../.." && pwd)/lib/common.sh" 2>/dev/null || exit 0
DEF="$(cfg definition_repo)"
[ -n "$DEF" ] || DEF="$(origin_ref "$HOME_DIR")"
SLUG="$(refslug "$DEF")"
[ -n "$SLUG" ] || exit 0
slug_re="$(printf '%s' "$SLUG" | sed 's/[.[\*^$]/\\&/g')"
# the definition repo's slug, or a shell variable named after the definition
DEF_RE="($slug_re|\\\$(\\{[A-Za-z0-9_]*DEF[^}]*\\}|[A-Za-z0-9_]*DEF[A-Za-z0-9_]*))"
ISSUES_RE="repos/$DEF_RE/issues"

has() { printf '%s' "$CMD" | grep -qiE -- "$1"; }
reason=""
if has '(^|[[:space:]])gh[[:space:]]+api([[:space:]]|$)' && has "$ISSUES_RE" \
   && has '(^|[[:space:]])(-X|--method)[[:space:]=]*(POST|PATCH|PUT|DELETE)|(^|[[:space:]])(-f|-F|--field|--raw-field|--input)([[:space:]=]|$)'; then
  reason="a gh api write to the issues of the definition repo"
elif has '(^|[[:space:]])gh[[:space:]]+issue[[:space:]]+(create|comment|edit|close|reopen|delete|transfer|pin|unpin|lock|unlock|develop)([[:space:]]|$)'; then
  if ! has '(^|[[:space:]])(-R|--repo)([[:space:]=]|$)'; then
    reason="a gh issue write without --repo, which gh resolves to the checkout under \$HOME: the definition repo"
  elif has "(^|[[:space:]])(-R|--repo)[[:space:]=]+([A-Za-z0-9.-]+/)?$DEF_RE([[:space:]\"']|$)"; then
    reason="a gh issue write on the definition repo"
  fi
elif has '(^|[[:space:]])gh[[:space:]]+api([[:space:]]|$)' && has 'graphql' && has 'createIssue'; then
  reason="the createIssue GraphQL mutation"
elif has '(^|[[:space:]])curl([[:space:]]|$)' && has "$ISSUES_RE" \
   && has '(^|[[:space:]])(-X|--request)[[:space:]=]*(POST|PATCH|PUT|DELETE)|(^|[[:space:]])(-d|--data|--data-binary|--data-raw|--json)([[:space:]=]|$)'; then
  reason="a curl write to the issues of the definition repo"
fi
[ -n "$reason" ] || exit 0

# a deployed instance logs the block; a bare checkout has no log to write
if [ -f "$CONFIG" ]; then
  sid="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
  [ -n "$sid" ] && export LOG_RUN_ID="$sid"
  if . "$(cd "$(dirname "$0")/../.." && pwd)/log.sh" 2>/dev/null; then
    logev warn definition_issue "guard blocked $reason"
  fi
fi
printf 'code-guardian: command blocked — %s. An issue on the definition repository (%s) is filed only with `bash "$HOME/scripts/definition-issue.sh" file "<title>" <body-file>`, which applies the definition_issues switch and the instance-data scan before it sends anything (docs/runbook.md → Definition-repo issues). Issues and comments on the target repo are not affected.\n' "$reason" "$SLUG" >&2
exit 2
