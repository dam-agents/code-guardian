# sufficiency.sh — the operator's sufficiency bar per task tier, parsed once
# for every consumer (docs/benchmark.md → Sufficiency by tier). Sourced by
# benchmark-report.sh; the table has one home in work/CONFIG.md and one
# reader here.
#
#   . scripts/lib/sufficiency.sh
#   BAR="$(sufficiency_json "/path/to/CONFIG.md")"
#   jq --argjson bar "$BAR" "$SUFFICIENCY_JQ"'…'   # tier_stats, tier_verdict
#
# Markdown rows `| tier | recall | precision | min_defects |` under
# `## Benchmark sufficiency`. A tier the table does not name, a missing table
# or a missing file keeps the default bar: recall 0.8, precision 0.7,
# min_defects 20. Header and separator rows drop out because their cells do
# not parse as numbers.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"   # cfg_table
sufficiency_json() { # <config.md path>
  local rows
  rows="$(CONFIG="${1:-}" cfg_table 'Benchmark sufficiency' \
    | jq -Rn '[inputs | split("|") | map(gsub("^\\s+|\\s+$"; ""))
               | select(length >= 5)
               | {t: .[1], r: (.[2] | tonumber?), p: (.[3] | tonumber?), n: (.[4] | tonumber?)}
               | select((.t == "simple" or .t == "complex")
                        and .r != null and .p != null and .n != null)]' 2>/dev/null)"
  jq -cn --argjson rows "${rows:-[]}" '
    {recall: 0.8, precision: 0.7, min_defects: 20} as $d
    | reduce ("simple", "complex") as $t ({};
        . + {($t): ([$rows[] | select(.t == $t)] | first
                    | if . == null then $d
                      else {recall: .r, precision: .p, min_defects: .n} end)})'
}

# jq over a list of fixture objects ({first, rereview}) of one run:
# tier_stats($t) pools the fixtures of tier $t — summed counts, so a tier
# reads as one sample, never as an average of small fractions — and
# tier_verdict turns the pooled stats into one of: sufficient, borderline
# (every value within 0.05 under the bar), insufficient, few (fewer pooled
# defects than min_defects), or null (no fixture of the tier). A false-fixed
# re-review is always insufficient: it approves a defect. Needs $bar.
SUFFICIENCY_JQ='
  def ratio($a; $b): if $b == 0 then null else ((($a / $b) * 1000 | round) / 1000) end;
  def tier_stats($t):
    [.[] | select((.first.tier // "simple") == $t)] as $fx
    | if ($fx | length) == 0 then null else
      ([$fx[] | .first.tp | length] | add) as $tp
      | ([$fx[] | .first.gt // 0] | add) as $gt
      | ([$fx[] | .first.fp | length] | add) as $fp
      | ([$fx[] | .first.difficulty.hard.tp // empty] | add) as $htp
      | ([$fx[] | .first.difficulty.hard.gt // empty] | add) as $hgt
      | ([$fx[] | .first.difficulty.easy.tp // empty] | add) as $etp
      | ([$fx[] | .first.difficulty.easy.gt // empty] | add) as $egt
      | {fixtures: ($fx | length), tp: $tp, gt: $gt, fp: $fp,
         recall: ratio($tp; $gt), precision: ratio($tp; $tp + $fp),
         easy: (if $egt == null then null else {tp: $etp, gt: $egt, recall: ratio($etp; $egt)} end),
         hard: (if $hgt == null then null else {tp: $htp, gt: $hgt, recall: ratio($htp; $hgt)} end),
         false_fixed: ([$fx[] | .rereview.false_fixed // 0] | add)}
      end;
  def tier_verdict($t):
    . as $s | $bar[$t] as $b
    | if $s == null then null
      elif $s.false_fixed > 0 then "insufficient"
      elif $s.gt < $b.min_defects then "few"
      elif $s.recall == null or $s.precision == null then "insufficient"
      elif $s.recall >= $b.recall and $s.precision >= $b.precision then "sufficient"
      elif $s.recall >= ($b.recall - 0.05) and $s.precision >= ($b.precision - 0.05) then "borderline"
      else "insufficient" end;
'
