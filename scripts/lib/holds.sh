#!/usr/bin/env bash
# holds.sh — live holders and PR holds (docs/review-mechanics.md → Live holder,
# docs/worklist.md → PR holds). Sourced by preflight.sh, review-pr.sh and the
# Stop hook; the caller provides WORK, LOG_DIR, NOW_EPOCH and lib/common.sh.
#
#   holder_cutoffs             sets HOLDER_CUT and FANOUT_CUT (UTC, to the second)
#   $HOLDER_JQ                 jq definitions: tkey, stepof, alive_last, live_holders
#   hold_live <n>              0 + why = held by a live run; 1 = no hold;
#                              2 + its timestamp = a dead hold, removed here
#   hold_acquire <n> <run>     0 = this run holds it; 1 + why = another live run does
#   hold_release <n> <run>     0 = removed the hold <run> owns; 1 = it owns none
#   hold_release_others <n> <run>
#                              removes every other hold <run> owns, prints their numbers
#
# A hold is `work/.holds.lock/<n>`: its creation time, then the owning run id,
# written in full before it is linked into place.

# A run is alive while it logs. Its newest event must be inside
# HOLDER_QUIET_MIN — above the longest gap a healthy review shows between
# events, measured at 16.7 min over real runs — or inside FANOUT_QUIET_MIN when
# that event is the skill fan-out, the one phase that is structurally silent
# (the holder is blocked on its subagents until `verified`; calibrate against
# stats.reviews.phases.skills, docs/audit.md task 23). CG_* override for tests.
HOLDER_QUIET_MIN="${CG_HOLDER_QUIET_MIN:-20}"
FANOUT_QUIET_MIN="${CG_FANOUT_QUIET_MIN:-60}"
HOLD_DIR="$WORK/.holds.lock"

holder_cutoffs() {
  HOLDER_CUT="$(epoch2iso $(( NOW_EPOCH - HOLDER_QUIET_MIN * 60 )) '%Y-%m-%dT%H:%M:%S')"
  FANOUT_CUT="$(epoch2iso $(( NOW_EPOCH - FANOUT_QUIET_MIN * 60 )) '%Y-%m-%dT%H:%M:%S')"
  [ -n "$HOLDER_CUT" ] && [ -n "$FANOUT_CUT" ]
}

# Events compare to the second (log.sh writes `.123Z` or `Z`; jq's sort is
# stable, so log order holds inside one second). A step is matched the way the
# Stop hook matches it: the `PR #<n>` prefix and the optional sha token
# stripped, so `skill:<name> done` and `rapid posted` stay non-terminal.
# live_holders: a `locked` step on the PR makes a run a holder — a taker that
# stood down holds nothing; it still owes the PR while its newest step there is
# not done/aborted/posted, and it is alive while its newest event of any kind
# is inside its window. Input: the events array; output: [{run, last}].
HOLDER_JQ='
  def tkey: (.ts // "") | tostring | .[0:19];
  def stepof: (.msg // "") | sub("^PR #[0-9]+:? +"; "") | sub("^[0-9a-f]{7,40}( +|$)"; "");
  def alive_last($cut; $fcut):
    sort_by(tkey) | last
    | select(. != null)
    | select(tkey >= (if ((.msg // "") | test("fanned out")) then $fcut else $cut end));
  def live_holders($n; $cut; $fcut):
    . as $ev
    | [ $ev[] | select(.event == "review_step" and ((.msg // "") | test("^PR #" + $n + "(:| |$)"))) ] as $pr
    | [ $pr[] | select(stepof | test("^locked( |$)")) | .run ] | unique
    | map(. as $r
          | select(([ $pr[] | select(.run == $r) ] | sort_by(tkey) | last | stepof
                    | test("^(done|aborted|posted)( |$)")) | not)
          | ([ $ev[] | select(.run == $r) ] | alive_last($cut; $fcut)) as $l
          | select($l != null)
          | {run: $r, last: $l});
'

hold_run_alive() { # <run-id> <since-ts> -> "last event <ts>" when alive
  holder_cutoffs || return 1
  events_jsonl | jq -rs --arg run "$1" --arg since "${2:0:19}" --arg cut "$HOLDER_CUT" --arg fcut "$FANOUT_CUT" \
    "$HOLDER_JQ"'[ .[] | select(.run == $run and tkey >= $since) ] | alive_last($cut; $fcut)
                  | "last event \(tkey)Z"' 2>/dev/null
}

hold_live() { # <n>
  local f="$HOLD_DIR/$1" held ts run alive
  held="$(cat "$f" 2>/dev/null)" || return 1
  ts="$(printf '%s\n' "$held" | sed -n 1p)"; run="$(printf '%s\n' "$held" | sed -n 2p)"
  # a hold younger than a minute may not have its owner's first event yet
  if [ $(( NOW_EPOCH - $(iso2epoch "$ts") )) -lt 60 ]; then
    echo "held by run ${run:0:8}, taken at $ts"; return 0
  fi
  if [ -n "$run" ] && alive="$(hold_run_alive "$run" "$ts")" && [ -n "$alive" ]; then
    echo "held by run ${run:0:8}, $alive"; return 0
  fi
  # remove only the hold judged dead: a run that took it over meanwhile wrote a
  # new one, which is judged again
  [ "$(cat "$f" 2>/dev/null)" = "$held" ] || { hold_live "$1"; return; }
  rm -f "$f"; echo "$ts"; return 2
}

hold_acquire() { # <n> <run>
  local f="$HOLD_DIR/$1" tmp why try
  mkdir -p "$HOLD_DIR" 2>/dev/null || { echo "the hold directory could not be made"; return 1; }
  tmp="$HOLD_DIR/.$1.$$.tmp"
  printf '%s\n%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" > "$tmp" 2>/dev/null \
    || { rm -f "$tmp"; echo "the hold could not be written"; return 1; }
  for try in 1 2; do
    # ln of the complete file: of two runs creating the same hold, exactly one
    # succeeds, and no reader sees it half written
    ln "$tmp" "$f" 2>/dev/null && { rm -f "$tmp"; return 0; }
    [ "$(sed -n 2p "$f" 2>/dev/null)" = "$2" ] && { rm -f "$tmp"; return 0; }
    why="$(hold_live "$1")" && { rm -f "$tmp"; echo "$why"; return 1; }
  done
  rm -f "$tmp"; echo "the hold could not be taken"; return 1
}

hold_release() { # <n> <run> -> 0 = released, 1 = <run> held nothing
  [ "$(sed -n 2p "$HOLD_DIR/$1" 2>/dev/null)" = "$2" ] && rm -f "$HOLD_DIR/$1"
}

# A run holds one PR at a time: taking the next one gives back the one before,
# also when its `release` was left out.
hold_release_others() { # <n> <run> -> one released PR number per line
  local f
  for f in "$HOLD_DIR"/*; do
    [ -f "$f" ] && [ "${f##*/}" != "$1" ] && [ "$(sed -n 2p "$f" 2>/dev/null)" = "$2" ] || continue
    rm -f "$f" && printf '%s\n' "${f##*/}"
  done
}
