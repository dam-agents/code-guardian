#!/usr/bin/env bash
# benchmark-report.sh — render the accumulated benchmark report as one
# self-contained HTML page on stdout (docs/benchmark.md → Running the
# benchmark, phase 2).
#
#   benchmark-report.sh <work/benchmark dir>
#
# Reads every scored run in <dir>/results/*.json (a multi-model run writes one
# file per model, joined by `run_id`) and prints the complete comparison: run tables (per run: model, effort, definition version, averaged
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
# their own 1–5 scale, reported beside the index, never mixed into it, and
# only for a run whose `judge_model_used` the pinned `judge` matches. The
# all-runs table also prints the delta against the previous run OF THE SAME
# HARNESS, MODEL AND EFFORT for index, seconds, output tokens, and cost — the regression
# signal for quality, speed, and cost (a cross-model or cross-effort delta
# conflates that change with everything else; the table itself is the
# cross-configuration comparison). A run without `effort` (written before it
# was recorded) compares only with another run without it; a run at effort
# "unknown" gets no delta.
#
# The `est $` column prices each run's summed token counters with the
# operator-maintained `## Benchmark model prices` table in work/CONFIG.md
# (USD per MTok: input, output, cache_read, cache_write; a row matches the
# run's model id per docs/benchmark.md → Model prices). No
# table, no matching row, or no measured tokens → "—", never a guess.
# The "Sufficiency by task tier" table answers "is this configuration good
# enough for simple work, and for complex work?": per configuration (harness,
# model, effort, isolation) its latest run, the fixtures of each manifest tier
# pooled into one sample, judged against the `## Benchmark sufficiency` bar in
# work/CONFIG.md (lib/sufficiency.sh — the single home of the bar and the
# verdict rule). It reads beside the index, never inside it.
# Layers (docs/benchmark.md → **Report layers**): Measured columns plain,
# Assessed (judge panel) columns tinted, the Recommended block (the run's
# `recommendation` beside its paired `comparison` rows) boxed apart. The run
# table splits into the core set (regression, deltas) and the adaptive set (no
# deltas); `restrict` keys a fixture by its `part` (absent = core). "Recall by
# language" pools the scorer's `languages` per model, under the
# `## Benchmark languages` minimum (lib/sufficiency.sh → languages_json).
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

# operator-maintained price table (work/CONFIG.md → ## Benchmark model
# prices), parsed by the shared reader in lib/prices.sh — one home, one parse,
# so the weekly trend report prices identically. Missing file/section → [].
CONFIG_MD="${BENCH_CONFIG:-${HOME:-/home/agent}/work/CONFIG.md}"
. "$SCRIPT_DIR/lib/prices.sh"
. "$SCRIPT_DIR/lib/sufficiency.sh"  # sufficiency_json, SUFFICIENCY_JQ
. "$SCRIPT_DIR/lib/report-tip.sh"   # REPORT_TIP_CSS, REPORT_TIP_JS
PRICES="$(prices_json "$CONFIG_MD")"
BAR="$(sufficiency_json "$CONFIG_MD")"
LANGS="$(languages_json "$CONFIG_MD")"
# the operator's decision rule (docs/benchmark.md → **Decision rule**), shown
# above every recommendation; missing = cheapest_not_worse
RULE="$(CONFIG="$CONFIG_MD" cfg benchmark_decision_rule 2>/dev/null)"; RULE="${RULE:-cheapest_not_worse}"

