#!/usr/bin/env bash
# monitor.sh — the monitor's detector: the agent's health alerts, apart from
# the review heartbeat (docs/monitor.md).
#
# Detects, never acts. Reads local files only — the events log, the review
# usage baseline, the review ledger, the harness settings — and makes no
# GitHub call, so the review gate stays free of health checks and a monitor
# tick costs no API quota. Its writes are bookkeeping: the alert ledger
# work/MONITOR.json (claims and deliveries), the stall-alert day claim, the
# anomaly marker and baseline, HEARTBEAT.log and the events log.
#
#   monitor.sh            -> worklist JSON: alerts_due[] (each with an `id`),
#                            stall_alert, review_anomaly, suppressed, config,
#                            logs; nothing_to_do when none is due
#   monitor.sh ack <id>…  -> records the alerts as delivered (send-then-record)
#
# An alerts_due entry is claimed for CLAIM_TTL_S when emitted: a later tick in
# that time skips it, and after it the alert is emitted again — a session that
# died before its ack (a model outage is the usual cause) loses nothing.
#
# Requires: bash, jq, sed/grep/cut/tr/sort, GNU or BSD date. No awk, no gh.

set -u
export LC_ALL=C

MODE="${1:-detect}"
HOME_DIR="${HOME:-/home/agent}"
WORK="${WORK_DIR:-$HOME_DIR/work}"
CONFIG="$WORK/CONFIG.md"
LEDGER="$WORK/REVIEW-LEDGER.jsonl"
REVIEW_USAGE="$WORK/REVIEW-USAGE.jsonl"   # the anomaly baseline
STATE="$WORK/MONITOR.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NOW_EPOCH=$(date -u +%s)
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

LOG_JOB=monitor
if ! . "$SCRIPT_DIR/log.sh" >/dev/null 2>&1; then logev() { :; }; fi
LOG_DIR="${LOG_DIR:-$WORK/logs}"
. "$SCRIPT_DIR/lib/common.sh"

LOGS=()
log() { LOGS+=("$1"); logev info monitor "$1"; }

CLAIM_TTL_S=1800          # an emitted, unacknowledged alert is due again after this
STATE_KEEP_S=$(( 14 * 86400 ))   # a row whose alert no tick finds goes after this
MODEL_GAP_S=3600          # API failures this far apart are two outages
CLASSIFIER_WINDOW_S=86400

# a non-negative integer key: missing -> <default>, off/none -> 0, other -> <default>
int_key() { # <key> <default>
  local v; v="$(cfg "$1")"
  case "$v" in
    ('') printf '%s' "$2";;
    (off|none) printf 0;;
    (*[!0-9]*) log "$1 '$v' is not a number, 0 or off — using $2"; printf '%s' "$2";;
    (*) printf '%s' "$v";;
  esac
}

# ------------------------------------------------------------ ledger ----
# {"alerts": {"<id>": {"kind", "first", "claimed", "sent"}}} — one writer at a
# time (with_state_lock, lib/common.sh), a broken file reads as empty
state_read() { jq -c 'if (.alerts | type) == "object" then . else {alerts: {}} end' "$STATE" 2>/dev/null || echo '{"alerts":{}}'; }
state_write() { # <json>
  printf '%s\n' "$1" > "$STATE.tmp" 2>/dev/null && mv "$STATE.tmp" "$STATE" 2>/dev/null
  rm -f "$STATE.tmp" 2>/dev/null
}

