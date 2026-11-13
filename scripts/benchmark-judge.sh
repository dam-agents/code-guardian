#!/usr/bin/env bash
# benchmark-judge.sh — score one benchmark review with the pinned judge model,
# or with the judge panel (docs/benchmark.md → Running the benchmark, phase 2,
# step 6):
#
#   benchmark-judge.sh <first|rereview> <judge-model>[,<judge-model>] <raw-review> \
#                      <manifest.json> <scorer.json> [<prior-review.md>]
#   benchmark-judge.sh check <judge-model>[,<judge-model>]
#   benchmark-judge.sh resolve
#   benchmark-judge.sh models
#   benchmark-judge.sh pin <judge-model> <why>
#
# `resolve` prints the judge every run uses, as one JSON object
# {judge, panel, panel_note, panel_unavailable, source, configured,
# judge_unavailable, cause, candidate}, and makes no model call. `configured`
# is `benchmark_judge` from work/CONFIG.md (missing = off). `judge` is the
# exact id this host serves for it: the name may be short or carry another
# provider prefix (`opus-5`, `claude/aws/claude-opus-5`), and the served id
# with the highest version that matches it is the judge.
# Under `auto`, `judge` is the model the agent pinned in
# work/benchmark/judge.json (source `picked`); with no pin (`unpicked`), or a
# pin the host no longer serves (`repick`), it is `candidate` — the newest Opus
# the host serves, else the newest Sonnet — or `auto` while the list is
# unknown. `judge_unavailable` says why no judge can run, and `cause` names it
# in one word: `no_cli`, `not_signed_in` or `not_served` (the host serves no
# model that matches). An unknown model list never makes a judge unavailable.
# Preflight's benchmark pass, the monitor and an operator-asked run read the
# same object, so every run gets the same judge. `models` prints the served ids.
#
# The panel: `benchmark_judge: <a>, <b>` (source `config`) names two judges of
# different model families. `panel` is the served id of each member, resolved
# like one id; a member the host does not serve leaves the panel and is listed
# in `panel_unavailable` [{configured, judge_unavailable, cause}]. With one
# member left, `panel_note` is "one family only"; with none, the top
# `judge_unavailable` and `cause` are set. `judge` is the first panel member,
# for older readers. `auto` and one id give a panel of one: [judge] ([] when off).
#
# `pin` records the agent's pick under `auto` (docs/benchmark.md → **Choosing
# the judge**) and moves the previous pick into `replaced`. It refuses while
# `benchmark_judge` is off, a model id or a panel: the operator's ids win.
#
# `check` makes no model call: it prints nothing and exits 0 when this host
# can run the judge — a CLI is ready and, when the model list is known, the
# host serves a model the name matches — else one line with the reason and
# exits 1. Onboarding runs it for the operator (docs/benchmark.md,
# docs/monitor.md → `judge_unavailable`). The claude CLI counts as signed in when `claude auth
# status` says so, or when the environment carries its credentials — `auth
# status` reports a gateway token (ANTHROPIC_AUTH_TOKEN) as signed out. A pi
# CLI on the host is enough too: it is the fallback below. For a panel, it
# prints one line per member that cannot run, and exits 1 only when no member
# can run.
#
# Prints one JSON object and exits 0 whatever the judge did:
#
#   {"status": "ok|off|unavailable|failed|mismatch",
#    "judge": {finding_accuracy, …, notes, fp_class} | null,
#    "judge_model_used": "<model that answered>" | null,
#    "judge_harness": "claude|pi" | null,
#    "tokens": {input, output, cache_read, cache_creation} | null,
#    "reason": "<why judge is null>" | null}
#
# `fp_class` classifies each scorer `fp` entry: [{file, line, class}], class
# `real` (probably a real defect the manifest does not list), `defensible` or
# `fabricated`; null when the reply has no valid list for every fp (the
# dimensions still count).
#
# A panel (`<judge-model>` is a comma list) runs every member in parallel, each
# exactly as one judge, and prints the same object: `status` is ok when at
# least one member is ok; `judge` holds each dimension averaged over the ok
# members (2 decimals) and `notes` as "<model>: <notes>" joined by " | ", plus
# `panel` [{model, harness, status, scores, fp_class, tokens, reason}] for every
# member, `disagreement` (max over the dimensions of max - min across the ok
# members; null with fewer than 2) and `fp_class` (majority class per fp over
# the members with a valid list, a tie is `defensible`). `judge_model_used` and
# `judge_harness` are comma lists over the ok members; `tokens` is the sum over
# all members. With no ok member, `judge` is null, `status` is the first
# member's and `reason` lists each member's.
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
# 600), WORK_DIR (the work/ directory).
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$SCRIPT_DIR/lib/toolpath.sh" ] && . "$SCRIPT_DIR/lib/toolpath.sh" 2>/dev/null
. "$SCRIPT_DIR/lib/common.sh"   # MODEL_JQ
BRIEF="$SCRIPT_DIR/templates/judge-brief.md"

