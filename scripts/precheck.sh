#!/usr/bin/env bash
# precheck.sh — the schedule gate: decides whether a run starts at all.
#
# The platform runs this before it starts the agent (a schedule's `precheck`
# field) and reads the exit code: 0 starts the session, 1 skips the occurrence
# with no model call at all, and anything else — a crash, or the two-minute
# timeout — means the gate itself broke, so the session starts anyway. Whatever
# the gate prints on stdout is appended to the task prompt.
#
#   precheck.sh <review|shepherd|benchmark|survey>   # the mode is required
#
# It runs `preflight.sh <mode>` ONCE, keeps the worklist on disk, and prints the
# path plus the summary the run starts from:
#
#   nothing_to_do -> exit 1. HEARTBEAT.log and the structured log already carry
#                    the tick, so an idle heartbeat costs zero tokens.
#   work          -> exit 0, `worklist: <path>` + the non-empty keys and logs.
#   no JSON       -> exit 2 with the reason, preflight's exit code and the tail
#                    of its stderr: the session starts and does the equivalent
#                    work manually (docs/runbook.md).
#   error         -> exit 2 with preflight's `error`: it could not decide (no
#                    target repo, no answer from the API), which is a broken
#                    gate, never an idle tick.
#
# preflight is never run twice for one fire. Its bookkeeping is one-shot — the
# `done -> awaiting_label` flip and the once-per-UTC-day stall-alert claim are
# consumed by this pass — so the run reads the file named here instead of
# recomputing the decisions.
#
# `audit` has no gate: preflight's audit mode always reports work, so the weekly
# audit keeps the in-session entry command (docs/runbook.md → **The schedule
# gate**).

set -u
export LC_ALL=C

MODE="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TMP="${TMPDIR:-/tmp}"

LOG_JOB="$MODE"
# stdout is the task prompt (and an idle fire must print nothing at all), so
# every command below it writes to a file, a variable or /dev/null
if ! . "$SCRIPT_DIR/log.sh" >/dev/null 2>&1; then
  logev() { :; }; log_redact() { printf '%s' "$1"; }
fi

case "$MODE" in
  review|shepherd|benchmark|survey) ;;
  audit)
    printf 'precheck: audit is not gated — its worklist always carries work. Run `bash "$HOME/scripts/preflight.sh" audit` in the session.\n'
    exit 2;;
  '')
    printf 'precheck: no mode given (use review|shepherd|benchmark|survey). The schedule gate names its mode — docs/runbook.md → **The schedule gate**.\n'
    exit 2;;
  *)
    printf 'precheck: unknown mode "%s" (use review|shepherd|benchmark|survey).\n' "$MODE"
    exit 2;;
esac

# The scratch of a gated fire, bounded here rather than by the session: a
# skipped fire has no session to clean up after it, and a gate that the
# platform stops at its two-minute limit never reaches preflight's own `rm -f`.
# All these patterns are short-lived, so the 3-hour window takes only dead files.
find "$TMP" -maxdepth 1 \( -name 'cg-worklist-*.json' -o -name 'cg-files.*' \
  -o -name 'cg-mentions-*' -o -name 'cg-precheck-err-*' -o -name 'cg-open-err.*' \) \
  -mmin +180 -delete >/dev/null 2>&1 || true

# A gate runs outside a session, so no transcript holds why it broke: keep
# preflight's stderr and log it with the exit code. The text reaches the task
# prompt, so it passes the same credential masking as a log line (log.sh ->
# log_redact), and a scratch file that cannot be created costs the cause, never
# the pass.
ERR="$TMP/cg-precheck-err-$$.log"
WHY=""
if ( umask 077; : > "$ERR" ) 2>/dev/null; then
  JSON="$(bash "$SCRIPT_DIR/preflight.sh" "$MODE" 2>"$ERR")"; PRE_RC=$?
  WHY="$(log_redact "$(tail -c 400 "$ERR" 2>/dev/null | tr '\n' ' ')")"
  rm -f "$ERR" 2>/dev/null || true
