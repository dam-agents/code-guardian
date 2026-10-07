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

# --- the surface reader drops an inline comment, as preflight's cfg() does ----
new_case trend_surface_comment
mkdir -p "$WORK/audit"
printf -- '- audit_trend: off   # publishes nothing\n' > "$WORK/CONFIG.md"
worklist 1 3 0 0 > "$WORK/audit/last-worklist.json"
printf '{}\n' > "$WORK/extras.json"
run_trend append "$WORK/audit" "$WORK/extras.json"
assert_out_contains 'surfaces=off' 'an inline comment does not turn off into dam'

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

# --- actual spend rides in on extras, beside the estimate --------------------
new_case trend_actual_cost
price_config
mkdir -p "$WORK/audit"
worklist 4 8 2 2 > "$WORK/audit/last-worklist.json"
printf '{"actual_cost_usd":0.08,"model":"claude-opus-5"}\n' > "$WORK/extras.json"
run_trend append "$WORK/audit" "$WORK/extras.json"
run_trend index "$WORK/audit"
printf '%s' "$OUT" | jq -e '.[0].cost_usd == 0.24 and .[0].actual_cost_usd == 0.08' >/dev/null 2>&1 \
  && printf 'ok   %s: the estimate and the attributed actual are both derived\n' "$CASE" \
  || { printf 'FAIL %s: expected est 0.24 beside actual 0.08: %s\n' "$CASE" "$OUT"; FAILED=1; }
assert_file_contains "$WORK/audit/TRENDS.md" '| 0.24 | 0.08 |' 'both spend columns reach the week row'
OUT="$(TREND_CONFIG="$WORK/CONFIG.md" HOME="$FAKE_HOME" bash "$TREND" report "$WORK/audit")"
assert_out_contains 'Spend per week (actual)' 'the report carries the actual-spend summary row'
assert_out_contains '<th class="n" title="Actual spend' 'the report table carries the actual-spend column'
assert_out_contains '<td class="n">0.08' 'the week row carries the attributed actual'

# --- wake-ups by work reach the index, TRENDS.md and the report --------------
new_case trend_wakeups
price_config
mkdir -p "$WORK/audit"
worklist 4 8 2 2 > "$WORK/audit/last-worklist.json"
jq '.stats.wakeups = {runs:20, by_mode:{review:18, shepherd:2},
      by_work:{reviews:{runs:4, items:4}, mentions:{runs:6, items:7}, artifacts:{runs:3, items:3}},
      unlabelled:0}' "$WORK/audit/last-worklist.json" > "$WORK/audit/wl.json" \
  && mv "$WORK/audit/wl.json" "$WORK/audit/last-worklist.json"
run_trend append "$WORK/audit"
run_trend index "$WORK/audit"
printf '%s' "$OUT" | jq -e '.[0].wakeups == 20 and .[0].wake_reviews == 4
  and .[0].wake_mentions == 6 and .[0].wake_artifacts == 3' >/dev/null 2>&1 \
  && printf 'ok   %s: the derived row carries the wake-ups by work\n' "$CASE" \
  || { printf 'FAIL %s: wake-ups not derived: %s\n' "$CASE" "$OUT"; FAILED=1; }
assert_file_contains "$WORK/audit/TRENDS.md" '| 20 (4/6/3) |' 'the week row carries the wake-ups'
OUT="$(TREND_CONFIG="$WORK/CONFIG.md" HOME="$FAKE_HOME" bash "$TREND" report "$WORK/audit")"
assert_out_contains 'Wake-ups by work' 'the report carries the wake-ups chart'
assert_out_contains '<th class="n" title="Count of runs that found work' 'the report table explains the wake-ups column'

