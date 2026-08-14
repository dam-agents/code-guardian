#!/usr/bin/env bash
# Claude Code harness helper — print the running session's cumulative token
# usage as one JSON object: {input, output, cache_read, cache_creation, msgs}.
#
#   usage-snapshot.sh <nonce>
#
# The caller invokes this with a run-unique nonce; the call itself writes the
# nonce into the session transcript, so the transcript containing it IS the
# caller's own session (concurrent sessions have their own transcripts). The
# summation is the shared usage-sum.jq — the same program that feeds the
# run-level `tokens` event (log-session-tokens.sh), so snapshot deltas use the
# same accounting by construction. The resolved transcript path is cached per
# nonce, so only the first snapshot of a run pays the directory sweep.
# Consumed by the benchmark's per-phase time/token measurement
# (docs/benchmark.md). Best-effort by design: on any miss (other harness, no
# transcript yet, no jq) it prints nothing and exits 0 — callers treat an
# empty result as "tokens unavailable", never an error.
set -u
export LC_ALL=C

NONCE="${1:-}"; [ -z "$NONCE" ] && exit 0
. "$(cd "$(dirname "$0")/../.." && pwd)/lib/toolpath.sh" 2>/dev/null || true
command -v jq >/dev/null 2>&1 || exit 0

# the nonce→transcript mapping cannot change mid-run: resolve once, cache it
CACHE="${TMPDIR:-/tmp}/.bench-usage-${NONCE}"
TP="$(cat "$CACHE" 2>/dev/null || true)"
if [ -z "$TP" ] || [ ! -f "$TP" ]; then
  # transcripts touched in the last day only — the projects dir accumulates.
  # Pod paths carry no spaces, so the unquoted ls expansion is safe here.
  MATCHES="$(find "${HOME:-/home/agent}/.claude/projects" -name '*.jsonl' -mtime -1 \
             -exec grep -lF "$NONCE" {} + 2>/dev/null)"
  [ -n "$MATCHES" ] || exit 0
  TP="$(ls -t $MATCHES 2>/dev/null | head -1)"
  { [ -n "$TP" ] && [ -f "$TP" ]; } || exit 0
  printf '%s' "$TP" > "$CACHE" 2>/dev/null || true
fi

jq -nR -f "$(cd "$(dirname "$0")" && pwd)/usage-sum.jq" "$TP" 2>/dev/null
exit 0
