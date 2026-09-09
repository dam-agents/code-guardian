# prices.sh — the operator-maintained model price table, parsed once for every
# consumer (docs/benchmark.md → Model prices). Sourced by benchmark-report.sh
# and audit-trend.sh; the table has one home in work/CONFIG.md and one reader
# here, so the two reports can never price a token differently.
#
#   . scripts/lib/prices.sh
#   PRICES="$(prices_json "/path/to/CONFIG.md")"   # [] when absent
#
# Markdown rows `| model substring | input | output | cache_read | cache_write |`
# under `## Benchmark model prices`, USD per MTok. Header and separator rows
# drop out because their price cells do not parse as numbers; a missing file or
# section yields [].
prices_json() { # <config.md path>
  local out
  out="$(sed -n '/^## Benchmark model prices/,/^## [^B]/p' "${1:-}" 2>/dev/null \
    | grep '^|' \
    | jq -Rn '[inputs | split("|") | map(gsub("^\\s+|\\s+$"; ""))
               | select(length >= 6)
               | {m: .[1], i: (.[2] | tonumber?), o: (.[3] | tonumber?),
                  cr: (.[4] | tonumber?), cw: (.[5] | tonumber?)}
               | select(.m != "" and .i != null and .o != null
                        and .cr != null and .cw != null)]' 2>/dev/null)"
  printf '%s' "${out:-[]}"
}
