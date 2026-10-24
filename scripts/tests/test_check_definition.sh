#!/usr/bin/env bash
# .agents/skills/agent-engineering/scripts/check-definition.sh — the
# deterministic checks of the agent-engineering skill, run against small agent
# definition repositories built in a sandbox. A whole-tree run reports every
# finding; a run with --base reports only what the change adds; the script runs
# with no awk on PATH, as on the pod.
. "$(dirname "$0")/helpers.sh"

CHECK="$REPO_ROOT/.agents/skills/agent-engineering/scripts/check-definition.sh"

g() { git -C "$DEF" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false "$@"; }

# a minimal clean definition, committed on main
new_def() { # <case-name>
  new_case "$1"
  DEF="$SANDBOX/def"
  mkdir -p "$DEF/docs" "$DEF/scripts"
  git init -q -b main "$DEF"
  printf '# Agent\n\nRead [the runbook](docs/runbook.md) first.\n' > "$DEF/CLAUDE.md"
  printf '# Runbook\n\n## Review run\n\n**Steps.** Run `scripts/gate.sh check`.\n' > "$DEF/docs/runbook.md"
  printf '#!/usr/bin/env bash\ncase "$1" in\n  check) echo ok ;;\nesac\n' > "$DEF/scripts/gate.sh"
  chmod +x "$DEF/scripts/gate.sh"
  printf '1.0.0\n' > "$DEF/VERSION"
  printf '# Changelog\n\n## 1.0.0 — 2026-01-01\n\n**Upgrade:** Nothing.\n' > "$DEF/CHANGELOG.md"
  g add -A >/dev/null && g commit -qm init
}

check() { # [--base main] — run with no awk on PATH; $OUT holds the output
  mkdir -p "$SANDBOX/noawk"
  printf '#!/bin/sh\necho "awk is not on this runtime" >&2\nexit 127\n' > "$SANDBOX/noawk/awk"
  chmod +x "$SANDBOX/noawk/awk"
  OUT="$(PATH="$SANDBOX/noawk:$PATH" bash "$CHECK" "$@" "$DEF" 2>"$STDERR_LOG")"
  RC=$?
}

has()  { assert_out_contains "$1" "$2"; }
lacks() { assert_out_absent "$1" "$2"; }

new_def clean_tree
check
assert_rc 0 "a clean definition passes"
has '0 fail, 0 warn' "a clean definition has no finding"
lacks 'awk is not on this runtime' "the script never calls awk"

new_def missing_tool
# every tool the script runs on PATH except xargs, which a runtime without
# findutils lacks
mkdir -p "$SANDBOX/bin"
for c in git jq grep sed find sort uniq cut tr head tail wc cmp mktemp basename dirname tar; do
  ln -s "$(command -v "$c")" "$SANDBOX/bin/$c"
done
OUT="$(PATH="$SANDBOX/bin" "$BASH" "$CHECK" "$DEF" 2>&1)"; RC=$?
assert_rc 2 "a missing tool stops the run before any check"
has 'missing command: xargs' "the missing tool is named"

new_def broken_references
printf '\nSee [gone](docs/gone.md), [here](docs/runbook.md#no-such) and docs/runbook.md → **Audit run**.\nRun `scripts/missing.sh`.\n' >> "$DEF/CLAUDE.md"
check
assert_rc 1 "a broken reference fails the run"
has 'FAIL	links	CLAUDE.md:5	dead link: docs/gone.md' "a dead link"
has 'FAIL	anchors	CLAUDE.md:5' "an anchor with no heading"
has "FAIL	section-refs	CLAUDE.md	no section 'Audit run'" "a prose section reference"
has 'WARN	paths	CLAUDE.md:6.*scripts/missing.sh' "a backticked path that does not exist"

new_def known_findings_stay_out_of_a_change
printf '\n[old](docs/old.md)\n' >> "$DEF/CLAUDE.md"
g commit -qam "pre-existing dead link"
g checkout -qb change
printf '\nA new line.\n' >> "$DEF/docs/runbook.md"
printf '1.0.1\n' > "$DEF/VERSION"
printf '# Changelog\n\n## 1.0.1 — 2026-01-02\n\n**Upgrade:** Nothing.\n\n## 1.0.0 — 2026-01-01\n\n**Upgrade:** Nothing.\n' > "$DEF/CHANGELOG.md"
g commit -qam change
check --base main
assert_rc 0 "a change that adds no defect passes"
lacks 'links' "a dead link that the base already has is not the change's"

