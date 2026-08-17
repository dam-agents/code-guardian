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
# all-runs table also prints the delta against the previous run OF THE SAME
# MODEL for index, seconds, output tokens, and cost — the regression signal
# for quality, speed, and cost (a cross-model delta conflates the model change
# with everything else; the table itself is the cross-model comparison).
#
# The `est $` column prices each run's summed token counters with the
# operator-maintained `## Benchmark model prices` table in work/CONFIG.md
# (USD per MTok: input, output, cache_read, cache_write; rows matched as a
# substring of the run's model id — docs/benchmark.md → Model prices). No
# table, no matching row, or no measured tokens → "—", never a guess.
# `BENCH_CONFIG` overrides the CONFIG.md path (tests).
# `benchmark-report.sh index <dir>` prints the same per-run index (plus cost)
# as JSON for chat summaries and trial comparisons.
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

# Tolerant per-file load: one corrupt/truncated results file is skipped with
# its data alone — it never discards the rest of the history. `fixtures`
# written as an array (a pre-validation shape drift) is keyed back by its
# `fixture` field, so an old run still renders under its slug instead of
# under 0,1,2… — history is append-only, so the reader tolerates what is
# already stored (benchmark-validate.sh keeps new writes to the object shape).
# operator-maintained price table (work/CONFIG.md → ## Benchmark model
# prices): markdown rows | model substring | input | output | cache_read |
# cache_write |, USD per MTok. Header/separator rows drop out because their
# price cells do not parse as numbers. Missing file/section → [].
CONFIG_MD="${BENCH_CONFIG:-${HOME:-/home/agent}/work/CONFIG.md}"
PRICES="$(sed -n '/^## Benchmark model prices/,/^## [^B]/p' "$CONFIG_MD" 2>/dev/null \
  | grep '^|' \
  | jq -Rn '[inputs | split("|") | map(gsub("^\\s+|\\s+$"; ""))
             | select(length >= 6)
             | {m: .[1], i: (.[2] | tonumber?), o: (.[3] | tonumber?),
                cr: (.[4] | tonumber?), cw: (.[5] | tonumber?)}
             | select(.m != "" and .i != null and .o != null
                      and .cr != null and .cw != null)]' 2>/dev/null)"
PRICES="${PRICES:-[]}"

