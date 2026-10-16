#!/usr/bin/env bash
# benchmark-judge.sh — score one benchmark review with the pinned judge model
# (docs/benchmark.md → Running the benchmark, phase 2, step 6):
#
#   benchmark-judge.sh <first|rereview> <judge-model> <raw-review> <manifest.json> \
#                      <scorer.json> [<prior-review.md>]
#
# Prints one JSON object and exits 0 whatever the judge did:
#
#   {"status": "ok|off|unavailable|failed|mismatch",
#    "judge": {finding_accuracy, …, notes} | null,
#    "judge_model_used": "<model that answered>" | null,
#    "tokens": {input, output, cache_read, cache_creation} | null,
#    "reason": "<why judge is null>" | null}
#
# The judge is a separate headless `claude -p` process, never a subagent of
# the run: a subagent inherits the session model on every harness that cannot
# pin one per agent, so each tested model judged itself and the judge scores
# of two models were not comparable. Here the model, the harness and the
# rubric (scripts/templates/judge-brief.md) are the same for every run,
# whatever model or harness the reviews ran on. The process has no tools, no
# MCP servers, no hooks, no saved session and an empty working directory: it
# reads only the inputs this script gives it.
#
# The script trusts no claim of the model. `judge_model_used` comes from the
# CLI's own `modelUsage`; a reply from any model the pinned id does not match
# (MODEL_JQ in lib/common.sh) is `mismatch` and keeps `judge` null — a judge
# score from the wrong model is worse than no score. Each dimension must be an
# integer 1–5, or the reply is `failed`.
#
# Exit 2 only on a usage error. Overrides (tests): CG_JUDGE_CLI (the claude
# binary), CG_JUDGE_TIMEOUT (seconds, default 600).
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$SCRIPT_DIR/lib/toolpath.sh" ] && . "$SCRIPT_DIR/lib/toolpath.sh" 2>/dev/null
. "$SCRIPT_DIR/lib/common.sh"   # MODEL_JQ
BRIEF="$SCRIPT_DIR/templates/judge-brief.md"

KIND="${1:-}"; MODEL="${2:-}"; REVIEW="${3:-}"; MANIFEST="${4:-}"; SCORER="${5:-}"; PRIOR="${6:-}"
usage() { printf 'usage: benchmark-judge.sh first|rereview <judge-model> <raw-review> <manifest.json> <scorer.json> [<prior-review.md>]\n' >&2; exit 2; }
case "$KIND" in (first|rereview) ;; (*) usage;; esac
[ -n "$MODEL" ] && [ -r "$REVIEW" ] && [ -r "$MANIFEST" ] && [ -r "$SCORER" ] || usage
[ "$KIND" = first ] || [ -r "$PRIOR" ] || usage

out() { # <status> <judge json> <model or empty> <tokens json> <reason or empty>
  jq -cn --arg s "$1" --argjson j "$2" --arg m "$3" --argjson t "$4" --arg r "$5" \
    '{status: $s, judge: $j, judge_model_used: (if $m == "" then null else $m end),
      tokens: $t, reason: (if $r == "" then null else $r end)}'
  exit 0
}

case "$MODEL" in (off|none|null) out off null "" null "benchmark_judge is off";; esac
CLI="${CG_JUDGE_CLI:-claude}"
command -v "$CLI" >/dev/null 2>&1 || out unavailable null "" null "no '$CLI' CLI on this host"
[ -r "$BRIEF" ] || out failed null "" null "judge brief missing: $BRIEF"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cg-judge.XXXXXX")" || out failed null "" null "cannot create a temp dir"
trap 'rm -rf "$TMP"' EXIT

DIMS='["finding_accuracy","category_accuracy","fix_quality","fp_defensibility","clarity","language"]'
if [ "$KIND" = rereview ]; then
  DIMS='["finding_accuracy","category_accuracy","fix_quality","fp_defensibility","clarity","language","loop_risk"]'
  LOOP='- `loop_risk` — 5 = no circling: the review acknowledges each fix and never
  flags it again or asks to revert it. Read `churn` and `false_fixed` in
  `SCORER` as evidence.
'
  LOOP_KEY=', "loop_risk": 0'
