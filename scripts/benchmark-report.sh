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
# the page. Every column header carries plain-language help — what the value
# measures, which direction is better, its range, and what a bad value costs —
# from the TIPS dictionary below, the single home of that text.
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
# prices), parsed by the shared reader in lib/prices.sh — one home, one parse,
# so the weekly trend report prices identically. Missing file/section → [].
CONFIG_MD="${BENCH_CONFIG:-${HOME:-/home/agent}/work/CONFIG.md}"
PRICES='[]'
if [ -f "$SCRIPT_DIR/lib/prices.sh" ]; then
  . "$SCRIPT_DIR/lib/prices.sh" 2>/dev/null
  PRICES="$(prices_json "$CONFIG_MD")"
fi
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
  # finding_accuracy alone: a run whose true positives matched the manifest by
  # position rather than by mechanism reads high on f1 and low here
  def fixture_find_acc: (.first.judge.finding_accuracy // null);
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

# Column help, keyed by the header label — THE single home of the reader-facing
# column semantics, for both tables (a label the dictionary does not know simply
# gets no help text). Each entry says in plain words what the column measures,
# which direction is better, its range, and what a bad value costs. It is
# rendered as the header `title`, so the help survives with JavaScript off; the
# page script moves it into a styled bubble.
TIPS='{
"run": "Date and time (UTC) of the benchmark run. One row is one full replay of the fixture set. Not a score.",
"trigger": "Why the run started: scheduled (the monthly tick), manual (the operator asked) or trial (a test of a branch). Only scheduled runs make the regular baseline. Not a score.",
"model": "The exact model that did the reviews. Compare rows of the same model to see what a definition change did. A different model moves almost every number.",
"version": "The agent definition version under test. If a number moves between two versions, the table of definition changes below shows what changed.",
"harness": "The version of the software that runs the agent. A change here can move speed and token counts without any change of the definition.",
"fixtures": "How many test projects the run scored. More is more stable. A run with fewer fixtures than its neighbours is not fully comparable.",
"index": "The single quality number, 0 to 1 — higher is better. It mixes the scores that matter most: defects found, correct severity, correct re-review, no circles. Near 0.9 is very good, below 0.5 the review misses much. It uses the deterministic scorer only, so the judge cannot move it.",
"avg f1": "Balance of the two errors, averaged over the fixtures: 0 to 1, higher is better. 1.0 means the review found every defect and reported nothing false. A low value can come from misses, from false alarms, or from both.",
"f1": "Balance of the two errors: 0 to 1, higher is better. 1.0 means the review found every defect and reported nothing false. Read it with prec and rec to see which of the two is weak.",
"prec": "Precision: the share of the blocking findings that are real, 0 to 1 — higher is better. Low precision means false alarms, and false alarms make the author stop reading the review.",
"rec": "Recall: the share of the known defects that the review found, 0 to 1 — higher is better. Low recall means defects reach production.",
"hard": "Recall on the defects the fixture marks hard — they need reasoning across files, not a text pattern. 0 to 1, higher is better. This is the headroom of the configuration. It stays out of the index, so old runs remain comparable.",
"avg sev": "Severity accuracy, averaged over the fixtures: the share of the correct findings that also got the correct severity. 0 to 1, higher is better. A blocker called a warning lets bad code merge.",
"sev": "Severity accuracy: the share of the correct findings that also got the correct severity. 0 to 1, higher is better. A blocker called a warning lets bad code merge.",
"avg fixed": "Re-review, averaged over the fixtures: the share of the truly fixed defects that the review recognized as fixed. 0 to 1, higher is better. A low value means the review asks again for work that is done.",
"fixed": "Re-review: the share of the truly fixed defects that the review recognized as fixed. 0 to 1, higher is better. A low value means the review asks again for work that is done.",
"avg new": "Re-review, averaged over the fixtures: the share of the newly added defects that the review found. 0 to 1, higher is better. A low value means new defects enter with the fix commits.",
"new": "Re-review: the share of the newly added defects that the review found. 0 to 1, higher is better. A low value means new defects enter with the fix commits.",
"circles": "Count of going-in-circles events in the whole run (churn plus false-fixed). 0 is the target. Each event sends the author into a loop, or approves a defect that is still there.",
"FPs": "Count of false alarms: blocking findings that match no known defect. Lower is better, 0 is best. Each one costs the author time and trust. It is a count, so it grows with the number of fixtures.",
"fp": "Count of false alarms in this fixture: blocking findings that match no known defect. Lower is better, 0 is best. Each one costs the author time and trust.",
"judge": "Average score of the language-model judge, on its own scale of 1 to 5 — higher is better, below 3 is weak. It rates what a script cannot measure: clear text, correct classes, usable fix lines. It never enters the index, because a judge can drift between runs.",
"find-acc": "One question to the judge: do the correct findings name the real defect? 1 to 5, higher is better. A high f1 beside a low find-acc is a warning — the review hit the correct lines but gave the wrong cause.",
"words": "Length of the first review in words. Not a score, but a long review hides its important findings. More words at an unchanged f1 means more text, not more value.",
"churn": "Count of new blocking findings that sit on a fix the last review asked for — the review attacks its own instruction. 0 is the target; above 0 the author is in a loop.",
"false-fixed": "Count of defects the re-review reports as fixed while they are still in the code. 0 is the target. This is the most dangerous error, because it approves a defect.",
"late": "Count of defects that were already in the first version but are reported as new only now. Not an error by itself: it shows what the first review missed.",
"sec": "Wall-clock seconds of the reviews. Lower is better, but only at equal quality — a fast review with a low index is not a better review. Platform load also moves this value.",
"out-tok": "How many tokens the model wrote. At equal quality, lower is better: output tokens are the most expensive part of a run. A dash means the harness gave no counters.",
"est $": "Estimated cost of the run in US dollars: the counted tokens priced with the table in CONFIG.md. Lower is better at equal quality. It is an estimate — a stale price row makes every value wrong, and a dash means no prices or no counters."
}'

