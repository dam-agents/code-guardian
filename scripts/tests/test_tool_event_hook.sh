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

# --- the classifier matches the basename of the command that set the status ---
# absolute paths are required inside review clones and calls are routinely
# prefixed `cd … &&`, so a prefix match could never fire on a real instance
new_case tool_event_inspect_shapes
base_config
mkdir -p "$WORK/logs"
EVENTS="$WORK/logs/events-$(date -u +%Y-%m-%d).jsonl"
: > "$EVENTS"

expect() { # <want: use|failure> <marker> <command>
  : > "$EVENTS"
  run_failure "$3"
  if [ "$(events "tool_$1" "$2")" -ge 1 ]; then
    printf 'ok   %s: %s -> tool_%s\n' "$CASE" "$2" "$1"
  else
    printf 'FAIL %s: %s not logged as tool_%s (got: %s)\n' \
      "$CASE" "$2" "$1" "$(jq -r '.event' "$EVENTS" | tr '\n' ' ')"; FAILED=1
  fi
}

expect use     'absolute-grep' '/usr/bin/grep -rn absolute-grep /home/agent/work'
expect use     'shimmed-rg'    '/usr/local/share/lazy-tools/rg -n shimmed-rg src'
expect use     'chained-grep'  'cd /home/agent/work && grep -n chained-grep MEMORY.md'
expect use     'pr-3498'       'cat CONFIG.md && cat MEMORY.md && ls reviews/pr-3498.md'
expect use     'quoted-alt'    "/usr/bin/grep -rnE 'quoted-alt|other' ."
expect failure 'npm'           'cd /tmp/review-pr-9 && npm install'
expect failure 'wc'            'grep -rn x . | wc -l'

# a chain's failing tail must survive the cmd cap, or the event cannot be attributed
: > "$EVENTS"
run_failure "cat A && cat B && $(printf 'echo %0.spadding-padding-padding-padding ' 1 2 3 4 5 6 7 8 9 10)&& ls /tmp/tail-marker-here"
assert_file_contains "$EVENTS" 'tail-marker-here' 'the failing tail of a long chain is still logged'

finish