else
  LOOP=''; LOOP_KEY=''
fi
# through the environment: BSD awk refuses a newline in a -v value
LOOP="$LOOP" LOOP_KEY="$LOOP_KEY" awk '
  /^\{\{LOOP_RISK\}\}$/ { printf "%s", ENVIRON["LOOP"]; next }
  { gsub(/\{\{LOOP_RISK_KEY\}\}/, ENVIRON["LOOP_KEY"]); print }' "$BRIEF" > "$TMP/brief.md" \
  || out failed null "" null "cannot render the judge brief"

{
  printf '## REVIEW\n\n'; cat "$REVIEW"
  printf '\n\n## MANIFEST\n\n'; cat "$MANIFEST"
  printf '\n\n## SCORER\n\n'; cat "$SCORER"
  [ "$KIND" = rereview ] && { printf '\n\n## PRIOR REVIEW\n\n'; cat "$PRIOR"; }
  printf '\n'
} > "$TMP/input.md"

TO=()
command -v timeout >/dev/null 2>&1 && TO=(timeout "${CG_JUDGE_TIMEOUT:-600}")
( cd "$TMP" && ${TO[@]+"${TO[@]}"} "$CLI" -p --model "$MODEL" --output-format json \
    --tools "" --strict-mcp-config --settings '{"disableAllHooks":true}' \
    --no-session-persistence --system-prompt-file "$TMP/brief.md" \
    < "$TMP/input.md" > "$TMP/reply.json" 2> "$TMP/stderr" )
RC=$?

jq -e 'type == "object"' "$TMP/reply.json" >/dev/null 2>&1 \
  || out failed null "" null "judge CLI exit $RC, no JSON reply: $(head -c 200 "$TMP/stderr" | tr '\n' ' ')"

TOKENS="$(jq -c '.usage | if type == "object" then
  {input: (.input_tokens // 0), output: (.output_tokens // 0),
   cache_read: (.cache_read_input_tokens // 0), cache_creation: (.cache_creation_input_tokens // 0)}
  else null end' "$TMP/reply.json" 2>/dev/null)"
TOKENS="${TOKENS:-null}"

if jq -e '.is_error == true' "$TMP/reply.json" >/dev/null 2>&1; then
  out failed null "" "$TOKENS" "judge CLI error: $(jq -r '.result // "" | tostring | .[0:200]' "$TMP/reply.json")"
fi

USED="$(jq -r '.modelUsage // {} | keys | join(",")' "$TMP/reply.json" 2>/dev/null)"
[ -n "$USED" ] || out failed null "" "$TOKENS" "judge reply names no model (modelUsage empty)"
jq -e --arg m "$MODEL" "$MODEL_JQ"'.modelUsage | keys | all(model_has($m))' "$TMP/reply.json" >/dev/null 2>&1 \
  || out mismatch null "$USED" "$TOKENS" "judge pinned to $MODEL, but $USED answered"

# the reply text is one JSON object; a model that still wraps it in a code
# fence or a sentence gets the outermost {...} cut out of it. The cut works on
# code points: jq 1.7 string index/rindex give byte offsets, so one non-ASCII
# character would shift a string slice
SCORES="$(jq -c --argjson dims "$DIMS" '
  (.result // "" | tostring) as $t
  | ($t | try fromjson catch
      ($t | explode | (index(123)) as $a | (rindex(125)) as $b
          | if $a == null or $b == null then null else (.[$a:$b + 1] | implode | try fromjson catch null) end)) as $o
  | if ($o | type) != "object" then null
    elif all($dims[]; . as $k | $o[$k] | type == "number" and . == floor and . >= 1 and . <= 5)
    then ($o | with_entries(select(.key as $k | $dims | index($k)))) + {notes: ($o.notes // "" | tostring)}
    else null end' "$TMP/reply.json" 2>/dev/null)"
[ -n "$SCORES" ] && [ "$SCORES" != null ] \
  || out failed null "$USED" "$TOKENS" "judge reply is not the score object: $(jq -r '.result // "" | tostring | .[0:200]' "$TMP/reply.json")"

out ok "$SCORES" "$USED" "$TOKENS" ""