# Tolerant per-file load: one corrupt/truncated results file is skipped with
# its data alone — it never discards the rest of the history. `fixtures`
# written as an array (a pre-validation shape drift) is keyed back by its
# `fixture` field, so an old run still renders under its slug instead of
# under 0,1,2… — history is append-only, so the reader tolerates what is
# already stored (benchmark-validate.sh keeps new writes to the object shape).
ALL="$(for f in "$DIR"/results/*.json; do
         [ -f "$f" ] || continue
         jq -c 'select(type == "object")
                | if (.fixtures | type) == "array"
                  then .fixtures = (reduce .fixtures[] as $e ({};
                         . + {($e.fixture // "unnamed"): ($e | del(.fixture))}))
                  else . end' "$f" 2>/dev/null || true
       done | jq -s 'sort_by(.ts // "")')"
RUNS="$(printf '%s' "$ALL" | jq length)"

JQ_COMMON="$PRICES_JQ$SUFFICIENCY_JQ"'
  def fmt: if . == null then "—" else tostring end;
  # one configuration = one harness, model, effort and isolation. The harness
  # is the first word of harness_version — pi, copilot — (lib/harness.sh);
  # every other run, the ones before named lines included, is Claude Code. A
  # run before isolation was recorded ran in-pod: none.
  def harness_of: (.harness_version // "" | if startswith("pi ") then "pi"
                   elif startswith("copilot ") then "copilot" else "claude-code" end);
  def isolation_of: (.isolation // "none");
  # first-review recall over every fixture of a run for one defect
  # difficulty, pooled from the scorer counts; null on runs before the counts
  def run_difficulty($d):
    [.fixtures // {} | .[] | .first.difficulty[$d]? | select(type == "object")] as $c
    | if ($c | length) == 0 then null
      else ratio([$c[].tp] | add; [$c[].gt] | add) end;
  def run_tiers: [.fixtures // {} | .[]] as $fx
    | reduce ("simple", "complex") as $t ({};
        ($fx | tier_stats($t)) as $s
        | . + {($t): (if $s == null then null else $s + {verdict: ($s | tier_verdict($t))} end)});
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
    | price_row(.model // "") as $p
    | if ($t | length) == 0 or $p == null then null
      else ({input: ([$t[].input // 0] | add), output: ([$t[].output // 0] | add),
             cache_read: ([$t[].cache_read // 0] | add), cache_creation: ([$t[].cache_creation // 0] | add)}
            | token_usd($p) | (. * 100 | round) / 100) end;
  def bools($o): [$o // {} | to_entries[] | .value | select(type == "boolean")];
  def jnums($o): [$o // {} | to_entries[] | select(.key != "disagreement") | .value | numbers];
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
  # judge scores count only from a run whose judge was the pinned model
  # (benchmark-judge.sh): a run judged by its own tested model, or one that
  # never recorded who judged, renders its judge cells as "—"
  def run_judged: (.judge // "" | tostring) as $j | (.judge_model_used // "" | tostring) as $u
    | ((.judge_panel // [$j]) | map(select(. != ""))) as $p
    | $j != "" and $j != "off" and $u != "" and ($p | length) > 0
      and ($u | split(",") | map(gsub("^\\s+|\\s+$"; "")) | all(. as $x | any($p[]; . as $m | $x | model_has($m))));
  # the set part of a fixture (docs/benchmark.md → **Core and adaptive set**):
  # absent = core, so every run before the split reads as core
  def restrict($p): .fixtures = ((.fixtures // {}) | with_entries(select((.value.part // "core") == $p)));
  # Assessed layer: false positives the judge panel classed as real defects,
  # and the precision once those count as true
  def fx_fp_real: [.first.judge.fp_class[]? | select(.class == "real")] | length;
  def run_fp_real: if run_judged then [.fixtures // {} | .[] | fx_fp_real] | add // 0 else null end;
  def run_prec_assessed: if run_judged | not then null else
      [.fixtures // {} | .[] | .first] as $f
      | ([$f[] | .tp // [] | length] | add // 0) as $tp
      | ([$f[] | .fp // [] | length] | add // 0) as $fp
      | run_fp_real as $r
      | if ($tp + $fp) == 0 then null else ratio($tp + $r; $tp + $fp) end end;
  # the model that wrote the fixtures scores on its own set: marked, never hidden
  def is_author: (.model // "" | ascii_downcase) as $m
    | any((.author_models // {})[] | select(. != "unknown" and . != "") | ascii_downcase; . as $a | $m | contains($a));
  def model_cell: "<td>\(.model // "—" | @html)\(if is_author then " <span class=auth title=\"This model wrote the fixtures: its result can be too high.\">author</span>" else "" end)</td>";
  # pooled first-review recall per language (scorer `languages`)
  def run_languages: [.fixtures // {} | .[] | .first.languages // {} | to_entries[]]
    | group_by(.key) | map({key: .[0].key, value: {tp: ([.[].value.tp] | add), gt: ([.[].value.gt] | add)}})
    | from_entries;
  # delta vs the previous same-model, same-effort run. The arrow duplicates the sign so the
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
  # an Assessed-layer cell: same value rules, the layer tint
  def acell: if . == null then "<td class=\"n dash as\">—</td>" else "<td class=\"n as\">\(.)</td>" end;
'

# Column help, keyed by the header label — THE single home of the reader-facing
# column semantics, for both tables (a label the dictionary does not know simply
# gets no help text). Each entry says in plain words what the column measures,
# which direction is better, its range, and what a bad value costs. It is
# rendered as the header `title`, so the help survives with JavaScript off; the
# page script moves it into a styled bubble.
TIPS='{
"run": "Date and time (UTC) of the benchmark run. One row is one full replay of the fixture set. Not a score.",
"trigger": "Why the run started: manual (the operator asked, also after a version update), trial (a test of a branch), or scheduled (the old monthly tick, before 15.0.0). Not a score.",
"Measured": "Measured layer: values a script computes from the reviews and the known defects, plus time, tokens and cost. Deterministic — the same raw reviews give the same numbers. The known defects come from the fixture author, so read them as measured against that ground truth.",
"Assessed": "Assessed layer: values a judge panel of language models gives. The models are pinned, but a judge can drift, so these values never enter the index.",
"real FPs": "Assessed: false alarms that the judge panel classed as probably a real defect the fixture does not list. Not a review error — it is a defect that the ground truth misses.",
"prec*": "Assessed precision: precision when the false alarms the judge panel classed as real defects count as correct findings. Read it beside prec — the gap is what the ground truth misses.",
"model": "The exact model that did the reviews. The word author marks the model that wrote the fixtures — its result can be too high. Compare rows of the same model to see what a definition change did. A different model moves almost every number.",
"effort": "The reasoning effort the reviews ran at. Lower effort means less thought per review, and it moves recall and tokens as much as a model change. Compare rows of the same effort; a dash means the run did not record it, and unknown means the harness did not expose it — such a row gets no delta.",
"version": "The agent definition version under test. If a number moves between two versions, the table of definition changes below shows what changed.",
"harness": "The version of the software that runs the agent. A change here can move speed and token counts without any change of the definition.",
"isolation": "Where the reviews ran. platform-subagent: in separate sub-agents that could not read the known defects. none: in the agent itself, after the operator approved it, or before isolation existed. Compare rows of the same isolation.",
"fixtures": "How many test projects the run scored. More is more stable. A run with fewer fixtures than its neighbours is not fully comparable.",
"index": "The single quality number, 0 to 1 — higher is better. It mixes the scores that matter most: defects found, correct severity, correct re-review, no circles. Near 0.9 is very good, below 0.5 the review misses much. It uses the deterministic scorer only, so the judge cannot move it.",
"avg f1": "Balance of the two errors, averaged over the fixtures: 0 to 1, higher is better. 1.0 means the review found every defect and reported nothing false. A low value can come from misses, from false alarms, or from both.",
"f1": "Balance of the two errors: 0 to 1, higher is better. 1.0 means the review found every defect and reported nothing false. Read it with prec and rec to see which of the two is weak.",
"prec": "Precision: the share of the blocking findings that are real, 0 to 1 — higher is better. Low precision means false alarms, and false alarms make the author stop reading the review.",
"rec": "Recall: the share of the known defects that the review found, 0 to 1 — higher is better. Low recall means defects reach production.",
"easy": "Recall on the defects the fixture does not mark hard — a local mistake that a careful read of one place finds. 0 to 1, higher is better. Read it beside hard: a high easy and a low hard value means the configuration finds simple mistakes but misses the ones that need reasoning.",
"easy rec": "Recall on the defects not marked hard, over all fixtures of the run as one sample. 0 to 1, higher is better. A dash means a run before the counts were recorded.",
"hard rec": "Recall on the defects marked hard (reasoning across files or control flow), over all fixtures of the run as one sample. 0 to 1, higher is better. The gap to easy rec is what the configuration cannot yet do.",
"simple": "Verdict for simple tasks: small changes in few files. Sufficient means the pooled recall and precision of these fixtures meet the bar in CONFIG.md and no re-review called a present defect fixed. Too few defects means the sample is too small to decide. A re-review that called a present defect fixed makes it insufficient at any sample size.",
"complex": "Verdict for complex tasks: large changes across many files, with defects that need reasoning across them. Same bar and rule as simple. A configuration sufficient for simple but not for complex tasks fits only small pull requests.",
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
"judge": "Average score of the language-model judge, on its own scale of 1 to 5 — higher is better, below 3 is weak. It rates what a script cannot measure: clear text, correct classes, usable fix lines. It never enters the index, because a judge can drift between runs. A dash means no pinned judge scored the run — a run that its own tested model judged shows a dash too.",
"find-acc": "One question to the judge: do the correct findings name the real defect? 1 to 5, higher is better. A high f1 beside a low find-acc is a warning — the review hit the correct lines but gave the wrong cause. A dash means no pinned judge scored the run.",
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
  def tha($l): th($l) | sub("^<th"; "<th class=as");
  # the layer row above a table header (docs/benchmark.md → **Report layers**):
  # $r run columns, $m Measured, $a Assessed — in a thead, so the sort script
  # still finds the column row first in the body
  def layers($r; $m; $a): "<thead><tr class=lay><th colspan=\($r)></th>"
    + "<th colspan=\($m) class=lm title=\"\($tips["Measured"] | @html)\">Measured</th>"
    + "<th colspan=\($a) class=la title=\"\($tips["Assessed"] | @html)\">Assessed</th></tr></thead>\n";
'

if [ "$OUT_MODE" = "index" ]; then
  printf '%s' "$ALL" | jq --argjson prices "$PRICES" --argjson bar "$BAR" "$JQ_COMMON"'
    [.[] | {ts, trigger, model, effort, isolation: (.isolation // "none"), definition_version,
            index: run_index, seconds: run_secs, output_tokens: run_out_tokens,
            cost_usd: run_cost, tiers: run_tiers, run_id: (.run_id // .ts),
            core_version, index_core: (restrict("core") | run_index),
            index_adaptive: (restrict("adaptive") | run_index), languages: run_languages,
            fixtures: ((.fixtures // {}) | with_entries(.value |= fixture_index))}]'
  exit 0
fi

# one all-runs row per run that holds a fixture of part $1 (core | adaptive);
# only the core carries deltas — the adaptive part changes between runs by design
run_rows() { printf '%s' "$ALL" | jq -r --argjson prices "$PRICES" --argjson bar "$BAR" \
  --arg part "$1" "$JQ_COMMON"'
  [.[] | restrict($part) | select((.fixtures | length) > 0)]
  | . as $all | to_entries[] | .key as $i | .value as $r
  # deltas compare against the previous run of the SAME harness, model,
  # effort and isolation — a cross-configuration delta would conflate that
  # change with the regression being watched; an "unknown" effort matches
  # nothing.
  | (if $part != "core" or $r.effort == "unknown" then null
     else [$all[0:$i][] | select(.model == $r.model and .effort == $r.effort
                                 and harness_of == ($r | harness_of)
                                 and isolation_of == ($r | isolation_of))] | last
     end) as $prev
  | ($r.fixtures // {} | [.[]]) as $fx
  | ($r | run_index) as $idx
  | ($r | run_secs) as $sec
  | ($r | run_out_tokens) as $tok
  | ($r | run_cost) as $cost
  | "<tr><td>\($r.ts | fmt | @html)</td><td>\($r.trigger // "—" | @html)</td>"
    + ($r | model_cell) + "<td>\($r.effort // "—" | @html)</td>"
    + "<td>\($r.definition_version // "—" | @html)</td>"
    + "<td>\($r.harness_version // "—" | @html)</td>"
    + "<td>\($r | isolation_of | @html)</td>"
    + "<td class=n>\($fx | length)</td>"
    + "<td class=\"n idx\"><b>\($idx | fmt)\(delta($idx; $prev | run_index))</b>\($idx | bar)</td>"
    + ($fx | avg(.first.f1) | ncell)
    + ($r | run_difficulty("easy") | ncell)
    + ($r | run_difficulty("hard") | ncell)
    + ($fx | avg(.first.severity_accuracy) | ncell)
    + ($fx | avg(.rereview.fixed_recall) | ncell)
    + ($fx | avg(.rereview.new_recall) | ncell)
    + ($fx | total(if .rereview == null then null
                   else ((.rereview.churn // 0) + (.rereview.false_fixed // 0)) end) | ncell)
    + ($fx | total(.first.fp | if . == null then null else length end) | ncell)
    + "<td class=n>\($sec | fmt)\(delta($sec; $prev | run_secs; -1))</td>"
    + "<td class=n>\($tok | fmt)\(delta($tok; $prev | run_out_tokens; -1))</td>"
    + "<td class=n>\(if $cost == null then "<span class=dash>—</span>" else "$\($cost)" end)\(delta($cost; $prev | run_cost; -1))</td>"
    + (if $r | run_judged then $fx | avg(fixture_judge) else null end | acell)
    + (if $r | run_judged then $fx | avg(fixture_find_acc) else null end | acell)
    + ($r | run_fp_real | acell)
    + ($r | run_prec_assessed | acell) + "</tr>"'; }
ROWS_CORE="$(run_rows core)"
ROWS_ADAPTIVE="$(run_rows adaptive)"

FIXTURE_SECTIONS="$(printf '%s' "$ALL" | jq -r --argjson prices "$PRICES" --argjson bar "$BAR" \
  --argjson tips "$TIPS" "$JQ_COMMON$JQ_TH"'
  . as $all
  | ([.[] | (.fixtures // {}) | keys[]] | unique) as $slugs
  | $slugs[] as $s
  | ([$all[] | .fixtures[$s]?.first.tier // empty] | last // "simple") as $tier
  | ([$all[] | .fixtures[$s]?.part // empty] | last // "core") as $part
  | "<h2>\($s | @html) <span class=tier>\($tier | @html)</span>\(if $part == "core" then "" else " <span class=tier>\($part | @html)</span>" end)</h2>\n<div class=scroll>\n<table>\n"
    + layers(3; 16; 2) + "<tr>"
    + ([ "run", "model", "effort", "index", "f1", "prec", "rec",
         "easy", "hard", "sev", "fp", "words", "fixed", "new", "churn", "false-fixed",
         "late", "sec", "out-tok" ] | map(th(.)) | add)
    + ([ "judge", "find-acc" ] | map(tha(.)) | add)
    + "</tr>\n"
    + ([$all[] | select((.fixtures // {}) | has($s))
        | (.fixtures[$s]) as $f
        | ($f | fixture_index) as $fi
        | run_judged as $jd
        | "<tr><td>\(.ts | fmt | @html)</td>" + model_cell
          + "<td>\(.effort // "—" | @html)</td>"
          + "<td class=\"n idx\"><b>\($fi | fmt)</b>\($fi | bar)</td>"
          + ($f.first.f1 | ncell)
          + ($f.first.precision | ncell)
          + ($f.first.recall | ncell)
          + ($f.first.recall_easy | ncell)
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
          + ([$f | .first.tokens.output?, .rereview.tokens.output?] | total(.) | ncell)
          + (if $jd then $f | fixture_judge else null end | acell)
          + (if $jd then $f | fixture_find_acc else null end | acell) + "</tr>"]
       | join("\n"))
    + "\n</table>\n</div>"')"

# sufficiency by task tier: one row per configuration, its latest run. A
# verdict cell carries the pooled counts, so a reader sees the sample size
# behind it (lib/sufficiency.sh holds the bar and the rule).
SUFFICIENCY="$(printf '%s' "$ALL" | jq -r --argjson prices "$PRICES" --argjson bar "$BAR" \
  --argjson tips "$TIPS" "$JQ_COMMON$JQ_TH"'
  def vcell($s): if $s == null then "<td class=\"dash\">—</td>"
    else ({sufficient: ["ok", "✓ sufficient"], borderline: ["mid", "≈ borderline"],
           insufficient: ["no", "✗ insufficient"], few: ["mid", "too few defects"]}[$s.verdict]) as $v
      | "<td class=\"v \($v[0])\"><b>\($v[1])</b><br><span class=sub>rec \($s.recall | fmt) (\($s.tp)/\($s.gt))"
        + " · prec \($s.precision | fmt)"
        + (if $s.hard == null then "" else " · hard \($s.hard.recall | fmt) (\($s.hard.tp)/\($s.hard.gt))" end)
        + (if $s.false_fixed > 0 then " · false-fixed \($s.false_fixed)" else "" end)
        + "</span></td>" end;
  if length == 0 then "" else
    group_by([.model // "", .effort // "", harness_of, isolation_of])
    | map(last) | sort_by(.ts // "") | reverse
    | "<h2>Sufficiency by task tier</h2>\n<p class=\"meta\">The latest run of each configuration. "
      + "Every fixture of a tier is pooled into one sample and checked against the bar in CONFIG.md "
      + "(simple: recall ≥ \($bar.simple.recall), precision ≥ \($bar.simple.precision), ≥ \($bar.simple.min_defects) defects; "
      + "complex: recall ≥ \($bar.complex.recall), precision ≥ \($bar.complex.precision), ≥ \($bar.complex.min_defects) defects; "
      + "no false-fixed). Borderline is within 0.05 under the bar.</p>\n"
      + "<div class=scroll>\n<table>\n<tr>"
      + ([ "run", "model", "effort", "harness", "isolation", "simple", "complex" ] | map(th(.)) | add)
      + "</tr>\n"
      + (map(run_tiers as $t
             | "<tr><td>\(.ts | fmt | @html)</td><td>\(.model // "—" | @html)</td>"
               + "<td>\(.effort // "—" | @html)</td><td>\(harness_of | @html)</td>"
               + "<td>\(isolation_of | @html)</td>" + vcell($t.simple) + vcell($t.complex) + "</tr>")
         | join("\n"))
      + "\n</table>\n</div>" end')"

# per-language view (docs/benchmark.md → **Languages**): the latest run of each
# model, first-review recall pooled per language over every fixture; a
# language under min_defects pooled defects reads "too few data", never a value
LANGUAGE_TABLE="$(printf '%s' "$ALL" | jq -r --argjson prices "$PRICES" --argjson bar "$BAR" \
  --argjson langs "$LANGS" --argjson tips "$TIPS" "$JQ_COMMON$JQ_TH"'
  [.[] | select(run_languages != {})] | group_by(.model // "") | map(last) as $runs
  | ([$runs[] | run_languages | keys[]] | unique) as $ls
  | if ($runs | length) == 0 then "" else
    "<h2>Recall by language</h2>\n<p class=\"meta\">Measured. The latest run of each model; first reviews pooled per language "
    + "(the language comes from the file extension). Fewer than \($langs.min_defects) pooled defects of a language read "
    + "<i>too few data</i>. A comparison between models uses the paired test of the Comparison section, not this table.</p>\n"
    + "<div class=scroll>\n<table>\n<tr>" + (["run", "model"] | map(th(.)) | add)
    + ($ls | map("<th title=\"Measured: first-review recall on the defects in \(. | @html) files, pooled over the fixtures, with found/known.\">\(. | @html)</th>") | add) + "</tr>\n"
    + ($runs | map(run_languages as $l
        | "<tr><td>\(.ts | fmt | @html)</td>" + model_cell
          + ($ls | map($l[.] as $c
              | if $c == null then "<td class=\"n dash\">—</td>"
                elif $c.gt < $langs.min_defects then "<td class=\"n dash\">too few data (\($c.tp)/\($c.gt))</td>"
                else "<td class=n>\(ratio($c.tp; $c.gt) | fmt) <span class=sub>(\($c.tp)/\($c.gt))</span></td>" end) | add)
          + "</tr>") | join("\n"))
    + "\n</table>\n</div>" end')"

# Recommended layer (docs/benchmark.md → **Decision rule**): per run id of the
# latest runs, the paired comparisons the session recorded (Measured) and the
# agent's recommendation under the operator's rule — a separate block, never a
# number cell
RECOMMENDATION="$(printf '%s' "$ALL" | jq -r --argjson prices "$PRICES" --argjson bar "$BAR" \
  --arg rule "$RULE" --argjson tips "$TIPS" "$JQ_COMMON$JQ_TH"'
  def vword: {a_better: "first model better", b_better: "second model better", in_noise: "in noise"}[.] // (. // "—");
  [.[] | select(.recommendation != null or .comparison != null)] | group_by(.run_id // .ts) | map(last)
  | sort_by(.ts // "") | reverse | .[0:5]
  | if length == 0 then "" else
    "<h2>Comparison and recommendation</h2>\n<p class=\"meta\">Decision rule (work/CONFIG.md): <b>\($rule | @html)</b>. "
    + "The comparison rows are measured: a paired test per defect on one snapshot. The recommendation is the agent&#39;s "
    + "opinion under that rule; it cites the numbers it uses.</p>\n"
    + (map(. as $r
        | "<h3>Run \(.run_id // .ts | @html)" + (if .models then " — " + (.models | join(", ") | @html) else "" end) + "</h3>\n"
          + (if (.comparison // {}) == {} then "" else
              "<div class=scroll>\n<table>\n<tr>" + (["pair", "defects", "only first", "only second", "Δ recall", "95 % interval", "p", "verdict"] | map(th(.)) | add) + "</tr>\n"
              + ([.comparison | to_entries[] | .value as $c | (.value.overall // .value) as $o
                  | "<tr><td>\(.key | sub("\\|"; " vs ") | @html)</td>" + ($o.n_defects | ncell) + ($o.only_a | ncell) + ($o.only_b | ncell)
                    + ($o.delta_recall | ncell) + "<td class=n>\($o.ci95 // [] | map(tostring) | join(" … ") | if . == "" then "—" else . end)</td>"
                    + ($o.mcnemar_p | ncell) + "<td>\($o.verdict | vword | @html)</td></tr>"] | join("\n"))
              + "\n</table>\n</div>\n" end)
          + (if .recommendation == null then "<div class=rec><b>Recommended</b> — none recorded for this run.</div>"
             else "<div class=rec><b>Recommended</b> <span class=sub>(confidence: \(.recommendation.confidence // "—" | @html); rule: \(.recommendation.rule // $rule | @html))</span>"
               + "<p>\(.recommendation.text // "" | @html)</p>"
               + (if (.recommendation.cites // []) == [] then "" else "<ul>" + (.recommendation.cites | map("<li>\(. | @html)</li>") | add) + "</ul>" end)
               + "</div>" end))
      | join("\n")) end')"

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
  layers(8; 12; 4) + "<tr>"
  + ([ "run", "trigger", "model", "effort", "version", "harness", "isolation", "fixtures", "index",
    "avg f1", "easy rec", "hard rec", "avg sev", "avg fixed", "avg new", "circles", "FPs",
    "sec", "out-tok", "est $" ] | map(th(.)) | add)
  + ([ "judge", "find-acc", "real FPs", "prec*" ] | map(tha(.)) | add) + "</tr>"')"

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
  --seq:#2a78d6;--good:#006300;--bad:#d03b3b;--assess:#b8860b;--rec:#7a4fc4;
}
@media (prefers-color-scheme:dark){:root{
  --surface:#1a1a19;--plane:#0d0d0d;--head:#232322;
  --ink:#fff;--ink-2:#c3c2b7;--ink-muted:#898781;
  --rule:#2c2c2a;--rule-strong:#383835;
  --seq:#3987e5;--good:#0ca30c;--bad:#e66767;--assess:#d8a531;--rec:#a07ce0;
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
${REPORT_TIP_CSS}
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
/* sufficiency verdicts: the word carries the meaning, color only repeats it */
td.v .sub{font-size:.75rem;color:var(--ink-2);font-variant-numeric:tabular-nums}
td.v.ok b{color:var(--good)}td.v.no b{color:var(--bad)}td.v.mid b{color:var(--ink-2)}
.tier{font-size:.75rem;font-weight:400;color:var(--ink-muted)}
.tbar{display:flex;gap:.5rem;align-items:center;font-size:.8rem;margin:.6rem 0 .35rem}
.tbar input,.tbar select,.tbar button{font:inherit;padding:.2rem .45rem;
  color:var(--ink);background:var(--surface);
  border:1px solid var(--rule-strong);border-radius:4px}
.tbar button{cursor:pointer;min-width:1.9rem}
.tbar button:hover:not(:disabled){border-color:var(--seq);color:var(--seq)}
.tbar button:disabled{opacity:.35;cursor:default}
.tbar .info{color:var(--ink-muted);margin-left:auto;font-variant-numeric:tabular-nums}
/* layers: Measured plain, Assessed tinted — one table, visibly apart */
tr.lay th{font-size:.72rem;text-transform:uppercase;letter-spacing:.04em;cursor:default}
tr.lay th.lm{border-top:3px solid var(--seq)}
tr.lay th.la,th.as,td.as{background:color-mix(in srgb,var(--assess) 12%,var(--surface))}
tr.lay th.la{border-top:3px solid var(--assess)}
.auth{font-size:.68rem;padding:0 .3rem;border:1px solid var(--assess);border-radius:3px;color:var(--ink-2)}
.sub{font-size:.75rem;color:var(--ink-2)}
.rec{margin:.6rem 0 1.2rem;padding:.6rem .8rem;border-left:4px solid var(--rec);
  background:color-mix(in srgb,var(--rec) 10%,var(--surface));font-size:.85rem}
.rec p{margin:.3rem 0}
ul{margin:.2rem 0 .6rem;padding-left:1.1rem;font-size:.82rem;color:var(--ink-2)}
li{margin:.1rem 0}
</style>
<h1>Review benchmark — accumulated results</h1>
<p class="meta">Latest run: ${GENERATED} · ${RUNS} run(s) on record.
<b>Hold the pointer on a column name</b> — or move the keyboard focus to it — to
read what that column measures, which direction is better, and what a bad value
costs. A "—" is data that was not measured, never a zero. The bar under each
index is that same 0–1 value; unbounded columns get no bar. Deltas (▲▼) compare
against the previous run of the <b>same harness, model, effort and isolation</b> — green means moved
the good way for that column, so ▼ on sec/tokens/cost is green. Comparison
across models or efforts is the table itself. The index is deterministic — computed from scorer output only,
judge scores never enter it. Three layers stay apart: <b>Measured</b> (plain
columns), <b>Assessed</b> (tinted columns, the judge panel) and <b>Recommended</b>
(the boxed text of the agent). Click a header to sort, type to filter, page long
histories. Full semantics: docs/benchmark.md.</p>
${RECOMMENDATION}
<h2>Core set — regression</h2>
<p class="meta">The frozen core. Deltas compare runs of the same configuration on it.</p>
<div class=scroll>
<table>
${HEAD_ALL}
${ROWS_CORE}
</table>
</div>
<h2>Adaptive set — current repository</h2>
<p class="meta">The part the agent keeps current with the repository. It changes between runs, so it carries no deltas and no trend.</p>
<div class=scroll>
<table>
${HEAD_ALL}
${ROWS_ADAPTIVE}
</table>
</div>
${LANGUAGE_TABLE}
${SUFFICIENCY}
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

${REPORT_TIP_JS}
</script>
EOF
