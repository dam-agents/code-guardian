#!/usr/bin/env bash
# skill-install.sh — install or refresh configured repo-sourced skills the way
# preflight does (lib/skills.sh → install_skill; docs/skills.md → Installation)
# for a run that installs outside preflight: the benchmark run's refresh, an
# on-demand review's missing skill.
#
#   skill-install.sh                 # every skill of the `## Review skills` table
#   skill-install.sh <skill>…        # the named ones
#
# Prints one JSON object, skill → status: `installed (N files)` | `cached` |
# `harness` | `install-failed` | `not-configured`. Exits 0 — a failed skill is
# skipped by its run, never a reason to abort it.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$SCRIPT_DIR/lib/toolpath.sh" ] && . "$SCRIPT_DIR/lib/toolpath.sh" 2>/dev/null
if ! . "$SCRIPT_DIR/log.sh" >/dev/null 2>&1; then logev() { :; }; fi
. "$SCRIPT_DIR/lib/common.sh"
. "$SCRIPT_DIR/lib/skills.sh"

HOME_DIR="${HOME:-/home/agent}"
WORK="${WORK_DIR:-$HOME_DIR/work}"
CONFIG="$WORK/CONFIG.md"

# skill<TAB>source per configured skill
configured() {
  skills_table_json | jq -r '.[] | [.skill, .source] | @tsv'
}

CONF="$(configured)"
if [ "$#" -eq 0 ]; then
  set -- $(skills_table_json | jq -r '.[].skill')
fi
OUT='{}'
for name in "$@"; do
  src="$(printf '%s\n' "$CONF" | awk -F'\t' -v n="$name" '$1 == n { s = $2 } END { print s }')"
  if [ -z "$src" ]; then st="not-configured"; else st="$(install_skill "$name" "$src")"; fi
  OUT="$(printf '%s' "$OUT" | jq --arg k "$name" --arg v "$st" '. + {($k): $v}')"
done
printf '%s\n' "$OUT"
