#!/usr/bin/env bash
# definition-issue.sh — the one path by which the agent files an issue on the
# definition repo (docs/runbook.md → **Definition-repo issues**).
#
#   check <title> <body-file>   scan the draft only; sends nothing
#   file  <title> <body-file>   the gate, the scan, the duplicate check, then
#                               the issue
#
# Prints one JSON object with `outcome` and exits 0:
#   disabled — `definition_issues` is not `enabled` (file only); nothing read
#              from or sent to GitHub
#   blocked  — the draft names something of this instance; `hits` lists each
#              rule and match. Nothing is sent, the duplicate search included
#   clean    — (check) the draft passed the scan
#   exists   — an open issue with the same title exists; `url`
#   filed    — the issue was created; `url`
#   error    — bad arguments, an unresolved definition repo or a failed call
#
# The definition repo may be public while the target repo is private, so the
# scan is a closed list of what identifies this instance, checked on the title
# and the body together:
#   - every value of work/CONFIG.md that names the instance — target and backup
#     repos (reference, host, owner, name), hosts other than github.com, bot
#     login and display name, marker and labels other than their defaults,
#     escalation owner, human_review_paths, skill-source owners other than the
#     definition repo's, Slack ids of the watch rules;
#   - every roster login, Slack id and name of work/DEVELOPERS.md;
#   - shapes: any URL outside the definition repo, issue and PR numbers, commit
#     SHAs, e-mail addresses, @-mentions, Slack ids, IPv4 addresses, and the
#     credential shapes of lib/redact.sh.
# The definition repo's own reference and URLs are removed before the scan, so
# an instance whose definition repo shares the target's owner can still link
# to it. A value of the documentation placeholders (docs/self-modification.md
# §1) never matches a shape.
#
# The scan backs the agent's own composition rules up; it never replaces them.
# Requires bash, jq, gh (file only), sed, grep, tr.

set -u
export LC_ALL=C

CMD="${1:-}"; TITLE="${2:-}"; BODY_FILE="${3:-}"
HOME_DIR="${HOME:-/home/agent}"
WORK="${WORK_DIR:-$HOME_DIR/work}"
CONFIG="$WORK/CONFIG.md"
DEVELOPERS="$WORK/DEVELOPERS.md"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

TITLE_MAX=120
BODY_MAX=8000

out() { printf '%s\n' "$1"; exit 0; }
fail() { out "$(jq -nc --arg e "$1" '{outcome:"error", error:$e}')"; }

case "$CMD" in (check|file) ;;
  (*) printf 'usage: %s check|file <title> <body-file>\n' "$0" >&2; exit 2;; esac

. "$SCRIPT_DIR/lib/common.sh"
. "$SCRIPT_DIR/lib/redact.sh"
if ! . "$SCRIPT_DIR/log.sh" 2>/dev/null; then logev() { :; }; fi

# --- the gate: nothing below runs while the operator has not opted in --------
if [ "$CMD" = "file" ]; then
  GATE="$(cfg definition_issues)"
  if [ "$GATE" != "enabled" ]; then
    logev info definition_issue "not filed — definition_issues is ${GATE:-unset}"
    out '{"outcome":"disabled"}'
  fi
fi

# --- the draft ----------------------------------------------------------------
case "$TITLE" in
  ('[audit] '?*|'[channel request] '?*) ;;
  (*) fail "title must start with '[audit] ' or '[channel request] '";;
esac
[ "${#TITLE}" -le "$TITLE_MAX" ] || fail "title longer than $TITLE_MAX characters"
[ -n "$BODY_FILE" ] && [ -f "$BODY_FILE" ] && [ -r "$BODY_FILE" ] || fail "body file unreadable"
BODY_LEN="$(wc -c < "$BODY_FILE" | tr -d ' ')"
[ "${BODY_LEN:-0}" -le "$BODY_MAX" ] || fail "body longer than $BODY_MAX bytes"