KIND="${1:-}"; MODEL="${2:-}"; REVIEW="${3:-}"; MANIFEST="${4:-}"; SCORER="${5:-}"; PRIOR="${6:-}"
usage() { printf 'usage: benchmark-judge.sh first|rereview <judge-model>[,<judge-model>] <raw-review> <manifest.json> <scorer.json> [<prior-review.md>]\n       benchmark-judge.sh check <judge-model>[,<judge-model>]\n       benchmark-judge.sh resolve | models\n       benchmark-judge.sh pin <judge-model> <why>\n' >&2; exit 2; }
WORK="${WORK_DIR:-${HOME:-/home/agent}/work}"
CONFIG="$WORK/CONFIG.md"
PICK="$WORK/benchmark/judge.json"
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

# The models this host serves, one id per line; nothing when the list is
# unknown (no listing endpoint, an OAuth or cloud sign-in, a failed request).
# claude: GET /v1/models of the CLI's endpoint; pi: `pi --list-models`. An
# unknown list never blocks the judge: the name is used as configured.
served_models() { # <claude|pi>
  if [ -n "${CG_JUDGE_MODELS+x}" ]; then cat "$CG_JUDGE_MODELS" 2>/dev/null; return 0; fi
  if [ "$1" = pi ]; then
    local p m rest
    "$PI" --list-models 2>/dev/null | sed 1d | while read -r p m rest; do
      [ -n "$m" ] || continue
      if [ -n "${PI_PROVIDER:-}" ]; then [ "$p" = "$PI_PROVIDER" ] && printf '%s\n' "$m"
      else printf '%s/%s\n' "$p" "$m"; fi
    done
    return 0
  fi
  [ -n "${ANTHROPIC_AUTH_TOKEN:-}${ANTHROPIC_API_KEY:-}" ] || return 0
  local h; h="$(mktemp)" || return 0
  chmod 600 "$h"
  { printf 'anthropic-version: 2023-06-01\n'
    if [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then printf 'Authorization: Bearer %s\n' "$ANTHROPIC_AUTH_TOKEN"
    else printf 'x-api-key: %s\n' "$ANTHROPIC_API_KEY"; fi; } > "$h"
  local base="${ANTHROPIC_BASE_URL:-https://api.anthropic.com}"
  curl -fsS -m 10 -H "@$h" "${base%/}/v1/models?limit=1000" 2>/dev/null \
    | jq -r '.data[]?.id | strings' 2>/dev/null
  rm -f "$h"
}
# jq over the served ids: the one id a name means — the same id, else the same
# model under another provider prefix, else every id the name matches
# (MODEL_JQ: `opus-5` matches `claude-opus-5`, never `claude-opus-5-5`); of
# several, the highest version, then the first id in sort order. null: no match
PICK_JQ="$MODEL_JQ"'
  def ver: model_key | [scan("[0-9]+") | tonumber];
  def pick($n): . as $ids
    | [$ids[] | select(. == $n)] as $same
    | [$ids[] | select(model_key == ($n | model_key))] as $key
    | (if ($same | length) > 0 then $same elif ($key | length) > 0 then $key
       else [$ids[] | select(model_has($n))] end)
    | if length == 0 then null
      else (map(ver) | max) as $v | map(select(ver == $v)) | sort | .[0] end;
'
pick_model() { # <name> <ids> → the served id, or nothing
  printf '%s\n' "$2" | jq -R . | jq -rs --arg n "$1" "$PICK_JQ"'map(select(. != "")) | pick($n) // empty' 2>/dev/null
}
# the judge auto recommends: the newest Opus the host serves, else the newest Sonnet
candidate() { # <ids>
  local c; c="$(pick_model opus "$1")"; [ -n "$c" ] || c="$(pick_model sonnet "$1")"; printf '%s' "$c"
}

# Sets JH (claude|pi) and WHY/CAUSE (empty, or why this host cannot run any judge)
harness_ready() {
  WHY=""; CAUSE=""
  if WHY="$(claude_why)"; then JH=claude
  elif pi_ready; then JH=pi; WHY=""
  else
    case "$WHY" in ("no '"*) CAUSE=no_cli;; (*) CAUSE=not_signed_in;; esac
    WHY="$WHY; $NO_FALLBACK"; JH=""
  fi
}
not_served() { # <name>
  WHY="this host serves no model that matches '$1' (benchmark-judge.sh models lists them)"; CAUSE=not_served
}

# the members of a comma list, one per line, trimmed, empty ones dropped
members() { printf '%s\n' "$1" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$'; }

if [ "$KIND" = models ]; then
  harness_ready
  [ -n "$JH" ] || { printf '%s\n' "$WHY" >&2; exit 1; }
  served_models "$JH"; exit 0
fi
if [ "$KIND" = check ]; then
  [ -n "$MODEL" ] || usage
  case "$MODEL" in (off|none|null) exit 0;; esac
  case "$MODEL" in (*,*)  # a panel: one line per member that cannot run
    OKN=0
    while IFS= read -r m; do
      if r="$(bash "$0" check "$m")"; then OKN=$((OKN + 1)); else printf '%s: %s\n' "$m" "$r"; fi
    done <<< "$(members "$MODEL")"
    [ "$OKN" -gt 0 ] && exit 0; exit 1;;
  esac
  harness_ready
  if [ -z "$WHY" ]; then
    IDS="$(served_models "$JH")"
    if [ -n "$IDS" ]; then
      if [ "$MODEL" = auto ]; then [ -n "$(candidate "$IDS")" ] || not_served opus
      else [ -n "$(pick_model "$MODEL" "$IDS")" ] || not_served "$MODEL"; fi
    fi
  fi
  [ -z "$WHY" ] && exit 0
  printf '%s\n' "$WHY"; exit 1
fi

CONF="$(cfg benchmark_judge)"
case "$CONF" in ("" |none|null) CONF=off;; esac
if [ "$KIND" = resolve ]; then
  CAND=""; WHY=""; CAUSE=""
  case "$CONF" in (*,*)  # a panel: each member resolves like one id
    PANEL='[]'; GONE='[]'; J=""
    harness_ready
    IDS=""; [ -z "$WHY" ] && IDS="$(served_models "$JH")"
    HWHY="$WHY"; HCAUSE="$CAUSE"
    while IFS= read -r m; do
      WHY=""; CAUSE=""; M="$m"
      if [ -n "$IDS" ]; then M="$(pick_model "$m" "$IDS")"; [ -n "$M" ] || not_served "$m"; fi
      if [ -n "$WHY" ]; then
        GONE="$(jq -c --arg c "$m" --arg w "$WHY" --arg k "$CAUSE" '. + [{configured: $c, judge_unavailable: $w, cause: $k}]' <<< "$GONE")"
      else PANEL="$(jq -c --arg m "$M" 'if any(.[]; . == $m) then . else . + [$m] end' <<< "$PANEL")"; fi
    done <<< "$(members "$CONF")"
    WHY="$HWHY"; CAUSE="$HCAUSE"
    if [ -z "$WHY" ] && [ "$PANEL" = '[]' ]; then
      WHY="this host serves no model of the judge panel '$CONF' (benchmark-judge.sh models lists them)"; CAUSE=not_served
    fi
    J="$(jq -r '.[0] // empty' <<< "$PANEL")"; [ -n "$J" ] || J="$(members "$CONF" | head -1)"
    jq -cn --arg j "$J" --argjson p "$PANEL" --argjson g "$GONE" --arg c "$CONF" --arg w "$WHY" --arg k "$CAUSE" \
      '{judge: $j, panel: $p, panel_note: (if ($p | length) == 1 then "one family only" else null end),
        panel_unavailable: $g, source: "config", configured: $c,
        judge_unavailable: (if $w == "" then null else $w end),
        cause: (if $k == "" then null else $k end), candidate: null}'
    exit 0;;
  esac
  case "$CONF" in
    (off)  J=off; SRC=off;;
    (auto) J="$(jq -r '.model // empty | strings' "$PICK" 2>/dev/null)"
           if [ -n "$J" ]; then SRC=picked; else J=auto; SRC=unpicked; fi;;
    (*)    J="$CONF"; SRC=config;;
  esac
  if [ "$J" != off ]; then
    harness_ready
    IDS=""; [ -z "$WHY" ] && IDS="$(served_models "$JH")"
    if [ -n "$IDS" ]; then
      [ "$CONF" = auto ] && CAND="$(candidate "$IDS")"
      if [ "$J" = auto ]; then
        [ -n "$CAND" ] && J="$CAND" || not_served opus
      elif M="$(pick_model "$J" "$IDS")" && [ -n "$M" ]; then J="$M"
      elif [ "$SRC" = picked ] && [ -n "$CAND" ]; then J="$CAND"; SRC=repick
      else not_served "$J"; fi
    fi
  fi
  jq -cn --arg j "$J" --arg s "$SRC" --arg c "$CONF" --arg w "$WHY" --arg k "$CAUSE" --arg d "$CAND" \
    '{judge: $j, panel: (if $j == "off" then [] else [$j] end), panel_note: null, panel_unavailable: [],
      source: $s, configured: $c,
      judge_unavailable: (if $w == "" then null else $w end),
      cause: (if $k == "" then null else $k end),
      candidate: (if $d == "" then null else $d end)}'
  exit 0
