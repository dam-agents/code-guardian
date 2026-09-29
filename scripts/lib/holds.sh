#!/usr/bin/env bash
# holds.sh — PR holds: a run owns the one PR it works on, its mentions and its
# review together (docs/worklist.md → PR holds).
#
#   hold_live <n>              0 + why = held by a live run; 1 = no hold;
#                              2 + its timestamp = a dead hold, removed here
#   hold_acquire <n> <run>     0 = this run holds it; 1 + why = another live run does
#   hold_release <n> <run>     0 = removed the hold <run> owns; 1 = it owns none
#
# A hold is `work/.holds.lock/<n>`: its creation time, then the owning run id,
# written in full before it is linked into place.
# The owner is alive while it logs — an event within HOLDER_QUIET_MIN, or
# FANOUT_QUIET_MIN when its newest event is the skill fan-out, the windows of a
# review lock's live holder (docs/review-mechanics.md → Live holder).
# The caller provides WORK, LOG_DIR, NOW_EPOCH, HOLDER_QUIET_MIN,
# FANOUT_QUIET_MIN and iso2epoch.

HOLD_DIR="$WORK/.holds.lock"

hold_run_alive() { # <run-id> <since-ts> -> "last event <ts>" when alive
  local cut fcut
  cut="$(date -u -d "@$(( NOW_EPOCH - HOLDER_QUIET_MIN * 60 ))" +%Y-%m-%dT%H:%M:%S 2>/dev/null \
         || date -u -r "$(( NOW_EPOCH - HOLDER_QUIET_MIN * 60 ))" +%Y-%m-%dT%H:%M:%S 2>/dev/null)" || return 1
  fcut="$(date -u -d "@$(( NOW_EPOCH - FANOUT_QUIET_MIN * 60 ))" +%Y-%m-%dT%H:%M:%S 2>/dev/null \
          || date -u -r "$(( NOW_EPOCH - FANOUT_QUIET_MIN * 60 ))" +%Y-%m-%dT%H:%M:%S 2>/dev/null)" || return 1
  ls "$LOG_DIR"/events-*.jsonl >/dev/null 2>&1 || return 1
  # seconds precision on both sides: an event's `.123Z` sorts before a `Z`
  cat "$LOG_DIR"/events-*.jsonl 2>/dev/null \
    | jq -c -R 'fromjson? // empty' 2>/dev/null \
    | jq -rs --arg run "$1" --arg since "${2:0:19}" --arg cut "$cut" --arg fcut "$fcut" '
        ( [ .[] | select(.run == $run and .ts[0:19] >= $since) ] | last ) as $l
        | ( ($l.msg // "") | test("fanned out") ) as $fan
        | if $l and $l.ts[0:19] >= (if $fan then $fcut else $cut end)
          then "last event \($l.ts[0:19])Z" else empty end' 2>/dev/null
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
