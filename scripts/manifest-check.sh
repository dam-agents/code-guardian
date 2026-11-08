#!/usr/bin/env bash
# manifest-check.sh — checks an agent manifest (docs/manifest.md) before it is
# published, and a peer's manifest before the agent relies on it.
#
# The agent writes the manifest; this script only reports. It never edits the
# card except in `stamp` mode, which writes source.version and nothing else.
#
#   check   <card.json>   own card: shape, references, version, privacy and
#                         credential scan
#   publish <card.json>   as check, plus: no `<placeholder>` left, version stamped
#   stamp   <card.json>   write source.version = digest of the card without
#                         source and runtime; prints the digest
#   peer    <card.json>   a peer's card: shape, references and version digest
#   digest  <card.json>   print the digest, change nothing
#
#   ok   <check> — <detail>
#   warn <check> — <detail>
#   FAIL <check> — <problem> — fix: <instruction>
#
# Exit 0 iff nothing FAILed. Needs bash and jq; with python3 + jsonschema
# present it also runs the full JSON Schema.

set -u
export LC_ALL=C

HOME_DIR="${AGENT_HOME:-$HOME}"
SCHEMA="${MANIFEST_SCHEMA:-$HOME_DIR/docs/manifest.schema.json}"
CONFIG="${WORK_DIR:-$HOME_DIR/work}/CONFIG.md"
ROSTER="${WORK_DIR:-$HOME_DIR/work}/DEVELOPERS.md"
SPEC="dam-agent-manifest/1"
# Config keys whose values may appear in the public card (labels, the bot
# account, the public definition repo). Every other CONFIG.md value is private,
# the target repo (`github_repo`) included: it can be a private repository.
# The list belongs to the definition: a change to it is a definition change
# (docs/self-modification.md), never an instance edit. MANIFEST_PUBLIC_KEYS
# replaces it for one run of the test suite.
PUBLIC_KEYS="${MANIFEST_PUBLIC_KEYS:-bot_display_name bot_login definition_repo definition_branch review_marker rereview_label rereview_delta_label urgent_label guide_label}"

mode="${1:-}"; card="${2:-}"
case "$mode" in (check|publish|stamp|peer|digest) ;; (*) echo "usage: $0 check|publish|stamp|peer|digest <card.json>" >&2; exit 2;; esac
[ -r "$card" ] || { echo "FAIL card — $card not readable — fix: write the card first (docs/manifest.md)"; exit 1; }
jq -e . "$card" >/dev/null 2>&1 || { echo "FAIL json — $card is not valid JSON — fix: rewrite it as one JSON object"; exit 1; }

sha() { if command -v sha256sum >/dev/null; then sha256sum; else shasum -a 256; fi; }
digest() { jq -S -c 'del(.source, .runtime)' "$card" | sha | cut -c1-12 | sed 's/^/sha256:/'; }

if [ "$mode" = digest ]; then digest; exit 0; fi
if [ "$mode" = stamp ]; then
  d="$(digest)"; tmp="$(mktemp)"
  jq --arg d "$d" '.source.version = $d' "$card" > "$tmp" && mv "$tmp" "$card"
  echo "$d"; exit 0
fi

fails=0
ok()   { echo "ok   $1 — $2"; }
warn() { echo "warn $1 — $2"; }
fail() { echo "FAIL $1 — $2 — fix: $3"; fails=$((fails + 1)); }
each() { jq -r "$1" "$card"; }

# 1. Shape: the parts of the schema that a reader depends on.
[ "$(each '.manifest')" = "$SPEC" ] && ok spec "$SPEC" \
  || fail spec "manifest is $(each '.manifest'), expected $SPEC" "set .manifest to \"$SPEC\" and follow docs/manifest.schema.json"
for k in readme agent source surfaces triggers skills trust; do
  jq -e --arg k "$k" 'has($k)' "$card" >/dev/null || fail "key-$k" "required key $k is missing" "add $k (docs/manifest.md → Sections)"
done
if extra="$(jq -r --slurpfile s "$SCHEMA" 'keys - ($s[0].properties | keys) | .[]' "$card" 2>/dev/null)"; then
  [ -z "$extra" ] && ok keys "no unknown top-level key" \
    || fail keys "unknown top-level keys: $(echo $extra)" "remove them or move their content into an existing section"
else
  warn keys "$SCHEMA not readable or not a schema; unknown-key check skipped"
fi
jq -e '(.readme | type == "string") and (.readme | length > 80)' "$card" >/dev/null \
  || fail readme "readme is missing or shorter than one paragraph" "write one paragraph for a reader that does not know this format"
jq -e '.agent | (.name and .description and .version) and ((.roles // []) | length > 0)' "$card" >/dev/null \
  || fail agent "agent needs name, description, version and at least one role" "fill .agent from the definition"
