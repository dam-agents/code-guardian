#!/usr/bin/env bash
# definition-pr.sh — the one path by which a channel request becomes a draft
# PR on the definition repo (docs/channel-requests.md → **Draft PR**).
#
#   prepare <id>                      a fresh clone of main on branch
#                                     channel/<id>, the bot as git identity
#   open    <id> <title> <body-file>  the checks, the scan, the commit, the
#                                     push, then the draft PR
#   discard <id>                      remove the clone
#
# <id> is a kebab-case slug of at most 40 characters. The clone lives at
# ${TMPDIR:-/tmp}/cg-defpr-<id>, never in $HOME. Prints one JSON object with
# `outcome` and exits 0:
#   disabled — `channel_definition_prs` is not `enabled`; nothing read from or
#              sent to GitHub
#   ready    — (prepare) the clone is at `dir`
#   exists   — the branch, or an open PR from it, is already on the remote;
#              `url` when a PR is open
#   invalid  — (open) `reason`: VERSION not bumped, VERSION and the newest
#              CHANGELOG.md heading differ, or `bash -n` fails on a script
#   nothing  — (open) the clone has no change
#   blocked  — (open) the title, the body or the diff names this instance;
#              `hits` as scripts/definition-issue.sh scan-pr prints them.
#              Nothing is committed or sent
#   opened   — (open) the draft PR was created; `url`
#   discarded — (discard) the clone is gone
#   error    — bad arguments, an unresolved definition repo or a failed call
#
# The agent edits the clone; this script never composes or changes a line of
# it. Only the definition's allowlisted paths are committed
# (docs/persistence.md → **Evolving the agent definition**).
# Requires bash, jq, gh, git, sed, grep.

set -u
export LC_ALL=C

CMD="${1:-}"; ID="${2:-}"; TITLE="${3:-}"; BODY_FILE="${4:-}"
HOME_DIR="${HOME:-/home/agent}"
WORK="${WORK_DIR:-$HOME_DIR/work}"
CONFIG="$WORK/CONFIG.md"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

TITLE_MAX=120
BODY_MAX=8000
PATHS=(CLAUDE.md AGENTS.md ONBOARDING.md README.md kit.yaml VERSION CHANGELOG.md .gitignore LICENSE docs scripts .agents .github)

out() { printf '%s\n' "$1"; exit 0; }
fail() { out "$(jq -nc --arg e "$1" '{outcome:"error", error:$e}')"; }

