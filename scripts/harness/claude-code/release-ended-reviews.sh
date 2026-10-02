#!/usr/bin/env bash
# Claude Code harness adapter — SessionEnd hook: a session that ends with a PR
# still locked (an operator stop, a stop the Stop hook let through) releases it
# at once, instead of leaving it held for the quiet window (registered by
# install.sh; behavior: docs/review-mechanics.md → Ended holder).
# Lists the PRs this run logged `locked` on and hands each to
# `review-pr.sh abandon <n> --run <session> --ended`, which judges and acts:
# a PR the run already ended is `not_held`, a PR a later run locked is
# `superseded`. A hard-killed session never fires SessionEnd; the operator then
# runs `abandon` without `--ended`. No-op unless work/CONFIG.md exists. Never
# blocks the agent: always exits 0.
set -u
INPUT="$(cat 2>/dev/null || true)"
[ -z "$INPUT" ] && exit 0
. "$(cd "$(dirname "$0")/../.." && pwd)/lib/toolpath.sh" 2>/dev/null || true
command -v jq >/dev/null 2>&1 || exit 0

sid="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
[ -n "$sid" ] || exit 0
export LOG_RUN_ID="$sid"
SCRIPTS="$(cd "$(dirname "$0")/../.." && pwd)"
. "$SCRIPTS/log.sh"
[ -f "$LOG_WORK/CONFIG.md" ] || exit 0

LOG_FILES=()
for f in "$LOG_DIR"/events-*.jsonl; do [ -f "$f" ] && LOG_FILES+=("$f"); done
[ "${#LOG_FILES[@]}" -gt 0 ] || exit 0

PRS="$(jq -r --arg run "$sid" '
    select(.run == $run and .event == "review_step")
    | .msg | capture("^PR #(?<pr>[0-9]+):? +(?<rest>.*)$")
    | select(.rest | sub("^[0-9a-f]{7,40}( +|$)"; "") | test("^locked( |$)"))
    | .pr' "${LOG_FILES[@]}" 2>/dev/null | sort -un)"

for pr in $PRS; do
  res="$(bash "$SCRIPTS/review-pr.sh" abandon "$pr" --run "$sid" --ended \
           --reason "session ended mid-review" 2>/dev/null | jq -r '.outcome // empty' 2>/dev/null)"
  [ "$res" = abandoned ] && logev warn review_abort "PR #$pr: released at session end — the session ended with the PR locked"
done
exit 0
