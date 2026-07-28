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
SCRIPT="$(cd "$(dirname "$0")" && pwd)/log-tool-event.sh"
chmod +x "$SCRIPT" "$(dirname "$SCRIPT")/../../log.sh" 2>/dev/null || true

mkdir -p "$(dirname "$SETTINGS")"
[ -s "$SETTINGS" ] || echo '{}' > "$SETTINGS"

if jq -e --arg c "$SCRIPT" \
    '[.hooks.PostToolUseFailure[]?.hooks[]?, .hooks.PostToolUse[]?.hooks[]?]
     | map(select(.command == $c)) | length == 2' "$SETTINGS" >/dev/null 2>&1; then
  echo "hooks already installed ($SETTINGS)"
  exit 0
fi

tmp="$(mktemp)"
if jq --arg c "$SCRIPT" '
    .hooks //= {} |
    .hooks.PostToolUseFailure = ([.hooks.PostToolUseFailure[]?
        | select([.hooks[]?.command] | index($c) | not)]
      + [{matcher:"*", hooks:[{type:"command", command:$c, timeout:15}]}]) |
    .hooks.PostToolUse = ([.hooks.PostToolUse[]?
        | select([.hooks[]?.command] | index($c) | not)]
      + [{matcher:"Bash|mcp__.*", hooks:[{type:"command", command:$c, timeout:15}]}])
  ' "$SETTINGS" > "$tmp"; then
  mv "$tmp" "$SETTINGS"
  echo "hooks installed into $SETTINGS (PostToolUseFailure + PostToolUse -> $SCRIPT)"
else
  rm -f "$tmp"
  echo "hook install did not complete — settings.json left unchanged"
fi
exit 0