else
  JSON="$(bash "$SCRIPT_DIR/preflight.sh" "$MODE" 2>/dev/null)"; PRE_RC=$?
fi

if ! printf '%s' "$JSON" | jq -e 'type == "object" and has("nothing_to_do")' >/dev/null 2>&1; then
  logev error precheck "$MODE gate: preflight printed no worklist (exit $PRE_RC) — the run starts and does the work manually${WHY:+ — stderr: $WHY}"
  printf 'precheck (%s): scripts/preflight.sh printed no JSON worklist (exit %s)%s. Read docs/runbook.md and do the equivalent work manually — never silently skip a heartbeat.\n' \
    "$MODE" "$PRE_RC" "${WHY:+ — stderr: $WHY}"
  exit 2
fi

PRE_ERR="$(printf '%s' "$JSON" | jq -r '.error // empty | tostring')"
if [ -n "$PRE_ERR" ]; then
  PRE_ERR="$(log_redact "$(printf '%s' "$PRE_ERR" | cut -c1-400)")"
  logev error precheck "$MODE gate: preflight could not decide (exit $PRE_RC) — the run starts and does the work manually — $PRE_ERR"
  printf 'precheck (%s): scripts/preflight.sh could not decide (exit %s): %s. Read docs/runbook.md and do the equivalent work manually — never silently skip a heartbeat.\n' \
    "$MODE" "$PRE_RC" "$PRE_ERR"
  exit 2
fi

if [ "$(printf '%s' "$JSON" | jq -r '.nothing_to_do')" = "true" ]; then
  logev info precheck "$MODE gate: nothing to do, no session started — $(printf '%s' "$JSON" | jq -r '[.logs[]?] | join("; ")' | cut -c1-300)"
  exit 1
fi

# The worklist carries the resolved config (roster ids, hosts, markers) and the
# per-PR inventories, and /tmp is shared: the file is this instance's to read.
OUT="$TMP/cg-worklist-$MODE-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"
( umask 077; : > "$OUT" ) 2>/dev/null || true
if ! printf '%s\n' "$JSON" > "$OUT" 2>/dev/null; then
  logev error precheck "$MODE gate: the worklist file could not be written — the run recomputes it"
  printf 'precheck (%s): work is due, but the worklist file could not be written. Run `bash "$HOME/scripts/preflight.sh" %s` yourself. One-shot bookkeeping of the first pass (the awaiting_label flip, the daily stall-alert claim) is already spent, so a stall alert may be missing from the second worklist.\n' "$MODE" "$MODE"
  exit 0
fi

# The non-empty work keys, so the prompt says why the run fired without the
# whole worklist travelling in it (a review worklist carries per-PR inventories
# and reaches megabytes).
WHAT="$(printf '%s' "$JSON" | jq -r '
  [ to_entries[]
    | select(.key | endswith("_due"))
    | select((.value | type) == "array" and (.value | length) > 0)
    | "\(.key)=\((.value | length))"
      + ( [ .value[] | .number? // empty ] | if length > 0 then " (#" + (map(tostring) | join(", #")) + ")" else "" end ) ]
  + ( if (.benchmark_due | type) == "object" then [ "benchmark_due=" + (.benchmark_due.action // "?") ] else [] end )
  + ( if (.survey_due | type) == "object" then [ "survey_due=" + (.survey_due.path // "?") ] else [] end )
  + ( if has("stall_alert") then [ "stall_alert=" + (.stall_alert.count | tostring) ] else [] end )
  | join(", ")')"

logev info precheck "$MODE gate: work due — $WHAT"

printf 'worklist: %s\n' "$OUT"
printf 'mode=%s, due: %s\n' "$MODE" "${WHAT:-see the worklist}"
printf '%s' "$JSON" | jq -r '.logs[]? | "- " + .'
printf 'The worklist above is already computed. Read the file, do not run preflight.sh again this run.\n'
exit 0
