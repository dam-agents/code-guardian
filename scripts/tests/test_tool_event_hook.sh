#!/usr/bin/env bash
# PostToolUseFailure hook (log-tool-event.sh): real failures are error
# tool_failure events; read-only inspect commands with a non-zero exit are
# info tool_use events (docs/logging.md → Harness adapters).
. "$(dirname "$0")/helpers.sh"

HOOK="$REPO_ROOT/scripts/harness/claude-code/log-tool-event.sh"

run_failure() { # <command>
  jq -nc --arg c "$1" \
    '{hook_event_name:"PostToolUseFailure", session_id:"s-hook", tool_name:"Bash",
      tool_input:{command:$c}, error:"exit status 1"}' \
    | WORK_DIR="$WORK" bash "$HOOK" >/dev/null 2>&1
}
events() { jq -r "select(.event==\"$1\") | .msg" "$EVENTS" 2>/dev/null | grep -c -- "$2" || true; }

new_case tool_event_levels
base_config
mkdir -p "$WORK/logs"
EVENTS="$WORK/logs/events-$(date -u +%Y-%m-%d).jsonl"
: > "$EVENTS"
run_failure 'grep -q marker work/reviews/pr-7.md'
run_failure 'gh api repos/acme/widgets/pulls/7/reviews -X POST'
if [ "$(events tool_use 'grep -q marker')" -eq 1 ] && [ "$(events tool_failure 'grep')" -eq 0 ]; then
  printf 'ok   %s: no-match grep logged as info tool_use, not error\n' "$CASE"
else
  printf 'FAIL %s: grep exit-1 not downgraded\n' "$CASE"; FAILED=1
fi
if [ "$(events tool_failure 'gh api')" -eq 1 ]; then
  printf 'ok   %s: real failure still an error tool_failure\n' "$CASE"
else
  printf 'FAIL %s: gh failure lost its error event\n' "$CASE"; FAILED=1
fi

finish