# renders one header cell with its help text from $TIPS
JQ_TH='
  def th($l): ($tips[$l] // "") as $t
    | "<th" + (if $t == "" then "" else " title=\"\($t | @html)\"" end)
      + ">\($l | @html)</th>";
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
    + ($fx | avg(fixture_find_acc) | ncell)
    + "<td class=n>\($sec | fmt)\(delta($sec; $prev | run_secs; -1))</td>"
    + "<td class=n>\($tok | fmt)\(delta($tok; $prev | run_out_tokens; -1))</td>"
    + "<td class=n>\(if $cost == null then "<span class=dash>—</span>" else "$\($cost)" end)\(delta($cost; $prev | run_cost; -1))</td></tr>"')"

FIXTURE_SECTIONS="$(printf '%s' "$ALL" | jq -r --argjson prices "$PRICES" \
  --argjson tips "$TIPS" "$JQ_COMMON$JQ_TH"'
  . as $all
  | ([.[] | (.fixtures // {}) | keys[]] | unique) as $slugs
  | $slugs[] as $s
  | "<h2>\($s | @html)</h2>\n<div class=scroll>\n<table>\n<tr>"
    + ([ "run", "model", "index", "judge", "find-acc", "f1", "prec", "rec",
         "hard", "sev", "fp", "words", "fixed", "new", "churn", "false-fixed",
         "late", "sec", "out-tok" ] | map(th(.)) | add)
    + "</tr>\n"
    + ([$all[] | select((.fixtures // {}) | has($s))
        | (.fixtures[$s]) as $f
        | ($f | fixture_index) as $fi
        | "<tr><td>\(.ts | fmt | @html)</td><td>\(.model // "—" | @html)</td>"
          + "<td class=\"n idx\"><b>\($fi | fmt)</b>\($fi | bar)</td>"
          + ($f | fixture_judge | ncell)
          + ($f | fixture_find_acc | ncell)
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

HEAD_ALL="$(jq -rn --argjson tips "$TIPS" "$JQ_TH"'
  [ "run", "trigger", "model", "version", "harness", "fixtures", "index",
    "avg f1", "avg sev", "avg fixed", "avg new", "circles", "FPs", "judge",
    "find-acc", "sec", "out-tok", "est $" ] | map(th(.)) | add')"

GENERATED="$(printf '%s' "$ALL" | jq -r '(last // {}) | .ts // "no runs yet"')"

# The page body. This heredoc is expanded, which is how the ${VARS} above reach
# it — so page text, CSS and script must carry no backtick and no bare `$`: the
# shell would run it as a command substitution and print the result into the
# page.
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
/* a column with help text is marked by a dotted underline; the text itself
   ships as the header title (readable with no JS) and the script below moves it
   into the bubble, because a native title is clipped by the scroller */
th[title],th[data-tip]{text-decoration:underline dotted var(--rule-strong);
  text-underline-offset:3px}
th[data-tip]:focus-visible{color:var(--ink);outline:2px solid var(--seq);
  outline-offset:-2px}
.tip{position:fixed;display:none;z-index:9;max-width:26rem;
  padding:.5rem .65rem;font-size:.78rem;font-weight:400;line-height:1.45;
  white-space:normal;color:var(--ink);background:var(--surface);
  border:1px solid var(--rule-strong);border-radius:6px;
  box-shadow:0 4px 14px color-mix(in srgb,var(--ink) 22%,transparent)}
.tip b{display:block;margin-bottom:.15rem}
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
<p class="meta">Latest run: ${GENERATED} · ${RUNS} run(s) on record.
<b>Hold the pointer on a column name</b> — or move the keyboard focus to it — to
read what that column measures, which direction is better, and what a bad value
costs. A "—" is data that was not measured, never a zero. The bar under each
index is that same 0–1 value; unbounded columns get no bar. Deltas (▲▼) compare
against the previous run of the <b>same model</b> — green means moved the good
way for that column, so ▼ on sec/tokens/cost is green. Cross-model comparison is
the table itself. The index is deterministic — computed from scorer output only,
judge scores never enter it. Click a header to sort, type to filter, page long
histories. Full semantics: docs/benchmark.md.</p>
<h2>All runs</h2>
<div class=scroll>
<table>
<tr>${HEAD_ALL}</tr>
${ROWS_ALL}
</table>
</div>
${VERSION_CHANGES}
${FIXTURE_SECTIONS}
<script>
// Client-side sort / filter / paging — no external assets (sealed artifact
// iframes allow no network). Click a header to sort (numeric columns by their
// leading number, "—" sorts last); the box filters rows by substring; long
// histories page.
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

// Column help. Every header carries its plain-language text in its title
// attribute, so the help is readable with the script disabled. One shared bubble
// replaces it here:
// a native title inside the horizontal scroller is slow, truncated and untouched
// by the light/dark tokens. Headers also become focusable, so the help and the
// sort both work from the keyboard.
(function () {
  var tip = document.createElement('div');
  tip.className = 'tip'; tip.id = 'col-tip'; tip.setAttribute('role', 'tooltip');
  document.body.appendChild(tip);
  var open = null;
  function hide() {
    if (open) open.removeAttribute('aria-describedby');
    open = null; tip.style.display = 'none';
  }
  function show(th) {
    var txt = th.getAttribute('data-tip'); if (!txt) return;
    var label = document.createElement('b'); label.textContent = th.textContent.trim();
    tip.textContent = ''; tip.appendChild(label);
    tip.appendChild(document.createTextNode(txt));
    tip.style.display = 'block'; tip.style.left = '0px'; tip.style.top = '0px';
    var r = th.getBoundingClientRect(), b = tip.getBoundingClientRect();
    var x = Math.min(Math.max(4, r.left), Math.max(4, window.innerWidth - b.width - 4));
    var y = r.bottom + 6;
    if (y + b.height > window.innerHeight - 4) y = Math.max(4, r.top - b.height - 6);
    tip.style.left = x + 'px'; tip.style.top = y + 'px';
    th.setAttribute('aria-describedby', 'col-tip'); open = th;
  }
  document.querySelectorAll('th[title]').forEach(function (th) {
    th.setAttribute('data-tip', th.getAttribute('title'));
    th.removeAttribute('title');
    th.tabIndex = 0;
    th.addEventListener('mouseenter', function () { show(th); });
    th.addEventListener('mouseleave', hide);
    th.addEventListener('focus', function () { show(th); });
    th.addEventListener('blur', hide);
    th.addEventListener('keydown', function (e) {
      if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); th.click(); }
      else if (e.key === 'Escape') hide();
    });
  });
  // any scroll moves the header out from under a bubble anchored to the viewport
  window.addEventListener('scroll', hide, true);
})();
</script>
EOF
