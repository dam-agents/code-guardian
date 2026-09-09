#!/usr/bin/env bash
# audit-trend.sh — the weekly trend artifact: append one week of measured
# facts, then render the accumulated report (docs/trends.md).
#
#   audit-trend.sh append   <dir> [<extras.json>] [<worklist.json>]
#   audit-trend.sh backfill <dir> <reviews dir>
#   audit-trend.sh index    <dir>
#   audit-trend.sh report   <dir>            # HTML on stdout (default mode)
#
# `dir` is work/audit/. `append` reads the audit worklist preflight left at
# <dir>/last-worklist.json (or the path given), so the week's numbers never
# pass through the agent, and merges the small `extras.json` only the session
# knows (time-to-first-review, its model id, check counts).
#
# Every mode is deterministic and offline: no API calls, no model calls. The
# history is append-only — a week file is written once and never edited, and
# an `audit` row supersedes a `backfill` row for the same week in the report
# while both stay on disk.
#
# Costs are computed at render time from the CONFIG price table via the shared
# reader (lib/prices.sh), so the whole history reprices when the table changes
# and a cost delta reflects token usage, not a price move. Tokens with no
# matching price row are excluded and the cell is marked a floor ("≥"), never
# guessed.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$SCRIPT_DIR/lib/toolpath.sh" ] && . "$SCRIPT_DIR/lib/toolpath.sh" 2>/dev/null

MODE="report"
case "${1:-}" in
  (append|backfill|index|report) MODE="$1"; shift;;
esac
DIR="${1:-}"; shift 2>/dev/null || true
[ -n "$DIR" ] || { printf 'usage: audit-trend.sh [append|backfill|index|report] <work/audit dir> [args]\n' >&2; exit 2; }

CONFIG_MD="${TREND_CONFIG:-${HOME:-/home/agent}/work/CONFIG.md}"
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ISO week label (2026-W37) of an epoch — the row key, so a week has one row
# whatever hour the audit fires. GNU and BSD date both accept %G/%V.
iso_week() { # <epoch>
  date -u -d "@$1" +%G-W%V 2>/dev/null || date -u -r "$1" +%G-W%V 2>/dev/null
}
iso2epoch() { # <iso ts> -> epoch, 0 when unparseable
  local t="${1:-}"; [ -n "$t" ] || { printf '0'; return; }
  date -u -d "$t" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$t" +%s 2>/dev/null || printf '0'
}