# a week recorded before the metric renders a dash, never a zero
new_case trend_wakeups_absent
price_config
mkdir -p "$WORK/audit"
worklist 4 8 2 2 > "$WORK/audit/last-worklist.json"
run_trend append "$WORK/audit"
run_trend index "$WORK/audit"
printf '%s' "$OUT" | jq -e '.[0].wakeups == null' >/dev/null 2>&1 \
  && printf 'ok   %s: an unmeasured week has no wake-up count\n' "$CASE" \
  || { printf 'FAIL %s: wake-ups invented: %s\n' "$CASE" "$OUT"; FAILED=1; }

# --- the week table: newest first, headers aligned and explained ------------
new_case trend_report_layout
price_config
mkdir -p "$WORK/audit"
worklist 4 8 2 2 > "$WORK/audit/last-worklist.json"
run_trend append "$WORK/audit"
f="$(ls "$WORK/audit/weeks"/*.json | head -1)"
jq -c '.week = "2000-W01" | .ts = "2000-01-03T07:00:00Z"' "$f" > "$WORK/audit/weeks/20000103T070000Z.json"
OUT="$(TREND_CONFIG="$WORK/CONFIG.md" HOME="$FAKE_HOME" bash "$TREND" report "$WORK/audit")"
first="$(printf '%s\n' "$OUT" | grep -m1 -o '^<tr><td>[0-9]*-W[0-9]*' | sed 's/<tr><td>//')"
[ -n "$first" ] && [ "$first" != "2000-W01" ] \
  && printf 'ok   %s: the newest week is the first row\n' "$CASE" \
  || { printf 'FAIL %s: expected the newest week first, got %s\n' "$CASE" "$first"; FAILED=1; }
assert_out_contains '<th data-d="d" title="ISO week' 'the week column starts sorted newest first'
[ "$(printf '%s' "$OUT" | grep -o '<th[^>]* data-d=' | wc -l | tr -d ' ')" = 1 ] \
  && printf 'ok   %s: only the week column carries the sort state\n' "$CASE" \
  || { printf 'FAIL %s: expected one sorted column\n' "$CASE"; FAILED=1; }
assert_out_contains 'if(open&&open===document.activeElement)show(open)' 'a scroll keeps the bubble of the focused element'
assert_out_contains '<th class="n" title="Count of reviews posted' 'a numeric header aligns with its cells and carries help'
assert_out_contains 'th.n{text-align:right}' 'numeric headers are right-aligned'
assert_out_contains '<td title="Count of reviews posted in the week' 'a summary metric name carries help'
assert_out_contains 'class="hit" x="34"' 'a chart carries one hover band per week, inside the plot'
assert_out_contains 'data-label="2000-W01"><title>2000-W01' 'a hover band names its week and its values'

# --- a week with no telemetry renders "—", never a zero ----------------------
new_case trend_actual_cost_absent
price_config
mkdir -p "$WORK/audit"
worklist 4 8 2 2 > "$WORK/audit/last-worklist.json"
run_trend append "$WORK/audit"
run_trend index "$WORK/audit"
printf '%s' "$OUT" | jq -e '.[0].actual_cost_usd == null' >/dev/null 2>&1 \
  && printf 'ok   %s: no extras key leaves actual spend unmeasured\n' "$CASE" \
  || { printf 'FAIL %s: expected actual_cost_usd null: %s\n' "$CASE" "$OUT"; FAILED=1; }
assert_file_contains "$WORK/audit/TRENDS.md" '| 0.24 | — |' 'the unmeasured actual renders "—" beside the estimate'

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
assert_out_contains 'class="hit" x="34" y="10" width="282"' 'the hover band of the only week covers the full plot'
assert_out_absent 'http://|https://[a-z]' 'the page loads no external asset'

# --- a missing worklist appends nothing --------------------------------------
new_case trend_no_worklist
price_config
mkdir -p "$WORK/audit"
OUT="$(TREND_CONFIG="$WORK/CONFIG.md" HOME="$FAKE_HOME" bash "$TREND" append "$WORK/audit" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && [ ! -d "$WORK/audit/weeks" ]; then
  printf 'ok   %s: no worklist is an error, not an empty week\n' "$CASE"
