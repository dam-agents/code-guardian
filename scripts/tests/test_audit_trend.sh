#!/usr/bin/env bash
# audit-trend.sh — the weekly trend artifact: append, backfill, pricing and
# the rendered report (docs/trends.md). Fully offline; no gh, no preflight.
. "$(dirname "$0")/helpers.sh"

TREND="$REPO_ROOT/scripts/audit-trend.sh"

# a worklist with the audit stats a real run produces
worklist() { # <reviews> <new findings> <fixed> <still> [model]
  jq -n --argjson rv "$1" --argjson nf "$2" --argjson fx "$3" --argjson sp "$4" \
        --arg model "${5:-claude-opus-5}" '
    {mode:"audit", nothing_to_do:false,
     stats:{since:"2026-09-02T07:00:00Z", open_prs:5, awaiting_label:{n:2, oldest_days:6},
       reviews:{total:$rv, first:$rv, re_review:0, approve:$rv, comment:0, request_changes:0,
                duration:{n:$rv, median_min:6},
                phases:{skills:{n:$rv, median_min:4}, compose:{n:$rv, median_min:1}}},
       findings:{fixed:$fx, still_present:$sp, json_reviews:$rv, new:$nf,
                 new_by_severity:{critical:1, warning:2, suggestion:($nf - 3)}},
       heartbeats:{total:100, idle:80}, log_events:{errors:1, warns:2},
       tokens:{runs:100, input:1000, output:2000, cache_read:3000, cache_creation:4000,
               by_model:{($model):{runs:100, input:1000, output:2000, cache_read:3000, cache_creation:4000}}},
       stalls:{total:10, stalled:1, wasted_output_tokens:500},
       reactions:{up:3, down:1, down_urls:[], scanned:9}},
     checks:[{id:"a",status:"ok",detail:""},{id:"b",status:"warn",detail:""}], failures:[], logs:[]}'
}

price_config() { # [extra price rows…]
  {
    printf -- '- audit_trend: dam\n\n'
    printf '## Benchmark model prices\n\n'
    printf '| model substring | input | output | cache_read | cache_write |\n'
    printf '|---|---|---|---|---|\n'
    printf '| claude-opus-5 | 15 | 75 | 1.5 | 18.75 |\n'
  } > "$WORK/CONFIG.md"
}

run_trend() { # <mode> [args…] — output in $OUT
  OUT="$(TREND_CONFIG="$WORK/CONFIG.md" HOME="$FAKE_HOME" bash "$TREND" "$@" 2>&1)"
}

# --- append writes one week file and the derived TRENDS.md --------------------
new_case trend_append
price_config
mkdir -p "$WORK/audit"
worklist 12 31 9 4 > "$WORK/audit/last-worklist.json"
printf '{"ttfr_median_min":14,"model":"claude-opus-5","memory_lines":96}\n' > "$WORK/extras.json"
run_trend append "$WORK/audit" "$WORK/extras.json"
assert_out_contains 'trend 20' 'append prints the week delta line'
assert_out_contains 'surfaces=dam' 'append reports the resolved publish surfaces'
if [ "$(ls "$WORK/audit/weeks"/*.json 2>/dev/null | grep -c .)" = "1" ]; then
  printf 'ok   %s: one week file written\n' "$CASE"
else printf 'FAIL %s: expected exactly one week file\n' "$CASE"; FAILED=1; fi
assert_file_contains "$WORK/audit/TRENDS.md" '^| week | src |' 'TRENDS.md carries the table header'
assert_file_contains "$WORK/audit/TRENDS.md" '| 12 (12/0) |' 'the week row carries the review counts'
assert_file_contains "$WORK/audit/TRENDS.md" '| 31 (1/2/28) |' 'raised findings split by severity'
# 1000*15 + 2000*75 + 3000*1.5 + 4000*18.75 = 244,500 / 1e6 = 0.24 USD
assert_file_contains "$WORK/audit/TRENDS.md" '| 0.24 |' 'tokens priced from the CONFIG table'
run_trend index "$WORK/audit"
printf '%s' "$OUT" | jq -e '.[0].acceptance == 0.69 and .[0].ttfr_min == 14 and .[0].cost_floor == false' >/dev/null 2>&1 \
  && printf 'ok   %s: derived row carries acceptance, ttfr and an exact cost\n' "$CASE" \
  || { printf 'FAIL %s: derived row wrong: %s\n' "$CASE" "$OUT"; FAILED=1; }