fi
if [ "$KIND" = pin ]; then
  WHY_PIN="${3:-}"
  [ -n "$MODEL" ] && [ -n "$WHY_PIN" ] || usage
  case "$MODEL" in (off|none|null|auto|*,*) usage;; esac
  [ "$CONF" = auto ] || { printf 'benchmark_judge is %s, not auto: the operator chose the judge\n' "$CONF" >&2; exit 1; }
  mkdir -p "${PICK%/*}" || exit 1
  OLD="$(jq -c 'if type == "object" then . else {} end' "$PICK" 2>/dev/null | head -1)"
  [ -n "$OLD" ] || OLD='{}'
  printf '%s\n' "$OLD" \
    | jq --arg m "$MODEL" --arg w "$WHY_PIN" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        (if (.model // "") != "" and .model != $m
         then [{model, chosen, why, until: $t}] else [] end) as $old
        | {model: $m, chosen: (if .model == $m then .chosen else $t end), why: $w,
           replaced: ((.replaced // []) + $old)}' > "$PICK.tmp" \
    && mv "$PICK.tmp" "$PICK" || { rm -f "$PICK.tmp"; exit 1; }
  cat "$PICK"; exit 0
fi

case "$KIND" in (first|rereview) ;; (*) usage;; esac
[ -n "$MODEL" ] && [ -r "$REVIEW" ] && [ -r "$MANIFEST" ] && [ -r "$SCORER" ] || usage
[ "$KIND" = first ] || [ -r "$PRIOR" ] || usage
DIMS='["finding_accuracy","category_accuracy","fix_quality","fp_defensibility","clarity","language"]'
[ "$KIND" = rereview ] && DIMS='["finding_accuracy","category_accuracy","fix_quality","fp_defensibility","clarity","language","loop_risk"]'

# a panel: every member is one judge call of this script, in parallel; the
# merge averages the ok members and takes the majority class of each fp
case "$MODEL" in (*,*)
  PT="$(mktemp -d "${TMPDIR:-/tmp}/cg-panel.XXXXXX")" || { printf '{"status":"failed","judge":null,"judge_model_used":null,"judge_harness":null,"tokens":null,"reason":"cannot create a temp dir"}\n'; exit 0; }
  trap 'rm -rf "$PT"' EXIT
  N=0
  while IFS= read -r m; do
    N=$((N + 1)); printf '%s' "$m" > "$PT/$N.model"
    bash "$0" "$KIND" "$m" "$REVIEW" "$MANIFEST" "$SCORER" ${PRIOR:+"$PRIOR"} > "$PT/$N.json" 2>/dev/null &
  done <<< "$(members "$MODEL")"
  wait
  for i in $(seq 1 "$N"); do
    jq -e 'type == "object"' "$PT/$i.json" >/dev/null 2>&1 \
      || printf '{"status":"failed","judge":null,"judge_model_used":null,"judge_harness":null,"tokens":null,"reason":"no JSON from the member call"}' > "$PT/$i.json"
    jq -c --rawfile m "$PT/$i.model" '{model: (.judge_model_used // $m), harness: .judge_harness, status,
        scores: (.judge | if type == "object" then del(.fp_class) else null end),
        fp_class: (.judge.fp_class? // null), tokens, reason}' "$PT/$i.json"
  done | jq -cs --argjson dims "$DIMS" '
    def r2: (. * 100 | round) / 100;
    . as $panel | [ .[] | select(.status == "ok") ] as $ok
    | if ($ok | length) == 0 then
        {status: ($panel[0].status // "failed"), judge: null, judge_model_used: null, judge_harness: null,
         tokens: null, reason: ([ $panel[] | "\(.model): \(.reason // .status)" ] | join("; "))}
      else
        ([ $ok[] | select(.fp_class | type == "array") | .fp_class ]) as $fpc
        | {status: "ok",
           judge: (reduce $dims[] as $k ({}; . + {($k): ([ $ok[].scores[$k] ] | add / length | r2)})
             + {notes: ([ $ok[] | "\(.model): \(.scores.notes // "")" ] | join(" | ")),
                panel: $panel,
                disagreement: (if ($ok | length) < 2 then null
                  else [ $dims[] as $k | [ $ok[].scores[$k] ] | max - min ] | max end),
                fp_class: (if ($fpc | length) == 0 then null
                  else [ range(0; $fpc[0] | length) as $i
                         | [ $fpc[][$i].class ] as $v
                         | ([ "real", "defensible", "fabricated" ]
                            | map({c: ., n: (. as $c | $v | map(select(. == $c)) | length)})
                            | max_by(.n).n as $top | map(select(.n == $top))) as $best
                         | $fpc[0][$i] + {class: (if ($best | length) == 1 then $best[0].c else "defensible" end)} ]
                  end)}),
           judge_model_used: ([ $ok[].model ] | join(",")),
           judge_harness: ([ $ok[].harness ] | join(",")),
           tokens: ([ $panel[].tokens | select(type == "object") ]
             | if length == 0 then null
               else {input: (map(.input) | add), output: (map(.output) | add),
                     cache_read: (map(.cache_read) | add), cache_creation: (map(.cache_creation) | add)} end),
           reason: null}
      end'
  exit 0;;
esac

JH=""   # the harness that answered: claude | pi
out() { # <status> <judge json> <model or empty> <tokens json> <reason or empty>
  jq -cn --arg s "$1" --argjson j "$2" --arg m "$3" --argjson t "$4" --arg r "$5" --arg h "$JH" \
    '{status: $s, judge: $j, judge_model_used: (if $m == "" then null else $m end),
      judge_harness: (if $h == "" then null else $h end),
      tokens: $t, reason: (if $r == "" then null else $r end)}'
  exit 0
}

case "$MODEL" in
  (off|none|null) out off null "" null "benchmark_judge is off";;
  (auto) out failed null "" null "benchmark_judge is auto and no judge is pinned yet: pick one (docs/benchmark.md → Choosing the judge)";;
esac
harness_ready
[ -n "$JH" ] || out unavailable null "" null "$WHY"
# a short or differently prefixed name calls the exact id the host serves
IDS="$(served_models "$JH")"
if [ -n "$IDS" ]; then
  M="$(pick_model "$MODEL" "$IDS")"
  [ -n "$M" ] || { not_served "$MODEL"; out unavailable null "" null "$WHY"; }
  MODEL="$M"
fi
[ -r "$BRIEF" ] || out failed null "" null "judge brief missing: $BRIEF"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cg-judge.XXXXXX")" || out failed null "" null "cannot create a temp dir"
trap 'rm -rf "$TMP"' EXIT

if [ "$KIND" = rereview ]; then
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
# claude -p also sends a long input to its small fast model (Haiku), which then
# shows up in modelUsage and makes the reply a mismatch: point that model at
# the judge too, so the pinned model is the only one that answers
run_claude() {
  ( cd "$TMP" && ANTHROPIC_DEFAULT_HAIKU_MODEL="$MODEL" ANTHROPIC_SMALL_FAST_MODEL="$MODEL" \
      ${TO[@]+"${TO[@]}"} "$CLI" -p --model "$MODEL" --output-format json \
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
# `fp_class` holds when it classifies every scorer fp (matched on file and
# line) with a known class; else it is null and the dimensions still count
FPS="$(jq -c '.fp // [] | if type == "array" then . else [] end' "$SCORER" 2>/dev/null)"
SCORES="$(jq -c --argjson dims "$DIMS" --argjson fps "${FPS:-[]}" '
  (.result // "" | tostring) as $t
  | ($t | try fromjson catch
      ($t | explode | (index(123)) as $a | (rindex(125)) as $b
          | if $a == null or $b == null then null else (.[$a:$b + 1] | implode | try fromjson catch null) end)) as $o
  | ($o.fp_class? | if type == "array" then [ .[] | objects
      | select((.class | IN("real", "defensible", "fabricated")) and (.file | type) == "string") ] else [] end) as $c
  | ([ $fps[] | . as $f
       | ([ $c[] | select(.file == $f.file and (.line | tostring) == ($f.line | tostring)) ][0]) as $m
       | if $m == null then null else {file: $f.file, line: $f.line, class: $m.class} end ]) as $fpc
  | if ($o | type) != "object" then null
    elif all($dims[]; . as $k | $o[$k] | type == "number" and . == floor and . >= 1 and . <= 5)
    then ($o | with_entries(select(.key as $k | $dims | index($k)))) + {notes: ($o.notes // "" | tostring),
           fp_class: (if ($fps | length) == 0 then []
                     elif ($o.fp_class | type) == "array" and all($fpc[]; . != null) then $fpc else null end)}
    else null end' "$TMP/reply.json" 2>/dev/null)"
[ -n "$SCORES" ] && [ "$SCORES" != null ] \
  || out failed null "$USED" "$TOKENS" "judge reply is not the score object: $(jq -r '.result // "" | tostring | .[0:200]' "$TMP/reply.json")"

out ok "$SCORES" "$USED" "$TOKENS" ""
