#!/usr/bin/env bash
# common.sh — the helpers every script shares: the work/CONFIG.md reader
# (docs/config.md), the developer roster, repo references, time, the event log
# and history-marker reads, GitHub GETs with retry and paging, and the remote
# marker dedup. Set CONFIG before calling cfg or cfg_table; source this file
# before GH_HOST is re-exported, so DEFAULT_HOST keeps the ambient default and
# each reference resolves independently.

# A CONFIG value is the text after `- <key>: `, minus a trailing comment and
# minus one layer of markdown quoting (`value`, "value") — writers reach for
# backticks, and the quoted form must resolve to the same value.
cfg() { sed -n "s/^- $1:[[:space:]]*//p" "$CONFIG" 2>/dev/null | head -1 \
        | sed -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//' \
              -e 's/^[`"'"'"']//' -e 's/[`"'"'"']$//'; }

# The table rows of one `## <heading>` section, stopping at the next `## `
# heading — an unbounded `,$p` range would swallow the sections that follow
# (e.g. `## Watch rules` rows parsed as skills). Header and separator rows are
# the caller's to skip.
cfg_table() { sed -n "/^## $1\$/,\${ /^## $1\$/d; /^## /q; p; }" "$CONFIG" 2>/dev/null | grep -E '^\|'; }

