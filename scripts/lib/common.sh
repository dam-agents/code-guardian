#!/usr/bin/env bash
# common.sh — the helpers every script shares: the work/CONFIG.md reader
# (docs/config.md), repo references, time, the event log and history-marker
# reads, and a GitHub GET with retry. Set CONFIG before calling cfg or
# cfg_table; source this file before GH_HOST is re-exported, so DEFAULT_HOST
# keeps the ambient default and each reference resolves independently.

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

# Runs <command…> as the one writer of <file>, a state file several runs
# rewrite in place (work/REVIEWS.md): `mkdir` of `<file>.lock` is atomic, and a
# lock older than a minute is a dead writer's. One waiter at a time removes a
# dead lock — the one that holds `<file>.break.lock`, and only while the lock is
# still old. Every attempt counts: after ten seconds the command runs anyway,
# with a warn, so a review never stalls on the lock.
state_lock_old() { [ -n "$(find "$1" -maxdepth 0 -mmin +1 2>/dev/null)" ]; }
with_state_lock() { # <file> <command…>
  local f="$1" l="$1.lock" b="$1.break.lock" i=0 rc; shift
  until mkdir "$l" 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -gt 100 ]; then
      command -v logev >/dev/null 2>&1 && logev warn state_lock "${f##*/}: lock held for 10 s — written without it"
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
  "$@"; rc=$?
  rmdir "$l" 2>/dev/null
  return "$rc"
}

# every retained structured event (docs/logging.md) as one JSON object per
# line; `fromjson?` drops the partial line a concurrently writing session may
# leave. LOG_DIR comes from log.sh.
events_jsonl() { cat "$LOG_DIR"/events-*.jsonl 2>/dev/null | jq -c -R 'fromjson? // empty' 2>/dev/null; }

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
  if .housekeeping_only then ["docs/review-bookkeeping.md"] else
    (if [.reviews_due, .mentions_due, .ci_failures_due, .fixes_due] | any(length > 0) then ["docs/review.md"] else [] end)
    + (if (.reviews_due | length) > 0 then ["docs/finding-form.md", "docs/skills.md"] else [] end)
    + (if any(.reviews_due[]; .kind == "re-review") then ["docs/review-rereview.md"] else [] end)
    + (if any(.reviews_due[]; .urgent == true or .closed == true) or (.urgent_alerts_due | length) > 0
       then ["docs/review-urgent.md"] else [] end)
    + (if ([.selfheals_due, .label_cleanups_due, .prunes_due, .status_resets_due] | map(length) | add) > 0
          or .stall_alert != null
       then ["docs/review-bookkeeping.md"] else [] end)
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
