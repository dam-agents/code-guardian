#!/usr/bin/env bash
# lib/ste.sh — the sentence measurement behind the STE bar, and the aggregation
# that carries it into the week's numbers (lib/review-records.sh). The bar
# grades prose, so review layout — headings, tables, code blocks, bullets —
# must never read as a long sentence. Contract: docs/review.md → **The sentence
# bar is 20 words**.
. "$(dirname "$0")/helpers.sh"

. "$REPO_ROOT/scripts/lib/ste.sh"
. "$REPO_ROOT/scripts/lib/review-records.sh"

SANDBOX="$(mktemp -d)"
SANDBOXES+=("$SANDBOX")

ok()  { printf 'ok   %s: %s\n' "$CASE" "$1"; }
bad() { printf 'FAIL %s: %s\n' "$CASE" "$1"; RC=1; }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1 (got '$2', want '$3')"; }
RC=0

# <name> <text> — measure a body and report one field
stat_of() { # <file> <field>
  ste_stats "$1" | jq -r --arg k "$2" '.[$k] | tostring'
}

CASE=layout_is_not_prose
# a review whose longest real sentence is 8 words: the heading, the table and
# the bullets must not merge into one sentence over the bar
cat > "$SANDBOX/review.md" <<'EOF'
## Review

### Summary
One pass over the diff. No blocking defect.

### Findings

🟡 **`scripts/lib/ste.sh:26` — the fallback is not JSON**

| Severity | Class | Locations |
| --- | --- | --- |
| warning | correctness | 1 |

- `ste_stats` returns a literal backslash
- the caller passes it to `jq --argjson`
- the ledger row is lost

**Fix:** put the default in a variable

### Verdict
APPROVE
EOF
is 'a compliant review has no sentence over the bar' \
   "$(stat_of "$SANDBOX/review.md" sentences_over_20)" '0'
is 'each bullet and each sentence counts once' \
   "$(stat_of "$SANDBOX/review.md" sentences)" '8'

CASE=blocks_and_wrapping
printf 'This is a wrapped sentence that continues\non the next line and ends here. Short one.\n' \
  > "$SANDBOX/wrap.md"
is 'a wrapped paragraph is not split at the line end' \
   "$(stat_of "$SANDBOX/wrap.md" sentences)" '2'
printf -- '- one bullet without a full stop\n- a second bullet\n' > "$SANDBOX/bul.md"
is 'a bullet with no terminal punctuation is one sentence' \
   "$(stat_of "$SANDBOX/bul.md" sentences)" '2'
printf 'Prose here.\n\n```suggestion\nthis code line is long enough to pass the bar on its own and must not count\n```\n\nMore prose.\n' \
  > "$SANDBOX/fence.md"
is 'a fenced block never counts' "$(stat_of "$SANDBOX/fence.md" sentences)" '2'
is 'and never trips the bar'     "$(stat_of "$SANDBOX/fence.md" sentences_over_20)" '0'

CASE=the_bar_itself
# one sentence of exactly <n> words — the full stop rides on the last word, or
# it would count as a word of its own
sentence() { # <n> <file>
  local i=1 s=""
  while [ "$i" -le "$1" ]; do s="$s word$i"; i=$((i+1)); done
  printf '%s.\n' "${s# }" > "$2"
}
sentence 20 "$SANDBOX/at.md"
is 'twenty words is inside the bar'  "$(stat_of "$SANDBOX/at.md" sentences_over_20)" '0'
is 'and is counted as one sentence'  "$(stat_of "$SANDBOX/at.md" sentences)" '1'
sentence 21 "$SANDBOX/over.md"
is 'twenty-one words is over it'     "$(stat_of "$SANDBOX/over.md" sentences_over_20)" '1'

CASE=unmeasurable_is_valid_json
# the callers pass this straight to `jq --argjson`; invalid JSON there loses the
# whole ledger row, not only the measurement (docs/review.md → Review ledger)
for arg in "/nonexistent/body.md" ""; do
  out="$(ste_stats "$arg")"
  printf '%s' "$out" | jq -e . >/dev/null 2>&1 \
    && ok "the zero row is valid JSON (${arg:-empty path})" \
    || bad "the zero row is not valid JSON: $out"
done
is 'and it reports nothing measured' "$(stat_of /nonexistent/body.md sentences)" '0'

CASE=one_broken_row_keeps_the_week
# a row whose measurement is half-written must not take the week's other
# numbers down with it (docs/audit.md → Review style)
{ printf '%s\n' '{"pr":1,"ts":"2026-09-16T00:00:00Z","ste":{"sentences":5,"avg_sentence_words":null,"sentences_over_20":1}}'
  printf '%s\n' '{"pr":2,"ts":"2026-09-16T00:00:00Z","ste":{"sentences":10,"avg_sentence_words":12.0,"sentences_over_20":2}}'
} > "$SANDBOX/rows.jsonl"
agg="$(jq -sc "$RR_AGG_JQ" "$SANDBOX/rows.jsonl" 2>/dev/null)"
is 'the aggregation still runs'        "$(printf '%s' "$agg" | jq -r '.reviews.total')" '2'
is 'the broken row is not measured'    "$(printf '%s' "$agg" | jq -r '.ste.reviews')" '1'
is 'the sound row still is'            "$(printf '%s' "$agg" | jq -r '.ste.avg_sentence_words')" '12'

exit "$RC"
