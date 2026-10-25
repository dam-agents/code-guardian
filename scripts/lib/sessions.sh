#!/usr/bin/env bash
# sessions.sh — this agent's own platform sessions (docs/sessions.md): one
# `list_sessions` read per process and the `send_session_message` signal,
# through lib/mcp.sh. Sourced by preflight.sh, review-pr.sh, dispatch.sh and
# monitor.sh after lib/common.sh; the caller sets SESS_ON=1 (the
# `session_awareness` key is not `disabled`) and may set SESS_CACHE, a file
# that keeps the one read for its subshells.
#
#   session_state <id>      `running` = a turn runs in it now, started inside
#                           SESSION_RUN_MAX_MIN or at an unknown time; `idle` =
#                           listed, no turn runs. rc 1 and nothing printed =
#                           unknown: no read, not listed, or running for longer
#                           than the window
#   sessions_running        one `<id>\t<start>\t<title>` line per session with a
#                           running turn; rc 1 = no read
#   session_start <id> <runStartedAt>
#                           the turn's start: runStartedAt, else the first event
#                           of the run with that id; empty when neither is known
#   session_signal <id> <text>
#                           queues one message into that session; rc 0 = queued
#
# Every unknown leaves the caller on its own rule from before this file: the
# log-based live-holder windows, the dispatch of every PR, no signal.

SESSION_RUN_MAX_MIN=180   # a turn longer than this is judged by the old rule
SESS_TIMEOUT_S="${SESS_TIMEOUT_S:-8}"
SESS_LIST_MAX=50          # the platform's own cap

# the {sessions:[…]} answer, or rc 1; a failed read is cached as a failure too,
# so one process asks once
sessions_read() {
  local out args
  [ "${SESS_ON:-0}" = 1 ] || return 1
  if [ -n "${SESS_CACHE:-}" ] && [ -s "$SESS_CACHE" ]; then
    jq -e '.sessions | type == "array"' "$SESS_CACHE" >/dev/null 2>&1 && cat "$SESS_CACHE" && return 0
    return 1
  fi
  declare -F mcp_call >/dev/null 2>&1 \
    || . "$(dirname "${BASH_SOURCE[0]}")/mcp.sh" 2>/dev/null || return 1
  args="$(mktemp "${TMPDIR:-/tmp}/cg-sessions.XXXXXX" 2>/dev/null)" || return 1
  printf '{"limit":%s}' "$SESS_LIST_MAX" > "$args"
  out="$(MCP_TIMEOUT_S="$SESS_TIMEOUT_S" mcp_call list_sessions "$args" 2>/dev/null)"
  rm -f "$args"
  if printf '%s' "$out" | jq -e '.sessions | type == "array"' >/dev/null 2>&1; then
    [ -n "${SESS_CACHE:-}" ] && printf '%s' "$out" > "$SESS_CACHE"
    printf '%s' "$out"; return 0
  fi
  [ -n "${SESS_CACHE:-}" ] && printf '{"read":"failed"}' > "$SESS_CACHE"
  return 1
}

# The platform leaves runStartedAt null for a turn it did not stamp; the run
# id is the session id, so the run's first logged event stands in for it.
session_start() { # <id> <runStartedAt>
  [ -n "${2:-}" ] && { printf '%s\n' "$2"; return 0; }
  declare -F events_jsonl >/dev/null 2>&1 || return 0
  grep -hF "\"run\":\"$1\"" "${LOG_DIR:-${WORK:-}/logs}"/events-*.jsonl 2>/dev/null | head -1 \
    | jq -r '.ts // empty' 2>/dev/null
}

session_state() { # <id>
  local list row cut start
  [ -n "${1:-}" ] || return 1
  list="$(sessions_read)" || return 1
  row="$(printf '%s' "$list" | jq -r --arg id "$1" '
    [ .sessions[] | select(.sessionId == $id) ] | first
    | if . == null then empty elif .running != true then "idle" else "running \(.runStartedAt // "")" end' 2>/dev/null)"
  case "$row" in
    (idle) echo idle; return 0;;
    (running*) ;;
    (*) return 1;;
  esac
  start="$(session_start "$1" "$(printf '%s' "${row#running}" | tr -d ' ')")"
  cut="$(epoch2iso $(( $(date -u +%s) - SESSION_RUN_MAX_MIN * 60 )))"
  [ -z "$start" ] || [ "${start:0:19}" \> "${cut:0:19}" ] || [ "${start:0:19}" = "${cut:0:19}" ] || return 1
  echo running
}

sessions_running() {
  local list id st title
  list="$(sessions_read)" || return 1
  printf '%s' "$list" | jq -r '.sessions[] | select(.running == true)
    | [.sessionId, (.runStartedAt // "-"), ((.title // "") | gsub("[\t\n]"; " "))] | @tsv' 2>/dev/null \
    | while IFS=$'\t' read -r id st title; do
        # `-` holds the place of a null start: read joins two tabs into one
        printf '%s\t%s\t%s\n' "$id" "$(session_start "$id" "${st#-}")" "$title"
      done
}

session_signal() { # <id> <text>
  local args rc
  [ "${SESS_ON:-0}" = 1 ] && [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 1
  declare -F mcp_call >/dev/null 2>&1 \
    || . "$(dirname "${BASH_SOURCE[0]}")/mcp.sh" 2>/dev/null || return 1
  args="$(mktemp "${TMPDIR:-/tmp}/cg-signal.XXXXXX" 2>/dev/null)" || return 1
  jq -nc --arg s "$1" --arg t "$2" '{sessionId: $s, text: $t}' > "$args" || { rm -f "$args"; return 1; }
  MCP_TIMEOUT_S="$SESS_TIMEOUT_S" mcp_call send_session_message "$args" >/dev/null 2>&1; rc=$?
  rm -f "$args"
  return "$rc"
}
