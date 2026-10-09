#!/usr/bin/env bash
# Claude Code harness adapter — PreToolUse (Bash) hook: refuses a command that
# writes an issue on the definition repo by any path other than
# scripts/definition-issue.sh (registered by install.sh; what it matches:
# docs/logging.md → Harness adapters; the rule: docs/runbook.md →
# Definition-repo issues). A refused command exits 2 and the model reads the
# reason on stderr.
#
# Anything unexpected (no jq, no definition repo, another tool) exits 0 — the
# script keeps its own gate and scan; this hook only adds the wall around it.
set -u
INPUT="$(cat 2>/dev/null || true)"
# the cheap test first, before any tool resolves: every write below names an
# issue or the addComment mutation
case "$INPUT" in
  (*[iI][sS][sS][uU][eE]*|*[aA][dD][dD][cC][oO][mM][mM][eE][nN][tT]*) ;;
  (*) exit 0;;
esac
# resolve shimmed tools before the jq guard and the first jq call (this hook
# fires per Bash call, so the shim tax dominates it) — ../../lib/toolpath.sh
. "$(cd "$(dirname "$0")/../.." && pwd)/lib/toolpath.sh" 2>/dev/null || true
command -v jq >/dev/null 2>&1 || exit 0

[ "$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)" = "Bash" ] || exit 0
# a backslash-newline continues the line
RAW="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null \
  | awk '{ if (sub(/\\$/, "")) printf "%s ", $0; else print }')"
[ -n "$RAW" ] || exit 0
CMD="$(printf '%s' "$RAW" | tr '\n\t' '  ')"
# one simple command per line: split on ; & | ( ) ` and newlines
SEGS="$(printf '%s\n' "$RAW" | tr ';&|()`\t' '\n\n\n\n\n\n ')"

HOME_DIR="${HOME:-/home/agent}"
CONFIG="${WORK_DIR:-$HOME_DIR/work}/CONFIG.md"
. "$(cd "$(dirname "$0")/../.." && pwd)/lib/common.sh" 2>/dev/null || exit 0
DEF="$(cfg definition_repo)"
[ -n "$DEF" ] || DEF="$(origin_ref "$HOME_DIR")"
SLUG="$(refslug "$DEF")"
[ -n "$SLUG" ] || exit 0
esc() { printf '%s' "$1" | sed 's/[.[\*^$]/\\&/g'; }
slug_re="$(esc "$SLUG")"; owner_re="$(esc "${SLUG%%/*}")"; name_re="$(esc "${SLUG#*/}")"
# the definition repo: its slug, a shell variable named after it ($DEF,
# $DEFINITION_REPO, ${DEF_REF#*/} — not $DEFAULT_REPO), or gh's {owner}/{repo},
# which resolves to the checkout under $HOME
VAR_NAME='[A-Za-z0-9_]*DEF(INITION)?(_[A-Za-z0-9_]*)?'
DEF_RE="($slug_re|\\\$(\\{$VAR_NAME([^A-Za-z0-9_}][^}]*)?\\}|$VAR_NAME)|\\{owner\\}/\\{repo\\})"
ISSUES_RE="repos/$DEF_RE/issues"
B='[^A-Za-z0-9_.-]'
Q="[\"'\\\\]*"

m() { printf '%s' "$1" | grep -qiE -- "$2"; } # <text> <ERE>

GH_API='(^|[[:space:]])gh[[:space:]]+api([[:space:]]|$)'
API_METHOD_WRITE="(^|[[:space:]])(-X|--method)[[:space:]=]*$Q(POST|PATCH|PUT|DELETE)"
API_METHOD_GET="(^|[[:space:]])(-X|--method)[[:space:]=]*${Q}GET([\"'[:space:]]|\$)"
API_FIELDS='(^|[[:space:]])(-f|-F|--field|--raw-field|--input)([[:space:]=]|$)|(^|[[:space:]])(-f|-F)[^[:space:]]*='
api_write() { # <text> — a gh api write to the definition issues; an explicit GET is a read
  m "$1" "$GH_API" && m "$1" "$ISSUES_RE" || return 1
  m "$1" "$API_METHOD_WRITE" || { m "$1" "$API_FIELDS" && ! m "$1" "$API_METHOD_GET"; }
}