DEF_REF="$(cfg definition_repo)"
[ -z "$DEF_REF" ] && DEF_REF="$(origin_ref "$HOME_DIR")"
DEF_HOST="$(refhost "$DEF_REF")"; DEFINITION_REPO="$(refslug "$DEF_REF")"
DEF_OWNER="${DEFINITION_REPO%%/*}"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cg-defissue.XXXXXX")" || fail "no temp dir"
trap 'rm -rf "$TMP"' EXIT
DRAFT="$TMP/draft.txt"
{ printf '%s\n' "$TITLE"; cat "$BODY_FILE"; } > "$DRAFT"

# the definition repo's own URLs and reference are the one sanctioned
# reference; drop them so they neither hit the URL shape nor an owner term
SCAN="$TMP/scan.txt"
if [ -n "$DEFINITION_REPO" ]; then
  def_re="$(printf '%s' "$DEF_HOST/$DEFINITION_REPO" | sed 's/[.[\*^$/]/\\&/g')"
  slug_re="$(printf '%s' "$DEFINITION_REPO" | sed 's/[.[\*^$/]/\\&/g')"
  sed -E -e "s/https?:\/\/$def_re([\/#?][^[:space:])>\"'\`]*)?//gI" \
         -e "s/$def_re//gI" -e "s/$slug_re//gI" "$DRAFT" > "$SCAN"
else
  cp "$DRAFT" "$SCAN"
fi

HITS="$TMP/hits.jsonl"; : > "$HITS"
hit() { jq -nc --arg r "$1" --arg m "$2" '{rule:$r, match:$m}' >> "$HITS"; }

# --- instance terms -------------------------------------------------------------
TERMS="$TMP/terms.txt"; : > "$TERMS"
term() { # <rule> <value> — one identifying value, at least 3 characters
  local v; v="$(trim "$1")"
  [ "${#v}" -ge 3 ] || return 0
  printf '%s\t%s\n' "$2" "$v" >> "$TERMS"
}
ref_terms() { # <rule> <[host/]owner/repo>
  local ref="$1" host slug
  [ -n "$ref" ] || return 0
  host="$(refhost "$ref")"; slug="$(refslug "$ref")"
  term "$slug" "$2"
  [ "$host" = "github.com" ] || term "$host" "$2"
  [ "${slug%%/*}" = "$DEF_OWNER" ] || term "${slug%%/*}" "$2"
  term "${slug#*/}" "$2"
}
ref_terms "$(cfg github_repo)" target_repo
ref_terms "$(cfg work_repo)" work_repo
[ "$DEF_HOST" = "github.com" ] || term "$DEF_HOST" definition_host
term "$(cfg bot_login)" bot_login
v="$(cfg bot_display_name)"; [ "$v" = "Code Guardian" ] || term "$v" bot_display_name
v="$(cfg review_marker)"; [ "$v" = "code-guardian:review" ] || term "$v" review_marker
v="$(cfg rereview_label)"; [ "$v" = "code-guardian-review" ] || term "$v" label
for k in urgent_label auto_merge_label agent_fix_label; do term "$(cfg "$k")" label; done
term "$(cfg escalation_owner)" escalation_owner
cfg human_review_paths | tr -d '`' | tr ',' '\n' | tr -d '*' | while IFS= read -r p; do
  term "$p" human_review_paths
done
skills_table_json 2>/dev/null | jq -r '.[] | select(.source != "harness") | .source' 2>/dev/null \
  | while IFS= read -r src; do
      o="$(refslug "$src")"; o="${o%%/*}"
      [ "$o" = "$DEF_OWNER" ] || term "$o" skill_source
    done
cfg_table 'Watch rules' | grep -oE 'slack:[A-Za-z0-9]+' | while IFS= read -r t; do
  term "${t#slack:}" watch_target
