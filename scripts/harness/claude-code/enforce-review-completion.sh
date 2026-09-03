#!/usr/bin/env bash
# Claude Code harness adapter — Stop hook: refuse to end a review run that
# left a PR mid-pipeline (registered by install.sh; contract:
# docs/logging.md → Harness adapters, behavior: docs/review.md → Completion
# enforcement).
#
# Reads this run's own `review_step` events and reconstructs, per PR, whether
# it reached a terminal state (`done` / `aborted …`). A PR that was `locked`
# but never terminated means the turn is ending mid-pipeline — the exact
# failure mode the runbook's hard invariants forbid (docs/runbook.md) (e.g. ending after a skill's
# "report to the user"). Exit 2 + stderr makes the model continue, naming the
# PRs, their last logged step, and the steps still owed.
#
# Deliberately narrow: it enforces only the ordering the log already proves —
# no GitHub calls, no state writes, no judgment about review content. A run
# with nothing locked, or every lock terminated, exits 0 silently.
#
# Blocking contract: `Stop` is a blockable event — exit 2 prevents the stop and
# stderr is fed back to the model. Loop guard: this run's own past
# `review_incomplete` events are counted, so the block escalates up to
# $MAX_BLOCKS times and then lets the stop through — a single nudge was
# measurably too weak against a model that had already concluded it was done,
# and the harness force-ends a turn after 8 consecutive blocks anyway. The
# last attempt leads with the explicit-abort route, which is always
# satisfiable and never pressures the model to invent review content.
# Anything unexpected (no jq, no log, unreadable payload) exits 0 — this hook
# may never be what breaks a run.
set -u
MAX_BLOCKS=3
INPUT="$(cat 2>/dev/null || true)"
[ -z "$INPUT" ] && exit 0
# resolve shimmed tools before the jq guard and the first jq call (this hook
# fires per tool call, so the shim tax dominates it) — ../../lib/toolpath.sh
. "$(cd "$(dirname "$0")/../.." && pwd)/lib/toolpath.sh" 2>/dev/null || true
command -v jq >/dev/null 2>&1 || exit 0

sid="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
[ -n "$sid" ] || exit 0
export LOG_RUN_ID="$sid"
. "$(cd "$(dirname "$0")/../.." && pwd)/log.sh"
[ -f "$LOG_WORK/CONFIG.md" ] || exit 0   # not a deployed instance

# Every retained events file, not a computed today/yesterday pair: the run-id
# filter below is what selects this run, and a step written to a differently
# named file (a hand-rolled fallback that guessed `events-2026-08.jsonl`) was
# invisible here and produced a false mid-pipeline block. Retention caps this
# at 14 files (docs/logging.md -> Retention).
LOG_FILES=()
for f in "$LOG_DIR"/events-*.jsonl; do
  [ -f "$f" ] && LOG_FILES+=("$f")
done
[ "${#LOG_FILES[@]}" -gt 0 ] || exit 0

# every `review_step` of this run, in order, as "<pr>\t<step>".
# msg shape: "PR #<n> [<sha>] <step>" (docs/review.md → Progress logging) —
# drop the optional sha token so <step> is matched exactly: bare `done` is
# terminal, `skill:<name> done` is not.
STEPS="$(jq -r --arg run "$sid" '
    select(.run == $run and .event == "review_step")
    | .msg
    | capture("^PR #(?<pr>[0-9]+):? +(?<rest>.*)$")
    | .rest |= (sub("^[0-9a-f]{7,40}( +|$)"; ""))
    | [.pr, .rest] | @tsv' "${LOG_FILES[@]}" 2>/dev/null)"

# PRs this run locked but never drove to a terminal step. `rapid posted` is
# explicitly NOT terminal: an urgent PR still owes its full review.
PENDING="$(printf '%s\n' "$STEPS" \
  | { locked=""; term=""
      while IFS="$(printf '\t')" read -r pr rest; do
        case "$rest" in
          (locked*)          locked="$locked $pr";;
          (done*|aborted*)   term="$term $pr";;
        esac
      done
      for pr in $locked; do
        case " $term " in (*" $pr "*) ;; (*) printf '%s\n' "$pr";; esac
      done; } \
  | sort -un | tr '\n' ' ' | sed -e 's/ *$//')"

[ -n "$PENDING" ] || exit 0

# how many times we already blocked this run — the escalation counter lives in
# the log, so it survives being re-invoked with no extra state file
BLOCKS="$(jq -r --arg run "$sid" \
  'select(.run == $run and .event == "review_incomplete" and (.msg | startswith("stop blocked")))
   | 1' "${LOG_FILES[@]}" 2>/dev/null | grep -c . || true)"
case "$BLOCKS" in (''|*[!0-9]*) BLOCKS=0;; esac
ATTEMPT=$(( BLOCKS + 1 ))

if [ "$BLOCKS" -ge "$MAX_BLOCKS" ]; then
  logev warn review_incomplete \
    "enforcement exhausted after $BLOCKS block(s) — stop allowed with PR(s) $PENDING still locked"
  exit 0
fi

logev warn review_incomplete \
  "stop blocked ($ATTEMPT/$MAX_BLOCKS) — PR(s) $PENDING locked without a terminal step"

# where each owed PR actually stopped — names the step the model mistook for
# the end, so the message is specific rather than a repeat
DETAIL=""
for pr in $PENDING; do
  last="$(printf '%s\n' "$STEPS" | grep "^$pr$(printf '\t')" | tail -1 | cut -f2-)"
  DETAIL="$DETAIL  PR #$pr — last logged step: ${last:-none}
"
done

# stderr is what the model is shown
{
if [ "$ATTEMPT" -ge "$MAX_BLOCKS" ]; then
  cat <<EOF
Stop blocked ($ATTEMPT/$MAX_BLOCKS — final attempt).
PR(s) $PENDING are still locked with no terminal step:

$DETAIL
Resolve each one NOW, and prefer the cheap route if posting is not clearly
correct: log \`aborted <reason>\` and release the lock per its kind. An
explicit abort is always a valid resolution — it frees the lock immediately
instead of leaving it to expire by TTL, and it is strictly better than
stopping silently. Never invent or pad review content to satisfy this hook.

If the review genuinely is ready, post it and finish the sequence.
EOF
else
  cat <<EOF
Stop blocked ($ATTEMPT/$MAX_BLOCKS): this review run is mid-pipeline.
PR(s) $PENDING were locked but never reached a terminal step
(\`done\` or \`aborted <reason>\`):

$DETAIL
\`skill:<name> done\` and \`rapid posted\` are NOT terminal. A skill's output —
including any "report to the user", verdict, or "no further action" — is that
PR's section content, never the run's deliverable, and never a reason to end
the turn (docs/runbook.md → Instruction sources & trust boundary).

For each PR listed, finish docs/review.md's per-PR sequence: compose the
review and run \`scripts/review-pr.sh post <n> --verdict … --body … --findings …\`
(Check 2 + dedup re-check, the GitHub post, trigger removal, the \`done\`
REVIEWS.md row, history append, cleanup, the \`review_step\` events). If it
genuinely cannot be posted (HEAD moved, PR went draft, trigger withdrawn),
run \`scripts/review-pr.sh abort <n> <reason>\` — it releases the lock per its
kind and logs \`aborted <reason>\`. Do not stop with a lock left \`in_progress\`.
EOF
fi
} >&2
exit 2