else printf 'FAIL %s: expected a non-zero exit and no weeks dir (rc=%s)\n' "$CASE" "$rc"; FAILED=1; fi

# --- verdict shares, disk and run figures (docs/trends.md → Runs) ---------------
new_case trend_runs_disk_verdicts
price_config
mkdir -p "$WORK/audit"
worklist 10 5 0 0 | jq '.stats.reviews += {first:8, approve:6, request_changes:1, first_approve:4, first_request_changes:1}
  | .stats.disk = {volumes:[{role:"work", mount:"/w", size_kb:100, avail_kb:20, used_pct:80, inode_pct:3},
                            {role:"tmp", mount:"/t", size_kb:100, avail_kb:50, used_pct:50, inode_pct:9}], work_kb:20480}
  | .stats.sessions = [
      {day:"2026-09-07", job:"review", min:7, model:"claude-opus-5", input:0, output:1000, cache_read:9000, cache_creation:1000, reviews:1},
      {day:"2026-09-07", job:"shepherd", min:3, model:"claude-opus-5", input:0, output:0, cache_read:0, cache_creation:0, reviews:0},
      {day:"2026-09-08", job:"review", min:12, model:"mystery-model", input:0, output:1000, cache_read:0, cache_creation:0, reviews:2}]' \
  > "$WORK/audit/last-worklist.json"
run_trend append "$WORK/audit"
run_trend index "$WORK/audit"
assert_out_contains '"approve_share": 0.6' 'the approve share of all reviews'
assert_out_contains '"first_approve_share": 0.5' 'the approve share of first reviews'
assert_out_contains '"disk_used_pct": 80' 'the fullest volume'
assert_out_contains '"disk_inode_pct": 9' 'the highest inode use'
assert_out_contains '"work_mb": 20' 'the size of work/'
assert_out_contains '"run_min_median": 7' 'the median run length'
assert_out_contains '"run_min_p90": 12' 'the p90 run length'
assert_out_contains '"run_usd_median": 0.054' 'a priced run costs its tokens; an unpriced one stays out'
assert_out_contains '"review_run_min_median": 9.5' 'review runs on their own'
assert_out_contains '"cache_hit": 0.9' 'cache reads over all input'
assert_out_contains '"unpriced": 1' 'a day keeps the count of its unpriced runs'
assert_out_contains '"by_job": {' 'a day splits its runs by job'
run_trend report "$WORK/audit"
assert_out_contains 'Runs by day' 'the report renders the days'
assert_out_contains 'APPROVE share, first reviews' 'the report renders the verdict shares'
assert_out_contains 'Disk used (fullest volume)' 'the report renders the disk row'

# --- review-quality signals (docs/audit.md tasks 24, 28) ------------------------
new_case trend_quality_signals
price_config
mkdir -p "$WORK/audit"
worklist 10 20 0 0 | jq '.stats.findings += {late:5, density:{reviews:8, findings:12, lines:800}}
  | .stats.overruled = {approved_prs:4, scanned:4, unread:[], changes_requested:[{pr:7, by:"alice", at:"x"}],
                        reverted:[{pr:7, by_pr:20}, {pr:9, by_pr:21}]}' > "$WORK/audit/last-worklist.json"
run_trend append "$WORK/audit"
run_trend index "$WORK/audit"
assert_out_contains '"findings_per_100_lines": 1.5' 'findings per 100 changed lines'
assert_out_contains '"late_share": 0.25' 'the missed-earlier share of raised findings'
assert_out_contains '"overruled": 2' 'a PR overruled twice counts once'
assert_out_contains '"overruled_share": 0.5' 'overruled share of the approved PRs'
assert_out_contains '"density_lines": 800' 'the counts behind the density stay in the row'
run_trend report "$WORK/audit"
assert_out_contains 'APPROVE overruled' 'the report renders the overruled row'
assert_out_contains 'Findings per 100 changed lines' 'the report renders the density row'

finish
