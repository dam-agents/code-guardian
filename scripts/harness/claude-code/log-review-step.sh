#!/usr/bin/env bash
# Claude Code harness adapter — PostToolUse hook: derive `review_step`
# milestones from the tool calls that *perform* them, instead of trusting the
# agent to log each one (registered by install.sh; contract: docs/logging.md →
# Harness adapters, steps: docs/review.md → Progress logging).
#
# Why this exists: the manual `logev review_step` calls of docs/review.md are
# written by the agent, so a turn that ends mid-pipeline loses exactly the
# events that would have pinned where it stopped — the log said "stalled after
# doc-drift" when the real story was "three more skills ran, unlogged". These
# events are the only stall diagnostic, so they may not depend on the agent
# remembering to emit them.
#
# Derivation is evidence-based and idempotent: each step is emitted at most
# once per (PR, step) per run, keyed on a /tmp marker dir, and only from a tool
# call that already succeeded. Steps the harness cannot observe (`locked`,
# `done`, `aborted <reason>`) stay the agent's duty — the row write is a file
# edit whose PR and verdict are not recoverable from the payload.
#
# Never blocks the agent and never fails a run: all error paths exit 0.
set -u
INPUT="$(cat 2>/dev/null || true)"
[ -z "$INPUT" ] && exit 0
# resolve shimmed tools before the jq guard and the first jq call (this hook
# fires per tool call, so the shim tax dominates it) — ../../lib/toolpath.sh
. "$(cd "$(dirname "$0")/../.." && pwd)/lib/toolpath.sh" 2>/dev/null || true
command -v jq >/dev/null 2>&1 || exit 0

evt="$(printf '%s' "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)"
[ "$evt" = "PostToolUse" ] || exit 0
sid="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
[ -n "$sid" ] || exit 0
export LOG_RUN_ID="$sid"
. "$(cd "$(dirname "$0")/../.." && pwd)/log.sh"
[ -f "$LOG_WORK/CONFIG.md" ] || exit 0   # not a deployed instance

tool="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)"

# emit <pr> <step> — once per (run, pr, step); the marker dir is ephemeral, so
# a fresh session re-emits legitimately
emit() { # <pr> <step-for-msg> <marker-key>
  local pr="$1" step="$2" key="$3" d="/tmp/.cg-steps-$sid"
  mkdir -p "$d" 2>/dev/null || return 0
  # mkdir is the atomic test-and-set: concurrent hook invocations can't double-log
  mkdir "$d/$pr-$key" 2>/dev/null || return 0
  LOG_JOB=review logev info review_step "PR #$pr $step"
}

case "$tool" in
  (Task)
    # a review skill runs as a subagent — the only trace of it in the payload.
    # Skill name and target PR both come from the prompt/description text.
    txt="$(printf '%s' "$INPUT" \
      | jq -r '[.tool_input.prompt, .tool_input.description, .tool_input.subagent_type]
               | map(select(type=="string")) | join(" ")' 2>/dev/null | tr '\n' ' ')"
    pr="$(printf '%s' "$txt" | grep -oE '(PR #|pulls/|review-pr-)[0-9]{1,7}' \
          | grep -oE '[0-9]{1,7}' | head -1)"
    [ -n "$pr" ] || exit 0
    # Skill names come from work/CONFIG.md — the `## Review skills` table plus
    # the artifact skill — never a hard-coded list: each instance configures its
    # own set, and a name missing here silently loses that skill's step.
    skills="$(sed -n '/^## Review skills$/,${ /^## Review skills$/d; /^## /q; p; }' \
                "$LOG_WORK/CONFIG.md" 2>/dev/null | grep -E '^\|' \
              | cut -d'|' -f2 | tr -d '[:blank:]' | grep -vE '^(skill|[-:]*)$')"
    art="$(sed -n 's/^- artifact_skill:[[:space:]]*//p' "$LOG_WORK/CONFIG.md" 2>/dev/null \
           | head -1 | sed -e 's/[[:space:]]*#.*$//' -e 's/@.*$//' -e 's/[[:space:]]*$//')"
    case "$art" in (none) art="";; esac
    for s in $skills $art; do        # unquoted: empty values expand to no word
      case "$txt" in (*"$s"*) emit "$pr" "skill:$s done" "skill-$s"; exit 0;; esac
    done
    ;;
  (Bash)
    cmd="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null | tr '\n' ' ')"
    [ -n "$cmd" ] || exit 0
    # posted <verdict> — the review POST itself. Only a create call counts:
    # `--method GET`/`gh api` reads of the same path are dedup checks, not posts.
    case "$cmd" in
      (*pulls/*/reviews*)
        case "$cmd" in
          (*--method\ GET*|*-X\ GET*) ;;
          (*-X\ POST*|*--method\ POST*|*-f\ event=*|*--field\ event=*|*--input*)
            pr="$(printf '%s' "$cmd" | grep -oE 'pulls/[0-9]{1,7}/reviews' | grep -oE '[0-9]{1,7}' | head -1)"
            # The verdict comes from the API's own answer first. Reading it out
            # of the command text couples this hook to how the request happens
            # to be phrased, and docs/review.md posts with `--input <payload>`,
            # which carries no `event=` at all — that is how `posted UNKNOWN`
            # got logged (work/LESSONS.md §11).
            v="$(printf '%s' "$INPUT" \
              | jq -r '.tool_response | if type=="string" then . else (.stdout // tojson) end' 2>/dev/null \
              | grep -oE '"state"[[:space:]]*:[[:space:]]*"(APPROVED|CHANGES_REQUESTED|COMMENTED)"' \
              | head -1 | grep -oE 'APPROVED|CHANGES_REQUESTED|COMMENTED')"
            case "$v" in
              (APPROVED)          v=APPROVE;;
              (CHANGES_REQUESTED) v=REQUEST_CHANGES;;
              (COMMENTED)         v=COMMENT;;
            esac
            # fall back to the payload file the command names, then to the
            # command text itself
            if [ -z "$v" ]; then
              pf="$(printf '%s' "$cmd" | sed -nE 's/.*--input[= ]+"?([^" ]+)"?.*/\1/p' | head -1)"
              [ -n "$pf" ] && v="$(jq -r '.event // empty' "$pf" 2>/dev/null)"
            fi
            [ -n "$v" ] || v="$(printf '%s' "$cmd" | grep -oE 'event=(APPROVE|COMMENT|REQUEST_CHANGES)' | head -1 | cut -d= -f2)"
            [ -n "$pr" ] && emit "$pr" "posted ${v:-UNKNOWN}" "posted"
            ;;
        esac
        ;;
    esac
    # cloned — the PR working dir appears; `git clone` into /tmp/review-pr-<n>
    case "$cmd" in
      (*git\ clone*review-pr-*)
        pr="$(printf '%s' "$cmd" | grep -oE 'review-pr-[0-9]{1,7}' | grep -oE '[0-9]{1,7}' | head -1)"
        [ -n "$pr" ] && emit "$pr" "cloned" "cloned"
        ;;
    esac
    ;;
esac
exit 0