new_def release_discipline
g checkout -qb change
printf '\nA new rule.\n' >> "$DEF/docs/runbook.md"
printf '# Changelog\n\n## 1.0.0 — 2026-01-01\n\n**Upgrade:** Edited.\n' > "$DEF/CHANGELOG.md"
g commit -qam change
check --base main
has 'WARN	version-bump	VERSION	the definition changed but VERSION stays 1.0.0' "a change with no version bump"
has 'FAIL	changelog	CHANGELOG.md	an entry released on the base was edited' "an edited released entry"

new_def version_skips_a_step
g checkout -qb change
printf '1.2.0\n' > "$DEF/VERSION"
printf '# Changelog\n\n## 1.2.0 — 2026-01-02\n\nNo block.\n\n## 1.0.0 — 2026-01-01\n\n**Upgrade:** Nothing.\n' > "$DEF/CHANGELOG.md"
g commit -qam change
check --base main
has 'FAIL	version-bump	VERSION	1.0.0 -> 1.2.0 is not one step' "a skipped version"
has 'WARN	changelog	CHANGELOG.md	the new entry has no \*\*Upgrade:\*\* block' "an entry without the convention of the released ones"

new_def added_lines
g checkout -qb change
cat >> "$DEF/scripts/gate.sh" <<'EOF'
if mkdir "$LOCK_DIR"; then :; fi
body="$(gh api repos/x/y/pulls)"; jq -n --argjson b "$(gh api repos/x/y/pulls)" .
git clean -fdx
n="$(gh api repos/x/y/issues 2>/dev/null || echo 0)"
EOF
printf 'token=%s%s\n' 'ghp_' 'abcdefghijklmnopqrstuvwxyz0123456789' >> "$DEF/scripts/gate.sh"
printf '\nAsk alice@acme.io in U07QWERT12 from /Users/alice/agent/.\n' >> "$DEF/docs/runbook.md"
g commit -qam change
check --base main
has 'WARN	shell	scripts/gate.sh:5	mkdir as a lock' "a mkdir lock"
has 'WARN	shell	scripts/gate.sh:6	command output passed in argv' "a payload in argv"
has 'FAIL	shell	scripts/gate.sh:7	git clean' "git clean"
has 'NOTE	shell	scripts/gate.sh:8	error hidden' "a failure that reads as zero"
has 'FAIL	secrets	scripts/gate.sh:9' "a token"
has 'WARN	instance	docs/runbook.md:7	e-mail' "an e-mail address"
has 'WARN	instance	docs/runbook.md:7	chat or member id U07QWERT12' "a member id"
has 'WARN	instance	docs/runbook.md:7	machine-specific absolute path' "a home path"

new_def docs_and_scripts
g checkout -qb change
printf '\n## Audit run\n\nRun `scripts/gate.sh audit`.\n' >> "$DEF/docs/runbook.md"
printf '# Orphan\n\nNobody links here.\n' > "$DEF/docs/orphan.md"
sed -i.bak 's/`scripts\/gate.sh check`/`scripts\/gate.sh verify`/' "$DEF/docs/runbook.md" && rm "$DEF/docs/runbook.md.bak"
printf 'Before the review, run `scripts/gate.sh check`.\n' >> "$DEF/CLAUDE.md"
g add -A >/dev/null && g commit -qm change
check --base main
has "WARN	commands	docs/runbook.md:9	names 'scripts/gate.sh audit'" "a script mode the dispatcher lacks"
has 'WARN	orphan-doc	docs/orphan.md' "a new doc nothing names"
lacks 'stale-term' "a term that still stands only where the change moved it"

new_def stale_term
printf '\nThe gate writes `review_marker` into each post.\n' >> "$DEF/docs/runbook.md"
printf 'Match `review_marker` before a post.\n' > "$DEF/docs/post.md"
printf 'See [post](docs/post.md).\n' >> "$DEF/CLAUDE.md"
g add -A >/dev/null && g commit -qm marker
g checkout -qb change
sed -i.bak 's/`review_marker`/`dedup_marker`/' "$DEF/docs/runbook.md" && rm "$DEF/docs/runbook.md.bak"
g commit -qam change
check --base main
has 'NOTE	stale-term	docs/post.md	the change removed `review_marker`' "a renamed term that still stands in another doc"

