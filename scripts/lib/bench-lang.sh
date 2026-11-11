# bench-lang.sh — the language of a benchmark defect, derived from its file
# extension (docs/benchmark.md). The single home of the mapping: the scorer,
# the statistics and the report read it from here, in bash or in jq.
#
#   bench_lang <path>        → java|typescript|javascript|python|go|ruby|shell|
#                              basic|csharp|kotlin|rust|php|c|cpp|markdown|yaml|other
#   bench_lang_jq_map        → {"<ext>": "<lang>", ...} (lowercase extensions)
#   BENCH_LANG_JQ            jq def: `<path> | bench_lang($map)` with the map above
#
# Sourced; no side effects. The extension is matched case-insensitively; a
# path without a known extension is `other`.

BENCH_LANG_MAP='java:java
ts:typescript tsx:typescript mts:typescript cts:typescript
js:javascript jsx:javascript mjs:javascript cjs:javascript
py:python pyi:python
go:go
rb:ruby rake:ruby
sh:shell bash:shell zsh:shell ksh:shell
bas:basic vb:basic vbs:basic frm:basic
cs:csharp
kt:kotlin kts:kotlin
rs:rust
php:php
c:c h:c
cc:cpp cpp:cpp cxx:cpp hpp:cpp hh:cpp hxx:cpp
md:markdown markdown:markdown
yml:yaml yaml:yaml'

bench_lang() { # <path>
  local b="${1##*/}" e pair
  case "$b" in (*.*) e="${b##*.}";; (*) printf 'other\n'; return;; esac
  e="$(printf '%s' "$e" | tr '[:upper:]' '[:lower:]')"
  for pair in $BENCH_LANG_MAP; do
    [ "${pair%%:*}" = "$e" ] && { printf '%s\n' "${pair#*:}"; return; }
  done
  printf 'other\n'
}

bench_lang_jq_map() {
  printf '%s\n' $BENCH_LANG_MAP | jq -Rn '[inputs | select(. != "") | split(":") | {(.[0]): .[1]}] | add'
}

BENCH_LANG_JQ='
  def bench_lang($map):
    (tostring | split("/") | last | ascii_downcase) as $b
    | (if ($b | test("[.]")) then ($b | split(".") | last) else "" end) as $e
    | ($map[$e] // "other");
'