bad_ids="$(each '[(.triggers, .skills, .contracts) // {} | keys[] | select(test("^[a-z0-9]+(-[a-z0-9]+)*$") | not)] | join(" ")')"
[ -z "$bad_ids" ] || fail ids "keys not kebab-case: $bad_ids" "rename them and every reference to them"
nodesc="$(each '[.triggers // {} | to_entries[] | select((.value.description // "") == "") | .key] | join(" ")')"
[ -z "$nodesc" ] || fail trigger-description "triggers without description: $nodesc" "say in one or two sentences when to use it and what happens"
noway="$(each '[.skills // {} | to_entries[] | select((.value.triggers // [] | length) == 0 and (.value.schedule // "") == "") | .key] | join(" ")')"
[ -z "$noway" ] || fail skill-start "skills with neither triggers nor schedule: $noway" "add the trigger that starts it or its schedule"
timers="$(each '[.triggers // {} | to_entries[] | select(.value.type == "schedule" or (.value.value // "" | test("^[-0-9*/,]+( +[-0-9*/,]+){4}$"))) | .key] | join(" ")')"
[ -z "$timers" ] || fail timer-trigger "triggers that are timers: $timers" "a timer is not a trigger: remove it and write the skill's schedule in words (every hour at minute 7)"
crons="$(each '[.skills // {} | to_entries[] | select(.value.schedule // "" | test("^[-0-9*/,]+( +[-0-9*/,]+){4}$")) | .key] | join(" ")')"
[ -z "$crons" ] || fail schedule-words "skills with a cron expression as schedule: $crons" "say the schedule in words (Fridays at 07:00 UTC)"