# ---------------------------------------------------------------- append -----
if [ "$MODE" = "append" ]; then
  EXTRAS_FILE="${1:-}"; WORKLIST="${2:-$DIR/last-worklist.json}"
  [ -f "$WORKLIST" ] || { printf 'audit-trend: no worklist at %s — nothing appended\n' "$WORKLIST" >&2; exit 3; }
  mkdir -p "$DIR/weeks" || exit 3

  EXTRAS='{}'
  if [ -n "$EXTRAS_FILE" ] && [ -f "$EXTRAS_FILE" ]; then
    # an unusable extras file leaves the week measured, with its session-only
    # values absent — the report then says "—" instead of a wrong number
    parsed="$(jq -c 'select(type=="object")' "$EXTRAS_FILE" 2>/dev/null)"
    [ -n "$parsed" ] && EXTRAS="$parsed" \
      || printf 'audit-trend: extras at %s unreadable — the week is appended without them\n' "$EXTRAS_FILE" >&2
  fi
  VERSION_NOW="$(cat "${HOME:-/home/agent}/VERSION" 2>/dev/null | tr -d ' \n')"

  SINCE="$(jq -r '.stats.since // empty' "$WORKLIST" 2>/dev/null)"
  WEEK="$(iso_week "$(date -u +%s)")"
  TS="$NOW_ISO"
  ROW="$(jq -n --slurpfile w "$WORKLIST" --argjson x "$EXTRAS" \
    --arg ts "$TS" --arg week "$WEEK" --arg since "$SINCE" --arg ver "${VERSION_NOW:-unknown}" '
    ($w[0] // {}) as $wl
    | {ts:$ts, week:$week, since:(if $since=="" then null else $since end),
       source:"audit", definition_version:$ver,
       stats:($wl.stats // {}),
       checks:(($wl.checks // []) | {ok:([.[]|select(.status=="ok")]|length),
                                     warn:([.[]|select(.status=="warn")]|length),
                                     fail:([.[]|select(.status=="fail")]|length)}),
       extras:$x}' 2>/dev/null)"
  [ -n "$ROW" ] || { printf 'audit-trend: could not build the week row from %s\n' "$WORKLIST" >&2; exit 3; }

  # append-only: a second audit in the same week writes its own file, and the
  # newest audit row of a week is the one the report shows
  OUT="$DIR/weeks/$(printf '%s' "$TS" | tr -d ':-').json"
  printf '%s\n' "$ROW" > "$OUT" || exit 3
  printf '%s\n' "$ROW" | jq -e '.stats | type == "object"' >/dev/null 2>&1 \
    || { printf 'audit-trend: week file has no stats object (%s)\n' "$OUT" >&2; exit 3; }
fi

# -------------------------------------------------------------- backfill -----
# One-time reconstruction from the posted-review history: review counts,
# verdicts, raised findings and the acceptance bullets are all recorded per
# review section, so they rebuild exactly. Everything measured from the event
# log (time, tokens, cost, heartbeats, stalls) has a 14-day retention and is
# left absent — the report renders it "—" rather than inventing it.
if [ "$MODE" = "backfill" ]; then
  RDIR="${1:-}"
  [ -n "$RDIR" ] && [ -d "$RDIR" ] || { printf 'usage: audit-trend.sh backfill <dir> <reviews dir>\n' >&2; exit 2; }
  mkdir -p "$DIR/weeks" || exit 3
  TMP="$(mktemp "${TMPDIR:-/tmp}/audit-trend-bf.XXXXXX")" || exit 3
  trap 'rm -f "$TMP" "$TMP.jsonl"' EXIT
  : > "$TMP.jsonl"
  for f in "$RDIR"/pr-*.md; do
    [ -f "$f" ] || continue
    idx=0; week=""
    while IFS= read -r line; do
      case "$line" in
        ('## Review at '*)
          ts="$(printf '%s' "$line" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z' | head -1)"
          [ -n "$ts" ] || { week=""; continue; }
          e="$(iso2epoch "$ts")"; [ "$e" -gt 0 ] || { week=""; continue; }
          week="$(iso_week "$e")"; idx=$((idx+1))
          verdict=UNKNOWN
          case "$line" in
            (*REQUEST_CHANGES*) verdict=request_changes;;
            (*APPROVE*)         verdict=approve;;
            (*COMMENT*)         verdict=comment;;
          esac
          printf '{"week":"%s","kind":"review","first":%s,"verdict":"%s"}\n' \
            "$week" "$([ "$idx" -eq 1 ] && printf 'true' || printf 'false')" "$verdict" >> "$TMP.jsonl";;
        ('- ✅ **Fixed:**'*)
          [ -n "$week" ] && printf '{"week":"%s","kind":"fixed"}\n' "$week" >> "$TMP.jsonl";;
        ('- 🔁 **Still present:**'*)
          [ -n "$week" ] && printf '{"week":"%s","kind":"still"}\n' "$week" >> "$TMP.jsonl";;
        ('<!-- findings-json:'*)
          [ -n "$week" ] || continue
          fj="$(printf '%s' "$line" | sed -e 's/^<!-- *findings-json: *//' -e 's/ *-->[[:space:]]*$//')"
          printf '%s' "$fj" | jq -c --arg w "$week" \
            'select(type=="array") | {week:$w, kind:"findings",
              new:([.[]|select(type=="object" and .status=="new")]|length),
              by_sev:([.[]|select(type=="object" and .status=="new")]
                      | group_by(.severity // "unknown")
                      | map({key:(.[0].severity // "unknown"), value:length}) | from_entries)}' \
            2>/dev/null >> "$TMP.jsonl";;
      esac
    done < "$f"
  done

  written=0; skipped=0
  while IFS= read -r wk; do
    [ -n "$wk" ] || continue
    # never overwrite: a week already on record (audit or backfill) stays
    if ls "$DIR"/weeks/*.json >/dev/null 2>&1 \
       && jq -sre --arg w "$wk" 'any(.[]; .week == $w)' "$DIR"/weeks/*.json >/dev/null 2>&1; then
      skipped=$((skipped+1)); continue
    fi
    row="$(jq -sc --arg w "$wk" --arg ts "$NOW_ISO" '
      [.[] | select(.week == $w)] as $e
      | ([$e[] | select(.kind=="review")]) as $rv
      | {ts:$ts, week:$w, since:null, source:"backfill", definition_version:null,
         stats:{reviews:{total:($rv|length),
                         first:([$rv[]|select(.first)]|length),
                         re_review:([$rv[]|select(.first|not)]|length),
                         approve:([$rv[]|select(.verdict=="approve")]|length),
                         comment:([$rv[]|select(.verdict=="comment")]|length),
                         request_changes:([$rv[]|select(.verdict=="request_changes")]|length)},
                findings:{fixed:([$e[]|select(.kind=="fixed")]|length),
                          still_present:([$e[]|select(.kind=="still")]|length),
                          json_reviews:([$e[]|select(.kind=="findings")]|length),
                          new:([$e[]|select(.kind=="findings")|.new]|add // 0),
                          new_by_severity:([$e[]|select(.kind=="findings")|.by_sev|to_entries[]]
                                           | group_by(.key)
                                           | map({key:.[0].key, value:([.[].value]|add)}) | from_entries)}},
         checks:null, extras:{}}' "$TMP.jsonl" 2>/dev/null)"
    [ -n "$row" ] || continue
    printf '%s\n' "$row" > "$DIR/weeks/${wk}-backfill.json" && written=$((written+1))
  done < <(jq -sr '[.[].week] | unique | .[]' "$TMP.jsonl" 2>/dev/null)
  printf 'backfill: %s week(s) written, %s already on record\n' "$written" "$skipped"
fi

# ------------------------------------------------- history & derivation ------
# Load every week file. One row per ISO week: the newest `audit` row wins over
# a `backfill` row, so a reconstructed week is replaced by the measured one as
# soon as an audit covers it — both files stay on disk forever.
ALL="$(for f in "$DIR"/weeks/*.json; do
         [ -f "$f" ] || continue
         jq -c 'select(type == "object") | select(.week != null)' "$f" 2>/dev/null || true
       done | jq -sc 'sort_by(.week, (.source == "audit"), (.ts // ""))
                      | group_by(.week) | map(.[-1]) | sort_by(.week)')"
ALL="${ALL:-[]}"
WEEKS="$(printf '%s' "$ALL" | jq 'length')"

PRICES='[]'
if [ -f "$SCRIPT_DIR/lib/prices.sh" ]; then
  . "$SCRIPT_DIR/lib/prices.sh" 2>/dev/null
  PRICES="$(prices_json "$CONFIG_MD")"
fi
PRICES="${PRICES:-[]}"

# THE single home of every derived metric: the table, the charts, the index
# output and the append delta all read these fields, so no two views of a week
# can disagree.
JQ_DERIVE='
  def r1: if . == null then null else (. * 10 | round) / 10 end;
  def r2: if . == null then null else (. * 100 | round) / 100 end;
  def sev($o; $k): ($o // {}) | (.[$k] // 0);
  # week cost in USD: each recorded model priced by its own table row. Tokens
  # under a model with no row are excluded and flagged, so the figure is a
  # floor, never a guess. `extras.model` names the session model for events
  # written before the hook recorded one.
  def cost:
    (.extras.model // null) as $fallback
    | [ ((.stats.tokens.by_model // {}) | to_entries[])
        | { m: (if (.key == "unknown" and $fallback != null) then $fallback else .key end),
            t: .value } ] as $used
    | if ($used | length) == 0 then {usd: null, floor: false}
      else ([ $used[]
              | . as $u
              | ([$prices[] | select(. as $p | $u.m | contains($p.m))] | first) as $p
              | if $p == null then null
                else (($u.t.input // 0) * $p.i + ($u.t.output // 0) * $p.o
                      + ($u.t.cache_read // 0) * $p.cr + ($u.t.cache_creation // 0) * $p.cw) / 1000000
                end ]) as $c
        | { usd: ([$c[] | select(. != null)] | if length == 0 then null else (add | r2) end),
            floor: ([$c[] | select(. == null)] | length > 0) }
      end;
  def derive:
    . as $w
    | (.stats // {}) as $s
    | ($s.reviews // {}) as $rv
    | ($s.findings // {}) as $fd
    | (cost) as $cost
    | ($rv.total // 0) as $rvn
    | (($fd.fixed // 0) + ($fd.still_present // 0)) as $accd
    | { week: .week, ts: .ts, source: (.source // "audit"), version: .definition_version,
        reviews: $rvn, first: ($rv.first // 0), re_review: ($rv.re_review // 0),
        approve: ($rv.approve // 0), comment: ($rv.comment // 0), request_changes: ($rv.request_changes // 0),
        findings_new: $fd.new,
        f_critical: (if $fd.new == null then null else sev($fd.new_by_severity; "critical") end),
        f_warning:  (if $fd.new == null then null else sev($fd.new_by_severity; "warning") end),
        f_suggestion: (if $fd.new == null then null else sev($fd.new_by_severity; "suggestion") end),
        findings_per_review: (if $fd.new == null or $rvn == 0 then null else ($fd.new / $rvn | r2) end),
        acceptance: (if $accd == 0 then null else (($fd.fixed // 0) / $accd | r2) end),
        up: ($s.reactions.up // null), down: ($s.reactions.down // null),
        ttfr_min: (.extras.ttfr_median_min // null),
        duration_min: ($rv.duration.median_min // null),
        top_phase: (($rv.phases // {}) | [to_entries[] | select(.value.median_min != null)]
                    | if length == 0 then null
                      else (max_by(.value.median_min) | "\(.key) \(.value.median_min)m") end),
        open_prs: ($s.open_prs // null),
        awaiting: ($s.awaiting_label.n // null),
        heartbeats: ($s.heartbeats.total // null),
        idle_ratio: (if ($s.heartbeats.total // 0) == 0 then null
                     else (($s.heartbeats.idle // 0) / $s.heartbeats.total | r2) end),
        out_tokens: ($s.tokens.output // null),
        cost_usd: $cost.usd, cost_floor: $cost.floor,
        cost_per_review: (if $cost.usd == null or $rvn == 0 then null else ($cost.usd / $rvn | r2) end),
        stalled: ($s.stalls.stalled // null), locked_runs: ($s.stalls.total // null),
        stalled_ratio: (if ($s.stalls.total // 0) == 0 then null
                        else (($s.stalls.stalled // 0) / $s.stalls.total | r2) end),
        wasted_out_tokens: ($s.stalls.wasted_output_tokens // null),
        errors: ($s.log_events.errors // null), warns: ($s.log_events.warns // null),
        c_ok: (.checks.ok // null), c_warn: (.checks.warn // null), c_fail: (.checks.fail // null),
        memory_lines: (.extras.memory_lines // null) };
'
DERIVED="$(printf '%s' "$ALL" | jq -c --argjson prices "$PRICES" "$JQ_DERIVE"'map(derive)' 2>/dev/null)"
DERIVED="${DERIVED:-[]}"

if [ "$MODE" = "index" ]; then
  printf '%s' "$DERIVED" | jq '.'
  exit 0
fi

# ------------------------------------------------------------- TRENDS.md -----
# Regenerated from the append-only week files (a repricing or a new column
# therefore reaches every past week), preserving the publish-id markers.
write_trends() {
  local markers=""
  [ -f "$DIR/TRENDS.md" ] && markers="$(grep -E '^<!-- audit-trend-(gist|dam): ' "$DIR/TRENDS.md" 2>/dev/null || true)"
  {
    printf '# Weekly trends\n'
    [ -n "$markers" ] && printf '%s\n' "$markers"
    printf '\n_Derived view of `weeks/*.json` (append-only), regenerated by `scripts/audit-trend.sh`._\n'
    printf '_Semantics: `docs/trends.md`. "—" = not measured that week._\n\n'
    printf '| week | src | reviews (1st/re) | ✅/⚠️/❌ | new 🔴/🟡/🟢 | f/rev | acc | ttfr | dur | idle | out-tok | est $ | $/rev | stalled | err/warn |\n'
    printf '|------|-----|------------------|---------|--------------|-------|-----|------|-----|------|---------|-------|-------|---------|----------|\n'
    printf '%s' "$DERIVED" | jq -r '
      def f: if . == null then "—" else tostring end;
      def pc: if . == null then "—" else ((. * 100 | round) | tostring + "%") end;
      .[] | "| \(.week) | \(if .source == "audit" then "audit" else "bf" end)"
        + " | \(.reviews|f) (\(.first|f)/\(.re_review|f))"
        + " | \(.approve|f)/\(.comment|f)/\(.request_changes|f)"
        + " | \(if .findings_new == null then "—" else "\(.findings_new) (\(.f_critical)/\(.f_warning)/\(.f_suggestion))" end)"
        + " | \(.findings_per_review|f) | \(.acceptance|pc) | \(.ttfr_min|f) | \(.duration_min|f)"
        + " | \(.idle_ratio|pc) | \(.out_tokens|f)"
        + " | \(if .cost_usd == null then "—" else (if .cost_floor then "≥" else "" end) + (.cost_usd|tostring) end)"
        + " | \(.cost_per_review|f)"
        + " | \(if .stalled == null then "—" else "\(.stalled)/\(.locked_runs)" end)"
        + " | \(.errors|f)/\(.warns|f) |"'
  } > "$DIR/TRENDS.md.tmp" && mv "$DIR/TRENDS.md.tmp" "$DIR/TRENDS.md"
}

if [ "$MODE" = "append" ] || [ "$MODE" = "backfill" ]; then
  write_trends
  # week-over-week delta for the report line — the two newest rows only
  printf '%s' "$DERIVED" | jq -r '
    def f: if . == null then "—" else tostring end;
    def pc: if . == null then "—" else ((. * 100 | round) | tostring + "%") end;
    def d(cur; prev; unit): if cur == null or prev == null then ""
      else ((cur - prev) | (. * 100 | round) / 100) as $x
        | if $x == 0 then " (=)"
          elif $x > 0 then " (▲\($x)\(unit))" else " (▼\($x * -1)\(unit))" end end;
    if length == 0 then "trend: nothing on record yet"
    else (.[-1]) as $c | (if length > 1 then .[-2] else null end) as $p
    | "trend \($c.week): reviews \($c.reviews)\(d($c.reviews; $p.reviews; ""))"
      + " · new findings \($c.findings_new|f)\(d($c.findings_new; $p.findings_new; ""))"
      + " · acceptance \($c.acceptance|pc)\(d((if $c.acceptance == null then null else $c.acceptance * 100 end);
                                              (if $p.acceptance == null then null else $p.acceptance * 100 end); "pp"))"
      + " · est $ \($c.cost_usd|f)\(d($c.cost_usd; $p.cost_usd; ""))"
      + " · $/review \($c.cost_per_review|f)\(d($c.cost_per_review; $p.cost_per_review; ""))"
      + " · ttfr \($c.ttfr_min|f)m\(d($c.ttfr_min; $p.ttfr_min; "m"))"
      + " · stalled \($c.stalled|f)/\($c.locked_runs|f)"
    end'
  surfaces="$(sed -n 's/^- *audit_trend: *//p' "$CONFIG_MD" 2>/dev/null | head -1 | tr -d ' ')"
  printf 'weeks=%s surfaces=%s report=%s\n' "$WEEKS" "${surfaces:-dam}" "$DIR/report.html"
  exit 0
fi

# ---------------------------------------------------------------- report -----
# Self-contained HTML: no external assets, because the gist renderer and the
# artifact viewer allow no network. Charts are inline SVG polylines over the
# same derived rows the table shows — a missing week breaks the line instead
# of interpolating across it.
JQ_VIEW='
  def f: if . == null then "—" else tostring end;
  def pc: if . == null then "—" else ((. * 100 | round) | tostring + "%") end;
  def cell: if . == null then "<td class=\"n dash\">—</td>" else "<td class=\"n\">\(.)</td>" end;
  # delta against the previous week; the arrow duplicates the sign, so color is
  # never the only signal. $good = "up" when a rising value is the good news.
  def delta($cur; $prev; $good; $unit):
    if $cur == null or $prev == null then ""
    else (((($cur - $prev) * 100 | round) / 100)) as $x
      | if $x == 0 then " <span class=\"d z\">=</span>"
        else (if ($x > 0) == ($good == "up") then "up" else "down" end) as $cls
          | " <span class=\"d \($cls)\">\(if $x > 0 then "▲" else "▼" end)\((if $x < 0 then -$x else $x end))\($unit)</span>"
        end
    end;
  # relative week-over-week change, the reading most metrics are judged by
  # ("+20%"); ratio columns use percentage points instead, because a percent
  # of a percent is unreadable. A zero or absent baseline yields no delta.
  def rel($cur; $prev; $good):
    if $cur == null or $prev == null then ""
    elif $cur == $prev then " <span class=\"d z\">=</span>"
    elif $prev == 0 then
      (if ($cur > 0) == ($good == "up") then "up" else "down" end) as $cls
      | " <span class=\"d \($cls)\">\(if $cur > 0 then "▲" else "▼" end) from 0</span>"
    else ((((($cur - $prev) / (if $prev < 0 then -$prev else $prev end)) * 1000 | round) / 10)) as $x
      | if $x == 0 then " <span class=\"d z\">=</span>"
        else (if ($x > 0) == ($good == "up") then "up" else "down" end) as $cls
          | " <span class=\"d \($cls)\">\(if $x > 0 then "▲" else "▼" end)\((if $x < 0 then -$x else $x end))%</span>"
        end
    end;
  # one summary row: latest week, previous week, w/w change, the mean of the
  # four weeks before the latest, and the change against that mean — the noise
  # filter a single week cannot give.
  def srow($rows; $label; $key; $good; $kind):
    ($rows[-1] // {}) as $c
    | (if ($rows | length) > 1 then $rows[-2] else {} end) as $p
    | [ $rows[:-1][-4:][] | .[$key] | select(. != null) ] as $base
    | (if ($base | length) == 0 then null
       else (($base | add) / ($base | length) * 100 | round) / 100 end) as $avg
    | ($c[$key]) as $cur
    | (if $kind == "pct" then ($cur | if . == null then "—" else ((. * 100 | round) | tostring) + "%" end)
       elif $kind == "usd" then ($cur | if . == null then "—" else "$" + (. | tostring) end)
       else ($cur | if . == null then "—" else tostring end) end) as $curs
    | (if $kind == "pct" then ($p[$key] | if . == null then "—" else ((. * 100 | round) | tostring) + "%" end)
       elif $kind == "usd" then ($p[$key] | if . == null then "—" else "$" + (. | tostring) end)
       else ($p[$key] | if . == null then "—" else tostring end) end) as $prevs
    | (if $kind == "pct" then ($avg | if . == null then "—" else ((. * 100 | round) | tostring) + "%" end)
       elif $kind == "usd" then ($avg | if . == null then "—" else "$" + (. | tostring) end)
       else ($avg | if . == null then "—" else tostring end) end) as $avgs
    | (if $kind == "pct" then delta((if $cur == null then null else $cur * 100 end);
                                    (if $p[$key] == null then null else $p[$key] * 100 end); $good; "pp")
       else rel($cur; $p[$key]; $good) end) as $dww
    | (if $kind == "pct" then delta((if $cur == null then null else $cur * 100 end);
                                    (if $avg == null then null else $avg * 100 end); $good; "pp")
       else rel($cur; $avg; $good) end) as $davg
    | "<tr><td>\($label)</td><td class=\"n\"><b>\($curs)</b></td><td class=\"n\">\($prevs)</td>"
      + "<td class=\"n\">\(if $dww == "" then "—" else $dww end)</td>"
      + "<td class=\"n\">\($avgs)</td>"
      + "<td class=\"n\">\(if $davg == "" then "—" else $davg end)</td></tr>";
  # one SVG line chart: $series = [{key, scale, color}] over $rows
  def svg($rows; $series):
    ($rows | length) as $n
    | [ $series[] | .key as $k | .scale as $sc | [$rows[] | .[$k] | select(. != null) | . * $sc] ]
    | flatten as $vals
    | (if ($vals | length) == 0 then null else ($vals | max) end) as $peak
    | if $peak == null then "<p class=\"nodata\">not measured yet</p>"
      else (if $peak <= 0 then 1 else $peak end) as $ymax
      | (if $n <= 1 then 0 else 282 / ($n - 1) end) as $step
      | ([ $series[]
           | .key as $k | .scale as $sc | .color as $col
           | [ $rows | to_entries[] | {x: (34 + (.key * $step)),
                                       v: (if (.value[$k]) == null then null else (.value[$k] * $sc) end)} ]
           | reduce .[] as $p ([[]];
               if $p.v == null then . + [[]]
               else (.[0:-1] + [ (.[-1] + [{x: $p.x, y: (80 - ($p.v / $ymax) * 66)}]) ]) end)
           | [ .[] | select(length > 0) ] as $segs
           | ([ $segs[] | select(length > 1)
                | "<polyline points=\"" + ([.[] | "\(.x | . * 10 | round / 10),\(.y | . * 10 | round / 10)"] | join(" ")) + "\" stroke=\"\($col)\"/>" ]
              + [ $segs[] | .[] | "<circle cx=\"\(.x | . * 10 | round / 10)\" cy=\"\(.y | . * 10 | round / 10)\" r=\"1.9\" fill=\"\($col)\"/>" ])
           | join("") ] | join("")) as $paths
      | "<svg viewBox=\"0 0 320 100\" role=\"img\">"
        + "<line class=\"ax\" x1=\"34\" y1=\"80\" x2=\"316\" y2=\"80\"/>"
        + "<line class=\"gr\" x1=\"34\" y1=\"47\" x2=\"316\" y2=\"47\"/>"
        + "<text class=\"lb\" x=\"31\" y=\"17\" text-anchor=\"end\">\((($ymax * 10 | round) / 10))</text>"
        + "<text class=\"lb\" x=\"31\" y=\"83\" text-anchor=\"end\">0</text>"
        + "<text class=\"lb\" x=\"34\" y=\"95\">\($rows[0].week)</text>"
        + (if $n > 1 then "<text class=\"lb\" x=\"316\" y=\"95\" text-anchor=\"end\">\($rows[-1].week)</text>" else "" end)
        + $paths + "</svg>"
      end;
  def figure($rows; $title; $note; $series):
    "<figure><figcaption>\($title)</figcaption>"
    + "<p class=\"legend\">" + ([$series[] | "<span style=\"color:\(.color)\">●</span> \(.name)"] | join(" · ")) + "</p>"
    + svg($rows; $series)
    + "<p class=\"note\">\($note)</p></figure>";
'
SUMMARY="$(printf '%s' "$DERIVED" | jq -r "$JQ_VIEW"'
  . as $rows
  | if length == 0 then "" else
    "<h2>Where it is heading</h2><div class=\"scroll\"><table><thead><tr>"
    + "<th>metric</th><th>\($rows[-1].week)</th>"
    + "<th>\(if length > 1 then $rows[-2].week else "prev" end)</th><th>w/w</th>"
    + "<th>4-week avg</th><th>vs avg</th></tr></thead><tbody>"
    + ([ srow($rows; "Reviews posted"; "reviews"; "up"; "num"),
         srow($rows; "Findings raised"; "findings_new"; "up"; "num"),
         srow($rows; "Findings per review"; "findings_per_review"; "up"; "num"),
         srow($rows; "Findings acceptance"; "acceptance"; "up"; "pct"),
         srow($rows; "Time to first review (min)"; "ttfr_min"; "down"; "num"),
         srow($rows; "Review duration (min)"; "duration_min"; "down"; "num"),
         srow($rows; "Spend per week"; "cost_usd"; "down"; "usd"),
         srow($rows; "Spend per review"; "cost_per_review"; "down"; "usd"),
         srow($rows; "Output tokens"; "out_tokens"; "down"; "num"),
         srow($rows; "Idle heartbeats"; "idle_ratio"; "up"; "pct"),
         srow($rows; "Stalled runs"; "stalled"; "down"; "num"),
         srow($rows; "Error events"; "errors"; "down"; "num"),
         srow($rows; "awaiting_label backlog"; "awaiting"; "down"; "num") ] | join(""))
    + "</tbody></table></div>"
    + "<p class=\"note\">▲▼ are relative changes; a ratio row changes in percentage points."
    + " Green is the good direction for that row. The 4-week average covers the four weeks"
    + " before the latest one, skipping weeks a metric was not measured.</p>"
  end' 2>/dev/null)"

CHARTS="$(printf '%s' "$DERIVED" | jq -r "$JQ_VIEW"'
  . as $rows
  | if length == 0 then "" else
    "<div class=\"grid\">"
    + figure($rows; "Reviews & findings raised"; "How much work the agent did and how much it found.";
             [{key:"reviews", scale:1, color:"var(--c1)", name:"reviews posted"},
              {key:"findings_new", scale:1, color:"var(--c2)", name:"findings raised"}])
    + figure($rows; "Spend per week (USD)"; "Tokens priced by the CONFIG table; a week with unpriced models is a floor.";
             [{key:"cost_usd", scale:1, color:"var(--c1)", name:"est $ / week"}])
    + figure($rows; "Spend per review (USD)"; "The efficiency signal: total spend divided by reviews posted.";
             [{key:"cost_per_review", scale:1, color:"var(--c1)", name:"est $ / review"}])
    + figure($rows; "Latency (minutes)"; "Queue wait plus review time, and the review itself.";
             [{key:"ttfr_min", scale:1, color:"var(--c1)", name:"time to first review"},
              {key:"duration_min", scale:1, color:"var(--c2)", name:"review duration"}])
    + figure($rows; "Findings acceptance (%)"; "Share of flagged findings fixed by the next re-review.";
             [{key:"acceptance", scale:100, color:"var(--c1)", name:"fixed / (fixed + still)"}])
    + figure($rows; "Wasted reviews & idle heartbeats (%)"; "Runs redone after a stall, and the idle share of heartbeats.";
             [{key:"stalled_ratio", scale:100, color:"var(--c2)", name:"stalled runs"},
              {key:"idle_ratio", scale:100, color:"var(--c1)", name:"idle heartbeats"}])
    + "</div>"
  end' 2>/dev/null)"

ROWS_HTML="$(printf '%s' "$DERIVED" | jq -r "$JQ_VIEW"'
  . as $rows
  | [ to_entries[]
      | .value as $c | (if .key == 0 then null else $rows[.key - 1] end) as $p
      | "<tr><td>\($c.week)</td><td>\(if $c.source == "audit" then "audit" else "backfill" end)</td>"
        + "<td>\($c.version // "—")</td>"
        + "<td class=\"n\"><b>\($c.reviews)</b>\(rel($c.reviews; $p.reviews; "up"))</td>"
        + "<td class=\"n\">\($c.first)/\($c.re_review)</td>"
        + "<td class=\"n\">\($c.approve)/\($c.comment)/\($c.request_changes)</td>"
        + (if $c.findings_new == null then "<td class=\"n dash\">—</td>"
           else "<td class=\"n\">\($c.findings_new)\(rel($c.findings_new; $p.findings_new; "up"))</td>" end)
        + (if $c.findings_new == null then "<td class=\"n dash\">—</td>"
           else "<td class=\"n\">\($c.f_critical)/\($c.f_warning)/\($c.f_suggestion)</td>" end)
        + ($c.findings_per_review | cell)
        + (if $c.acceptance == null then "<td class=\"n dash\">—</td>"
           else "<td class=\"n\">\($c.acceptance | pc)\(delta($c.acceptance * 100;
                    (if $p.acceptance == null then null else $p.acceptance * 100 end); "up"; "pp"))</td>" end)
        + (if $c.up == null then "<td class=\"n dash\">—</td>" else "<td class=\"n\">\($c.up)/\($c.down)</td>" end)
        + (if $c.ttfr_min == null then "<td class=\"n dash\">—</td>"
           else "<td class=\"n\">\($c.ttfr_min)\(rel($c.ttfr_min; $p.ttfr_min; "down"))</td>" end)
        + ($c.duration_min | cell)
        + "<td>\($c.top_phase // "—")</td>"
        + ($c.open_prs | cell) + ($c.awaiting | cell)
        + (if $c.heartbeats == null then "<td class=\"n dash\">—</td>"
           else "<td class=\"n\">\($c.heartbeats) (\($c.idle_ratio | pc))</td>" end)
        + ($c.out_tokens | cell)
        + (if $c.cost_usd == null then "<td class=\"n dash\">—</td>"
           else "<td class=\"n\">\(if $c.cost_floor then "≥" else "" end)\($c.cost_usd)\(rel($c.cost_usd; $p.cost_usd; "down"))</td>" end)
        + (if $c.cost_per_review == null then "<td class=\"n dash\">—</td>"
           else "<td class=\"n\">\($c.cost_per_review)\(rel($c.cost_per_review; $p.cost_per_review; "down"))</td>" end)
        + (if $c.stalled == null then "<td class=\"n dash\">—</td>"
           else "<td class=\"n\">\($c.stalled)/\($c.locked_runs)</td>" end)
        + (if $c.errors == null then "<td class=\"n dash\">—</td>" else "<td class=\"n\">\($c.errors)/\($c.warns)</td>" end)
        + (if $c.c_fail == null then "<td class=\"n dash\">—</td>"
           else "<td class=\"n\">\($c.c_fail)/\($c.c_warn)/\($c.c_ok)</td>" end)
        + "</tr>" ] | join("\n")' 2>/dev/null)"

LATEST="$(printf '%s' "$DERIVED" | jq -r '(last // {}) | .week // "no weeks yet"')"
PRICED="$(printf '%s' "$PRICES" | jq 'length')"

cat <<EOF
<!doctype html>
<meta charset="utf-8">
<title>Weekly trends</title>
<style>
/* Role tokens, both modes selected explicitly; values shared with the
   benchmark report so the two artifacts read as one system. */
:root{
  color-scheme:light dark;
  --surface:#fcfcfb;--plane:#f9f9f7;--head:#f2f2f0;
  --ink:#0b0b0b;--ink-2:#52514e;--ink-muted:#898781;
  --rule:#e1e0d9;--rule-strong:#c3c2b7;
  --seq:#2a78d6;--good:#006300;--bad:#d03b3b;
  --c1:#2a78d6;--c2:#b8641f;
}
@media (prefers-color-scheme:dark){:root{
  --surface:#1a1a19;--plane:#0d0d0d;--head:#232322;
  --ink:#fff;--ink-2:#c3c2b7;--ink-muted:#898781;
  --rule:#2c2c2a;--rule-strong:#383835;
  --seq:#3987e5;--good:#0ca30c;--bad:#e66767;
  --c1:#3987e5;--c2:#e0a03c;
}}
body{font-family:system-ui,-apple-system,'Segoe UI',sans-serif;margin:0 auto;
  padding:2rem 1rem;max-width:84rem;color:var(--ink);background:var(--plane);
  line-height:1.5;-webkit-text-size-adjust:100%}
h1{font-size:1.35rem;letter-spacing:-.01em;margin:0 0 .4rem}
h2{font-size:1.05rem;margin:2.2rem 0 .3rem;padding-bottom:.25rem;
  border-bottom:1px solid var(--rule-strong)}
p.meta{color:var(--ink-2);font-size:.82rem;max-width:60rem;margin:.3rem 0 1.4rem}
.grid{display:grid;gap:1rem;grid-template-columns:repeat(auto-fit,minmax(19rem,1fr))}
figure{margin:0;padding:.7rem .8rem .5rem;background:var(--surface);
  border:1px solid var(--rule);border-radius:6px}
figcaption{font-size:.85rem;font-weight:600;margin-bottom:.1rem}
.legend{font-size:.75rem;color:var(--ink-2);margin:.1rem 0 .3rem}
.note{font-size:.72rem;color:var(--ink-muted);margin:.25rem 0 0}
.nodata{font-size:.78rem;color:var(--ink-muted);margin:.6rem 0 1.4rem}
svg{width:100%;height:auto;display:block;overflow:visible}
svg polyline{fill:none;stroke-width:1.6}
svg .ax{stroke:var(--rule-strong);stroke-width:.8}
svg .gr{stroke:var(--rule);stroke-width:.6;stroke-dasharray:2 2}
svg .lb{font-size:6.5px;fill:var(--ink-muted);font-family:system-ui,sans-serif}
.scroll{overflow-x:auto;background:var(--surface);border:1px solid var(--rule);
  border-radius:6px}
table{border-collapse:collapse;width:100%;font-size:.82rem;margin:0}
th,td{padding:.36rem .6rem;text-align:left;border-bottom:1px solid var(--rule);
  white-space:nowrap}
th{background:var(--head);cursor:pointer;user-select:none;font-weight:600;
  color:var(--ink-2)}
th:hover{color:var(--ink)}
th[data-d="a"]::after{content:" ▲";color:var(--seq)}
th[data-d="d"]::after{content:" ▼";color:var(--seq)}
tbody tr:last-child td{border-bottom:0}
td.n{text-align:right;font-variant-numeric:tabular-nums}
tr:hover td{background:color-mix(in srgb,var(--seq) 8%,transparent)}
.d{font-size:.75rem;font-variant-numeric:tabular-nums;white-space:nowrap}
.d.up{color:var(--good)}.d.down{color:var(--bad)}.d.z{color:var(--ink-muted)}
td.dash{color:var(--ink-muted)}
</style>
<h1>Code review agent — weekly trends</h1>
<p class="meta">Latest week: ${LATEST} · ${WEEKS} week(s) on record · ${PRICED}
price row(s) loaded. One row per ISO week, appended by the weekly audit; rows
marked <b>backfill</b> were reconstructed from the review history and carry
only what that history records. "—" means not measured that week, never zero.
Deltas (▲▼) are the relative change against the previous week — green when the
value moved the good way for its column, so ▼ is green on cost, latency and
stalls; ratio columns change in percentage points (pp).
Spend is a token estimate from the CONFIG price table, and "≥" marks a week
whose tokens include a model the table does not price. Click a header to sort.
Semantics: docs/trends.md.</p>
${SUMMARY}
<h2>Week over week</h2>
${CHARTS}
<h2>Every week</h2>
<div class=scroll>
<table>
<thead>
<tr><th>week</th><th>src</th><th>version</th><th>reviews</th><th>1st/re</th>
<th>✅/⚠️/❌</th><th>found</th><th>🔴/🟡/🟢</th><th>f/rev</th><th>acc</th>
<th>👍/👎</th><th>ttfr</th><th>dur</th><th>slowest phase</th><th>open</th>
<th>awaiting</th><th>heartbeats</th><th>out-tok</th><th>est \$</th><th>\$/rev</th>
<th>stalled</th><th>err/warn</th><th>🔴/🟡/🟢 checks</th></tr>
</thead>
<tbody>
${ROWS_HTML}
</tbody>
</table>
</div>
<script>
// Sort only — no external assets (the gist renderer and the artifact viewer
// allow no network). Numeric when every cell parses as a number, else text.
document.querySelectorAll('th').forEach(function(th,i){
  th.addEventListener('click',function(){
    var tb=th.closest('table').tBodies[0], rows=[].slice.call(tb.rows);
    var dir=th.dataset.d==='a'?'d':'a';
    th.closest('tr').querySelectorAll('th').forEach(function(o){delete o.dataset.d});
    th.dataset.d=dir;
    var val=function(r){var t=(r.cells[i]?r.cells[i].textContent:'').trim()
      .replace(/[▲▼=]/g,'').replace(/[≥%,]/g,'').trim();
      var n=parseFloat(t); return isNaN(n)?null:n;};
    var numeric=rows.every(function(r){var t=(r.cells[i]?r.cells[i].textContent:'').trim();
      return t==='—'||val(r)!==null;});
    rows.sort(function(a,b){
      if(numeric){var x=val(a),y=val(b);
        if(x===null)return 1; if(y===null)return -1; return dir==='a'?x-y:y-x;}
      var s=(a.cells[i]?a.cells[i].textContent:''),t=(b.cells[i]?b.cells[i].textContent:'');
      return dir==='a'?s.localeCompare(t):t.localeCompare(s);});
    rows.forEach(function(r){tb.appendChild(r)});
  });
});
</script>
EOF
