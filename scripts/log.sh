#!/usr/bin/env bash
# log.sh — harness-agnostic structured logging for code-guardian.
# Format home: docs/logging.md. Source this file, then:
#
#   logev <level> <event> <message>      # level: debug|info|warn|error
#
# One JSONL line per event in $WORK/logs/events-YYYY-MM-DD.jsonl:
#   {"ts":"…","run":"…","job":"…","level":"…","event":"…","msg":"…"}
#
#   run — LOG_RUN_ID env, else the harness session id, else start time + pid.
#   job — LOG_JOB env (review|shepherd|audit|…), default "session".
#
# `debug` lines are written only when work/CONFIG.md has `log_level: debug`.
# Logging must never break a run: every failure path is swallowed.

LOG_WORK="${WORK_DIR:-${HOME:-/home/agent}/work}"
LOG_DIR="$LOG_WORK/logs"
# resolve shimmed tools once (logev execs jq per event) — lib/toolpath.sh
[ -n "${TOOLPATH_CACHE:-}" ] \
  || . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/toolpath.sh" 2>/dev/null || true
LOG_RUN="${LOG_RUN_ID:-${CLAUDE_CODE_SESSION_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}}"
LOG_LEVEL="$(sed -n 's/^- log_level:[[:space:]]*//p' "$LOG_WORK/CONFIG.md" 2>/dev/null \
             | head -1 | sed -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//')"
LOG_LEVEL="${LOG_LEVEL:-info}"

# best-effort masking of well-known credential shapes before anything is
# written (invariant: no secrets in any log) — GitHub tokens, Slack tokens,
# bearer headers
log_redact() {
  printf '%s' "$1" | sed -E \
    -e 's/(ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]{8,}/\1_[redacted]/g' \
    -e 's/xox[a-z]-[A-Za-z0-9-]{8,}/xox-[redacted]/g' \
    -e 's|[Bb]earer +[A-Za-z0-9._~+/=-]{8,}|Bearer [redacted]|g' 2>/dev/null || printf '%s' "$1"
}

logev() {
  [ "$1" = "debug" ] && [ "$LOG_LEVEL" != "debug" ] && return 0
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ 2>/dev/null)"
  case "$ts" in (*N*|'') ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)";; esac
  mkdir -p "$LOG_DIR" 2>/dev/null || return 0
  jq -nc --arg ts "$ts" --arg run "$LOG_RUN" --arg job "${LOG_JOB:-session}" \
    --arg level "$1" --arg event "$2" --arg msg "$(log_redact "$3")" \
    '{ts:$ts, run:$run, job:$job, level:$level, event:$event, msg:$msg}' \
    >> "$LOG_DIR/events-$(date -u +%Y-%m-%d).jsonl" 2>/dev/null || true
}
