#!/usr/bin/env bash
# Claude Code harness adapter — SessionEnd hook: one `tokens` event per run
# (registered by install.sh; adapter contract: docs/logging.md).
# Sums the per-message API usage of the session transcript and of its
# subagents' transcripts (`<session>/subagents/*.jsonl` beside it), deduped by
# message id, into: input / output / cache_read / cache_creation / msgs, then
# appends `subagents=<n>` and, when n > 0, the subagents' own share as
# `sub_tokens=in:…,out:…,cr:…,cw:…`. The run id is the session id, so the event
# joins 1:1 with the run's other events. Best-effort: a hard-crashed session
# never fires SessionEnd and simply has no tokens event.
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
# msg format is parsed by preflight.sh audit (TOKENS_WEEK capture) — keep in
# sync. The subagent fields come last and share no `<name>=` with the fields
# the capture reads.
SUM="$(cd "$(dirname "$0")" && pwd)/usage-sum.jq"
SUBS=()
for f in "${tp%.jsonl}"/subagents/*.jsonl; do [ -f "$f" ] && SUBS+=("$f"); done
all="$(jq -nR -f "$SUM" "$tp" ${SUBS[@]+"${SUBS[@]}"} 2>/dev/null)"
[ -n "$all" ] || exit 0
# the subagents' share is the total minus the main transcript, so a message
# both files carry counts once, on the main side
main=''
[ "${#SUBS[@]}" -gt 0 ] && main="$(jq -nR -f "$SUM" "$tp" 2>/dev/null)"
[ -n "$main" ] || main='{}'
msg="$(jq -rn --argjson a "$all" --argjson m "$main" --argjson n "${#SUBS[@]}" '
  "input=\($a.input) output=\($a.output) cache_read=\($a.cache_read) cache_creation=\($a.cache_creation) msgs=\($a.msgs) model=\($a.model // "unknown") subagents=\($n)"
  + (if $n > 0 then
       " sub_tokens=in:\($a.input - ($m.input // 0)),out:\($a.output - ($m.output // 0)),cr:\($a.cache_read - ($m.cache_read // 0)),cw:\($a.cache_creation - ($m.cache_creation // 0))"
     else "" end)' 2>/dev/null)"
[ -n "$msg" ] && logev info tokens "$msg"
exit 0
