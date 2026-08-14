#!/usr/bin/env bash
# benchmark-score.sh — deterministic scorer for one benchmark raw review
# (docs/benchmark.md). Pure local computation: reads the two input files,
# prints one JSON object on stdout, writes nothing else; safe to re-run.
#
#   benchmark-score.sh first    <raw-review.md> <manifest.json>
#   benchmark-score.sh rereview <raw-review.md> <manifest.json>
#
# Matching: a predicted finding (from the review's findings-json line) matches
# a manifest defect when the files are equal and the line sits within ±3 of
# the defect's anchor (line_v1 and/or line_v2 — the fixture keeps same-file
# defects ≥10 lines apart, so the windows never overlap). Each defect and each
# prediction is used at most once (greedy, manifest order). A prediction with
# line: null matches by file only in the fixed bucket (a fixed one-liner may
# drop its line); everywhere else it stays unmatched.
#
# Output fields — first mode:
#   gt                     defects present in v1 (ground-truth set size)
#   tp[]                   matched: {id, file, line, gt_severity, pred_severity}
#   fn[]                   missed defect ids
#   fp[]                   unmatched blocking predictions (critical|warning)
#   suggestions_unmatched  unmatched suggestion predictions (recorded, not FPs)
#   precision              tp / (tp + fp)   (null when there are no blocking predictions)
#   recall                 tp / gt          (+ recall_critical / recall_warning per severity)
#   f1                     harmonic mean of precision and recall (null-safe)
#   severity_accuracy      share of tp with pred_severity == gt_severity (null when tp = 0)
#
# rereview mode (prior-review scope from manifest in_prior_review):
#   fixed_gt / still_gt / new_gt   ground-truth bucket sizes
#   fixed_recall / still_recall / new_recall   matched share per bucket
#   false_fixed            predictions reported fixed that the manifest keeps
#                          (the dangerous direction — weight it in reports)
#   late_finds             v1 defects outside the prior review reported as new
#                          now (read together with the first run's recall —
#                          a consistency signal, not an error by itself)
#   churn                  blocking "new" predictions sitting on a fix site
#                          (manifest fix_line_v2 of a fixed defect, ±3) — the
#                          review flags the very fix the prior review asked
#                          for: the going-in-circles signal. Disjoint from
#                          new_fp.
#   new_fp                 blocking "new" predictions matching nothing at all
#
# both modes:
#   format  {findings_json, marker, sections, fix_lines, verdict,
#            verdict_consistent[, delta_section]}
#           fix_lines: every blocking status-"new" entry carries a non-empty fix.
#           verdict_consistent: the verdict matches the open blocking set
#           (critical → REQUEST_CHANGES, warning → COMMENT, none → APPROVE;
#           status-"fixed" entries excluded).
#   length  {words_total, findings, words_per_finding}
#   ste     {sentences, avg_sentence_words, sentences_over_20} — computed on
#           prose only (code fences and HTML-comment lines removed); a
#           sentence is the text up to . ! or ?

set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# speed only — resolve a mise-shimmed jq to the real binary (lib/toolpath.sh)
[ -f "$SCRIPT_DIR/lib/toolpath.sh" ] && . "$SCRIPT_DIR/lib/toolpath.sh" 2>/dev/null

MODE="${1:-}"; RAW="${2:-}"; MANIFEST="${3:-}"
usage() { printf 'usage: benchmark-score.sh first|rereview <raw-review.md> <manifest.json>\n' >&2; exit 2; }
case "$MODE" in (first|rereview) ;; (*) usage;; esac
[ -f "$RAW" ] || { printf 'raw review not readable: %s\n' "$RAW" >&2; exit 2; }
jq -e . "$MANIFEST" >/dev/null 2>&1 || { printf 'manifest not valid JSON: %s\n' "$MANIFEST" >&2; exit 2; }

# word count without wc (not in the pod's required command set)
count_words() { grep -o '[^[:space:]][^[:space:]]*' | grep -c ''; }

# shared jq defs for both scoring modes — one home for rounding and the
# ±3-line matching window, so first-review and re-review scores always use
# the same rules
JQ_DEFS='
  def r3: if . == null then null else (. * 1000 | round) / 1000 end;
  def dist($a; $b): ($a - $b) | if . < 0 then -. else . end;
'

