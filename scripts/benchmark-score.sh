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
#   new_fp                 unmatched blocking "new" predictions
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

# ------------------------------------------------ findings-json + format ----
FJ="$(sed -n 's/^<!-- findings-json: \(.*\) -->[[:space:]]*$/\1/p' "$RAW" | head -1)"
FJ_OK=true
printf '%s' "$FJ" | jq -e 'type == "array"' >/dev/null 2>&1 || { FJ_OK=false; FJ='[]'; }

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

FMT="$(jq -n --argjson fj "$FJ" --arg verdict "$VERDICT" '
  ($fj | map(select(.status != "fixed"))) as $open
  | (if ($open | any(.severity == "critical")) then "REQUEST_CHANGES"
     elif ($open | any(.severity == "warning")) then "COMMENT"
     else "APPROVE" end) as $expected
  | {fix_lines: ($fj | map(select(.status == "new"
                                  and (.severity == "critical" or .severity == "warning")))
                     | all(.fix != null and .fix != "")),
     verdict: $verdict,
     verdict_consistent: ($verdict == $expected)}')"

# ------------------------------------------------------ length + STE proxy ----
WORDS_TOTAL="$(count_words < "$RAW")"
LENGTH="$(jq -n --argjson fj "$FJ" --argjson w "$WORDS_TOTAL" '
  {words_total: $w, findings: ($fj | length),
   words_per_finding: (if ($fj | length) == 0 then null
                       else (($w / ($fj | length)) | round) end)}')"

TMP_SENT="$(mktemp "${TMPDIR:-/tmp}/bench-sent.XXXXXX")"
trap 'rm -f "$TMP_SENT"' EXIT
sed -e '/^```/,/^```/d' -e '/^[[:space:]]*<!--/d' "$RAW" \
  | tr '\n' ' ' \
  | sed -e 's/[.!?][[:space:]][[:space:]]*/\n/g' -e 's/[.!?][[:space:]]*$//' \
  | grep -v '^[[:space:]]*$' > "$TMP_SENT" || true
STE="$(while IFS= read -r s; do printf '%s\n' "$s" | count_words; done < "$TMP_SENT" \
  | jq -s '{sentences: length,
            avg_sentence_words: (if length == 0 then null
                                 else ((add / length * 10) | round) / 10 end),
            sentences_over_20: ([.[] | select(. > 20)] | length)}')"

# ------------------------------------------------------------- matching ----
if [ "$MODE" = "first" ]; then
  SCORE="$(jq -n --slurpfile m_ "$MANIFEST" --argjson fj "$FJ" '
    def r3: if . == null then null else (. * 1000 | round) / 1000 end;
    def dist($a; $b): ($a - $b) | if . < 0 then -. else . end;
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
  SCORE="$(jq -n --slurpfile m_ "$MANIFEST" --argjson fj "$FJ" '
    def r3: if . == null then null else (. * 1000 | round) / 1000 end;
    def dist($a; $b): ($a - $b) | if . < 0 then -. else . end;
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
    | bmatch($fixedGT; $pF; true)  as $mf
    | bmatch($stillGT; $pS; false) as $ms
    | bmatch($newGT;   $pN; false) as $mn
    | ($pN | to_entries
           | map(select(.key as $k | ($mn.used | index($k)) == null) | .value)) as $restN
    | bmatch($lateGT; $restN; false) as $ml
    | ($restN | to_entries
              | map(select(.key as $k | ($ml.used | index($k)) == null) | .value)
              | map(select(.severity == "critical" or .severity == "warning"))
              | length) as $newfp
    | {fixed_gt: ($fixedGT | length), still_gt: ($stillGT | length),
       new_gt: ($newGT | length),
       fixed_recall: (frac($mf.hit; $fixedGT | length) | r3),
       still_recall: (frac($ms.hit; $stillGT | length) | r3),
       new_recall:   (frac($mn.hit; $newGT   | length) | r3),
       false_fixed: (bmatch($stillGT; $pF; true) | .hit),
       late_finds: $ml.hit,
       new_fp: $newfp}')"
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
