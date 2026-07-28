#!/usr/bin/env bash
# Claude Code harness adapter — SessionEnd hook: one `tokens` event per run
# (registered by install.sh; adapter contract: docs/logging.md).
# Sums the session transcript's per-message API usage (deduped by message id)
# into: input / output / cache_read / cache_creation / msgs. The run id is the
# session id, so the event joins 1:1 with the run's other events. Best-effort:
# a hard-crashed session never fires SessionEnd and simply has no tokens event.
# Never blocks the agent: always exits 0.
set -u
INPUT="$(cat 2>/dev/null || true)"
[ -z "$INPUT" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

sid="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
tp="$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)"
{ [ -n "$tp" ] && [ -f "$tp" ]; } || exit 0
[ -n "$sid" ] && export LOG_RUN_ID="$sid"
. "$(cd "$(dirname "$0")/../.." && pwd)/log.sh"

msg="$(jq -c -R 'fromjson? // empty' "$tp" 2>/dev/null | jq -rs '
  [.[] | select(.message.usage) | {id: (.message.id // .uuid), u: .message.usage}]
  | unique_by(.id)
  | "input=\([.[].u.input_tokens // 0] | add // 0)"
    + " output=\([.[].u.output_tokens // 0] | add // 0)"
    + " cache_read=\([.[].u.cache_read_input_tokens // 0] | add // 0)"
    + " cache_creation=\([.[].u.cache_creation_input_tokens // 0] | add // 0)"
    + " msgs=\(length)"' 2>/dev/null)"
[ -n "$msg" ] && logev info tokens "$msg"
exit 0
