#!/usr/bin/env bash
# benchmark-judge.sh — score one benchmark review with the pinned judge model
# (docs/benchmark.md → Running the benchmark, phase 2, step 6):
#
#   benchmark-judge.sh <first|rereview> <judge-model> <raw-review> <manifest.json> \
#                      <scorer.json> [<prior-review.md>]
#   benchmark-judge.sh check <judge-model>
#
# `check` makes no model call: it prints nothing and exits 0 when this host
# can run the judge, else one line with the reason and exits 1. Preflight's
# benchmark pass and the monitor run it (docs/benchmark.md, docs/monitor.md →
# `judge_unavailable`). The claude CLI counts as signed in when `claude auth
# status` says so, or when the environment carries its credentials — `auth
# status` reports a gateway token (ANTHROPIC_AUTH_TOKEN) as signed out. A pi
# CLI on the host is enough too: it is the fallback below.
#
# Prints one JSON object and exits 0 whatever the judge did:
#
#   {"status": "ok|off|unavailable|failed|mismatch",
#    "judge": {finding_accuracy, …, notes} | null,
#    "judge_model_used": "<model that answered>" | null,
#    "judge_harness": "claude|pi" | null,
#    "tokens": {input, output, cache_read, cache_creation} | null,
#    "reason": "<why judge is null>" | null}
#
# The judge is a separate headless process, never a subagent of the run: a
# subagent inherits the session model on every harness that cannot pin one
# per agent, so each tested model judged itself and the judge scores of two
# models were not comparable. Here the model and the rubric
# (scripts/templates/judge-brief.md) are the same for every run, whatever
# model or harness the reviews ran on. The process is `claude -p`; when that
# CLI is missing or not signed in, it is `pi --mode json` on the same pinned
# model, through this host's pi provider (PI_PROVIDER) — a pi pod reaches its
# models without a claude sign-in. Either process has no tools, no MCP
# servers, no hooks or extensions, no saved session and an empty working
# directory: it reads only the inputs this script gives it.
#
# The script trusts no claim of the model. `judge_model_used` comes from the
# CLI's own usage record (claude: `modelUsage`; pi: the assistant message's
# `responseModel`, else its `model`); a reply from any model the pinned id does not match
# (MODEL_JQ in lib/common.sh) is `mismatch` and keeps `judge` null — a judge
# score from the wrong model is worse than no score. Each dimension must be an
# integer 1–5, or the reply is `failed`.
#
# Exit 2 only on a usage error. Overrides (tests): CG_JUDGE_CLI (the claude
# binary), CG_JUDGE_PI (the pi binary), CG_JUDGE_TIMEOUT (seconds, default
# 600).
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$SCRIPT_DIR/lib/toolpath.sh" ] && . "$SCRIPT_DIR/lib/toolpath.sh" 2>/dev/null
. "$SCRIPT_DIR/lib/common.sh"   # MODEL_JQ
BRIEF="$SCRIPT_DIR/templates/judge-brief.md"

KIND="${1:-}"; MODEL="${2:-}"; REVIEW="${3:-}"; MANIFEST="${4:-}"; SCORER="${5:-}"; PRIOR="${6:-}"
usage() { printf 'usage: benchmark-judge.sh first|rereview <judge-model> <raw-review> <manifest.json> <scorer.json> [<prior-review.md>]\n       benchmark-judge.sh check <judge-model>\n' >&2; exit 2; }
CLI="${CG_JUDGE_CLI:-claude}"
PI="${CG_JUDGE_PI:-pi}"
NOT_SIGNED_IN="the '$CLI' CLI on this host is not signed in: run \`claude auth login\` on the host once, or set ANTHROPIC_API_KEY"
NO_FALLBACK="no '$PI' CLI to fall back to"

# nothing and 0 when claude -p can answer, else the reason and 1
claude_why() {
  command -v "$CLI" >/dev/null 2>&1 || { printf "no '%s' CLI on this host" "$CLI"; return 1; }
  [ -n "${ANTHROPIC_API_KEY:-}${ANTHROPIC_AUTH_TOKEN:-}${CLAUDE_CODE_OAUTH_TOKEN:-}${CLAUDE_CODE_USE_BEDROCK:-}${CLAUDE_CODE_USE_VERTEX:-}${CLAUDE_CODE_USE_FOUNDRY:-}" ] && return 0
  local to=(); command -v timeout >/dev/null 2>&1 && to=(timeout 20)
  ${to[@]+"${to[@]}"} "$CLI" auth status 2>/dev/null | jq -e '.loggedIn == true' >/dev/null 2>&1 && return 0
  printf '%s' "$NOT_SIGNED_IN"; return 1
}
pi_ready() { command -v "$PI" >/dev/null 2>&1; }

if [ "$KIND" = check ]; then
  [ -n "$MODEL" ] || usage
  case "$MODEL" in (off|none|null) exit 0;; esac
  WHY="$(claude_why)" && exit 0
  pi_ready && exit 0
  printf '%s; %s\n' "$WHY" "$NO_FALLBACK"; exit 1
