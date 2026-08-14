#!/usr/bin/env bash
# benchmark-report.sh — render the accumulated benchmark report as one
# self-contained HTML page on stdout (docs/benchmark.md → Running the
# benchmark, phase 2).
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
# averaged per run — **fully deterministic**: it is computed from scorer
# output only, and judge scores never enter it, so enabling, disabling, or
# changing the judge cannot move the index. The components and their weights
# live in exactly one place — the fixture_index definition in JQ_COMMON below
# (first-review recall/precision/severity/format, re-review
# fixed/still/new recall, and circle-free, which degrades as the review
# flags its own fixes or un-fixes findings). A component whose data is
# missing drops out and the remaining weights renormalize. The separate
# "judge" column is the LLM-judged view: all judge dimensions averaged on
# their own 1–5 scale, reported beside the index, never mixed into it. The
# all-runs table also prints the delta against the previous run for index,
# seconds, and output tokens — the regression signal for quality, speed, and
# cost. `benchmark-report.sh index <dir>` prints the same per-run index as
# JSON for chat summaries and trial comparisons.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$SCRIPT_DIR/lib/toolpath.sh" ] && . "$SCRIPT_DIR/lib/toolpath.sh" 2>/dev/null

# `index` mode prints the deterministic quality index as JSON (one row per
# run) for the chat summary and trial comparisons — same fixture_index the
# HTML uses, one implementation.
OUT_MODE=html
[ "${1:-}" = "index" ] && { OUT_MODE=index; shift; }
DIR="${1:-}"
[ -n "$DIR" ] && [ -d "$DIR/results" ] || {
  printf 'usage: benchmark-report.sh [index] <work/benchmark dir with results/>\n' >&2; exit 2; }

# tolerant per-file load: one corrupt/truncated results file is skipped with
# its data alone — it never discards the rest of the history
ALL="$(for f in "$DIR"/results/*.json; do
         [ -f "$f" ] || continue
         jq -c 'select(type == "object")' "$f" 2>/dev/null || true
       done | jq -s 'sort_by(.ts // "")')"
