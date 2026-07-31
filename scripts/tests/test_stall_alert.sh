#!/usr/bin/env bash
# stall_alert: the 24h stalled-review rate detector — threshold, PR list,
# once-per-day dedup, window boundary, and the config off switch.
# Contract: docs/review.md → Stalled-review rate alert.
. "$(dirname "$0")/helpers.sh"

SHA1="1111111111111111111111111111111111111111"

# one `stale in_progress lock` takeover event, <secs> ago, for PR <n>
stall_event() { # <secs-ago> <pr>
  jq -nc --arg ts "$(iso_ago "$1")" --argjson n "$2" \
    '{ts:$ts, run:"r", job:"review", level:"info", event:"preflight",
      msg:("PR #" + ($n|tostring) + ": stale in_progress lock (39m) — takeover")}' \
    >> "$WORK/logs/events-$(date -u +%Y-%m-%d).jsonl"
}

stall_case() { # <case-name> [extra config lines…]
  new_case "$1"; shift
  base_config "$@"
  mkdir -p "$WORK/logs"
  pr_json 1 "open PR" '[]' "$SHA1" | open_prs_fx
}

# --- below threshold → silent --------------------------------------------------
stall_case stall_below
stall_event 3600 10
stall_event 7200 11
stall_event 10800 10
run_preflight review
assert_jq '.stall_alert == null' '3 stalls stay under the default threshold of 4'

# --- at threshold → one alert, distinct PRs listed -----------------------------
stall_case stall_at_threshold
stall_event 3600 10
stall_event 7200 11
stall_event 10800 10
stall_event 14400 12
run_preflight review
assert_jq '.stall_alert.count == 4 and .stall_alert.threshold == 4 and .stall_alert.window_hours == 24' 'alert carries count + threshold'
assert_jq '.stall_alert.prs | sort == [10,11,12]' 'distinct PRs listed, deduped'
assert_jq '.stall_alert.per_day_7d | type == "array" and length >= 1 and (.[-1].stalls == 4)' 'per-day trend included'
assert_file_contains "$WORK/.stall-alert-day" "$(date -u +%Y-%m-%d)" 'marker records the alert day'
if [ ! -d "$WORK/.stall-alert.lock" ]; then
  printf 'ok   %s: %s\n' "$CASE" 'dedup lock released'
else
  printf 'FAIL %s: dedup lock left behind\n' "$CASE"; FAILED=1
fi

# --- dedup: the same day never alerts twice -----------------------------------
run_preflight review
assert_jq '.stall_alert == null' 'second run the same day is deduped'

# --- a due alert is work on its own, with nothing else to do -------------------
# no open PRs at all, so the alert is the only reason this run isn't idle
stall_case stall_alone
printf '[]' | fx "api repos/$TEST_REPO/pulls?state=open&per_page=100"
for s in 3600 7200 10800 14400; do stall_event "$s" 10; done
run_preflight review
assert_jq '.stall_alert.count == 4' 'alert fires with no open PRs'
assert_jq '.nothing_to_do == false' 'a due alert alone makes the run non-idle'

# --- events older than the window are ignored ---------------------------------
stall_case stall_window
stall_event 3600 10
stall_event 90000 11    # 25h ago — outside the 24h window
stall_event 100000 12
stall_event 110000 13
run_preflight review
assert_jq '.stall_alert == null' 'stalls older than 24h do not count'

# --- an earlier alert day does not suppress today ------------------------------
stall_case stall_marker_stale
printf '2020-01-01\n' > "$WORK/.stall-alert-day"
for s in 3600 7200 10800 14400; do stall_event "$s" 10; done
run_preflight review
assert_jq '.stall_alert.count == 4' 'a stale marker day still alerts'

# --- explicit threshold honoured ----------------------------------------------
stall_case stall_custom_threshold '- stall_alert_threshold: 2'
stall_event 3600 10
stall_event 7200 11
run_preflight review
assert_jq '.stall_alert.count == 2 and .stall_alert.threshold == 2' 'configured threshold of 2 fires'

# --- off switch ----------------------------------------------------------------
stall_case stall_off '- stall_alert_threshold: off'
for s in 3600 7200 10800 14400 18000; do stall_event "$s" 10; done
run_preflight review
assert_jq '.stall_alert == null' 'threshold off disables the detector'

# --- unparseable value falls back to the documented default -------------------
stall_case stall_bad_value '- stall_alert_threshold: banana'
for s in 3600 7200 10800 14400; do stall_event "$s" 10; done
run_preflight review
assert_jq '.stall_alert.threshold == 4' 'garbage threshold falls back to 4'

# --- a stale claim lock (killed run) is removed, the alert still fires --------
stall_case stall_stale_lock
mkdir "$WORK/.stall-alert.lock"
touch -t 202001010000 "$WORK/.stall-alert.lock"
for s in 3600 7200 10800 14400; do stall_event "$s" 10; done
run_preflight review
assert_jq '.stall_alert.count == 4' 'a lock left by a killed run does not suppress the alert'

# --- a fresh claim lock (live concurrent run) still dedups ---------------------
stall_case stall_fresh_lock
mkdir "$WORK/.stall-alert.lock"
for s in 3600 7200 10800 14400; do stall_event "$s" 10; done
run_preflight review
assert_jq '.stall_alert == null' 'a live concurrent claim suppresses this run'

# --- unrelated preflight lines are not counted --------------------------------
stall_case stall_no_false_positives
for s in 3600 7200 10800 14400; do
  jq -nc --arg ts "$(iso_ago "$s")" \
    '{ts:$ts, run:"r", job:"review", level:"info", event:"preflight",
      msg:"PR #10: fresh in_progress lock (9m) — skipped"}' \
    >> "$WORK/logs/events-$(date -u +%Y-%m-%d).jsonl"
done
run_preflight review
assert_jq '.stall_alert == null' 'fresh-lock skips are not stalls'

finish