trim() { printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

# --- the token's GitHub identity (docs/github-access.md) --------------------
# $WORK/GITHUB.json caches {login, kind, checked_at} for IDENTITY_TTL_MIN, plus
# {previous, changed_at} once the login changed. kind: `app` for a GitHub App
# login (`<app>[bot]`), else `user`.
IDENTITY_TTL_MIN=60
login_kind() { case "$1" in (*"[bot]") printf app;; (*) printf user;; esac; }
token_login() { jq -r '.login // empty' "$WORK/GITHUB.json" 2>/dev/null; }
token_kind() { local l; l="$(token_login)"; [ -n "$l" ] && login_kind "$l"; }
# The token's login on [host]: GraphQL `viewer`, else REST `GET /user`. An App
# token cannot read /user, and the pod's proxy can refuse GraphQL for a user
# token, so each read covers the other.
gh_login() { # [host]
  local l
  l="$(gh api ${1:+--hostname "$1"} graphql -f query='{viewer{login}}' 2>/dev/null | jq -r '.data.viewer.login // empty' 2>/dev/null)"
  [ -n "$l" ] || l="$(gh api ${1:+--hostname "$1"} user 2>/dev/null | jq -r '.login // empty' 2>/dev/null)"
  [ -n "$l" ] && printf '%s' "$l"
}
# The @-mention pattern of a login, for jq test(): a GitHub App login
# (`<slug>[bot]`) also matches as `@<slug>`, the form people type
mention_re() { # <login>
  local h alt=""
  for h in "$1" "${1%"[bot]"}"; do
    [ -n "$h" ] || continue
    h="$(printf '%s' "$h" | sed 's/[][\\.*^$(){}+?|]/\\&/g')"
    case "|$alt|" in (*"|$h|"*) continue;; esac
    alt="${alt:+$alt|}$h"
  done
  printf '@(%s)([^A-Za-z0-9-]|$)' "$alt"
}
# The commit email GitHub links to <login>: `<id>+<login>@users.noreply.<host>`,
# the plain `<login>@…` form when the account id is unreadable
noreply_email() { # <login> [host]
  local id
  id="$(gh api ${2:+--hostname "$2"} "users/$(uri "$1")" 2>/dev/null | jq -r '.id // empty' 2>/dev/null)"
  case "$id" in (*[!0-9]*) id="";; esac
  printf '%s%s@users.noreply.%s' "${id:+$id+}" "$1" "${2:-github.com}"
}
# Re-reads the token's login (gh_login) when the cache is stale or [force]; a
# failed read keeps the cache as it is.
identity_refresh() { # [force]
  local f="$WORK/GITHUB.json" login age
  if [ "${1:-}" != force ] && [ -f "$f" ]; then
    age=$(( ($(date -u +%s) - $(iso2epoch "$(jq -r '.checked_at // empty' "$f" 2>/dev/null)" 2>/dev/null || echo 0)) / 60 ))
    [ "$age" -lt "$IDENTITY_TTL_MIN" ] && return 0
  fi
  login="$(gh_login)"
  [ -n "$login" ] || return 1
  identity_record "$login"
}
# Writes <login> into the cache as the token's login, with a changed login's
# warn. A read of the token (identity_refresh) or a write that names its
# author (a created check run's App) gives the login. A cache that is not one
# JSON object (empty, cut, corrupted) reads as absent and is written fresh.
identity_record() { # <login>
  local f="$WORK/GITHUB.json" now login="$1" old cur
  [ -n "$login" ] || return 1
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  cur="$(jq -cs 'if length == 1 and (.[0] | type) == "object" then .[0] else empty end' "$f" 2>/dev/null)" || cur=""
  [ -n "$cur" ] || cur='{}'
  old="$(printf '%s' "$cur" | jq -r '.login // empty | strings' 2>/dev/null)"
  printf '%s' "$cur" \
    | jq -c --arg l "$login" --arg k "$(login_kind "$login")" --arg o "$old" --arg ok "$(login_kind "$old")" --arg t "$now" '
        (if $o != "" and $o != $l then .previous = {login: $o, kind: $ok} | .changed_at = $t else . end)
        | .login = $l | .kind = $k | .checked_at = $t' > "$f.tmp" 2>/dev/null \
    && [ -s "$f.tmp" ] && mv -f "$f.tmp" "$f" || { rm -f "$f.tmp"; return 1; }
  if [ -n "$old" ] && [ "$old" != "$login" ] && type logev >/dev/null 2>&1; then
    logev warn github_identity "the GitHub token now acts as $login ($(login_kind "$login")), was $old ($(login_kind "$old")) — run scripts/github-access.sh in the direct session"
  fi
  return 0
}
# Logins whose content is the agent's own by the login alone: bot_login when it
# is a user account. A bot login can be shared by several agents (one GitHub
# App), so its content is the agent's only with the review marker.
self_trusted_login() { local b; b="$(cfg bot_login)"; [ "$(login_kind "$b")" = user ] && printf '%s' "$b"; return 0; }
# The other logins the agent posts as (a bot bot_login, the token's login), as
# a JSON array — their content needs the review marker
self_marked_logins() {
  local t; t="$(self_trusted_login)"
  { cfg bot_login; printf '\n'; token_login; } 2>/dev/null \
    | jq -Rsc --arg t "$t" 'split("\n") | map(select(. != "" and . != $t)) | unique'
}

# The `## Review skills` table as [{skill, source, trigger, section}]
# (docs/skills.md), header and separator rows dropped
skills_table_json() {
  cfg_table 'Review skills' | while IFS='|' read -r _ s src trig sec _rest; do
    s="$(trim "$s")"; case "$s" in (''|skill|-*|:*) continue;; esac
    jq -nc --arg s "$s" --arg src "$(trim "$src")" --arg t "$(trim "$trig")" --arg sec "$(trim "$sec")" \
      '{skill:$s, source:$src, trigger:$t, section:$sec}'
  done | jq -s .
}

# work/DEVELOPERS.md as `login<TAB>slack_id` lines: the table format, else
# `login:` + `slack_id:` bullet pairs (ONBOARDING Step 4 → Build the developer
# roster). The slack_id is raw; SLACK_ID_RE tells a mentionable one.
SLACK_ID_RE='^U[A-Z0-9]{6,}$'
roster_tsv() { # <DEVELOPERS.md>
  local out
  [ -r "$1" ] || return 0
  out="$(grep -E '^\|' "$1" | while IFS='|' read -r _ l sid _rest; do
      l="$(printf '%s' "$l" | tr -d '\` ')"; sid="$(printf '%s' "$sid" | tr -d '\` ')"
      case "$l" in ('') ;; (login) ;; (-*) ;; (*) printf '%s\t%s\n' "$l" "$sid";; esac
    done)"
  [ -n "$out" ] || out="$(login=""; while IFS= read -r line; do
      case "$line" in
        (*slack_id:*) sid="$(printf '%s' "${line#*slack_id:}" | tr -d '\` ')"
                      [ -n "$login" ] && printf '%s\t%s\n' "$login" "$sid";;
        (*login:*)    login="$(printf '%s' "${line#*login:}" | tr -d '\` ')";;
      esac
    done < "$1")"
  [ -z "$out" ] || printf '%s\n' "$out"
}

# The Slack send guard (docs/shepherd.md → Hard rules): rc 1, naming each one on
# stderr, when the text on stdin holds a `<@…>` token that is not a valid roster
# slack_id or any `<!…>` broadcast (here, channel, everyone, subteam); rc 0
# otherwise. A missing roster fails every token.
mentions_check() { # <DEVELOPERS.md>  < message text
  local ids bad
  ids="$(roster_tsv "$1" | cut -f2 | grep -E "$SLACK_ID_RE")"
  bad="$(grep -oE '<[@!][^>]*>' | sort -u | while IFS= read -r t; do
      case "$t" in ('<!'*) printf '%s\n' "$t"; continue;; esac
      id="${t#<@}"; id="${id%>}"; id="${id%%|*}"
      [ -n "$id" ] && printf '%s\n' "$ids" | grep -qxF "$id" || printf '%s\n' "$t"
    done)"
  [ -z "$bad" ] || { printf '%s\n' "$bad" | sed 's/^/not a roster slack_id: /' >&2; return 1; }
}