# --- an unpriced model makes the cost a floor, never a guess ------------------
new_case trend_cost_floor
price_config
mkdir -p "$WORK/audit"
worklist 4 8 2 2 "some-other-model" > "$WORK/audit/last-worklist.json"
run_trend append "$WORK/audit"
run_trend index "$WORK/audit"
printf '%s' "$OUT" | jq -e '.[0].cost_usd == null and .[0].cost_per_review == null' >/dev/null 2>&1 \
  && printf 'ok   %s: no matching price row leaves the cost unset\n' "$CASE" \
  || { printf 'FAIL %s: expected an unpriced week: %s\n' "$CASE" "$OUT"; FAILED=1; }
assert_file_contains "$WORK/audit/TRENDS.md" '| — | — |' 'the unpriced week renders "—", not 0'

# --- a mixed week is a floor -------------------------------------------------
new_case trend_cost_partial
price_config
mkdir -p "$WORK/audit"
worklist 4 8 2 2 > "$WORK/audit/last-worklist.json"
jq '.stats.tokens.by_model["mystery-model"] = {runs:1,input:10,output:10,cache_read:10,cache_creation:10}' \
  "$WORK/audit/last-worklist.json" > "$WORK/audit/wl.json" && mv "$WORK/audit/wl.json" "$WORK/audit/last-worklist.json"
run_trend append "$WORK/audit"
run_trend index "$WORK/audit"
printf '%s' "$OUT" | jq -e '.[0].cost_usd == 0.24 and .[0].cost_floor == true' >/dev/null 2>&1 \
  && printf 'ok   %s: priced models counted, the cell flagged a floor\n' "$CASE" \
  || { printf 'FAIL %s: expected a flagged floor: %s\n' "$CASE" "$OUT"; FAILED=1; }
assert_file_contains "$WORK/audit/TRENDS.md" '≥0.24' 'the floor marker reaches the row'

# --- backfill reconstructs weeks from the review history ---------------------
new_case trend_backfill
price_config
mkdir -p "$WORK/audit"
cat > "$WORK/reviews/pr-1.md" <<'MD'
# PR #1: first

## Review at aaaaaaa — 2026-08-11T09:00:00Z — COMMENT
<!-- findings-json: [{"status":"new","severity":"warning","file":"a.ts","line":1,"summary":"x","fix":"y"},{"status":"new","severity":"suggestion","file":"a.ts","line":2,"summary":"x","fix":null}] -->

## Review at bbbbbbb — 2026-08-13T09:00:00Z — APPROVE
- ✅ **Fixed:** null check added (`a.ts:1`)
<!-- findings-json: [{"status":"fixed","severity":"warning","file":"a.ts","line":1,"summary":"x","fix":null}] -->
MD
cat > "$WORK/reviews/pr-2.md" <<'MD'
# PR #2: later week

## Review at ccccccc — 2026-08-20T09:00:00Z — REQUEST_CHANGES
- 🔁 **Still present:** unbounded retry (`c.ts:30`)
<!-- findings-json: [{"status":"new","severity":"critical","file":"c.ts","line":30,"summary":"x","fix":"y"}] -->
MD
run_trend backfill "$WORK/audit" "$WORK/reviews"
assert_out_contains 'backfill: 2 week(s) written' 'both history weeks reconstructed'
run_trend index "$WORK/audit"
printf '%s' "$OUT" | jq -e 'length == 2 and (.[0].source == "backfill")
  and (.[0].reviews == 2 and .[0].first == 1 and .[0].re_review == 1 and .[0].findings_new == 2)
  and (.[1].reviews == 1 and .[1].request_changes == 1 and .[1].f_critical == 1)' >/dev/null 2>&1 \
  && printf 'ok   %s: counts and verdicts rebuilt per ISO week\n' "$CASE" \
  || { printf 'FAIL %s: backfill rows wrong: %s\n' "$CASE" "$OUT"; FAILED=1; }