fi

case "$KIND" in (first|rereview) ;; (*) usage;; esac
[ -n "$MODEL" ] && [ -r "$REVIEW" ] && [ -r "$MANIFEST" ] && [ -r "$SCORER" ] || usage
[ "$KIND" = first ] || [ -r "$PRIOR" ] || usage

JH=""   # the harness that answered: claude | pi
out() { # <status> <judge json> <model or empty> <tokens json> <reason or empty>
  jq -cn --arg s "$1" --argjson j "$2" --arg m "$3" --argjson t "$4" --arg r "$5" --arg h "$JH" \
    '{status: $s, judge: $j, judge_model_used: (if $m == "" then null else $m end),
      judge_harness: (if $h == "" then null else $h end),
      tokens: $t, reason: (if $r == "" then null else $r end)}'
  exit 0
}

case "$MODEL" in (off|none|null) out off null "" null "benchmark_judge is off";; esac
if WHY="$(claude_why)"; then JH=claude
elif pi_ready; then JH=pi
else out unavailable null "" null "$WHY; $NO_FALLBACK"
fi
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
run_claude() {
  ( cd "$TMP" && ${TO[@]+"${TO[@]}"} "$CLI" -p --model "$MODEL" --output-format json \
      --tools "" --strict-mcp-config --settings '{"disableAllHooks":true}' \
      --no-session-persistence --system-prompt-file "$TMP/brief.md" \
      < "$TMP/input.md" > "$TMP/reply.json" 2> "$TMP/stderr" )
}
# pi's event stream, turned into the claude reply shape the checks below read:
# the last assistant message's text, usage and model — the provider's
# `responseModel` where it names one, else the requested `model`. Outside this session:
# no session id of its own, so the definition's extension (also off) and the
# platform never count it as a run.
run_pi() {
  local args=(--mode json --no-session --no-tools --no-extensions --no-skills
              --no-prompt-templates --no-context-files --no-mcp --model "$MODEL"
              --system-prompt "$(cat "$TMP/brief.md")")
  [ -n "${PI_PROVIDER:-}" ] && args+=(--provider "$PI_PROVIDER")
  ( cd "$TMP" && env -u PI_SESSION_ID -u PI_SESSION_FILE ${TO[@]+"${TO[@]}"} "$PI" "${args[@]}" \
      "@$TMP/input.md" "Score the review in the attached input. Reply with the JSON object only." \
      < /dev/null > "$TMP/events.jsonl" 2> "$TMP/stderr" )
  local rc=$?
  jq -cR 'fromjson? // empty' "$TMP/events.jsonl" 2>/dev/null | jq -cs '
    [ .[] | select(.type == "message_end" and .message.role? == "assistant") | .message ] | last
    | select(type == "object")
    | (.stopReason == "error" or .stopReason == "aborted") as $err
    | {is_error: $err,
       result: (if $err then (.errorMessage // "pi stopped on \(.stopReason)")
                else [.content[]? | select(.type == "text") | .text] | join("") end),
       usage: (.usage | if type == "object" then {input_tokens: .input, output_tokens: .output,
               cache_read_input_tokens: .cacheRead, cache_creation_input_tokens: .cacheWrite} else null end),
       modelUsage: ((.responseModel // .model) as $m
                    | if ($m | type) == "string" and $m != "" then {($m): {}} else {} end)}' \
    > "$TMP/reply.json" 2>/dev/null
  return "$rc"
}
if [ "$JH" = claude ]; then
  run_claude; RC=$?
  # a sign-in that `auth status` reported but the call refused
  if jq -e '.is_error == true and (.result // "" | tostring | test("^Not logged in"))' "$TMP/reply.json" >/dev/null 2>&1 \
     && pi_ready; then JH=pi; fi
fi
if [ "$JH" = pi ]; then run_pi; RC=$?; fi

jq -e 'type == "object"' "$TMP/reply.json" >/dev/null 2>&1 \
  || out failed null "" null "judge $JH CLI exit $RC, no JSON reply: $(head -c 200 "$TMP/stderr" | tr '\n' ' ')"

TOKENS="$(jq -c '.usage | if type == "object" then
  {input: (.input_tokens // 0), output: (.output_tokens // 0),
   cache_read: (.cache_read_input_tokens // 0), cache_creation: (.cache_creation_input_tokens // 0)}
  else null end' "$TMP/reply.json" 2>/dev/null)"
TOKENS="${TOKENS:-null}"

if jq -e '.is_error == true and (.result // "" | tostring | test("^Not logged in"))' "$TMP/reply.json" >/dev/null 2>&1; then
  out unavailable null "" "$TOKENS" "$NOT_SIGNED_IN; $NO_FALLBACK"
fi
if jq -e '.is_error == true' "$TMP/reply.json" >/dev/null 2>&1; then
  out failed null "" "$TOKENS" "judge $JH CLI error: $(jq -r '.result // "" | tostring | .[0:200]' "$TMP/reply.json")"
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
