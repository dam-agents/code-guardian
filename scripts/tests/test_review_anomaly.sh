#!/usr/bin/env bash
# review_anomaly: a review whose cost, time or peak context exceeds factor ×
# the median of its model's previous reviews, or whose repeats, failures or
# largest tool result cross an absolute limit — baseline size, per-model
# grouping, pricing, the judged-once marker, the ledger join and the off switch.
# Contract: docs/review-bookkeeping.md → Review anomaly alert.
. "$(dirname "$0")/helpers.sh"

SHA1="1111111111111111111111111111111111111111"

# one `review_cost` event, <secs> ago, for PR <n>; extra key=value pairs
# override the defaults
cost_event() { # <secs-ago> <pr> <output-tokens> [model] [key=value…]
  local ago="$1" pr="$2" out="$3" model="${4:-claude-opus-5-5}" kv
  shift 3; [ $# -gt 0 ] && shift
  kv="secs=600 input=100 output=$out cache_read=0 cache_creation=0 msgs=40 model=$model subagents=3 peak_ctx=50000 repeats=2 repeat_tool=Bash max_out=4000 failures=0"
  for o in "$@"; do kv="$(printf '%s' "$kv" | sed -E "s/(^| )${o%%=*}=[^ ]+/\1$o/")"; done
  jq -nc --arg ts "$(iso_ago "$ago")" --argjson n "$pr" --arg kv "$kv" \
    '{ts:$ts, run:"r", job:"review", level:"info", event:"review_cost",
      msg:("PR #\($n) abcdef1 " + $kv)}' \
    >> "$WORK/logs/events-$(date -u +%Y-%m-%d).jsonl"
}
# <count> baseline reviews of <output-tokens> each, 2–<count+2> h ago
baseline() { # <count> <output-tokens> [model]
  local i; for i in $(seq 1 "$1"); do cost_event $(( 7200 + i * 600 )) $(( 100 + i )) "$2" "${3:-}"; done
}
rules() { printf '%s' "$OUT" | jq -c '[.review_anomaly.reviews[0].reasons[].rule]' 2>/dev/null; }
assert_rules() { # <json array> <description>
  if [ "$(rules)" = "$1" ]; then printf 'ok   %s: %s\n' "$CASE" "$2"
  else printf 'FAIL %s: %s (want %s, got %s)\n' "$CASE" "$2" "$1" "$(rules)"; FAILED=1; fi
}

anomaly_case() { # <case-name> [extra config lines…]
  new_case "$1"; shift
  base_config "$@"
  mkdir -p "$WORK/logs"
  pr_json 1 "open PR" '[]' "$SHA1" | open_prs_fx
}

# --- a cost outlier over 4× the median → one entry, reason cost ---------------
anomaly_case anomaly_cost
baseline 12 1000
cost_event 600 42 5000
run_preflight review
assert_jq '.review_anomaly.factor == 4 and (.review_anomaly.reviews | length) == 1' 'one review over the default factor'
assert_rules '["cost"]' 'the reason is cost'
assert_jq '.review_anomaly.reviews[0] | .pr == 42 and .reasons[0].ratio == 4.9 and .samples == 12 and .unit == "weighted_tokens"' \
  'entry carries PR, ratio, samples; unpriced model is weighted'
assert_jq '.review_anomaly.reviews[0] | .msgs == 40 and .subagents == 3 and .secs == 600 and .repeat_tool == "Bash"' \
  'entry carries the breakdown'
assert_jq '.nothing_to_do == false and (.read_set | index("docs/review-bookkeeping.md"))' 'a due alert is work and reads its home'

# --- judged once: the next pass is silent ------------------------------------
run_preflight review
assert_jq '.review_anomaly == null' 'a judged review never alerts twice'

# --- under every limit → silent ------------------------------------------------
anomaly_case anomaly_none
baseline 12 1000
cost_event 600 42 3900 '' secs=2000 peak_ctx=150000 repeats=7 failures=4 max_out=199999
run_preflight review
assert_jq '.review_anomaly == null' 'values just under each limit stay silent'

