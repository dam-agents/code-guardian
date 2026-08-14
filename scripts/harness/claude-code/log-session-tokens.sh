#!/usr/bin/env bash
# Claude Code harness adapter — SessionEnd hook: one `tokens` event per run
# (registered by install.sh; adapter contract: docs/logging.md).
# Sums the session transcript's per-message API usage (deduped by message id)
# into: input / output / cache_read / cache_creation / msgs. The run id is the
# session id, so the event joins 1:1 with the run's other events. Best-effort:
# a hard-crashed session never fires SessionEnd and simply has no tokens event.
# No-op unless work/CONFIG.md exists (same deployed-instance guard as
# log-tool-event.sh). Never blocks the agent: always exits 0.
set -u
INPUT="$(cat 2>/dev/null || true)"
[ -z "$INPUT" ] && exit 0
# resolve shimmed tools before the jq guard and the first jq call (this hook
# fires per tool call, so the shim tax dominates it) — ../../lib/toolpath.sh
. "$(cd "$(dirname "$0")/../.." && pwd)/lib/toolpath.sh" 2>/dev/null || true
command -v jq >/dev/null 2>&1 || exit 0

sid="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
tp="$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)"
{ [ -n "$tp" ] && [ -f "$tp" ]; } || exit 0
[ -n "$sid" ] && export LOG_RUN_ID="$sid"
. "$(cd "$(dirname "$0")/../.." && pwd)/log.sh"
[ -f "$LOG_WORK/CONFIG.md" ] || exit 0

# summation = the shared usage-sum.jq (also feeds the benchmark's snapshots);
# msg format is parsed by preflight.sh audit (TOKENS_WEEK capture) — keep in sync
msg="$(jq -nR -f "$(cd "$(dirname "$0")" && pwd)/usage-sum.jq" "$tp" 2>/dev/null \
  | jq -r '"input=\(.input) output=\(.output) cache_read=\(.cache_read) cache_creation=\(.cache_creation) msgs=\(.msgs)"' 2>/dev/null)"
[ -n "$msg" ] && logev info tokens "$msg"
exit 0
