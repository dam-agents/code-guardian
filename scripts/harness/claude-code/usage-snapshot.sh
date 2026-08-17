#!/usr/bin/env bash
# Claude Code harness helper — print the running session's cumulative token
# usage as one JSON object: {input, output, cache_read, cache_creation, msgs}.
#
#   usage-snapshot.sh <nonce>
#
# The caller invokes this with a run-unique nonce; the call itself writes the
# nonce into the session transcript, so a transcript containing it belongs to
# the caller's own run (concurrent sessions have their own nonces). Subagents
# spawned with the nonce in their prompt (docs/benchmark.md — skill fan-outs,
# reviewer subagents) carry it into their own transcript files, so the sum
# spans EVERY transcript holding the nonce — delegated work is counted, and
# usage-sum.jq's dedup-by-message-id keeps a transcript layout that embeds
# subagent usage in the parent from double-counting. The summation is the
# shared usage-sum.jq — the same program that feeds the run-level `tokens`
# event (log-session-tokens.sh), so snapshot deltas use the same accounting
# by construction. The matching set GROWS while the run progresses (each new
# subagent adds a file), so every call re-scans and unions the result with
# the per-nonce cache (files can age out of the scan window mid-run).
# Consumed by the benchmark's per-phase time/token measurement
# (docs/benchmark.md). Best-effort by design: on any miss (other harness, no
# transcript yet, no jq) it prints nothing and exits 0 — callers treat an
# empty result as "tokens unavailable", never an error.
set -u
export LC_ALL=C

NONCE="${1:-}"; [ -z "$NONCE" ] && exit 0
. "$(cd "$(dirname "$0")/../.." && pwd)/lib/toolpath.sh" 2>/dev/null || true
command -v jq >/dev/null 2>&1 || exit 0

# union of the cached set and a fresh scan (transcripts touched in the last
# day only — the projects dir accumulates); the cache keeps files that age
# out of the scan window mid-run, the scan adds files new subagents create
CACHE="${TMPDIR:-/tmp}/.bench-usage-${NONCE}"
KNOWN="$(cat "$CACHE" 2>/dev/null || true)"
FRESH="$(find "${HOME:-/home/agent}/.claude/projects" -name '*.jsonl' -mtime -1 \
           -exec grep -lF "$NONCE" {} + 2>/dev/null)"
FILES="$(printf '%s\n%s\n' "$KNOWN" "$FRESH" | sort -u \
         | while IFS= read -r f; do [ -f "$f" ] && printf '%s\n' "$f"; done)"
[ -n "$FILES" ] || exit 0
printf '%s\n' "$FILES" > "$CACHE" 2>/dev/null || true

# pod paths carry no spaces, so the unquoted expansion is safe here
# shellcheck disable=SC2086
set -- $FILES
jq -nR -f "$(cd "$(dirname "$0")" && pwd)/usage-sum.jq" "$@" 2>/dev/null
exit 0