new_def restated_rule
long='Every scheduled run reads the worklist file that its gate wrote and never computes the worklist again.'
printf '\n%s\n' "$long" >> "$DEF/docs/runbook.md"
g commit -qam "rule home"
g checkout -qb change
printf '\n- %s\n' "$long" >> "$DEF/CLAUDE.md"
g commit -qam change
check --base main
has 'WARN	restated	CLAUDE.md:5	this line already stands in docs/runbook.md' "a rule restated in a second file"
has 'WARN	size	CLAUDE.md	always-loaded entry file grew' "growth of the entry file"

new_def scripts_and_skills
mkdir -p "$DEF/scripts/tests" "$DEF/.agents/skills/demo"
printf '#!/usr/bin/env bash\nbash ../gate.sh check\n' > "$DEF/scripts/tests/test_gate.sh"
g add -A >/dev/null && g commit -qm tests
g checkout -qb change
printf '#!/usr/bin/env bash\necho new\n' > "$DEF/scripts/new.sh"
printf '#!/usr/bin/env bash\nif then\n' > "$DEF/scripts/broken.sh"; chmod +x "$DEF/scripts/broken.sh"
printf -- '---\nname: other\n---\n# Demo\n' > "$DEF/.agents/skills/demo/SKILL.md"
printf '\necho more\n' >> "$DEF/scripts/gate.sh"
g add -A >/dev/null && g commit -qm change
check --base main
has 'WARN	exec-bit	scripts/new.sh' "a new script without the executable bit of its siblings"
has 'FAIL	syntax	scripts/broken.sh' "a script that does not parse"
has 'WARN	tests	scripts/new.sh	no test names this script' "a script no test names"
has 'NOTE	tests	scripts/gate.sh	the script changed and no test did' "a changed script with no changed test"
has "FAIL	skills	.agents/skills/demo/SKILL.md	front matter name 'other' != directory 'demo'" "a skill name that is not its directory"
has 'FAIL	skills	.agents/skills/demo/SKILL.md	no description' "a skill with no description"

new_def kit_manifest
cat > "$DEF/kit.yaml" <<'EOF'
id: agent
schedules:
  - name: agent-review
    precheck: bash "$HOME/scripts/precheck.sh" review
    task: >-
      Run the review run of
      docs/runbook.md.
  - name: agent-review
    task: Run the audit.
EOF
printf '\n> Run the review run of docs/runbook.md.\n' >> "$DEF/docs/runbook.md"
check
has 'FAIL	kit	kit.yaml	runs scripts/precheck.sh' "a precheck script the repository lacks"
has 'FAIL	kit	kit.yaml	schedule name declared twice: agent-review' "a duplicate schedule name"
has 'WARN	kit	kit.yaml	schedule task text has no identical copy in any doc.*Run the audit' "a task text with no source"
lacks 'Run the review run' "a task text equal to its doc blockquote"

new_def task_text_names_a_changed_doc
printf 'id: agent\nschedules:\n  - name: agent-review\n    task: Run the review run of docs/runbook.md.\n' > "$DEF/kit.yaml"
printf '\n> Run the review run of docs/runbook.md.\n' >> "$DEF/docs/runbook.md"
g add -A >/dev/null && g commit -qm kit
g checkout -qb change
printf '\nThe review run now ends with a summary.\n' >> "$DEF/docs/runbook.md"
g commit -qam change
check --base main
has 'NOTE	kit	docs/runbook.md	a schedule task text in kit.yaml names this doc' "a changed doc whose task text stays as it is"

new_def tracked_but_ignored
printf '/*\n!/.gitignore\n!/CLAUDE.md\n!/docs/\n!/scripts/\n!/VERSION\n!/CHANGELOG.md\n' > "$DEF/.gitignore"
mkdir -p "$DEF/.agents/skills/x"
printf -- '---\nname: x\ndescription: d\n---\n' > "$DEF/.agents/skills/x/SKILL.md"
g add .gitignore >/dev/null && g add -f .agents/skills/x/SKILL.md >/dev/null && g commit -qm skill
check
has 'WARN	ignored	.agents/skills/x/SKILL.md' "a force-added file the allowlist ignores"

finish
