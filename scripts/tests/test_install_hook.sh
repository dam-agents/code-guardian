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

assert_settings() { # <jq-filter> <description>
  if jq -e "$1" "$FAKE_HOME/.claude/settings.json" >/dev/null 2>&1; then
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
assert_settings '.autoMode.allow | any(startswith("[code-guardian]") and contains("gh issue create") and contains("acme/guardian"))' 'tracking-issue rule names the definition repo'
assert_settings '.autoMode.allow | any(startswith("[code-guardian]") and contains("curl -X PUT"))' 'artifact upload rule present'
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
assert_settings '[.autoMode.allow[] | select(startswith("[code-guardian]"))] | length == 2 and all(contains("acme/guardian2") or contains("curl"))' 'changed definition_repo replaces own rules'
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
assert_settings '.autoMode.allow | all(contains("gh issue create") | not)' 'no tracking-issue rule without a slug'

exit "$FAILED"
