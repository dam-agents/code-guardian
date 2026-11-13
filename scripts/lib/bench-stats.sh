#!/usr/bin/env bash
# bench-stats.sh — deterministic statistics over benchmark results files
# (docs/benchmark.md). jq + awk only; the same input always prints the same
# output. Source it for the functions, or run it as a CLI:
#
#   bash scripts/lib/bench-stats.sh paired <results-a.json> <results-b.json>
#   bash scripts/lib/bench-stats.sh ci <results.json>
#
# The unit is one first-review ground-truth defect (v1): key <slug>/<id>, hit
# = in first.tp[].id, miss = in first.fn[]. Its part is fixtures.<slug>.part
# (absent = core); its language comes from the file of tp[] / fn_detail[]
# through lib/bench-lang.sh. A defect whose language no file names (an old
# results file without fn_detail) makes the `languages` scope null.
#
# bench_paired — defects present in BOTH files, paired per defect:
#   {n_defects, only_a, only_b, both, neither, mcnemar_p, delta_recall,
#    ci95: [lo, hi], verdict, parts: {<part>: {same fields}},
#    languages: {<lang>: {same fields}} | null}
#   mcnemar_p      exact two-sided binomial p when only_a + only_b < 25, else
#                  chi-square with continuity correction (1 df); 1 with no
#                  discordant defect, null with no defect
#   delta_recall   recall_a - recall_b over the paired defects
#   ci95           paired bootstrap of delta_recall over defects
#   verdict        a_better | b_better when mcnemar_p < 0.05 and ci95 excludes
#                  0, else in_noise
#
# bench_ci — one file:
#   {n_defects, recall, recall_ci95: [lo, hi], n_predictions, precision,
#    precision_ci95: [lo, hi], parts: {...}, languages: {...} | null}
#   recall resamples the defects; precision resamples the blocking
#   predictions (first.tp[] count 1, first.fp[] count 0; an fp's language is
#   its own file's).
#
# Bootstrap: 1000 resamples, Park-Miller generator with the fixed seed 20260304,
# percentile interval (26th and 975th of the sorted resamples). Values are
# rounded to 3 decimals, p to 4 significant digits.

BENCH_STATS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$BENCH_STATS_DIR/bench-lang.sh"