if [ "$MODE" = "ack" ]; then
  shift
  [ "$#" -gt 0 ] || { echo '{"error":"ack needs at least one alert id"}'; exit 2; }
  ids="$(printf '%s\n' "$@" | jq -R . | jq -sc .)"
  ack_apply() {
    state_write "$(state_read | jq -c --argjson ids "$ids" --arg now "$NOW_ISO" '
      reduce $ids[] as $i (.; .alerts[$i] = ((.alerts[$i] // {kind: ($i | split(":")[0]), first: $now}) + {sent: $now}))')"
  }
  with_state_lock "$STATE" ack_apply
  logev info monitor_alert_sent "$*"
  jq -nc --argjson ids "$ids" '{acknowledged: $ids}'
  exit 0
fi
[ "$MODE" = "detect" ] || { echo '{"error":"unknown mode — use monitor.sh or monitor.sh ack <id>…"}'; exit 2; }

[ -f "$CONFIG" ] || log "work/CONFIG.md missing — running with defaults"
MODEL_THRESHOLD="$(int_key model_alert_threshold 2)"
CLASSIFIER_THRESHOLD="$(int_key classifier_alert_threshold 20)"
STALL_ALERT_THRESHOLD="$(int_key stall_alert_threshold 4)"

# candidate alerts of this tick: one JSON object per line, each with id + kind
CANDIDATES=""
# condition kinds whose condition cleared this tick: their ledger rows go, so
# the same condition alerts again when it returns
CLEARED=""
cand() { CANDIDATES="$CANDIDATES$1"$'\n'; }
# an event ts (ms precision) or a ledger ts as epoch seconds, 0 when unreadable
EP='def ep: (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601?) // 0;'


# ---------------------------------------------------- model unavailable ----
# StopFailure turns (log-api-failure.sh → api_failure) of the availability
# classes, grouped into outages: failures less than MODEL_GAP_S apart are one.
# An outage alerts once it reaches the threshold, and once more when it is
# over, if its first alert went out while it was still open.
if [ "$MODEL_THRESHOLD" -gt 0 ]; then
  OUTAGES="$(events_jsonl api_failure | jq -sc --argjson gap "$MODEL_GAP_S" "$EP"'
    [ .[] | select(.event == "api_failure")
      | {ts, run, class: ((.msg | capture("^(?<c>[a-z_]+):") | .c) // "unknown"), msg}
      | select(.class | IN("invalid_request", "max_output_tokens") | not) ]
    | sort_by(.ts)
    | reduce .[] as $e ([];
        if length > 0 and (($e.ts | ep) - (.[-1][-1].ts | ep)) < $gap
        then .[-1] += [$e] else . + [[$e]] end)' 2>/dev/null)"
  [ -n "$OUTAGES" ] || OUTAGES='[]'
  while IFS= read -r o; do [ -n "$o" ] && cand "$o"; done < <(printf '%s' "$OUTAGES" | jq -c \
    --argjson now "$NOW_EPOCH" --argjson gap "$MODEL_GAP_S" --argjson thr "$MODEL_THRESHOLD" "$EP"'
    .[] | select(length >= $thr)
    | {first: .[0].ts, last: .[-1].ts, count: length, runs: (map(.run) | unique | length),
       errors: (group_by(.class) | map({key: .[0].class, value: length}) | from_entries),
       sample: (.[-1].msg | .[0:240])}
    | . + {open: (($now - (.last | ep)) < $gap),
           over_at: ((.last | ep) + $gap | todate)}
    | ({id: "model:\(.first)", kind: "model_unavailable"} + .),
      (select(.open | not) | {id: "model:\(.first):recovered", kind: "model_recovered",
        needs: "model:\(.first)"} + .)')
fi

# ------------------------------------------------------- classifier ----
# PermissionDenied refusals (log-permission-denied.sh → classifier_block):
# a day over the threshold alerts once that UTC day; a refused review post
# alerts on its own, unless the same PR was posted after it.
if [ "$CLASSIFIER_THRESHOLD" -gt 0 ]; then
  CB_SINCE="$(epoch2iso $(( NOW_EPOCH - CLASSIFIER_WINDOW_S )))"
  CB="$(events_jsonl classifier_block | jq -sc --arg s "$CB_SINCE" '
    [ .[] | select(.event == "classifier_block" and .level == "warn" and .ts >= $s)
      | {ts, run, tool: (.msg | split(" ")[0]),
         what: ((.msg | capture("\\[(?<w>.*)\\] — ") | .w) // ""),
         reason: ((.msg | capture(" — (?<r>[^—]*)$") | .r) // "")} ]' 2>/dev/null)"
  [ -n "$CB" ] || CB='[]'
  CB_N="$(printf '%s' "$CB" | jq length)"
  if [ "$CB_N" -ge "$CLASSIFIER_THRESHOLD" ]; then
    cand "$(printf '%s' "$CB" | jq -c --arg day "${NOW_ISO:0:10}" --argjson thr "$CLASSIFIER_THRESHOLD" '
      {id: "classifier:\($day)", kind: "classifier_spike", count: length, threshold: $thr, window_hours: 24,
       runs: (map(.run) | unique | length),
       by_tool: (group_by(.tool) | map({key: .[0].tool, value: length}) | from_entries),
       by_reason: (group_by(.reason) | map({key: .[0].reason, value: length}) | from_entries),
       top: (map("\(.tool) \(.what)" | gsub("[0-9]+"; "N") | .[0:80]) | group_by(.) | map({pattern: .[0], count: length})
             | sort_by(-.count) | .[0:5])}')"
  fi
  while IFS= read -r o; do [ -n "$o" ] && cand "$o"; done < <(printf '%s' "$CB" | jq -c \
    --slurpfile steps <(events_jsonl review_step | jq -c --arg s "$CB_SINCE" \
      'select(.event == "review_step" and .ts >= $s) | {ts, pr: ((.msg | capture("^PR #(?<pr>[0-9]+) [0-9a-f]+ posted") | .pr) // null)}
       | select(.pr != null)' 2>/dev/null) '
    .[] | select(.tool == "Bash" and (.what | test("review-pr\\.sh\"? post ")))
    | (.what | capture("post (?<pr>[0-9]+)") | .pr) as $pr | select($pr != null)
    | . as $b | select(any($steps[]; .pr == $pr and .ts > $b.ts) | not)
    | {id: "post_blocked:\(.run):\($pr)", kind: "review_post_blocked", pr: ($pr | tonumber), ts, reason}')
fi

# -------------------------------------------------- harness adapter ----
# install.sh --check names the parts of the Claude Code adapter that are not
# current — a missing hook, [code-guardian] rules an older definition wrote.
# The check reads only local files; a re-install clears the condition.
INSTALL="$SCRIPT_DIR/harness/claude-code/install.sh"
if [ -f "$HOME_DIR/.claude/settings.json" ] && [ -f "$INSTALL" ]; then
  DRIFT="$(CLAUDECODE=1 bash "$INSTALL" --check 2>/dev/null | tr ' ' '\n' | grep -v '^$' | sort | tr '\n' ' ')"
  DRIFT="${DRIFT% }"
  if [ -n "$DRIFT" ]; then
    cand "$(jq -nc --arg p "$DRIFT" '{id: "harness:\($p | gsub(" "; "+"))", kind: "harness_drift", parts: ($p | split(" "))}')"
  else CLEARED="$CLEARED harness_drift"; fi
fi

# --------------------------------------------------- review heartbeat ----
# The review gate logs every tick (precheck or heartbeat event, job review).
# Silence past 1.5x the quiet interval (at least an hour) means the schedule
# stopped or the gate cannot start.
REVIEW_INTERVAL_QUIET="$(int_key review_interval_quiet 60)"
[ "$REVIEW_INTERVAL_QUIET" -ge 1 ] || REVIEW_INTERVAL_QUIET=60
HB_GAP_MAX_S=$(( REVIEW_INTERVAL_QUIET * 90 ))
[ "$HB_GAP_MAX_S" -ge 3600 ] || HB_GAP_MAX_S=3600
HB_LAST="$(cat "$LOG_DIR"/events-*.jsonl 2>/dev/null | grep -F '"job":"review"' \
  | grep -E '"event":"(precheck|heartbeat)"' | jq -r -R 'fromjson? | .ts' 2>/dev/null | sort | tail -1)"
if [ -n "$HB_LAST" ]; then
  HB_AGE=$(( NOW_EPOCH - $(iso2epoch "$HB_LAST") ))
  if [ "$HB_AGE" -gt "$HB_GAP_MAX_S" ]; then
    cand "$(jq -nc --arg l "$HB_LAST" --argjson a "$HB_AGE" --argjson m "$HB_GAP_MAX_S" \
      '{id: "heartbeat:\($l)", kind: "heartbeat_gap", last: $l, silent_minutes: ($a / 60 | floor), limit_minutes: ($m / 60 | floor)}')"
  else CLEARED="$CLEARED heartbeat_gap"; fi
fi

# ------------------------------------------------------------ backup ----
# work-backup.sh logs an error when a persist gives up. A failure that no
# later push cleared for 6 hours alerts; the next push clears it.
if [ -n "$(cfg work_repo)" ]; then
  BK="$(events_jsonl work_backup | jq -sc '
    [ .[] | select(.event == "work_backup") ] | sort_by(.ts)
    | (map(select(.msg | startswith("pushed"))) | last | .ts) as $ok
    | [ .[] | select(.level == "error" and (.ts > ($ok // ""))) ]
    | if length == 0 then null else {first: .[0].ts, failures: length, sample: (.[-1].msg | .[0:200])} end' 2>/dev/null)"
  if [ -n "$BK" ] && [ "$BK" != null ] \
     && [ $(( NOW_EPOCH - $(iso2epoch "$(printf '%s' "$BK" | jq -r .first)") )) -ge 21600 ]; then
    cand "$(printf '%s' "$BK" | jq -c '{id: "backup:\(.first)", kind: "backup_failing"} + .')"
  else CLEARED="$CLEARED backup_failing"; fi
fi

# ---------------------------------------------- claim against the ledger ----
# One candidate per id, the first found: a run that retried a refused post is
# one review_post_blocked alert. A row whose alert this tick still finds stays,
# whatever its age — the events log can outlive STATE_KEEP_S (docs/logging.md
# → Retention), and a sent alert is never sent again. Every other row goes
# STATE_KEEP_S after its last claim or send.
DUE='[]'; SUPPRESSED=0
claim() {
  local st new
  st="$(state_read)"
  new="$(printf '%s' "$CANDIDATES" | jq -sc --argjson st "$st" --arg now "$NOW_ISO" \
      --argjson nowe "$NOW_EPOCH" --argjson ttl "$CLAIM_TTL_S" --argjson keep "$STATE_KEEP_S" \
      --arg cleared "$CLEARED" "$EP"'
    ($cleared | split(" ") | map(select(length > 0))) as $clr
    | unique_by(.id) as $c
    | ($c | map(.id)) as $ids
    | ($st.alerts | with_entries(select(.value.kind | IN($clr[]) | not))
       | with_entries(select((.key | IN($ids[]))
           or ($nowe - ((.value.sent // .value.claimed // .value.first // $now) | ep)) < $keep))) as $a
    | [ $c[] | select(.needs == null or ($a[.needs].sent != null
                 and (($a[.needs].sent | ep) < (.over_at | ep)))) ] as $c
    | { due: [ $c[] | select($a[.id].sent == null
                 and (($a[.id].claimed == null) or ($nowe - ($a[.id].claimed | ep)) >= $ttl)) ],
        suppressed: [ $c[] | select($a[.id].sent != null) ] | length } as $r
    | { due: $r.due, suppressed: $r.suppressed,
        state: {alerts: (reduce $r.due[] as $d ($a;
          .[$d.id] = ((.[$d.id] // {kind: $d.kind, first: $now}) + {claimed: $now})))} }' 2>/dev/null)"
  [ -n "$new" ] || return 1
  state_write "$(printf '%s' "$new" | jq -c .state)"
  DUE="$(printf '%s' "$new" | jq -c .due)"
  SUPPRESSED="$(printf '%s' "$new" | jq .suppressed)"
}
with_state_lock "$STATE" claim || log "alert ledger unreadable — no alert claimed this tick"
[ "$SUPPRESSED" -gt 0 ] && log "suppressed $SUPPRESSED alert(s) already reported"

# ---------------------------------------- stalled-review rate alert ----
# docs/monitor.md → Stalled-review rate alert. Counts the last 24h of
# `stale in_progress lock` takeovers, one per dead lock, and emits ONE alert
# per UTC day at the threshold. The day claim is spent here, at detection.
STALL_SEL='select(.event == "preflight" and (.msg | test("stale in_progress lock")))
  | {ts, pr: (.msg | capture("PR #(?<n>[0-9]+)") | .n | tonumber),
     lock: ((.msg | capture("locked (?<l>[^ )]+)") | .l) // "")}'
# stalls(scope): one event per stall, its first line. A keyed line counts once
# per (PR, lock time); an unkeyed line once per (PR, scope), and only when no
# keyed line of that PR shares the scope
STALL_DEFS='def stalls(scope): map(.scope = (.ts | scope))
  | ([.[] | select(.lock != "") | [.pr, .scope]] | unique) as $kp
  | (map(select(.lock != "")) | group_by([.pr, .lock]) | map(min_by(.ts)))
    + (map(select(.lock == "" and ([.pr, .scope] | IN($kp[]) | not)))
       | group_by([.pr, .scope]) | map(min_by(.ts)));'
STALL_ALERT=""
if [ "$STALL_ALERT_THRESHOLD" -gt 0 ]; then
  STALL_SINCE_ISO="$(epoch2iso $(( NOW_EPOCH - 86400 )))"
  STALL_EVENTS="$(events_jsonl preflight | jq -sc "[ .[] | try ($STALL_SEL) ]" 2>/dev/null)"
  [ -n "$STALL_EVENTS" ] || STALL_EVENTS='[]'
  STALL_WIN="$(printf '%s' "$STALL_EVENTS" | jq -c --arg s "$STALL_SINCE_ISO" \
    "$STALL_DEFS"' map(select(.ts >= $s)) | stalls("")')"
  STALL_N="$(printf '%s' "$STALL_WIN" | jq length)"; STALL_N="${STALL_N:-0}"
  STALL_PRS="$(printf '%s' "$STALL_WIN" | jq -r '[.[].pr] | unique | map(tostring) | join(" ")')"
  STALL_WEEK="$(printf '%s' "$STALL_EVENTS" | jq -c "$STALL_DEFS"' stalls(.[0:10])
    | group_by(.ts[0:10]) | map({day: .[0].ts[0:10], stalls: length}) | sort_by(.day) | .[-7:]')"
  [ -n "$STALL_WEEK" ] || STALL_WEEK='[]'
  STALL_MARKER="$WORK/.stall-alert-day"
  STALL_TODAY="$(date -u +%Y-%m-%d)"
  find "$WORK/.stall-alert.lock" -maxdepth 0 -mmin +5 -exec rmdir {} \; 2>/dev/null || true
  if [ "$STALL_N" -ge "$STALL_ALERT_THRESHOLD" ] \
     && [ "$(cat "$STALL_MARKER" 2>/dev/null)" != "$STALL_TODAY" ] \
     && mkdir "$WORK/.stall-alert.lock" 2>/dev/null; then
    if [ "$(cat "$STALL_MARKER" 2>/dev/null)" != "$STALL_TODAY" ]; then
      printf '%s\n' "$STALL_TODAY" > "$STALL_MARKER" 2>/dev/null
      STALL_ALERT="$(jq -n --argjson count "$STALL_N" \
        --argjson threshold "$STALL_ALERT_THRESHOLD" \
        --argjson week "$STALL_WEEK" \
        --argjson prs "$(printf '%s' "$STALL_PRS" | tr ' ' '\n' | jq -R . | jq -s '[.[] | select(length>0) | tonumber]')" \
        '{count:$count, threshold:$threshold, prs:$prs, window_hours:24, per_day_7d:$week}')"
      log "stalled reviews: $STALL_N in the last 24h (threshold $STALL_ALERT_THRESHOLD) on PR(s) $STALL_PRS — alert due"
      logev warn stall_rate "$STALL_N stalled review(s) in 24h (threshold $STALL_ALERT_THRESHOLD) on PR(s) $STALL_PRS"
    fi
    rmdir "$WORK/.stall-alert.lock" 2>/dev/null
  fi
fi

# ------------------------------------------------ review anomaly alert ----
# docs/monitor.md → Review anomaly alert. Every `review_cost` event of the last
# 24 h newer than the marker is judged once: each metric against max(floor,
# factor × the median of the same model's previous reviews). The marker then
# moves to the newest event, under a mkdir claim.
ANOMALY_FACTOR="$(cfg review_anomaly_factor)"
case "$ANOMALY_FACTOR" in
  (off|none) ANOMALY_FACTOR=0;;
  ('') ANOMALY_FACTOR=4;;
  (*) ANOMALY_F="$(printf '%s\n' "$ANOMALY_FACTOR" | grep -E '^[0-9]+(\.[0-9]+)?$' \
        | jq -R 'tonumber | select(. == 0 or . >= 1)' 2>/dev/null)"
      if [ -n "$ANOMALY_F" ]; then ANOMALY_FACTOR="$ANOMALY_F"
      else log "review_anomaly_factor '$ANOMALY_FACTOR' is not 0, off or a number of 1 or more — using 4"; ANOMALY_FACTOR=4; fi;;
esac
ANOMALY_MIN_SAMPLES=10     # baseline reviews of the same model before a median rule applies
ANOMALY_WINDOW=30          # the baseline: that model's last N reviews before the one judged
ANOMALY_REPEATS=8          # floor: one identical tool call this often in one review
ANOMALY_FAILURES=5         # floor: tool_failure events in one review
ANOMALY_OUTPUT=200000      # floor: characters of one tool result
ANOMALY_ALERT=""
if [ "$ANOMALY_FACTOR" != 0 ]; then
  find "$WORK/.review-anomaly.lock" -maxdepth 0 -mmin +5 -exec rmdir {} \; 2>/dev/null || true
  if mkdir "$WORK/.review-anomaly.lock" 2>/dev/null; then
    ANOMALY_MARKER="$WORK/.review-anomaly-seen"
    ANOMALY_CUT="$(epoch2iso $(( NOW_EPOCH - 86400 )))"
    ANOMALY_SEEN="$(cat "$ANOMALY_MARKER" 2>/dev/null)"
    [ "$ANOMALY_SEEN" \> "$ANOMALY_CUT" ] || ANOMALY_SEEN="$ANOMALY_CUT"
    ANOMALY_EVENTS="$(events_jsonl review_cost | jq -sc '[ .[] | select(.event == "review_cost") | try (
        .ts as $ts | .msg | capture("^PR #(?<pr>[0-9]+) (?<sha>[0-9a-f]{7}) ") as $c
        | [scan("([a-z_]+)=([^ ]+)") | {(.[0]): (.[1] | tonumber? // .)}] | add
        | . + {ts: $ts, pr: ($c.pr | tonumber), sha: $c.sha}) ] | sort_by(.ts)' 2>/dev/null)"
    if [ -n "$ANOMALY_EVENTS" ] && [ "$(printf '%s' "$ANOMALY_EVENTS" | jq --arg s "$ANOMALY_SEEN" 'any(.[]; .ts > $s)')" = true ]; then
      . "$SCRIPT_DIR/lib/prices.sh"
      # the baseline outlives the 14-day event retention: the judged reviews of
      # REVIEW-USAGE.jsonl plus the retained events, one row per review
      ANOMALY_ALL="$( { jq -cR 'fromjson? // empty' "$REVIEW_USAGE" 2>/dev/null; printf '%s' "$ANOMALY_EVENTS" | jq -c '.[]'; } \
        | jq -sc '[.[] | objects] | unique_by([.ts, .pr, .sha, .model]) | sort_by(.ts)' 2>/dev/null)"
      ANOMALY_STORE=true
      [ -n "$ANOMALY_ALL" ] || { ANOMALY_ALL="$ANOMALY_EVENTS"; ANOMALY_STORE=false; }
      ANOMALY_JUDGED="$(printf '%s' "$ANOMALY_ALL" | jq -c --arg seen "$ANOMALY_SEEN" \
        --argjson f "$ANOMALY_FACTOR" --argjson min "$ANOMALY_MIN_SAMPLES" --argjson w "$ANOMALY_WINDOW" \
        --argjson lim "$(jq -nc --argjson r "$ANOMALY_REPEATS" --argjson fl "$ANOMALY_FAILURES" --argjson o "$ANOMALY_OUTPUT" \
                         '{repeats: $r, failures: $fl, max_out: $o}')" \
        --argjson prices "$(prices_json "$CONFIG")" "$PRICES_JQ"'
        # unpriced model: tokens weighted by the usual Claude price ratios
        def cost: price_row(.model) as $p
          | if $p then {v: token_usd($p), unit: "usd"}
            else {v: ((.input // 0) + 5 * (.output // 0) + 0.1 * (.cache_read // 0) + 1.25 * (.cache_creation // 0)),
                  unit: "weighted_tokens"} end;
        def median: sort | if length % 2 == 1 then .[length / 2 | floor]
                           else (.[length / 2 - 1] + .[length / 2]) / 2 end;
        def r($d): . * $d | round / $d;
        def rule($r; $b; $rule; $k; $floor): [$b[] | .[$k] | numbers] as $x
          | (if ($x | length) >= $min then ($x | median) else null end) as $m
          | ([$floor, (if ($m // 0) > 0 then $f * $m else null end)] | map(numbers) | max) as $lim
          | select($lim != null and ($r[$k] | type) == "number" and $r[$k] >= $lim)
          | {rule: $rule, value: ($r[$k] | r(100)), limit: ($lim | r(100)), median: ($m | if . then r(100) else null end),
             ratio: (if ($m // 0) > 0 then $r[$k] / $m | r(10) else null end)};
        map(. + cost) as $all
        | {newest: ($all | map(.ts) | max),
           reviews: [$all[] | select(.ts > $seen) as $r
             | [$all[] | select(.model == $r.model and .ts < $r.ts)][-$w:] as $b
             | [rule($r; $b; "cost"; "v"; null), rule($r; $b; "time"; "secs"; null),
                rule($r; $b; "context"; "peak_ctx"; null), rule($r; $b; "repeats"; "repeats"; $lim.repeats),
                rule($r; $b; "failures"; "failures"; $lim.failures), rule($r; $b; "output"; "max_out"; $lim.max_out)] as $why
             | select($why | length > 0)
             | {pr: $r.pr, sha: $r.sha, ts: $r.ts, model: $r.model, reasons: $why,
                unit: $r.unit, cost: ($r.v | r(100)), samples: ($b | length),
                secs: $r.secs, msgs: $r.msgs, subagents: $r.subagents,
                input: $r.input, output: $r.output, cache_read: $r.cache_read, cache_creation: $r.cache_creation,
                peak_ctx: $r.peak_ctx, repeats: $r.repeats, repeat_tool: $r.repeat_tool,
                max_out: $r.max_out, failures: $r.failures}]}' 2>/dev/null)"
      ANOMALY_NEWEST="$(printf '%s' "$ANOMALY_JUDGED" | jq -r '.newest // empty' 2>/dev/null)"
      if [ "$ANOMALY_STORE" = true ]; then
        printf '%s' "$ANOMALY_ALL" | jq -c --argjson w "$ANOMALY_WINDOW" \
          'group_by(.model) | map(.[-$w:]) | add // [] | sort_by(.ts) | .[]' \
          > "$REVIEW_USAGE.tmp" 2>/dev/null && mv "$REVIEW_USAGE.tmp" "$REVIEW_USAGE" 2>/dev/null
        rm -f "$REVIEW_USAGE.tmp" 2>/dev/null
      fi
      [ -n "$ANOMALY_NEWEST" ] && printf '%s\n' "$ANOMALY_NEWEST" > "$ANOMALY_MARKER" 2>/dev/null
      if [ "$(printf '%s' "$ANOMALY_JUDGED" | jq '.reviews | length' 2>/dev/null)" -gt 0 ] 2>/dev/null; then
        # kind and size from the review ledger, on stdin after the judged reviews
        ANOMALY_ALERT="$( { printf '%s\n' "$ANOMALY_JUDGED"; jq -cR 'fromjson? // empty | select(.src == "ledger")' "$LEDGER" 2>/dev/null; } \
          | jq -nc --argjson f "$ANOMALY_FACTOR" 'input as $j | [inputs] as $ledger
              | {factor: $f, reviews: [$j.reviews[] | . as $r
                  | ([$ledger[] | select(.pr == $r.pr and ((.sha // "") | startswith($r.sha)))] | last) as $l
                  | . + {kind: ($l.kind // null), size: ($l.size // null)}]}' 2>/dev/null)"
        [ -n "$ANOMALY_ALERT" ] || ANOMALY_ALERT="$(printf '%s' "$ANOMALY_JUDGED" | jq -c --argjson f "$ANOMALY_FACTOR" '{factor: $f, reviews}')"
        ANOMALY_LIST="$(printf '%s' "$ANOMALY_ALERT" | jq -r '[.reviews[] | "PR #\(.pr) (\([.reasons[].rule] | join("+")))"] | join(", ")')"
        log "review anomaly: $ANOMALY_LIST — alert due"
        logev warn review_anomaly "$ANOMALY_LIST"
      fi
    fi
    rmdir "$WORK/.review-anomaly.lock" 2>/dev/null
  fi
fi

# ------------------------------------------------------------- output ----
N_DUE="$(printf '%s' "$DUE" | jq length)"
NOTHING=true
{ [ "$N_DUE" -gt 0 ] || [ -n "$STALL_ALERT" ] || [ -n "$ANOMALY_ALERT" ]; } && NOTHING=false
[ "$N_DUE" -gt 0 ] && log "alerts due: $(printf '%s' "$DUE" | jq -r 'group_by(.kind)
  | map(.[0].kind + (if length > 1 then "×\(length)" else "" end)) | join(", ")')"
printf '%s\n' "$NOW_ISO monitor nothing_to_do=$NOTHING ${LOGS[*]:-}" >> "$WORK/HEARTBEAT.log" 2>/dev/null
# the audit's wake-up count reads these keys back (stats.wakeups)
logev info heartbeat "mode=monitor nothing_to_do=$NOTHING monitor=$N_DUE stall=$([ -n "$STALL_ALERT" ] && echo 1 || echo 0) anomaly=$([ -n "$ANOMALY_ALERT" ] && echo 1 || echo 0)"

SLACK="$(cfg slack_notifications)"
jq -n --argjson nothing "$NOTHING" --argjson due "$DUE" --argjson sup "$SUPPRESSED" \
  --argjson stall "${STALL_ALERT:-null}" --argjson anomaly "${ANOMALY_ALERT:-null}" \
  --arg slack "${SLACK:-disabled}" --arg eo "$(cfg escalation_owner)" --arg name "$(cfg bot_display_name)" \
  --argjson mt "$MODEL_THRESHOLD" --argjson ct "$CLASSIFIER_THRESHOLD" --argjson st "$STALL_ALERT_THRESHOLD" \
  --argjson raf "$ANOMALY_FACTOR" \
  --argjson logs "$(printf '%s\n' "${LOGS[@]:-}" | jq -R . | jq -s '[.[] | select(length>0)]')" '
  {mode: "monitor", nothing_to_do: $nothing, alerts_due: $due, suppressed: $sup, logs: $logs}
  + (if $stall == null then {} else {stall_alert: $stall} end)
  + (if $anomaly == null then {} else {review_anomaly: $anomaly} end)
  + {config: {slack_notifications: $slack,
       escalation_owner: (if $eo == "" then null else $eo end),
       bot_display_name: (if $name == "" then null else $name end),
       model_alert_threshold: $mt, classifier_alert_threshold: $ct, stall_alert_threshold: $st,
       review_anomaly_factor: $raf}}'
exit 0
