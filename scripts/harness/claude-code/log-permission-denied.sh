#!/usr/bin/env bash
# Claude Code harness adapter — hook target for PermissionDenied (registered by
# install.sh; adapter contract: docs/logging.md → Harness adapters). The
# harness fires it when the auto-mode classifier refuses a tool call. Reads the
# hook JSON from stdin and writes one unified-log event:
#
#   level=warn, event=classifier_block, msg="<tool> [<what>] — <reason>"
#
# <what> is the Bash command, or the subagent type and description of an Agent
# call, or the URL or path — capped, so a heredoc body never reaches the log.
# The monitor and the weekly audit count these (docs/monitor.md). Record only:
# the hook never asks the harness to retry the refused call.
#
# No-op unless a deployed instance's work/CONFIG.md exists. Always exits 0.
set -u
INPUT="$(cat 2>/dev/null || true)"
[ -z "$INPUT" ] && exit 0
. "$(cd "$(dirname "$0")/../.." && pwd)/lib/toolpath.sh" 2>/dev/null || true
command -v jq >/dev/null 2>&1 || exit 0

sid="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
[ -n "$sid" ] && export LOG_RUN_ID="$sid"
. "$(cd "$(dirname "$0")/../.." && pwd)/log.sh"
[ -f "$LOG_WORK/CONFIG.md" ] || exit 0

tool="$(printf '%s' "$INPUT" | jq -r '.tool_name // "unknown"' 2>/dev/null)"
what="$(printf '%s' "$INPUT" | jq -j '.tool_input
  | if type != "object" then ""
    elif .command then .command
    elif .subagent_type or .description then "\(.subagent_type // "default"): \(.description // "")"
    elif .url then .url
    elif .file_path then .file_path
    else (keys | join(",")) end' 2>/dev/null | tr '\n' ' ' | cut -c1-300)"
reason="$(printf '%s' "$INPUT" | jq -j '.reason // "no reason given"' 2>/dev/null | tr '\n' ' ' | cut -c1-300)"

logev warn classifier_block "$tool${what:+ [$what]} — $reason"
exit 0
