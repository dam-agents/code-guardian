#!/usr/bin/env bash
# dispatch.sh — one session per PR: a review run whose worklist holds several
# PRs starts the PRs after its first at once, each in a fresh session of its
# own, instead of leaving them to the next heartbeat (docs/worklist.md →
# Dispatch).
#
#   dispatch.sh plan <worklist>
#       Cuts one unit worklist per PR to dispatch — that PR's entries alone,
#       its bookkeeping included, `dispatched: {number, by}`, its own read_set
#       — next to <worklist>, and prints
#       {"dispatch": [{number, worklist, name, task}]}: every PR after the first
#       in run order, each with the exact `name` and `task` of its
#       mcp__platform-outbound__schedule_once call. The platform's own limits on
#       one-time tasks bound how many start; a refused PR stays with the run.
#       Prints an empty list for one PR, a housekeeping-only run, or
#       `review_dispatch: disabled` in the worklist's config.
#   dispatch.sh rest <worklist> [<n>…]
#       Prints `worklist: <path>` — <worklist> without the entries of PRs <n>…,
#       its read_set recomputed — the run's worklist from then on. A <n> with
#       no unit worklist from `plan` is refused. With no <n> it prints
#       <worklist> itself.
#
# The task text is a fixed template carrying the PR number and the unit's path
# and nothing from the PR, because it reaches the new session as its prompt.
# Its first line names the PR: the platform lists a session under the title the
# harness gives it, which falls back to the first prompt.
# Local writes only: the unit and rest files beside <worklist>, which the gate's
# /tmp sweep removes with it (precheck.sh), and one `dispatch` event.

set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_JOB="${LOG_JOB:-review}"
if ! . "$SCRIPT_DIR/log.sh" >/dev/null 2>&1; then logev() { :; }; LOG_RUN=""; fi
. "$SCRIPT_DIR/lib/common.sh"

die() { printf 'dispatch: %s\n' "$1" >&2; exit 2; }

# The entries that belong to one PR travel with it — its urgent alert, so the
# session that reviews the PR announces it first, and its bookkeeping rows, so
# one session writes that PR's REVIEWS.md row; the stall alert stays with the
# run that received the worklist. Run order is docs/runbook.md → Review run
# steps 5 to 10: urgent reviews, mentions, reviews, artifacts, CI failures,
# merges, fixes.
UNIT_JQ='
  def per_pr: ["reviews_due","mentions_due","ci_failures_due","merges_due","fixes_due","artifacts_due","urgent_alerts_due",
               "selfheals_due","label_cleanups_due","prunes_due","status_resets_due"];
  def only_prs($ns): reduce per_pr[] as $k (.;
    .[$k] = [(.[$k] // [])[] | select(.number as $x | any($ns[]; . == $x))]);
  def drop_prs($ns): reduce per_pr[] as $k (.;
    .[$k] = [(.[$k] // [])[] | select(.number as $x | any($ns[]; . == $x) | not)]);
  def units:
    ([(.reviews_due // [])[] | select(.urgent == true) | .number]
     + [(.mentions_due // [])[].number] + [(.reviews_due // [])[].number]
     + [(.artifacts_due // [])[].number] + [(.ci_failures_due // [])[].number]
     + [(.merges_due // [])[].number] + [(.fixes_due // [])[].number])
    | map(select(type == "number"))
    | reduce .[] as $n ([]; if any(.[]; . == $n) then . else . + [$n] end);
'

CMD="${1:-}"; WL="${2:-}"
[ -n "$WL" ] || die "usage: dispatch.sh plan|rest <worklist> [<n>…]"
[ -r "$WL" ] || die "no readable worklist at $WL"
jq -e 'type == "object" and .mode == "review"' "$WL" >/dev/null 2>&1 || die "$WL is not a review worklist"
BASE="${WL%.json}"
umask 077

case "$CMD" in
  plan)
    NUMS="$(jq -r "$UNIT_JQ"'
      if .housekeeping_only == true or .nothing_to_do == true
         or (.config.review_dispatch // "enabled") == "disabled" then empty
      else units[1:][] end' "$WL")" \
      || die "the worklist could not be read"
    OUT='[]'
    for n in $NUMS; do
      case "$n" in (''|*[!0-9]*) continue;; esac
      UNIT="$BASE-pr$n.json"
      jq --argjson n "$n" --arg by "${LOG_RUN:0:8}" "$READ_SET_JQ$UNIT_JQ"'
        only_prs([$n])
        | del(.stall_alert, .housekeeping_only)
        | .dispatched = {number: $n, by: $by}
        | .logs = (["PR #\($n): dispatched by run \($by) to a session of its own"]
                   + [(.logs // [])[] | select(startswith("project profile"))])
        | .read_set = read_set' "$WL" > "$UNIT" 2>/dev/null \
        || { rm -f "$UNIT"; logev error dispatch "PR #$n: the unit worklist could not be written — the run keeps the PR"; continue; }
      TASK="Review PR #$n — a review heartbeat dispatched by one that found several PRs.
worklist: $UNIT
"'Read the worklist JSON at that path and never run preflight.sh this run; if the file is gone, run `bash "$HOME/scripts/preflight.sh" review` yourself. Then follow CLAUDE.md → "Review run" and back up work/ at the end (`scripts/work-backup.sh persist`).'
      OUT="$(printf '%s' "$OUT" | jq -c --argjson n "$n" --arg w "$UNIT" --arg t "$TASK" \
        '. + [{number:$n, worklist:$w, name:("code-guardian-review-pr-" + ($n | tostring)), task:$t}]')"
    done
    printf '%s' "$OUT" | jq '{dispatch: .}'
    ;;
  rest)
    shift 2
    if [ "$#" -eq 0 ]; then printf 'worklist: %s\n' "$WL"; exit 0; fi
    for n in "$@"; do
      case "$n" in (''|*[!0-9]*) die "not a PR number: $n";; esac
      [ -f "$BASE-pr$n.json" ] || die "PR #$n has no unit worklist from plan — it stays in $WL"
    done
    NS="$(printf '%s\n' "$@" | jq -R 'tonumber' | jq -sc .)"
    REST="$BASE-rest.json"
    STARTED="$(printf '#%s, ' "$@" | sed 's/, $//')"
    if ! jq --argjson ns "$NS" "$READ_SET_JQ$UNIT_JQ"'drop_prs($ns) | .read_set = read_set' "$WL" > "$REST" 2>/dev/null; then
      rm -f "$REST"
      logev error dispatch "the rest worklist could not be written — the run goes on with $WL and leaves $STARTED to their sessions"
      die "the rest worklist could not be written — go on with $WL and leave every entry of $STARTED to its own session"
    fi
    KEPT="$(jq -r "$UNIT_JQ"'[units[] | "#\(.)"] | join(", ")' "$REST")"
    logev info dispatch "$STARTED dispatched to sessions of their own; this run keeps ${KEPT:-no PR}"
    printf 'worklist: %s\n' "$REST"
    ;;
  *) die "usage: dispatch.sh plan|rest <worklist> [<n>…]";;
esac