# one cell of a markdown table row, blanks trimmed
row_field() { printf '%s' "$1" | cut -d'|' -f"$2" | sed -e 's/^ *//' -e 's/ *$//'; }

# ISO timestamp -> epoch, 0 when empty or unparseable. GNU first (it reads an
# empty string as today's midnight, hence the guard); the BSD fallback needs -u
# or the trailing Z is read as local time.
iso2epoch() {
  [ -n "${1:-}" ] || { echo 0; return; }
  date -d "$1" +%s 2>/dev/null || date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || echo 0
}

# Every repo reference is `[<host>/]<owner>/<repo>`: three segments name the
# host, two use the ambient default.
DEFAULT_HOST="${GH_HOST:-github.com}"
refhost() { case "$1" in (*/*/*) printf '%s' "${1%%/*}";; (*) printf '%s' "$DEFAULT_HOST";; esac; }
refslug() { case "$1" in (*/*/*) printf '%s' "${1#*/}";;  (*) printf '%s' "$1";; esac; }

# epoch -> UTC time in <format> (default ISO-8601 with Z), GNU then BSD date;
# empty when neither form works
epoch2iso() { # <epoch> [date format]
  local f="${2:-%Y-%m-%dT%H:%M:%SZ}"
  date -u -d "@$1" +"$f" 2>/dev/null || date -u -r "$1" +"$f" 2>/dev/null
}

# Runs <command…> as the one writer of <file>, a state file several runs
# rewrite in place (work/REVIEWS.md). `mkdir` of `<file>.lock` is atomic; the
# holder writes its pid inside as `owner`, and only the owner gives the lock
# back. A lock older than STATE_LOCK_DEAD_S is a dead writer's: one waiter at a
# time removes it — the one that holds `<file>.break.lock`, and only while the
# lock is still old. A waiter still waiting after STATE_LOCK_WAIT_S, longer than
# a dead lock lives, runs the command anyway with a warn, so a review never
# stalls on the lock. Tests shorten both.
STATE_LOCK_DEAD_S="${STATE_LOCK_DEAD_S:-60}"
STATE_LOCK_WAIT_S="${STATE_LOCK_WAIT_S:-120}"
state_lock_age() { # <path> → seconds since its last change
  local m; m="$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null)" && [ -n "$m" ] || return 1
  printf '%s' $(( $(date +%s) - m ))
}
state_lock_old() { local a; a="$(state_lock_age "$1")" && [ "$a" -ge "$STATE_LOCK_DEAD_S" ]; }
with_state_lock() { # <file> <command…>
  local f="$1" l="$1.lock" b="$1.break.lock" me="${BASHPID:-$$}" start rc; shift
  start=$(date +%s)
  until mkdir "$l" 2>/dev/null; do
    if [ $(( $(date +%s) - start )) -ge "$STATE_LOCK_WAIT_S" ]; then
      command -v logev >/dev/null 2>&1 && logev warn state_lock "${f##*/}: lock held for $STATE_LOCK_WAIT_S s — written without it"
      "$@"; return
    fi
    if state_lock_old "$l" && mkdir "$b" 2>/dev/null; then
      state_lock_old "$l" && rm -rf "$l"
      rmdir "$b" 2>/dev/null
      continue
    fi
    state_lock_old "$b" && rmdir "$b" 2>/dev/null
    sleep 0.1
  done
  printf '%s\n' "$me" > "$l/owner" 2>/dev/null
  "$@"; rc=$?
  [ "$(cat "$l/owner" 2>/dev/null)" = "$me" ] && rm -rf "$l"
  return "$rc"
}

# every retained structured event (docs/logging.md) as one JSON object per
# line; `fromjson?` drops the partial line a concurrently writing session may
# leave. With an event name, a fixed-string grep keeps that event's lines
# before jq parses them (log.sh writes compact JSON). LOG_DIR comes from log.sh.
events_jsonl() { # [event]
  if [ -n "${1:-}" ]; then grep -hF "\"event\":\"$1\"" "$LOG_DIR"/events-*.jsonl 2>/dev/null
  else cat "$LOG_DIR"/events-*.jsonl 2>/dev/null; fi | jq -c -R 'fromjson? // empty' 2>/dev/null
}

# a run id as a log line names it: a harness session UUID by its first 8
# characters, a gate's `<mode>-<stamp>-<pid>` id whole (docs/logging.md → The
# events log)
run_short() { # <run-id>
  case "$1" in
    ([0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-*) printf '%s' "${1:0:8}";;
    (*) printf '%s' "$1";;
  esac
}

# the payload of the last `<!-- findings-json: … -->` or `<!-- review-meta: … -->`
# line of a history file or section on stdin (docs/review-mechanics.md →
# Summary body format); nothing when the line is absent
marker_payload() { # <findings-json|review-meta>  < text
  grep -o "<!-- $1: .* -->" | tail -1 | sed -e "s/^<!-- $1: //" -e 's/ -->$//'
}

# a value as one URL path segment (a label name may hold `/`, `?` or `%`)
uri() { jq -rn --arg v "$1" '$v | @uri'; }

# GET with one silent retry, captured per attempt so a failed attempt's error
# body never reaches the caller -> body on stdout; rc 1 after two failed attempts
gh_get() { # <gh api args…>
  local out
  out="$(gh api "$@" 2>/dev/null)" && { printf '%s' "$out"; return 0; }
  sleep 1
  out="$(gh api "$@" 2>/dev/null)" && { printf '%s' "$out"; return 0; }
  return 1
}

# Every page of a GitHub list as one JSON array, each page read with gh_get:
# <endpoint> itself, then `&page=2`, `&page=3` … while the last page came back
# full. A page that is not an array, or a list past GH_PAGES_MAX pages, is no
# answer: rc 1 and nothing on stdout, never a list read in part.
GH_PAGES_MAX=20
gh_get_all() { # <endpoint with per_page=100>
  local page=1 body n all=""
  while [ "$page" -le "$GH_PAGES_MAX" ]; do
    if [ "$page" -eq 1 ]; then body="$(gh_get "$1")" || return 1
    else body="$(gh_get "$1&page=$page")" || return 1; fi
    n="$(printf '%s' "$body" | jq 'if type == "array" then length else -1 end' 2>/dev/null)"
    case "$n" in (''|-*) return 1;; esac
    all="$all$body"$'\n'
    [ "$n" -lt 100 ] && { printf '%s' "$all" | jq -sc 'add'; return; }
    page=$((page + 1))
  done
  return 1
}

# The remote marker dedup at one SHA (docs/review-mechanics.md → Review
# tracking state): the timestamp of the newest review carrying
# `<!-- <marker> headRefOid=<sha> -->`, else of the newest PR comment carrying
# it; empty when every page answered without it; `__api_error__` when a read
# had no answer — unknown, never absent. With a file, the reviews list is kept
# there as a `pr=<n>` line and the array, for a second scan of the same PR.
marker_reviewed_at() { # <owner/repo> <n> <marker> <sha> [<reviews file>]
  local m="<!-- $3 headRefOid=$4 -->" body ts err=0
  [ -z "${5:-}" ] || : > "$5" 2>/dev/null
  if body="$(gh_get_all "repos/$1/pulls/$2/reviews?per_page=100")"; then
    [ -z "${5:-}" ] || { printf 'pr=%s\n' "$2"; printf '%s' "$body"; } > "$5" 2>/dev/null
    ts="$(printf '%s' "$body" | jq -r --arg m "$m" \
      '[.[] | select(.body != null) | select(.body | contains($m)) | .submitted_at] | last // empty' 2>/dev/null)"
    [ -n "$ts" ] && { printf '%s' "$ts"; return 0; }
  else err=1; fi
  if body="$(gh_get_all "repos/$1/issues/$2/comments?per_page=100")"; then
    ts="$(printf '%s' "$body" | jq -r --arg m "$m" \
      '[.[] | select(.body | contains($m)) | .created_at] | last // empty' 2>/dev/null)"
    [ -n "$ts" ] && { printf '%s' "$ts"; return 0; }
  else err=1; fi
  [ "$err" -eq 1 ] && printf '__api_error__'
  return 0
}

# A checkout's `origin` as a `<host>/<owner>/<repo>` reference — https, ssh and
# scp forms, credentials dropped. The fallback for a missing definition_repo.
origin_ref() { # <checkout dir>
  git -C "$1" remote get-url origin 2>/dev/null \
    | sed -e 's#^git@\([^:]*\):#\1/#' -e 's#^[a-z]*://##' -e 's#^[^@/]*@##' -e 's#\.git$##'
}

# The files a review-mode run reads before acting (docs/runbook.md → Review
# run, step 2): the core per due key, the rare cases only when an entry needs
# them. A mention reply and a CI triage comment write outward prose, so they
# read review.md for its style rules and PR-context calls. A file the run needs
# later — a `carry`, a `closed_*` post, an on-demand ask — is read on that
# trigger, not here. preflight.sh applies it to the worklist, dispatch.sh to
# each worklist it cuts from one.
READ_SET_JQ='def read_set:
  (if ([.selfheals_due, .label_cleanups_due, .prunes_due, .status_resets_due] | map(length) | add) > 0
   then ["docs/review-bookkeeping.md"] else [] end) as $bookkeeping
  | if .housekeeping_only then
    $bookkeeping + (if (.artifacts_due | length) > 0 then ["docs/artifact.md"] else [] end)
  else
    (if [.reviews_due, .mentions_due, .ci_failures_due, .fixes_due] | any(length > 0) then ["docs/review.md"] else [] end)
    + (if (.reviews_due | length) > 0 then ["docs/finding-form.md", "docs/skills.md"] else [] end)
    + (if any(.reviews_due[]; .kind == "re-review") then ["docs/review-rereview.md"] else [] end)
    + (if any(.reviews_due[]; .urgent == true or .closed == true) or (.urgent_alerts_due | length) > 0
       then ["docs/review-urgent.md"] else [] end)
    + $bookkeeping
    + (if ((.reviews_due | length) > 0 or (.mentions_due | length) > 0)
          and ((.config.watch_rules // []) | length) > 0
       then ["docs/watches.md"] else [] end)
    + (if (.mentions_due | length) > 0 then ["docs/mentions.md"] else [] end)
    + (if (.ci_failures_due | length) > 0 then ["docs/ci-triage.md"] else [] end)
    + (if (.artifacts_due | length) > 0 then ["docs/artifact.md"] else [] end)
    + (if (.merges_due | length) > 0 then ["docs/auto-merge.md"] else [] end)
    + (if (.fixes_due | length) > 0 then ["docs/agent-fixes.md"] else [] end)
    + ["work/MEMORY.md", "work/LESSONS.md"]
  end;'

# Model-id matching, shared by the price table (lib/prices.sh) and the audit's
# session_models check. A configured name may carry a provider path
# (`claude/aws/claude-opus-5-5`) and a context suffix (`[1m]`); a recorded id
# may carry a platform prefix or suffix (`us.anthropic.claude-opus-5-5-v1:0`).
# After a name that ends in a digit, a dash plus one or two digits reads as a
# later version: `claude-opus-5` does not match `claude-opus-5-5`, `opus`
# matches both. Other suffix forms (`.1`, `50`, `4o`, `-20260401`) still match.
MODEL_JQ='
  def model_key: ascii_downcase | sub("^.*/"; "") | sub("\\[[^]]*\\]$"; "");
  def model_has($name): ($name | model_key) as $w | ascii_downcase as $m
    | ($m | index($w)) as $i
    | $w != "" and $i != null
      and (($w | test("[0-9]$") | not)
           or ($m[($i + ($w | length)):] | test("^-[0-9]{1,2}([^0-9]|$)") | not));
'
