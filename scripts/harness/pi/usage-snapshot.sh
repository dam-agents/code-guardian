#!/usr/bin/env bash
# pi harness helper — print the token usage of every pi session transcript
# that holds the nonce, as one JSON object: {input, output, cache_read,
# cache_creation, msgs, model}. Same contract as
# ../claude-code/usage-snapshot.sh (docs/benchmark.md → per-phase
# measurement): the caller's own bash call writes the nonce into its session
# transcript, and every nested subagent (subagents.sh) gets the nonce in its
# prompt, so its own transcript matches too. Best-effort: on any miss it prints
# nothing and exits 0.
#
#   usage-snapshot.sh <nonce>
set -u
export LC_ALL=C

NONCE="${1:-}"; [ -z "$NONCE" ] && exit 0
. "$(cd "$(dirname "$0")/../.." && pwd)/lib/toolpath.sh" 2>/dev/null || true
command -v jq >/dev/null 2>&1 || exit 0

SESSIONS="${PI_CODING_AGENT_DIR:-${HOME:-/home/agent}/.pi/agent}/sessions"
CACHE="${TMPDIR:-/tmp}/.bench-usage-${NONCE}"
KNOWN="$(cat "$CACHE" 2>/dev/null || true)"
FRESH="$(find "$SESSIONS" -name '*.jsonl' -mtime -1 \
           -exec grep -lF "$NONCE" {} + 2>/dev/null)"
FILES="$(printf '%s\n%s\n' "$KNOWN" "$FRESH" | sort -u \
         | while IFS= read -r f; do [ -f "$f" ] && printf '%s\n' "$f"; done)"
[ -n "$FILES" ] || exit 0
printf '%s\n' "$FILES" > "$CACHE" 2>/dev/null || true

# pi session paths carry no spaces (--<cwd with / as ->--/<ts>_<id>.jsonl)
# shellcheck disable=SC2086
set -- $FILES
jq -nR -f "$(cd "$(dirname "$0")/../claude-code" && pwd)/usage-sum.jq" "$@" 2>/dev/null
exit 0
