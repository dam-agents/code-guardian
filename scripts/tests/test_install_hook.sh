#!/usr/bin/env bash
# Harness adapter install (scripts/harness/claude-code/install.sh): the
# [code-guardian] auto-mode rules in ~/.claude/settings.json.
# Contract: docs/logging.md → Harness adapters.
. "$(dirname "$0")/helpers.sh"

INSTALL="$REPO_ROOT/scripts/harness/claude-code/install.sh"

# run install.sh against the fake HOME; stdout lands in $OUT
run_install() {
  OUT="$(HOME="$FAKE_HOME" CLAUDECODE=1 bash "$INSTALL" 2>>"$STDERR_LOG")"
}

assert_settings() { # <jq-filter, $d = the deny list> <description>
  if jq -e --argjson d "${DENY_JSON:-[]}" "$1" "$FAKE_HOME/.claude/settings.json" >/dev/null 2>&1; then
    printf 'ok   %s: %s\n' "$CASE" "$2"
  else
    printf 'FAIL %s: %s\n     autoMode: %s\n' "$CASE" "$2" \
      "$(jq -c .autoMode "$FAKE_HOME/.claude/settings.json" 2>&1 | cut -c1-300)"
    FAILED=1
  fi
}

assert_out() { # <substring> <description>
  case "$OUT" in
    (*"$1"*) printf 'ok   %s: %s\n' "$CASE" "$2";;
    (*) printf 'FAIL %s: %s (want "%s")\n     out: %s\n' "$CASE" "$2" "$1" "$OUT"; FAILED=1;;
  esac
}

install_case() { # <case-name> [config lines…]
  new_case "$1"; shift
  mkdir -p "$FAKE_HOME/work"
  for l in "$@"; do printf -- '%s\n' "$l"; done > "$FAKE_HOME/work/CONFIG.md"
}

# --- fresh settings: built-in rules kept, both slugs from CONFIG.md -------------
install_case fresh '- github_repo: acme/widgets' '- definition_repo: `acme/guardian` # def'
run_install
assert_settings '.autoMode.environment[0] == "$defaults" and .autoMode.allow[0] == "$defaults"' 'new lists start with $defaults'
assert_settings '.autoMode.environment | any(startswith("[code-guardian]") and contains("acme/widgets") and contains("acme/guardian"))' 'environment names target and definition repo'
assert_settings '.autoMode.allow | any(startswith("[code-guardian]") and contains("definition-issue.sh file") and contains("acme/guardian"))' 'tracking-issue rule names the definition repo'
assert_settings '.autoMode.allow | any(startswith("[code-guardian]") and contains("curl -X PUT"))' 'artifact upload rule present'
assert_settings '.autoMode.allow | any(startswith("[code-guardian]") and contains("schedule_once") and contains("scripts/dispatch.sh plan"))' 'review dispatch rule present'
assert_settings '[.hooks.Stop[]?.hooks[]?.command] | any(endswith("enforce-review-completion.sh"))' 'hooks still registered'
run_install
assert_out "already installed" 'second run is a no-op'

# --- operator entries stay, own entries are replaced -----------------------------
install_case operator_kept '- github_repo: acme/widgets' '- definition_repo: acme/guardian'
mkdir -p "$FAKE_HOME/.claude"
echo '{"theme":"dark","autoMode":{"allow":["operator rule"]}}' > "$FAKE_HOME/.claude/settings.json"
run_install
assert_settings '.autoMode.allow[0] == "operator rule" and (.autoMode.allow | index("$defaults") | not)' 'operator list kept as written, no $defaults added'
assert_settings '.theme == "dark"' 'other keys stay'
printf -- '- github_repo: acme/widgets\n- definition_repo: acme/guardian2\n' > "$FAKE_HOME/work/CONFIG.md"
run_install
assert_settings '[.autoMode.allow[] | select(startswith("[code-guardian]"))] | length == 3 and all(contains("acme/guardian2") or contains("curl") or contains("schedule_once"))' 'changed definition_repo replaces own rules'
assert_settings '[.autoMode.environment[] | select(startswith("[code-guardian]"))] | length == 2' 'environment rules not duplicated'

# --- no CONFIG.md yet: definition repo from $HOME's origin ------------------------
install_case origin_fallback
rm -f "$FAKE_HOME/work/CONFIG.md"
git -C "$FAKE_HOME" init -q && git -C "$FAKE_HOME" remote add origin "https://x-access-token:secret@github.com/acme/guardian.git"
run_install
assert_settings '.autoMode.allow | any(startswith("[code-guardian]") and contains("on acme/guardian with"))' 'definition repo from origin, host stripped'
assert_settings '[.autoMode[][]] | all(contains("secret") | not)' 'no credential from the origin URL'

# --- definition repo unresolved: tracking-issue rule left out ---------------------
install_case unresolved
run_install
assert_out "definition repo unresolved" 'unresolved definition repo is reported'
assert_settings '.autoMode.allow | all(contains("definition-issue.sh") | not)' 'no tracking-issue rule without a slug'

# --- tool deny list and the review-skill agent --------------------------------------
ADAPTER="$REPO_ROOT/scripts/harness/claude-code"
DENY_JSON="$(sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//' "$ADAPTER/denied-tools.txt" \
  | jq -Rsc 'split("\n") | map(select(length > 0))')"
agent() { printf "%s" "$FAKE_HOME/.claude/agents/review-skill.md"; }
run_check() { OUT="$(HOME="$FAKE_HOME" CLAUDECODE=1 bash "$INSTALL" --check 2>>"$STDERR_LOG")"; }