# One TSV row per unit. paired: <part> <lang|?> <hitA> <hitB>; ci: <kind d|p>
# <part> <lang|?> <value>.
_bench_rows_jq="$BENCH_LANG_JQ"'
  def part($r; $s): ($r.fixtures[$s].part // "core");
  def units($r):
    [ ($r.fixtures // {}) | if type == "object" then to_entries[] else empty end
      | .key as $s | .value.first | select(type == "object")
      | ( (.tp // [])[] | {key: "\($s)/\(.id)", s: $s, hit: 1, file: .file} ),
        ( (.fn_detail // []) as $fd
          | (.fn // [])[] | . as $id
          | {key: "\($s)/\($id)", s: $s, hit: 0,
             file: ([ $fd[] | select(.id == $id) | .file ] | first)} ) ];
  def lang($f; $map): if $f == null then "?" else ($f | bench_lang($map)) end;
'

_bench_awk='
function lcg() { seed = (seed * 16807) % 2147483647; return seed }
function r3(x) { return sprintf("%.3f", x) + 0 }
function binom_p(b, c,   n, k, m, s, lc) {
  n = b + c; m = (b < c) ? b : c; s = 0
  for (k = 0; k <= m; k++) {
    lc = 0
    for (j = 1; j <= k; j++) lc += log(n - k + j) - log(j)
    s += exp(lc - n * log(2))
  }
  s = 2 * s; return (s > 1) ? 1 : s
}
function erfc(z,   t, y) {
  t = 1 / (1 + 0.3275911 * z)
  y = t * (0.254829592 + t * (-0.284496736 + t * (1.421413741 + t * (-1.453152027 + t * 1.061405429))))
  return y * exp(-z * z)
}
function mcnemar(b, c,   x) {
  if (b + c == 0) return 1
  if (b + c < 25) return binom_p(b, c)
  x = (b > c ? b - c : c - b) - 1; x = x * x / (b + c)
  return erfc(sqrt(x / 2))
}
# percentile interval of R integer sums in hist[] (offset off), as a share of n
function pct(n, off,   v, cum, lo, hi, want_lo, want_hi) {
  want_lo = 26; want_hi = 975; cum = 0; lo = ""; hi = ""
  for (v = -off; v <= n; v++) {
    cum += hist[v + off]
    if (lo == "" && cum >= want_lo) lo = v
    if (hi == "" && cum >= want_hi) hi = v
  }
  return "[" r3(lo / n) ", " r3(hi / n) "]"
}
function clear(n,   v) { for (v = 0; v <= 2 * n; v++) hist[v] = 0 }
function paired(g,   n, i, b, c, both, nei, r, s, k, p, d, lo, hi, ci, verdict, q) {
  n = cnt[g]; b = c = both = nei = 0
  for (i = 1; i <= n; i++) {
    if (A[g, i] && B[g, i]) both++; else if (A[g, i]) b++; else if (B[g, i]) c++; else nei++
  }
  if (n == 0) return "{\"n_defects\": 0, \"only_a\": 0, \"only_b\": 0, \"both\": 0, \"neither\": 0, \"mcnemar_p\": null, \"delta_recall\": null, \"ci95\": null, \"verdict\": \"in_noise\"}"
  p = mcnemar(b, c); d = (b - c) / n
  seed = 20260304; clear(n)
  for (r = 1; r <= 1000; r++) {
    s = 0
    for (i = 1; i <= n; i++) { k = int(lcg() / 2147483647 * n) + 1; s += A[g, k] - B[g, k] }
    hist[s + n]++
  }
  ci = pct(n, n)
  split(substr(ci, 2, length(ci) - 2), q, ", "); lo = q[1] + 0; hi = q[2] + 0
  verdict = "in_noise"
  if (p < 0.05 && (lo > 0 || hi < 0)) verdict = (d > 0) ? "a_better" : "b_better"
  return "{\"n_defects\": " n ", \"only_a\": " b ", \"only_b\": " c ", \"both\": " both \
         ", \"neither\": " nei ", \"mcnemar_p\": " (sprintf("%.4g", p) + 0) \
         ", \"delta_recall\": " r3(d) ", \"ci95\": " ci ", \"verdict\": \"" verdict "\"}"
}
function boot(g,   n, i, r, s, k, sum) {
  n = cnt[g]; if (n == 0) return "null"
  sum = 0; for (i = 1; i <= n; i++) sum += A[g, i]
  seed = 20260304; clear(n)
  for (r = 1; r <= 1000; r++) {
    s = 0
    for (i = 1; i <= n; i++) { k = int(lcg() / 2147483647 * n) + 1; s += A[g, k] }
    hist[s]++
  }
  return r3(sum / n) "\t" pct(n, 0)
}
function add(g, a, b) { if (!(g in cnt)) { cnt[g] = 0; order[++ng] = g }; cnt[g]++; A[g, cnt[g]] = a; B[g, cnt[g]] = b }
BEGIN { FS = "\t"; ng = 0 }
mode == "paired" { add("overall\t", $3, $4); add("part\t" $1, $3, $4); add("lang\t" $2, $3, $4) }
mode == "ci"     { add($1 "overall\t", $4, 0); add($1 "part\t" $2, $4, 0); add($1 "lang\t" $3, $4, 0) }
END {
  for (x = 1; x <= ng; x++) {
    g = order[x]
    if (mode == "paired") print g "\t" paired(g)
    else { split(boot(g), o, "\t"); print g "\t" cnt[g] "\t" o[1] "\t" o[2] }
  }
}'

bench_paired() { # <results-a.json> <results-b.json>
  local map rows
  map="$(bench_lang_jq_map)"
  rows="$(jq -rn --slurpfile a "$1" --slurpfile b "$2" --argjson map "$map" "$_bench_rows_jq"'
    ($a[0]) as $ra | ($b[0]) as $rb
    | (units($ra) | map({(.key): .}) | add // {}) as $ua
    | (units($rb) | map({(.key): .}) | add // {}) as $ub
    | [ $ua | keys[] | select($ub[.] != null) ] | sort[]
    | . as $k | $ua[$k] as $x | $ub[$k] as $y
    | [ part($ra; $x.s), lang($x.file // $y.file; $map), $x.hit, $y.hit ] | @tsv')" || return 1
  printf '%s\n' "$rows" | sed '/^$/d' | awk -v mode=paired "$_bench_awk" \
    | jq -Rn '[inputs | split("\t") | {scope: .[0], name: .[1], v: (.[2] | fromjson)}] as $r
      | ($r | map(select(.scope == "overall")) | .[0].v
         // {n_defects: 0, only_a: 0, only_b: 0, both: 0, neither: 0, mcnemar_p: null,
             delta_recall: null, ci95: null, verdict: "in_noise"})
      + {parts: ($r | map(select(.scope == "part") | {(.name): .v}) | add // {}),
         languages: (if any($r[]; .scope == "lang" and .name == "?") then null
                     else ($r | map(select(.scope == "lang") | {(.name): .v}) | add // {}) end)}'
}

bench_ci() { # <results.json>
  local map rows
  map="$(bench_lang_jq_map)"
  rows="$(jq -rn --slurpfile a "$1" --argjson map "$map" "$_bench_rows_jq"'
    $a[0] as $r
    | (units($r) | sort_by(.key)[] | ["d", part($r; .s), lang(.file; $map), .hit] | @tsv),
      ( ($r.fixtures // {}) | if type == "object" then to_entries[] else empty end
        | .key as $s | .value.first | select(type == "object")
        | ((.tp // [])[] | ["p", part($r; $s), lang(.file; $map), 1] | @tsv),
          ((.fp // [])[] | ["p", part($r; $s), lang(.file; $map), 0] | @tsv) )')" || return 1
  printf '%s\n' "$rows" | sed '/^$/d' | awk -v mode=ci "$_bench_awk" \
    | jq -Rn 'def one($r; $scope; $name):
        ([$r[] | select(.kind == "d" and .scope == $scope and .name == $name)] | .[0]) as $d
        | ([$r[] | select(.kind == "p" and .scope == $scope and .name == $name)] | .[0]) as $p
        | {n_defects: ($d.n // 0), recall: ($d.v // null), recall_ci95: ($d.ci // null),
           n_predictions: ($p.n // 0), precision: ($p.v // null), precision_ci95: ($p.ci // null)};
      def names($r; $scope): [$r[] | select(.scope == $scope) | .name] | unique;
      [inputs | split("\t")
       | {kind: (.[0] | .[0:1]), scope: (.[0] | .[1:]), name: .[1],
          n: (.[2] | tonumber), v: (.[3] | tonumber), ci: (.[4] | fromjson)}] as $r
      | one($r; "overall"; "")
      + {parts: (names($r; "part") | map(. as $n | {($n): one($r; "part"; $n)}) | add // {}),
         languages: (if any($r[]; .kind == "d" and .scope == "lang" and .name == "?") then null
                     else (names($r; "lang") | map(. as $n | {($n): one($r; "lang"; $n)}) | add // {}) end)}'
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  export LC_ALL=C
  case "${1:-}" in
    (paired) [ "$#" -eq 3 ] && [ -f "$2" ] && [ -f "$3" ] \
               || { printf 'usage: bench-stats.sh paired <results-a.json> <results-b.json>\n' >&2; exit 2; }
             bench_paired "$2" "$3";;
    (ci)     [ "$#" -eq 2 ] && [ -f "$2" ] \
               || { printf 'usage: bench-stats.sh ci <results.json>\n' >&2; exit 2; }
             bench_ci "$2";;
    (*) printf 'usage: bench-stats.sh paired <a.json> <b.json> | ci <results.json>\n' >&2; exit 2;;
  esac
fi