RUNS="$(printf '%s' "$ALL" | jq length)"

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
  # weighted, fully deterministic quality index of one fixture object —
  # scorer output only, judge never enters it. THE single home of the
  # weights (they sum to 1.00; missing components renormalize):
  def fixture_index:
    .first as $f | .rereview as $r
    | (bools($f.format) + bools($r.format)) as $fb
    | [ {v: $f.recall_critical,   w: 0.20},
        {v: $f.precision,         w: 0.15},
        {v: $f.recall,            w: 0.10},
        {v: $f.severity_accuracy, w: 0.10},
        {v: (if ($fb | length) == 0 then null
             else (([$fb[] | select(.)] | length) / ($fb | length)) end), w: 0.10},
        {v: $r.fixed_recall,      w: 0.10},
        {v: $r.still_recall,      w: 0.10},
        {v: $r.new_recall,        w: 0.05},
        {v: (if $r == null then null
             else (1 - ([1, ((($r.churn // 0) + ($r.false_fixed // 0)) / 3)] | min)) end), w: 0.10} ]
    | [.[] | select(.v != null)]
    | if length == 0 then null
      else (([.[] | .v * .w] | add) / ([.[].w] | add) | r3) end;
  def run_index: [.fixtures // {} | .[] | fixture_index] | avg(.);
  # the LLM-judged view, on its own 1-5 scale, reported beside the index
  def fixture_judge:
    (jnums(.first.judge) + jnums(.rereview.judge)) as $jn
    | if ($jn | length) == 0 then null else (($jn | add / length) | r3) end;
  def delta($c; $p): if $c == null or $p == null then ""
    else (($c - $p) | if . >= 0 then " (+\(r3))" else " (\(r3))" end) end;
'

if [ "$OUT_MODE" = "index" ]; then
  printf '%s' "$ALL" | jq "$JQ_COMMON"'
    [.[] | {ts, trigger, model, definition_version,
            index: run_index, seconds: run_secs, output_tokens: run_out_tokens,
            fixtures: ((.fixtures // {}) | with_entries(.value |= fixture_index))}]'
  exit 0
fi

ROWS_ALL="$(printf '%s' "$ALL" | jq -r "$JQ_COMMON"'
  . as $all | to_entries[] | .key as $i | .value as $r
  | (if $i == 0 then null else $all[$i - 1] end) as $prev
  | ($r.fixtures // {} | [.[]]) as $fx
  | ($r | run_index) as $idx
  | ($r | run_secs) as $sec
  | ($r | run_out_tokens) as $tok
  | "<tr><td>\($r.ts | fmt | @html)</td><td>\($r.trigger // "—" | @html)</td>"
    + "<td>\($r.model // "—" | @html)</td><td>\($r.definition_version // "—" | @html)</td>"
    + "<td>\($r.harness_version // "—" | @html)</td>"
    + "<td class=n>\($fx | length)</td>"
    + "<td class=n><b>\($idx | fmt)</b>\(delta($idx; $prev | run_index))</td>"
    + "<td class=n>\($fx | avg(.first.f1) | fmt)</td>"
    + "<td class=n>\($fx | avg(.first.severity_accuracy) | fmt)</td>"
    + "<td class=n>\($fx | avg(.rereview.fixed_recall) | fmt)</td>"
    + "<td class=n>\($fx | avg(.rereview.new_recall) | fmt)</td>"
    + "<td class=n>\($fx | total(if .rereview == null then null
                                 else ((.rereview.churn // 0) + (.rereview.false_fixed // 0)) end) | fmt)</td>"
    + "<td class=n>\($fx | total(.first.fp | if . == null then null else length end) | fmt)</td>"
    + "<td class=n>\($fx | avg(fixture_judge) | fmt)</td>"
    + "<td class=n>\($sec | fmt)\(delta($sec; $prev | run_secs))</td>"
    + "<td class=n>\($tok | fmt)\(delta($tok; $prev | run_out_tokens))</td></tr>"')"

FIXTURE_SECTIONS="$(printf '%s' "$ALL" | jq -r "$JQ_COMMON"'
  . as $all
  | ([.[] | (.fixtures // {}) | keys[]] | unique) as $slugs
  | $slugs[] as $s
  | "<h2>\($s | @html)</h2>\n<table>\n<tr><th>run</th><th>model</th><th>index</th><th>judge</th>"
    + "<th>f1</th><th>prec</th><th>rec</th><th>sev</th><th>words</th>"
    + "<th>fixed</th><th>new</th><th>churn</th><th>false-fixed</th><th>late</th>"
    + "<th>sec</th><th>out-tok</th></tr>\n"
    + ([$all[] | select((.fixtures // {}) | has($s))
        | (.fixtures[$s]) as $f
        | "<tr><td>\(.ts | fmt | @html)</td><td>\(.model // "—" | @html)</td>"
          + "<td class=n><b>\($f | fixture_index | fmt)</b></td>"
          + "<td class=n>\($f | fixture_judge | fmt)</td>"
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
th{background:#f2f2f2;cursor:pointer;user-select:none;white-space:nowrap}
th[data-d="a"]::after{content:" ▲"}th[data-d="d"]::after{content:" ▼"}
td.n{text-align:right;font-variant-numeric:tabular-nums}
tr.alt td{background:#fafafa}
p.meta{color:#666;font-size:.85rem}
.tbar{display:flex;gap:.6rem;align-items:center;font-size:.85rem;margin:.5rem 0 0}
.tbar input,.tbar select{font-size:.85rem;padding:.15rem .4rem;border:1px solid #c0c0c0;border-radius:3px}
.tbar button{font-size:.85rem;padding:.1rem .5rem;border:1px solid #c0c0c0;border-radius:3px;background:#f7f7f7;cursor:pointer}
.tbar button:disabled{opacity:.4;cursor:default}
.tbar .info{color:#666;margin-left:auto}
</style>
<h1>Review benchmark — accumulated results</h1>
<p class="meta">Latest run: ${GENERATED} · ${RUNS} run(s) on record. Scores 0–1,
higher is better; sec = wall-clock seconds, out-tok = output tokens (— = not
measured). The index is deterministic — computed from scorer output only,
judge scores never enter it (the judge column is its own 1–5 scale). Click a
header to sort, type to filter, page long histories. Semantics:
docs/benchmark.md.</p>
<h2>All runs</h2>
<table>
<tr><th>run</th><th>trigger</th><th>model</th><th>version</th><th>harness</th>
<th>fixtures</th><th>index</th><th>avg f1</th><th>avg sev</th><th>avg fixed</th>
<th>avg new</th><th>circles</th><th>FPs</th><th>judge</th><th>sec</th><th>out-tok</th></tr>
${ROWS_ALL}
</table>
${VERSION_CHANGES}
${FIXTURE_SECTIONS}
<script>
// Client-side sort / filter / paging — no external assets (gist renderer and
// sealed artifact iframes allow no network). Click a header to sort (numeric
// columns by their leading number, "—" sorts last); the box filters rows by
// substring; long histories page.
document.querySelectorAll('table').forEach(function (t) {
  var body = t.tBodies[0]; if (!body) return;
  var all = Array.prototype.slice.call(body.rows);
  var head = all[0], rows = all.slice(1);
  if (!head || rows.length === 0) return;

  var bar = document.createElement('div'); bar.className = 'tbar';
  var inp = document.createElement('input');
  inp.type = 'search'; inp.placeholder = 'filter rows…';
  var sel = document.createElement('select');
  [['20', '20'], ['50', '50'], ['all', 'all']].forEach(function (o) {
    var e = document.createElement('option');
    e.value = o[0]; e.textContent = o[1] + ' / page'; sel.appendChild(e);
  });
  var prev = document.createElement('button'); prev.textContent = '‹';
  var next = document.createElement('button'); next.textContent = '›';
  var info = document.createElement('span'); info.className = 'info';
  bar.appendChild(inp); bar.appendChild(sel);
  bar.appendChild(prev); bar.appendChild(next); bar.appendChild(info);
  t.parentNode.insertBefore(bar, t);

  var page = 0, filter = '';
  function size() { return sel.value === 'all' ? Infinity : parseInt(sel.value, 10); }
  function matching() {
    return rows.filter(function (r) {
      return !filter || r.textContent.toLowerCase().indexOf(filter) !== -1;
    });
  }
  function render() {
    var v = matching(), s = size();
    var pages = Math.max(1, Math.ceil(v.length / s));
    if (page >= pages) page = pages - 1;
    var from = page * s;
    rows.forEach(function (r) { r.style.display = 'none'; r.classList.remove('alt'); });
    v.slice(from, from + s).forEach(function (r, i) {
      r.style.display = '';
      if (i % 2 === 1) r.classList.add('alt');
    });
    var shown = Math.min(v.length, from + s);
    info.textContent = v.length === 0 ? 'no rows match'
      : (from + 1) + '–' + shown + ' of ' + v.length + ' rows';
    prev.disabled = page === 0; next.disabled = page >= pages - 1;
  }
  inp.addEventListener('input', function () { filter = inp.value.toLowerCase(); page = 0; render(); });
  sel.addEventListener('change', function () { page = 0; render(); });
  prev.addEventListener('click', function () { if (page > 0) { page--; render(); } });
  next.addEventListener('click', function () { page++; render(); });

  function cellVal(r, i, numeric) {
    var c = r.cells[i]; if (!c) return numeric ? null : '';
    var txt = c.textContent.trim();
    if (!numeric) return txt.toLowerCase();
    var m = txt.match(/-?[0-9]+(\.[0-9]+)?/);
    return m ? parseFloat(m[0]) : null;
  }
  Array.prototype.forEach.call(head.cells, function (th, i) {
    th.addEventListener('click', function () {
      var dir = th.dataset.d === 'a' ? 'd' : 'a';
      Array.prototype.forEach.call(head.cells, function (h) { delete h.dataset.d; });
      th.dataset.d = dir;
      var numeric = rows.some(function (r) { return r.cells[i] && r.cells[i].classList.contains('n'); });
      rows.sort(function (a, b) {
        var x = cellVal(a, i, numeric), y = cellVal(b, i, numeric);
        if (numeric) {
          // missing values sort last in BOTH directions
          if (x === null || y === null) return x === null && y === null ? 0 : (x === null ? 1 : -1);
        }
        var c = x < y ? -1 : x > y ? 1 : 0;
        return dir === 'a' ? c : -c;
      });
      rows.forEach(function (r) { body.appendChild(r); });
      render();
    });
  });
  render();
});
</script>
EOF
