#!/usr/bin/env bash
# benchmark-provenance.sh — print the run-input provenance of a benchmark run
# as one JSON object (docs/benchmark.md → Running the benchmark, phase 2):
#
#   benchmark-provenance.sh <work/benchmark dir>
#
#   {definition_version, prev_version, changes_since_prev[], harness_version,
#    memory_sha, skill_sources{}, definition_ref{branch,sha}}
#
# Deterministic and read-only, so every run assembles these fields the same
# way whatever model executes it. The caller merges in what only the session
# knows (model id, trigger, judge). All fields are best-effort: a missing
# source yields null/empty, never a failure.
#
# - prev_version: definition_version of the newest earlier results/*.json.
# - changes_since_prev: release-commit subjects between prev_version and the
#   checked-out VERSION, newest first (release commits = commits touching
#   VERSION; docs/self-modification.md §12 — one bump per change). Empty when
#   the version did not change or history is unavailable.
# - skill_sources: every entry of the preflight skill-install cache
#   (short source SHA per installed repo-sourced skill).
# - definition_ref: the checkout's branch + short sha — on a feature branch
#   (trial runs) VERSION alone does not identify the code.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$SCRIPT_DIR/lib/toolpath.sh" ] && . "$SCRIPT_DIR/lib/toolpath.sh" 2>/dev/null

BDIR="${1:-}"
[ -n "$BDIR" ] || { printf 'usage: benchmark-provenance.sh <work/benchmark dir>\n' >&2; exit 2; }
HOME_DIR="${HOME:-/home/agent}"

CUR_VER="$(head -1 "$HOME_DIR/VERSION" 2>/dev/null || true)"

PREV_VER=""
if ls "$BDIR"/results/*.json >/dev/null 2>&1; then
  PREV_VER="$(for f in "$BDIR"/results/*.json; do
                jq -c 'select(type == "object")' "$f" 2>/dev/null || true
              done | jq -rs 'sort_by(.ts // "") | last | .definition_version // empty')"
fi

CHANGES='[]'
if [ -n "$PREV_VER" ] && [ -n "$CUR_VER" ] && [ "$PREV_VER" != "$CUR_VER" ]; then
  CHANGES="$(git -C "$HOME_DIR" log --format='%H%x09%s' -- VERSION 2>/dev/null \
    | while IFS="$(printf '\t')" read -r sha subj; do
        [ "$(git -C "$HOME_DIR" show "$sha:VERSION" 2>/dev/null | head -1)" = "$PREV_VER" ] && break
        printf '%s\n' "$subj"
      done | head -30 | jq -R . | jq -s .)"
fi

HARNESS="$(claude --version 2>/dev/null | head -1 || true)"
MEMORY_SHA="$(git hash-object "$HOME_DIR/work/MEMORY.md" 2>/dev/null || true)"

SKILLS='{}'
SKILL_CACHE="$HOME_DIR/.claude/skills/.cache"
if ls "$SKILL_CACHE"/*.sha >/dev/null 2>&1; then
  SKILLS="$(for f in "$SKILL_CACHE"/*.sha; do
              n="${f##*/}"; n="${n%.sha}"
              printf '%s\t%.12s\n' "$n" "$(cat "$f" 2>/dev/null)"
            done | jq -R 'split("\t") | {(.[0]): .[1]}' | jq -s 'add // {}')"
fi

BRANCH="$(git -C "$HOME_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
SHA="$(git -C "$HOME_DIR" rev-parse --short=12 HEAD 2>/dev/null || true)"

jq -n --arg cur "$CUR_VER" --arg prev "$PREV_VER" --argjson changes "$CHANGES" \
      --arg harness "$HARNESS" --arg mem "$MEMORY_SHA" --argjson skills "$SKILLS" \
      --arg branch "$BRANCH" --arg sha "$SHA" '
  def ornull: if . == "" then null else . end;
  {definition_version: ($cur | ornull),
   prev_version: ($prev | ornull),
   changes_since_prev: $changes,
   harness_version: ($harness | ornull),
   memory_sha: ($mem | ornull),
   skill_sources: $skills,
   definition_ref: {branch: ($branch | ornull), sha: ($sha | ornull)}}'