# ------------------------------------------------ findings-json + format ----
# Normalize before scoring: the reviewed model wrote this line, so malformed
# elements are graded (dropped/nulled), never a crash — keep objects only and
# coerce line to a number or null.
FJ="$(sed -n 's/^<!-- findings-json: \(.*\) -->[[:space:]]*$/\1/p' "$RAW" | head -1)"
FJ_OK=true
FJ="$(printf '%s' "$FJ" | jq -c 'select(type == "array")
  | map(select(type == "object")
        | .line = ((.line // null) | if type == "number" then . else (tonumber? // null) end))' \
  2>/dev/null)" || FJ=''
[ -n "$FJ" ] || { FJ_OK=false; FJ='[]'; }

MARKER_OK=false
grep -qE '^<!-- .+ headRefOid=[0-9a-f]{40} -->' "$RAW" && MARKER_OK=true

SECTIONS_OK=true
for s in '### Summary' '### Findings' '### Verdict'; do
  grep -q "^$s" "$RAW" || SECTIONS_OK=false
done
DELTA_OK=false
grep -q '^### Changes since last review' "$RAW" && DELTA_OK=true

VERDICT="$(sed -n '/^### Verdict/,$p' "$RAW" | grep -oE 'REQUEST_CHANGES|APPROVE|COMMENT' | head -1)"
VERDICT="${VERDICT:-missing}"

# fix_lines: the findings-json contract nulls fix only on suggestion and
# fixed entries — every OPEN blocking entry (new and still) must carry one
FMT="$(jq -n --argjson fj "$FJ" --arg verdict "$VERDICT" '
  ($fj | map(select(.status != "fixed"))) as $open
  | (if ($open | any(.severity == "critical")) then "REQUEST_CHANGES"
     elif ($open | any(.severity == "warning")) then "COMMENT"
     else "APPROVE" end) as $expected
  | {fix_lines: ($open | map(select(.severity == "critical" or .severity == "warning"))
                       | all(.fix != null and .fix != "")),
     verdict: $verdict,
     verdict_consistent: ($verdict == $expected)}')"

# ------------------------------------------------------ length + STE proxy ----
WORDS_TOTAL="$(count_words < "$RAW")"
LENGTH="$(jq -n --argjson fj "$FJ" --argjson w "$WORDS_TOTAL" '
  {words_total: $w, findings: ($fj | length),
   words_per_finding: (if ($fj | length) == 0 then null
                       else (($w / ($fj | length)) | round) end)}')"

# one jq pass computes every sentence length (no temp file, no per-sentence
# subprocesses); fences match indented openers too — an unbalanced fence
# still degrades this one metric only, never the scoring
STE="$(sed -e '/^[[:space:]]*```/,/^[[:space:]]*```/d' -e '/^[[:space:]]*<!--/d' "$RAW" \
  | tr '\n' ' ' \
  | sed -e 's/[.!?][[:space:]][[:space:]]*/\n/g' -e 's/[.!?][[:space:]]*$//' \
  | jq -Rs '[split("\n")[] | select(test("[^[:space:]]")) | [scan("[^[:space:]]+")] | length]
            | {sentences: length,
               avg_sentence_words: (if length == 0 then null
                                    else ((add / length * 10) | round) / 10 end),
               sentences_over_20: ([.[] | select(. > 20)] | length)}')"

# ------------------------------------------------------------- matching ----
if [ "$MODE" = "first" ]; then
  SCORE="$(jq -n --slurpfile m_ "$MANIFEST" --argjson fj "$FJ" "$JQ_DEFS"'
    def sevrec($gtl; $tpl; $sev):
      ($gtl | map(select(.severity == $sev)) | length) as $n
      | if $n == 0 then null
        else (($tpl | map(select(.gt_severity == $sev)) | length) / $n) end;
    $m_[0] as $m
    | ($m.defects | map(select(.line_v1 != null))) as $gt
    | reduce range(0; $gt | length) as $i (
        {used: [], tp: [], fn: []};
        . as $st | $gt[$i] as $g
        | ([ range(0; $fj | length)
             | select(($fj[.].file == $g.file)
                      and ($fj[.].line != null)
                      and (dist($fj[.].line; $g.line_v1) <= 3)
                      and (. as $ix | ($st.used | index($ix)) == null)) ]
           | first) as $mi
        | if $mi == null then $st | .fn += [$g.id]
          else $st | .used += [$mi]
                   | .tp += [{id: $g.id, file: $g.file, line: $g.line_v1,
                              gt_severity: $g.severity,
                              pred_severity: $fj[$mi].severity}]
          end)
    | . as $r
    | ($fj | to_entries
           | map(select(.key as $k | ($r.used | index($k)) == null) | .value)) as $un
    | ($un | map(select(.severity == "critical" or .severity == "warning"))
           | map({file, line, severity, summary})) as $fp
    | ($r.tp | length) as $tpn | ($gt | length) as $gtn | ($fp | length) as $fpn
    | (if ($tpn + $fpn) == 0 then null else ($tpn / ($tpn + $fpn)) end) as $p
    | (if $gtn == 0 then null else ($tpn / $gtn) end) as $rec
    | (if $p == null or $rec == null then null
       elif ($p + $rec) == 0 then 0
       else (2 * $p * $rec / ($p + $rec)) end) as $f1
    | (if $tpn == 0 then null
       else (($r.tp | map(select(.gt_severity == .pred_severity)) | length) / $tpn) end) as $seva
    | {gt: $gtn, tp: $r.tp, fn: $r.fn, fp: $fp,
       suggestions_unmatched: ($un | map(select(.severity == "suggestion")) | length),
       precision: ($p | r3), recall: ($rec | r3), f1: ($f1 | r3),
       recall_critical: (sevrec($gt; $r.tp; "critical") | r3),
       recall_warning: (sevrec($gt; $r.tp; "warning") | r3),
       severity_accuracy: ($seva | r3)}')"
else
  SCORE="$(jq -n --slurpfile m_ "$MANIFEST" --argjson fj "$FJ" "$JQ_DEFS"'
    def anchored($pl; $g):
      ($g.line_v1 != null and $pl != null and dist($pl; $g.line_v1) <= 3)
      or ($g.line_v2 != null and $pl != null and dist($pl; $g.line_v2) <= 3);
    # greedy bucket match; $fileonly admits line:null predictions by file alone
    def bmatch($gtl; $preds; $fileonly):
      reduce range(0; $gtl | length) as $i (
        {used: [], hit: 0};
        . as $st | $gtl[$i] as $g
        | ([ range(0; $preds | length)
             | select(($preds[.].file == $g.file)
                      and (. as $ix | ($st.used | index($ix)) == null)
                      and (anchored($preds[.].line; $g)
                           or ($fileonly and $preds[.].line == null))) ]
           | first) as $mi
        | if $mi == null then $st else $st | .used += [$mi] | .hit += 1 end);
    def frac($hit; $n): if $n == 0 then null else ($hit / $n) end;
    $m_[0] as $m | $m.defects as $d
    | ($d | map(select(.fixed_in_v2 == true  and .in_prior_review == true)))  as $fixedGT
    | ($d | map(select(.fixed_in_v2 == false and .in_prior_review == true
                       and .line_v1 != null)))                               as $stillGT
    | ($d | map(select(.line_v1 == null)))                                   as $newGT
    | ($d | map(select(.line_v1 != null and .fixed_in_v2 == false
                       and .in_prior_review == false)))                      as $lateGT
    | ($fj | map(select(.status == "fixed"))) as $pF
    | ($fj | map(select(.status == "still"))) as $pS
    | ($fj | map(select(.status == "new")))   as $pN
    | ($d | map(select(.fixed_in_v2 == true and (.fix_line_v2 // null) != null)
                | {file, line_v1: null, line_v2: .fix_line_v2}))              as $fixSites
    | bmatch($fixedGT; $pF; true)  as $mf
    # false_fixed considers only fixed claims NOT consumed by the fixed
    # bucket, and matches them by line — a correct line-null fixed claim is
    # never double-counted against a same-file still-present defect
    | ($pF | to_entries
           | map(select(.key as $k | ($mf.used | index($k)) == null) | .value)) as $restF
    | bmatch($stillGT; $pS; false) as $ms
    | bmatch($newGT;   $pN; false) as $mn
    | ($pN | to_entries
           | map(select(.key as $k | ($mn.used | index($k)) == null) | .value)) as $restN
    | bmatch($lateGT; $restN; false) as $ml
    | ($restN | to_entries
              | map(select(.key as $k | ($ml.used | index($k)) == null) | .value)) as $restN2
    | bmatch($fixSites; ($restN2 | map(select(.severity == "critical" or .severity == "warning"))); false) as $mc
    | ($restN2 | map(select(.severity == "critical" or .severity == "warning")) | length) as $blockrest
    | {fixed_gt: ($fixedGT | length), still_gt: ($stillGT | length),
       new_gt: ($newGT | length),
       fixed_recall: (frac($mf.hit; $fixedGT | length) | r3),
       still_recall: (frac($ms.hit; $stillGT | length) | r3),
       new_recall:   (frac($mn.hit; $newGT   | length) | r3),
       false_fixed: (bmatch($stillGT; $restF; false) | .hit),
       late_finds: $ml.hit,
       churn: $mc.hit,
       new_fp: ($blockrest - $mc.hit)}')"
fi

# ------------------------------------------------------------- assembly ----
jq -n --argjson score "$SCORE" --argjson fmt "$FMT" \
      --argjson len "$LENGTH" --argjson ste "$STE" \
      --argjson fjok "$FJ_OK" --argjson marker "$MARKER_OK" \
      --argjson sections "$SECTIONS_OK" --argjson delta "$DELTA_OK" \
      --arg mode "$MODE" '
  $score
  + {format: ({findings_json: $fjok, marker: $marker, sections: $sections} + $fmt
              + (if $mode == "rereview" then {delta_section: $delta} else {} end)),
     length: $len, ste: $ste}'