done
if [ -f "$DEVELOPERS" ]; then
  grep -E '^\|' "$DEVELOPERS" | while IFS= read -r row; do
    login="$(row_field "$row" 2)"; sid="$(row_field "$row" 3)"; name="$(row_field "$row" 4)"
    case "$login" in (''|login|-*|:*) continue;; esac
    term "$login" roster; term "$sid" roster; term "$name" roster
  done
fi

while IFS="$(printf '\t')" read -r rule val; do
  [ -n "$val" ] || continue
  grep -qiF -- "$val" "$SCAN" && hit "$rule" "$val"
done < "$TERMS"

# --- shapes ---------------------------------------------------------------------
shape() { # <rule> <ERE> [filter-ERE that a match must also satisfy]
  grep -oiE -- "$2" "$SCAN" 2>/dev/null | sort -u | while IFS= read -r m; do
    [ -n "${3:-}" ] && ! printf '%s' "$m" | grep -qE -- "$3" && continue
    case "$m" in (*U0123ABCD*|*acme/widgets*|*github.example.com*) continue;; esac
    hit "$1" "$m"
  done
}
shape url '[a-z][a-z0-9+.-]*://[^[:space:])>"'"'"'`]+'
shape number '(^|[^A-Za-z0-9&])#[0-9]+'
shape number '(^|[^A-Za-z])(pulls?|issues?|pr)[ /#-]*[0-9]+'
shape sha '(^|[^A-Za-z0-9])[0-9a-f]{12,40}([^A-Za-z0-9]|$)' '[0-9]'
shape email '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
shape mention '(^|[^A-Za-z0-9_.@/-])@[A-Za-z0-9][A-Za-z0-9-]*'
shape slack_id '(^|[^A-Za-z0-9])[UCGDW][A-Z0-9]{8,12}([^A-Za-z0-9]|$)' '[0-9]'
shape ipv4 '(^|[^0-9.])([0-9]{1,3}\.){3}[0-9]{1,3}([^0-9.]|$)'

cp "$DRAFT" "$TMP/redact.txt"
n="$(redact_file "$TMP/redact.txt")" || n=1
[ "${n:-0}" -gt 0 ] && hit credential "$n credential-shaped value(s)"

HITS_JSON="$(jq -sc 'unique' "$HITS")"
if [ "$(printf '%s' "$HITS_JSON" | jq length)" -gt 0 ]; then
  logev warn definition_issue "blocked — draft names instance data ($(printf '%s' "$HITS_JSON" | jq -r '[.[].rule] | unique | join(",")'))"
  out "$(jq -nc --argjson h "$HITS_JSON" '{outcome:"blocked", hits:$h}')"
fi
[ "$CMD" = "check" ] && out '{"outcome":"clean"}'

# --- duplicate check, then the issue ------------------------------------------
[ -n "$DEFINITION_REPO" ] || fail "definition_repo unresolved"
OPEN="$(gh api --hostname "$DEF_HOST" "repos/$DEFINITION_REPO/issues?state=open&per_page=100" 2>/dev/null)" \
  || fail "open issues unreadable"
DUP="$(printf '%s' "$OPEN" | jq -r --arg t "$TITLE" \
  '[.[]? | select((.pull_request | not) and .title == $t) | .html_url][0] // empty' 2>/dev/null)"
[ -n "$DUP" ] && out "$(jq -nc --arg u "$DUP" '{outcome:"exists", url:$u}')"

jq -n --arg t "$TITLE" --rawfile b "$BODY_FILE" '{title:$t, body:$b}' > "$TMP/issue.json" \
  || fail "payload not built"
URL="$(gh api --hostname "$DEF_HOST" -X POST "repos/$DEFINITION_REPO/issues" --input - \
  < "$TMP/issue.json" 2>/dev/null | jq -r '.html_url // empty' 2>/dev/null)"
case "$URL" in (https://*) ;;
  (*) logev error definition_issue "create failed"; fail "issue create failed";; esac
logev info definition_issue "filed $URL"
out "$(jq -nc --arg u "$URL" '{outcome:"filed", url:$u}')"