# --- the median rules: time and context ----------------------------------------
anomaly_case anomaly_time_context
baseline 12 1000
cost_event 600 42 1000 '' secs=3000 peak_ctx=250000
run_preflight review
assert_rules '["time","context"]' 'time and peak context over 4× their medians'

# --- the absolute rules apply without a baseline --------------------------------
anomaly_case anomaly_absolute
cost_event 600 42 1000 '' repeats=8 failures=5 max_out=200000
run_preflight review
assert_rules '["repeats","failures","output"]' 'repeats, failures and output at their limits, no baseline needed'
assert_jq '.review_anomaly.reviews[0].reasons[0].limit == 8' 'an absolute reason carries its limit'

# --- a repo whose norm is higher raises the limit above the floor -------------
anomaly_case anomaly_adaptive
for i in $(seq 1 12); do cost_event $(( 7200 + i * 600 )) $(( 100 + i )) 1000 '' repeats=6 failures=2; done
cost_event 600 42 1000 '' repeats=20 failures=7
run_preflight review
assert_jq '.review_anomaly == null' 'repeats 20 and failures 7 stay under 4× a median of 6 and 2'
cost_event 300 43 1000 '' repeats=24
run_preflight review
assert_jq '.review_anomaly.reviews[0].reasons == [{rule:"repeats", value:24, limit:24, median:6, ratio:4}]' \
  'the limit is factor × the repo median once it exceeds the floor'

# --- the baseline outlives the event retention ----------------------------------
anomaly_case anomaly_durable_baseline
baseline 12 1000
cost_event 600 41 1000
run_preflight review
if [ "$(wc -l < "$WORK/REVIEW-USAGE.jsonl" | tr -d ' ')" = 13 ]; then printf 'ok   %s: the baseline file holds every review\n' "$CASE"
else printf 'FAIL %s: baseline file has %s rows\n' "$CASE" "$(wc -l < "$WORK/REVIEW-USAGE.jsonl")"; FAILED=1; fi
rm -f "$WORK"/logs/events-*.jsonl
cost_event 60 42 5000
run_preflight review
assert_rules '["cost"]' 'with the event log gone, the stored baseline still judges a review'

# --- the baseline keeps the last 30 reviews per model -----------------------------
anomaly_case anomaly_baseline_cap
baseline 35 1000
for i in 1 2 3; do cost_event $(( 7300 + i * 600 )) $(( 300 + i )) 1000 claude-sonnet-5-5; done
run_preflight review
if [ "$(wc -l < "$WORK/REVIEW-USAGE.jsonl" | tr -d ' ')" = 33 ]; then printf 'ok   %s: 30 per model are kept\n' "$CASE"
else printf 'FAIL %s: baseline file has %s rows\n' "$CASE" "$(wc -l < "$WORK/REVIEW-USAGE.jsonl")"; FAILED=1; fi

# --- too few baseline reviews → no median rule -----------------------------------
anomaly_case anomaly_few_samples
baseline 9 1000
cost_event 600 42 9000
run_preflight review
assert_jq '.review_anomaly == null' 'fewer than 10 baseline reviews never apply a median rule'

# --- the baseline is the same model's ------------------------------------------
anomaly_case anomaly_per_model
for i in $(seq 1 12); do cost_event $(( 7300 + i * 600 )) $(( 300 + i )) 1000 claude-sonnet-5-5; done
baseline 12 8000
cost_event 600 42 9000
run_preflight review
assert_jq '.review_anomaly == null' 'a review is compared with its own model, not a cheaper one'

# --- priced model: USD and the configured factor --------------------------------
anomaly_case anomaly_priced '- review_anomaly_factor: 2.5' '' '## Benchmark model prices' '' \
  '| model | input | output | cache_read | cache_write |' '| --- | --- | --- | --- | --- |' \
  '| opus | 5 | 25 | 0.5 | 6.25 |'
