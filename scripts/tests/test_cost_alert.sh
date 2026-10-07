#!/usr/bin/env bash
# cost_alert: a review whose lock-to-done usage exceeds factor × the median of
# its model's previous reviews — baseline size, per-model grouping, pricing,
# the judged-once marker, the ledger join and the config off switch.
# Contract: docs/review-bookkeeping.md → Review cost alert.
. "$(dirname "$0")/helpers.sh"

SHA1="1111111111111111111111111111111111111111"

# one `review_cost` event, <secs> ago, for PR <n>
cost_event() { # <secs-ago> <pr> <output-tokens> [model]
  jq -nc --arg ts "$(iso_ago "$1")" --argjson n "$2" --argjson o "$3" --arg m "${4:-claude-opus-5-5}" \
    '{ts:$ts, run:"r", job:"review", level:"info", event:"review_cost",
      msg:("PR #\($n) abcdef1 secs=600 input=100 output=\($o) cache_read=0 cache_creation=0 msgs=40 model=\($m) subagents=3")}' \
    >> "$WORK/logs/events-$(date -u +%Y-%m-%d).jsonl"
}
# <count> baseline reviews of <output-tokens> each, 3–<count+2> h ago
baseline() { # <count> <output-tokens> [model]
  local i; for i in $(seq 1 "$1"); do cost_event $(( 7200 + i * 600 )) $(( 100 + i )) "$2" "${3:-}"; done
}

cost_case() { # <case-name> [extra config lines…]
  new_case "$1"; shift
  base_config "$@"
  mkdir -p "$WORK/logs"
  pr_json 1 "open PR" '[]' "$SHA1" | open_prs_fx
}

# --- an outlier over 4× the median → one alert entry -------------------------
cost_case cost_outlier
baseline 12 1000
cost_event 600 42 5000
run_preflight review
assert_jq '.cost_alert.factor == 4 and (.cost_alert.reviews | length) == 1' 'one review over the default factor'
assert_jq '.cost_alert.reviews[0] | .pr == 42 and .ratio == 4.9 and .samples == 12 and .unit == "weighted_tokens"' \
  'entry carries PR, ratio, samples; unpriced model is weighted'
assert_jq '.cost_alert.reviews[0] | .msgs == 40 and .subagents == 3 and .secs == 600' 'entry carries the breakdown'
assert_jq '.nothing_to_do == false and (.read_set | index("docs/review-bookkeeping.md"))' 'a due alert is work and reads its home'

# --- judged once: the next pass is silent ------------------------------------
run_preflight review
assert_jq '.cost_alert == null' 'a judged review never alerts twice'

# --- under the factor → silent -----------------------------------------------
cost_case cost_under
baseline 12 1000
cost_event 600 42 3900
run_preflight review
assert_jq '.cost_alert == null' '3.9× stays under the default factor'

# --- too few baseline reviews → silent ----------------------------------------
cost_case cost_few_samples
baseline 9 1000
cost_event 600 42 9000
run_preflight review
assert_jq '.cost_alert == null' 'fewer than 10 baseline reviews never alert'

# --- the baseline is the same model's ------------------------------------------
cost_case cost_per_model
baseline 12 1000 claude-sonnet-5-5
baseline 12 8000
cost_event 600 42 9000
run_preflight review
assert_jq '.cost_alert == null' 'a review is compared with its own model, not a cheaper one'

# --- priced model: USD and the configured factor --------------------------------
cost_case cost_priced '- cost_alert_factor: 2.5' '' '## Benchmark model prices' '' \
  '| model | input | output | cache_read | cache_write |' '| --- | --- | --- | --- | --- |' \
  '| opus | 5 | 25 | 0.5 | 6.25 |'
baseline 12 1000
cost_event 600 42 3000
run_preflight review
assert_jq '.cost_alert.factor == 2.5 and .cost_alert.reviews[0].unit == "usd"' 'priced in USD, factor 2.5 honoured'
assert_jq '.config.cost_alert_factor == 2.5' 'config object carries the factor'

# --- ledger join: kind and size --------------------------------------------------
cost_case cost_ledger
baseline 12 1000
cost_event 600 42 5000
printf '%s\n' '{"src":"ledger","pr":42,"ts":"2026-10-07T10:00:00Z","sha":"abcdef1234567890abcdef1234567890abcdef12","kind":"first","verdict":"APPROVE","size":{"files":40,"additions":1800,"deletions":20}}' \
  > "$WORK/REVIEW-LEDGER.jsonl"
run_preflight review
assert_jq '.cost_alert.reviews[0] | .kind == "first" and .size.additions == 1800' 'entry carries the ledger kind and size'

# --- first contact judges the last 24 h only -----------------------------------
cost_case cost_first_contact
baseline 12 1000
cost_event 7100 41 1000
jq -nc --arg ts "$(iso_ago 90000)" '{ts:$ts, run:"r", job:"review", level:"info", event:"review_cost",
  msg:"PR #40 abcdef1 secs=1 input=0 output=99999 cache_read=0 cache_creation=0 msgs=1 model=claude-opus-5-5 subagents=0"}' \
  >> "$WORK/logs/events-$(date -u +%Y-%m-%d).jsonl"
run_preflight review
assert_jq '.cost_alert == null' 'a review older than 24 h is not judged on first contact'
assert_file_contains "$WORK/.cost-alert-seen" "$(iso_ago 7100 | cut -c1-13)" 'the marker moves to the newest event'

# --- off switch ----------------------------------------------------------------
cost_case cost_off '- cost_alert_factor: off'
baseline 12 1000
cost_event 600 42 9000
run_preflight review
assert_jq '.cost_alert == null and .config.cost_alert_factor == 0' 'factor off disables the detector'

# --- unparseable value falls back to the documented default -------------------
cost_case cost_bad_value '- cost_alert_factor: banana'
baseline 12 1000
cost_event 600 42 5000
run_preflight review
assert_jq '.cost_alert.factor == 4' 'garbage factor falls back to 4'

# --- a fresh claim lock (live concurrent run) leaves the judgment to it --------
cost_case cost_fresh_lock
mkdir "$WORK/.cost-alert.lock"
baseline 12 1000
cost_event 600 42 5000
run_preflight review
assert_jq '.cost_alert == null' 'a live concurrent claim suppresses this run'

finish
