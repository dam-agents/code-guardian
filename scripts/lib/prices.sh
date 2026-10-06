# prices.sh — the operator-maintained model price table, parsed once for every
# consumer (docs/benchmark.md → Model prices). Sourced by benchmark-report.sh
# and audit-trend.sh; the table has one home in work/CONFIG.md and one reader
# here, so the two reports read the same prices and price a token alike.
#
#   . scripts/lib/prices.sh
#   PRICES="$(prices_json "/path/to/CONFIG.md")"   # [] when absent
#   jq --argjson prices "$PRICES" "$PRICES_JQ"'…'   # price_row, token_usd
#
# Markdown rows `| model substring | input | output | cache_read | cache_write |`
# under `## Benchmark model prices`, USD per MTok. Header and separator rows
# drop out because their price cells do not parse as numbers; a missing file or
# section yields [].
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"   # cfg_table
prices_json() { # <config.md path>
  local out
  out="$(CONFIG="${1:-}" cfg_table 'Benchmark model prices' \
    | jq -Rn '[inputs | split("|") | map(gsub("^\\s+|\\s+$"; ""))
               | select(length >= 6)
               | {m: .[1], i: (.[2] | tonumber?), o: (.[3] | tonumber?),
                  cr: (.[4] | tonumber?), cw: (.[5] | tonumber?)}
               | select(.m != "" and .i != null and .o != null
                        and .cr != null and .cw != null)]' 2>/dev/null)"
  printf '%s' "${out:-[]}"
}

# jq: the price row of a model id (the first row whose model substring it
# contains, null without one) and the USD cost of a token object
# {input, output, cache_read, cache_creation} at a row. Needs $prices.
PRICES_JQ='
  def price_row($m): [$prices[] | select(. as $p | $m | contains($p.m))] | first;
  def token_usd($p): ((.input // 0) * $p.i + (.output // 0) * $p.o
                      + (.cache_read // 0) * $p.cr + (.cache_creation // 0) * $p.cw) / 1000000;
'