baseline 12 1000
cost_event 600 42 3000
run_preflight review
assert_jq '.review_anomaly.factor == 2.5 and .review_anomaly.reviews[0].unit == "usd"' 'priced in USD, factor 2.5 honoured'
assert_jq '.config.review_anomaly_factor == 2.5' 'config object carries the factor'

# --- ledger join: kind and size --------------------------------------------------
anomaly_case anomaly_ledger
baseline 12 1000
cost_event 600 42 5000
printf '%s\n' '{"src":"ledger","pr":42,"ts":"2026-10-07T10:00:00Z","sha":"abcdef1234567890abcdef1234567890abcdef12","kind":"first","verdict":"APPROVE","size":{"files":40,"additions":1800,"deletions":20}}' \
  > "$WORK/REVIEW-LEDGER.jsonl"
run_preflight review
assert_jq '.review_anomaly.reviews[0] | .kind == "first" and .size.additions == 1800' 'entry carries the ledger kind and size'

# --- first contact judges the last 24 h only -----------------------------------
anomaly_case anomaly_first_contact
baseline 12 1000
cost_event 7100 41 1000
cost_event 90000 40 99999 '' repeats=50
run_preflight review
assert_jq '.review_anomaly == null' 'a review older than 24 h is not judged on first contact'
assert_file_contains "$WORK/.review-anomaly-seen" "$(iso_ago 7100 | cut -c1-13)" 'the marker moves to the newest event'

# --- off switch ----------------------------------------------------------------
anomaly_case anomaly_off '- review_anomaly_factor: off'
cost_event 600 42 9000 '' repeats=50
run_preflight review
assert_jq '.review_anomaly == null and .config.review_anomaly_factor == 0' 'factor off disables the detector'

# --- unparseable value falls back to the documented default -------------------
anomaly_case anomaly_bad_value '- review_anomaly_factor: banana'
baseline 12 1000
cost_event 600 42 5000
run_preflight review
assert_jq '.review_anomaly.factor == 4' 'garbage factor falls back to 4'

# --- a fresh claim lock (live concurrent run) leaves the judgment to it --------
anomaly_case anomaly_fresh_lock
mkdir "$WORK/.review-anomaly.lock"
cost_event 600 42 5000 '' repeats=50
run_preflight review
assert_jq '.review_anomaly == null' 'a live concurrent claim suppresses this run'

# --- the weekly audit reports the review shape, this week and the one before ---
anomaly_case anomaly_audit_shape
for i in 1 2 3; do cost_event $(( 8 * 86400 + i * 600 )) $(( 200 + i )) 1000 '' repeats=2 peak_ctx=40000; done
for i in 1 2 3 4 5; do cost_event $(( 7200 + i * 600 )) $(( 100 + i )) 1000 '' repeats=$(( 2 + i )) peak_ctx=60000; done
jq -nc --arg ts "$(iso_ago 3600)" '{ts:$ts, run:"r", job:"review", level:"warn", event:"review_anomaly",
  msg:"PR #101 (repeats), PR #102 (cost+time)"}' >> "$WORK/logs/events-$(date -u +%Y-%m-%d).jsonl"
run_preflight review
run_preflight audit
assert_jq '.stats.review_shape.week | .reviews == 5 and .median.repeats == 5 and .median.peak_ctx == 60000' 'this week: count and medians'
assert_jq '.stats.review_shape.previous | .reviews == 3 and .median.repeats == 2 and .median.peak_ctx == 40000' 'the week before, from the retained log'
assert_jq '.stats.review_shape.anomalies == 2' 'the week counts the reviews its anomaly alerts named'
assert_jq '.stats.review_shape.baseline == {"claude-opus-5-5": 8} and .stats.review_shape.baseline_min == 10' \
  'the stored baseline per model, seeded from every retained event, against the minimum'

finish