# Unknown keys inside the sections readers parse, without the full schema pass.
nested="$(jq -r --slurpfile s "$SCHEMA" '
  $s[0].properties as $p
  | [ ((.triggers // {}) | to_entries[] | "triggers.\(.key)" as $w | .value | keys - ($p.triggers.additionalProperties.properties | keys) | .[] | "\($w).\(.)"),
      ((.skills // {}) | to_entries[] | "skills.\(.key)" as $w | .value | keys - ($p.skills.additionalProperties.properties | keys) | .[] | "\($w).\(.)"),
      ((.contracts // {}) | to_entries[] | "contracts.\(.key)" as $w | .value | keys - ($p.contracts.additionalProperties.properties | keys) | .[] | "\($w).\(.)"),
      ((.surfaces // {}) | to_entries[] | "surfaces.\(.key)" as $w | .value
        | (keys - ($p.surfaces.additionalProperties.properties | keys) | .[] | "\($w).\(.)"),
          ((.channels // [])[] | keys - ($p.surfaces.additionalProperties.properties.channels.items.properties | keys) | .[] | "\($w).channels[].\(.)"),
          ((.pages // [])[] | keys - ($p.surfaces.additionalProperties.properties.pages.items.properties | keys) | .[] | "\($w).pages[].\(.)")),
      ((.runtime.providers // [])[] | keys - ($p.runtime.properties.providers.items.properties | keys) | .[] | "runtime.providers[].\(.)")
    ] | unique | join(" ")' "$card" 2>/dev/null)"
[ -z "$nested" ] || fail nested-keys "keys the schema does not know: $nested" "remove them; a value that belongs in the card has a field in docs/manifest.schema.json"

rt="$(each '.runtime // {} | keys - ["harness", "providers", "listedAt"] | join(" ")')"
[ -z "$rt" ] || fail runtime "runtime carries $rt" "keep only harness, providers and listedAt: the card says what the agent can use, never how it is used"

# 2. References: every name in a list points at an entry of this card.
refs="$(jq -r '
  (.triggers // {}) as $t | (.skills // {}) as $s | (.contracts // {}) as $k | (.surfaces // {}) as $f
  | [ ($t | to_entries[] | .key as $id | .value.starts as $sk | .value.surface as $sf
        | (if ($s | has($sk)) then empty else "trigger \($id) starts unknown skill \($sk)" end),
          (if ($f | has($sf)) then empty else "trigger \($id) names unknown surface \($sf)" end)),
      ($s | to_entries[] | .key as $n | .value as $v
        | ((($v.triggers // [])[]) as $tr
            | if ($t | has($tr)) | not then "skill \($n) names unknown trigger \($tr)"
              elif $t[$tr].starts != $n then "skill \($n) lists trigger \($tr) that starts \($t[$tr].starts)"
              else empty end),
          ((($v.reads // []) + ($v.writes // []))[] as $c
            | if ($k | has($c)) then empty else "skill \($n) names unknown contract \($c)" end)),
      ((.handoffs // [])[] | .via as $v | .direction as $d
        | if (if $d == "in" then ($t | has($v)) else ($k | has($v)) end) then empty else "handoff \($d) via unknown \($v)" end),
      ([$s[] | (.reads // []) + (.writes // []) | .[]] as $used
        | $k | keys[] | . as $id | if ($used | index($id)) then empty else "contract \($id) is not read or written by any skill" end),
      ((($f.artifact // {}).pages // [])[] | .name as $pn | .contract as $pc
        | if $pc == null or ($k | has($pc)) then empty else "page \($pn) names unknown contract \($pc)" end)
    ] | .[]' "$card" 2>&1)" || refs="jq could not read the card: $refs"
if [ -z "$refs" ]; then ok references "every trigger, skill and contract reference resolves"
else while IFS= read -r r; do fail references "$r" "fix the name or add the entry"; done <<< "$refs"; fi

# Optional full schema pass: `ok` only when the validator ran and found nothing.
if [ ! -r "$SCHEMA" ]; then
  warn schema "$SCHEMA not readable; full JSON Schema pass skipped"
elif ! python3 -I -c 'import jsonschema' 2>/dev/null; then
  warn schema "full JSON Schema pass skipped (python3 -I cannot import jsonschema); shape checks above still ran"
else
  out="$(python3 -I -c '
import json, sys, jsonschema
s = json.load(open(sys.argv[1])); c = json.load(open(sys.argv[2]))
v = jsonschema.Draft202012Validator(s, format_checker=jsonschema.Draft202012Validator.FORMAT_CHECKER)
errs = list(v.iter_errors(c))
for e in errs: print("/".join(map(str, e.path)) or "(root)", "—", e.message)
sys.exit(3 if errs else 0)' "$SCHEMA" "$card" 2>&1)"; rc=$?
  case "$rc" in
    (0) ok schema "valid against $(basename "$SCHEMA")";;
    (3) while IFS= read -r r; do fail schema "$r" "match docs/manifest.schema.json"; done <<< "$out";;
    (*) warn schema "validator did not run: $(printf '%s\n' "$out" | tail -1)";;
  esac
fi

# 3. Version: source.version is the digest of what readers use.
d="$(digest)"; v="$(each '.source.version // ""')"
[ "$v" = "$d" ] && ok version "$v" \
  || if [ "$mode" = peer ]; then
       fail version "source.version is ${v:-empty}, content digest is $d: the card changed after it was stamped" "do not pin this copy; tell the operator and the peer's owner"
     else fail version "source.version is ${v:-empty}, content digest is $d" "run: bash scripts/manifest-check.sh stamp <card>"; fi

size="$(wc -c < "$card")"
if [ "$size" -le 32768 ]; then ok size "$size bytes"
elif [ "$mode" = peer ]; then fail size "$size bytes" "do not pin a card over 32 KB; tell the operator"
else warn size "$size bytes; keep the card under 32 KB"; fi

[ "$mode" = peer ] && { [ "$fails" -eq 0 ] && echo PASS; exit $(( fails > 0 )); }

# 4. Privacy: no private config value and no private shape in the card.
if [ ! -r "$CONFIG" ] && [ "$mode" = publish ]; then
  fail privacy-config "$CONFIG not readable; the card cannot be published unscanned" "run from the agent's home, or set WORK_DIR to the directory that holds CONFIG.md"
elif [ -r "$CONFIG" ]; then
  leaks=""
  while IFS= read -r line; do
    key="${line%%:*}"; key="${key#- }"; val="${line#*: }"; val="${val%%  #*}"; val="${val//\`/}"
    case " $PUBLIC_KEYS " in (*" $key "*) continue;; esac
    case "$key" in (*_*) grep -qwF -- "$key" "$card" && leaks="$leaks $key";; esac
    for part in $(echo "$val" | tr ',' ' '); do
      [ "${#part}" -ge 4 ] || continue
      case "$part" in (enabled|disabled|true|false|none|off|on|dam|both|label|chat) continue;; esac
      grep -qwF -- "$part" "$card" && leaks="$leaks $key"
    done
  done < <(grep -E '^- [a-z_]+:' "$CONFIG")
  leaks="$(echo $leaks | tr ' ' '\n' | sort -u | tr '\n' ' ')"
  [ -z "${leaks// /}" ] && ok privacy-config "no private CONFIG.md key or value in the card" \
    || fail privacy-config "private config keys or their values appear: $leaks" "remove them, or add the key to PUBLIC_KEYS only when the design marks it public"
else
  warn privacy-config "$CONFIG not readable; config scan skipped"
fi
shapes="$( (grep -oE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[a-z]{2,}|/home/agent/work/[^" ]*' "$card"; sed 's/^/ /' "$card" | grep -oE '[^A-Za-z0-9_./-]((\$HOME|~|\$\{HOME\})/)?work/[^" ]*' | cut -c2-; grep -oE '\b[UWCGD][A-Z0-9]{8,11}\b' "$card" | grep '[0-9]') | sort -u | head -5)"
[ -z "$shapes" ] && ok privacy-shapes "no e-mail, Slack id or work/ path" \
  || fail privacy-shapes "private shapes in the card: $(echo $shapes)" "replace with names or remove (docs/manifest.md → What stays out)"

# People and private conversations: a roster login anywhere in the card, an
# owner that is one word and no role id (it reads as a login), and a numeric
# chat id (Telegram) as a conversation name or anywhere as a supergroup id.
# The roster is read through roster_tsv (scripts/lib/common.sh), which knows
# both documented forms: table rows and `login:`/`slack_id:` bullet pairs.
# A roster that exists is read or the check fails: an unreadable file, a
# dangling symlink, a missing common.sh and a roster with no login all fail
# closed. Presence is the directory entry (-e or -L): -e alone follows a link.
people=""; roster_fail=""; roster_present=""
{ [ -e "$ROSTER" ] || [ -L "$ROSTER" ]; } && roster_present=1
if [ -n "$roster_present" ] && [ ! -r "$ROSTER" ]; then
  roster_fail=1; fail privacy-people "the roster cannot be read ($ROSTER)" "fix its permissions or the link target, so the card is scanned"
elif [ -r "$ROSTER" ]; then
  COMMON_LIB="$(dirname "$0")/lib/common.sh"
  if [ -r "$COMMON_LIB" ] && . "$COMMON_LIB" 2>/dev/null && type roster_tsv >/dev/null 2>&1; then
    logins="$(roster_tsv "$ROSTER" | cut -f1 | sort -u)"
    if [ -z "$logins" ]; then
      roster_fail=1; fail privacy-people "the roster holds no login ($ROSTER)" "write it in a documented form (ONBOARDING.md → Build the developer roster), or remove the empty file"
    fi
    while IFS= read -r login; do
      [ -n "$login" ] && grep -qiwF -- "$login" "$card" && people="$people $login"
    done <<< "$logins"
  else
    roster_fail=1; fail privacy-people "the roster could not be read ($COMMON_LIB)" "run the check from the agent's home, where scripts/lib/common.sh is readable"
  fi
fi
owner="$(each '.agent.owner // ""')"
case "$owner" in
  (""|*" "*|operator|code-reviewer|implementer|qa-tester|quality-advisor|reporter) ;;
  (*) people="$people owner=$owner";;
esac
chats="$( (each '[.surfaces // {} | .[] | (.channels // [])[] | .name // "" | select(test("^-?[0-9]{5,}$"))] | .[]'; grep -oE '(^|[^0-9])-100[0-9]{10}([^0-9]|$)' "$card" | tr -cd '0-9-\n' | grep -oE -- '-100[0-9]{10}') | sort -u | head -5)"
people="$(echo $people $chats)"
scope="roster login"; [ -n "$roster_present" ] || scope="roster login (no roster: logins checked against CONFIG.md only)"
if [ -n "$people" ]; then
  fail privacy-people "a person or a private conversation in the card: $people" "name a role or the conversation's name instead (docs/manifest.md → What stays out)"
elif [ -z "$roster_fail" ]; then
  ok privacy-people "no $scope, person owner or numeric chat id"
fi

# Credentials: every shape scripts/lib/redact.sh masks, on a copy of the card.
# The card is refused, never masked: a masked card would publish a broken value
# under a new version. The pass fails closed.
REDACT_LIB="$(dirname "$0")/lib/redact.sh"
cred_copy="$(mktemp)"; cp "$card" "$cred_copy"
if [ -r "$REDACT_LIB" ] && . "$REDACT_LIB" && n="$(redact_file "$cred_copy")"; then
  [ "$n" -eq 0 ] && ok privacy-credentials "no credential shape (scripts/lib/redact.sh)" \
    || fail privacy-credentials "$n credential values in the card" "remove them; a credential never goes in the card (docs/manifest.md → What stays out)"
else
  fail privacy-credentials "the redaction pass did not run ($REDACT_LIB)" "run the check from the agent's home, where scripts/lib/redact.sh is readable"
fi
rm -f "$cred_copy"

# 5. Publish gate.
if [ "$mode" = publish ]; then
  ph="$(grep -c 'TODO(manifest)' "$card")"
  [ "$ph" -eq 0 ] && ok placeholders "none" || fail placeholders "$ph unfilled TODO(manifest) values" "fill them from the runtime sources (docs/manifest.md → Sources) or remove the field"
fi

[ "$fails" -eq 0 ] && echo PASS
exit $(( fails > 0 ))