install_case trim_fresh '- github_repo: acme/widgets'
mkdir -p "$FAKE_HOME/.claude"
echo '{"permissions":{"defaultMode":"auto","deny":["Bash(rm -rf *)"]}}' > "$FAKE_HOME/.claude/settings.json"
run_check
assert_out "tool-deny skill-agent" '--check names both parts before the install'
run_install
assert_settings '.permissions.deny == ["Bash(rm -rf *)"] + $d' 'deny list appended after the operator entry'
assert_settings '.permissions.defaultMode == "auto"' 'other permission keys stay'
if cmp -s "$ADAPTER/agents/review-skill.md" "$(agent)"; then printf 'ok   %s: review-skill agent installed\n' "$CASE"
else printf 'FAIL %s: review-skill agent missing or different\n' "$CASE"; FAILED=1; fi
run_check
if [ -z "$OUT" ]; then printf 'ok   %s: --check prints nothing once installed\n' "$CASE"
else printf 'FAIL %s: --check after install printed "%s"\n' "$CASE" "$OUT"; FAILED=1; fi
run_install
assert_out "already installed" 'second run is a no-op'
assert_settings '[.permissions.deny[] | select(. as $x | $d | index([$x]))] | length == ($d | length)' 'no duplicate deny entries'

# a name dropped from denied-tools.txt leaves settings.json; a stale agent is replaced
echo '["mcp__platform-outbound__gone_tool"]' > "$FAKE_HOME/.claude/.code-guardian-denied-tools.json"
jq '.permissions.deny += ["mcp__platform-outbound__gone_tool"]' "$FAKE_HOME/.claude/settings.json" > "$SANDBOX/s.json" \
  && mv "$SANDBOX/s.json" "$FAKE_HOME/.claude/settings.json"
echo "stale" >> "$(agent)"
run_install
assert_settings '.permissions.deny | index("mcp__platform-outbound__gone_tool") | not' 'a dropped name is removed'
assert_settings '.permissions.deny[0] == "Bash(rm -rf *)"' 'the operator entry stays'
if cmp -s "$ADAPTER/agents/review-skill.md" "$(agent)"; then printf 'ok   %s: stale agent replaced\n' "$CASE"
else printf 'FAIL %s: stale agent not replaced\n' "$CASE"; FAILED=1; fi

# another harness: nothing written, --check silent
install_case trim_other_harness
OUT="$(HOME="$FAKE_HOME" CLAUDECODE=0 bash "$INSTALL" 2>>"$STDERR_LOG")"
assert_out "not the Claude Code harness" 'other harness prints the notice'
if [ ! -e "$FAKE_HOME/.claude/settings.json" ] && [ ! -e "$(agent)" ]; then
  printf 'ok   %s: nothing written on another harness\n' "$CASE"
else printf 'FAIL %s: files written on another harness\n' "$CASE"; FAILED=1; fi
OUT="$(HOME="$FAKE_HOME" CLAUDECODE=0 bash "$INSTALL" --check 2>>"$STDERR_LOG")"
if [ -z "$OUT" ]; then printf 'ok   %s: --check silent on another harness\n' "$CASE"
else printf 'FAIL %s: --check printed "%s" on another harness\n' "$CASE" "$OUT"; FAILED=1; fi

# --- no procedure names a denied tool --------------------------------------------------
# the deny list removes a tool from every session: a doc that calls one would
# fail on a deployed instance
new_case trim_unused_only
DOCS=("$REPO_ROOT/CLAUDE.md" "$REPO_ROOT/AGENTS.md" "$REPO_ROOT/ONBOARDING.md" "$REPO_ROOT/README.md"
      "$REPO_ROOT"/docs/*.md "$REPO_ROOT"/scripts/templates/* "$REPO_ROOT"/.agents/skills/*/SKILL.md)
names_tool() { # <tool> — true when a doc names it
  local pat
  case "$1" in
    mcp__*) pat="(^|[^A-Za-z0-9_]|__)${1##*__}([^A-Za-z0-9_]|\$)" ;;
    *) pat="\`${1}\`|${1} tool|${1}\\(" ;;
  esac
  grep -lE "$pat" "${DOCS[@]}" >/dev/null 2>&1
}
if names_tool mcp__platform-outbound__create_artifact_upload_url && names_tool Skill; then
  printf 'ok   %s: the scan finds tools the procedures do name\n' "$CASE"
else printf 'FAIL %s: the scan misses named tools — the guard below proves nothing\n' "$CASE"; FAILED=1; fi
named=""
for t in $(printf '%s' "$DENY_JSON" | jq -r '.[]'); do names_tool "$t" && named="$named $t"; done
if [ -z "$named" ]; then printf 'ok   %s: no doc names a denied tool\n' "$CASE"
else printf 'FAIL %s: denied tools named by a procedure:%s\n' "$CASE" "$named"; FAILED=1; fi

# --- the platform's prompts keep their tools ---------------------------------------
# a Kit Update prompt (DAM kit-update-prompt.ts) calls these; no doc names them,
# so the scan above cannot protect them
new_case trim_platform_tools
PLATFORM_TOOLS=(list_schedules create_schedule report_kit_updated cancel_kit_update)
grep -qE '^skills:' "$REPO_ROOT/kit.yaml" && PLATFORM_TOOLS+=(install_skill)
denied=""
for t in "${PLATFORM_TOOLS[@]}"; do
  printf '%s' "$DENY_JSON" | jq -e --arg t "mcp__platform-outbound__$t" 'index($t)' >/dev/null && denied="$denied $t"
done
if [ -z "$denied" ]; then printf 'ok   %s: the Kit Update tools stay available\n' "$CASE"
else printf 'FAIL %s: denied tools a platform prompt calls:%s\n' "$CASE" "$denied"; FAILED=1; fi

exit "$FAILED"
