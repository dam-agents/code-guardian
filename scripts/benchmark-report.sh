#!/usr/bin/env bash
# benchmark-report.sh — render the accumulated benchmark report as one
# self-contained HTML page on stdout (docs/benchmark.md → The report).
#
#   benchmark-report.sh <work/benchmark dir>
#
# Reads every scored run in <dir>/results/*.json and prints the complete
# comparison: an all-runs table (per run: model, definition version, averaged
# headline scores across fixtures, total wall-clock seconds and output
# tokens), then one trend table per fixture. Deterministic — the same inputs
# render the same page; the benchmark run republishes it after every run, so
# the published artifact always carries the full history. Missing values
# (e.g. tokens on a harness without transcripts) render as "—", never break
# the page.
#
# The "index" column is one weighted quality index in [0,1], per fixture and
# averaged per run. Components and weights: recall_critical .20,
# precision .15, recall .10, severity_accuracy .10, format-pass rate .10
# (share of true format booleans), fixed_recall .10, new_recall .05,
# circle-free .10 (1 − min(1, (churn + false_fixed)/3) — degrades as the
# review flags its own fixes or un-fixes findings), judge .10 (all judge
# dimensions averaged / 5). A component whose data is missing drops out and
# the remaining weights renormalize, so runs with and without a judge stay
# comparable — the component set is pinned by the data each run carries.
# The all-runs table also prints the delta against the previous run for
# index, seconds, and output tokens — the regression signal for quality,
# speed, and cost.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$SCRIPT_DIR/lib/toolpath.sh" ] && . "$SCRIPT_DIR/lib/toolpath.sh" 2>/dev/null

DIR="${1:-}"
[ -n "$DIR" ] && [ -d "$DIR/results" ] || {
  printf 'usage: benchmark-report.sh <work/benchmark dir with results/>\n' >&2; exit 2; }

RUNS="$(ls "$DIR"/results/*.json 2>/dev/null | grep -c '')"
if [ "$RUNS" -eq 0 ]; then ALL='[]'; else
  ALL="$(jq -s 'map(select(type == "object")) | sort_by(.ts // "")' "$DIR"/results/*.json 2>/dev/null)" || ALL='[]'
fi

