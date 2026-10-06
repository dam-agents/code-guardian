#!/usr/bin/env bash
# common.sh — the helpers every script shares: the work/CONFIG.md reader
# (docs/config.md), repo references, time and a GitHub GET with retry. Set
# CONFIG before calling cfg or cfg_table; source this file before GH_HOST is
# re-exported, so DEFAULT_HOST keeps the ambient default and each reference
# resolves independently.

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

# The `## Review skills` table as [{skill, source, trigger, section}]
# (docs/skills.md), header and separator rows dropped
skills_table_json() {
  cfg_table 'Review skills' | while IFS='|' read -r _ s src trig sec _rest; do
    s="$(trim "$s")"; case "$s" in (''|skill|-*|:*) continue;; esac
    jq -nc --arg s "$s" --arg src "$(trim "$src")" --arg t "$(trim "$trig")" --arg sec "$(trim "$sec")" \
      '{skill:$s, source:$src, trigger:$t, section:$sec}'
  done | jq -s .
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

# every retained structured event (docs/logging.md) as one JSON object per
# line; `fromjson?` drops the partial line a concurrently writing session may
# leave. LOG_DIR comes from log.sh.
events_jsonl() { cat "$LOG_DIR"/events-*.jsonl 2>/dev/null | jq -c -R 'fromjson? // empty' 2>/dev/null; }

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

# A checkout's `origin` as a `<host>/<owner>/<repo>` reference — https, ssh and
# scp forms, credentials dropped. The fallback for a missing definition_repo.
origin_ref() { # <checkout dir>
  git -C "$1" remote get-url origin 2>/dev/null \
    | sed -e 's#^git@\([^:]*\):#\1/#' -e 's#^[a-z]*://##' -e 's#^[^@/]*@##' -e 's#\.git$##'
}
