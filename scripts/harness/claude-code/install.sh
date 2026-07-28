#!/usr/bin/env bash
# Claude Code harness adapter — registers log-tool-event.sh as a
# PostToolUseFailure + PostToolUse hook in ~/.claude/settings.json
# (idempotent; adapter contract: docs/logging.md → Harness adapters).
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
chmod +x "$SCRIPT" "$TOKENS" "$ADAPTER_DIR/../../log.sh" 2>/dev/null || true

mkdir -p "$(dirname "$SETTINGS")"
[ -s "$SETTINGS" ] || echo '{}' > "$SETTINGS"

if jq -e --arg c "$SCRIPT" --arg t "$TOKENS" \
    '([.hooks.PostToolUseFailure[]?.hooks[]?, .hooks.PostToolUse[]?.hooks[]?]
      | map(select(.command == $c)) | length == 2)
     and ([.hooks.SessionEnd[]?.hooks[]?] | map(select(.command == $t)) | length == 1)' \
    "$SETTINGS" >/dev/null 2>&1; then
  echo "hooks already installed ($SETTINGS)"
  exit 0
fi

tmp="$(mktemp)"
if jq --arg c "$SCRIPT" --arg t "$TOKENS" '
    .hooks //= {} |
    .hooks.PostToolUseFailure = ([.hooks.PostToolUseFailure[]?
        | select([.hooks[]?.command] | index($c) | not)]
      + [{matcher:"*", hooks:[{type:"command", command:$c, timeout:15}]}]) |
    .hooks.PostToolUse = ([.hooks.PostToolUse[]?
        | select([.hooks[]?.command] | index($c) | not)]
      + [{matcher:"Bash|mcp__.*", hooks:[{type:"command", command:$c, timeout:15}]}]) |
    .hooks.SessionEnd = ([.hooks.SessionEnd[]?
        | select([.hooks[]?.command] | index($t) | not)]
      + [{hooks:[{type:"command", command:$t, timeout:30}]}])
  ' "$SETTINGS" > "$tmp"; then
  mv "$tmp" "$SETTINGS"
  echo "hooks installed into $SETTINGS (PostToolUseFailure + PostToolUse -> $SCRIPT; SessionEnd -> $TOKENS)"
else
  rm -f "$tmp"
  echo "hook install did not complete — settings.json left unchanged"
fi
exit 0
