#!/usr/bin/env bash
# Claude Code harness adapter — registers the adapter hooks in
# ~/.claude/settings.json (idempotent; contract: docs/logging.md → Harness
# adapters): log-tool-event.sh on PostToolUseFailure + PostToolUse,
# log-review-step.sh on PostToolUse (Bash|Task), log-session-tokens.sh on
# SessionEnd, enforce-review-completion.sh on Stop. It also keeps the
# auto-mode classifier rules for the agent's documented writes
# (autoMode.environment / autoMode.allow, entries tagged [code-guardian]).
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

# auto-mode classifier rules: the classifier blocks an issue on a repo other
# than the target and an upload of a local file unless it knows both are the
# agent's documented work (docs/logging.md → Harness adapters). The slugs come
# from work/CONFIG.md; the definition repo falls back to $HOME's origin, so
# Step 1b works before the config exists.
HOME_DIR="${HOME:-/home/agent}"
CONFIG="$HOME_DIR/work/CONFIG.md"
. "$ADAPTER_DIR/../../lib/common.sh"
DEF="$(cfg definition_repo)"
[ -n "$DEF" ] || DEF="$(origin_ref "$HOME_DIR")"
case "$DEF" in (github.com/*) DEF="${DEF#github.com/}";; esac
TARGET="$(cfg github_repo)"
AM_ENV="$(jq -nc --arg d "$DEF" --arg r "$TARGET" --arg h "$HOME_DIR" '[
  "[code-guardian] This is an unattended code review agent. It reviews pull requests on \(if $r == "" then "the github_repo of \($h)/work/CONFIG.md" else $r end)\(if $d == "" then "" else ", and its own definition repository is \($d)" end).",
  "[code-guardian] The DAM Artifact Library is a publish surface the operator configured. Its create_artifact_upload_url tool returns a presigned upload URL for one file."]')"
AM_ALLOW="$(jq -nc --arg d "$DEF" --arg h "$HOME_DIR" '
  (if $d == "" then [] else
    ["[code-guardian] Opening a tracking issue on \($d) with gh issue create: the weekly audit and the channel-refused rule file them there."] end)
  + ["[code-guardian] Uploading a file under \($h)/work/audit/ or \($h)/work/reviews/pr-artifacts/ with curl -X PUT --data-binary to the URL that create_artifact_upload_url returned in the same session."]')"
[ -n "$DEF" ] || echo "definition repo unresolved — tracking-issue rule left out; re-run once work/CONFIG.md has definition_repo"

if jq -e --arg c "$SCRIPT" --arg t "$TOKENS" --arg f "$FINISH" --arg s "$STEPS" \
      --argjson e "$AM_ENV" --argjson a "$AM_ALLOW" \
    '[(.autoMode.environment // [])[], (.autoMode.allow // [])[]
      | select(type == "string" and startswith("[code-guardian]"))] == ($e + $a)
     and ([.hooks.PostToolUseFailure[]?.hooks[]?, .hooks.PostToolUse[]?.hooks[]?]
      | map(select(.command == $c)) | length == 2)
     and ([.hooks.SessionEnd[]?.hooks[]?] | map(select(.command == $t)) | length == 1)
     and ([.hooks.Stop[]?.hooks[]?] | map(select(.command == $f)) | length == 1)
     and ([.hooks.PostToolUse[]?.hooks[]?] | map(select(.command == $s)) | length == 1)' \
    "$SETTINGS" >/dev/null 2>&1; then
  echo "hooks and auto-mode rules already installed ($SETTINGS)"
  exit 0
fi

tmp="$(mktemp)"
if jq --arg c "$SCRIPT" --arg t "$TOKENS" --arg f "$FINISH" --arg s "$STEPS" \
      --argjson e "$AM_ENV" --argjson a "$AM_ALLOW" '
    # own entries are replaced, the operator'"'"'s kept; a new list keeps the
    # built-in rules through "$defaults"
    def am($k; $new): .autoMode[$k] = (((.autoMode[$k] // ["$defaults"])
        | map(select(type != "string" or (startswith("[code-guardian]") | not)))) + $new);
    .autoMode //= {} | am("environment"; $e) | am("allow"; $a) |
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
  echo "hooks installed into $SETTINGS (PostToolUseFailure + PostToolUse -> $SCRIPT; PostToolUse Bash|Task -> $STEPS; SessionEnd -> $TOKENS; Stop -> $FINISH; [code-guardian] rules -> autoMode.environment + autoMode.allow)"
else
  rm -f "$tmp"
  echo "hook install did not complete — settings.json left unchanged"
fi
exit 0
