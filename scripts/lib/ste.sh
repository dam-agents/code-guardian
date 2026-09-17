#!/usr/bin/env bash
# ste.sh — the sentence measurement behind the STE bar (docs/review.md →
# **The sentence bar is 20 words**).
#
#   ste_stats <file>    # {sentences, avg_sentence_words, sentences_over_20}
#
# Prose only: fenced code blocks and HTML-comment lines are removed first, so a
# `suggestion` diff and the findings-json marker never count as sentences. A
# sentence ends at . ! or ?. One jq pass, no temp file and no per-sentence
# subprocess — this runs on every posted review and on every scored fixture.
#
# An unbalanced fence degrades this measurement alone; no caller may fail on it.
# Sourced by review-pr.sh (ledger row) and benchmark-score.sh (scorer output),
# so the weekly audit and the benchmark can never measure two different things.
# Needs jq.

ste_stats() { # <file>
  local f="${1:-}" out=""
  if [ -n "$f" ] && [ -f "$f" ]; then
    out="$(sed -e '/^[[:space:]]*```/,/^[[:space:]]*```/d' -e '/^[[:space:]]*<!--/d' "$f" \
      | tr '\n' ' ' \
      | sed -e 's/[.!?][[:space:]][[:space:]]*/\n/g' -e 's/[.!?][[:space:]]*$//' \
      | jq -Rsc '[split("\n")[] | select(test("[^[:space:]]")) | [scan("[^[:space:]]+")] | length]
                | {sentences: length,
                   avg_sentence_words: (if length == 0 then null
                                        else ((add / length * 10) | round) / 10 end),
                   sentences_over_20: ([.[] | select(. > 20)] | length)}' 2>/dev/null)"
  fi
  printf '%s\n' "${out:-{\"sentences\":0,\"avg_sentence_words\":null,\"sentences_over_20\":0\}}"
}