printf '%s' "$OUT" | jq -e '.[0].cost_usd == null and .[0].ttfr_min == null and .[0].heartbeats == null' >/dev/null 2>&1 \
  && printf 'ok   %s: log-derived metrics stay unmeasured in a backfilled week\n' "$CASE" \
  || { printf 'FAIL %s: backfill invented log metrics: %s\n' "$CASE" "$OUT"; FAILED=1; }
# re-running writes nothing new, and an audit week supersedes its backfill row
run_trend backfill "$WORK/audit" "$WORK/reviews"
assert_out_contains 'backfill: 0 week(s) written, 2 already on record' 'backfill never overwrites a recorded week'

# --- an audit row supersedes the backfill row of the same week ---------------
new_case trend_supersede
price_config
mkdir -p "$WORK/audit/weeks"
week="$(date -u +%G-W%V)"
jq -n --arg w "$week" '{ts:"2026-01-01T00:00:00Z", week:$w, source:"backfill",
  stats:{reviews:{total:1, first:1, re_review:0}}, checks:null, extras:{}}' \
  > "$WORK/audit/weeks/$week-backfill.json"
worklist 9 12 3 1 > "$WORK/audit/last-worklist.json"
run_trend append "$WORK/audit"
run_trend index "$WORK/audit"
printf '%s' "$OUT" | jq -e 'length == 1 and .[0].source == "audit" and .[0].reviews == 9' >/dev/null 2>&1 \
  && printf 'ok   %s: the measured row replaces the reconstructed one\n' "$CASE" \
  || { printf 'FAIL %s: supersede failed: %s\n' "$CASE" "$OUT"; FAILED=1; }

# --- report renders offline, keeps publish markers, states unmeasured --------
new_case trend_report
price_config
mkdir -p "$WORK/audit"
worklist 6 10 4 1 > "$WORK/audit/last-worklist.json"
run_trend append "$WORK/audit"
printf '# Weekly trends\n<!-- audit-trend-dam: abc123 -->\n' > "$WORK/audit/TRENDS.md.seed"
{ head -1 "$WORK/audit/TRENDS.md.seed"; sed -n '2p' "$WORK/audit/TRENDS.md.seed"; tail -n +2 "$WORK/audit/TRENDS.md"; } \
  > "$WORK/audit/TRENDS.md.new" && mv "$WORK/audit/TRENDS.md.new" "$WORK/audit/TRENDS.md"
run_trend append "$WORK/audit"
assert_file_contains "$WORK/audit/TRENDS.md" 'audit-trend-dam: abc123' 'the publish marker survives regeneration'
OUT="$(TREND_CONFIG="$WORK/CONFIG.md" HOME="$FAKE_HOME" bash "$TREND" report "$WORK/audit")"
assert_out_contains '<title>Weekly trends</title>' 'report renders a self-contained page'
assert_out_contains '<circle cx=' 'the charts render from the recorded weeks'
assert_out_absent 'http://|https://[a-z]' 'the page loads no external asset'

# --- a missing worklist appends nothing --------------------------------------
new_case trend_no_worklist
price_config
mkdir -p "$WORK/audit"
OUT="$(TREND_CONFIG="$WORK/CONFIG.md" HOME="$FAKE_HOME" bash "$TREND" append "$WORK/audit" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && [ ! -d "$WORK/audit/weeks" ]; then
  printf 'ok   %s: no worklist is an error, not an empty week\n' "$CASE"
else printf 'FAIL %s: expected a non-zero exit and no weeks dir (rc=%s)\n' "$CASE" "$rc"; FAILED=1; fi

finish
