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
#       {"dispatch": [{number, worklist, name, task, sessionTitle, model?}]}:
#       every PR after the first in run order, each with the exact `name`,
#       `task`, `sessionTitle` and `model` of its
#       mcp__platform-outbound__schedule_once call — `model` is the config's
#       `review_model`, absent under `default` (docs/config.md). The platform's own limits on
#       one-time tasks bound how many start; a refused PR stays with the run.
#       Prints an empty list for one PR, a housekeeping-only run, or
#       `review_dispatch: disabled` in the worklist's config.
#   dispatch.sh rest <worklist> [<n>…]
#       Prints `worklist: <path>` — <worklist> without the entries of PRs <n>…,
#       its read_set recomputed — the run's worklist from then on, and
#       `title: <title>`, the session title of the work it keeps. A <n> with
#       no unit worklist from `plan` is refused. With no <n> it prints
#       <worklist> itself and its title.
#
# The task text is a fixed template carrying the PR number and the unit's path
# and nothing from the PR, because it reaches the new session as its prompt.
# A session title names the work and PR numbers alone, in the form
# `<Verb> <object>` (TITLE_JQ); the task's first line names the PR too, for a
# platform that takes no sessionTitle.
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
# one session writes that PR's REVIEWS.md row; the stall and anomaly alerts
# stay with the run that received the worklist. Run order is docs/runbook.md → Review run
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

# The session title of one PR names its main work — the review first, then the
# run order of the other keys; a run keeping several PRs lists their numbers.
TITLE_JQ='
  def has_pr($k; $n): any((.[$k] // [])[]; .number == $n);
  def unit_title($n):
    ((.reviews_due // []) | map(select(.number == $n)) | first) as $r
    | if $r != null then
        (if $r.kind == "re-review" then "Re-review PR #\($n)"
         elif $r.urgent == true then "Review urgent PR #\($n)"
         else "Review PR #\($n)" end)
      elif has_pr("mentions_due"; $n) then "Answer mention on PR #\($n)"
      elif has_pr("artifacts_due"; $n) then "Publish artifact for PR #\($n)"
      elif has_pr("ci_failures_due"; $n) then "Triage CI on PR #\($n)"
      elif has_pr("merges_due"; $n) then "Merge PR #\($n)"
      elif has_pr("fixes_due"; $n) then "Fix findings on PR #\($n)"
      else "Review PR #\($n)" end;
  def run_title:
    units as $u
    | if ($u | length) == 1 then unit_title($u[0])
      elif ($u | length) > 1 then
        "Review PRs " + ([$u[:5][] | "#\(.)"] | join(", "))
        + (if ($u | length) > 5 then " +\(($u | length) - 5) more" else "" end)
      elif .stall_alert != null or .review_anomaly != null then "Report review alerts"
      else "Tidy review state" end;
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
    MODEL="$(jq -r '.config.review_model // "default"' "$WL")"
    OUT='[]'
    for n in $NUMS; do
      case "$n" in (''|*[!0-9]*) continue;; esac
      UNIT="$BASE-pr$n.json"
      jq --argjson n "$n" --arg by "${LOG_RUN:0:8}" "$READ_SET_JQ$UNIT_JQ"'
        only_prs([$n])
        | del(.stall_alert, .review_anomaly, .housekeeping_only)
        | .dispatched = {number: $n, by: $by}
        | .logs = (["PR #\($n): dispatched by run \($by) to a session of its own"]
                   + [(.logs // [])[] | select(startswith("project profile"))])
        | .read_set = read_set' "$WL" > "$UNIT" 2>/dev/null \
        || { rm -f "$UNIT"; logev error dispatch "PR #$n: the unit worklist could not be written — the run keeps the PR"; continue; }
      TASK="Review PR #$n — a review heartbeat dispatched by one that found several PRs.
worklist: $UNIT
"'Read the worklist JSON at that path and never run preflight.sh this run; if the file is gone, run `bash "$HOME/scripts/preflight.sh" review` yourself. Then follow CLAUDE.md → "Review run" and back up work/ at the end (`scripts/work-backup.sh persist`).'
      TITLE="$(jq -r --argjson n "$n" "$UNIT_JQ$TITLE_JQ"'unit_title($n)' "$WL")"
      OUT="$(printf '%s' "$OUT" | jq -c --argjson n "$n" --arg w "$UNIT" --arg t "$TASK" --arg m "$MODEL" --arg s "$TITLE" \
        '. + [{number:$n, worklist:$w, name:("code-guardian-review-pr-" + ($n | tostring)), task:$t, sessionTitle:$s}
              + (if ($m | ascii_downcase) == "default" or $m == "" then {} else {model:$m} end)]')"
    done
    printf '%s' "$OUT" | jq '{dispatch: .}'
    ;;
  rest)
    shift 2
    if [ "$#" -eq 0 ]; then
      printf 'worklist: %s\ntitle: %s\n' "$WL" "$(jq -r "$UNIT_JQ$TITLE_JQ"'run_title' "$WL")"
      exit 0
    fi
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
    printf 'worklist: %s\ntitle: %s\n' "$REST" "$(jq -r "$UNIT_JQ$TITLE_JQ"'run_title' "$REST")"
    ;;
  *) die "usage: dispatch.sh plan|rest <worklist> [<n>…]";;
esac
