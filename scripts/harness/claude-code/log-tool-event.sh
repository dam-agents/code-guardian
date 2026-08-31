#!/usr/bin/env bash
# Claude Code harness adapter — hook target for PostToolUseFailure and
# PostToolUse (registered by install.sh; adapter contract: docs/logging.md).
# Reads the hook JSON from stdin and writes unified-log events:
#
#   PostToolUseFailure -> level=error, event=tool_failure   (every tool)
#   PostToolUse        -> level=debug, event=tool_use       (external calls
#                         only: Bash gh/git/curl commands and mcp__ tools;
#                         written only under log_level: debug)
#
# No-op unless a deployed instance's work/CONFIG.md exists — the hook is
# registered user-globally, and this guard keeps it from logging unrelated
# sessions (e.g. a developer machine) into $HOME/work/logs.
# Never blocks the agent: always exits 0.
set -u
INPUT="$(cat 2>/dev/null || true)"
[ -z "$INPUT" ] && exit 0
# resolve shimmed tools before the jq guard and the first jq call (this hook
# fires per tool call, so the shim tax dominates it) — ../../lib/toolpath.sh
. "$(cd "$(dirname "$0")/../.." && pwd)/lib/toolpath.sh" 2>/dev/null || true
command -v jq >/dev/null 2>&1 || exit 0

evt="$(printf '%s' "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)"
sid="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
[ -n "$sid" ] && export LOG_RUN_ID="$sid"
. "$(cd "$(dirname "$0")/../.." && pwd)/log.sh"
[ -f "$LOG_WORK/CONFIG.md" ] || exit 0
# successful calls are debug-only — skip all parsing work at log_level: info
{ [ "$evt" = "PostToolUseFailure" ] || [ "$LOG_LEVEL" = "debug" ]; } || exit 0

tool="$(printf '%s' "$INPUT" | jq -r '.tool_name // "unknown"' 2>/dev/null)"
# failures keep more of the command than successes do: the element that failed
# is the LAST one of a `;`/`&&` chain, and a 200-char cap cut exactly the tail
# that says which tool failed and why (docs/logging.md -> tool_failure)
cmd_cap=200; [ "$evt" = "PostToolUseFailure" ] && cmd_cap=800
cmd="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // .tool_input.url // empty' 2>/dev/null \
      | tr '\n' ' ' | cut -c1-"$cmd_cap")"

# Read-only inspect commands answer "no match" with a non-zero exit — a result,
# not a failure. Match the BASENAME of the command that actually set the exit
# status, i.e. the last element of a `;`/`&&`/`||` chain: absolute paths are
# required inside review clones (work/LESSONS.md §1 — shimmed tools die there),
# and calls are routinely written as `cd … && …`, so a prefix match on the raw
# string could never fire on a real instance.
is_inspect() { # <command-string>
  local last base
  last="$1"
  # separators are matched with their trailing space so a quoted `a|b` inside a
  # grep pattern is not mistaken for a pipeline
  last="${last##*&& }"; last="${last##*|| }"; last="${last##*; }"; last="${last##*| }"
  last="${last#"${last%%[![:space:]]*}"}"                 # ltrim
  while :; do                                             # drop VAR=x prefixes
    case "$last" in ([A-Za-z_][A-Za-z_0-9]*=*\ *) last="${last#* }";; (*) break;; esac
  done
  base="${last%%[[:space:]]*}"; base="${base##*/}"
  case "$base" in
    (grep|egrep|fgrep|rg|ag|ls|find|fd|test|'['|command|stat|which|type) return 0;;
  esac
  return 1
}
resp() { printf '%s' "$INPUT" \
  | jq -r '.tool_response | if type=="string" then . else tojson end' 2>/dev/null \
  | tr '\n' ' ' | cut -c1-"$1"; }

if [ "$evt" = "PostToolUseFailure" ]; then
  # capture whatever the harness gave us: tool_response is often null on a
  # failure, so fall back through the common error/output fields, then to the
  # raw hook payload — a failure with no context is what makes stalls
  # undiagnosable (docs/logging.md → tool_failure). Wider cap than success.
  err="$(printf '%s' "$INPUT" | jq -r '
      [ (.tool_response | if .==null then empty
                          elif type=="string" then . else tojson end),
        .error, .message, .tool_response.error, .tool_response.stderr,
        .tool_response.stdout ]
      | map(select(. != null and . != "")) | .[0] // empty' 2>/dev/null \
    | tr '\n' ' ' | cut -c1-800)"
  [ -z "$err" ] && err="$(printf '%s' "$INPUT" | jq -c '{tool_input, tool_response}' 2>/dev/null | cut -c1-800)"
  if [ "$tool" = "Bash" ] && is_inspect "$cmd"; then
    logev info tool_use "$tool [$cmd] -> ${err:-non-zero exit}"
  else
    logev error tool_failure "$tool${cmd:+ [$cmd]}: ${err:-unknown error}"
  fi
else
  case "$tool:$cmd" in
    (Bash:gh\ *|Bash:*\ gh\ *|Bash:curl\ *|Bash:*\ curl\ *|Bash:git\ *|Bash:*\ git\ *)
      logev debug tool_use "$tool [$cmd] -> $(resp 160)";;
    (mcp__*:*)
      logev debug tool_use "$tool";;
  esac
fi
exit 0