case "$CMD" in (prepare|discard) ;; (open) [ $# -eq 4 ] || CMD=usage;; (*) CMD=usage;; esac
if [ "$CMD" = usage ]; then
  printf 'usage: %s prepare <id> | open <id> <title> <body-file> | discard <id>\n' "$0" >&2; exit 2
fi
printf '%s' "$ID" | grep -qE '^[a-z0-9]+(-[a-z0-9]+)*$' && [ "${#ID}" -le 40 ] \
  || fail "id must be a kebab-case slug of at most 40 characters"

. "$SCRIPT_DIR/lib/common.sh"
if ! . "$SCRIPT_DIR/log.sh" 2>/dev/null; then logev() { :; }; fi

DIR="${TMPDIR:-/tmp}"; DIR="${DIR%/}/cg-defpr-$ID"
BRANCH="channel/$ID"

if [ "$CMD" = "discard" ]; then
  rm -rf "$DIR"; logev info definition_pr "$ID: clone discarded"
  out '{"outcome":"discarded"}'
fi

# --- the gate: nothing below runs while the operator has not opted in --------
GATE="$(cfg channel_definition_prs)"
if [ "$GATE" != "enabled" ]; then
  logev info definition_pr "$ID: not opened — channel_definition_prs is ${GATE:-unset}"
  out '{"outcome":"disabled"}'
fi

DEF_REF="$(cfg definition_repo)"
[ -z "$DEF_REF" ] && DEF_REF="$(origin_ref "$HOME_DIR")"
DEF_HOST="$(refhost "$DEF_REF")"; DEFINITION_REPO="$(refslug "$DEF_REF")"
[ -n "$DEFINITION_REPO" ] || fail "definition_repo unresolved"

# the branch or its PR on the remote: an earlier request with this id
remote_exists() {
  local prs url heads
  prs="$(gh api --hostname "$DEF_HOST" \
    "repos/$DEFINITION_REPO/pulls?state=open&head=${DEFINITION_REPO%%/*}:$BRANCH&per_page=10" 2>/dev/null)" \
    || fail "open pull requests unreadable"
  url="$(printf '%s' "$prs" | jq -r '[.[]? | .html_url][0] // empty' 2>/dev/null)"
  [ -n "$url" ] && out "$(jq -nc --arg u "$url" '{outcome:"exists", url:$u}')"
  heads="$(git ls-remote --heads "$CLONE_URL" "$BRANCH" 2>/dev/null)" || fail "remote branches unreadable"
  [ -z "$heads" ] || out '{"outcome":"exists"}'
}
CLONE_URL="${CG_CLONE_URL:-$(git -C "$HOME_DIR" remote get-url origin 2>/dev/null)}"
[ -n "$CLONE_URL" ] || CLONE_URL="https://$DEF_HOST/$DEFINITION_REPO.git"

if [ "$CMD" = "prepare" ]; then
  remote_exists
  rm -rf "$DIR"
  git clone -q --branch main --single-branch "$CLONE_URL" "$DIR" >/dev/null 2>&1 \
    || { rm -rf "$DIR"; fail "clone of main did not succeed"; }
  git -C "$DIR" checkout -q -b "$BRANCH" >/dev/null 2>&1 || fail "branch not created"
  name="$(cfg bot_display_name)"; name="${name:-Code Guardian}"
  who="$(token_login)"; who="${who:-$(cfg bot_login)}"; who="${who:-code-guardian}"
  git -C "$DIR" config user.name "$name"
  git -C "$DIR" config user.email "$(noreply_email "$who" "$DEF_HOST")"
  git -C "$DIR" rev-parse HEAD > "$DIR/.git/cg-defpr-base"
  logev info definition_pr "$ID: clone ready"
  out "$(jq -nc --arg d "$DIR" --arg b "$BRANCH" '{outcome:"ready", dir:$d, branch:$b}')"
fi

# --- open -----------------------------------------------------------------------
[ -d "$DIR/.git" ] && [ -f "$DIR/.git/cg-defpr-base" ] || fail "no clone — run prepare first"
[ "$(git -C "$DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)" = "$BRANCH" ] || fail "the clone is not on $BRANCH"
BASE="$(cat "$DIR/.git/cg-defpr-base")"
[ -n "$TITLE" ] && [ "${#TITLE}" -le "$TITLE_MAX" ] || fail "title empty or longer than $TITLE_MAX characters"
[ -f "$BODY_FILE" ] && [ -r "$BODY_FILE" ] || fail "body file unreadable"
[ "$(wc -c < "$BODY_FILE" | tr -d ' ')" -le "$BODY_MAX" ] || fail "body longer than $BODY_MAX bytes"

ADD=()
for p in "${PATHS[@]}"; do
  [ -e "$DIR/$p" ] || git -C "$DIR" cat-file -e "$BASE:$p" 2>/dev/null && ADD+=("$p")
done
git -C "$DIR" add -A -- "${ADD[@]}" 2>/dev/null || fail "git add failed"
git -C "$DIR" diff --cached --quiet "$BASE" -- && out '{"outcome":"nothing"}'

invalid() { out "$(jq -nc --arg r "$1" '{outcome:"invalid", reason:$r}')"; }
new_v="$(head -1 "$DIR/VERSION" 2>/dev/null | tr -d '[:space:]')"
old_v="$(git -C "$DIR" show "$BASE:VERSION" 2>/dev/null | head -1 | tr -d '[:space:]')"
[ -n "$new_v" ] && [ "$new_v" != "$old_v" ] || invalid "VERSION is not bumped"
top="$(grep -m1 -E '^## [0-9]' "$DIR/CHANGELOG.md" 2>/dev/null | sed -E 's/^## ([^ ]+).*/\1/')"
[ "$top" = "$new_v" ] || invalid "the newest CHANGELOG.md heading is not $new_v"
bad=""
while IFS= read -r f; do
  case "$f" in (*.sh) [ -f "$DIR/$f" ] && ! bash -n "$DIR/$f" 2>/dev/null && bad="$bad $f";; esac
done < <(git -C "$DIR" diff --cached --name-only "$BASE")
[ -z "$bad" ] || invalid "bash -n fails:$bad"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cg-defpr-scan.XXXXXX")" || fail "no temp dir"
trap 'rm -rf "$TMP"' EXIT
git -C "$DIR" diff --cached -U0 "$BASE" | grep -E '^\+' | grep -vE '^\+\+\+ ' | sed 's/^+//' > "$TMP/added.txt"
SCAN="$(CG_VOCAB_ROOT="$DIR" bash "$SCRIPT_DIR/definition-issue.sh" scan-pr "$TITLE" "$BODY_FILE" "$TMP/added.txt")"
case "$(printf '%s' "$SCAN" | jq -r '.outcome // empty' 2>/dev/null)" in
  (clean) ;;
  (blocked) logev warn definition_pr "$ID: blocked — the draft names instance data"; out "$SCAN";;
  (*) fail "scan failed: $(printf '%s' "$SCAN" | jq -r '.error // "no output"' 2>/dev/null)";;
esac

remote_exists
git -C "$DIR" commit -q -m "$TITLE" >/dev/null 2>&1 || fail "commit failed"
git -C "$DIR" push -q origin "$BRANCH" >/dev/null 2>&1 || fail "push failed"
jq -n --arg t "$TITLE" --rawfile b "$BODY_FILE" --arg h "$BRANCH" \
  '{title:$t, body:$b, head:$h, base:"main", draft:true}' > "$TMP/pr.json" || fail "payload not built"
URL="$(gh api --hostname "$DEF_HOST" -X POST "repos/$DEFINITION_REPO/pulls" --input - \
  < "$TMP/pr.json" 2>/dev/null | jq -r '.html_url // empty' 2>/dev/null)"
case "$URL" in (https://*) ;;
  (*) logev error definition_pr "$ID: create failed"; fail "pull request create failed — $BRANCH is pushed";; esac
rm -rf "$DIR"
logev info definition_pr "$ID: opened $URL"
out "$(jq -nc --arg u "$URL" '{outcome:"opened", url:$u}')"
