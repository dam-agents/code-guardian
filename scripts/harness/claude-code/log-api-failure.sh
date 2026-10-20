#!/usr/bin/env bash
# Claude Code harness adapter — hook target for StopFailure (registered by
# install.sh; adapter contract: docs/logging.md → Harness adapters). The
# harness fires it when a turn ends on an API error its own retries did not
# clear. Reads the hook JSON from stdin and writes one unified-log event:
#
#   level=error, event=api_failure, msg="<error>: <error_details>"
#
# <error> is the harness's class, one of docs/monitor.md → The `api_failure`
# classes (the pi adapter maps onto the same list). The monitor turns
# a cluster of them into the model-unavailable alert (docs/monitor.md).
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

err="$(printf '%s' "$INPUT" | jq -j '.error // "unknown"' 2>/dev/null | tr -c 'a-z_' '_' | cut -c1-40)"
det="$(printf '%s' "$INPUT" | jq -j '.error_details // .last_assistant_message // ""
  | if type == "string" then . else tojson end' 2>/dev/null | tr '\n' ' ' | cut -c1-300)"

logev error api_failure "${err:-unknown}: ${det:-no detail}"
exit 0