JQ_COMMON='
  def fmt: if . == null then "—" else tostring end;
  def r3: if . == null then null else (. * 1000 | round) / 1000 end;
  def avg(f): [.[] | f | select(. != null)] as $v
    | if ($v | length) == 0 then null else (($v | add) / ($v | length) | r3) end;
  def total(f): [.[] | f | select(. != null)] as $v
    | if ($v | length) == 0 then null else ($v | add) end;
  def run_secs: [.fixtures // {} | .[] | (.first.seconds, .rereview.seconds)] | total(.);
  def run_out_tokens: [.fixtures // {} | .[] | (.first.tokens.output?, .rereview.tokens.output?)] | total(.);
  def bools($o): [$o // {} | to_entries[] | .value | select(type == "boolean")];
  def jnums($o): [$o // {} | to_entries[] | .value | numbers];
  # weighted quality index of one fixture object — weights in the header
  def fixture_index:
    .first as $f | .rereview as $r
    | (bools($f.format) + bools($r.format)) as $fb
    | (jnums($f.judge) + jnums($r.judge)) as $jn
    | [ {v: $f.recall_critical,   w: 0.20},
        {v: $f.precision,         w: 0.15},
        {v: $f.recall,            w: 0.10},
        {v: $f.severity_accuracy, w: 0.10},
        {v: (if ($fb | length) == 0 then null
             else (([$fb[] | select(.)] | length) / ($fb | length)) end), w: 0.10},
        {v: $r.fixed_recall,      w: 0.10},
        {v: $r.new_recall,        w: 0.05},
        {v: (if $r == null then null
             else (1 - ([1, ((($r.churn // 0) + ($r.false_fixed // 0)) / 3)] | min)) end), w: 0.10},
        {v: (if ($jn | length) == 0 then null else (($jn | add / length) / 5) end), w: 0.10} ]
    | [.[] | select(.v != null)]
    | if length == 0 then null
      else (([.[] | .v * .w] | add) / ([.[].w] | add) | r3) end;
  def run_index: [.fixtures // {} | .[] | fixture_index] | avg(.);
  def delta($c; $p): if $c == null or $p == null then ""
    else (($c - $p) | if . >= 0 then " (+\(r3))" else " (\(r3))" end) end;
'

ROWS_ALL="$(printf '%s' "$ALL" | jq -r "$JQ_COMMON"'
  . as $all | to_entries[] | .key as $i | .value as $r
  | (if $i == 0 then null else ($all[$i - 1] // null) end) as $prev
  | ($r.fixtures // {} | [.[]]) as $fx
  | ($r | run_index) as $idx
  | (if $prev == null then null else ($prev | run_index) end) as $pidx
  | ($r | run_secs) as $sec
  | (if $prev == null then null else ($prev | run_secs) end) as $psec
  | ($r | run_out_tokens) as $tok
  | (if $prev == null then null else ($prev | run_out_tokens) end) as $ptok
  | "<tr><td>\($r.ts | fmt | @html)</td><td>\($r.trigger // "—" | @html)</td>"
    + "<td>\($r.model // "—" | @html)</td><td>\($r.definition_version // "—" | @html)</td>"
    + "<td>\($r.harness_version // "—" | @html)</td>"
    + "<td class=n>\($fx | length)</td>"
    + "<td class=n><b>\($idx | fmt)</b>\(delta($idx; $pidx))</td>"
    + "<td class=n>\($fx | avg(.first.f1) | fmt)</td>"
    + "<td class=n>\($fx | avg(.first.severity_accuracy) | fmt)</td>"
    + "<td class=n>\($fx | avg(.rereview.fixed_recall) | fmt)</td>"
    + "<td class=n>\($fx | avg(.rereview.new_recall) | fmt)</td>"
    + "<td class=n>\($fx | total(((.rereview.churn // 0) + (.rereview.false_fixed // 0))) | fmt)</td>"
    + "<td class=n>\($fx | total(.first.fp | length) | fmt)</td>"
    + "<td class=n>\($fx | avg(.first.judge.finding_accuracy) | fmt)</td>"
    + "<td class=n>\($sec | fmt)\(delta($sec; $psec))</td>"
    + "<td class=n>\($tok | fmt)\(delta($tok; $ptok))</td></tr>"')"

FIXTURE_SECTIONS="$(printf '%s' "$ALL" | jq -r "$JQ_COMMON"'
  . as $all
  | ([.[] | (.fixtures // {}) | keys[]] | unique) as $slugs
  | $slugs[] as $s
  | "<h2>\($s | @html)</h2>\n<table>\n<tr><th>run</th><th>model</th><th>index</th>"
    + "<th>f1</th><th>prec</th><th>rec</th><th>sev</th><th>words</th>"
    + "<th>fixed</th><th>new</th><th>churn</th><th>false-fixed</th><th>late</th>"
    + "<th>sec</th><th>out-tok</th></tr>\n"
    + ([$all[] | select((.fixtures // {}) | has($s))
        | (.fixtures[$s]) as $f
        | "<tr><td>\(.ts | fmt | @html)</td><td>\(.model // "—" | @html)</td>"
          + "<td class=n><b>\($f | fixture_index | fmt)</b></td>"
          + "<td class=n>\($f.first.f1 | fmt)</td>"
          + "<td class=n>\($f.first.precision | fmt)</td>"
          + "<td class=n>\($f.first.recall | fmt)</td>"
          + "<td class=n>\($f.first.severity_accuracy | fmt)</td>"
          + "<td class=n>\($f.first.length.words_total | fmt)</td>"
          + "<td class=n>\($f.rereview.fixed_recall | fmt)</td>"
          + "<td class=n>\($f.rereview.new_recall | fmt)</td>"
          + "<td class=n>\($f.rereview.churn | fmt)</td>"
          + "<td class=n>\($f.rereview.false_fixed | fmt)</td>"
          + "<td class=n>\($f.rereview.late_finds | fmt)</td>"
          + "<td class=n>\([$f | .first.seconds, .rereview.seconds] | total(.) | fmt)</td>"
          + "<td class=n>\([$f | .first.tokens.output?, .rereview.tokens.output?] | total(.) | fmt)</td></tr>"]
       | join("\n"))
    + "\n</table>"')"

# definition releases between tested versions — for development tracking
VERSION_CHANGES="$(printf '%s' "$ALL" | jq -r '
  [.[] | select((.changes_since_prev // []) | length > 0)] as $c
  | if ($c | length) == 0 then "" else
      "<h2>Definition changes between tested runs</h2>\n"
      + ([$c[]
          | "<h3>\(.definition_version // "?" | @html) — tested \(.ts // "?" | @html)"
            + (if .prev_version then " (since \(.prev_version | @html))" else "" end)
            + "</h3>\n<ul>"
            + ([.changes_since_prev[] | "<li>\(. | @html)</li>"] | join(""))
            + "</ul>"] | join("\n"))
    end')"

GENERATED="$(printf '%s' "$ALL" | jq -r '(last // {}) | .ts // "no runs yet"')"

cat <<EOF
<!doctype html>
<meta charset="utf-8">
<title>Benchmark report</title>
<style>
body{font-family:-apple-system,'Segoe UI',sans-serif;margin:2rem auto;max-width:72rem;padding:0 1rem;color:#1a1a1a;background:#fff}
h1{font-size:1.4rem}h2{font-size:1.1rem;margin-top:2rem}
table{border-collapse:collapse;width:100%;font-size:.85rem;margin:.5rem 0}
th,td{border:1px solid #d0d0d0;padding:.3rem .55rem;text-align:left}
th{background:#f2f2f2}td.n{text-align:right;font-variant-numeric:tabular-nums}
tr:nth-child(even) td{background:#fafafa}
p.meta{color:#666;font-size:.85rem}
</style>
<h1>Review benchmark — accumulated results</h1>
<p class="meta">Latest run: ${GENERATED} · ${RUNS} run(s) on record. Scores 0–1,
higher is better; sec = wall-clock seconds, out-tok = output tokens (— = not
measured). Semantics: docs/benchmark.md.</p>
<h2>All runs</h2>
<table>
<tr><th>run</th><th>trigger</th><th>model</th><th>version</th><th>harness</th>
<th>fixtures</th><th>index</th><th>avg f1</th><th>avg sev</th><th>avg fixed</th>
<th>avg new</th><th>circles</th><th>FPs</th><th>judge</th><th>sec</th><th>out-tok</th></tr>
${ROWS_ALL}
</table>
${VERSION_CHANGES}
${FIXTURE_SECTIONS}
EOF
