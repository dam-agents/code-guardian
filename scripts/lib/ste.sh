#!/usr/bin/env bash
# ste.sh — the sentence measurement behind the STE bar (docs/review.md →
# **The sentence bar is 20 words**).
#
#   ste_stats <file>    # {sentences, avg_sentence_words, sentences_over_20, v}
#
# Prose only. Fenced code blocks, HTML-comment lines, headings and table rows
# are dropped first, so a `suggestion` diff, the findings-json marker and the
# layout of a finding never count as sentences. What survives is assembled into
# blocks — a blank line and a new list item start one, a wrapped line continues
# the block it belongs to — and each block splits further at . ! or ?. A block
# with no terminal punctuation is one sentence, which is what a bullet is.
#
# One jq pass, no temp file and no per-sentence subprocess — this runs on every
# posted review and on every scored fixture. An unbalanced fence degrades this
# measurement alone; no caller may fail on it, so an unreadable file and a
# failed pass both return the zero row.
#
# Sourced by review-pr.sh (ledger row) and benchmark-score.sh (scorer output),
# so the weekly audit and the benchmark can never measure two different things.
# Needs jq.
#
# `v` is the measurement itself: a reader compares two numbers only when both
# carry the same `v`, so a change here never reads as a style change in the
# benchmark delta (docs/benchmark.md). Raise it whenever the counting changes.
# v2 assembles blocks before splitting; v1 (unlabelled) split the whole text at
# every `. ` and read layout as prose.

STE_V=2
STE_ZERO='{"sentences":0,"avg_sentence_words":null,"sentences_over_20":0,"v":2}'

STE_JQ='
def strip_layout:
  reduce .[] as $l ({ fence: false, out: [] };
    if ($l | test("^[[:space:]]*```")) then .fence = (.fence | not)
    elif .fence then .
    elif ($l | test("^[[:space:]]*(<!--|#|\\||-{3,}[[:space:]]*$)")) then .
    else .out += [$l] end)
  | .out;
def blocks:
  reduce .[] as $l ([];
    if ($l | test("^[[:space:]]*$")) then . + [""]
    elif ($l | test("^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]")) then . + [$l]
    elif (length == 0) or (.[-1] | test("^[[:space:]]*$")) then . + [$l]
    else .[:-1] + [ .[-1] + " " + $l ] end);
split("\n") | strip_layout | blocks
| [ .[] | [splits("[.!?]+[[:space:]]+")] | .[] ]
| map(select(test("[^[:space:]]")) | [scan("[^[:space:]]+")] | length)
| {sentences: length,
   avg_sentence_words: (if length == 0 then null
                        else ((add / length * 10) | round) / 10 end),
   sentences_over_20: ([.[] | select(. > 20)] | length),
   v: $v}
'

ste_stats() { # <file>
  local f="${1:-}" out=""
  [ -n "$f" ] && [ -f "$f" ] \
    && out="$(jq -Rsc --argjson v "$STE_V" "$STE_JQ" "$f" 2>/dev/null)"
  printf '%s\n' "${out:-$STE_ZERO}"
}