ALL="$(for f in "$DIR"/results/*.json; do
         [ -f "$f" ] || continue
         jq -c 'select(type == "object")
                | if (.fixtures | type) == "array"
                  then .fixtures = (reduce .fixtures[] as $e ({};
                         . + {($e.fixture // "unnamed"): ($e | del(.fixture))}))
                  else . end' "$f" 2>/dev/null || true
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
  # estimated run cost in USD from the CONFIG price table ($prices global);
  # null without measured tokens or a matching price row — never a guess
  def run_cost:
    ([.fixtures // {} | .[] | (.first.tokens?, .rereview.tokens?)
      | select(type == "object")]) as $t
    | (.model // "") as $m
    | ([$prices[] | select(. as $p | $m | contains($p.m))] | first) as $p
    | if ($t | length) == 0 or $p == null then null
      else ((([$t[].input // 0] | add) * $p.i + ([$t[].output // 0] | add) * $p.o
             + ([$t[].cache_read // 0] | add) * $p.cr
             + ([$t[].cache_creation // 0] | add) * $p.cw) / 1000000
            | (. * 100 | round) / 100) end;
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
  # delta vs the previous same-model run. The arrow duplicates the sign so the
  # direction never rests on color alone; $g flips which direction is "good"
  # (1 = higher is better, -1 = lower is better, as for seconds/tokens/cost).
  def delta($c; $p; $g): if $c == null or $p == null then ""
    else (($c - $p) | r3) as $d
      | (if $d == 0 then "z" elif ($d * $g) > 0 then "up" else "down" end) as $cls
      | (if $d > 0 then "▲+\($d)" elif $d < 0 then "▼\($d)" else "±0" end) as $txt
      | " <span class=\"d \($cls)\">\($txt)</span>" end;
  def delta($c; $p): delta($c; $p; 1);
  # thin magnitude bar for a bounded 0–1 score, drawn under the value
  def bar: if . == null then "" else
    "<span class=bar style=\"width:\((. * 100 | round) | if . < 2 then 2 else . end)%\"></span>" end;
  # "—" cells carry a muted class so missing data recedes instead of reading as a value
  def ncell: if . == null then "<td class=\"n dash\">—</td>" else "<td class=n>\(.)</td>" end;
'

if [ "$OUT_MODE" = "index" ]; then
  printf '%s' "$ALL" | jq --argjson prices "$PRICES" "$JQ_COMMON"'
    [.[] | {ts, trigger, model, definition_version,
            index: run_index, seconds: run_secs, output_tokens: run_out_tokens,
            cost_usd: run_cost,
            fixtures: ((.fixtures // {}) | with_entries(.value |= fixture_index))}]'
  exit 0
fi

ROWS_ALL="$(printf '%s' "$ALL" | jq -r --argjson prices "$PRICES" "$JQ_COMMON"'
  . as $all | to_entries[] | .key as $i | .value as $r
  # deltas compare against the previous run of the SAME model — a cross-model
  # delta would conflate the model change with the regression being watched
  | ([$all[0:$i][] | select(.model == $r.model)] | last) as $prev
  | ($r.fixtures // {} | [.[]]) as $fx
  | ($r | run_index) as $idx
  | ($r | run_secs) as $sec
  | ($r | run_out_tokens) as $tok
  | ($r | run_cost) as $cost
  | "<tr><td>\($r.ts | fmt | @html)</td><td>\($r.trigger // "—" | @html)</td>"
    + "<td>\($r.model // "—" | @html)</td><td>\($r.definition_version // "—" | @html)</td>"
    + "<td>\($r.harness_version // "—" | @html)</td>"
    + "<td class=n>\($fx | length)</td>"
    + "<td class=\"n idx\"><b>\($idx | fmt)\(delta($idx; $prev | run_index))</b>\($idx | bar)</td>"
    + ($fx | avg(.first.f1) | ncell)
    + ($fx | avg(.first.severity_accuracy) | ncell)
    + ($fx | avg(.rereview.fixed_recall) | ncell)
    + ($fx | avg(.rereview.new_recall) | ncell)
    + ($fx | total(if .rereview == null then null
                   else ((.rereview.churn // 0) + (.rereview.false_fixed // 0)) end) | ncell)
    + ($fx | total(.first.fp | if . == null then null else length end) | ncell)
    + ($fx | avg(fixture_judge) | ncell)
    + "<td class=n>\($sec | fmt)\(delta($sec; $prev | run_secs; -1))</td>"
    + "<td class=n>\($tok | fmt)\(delta($tok; $prev | run_out_tokens; -1))</td>"
    + "<td class=n>\(if $cost == null then "<span class=dash>—</span>" else "$\($cost)" end)\(delta($cost; $prev | run_cost; -1))</td></tr>"')"

FIXTURE_SECTIONS="$(printf '%s' "$ALL" | jq -r --argjson prices "$PRICES" "$JQ_COMMON"'
  . as $all
  | ([.[] | (.fixtures // {}) | keys[]] | unique) as $slugs
  | $slugs[] as $s
  | "<h2>\($s | @html)</h2>\n<div class=scroll>\n<table>\n<tr><th>run</th><th>model</th><th>index</th><th>judge</th>"
    + "<th>f1</th><th>prec</th><th>rec</th><th>hard</th><th>sev</th><th>fp</th><th>words</th>"
    + "<th>fixed</th><th>new</th><th>churn</th><th>false-fixed</th><th>late</th>"
    + "<th>sec</th><th>out-tok</th></tr>\n"
    + ([$all[] | select((.fixtures // {}) | has($s))
        | (.fixtures[$s]) as $f
        | ($f | fixture_index) as $fi
        | "<tr><td>\(.ts | fmt | @html)</td><td>\(.model // "—" | @html)</td>"
          + "<td class=\"n idx\"><b>\($fi | fmt)</b>\($fi | bar)</td>"
          + ($f | fixture_judge | ncell)
          + ($f.first.f1 | ncell)
          + ($f.first.precision | ncell)
          + ($f.first.recall | ncell)
          + ($f.first.recall_hard | ncell)
          + ($f.first.severity_accuracy | ncell)
          + ($f.first.fp | if . == null then null else length end | ncell)
          + ($f.first.length.words_total | ncell)
          + ($f.rereview.fixed_recall | ncell)
          + ($f.rereview.new_recall | ncell)
          + ($f.rereview.churn | ncell)
          + ($f.rereview.false_fixed | ncell)
          + ($f.rereview.late_finds | ncell)
          + ([$f | .first.seconds, .rereview.seconds] | total(.) | ncell)
          + ([$f | .first.tokens.output?, .rereview.tokens.output?] | total(.) | ncell) + "</tr>"]
       | join("\n"))
    + "\n</table>\n</div>"')"

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
/* Role tokens; both modes selected (never an automatic flip). Values and the
   validated light/dark steps come from the data-viz palette — swapping a brand
   palette means editing only this block. */
:root{
  color-scheme:light dark;
  --surface:#fcfcfb;--plane:#f9f9f7;--head:#f2f2f0;
  --ink:#0b0b0b;--ink-2:#52514e;--ink-muted:#898781;
  --rule:#e1e0d9;--rule-strong:#c3c2b7;
  --seq:#2a78d6;--good:#006300;--bad:#d03b3b;
}
@media (prefers-color-scheme:dark){:root{
  --surface:#1a1a19;--plane:#0d0d0d;--head:#232322;
  --ink:#fff;--ink-2:#c3c2b7;--ink-muted:#898781;
  --rule:#2c2c2a;--rule-strong:#383835;
  --seq:#3987e5;--good:#0ca30c;--bad:#e66767;
}}
body{font-family:system-ui,-apple-system,'Segoe UI',sans-serif;margin:0 auto;
  padding:2rem 1rem;max-width:84rem;color:var(--ink);background:var(--plane);
  line-height:1.5;-webkit-text-size-adjust:100%}
h1{font-size:1.35rem;letter-spacing:-.01em;margin:0 0 .4rem}
h2{font-size:1.05rem;letter-spacing:-.005em;margin:2.2rem 0 .3rem;
  padding-bottom:.25rem;border-bottom:1px solid var(--rule-strong)}
h3{font-size:.9rem;margin:1rem 0 .2rem;color:var(--ink-2)}
p.meta{color:var(--ink-2);font-size:.82rem;max-width:60rem;margin:.3rem 0 1.4rem}
/* horizontal scroller: these tables run to ~17 columns. Vertical sticky headers
   would conflict with it (an overflow-x container also scrolls y), and paging
   already bounds row count — so scroll wins over sticky here. */
.scroll{overflow-x:auto;background:var(--surface);border:1px solid var(--rule);
  border-radius:6px}
table{border-collapse:collapse;width:100%;font-size:.82rem;margin:0}
/* hairline horizontal rules only — a full grid on every cell reads as noise */
th,td{padding:.36rem .6rem;text-align:left;border-bottom:1px solid var(--rule);
  white-space:nowrap}
th{background:var(--head);cursor:pointer;user-select:none;font-weight:600;
  color:var(--ink-2);position:relative}
th:hover{color:var(--ink)}
th[data-d="a"]::after{content:" ▲";color:var(--seq)}
th[data-d="d"]::after{content:" ▼";color:var(--seq)}
tbody tr:last-child td{border-bottom:0}
td.n{text-align:right;font-variant-numeric:tabular-nums}
tr.alt td{background:color-mix(in srgb,var(--ink) 3%,transparent)}
tr:hover td{background:color-mix(in srgb,var(--seq) 8%,transparent)}
/* index cell: value plus a thin magnitude bar. Honest because the index is a
   bounded 0–1 scale anchored at a shared left baseline; unbounded columns
   (sec, tokens, cost) get no bar — there is no non-arbitrary maximum. */
td.idx .bar{display:block;height:3px;margin-top:3px;border-radius:2px;
  background:var(--seq);min-width:1px}
/* deltas: arrow duplicates the sign, so color is never the only signal */
.d{font-size:.75rem;font-weight:400;font-variant-numeric:tabular-nums;white-space:nowrap}
.d.up{color:var(--good)}.d.down{color:var(--bad)}.d.z{color:var(--ink-muted)}
td.dash{color:var(--ink-muted)}
.tbar{display:flex;gap:.5rem;align-items:center;font-size:.8rem;margin:.6rem 0 .35rem}
.tbar input,.tbar select,.tbar button{font:inherit;padding:.2rem .45rem;
  color:var(--ink);background:var(--surface);
  border:1px solid var(--rule-strong);border-radius:4px}
.tbar button{cursor:pointer;min-width:1.9rem}
.tbar button:hover:not(:disabled){border-color:var(--seq);color:var(--seq)}
.tbar button:disabled{opacity:.35;cursor:default}
.tbar .info{color:var(--ink-muted);margin-left:auto;font-variant-numeric:tabular-nums}
ul{margin:.2rem 0 .6rem;padding-left:1.1rem;font-size:.82rem;color:var(--ink-2)}
li{margin:.1rem 0}
</style>
<h1>Review benchmark — accumulated results</h1>
<p class="meta">Latest run: ${GENERATED} · ${RUNS} run(s) on record. Scores 0–1,
higher is better; sec = wall-clock seconds, out-tok = output tokens, est $ =
tokens priced by the CONFIG model-price table (— = not measured / not priced).
The bar under each index is that same 0–1 value; unbounded columns get no bar.
Deltas (▲▼) compare against the previous run of the <b>same model</b> — green
means moved the good way for that column, so ▼ on sec/tokens/cost is green.
Cross-model comparison is the table itself. The index is deterministic —
computed from scorer output only, judge scores never enter it (the judge column
is its own 1–5 scale; hard = recall on defects the manifest marks hard,
reported beside the index, never inside it). Click a header to sort, type to
filter, page long histories. Semantics: docs/benchmark.md.</p>
<h2>All runs</h2>
<div class=scroll>
<table>
<tr><th>run</th><th>trigger</th><th>model</th><th>version</th><th>harness</th>
<th>fixtures</th><th>index</th><th>avg f1</th><th>avg sev</th><th>avg fixed</th>
<th>avg new</th><th>circles</th><th>FPs</th><th>judge</th><th>sec</th><th>out-tok</th><th>est $</th></tr>
${ROWS_ALL}
</table>
</div>
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
  // the toolbar goes ABOVE the horizontal scroller, not inside it — otherwise
  // the controls scroll sideways out of view with the table
  var anchor = t.closest('.scroll') || t;
  anchor.parentNode.insertBefore(bar, anchor);

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
