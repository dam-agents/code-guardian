#!/usr/bin/env bash
# Claude Code harness adapter — registers the adapter hooks in
# ~/.claude/settings.json (idempotent; contract: docs/logging.md → Harness
# adapters): log-tool-event.sh on PostToolUseFailure + PostToolUse,
# log-review-step.sh on PostToolUse (Bash|Task), log-session-tokens.sh on
# SessionEnd, enforce-review-completion.sh on Stop.
# On any other harness it prints a notice and exits 0 — the agent then logs
# tool failures manually per docs/logging.md. Newly registered hooks take
# effect from the next session.
set -u

if [ "${CLAUDECODE:-}" != "1" ]; then
  echo "not the Claude Code harness (CLAUDECODE != 1) — no hooks installed; manual tool-failure logging applies (docs/logging.md)"
  exit 0
fi
command -v jq >/dev/null 2>&1 || { echo "jq missing — cannot install hooks"; exit 0; }

SETTINGS="${HOME:-/home/agent}/.claude/settings.json"
ADAPTER_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$ADAPTER_DIR/log-tool-event.sh"
TOKENS="$ADAPTER_DIR/log-session-tokens.sh"
FINISH="$ADAPTER_DIR/enforce-review-completion.sh"
STEPS="$ADAPTER_DIR/log-review-step.sh"
chmod +x "$SCRIPT" "$TOKENS" "$FINISH" "$STEPS" "$ADAPTER_DIR/../../log.sh" 2>/dev/null || true

mkdir -p "$(dirname "$SETTINGS")"
[ -s "$SETTINGS" ] || echo '{}' > "$SETTINGS"

if jq -e --arg c "$SCRIPT" --arg t "$TOKENS" --arg f "$FINISH" --arg s "$STEPS" \
    '([.hooks.PostToolUseFailure[]?.hooks[]?, .hooks.PostToolUse[]?.hooks[]?]
      | map(select(.command == $c)) | length == 2)
     and ([.hooks.SessionEnd[]?.hooks[]?] | map(select(.command == $t)) | length == 1)
     and ([.hooks.Stop[]?.hooks[]?] | map(select(.command == $f)) | length == 1)
     and ([.hooks.PostToolUse[]?.hooks[]?] | map(select(.command == $s)) | length == 1)' \
    "$SETTINGS" >/dev/null 2>&1; then
  echo "hooks already installed ($SETTINGS)"
  exit 0
fi

tmp="$(mktemp)"
if jq --arg c "$SCRIPT" --arg t "$TOKENS" --arg f "$FINISH" --arg s "$STEPS" '
    .hooks //= {} |
    .hooks.PostToolUseFailure = ([.hooks.PostToolUseFailure[]?
        | select([.hooks[]?.command] | index($c) | not)]
      + [{matcher:"*", hooks:[{type:"command", command:$c, timeout:15}]}]) |
    .hooks.PostToolUse = ([.hooks.PostToolUse[]?
        | select([.hooks[]?.command] | index($c) | not)
        | select([.hooks[]?.command] | index($s) | not)]
      + [{matcher:"Bash|mcp__.*", hooks:[{type:"command", command:$c, timeout:15}]}]
      + [{matcher:"Bash|Task", hooks:[{type:"command", command:$s, timeout:15}]}]) |
    .hooks.SessionEnd = ([.hooks.SessionEnd[]?
        | select([.hooks[]?.command] | index($t) | not)]
      + [{hooks:[{type:"command", command:$t, timeout:30}]}]) |
    .hooks.Stop = ([.hooks.Stop[]?
        | select([.hooks[]?.command] | index($f) | not)]
      + [{hooks:[{type:"command", command:$f, timeout:15}]}])
  ' "$SETTINGS" > "$tmp"; then
  mv "$tmp" "$SETTINGS"
  echo "hooks installed into $SETTINGS (PostToolUseFailure + PostToolUse -> $SCRIPT; PostToolUse Bash|Task -> $STEPS; SessionEnd -> $TOKENS; Stop -> $FINISH)"
else
  rm -f "$tmp"
  echo "hook install did not complete — settings.json left unchanged"
fi
exit 0