ISSUE_VERB='(^|[[:space:]])gh[[:space:]]+issue([[:space:]]+(-R|--repo)([[:space:]]+|=)?[^[:space:]]+)?[[:space:]]+(create|comment|edit|close|reopen|delete|transfer|pin|unpin|lock|unlock|develop)([[:space:]]|$)'
REPO_FLAG='(^|[[:space:]])(-R|--repo)'
REPO_DEF="(^|[[:space:]])(-R|--repo)[[:space:]=]*[\"']?([A-Za-z0-9.-]+/)?$DEF_RE([[:space:]\"']|\$)"

CURL='(^|[[:space:]])curl([[:space:]]|$)'
CURL_WRITE='(^|[[:space:]])(-X|--request)[[:space:]=]*["'"'"']?(POST|PATCH|PUT|DELETE)|(^|[[:space:]])(-d|-F|-T)|(^|[[:space:]])(--data[a-z-]*|--json|--form|--upload-file)([[:space:]=]|$)'
curl_write() { m "$1" "$CURL" && m "$1" "$ISSUES_RE" && m "$1" "$CURL_WRITE"; }

GQL_MUTATION='(^|[^A-Za-z])(createIssue|updateIssue|addComment|closeIssue|reopenIssue|deleteIssue|transferIssue)([^A-Za-z]|$)'
GQL_REPO='(^|[^A-Za-z])owner([^A-Za-z]|$)|\$\{?[A-Za-z0-9_]*REPO|repos/|(^|[[:space:]])(-R|--repo)'
gql_write() { # <text> — an issue mutation naming the definition repo, or no repo at all
  m "$1" "$GH_API" && m "$1" 'graphql' && m "$1" "$GQL_MUTATION" || return 1
  m "$1" "(^|$B)$DEF_RE($B|\$)" && return 0
  m "$1" "(^|[^A-Za-z])owner$Q[[:space:]]*[:=][[:space:]]*$Q$owner_re($B|\$)" \
    && m "$1" "(^|[^A-Za-z])name$Q[[:space:]]*[:=][[:space:]]*$Q$name_re($B|\$)" && return 0
  ! m "$1" "$GQL_REPO"
}

reason=""
while IFS= read -r seg; do
  case "$seg" in (*[gG][hH]*|*[cC][uU][rR][lL]*) ;; (*) continue;; esac
  if m "$seg" "$ISSUE_VERB"; then
    if ! m "$seg" "$REPO_FLAG"; then
      reason="a gh issue write without --repo, which gh resolves to the checkout under \$HOME: the definition repo"
    elif m "$seg" "$REPO_DEF"; then
      reason="a gh issue write on the definition repo"
    fi
  fi
  [ -z "$reason" ] && api_write "$seg" && reason="a gh api write to the issues of the definition repo"
  [ -z "$reason" ] && curl_write "$seg" && reason="a curl write to the issues of the definition repo"
  [ -n "$reason" ] && break
done <<EOF
$SEGS
EOF
# the whole command too: a quoted ; or | must not split one write in two
[ -z "$reason" ] && api_write "$CMD" && reason="a gh api write to the issues of the definition repo"
[ -z "$reason" ] && curl_write "$CMD" && reason="a curl write to the issues of the definition repo"
[ -z "$reason" ] && gql_write "$CMD" && reason="an issue GraphQL mutation on the definition repo"
[ -n "$reason" ] || exit 0

# a deployed instance logs the block; a bare checkout has no log to write
if [ -f "$CONFIG" ]; then
  sid="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
  [ -n "$sid" ] && export LOG_RUN_ID="$sid"
  if . "$(cd "$(dirname "$0")/../.." && pwd)/log.sh" 2>/dev/null; then
    logev warn definition_issue "guard blocked $reason"
  fi
fi
printf 'code-guardian: command blocked — %s. An issue on the definition repository (%s) is filed only with `bash "$HOME/scripts/definition-issue.sh" file "<title>" <body-file>`, which applies the definition_issues switch and the instance-data scan before it sends anything (docs/runbook.md → Definition-repo issues). Issues and comments on the target repo are not affected; run a target-repo write as a command of its own.\n' "$reason" "$SLUG" >&2
exit 2
