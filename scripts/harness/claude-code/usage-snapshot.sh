#!/usr/bin/env bash
# Claude Code harness helper — print the running session's cumulative token
# usage as one JSON object: {input, output, cache_read, cache_creation, msgs}.
#
#   usage-snapshot.sh <nonce>
#
# The caller invokes this with a run-unique nonce; the call itself writes the
# nonce into the session transcript, so the transcript containing it IS the
# caller's own session (concurrent sessions have their own transcripts). The
# summation matches log-session-tokens.sh (dedup by message id — keep in sync),
# so deltas between two snapshots use the same accounting as the run-level
# `tokens` event. Consumed by the benchmark's per-phase time/token measurement
# (docs/benchmark.md). Best-effort by design: on any miss (other harness, no
# transcript yet, no jq) it prints nothing and exits 0 — callers treat an
# empty result as "tokens unavailable", never an error.
set -u
export LC_ALL=C

NONCE="${1:-}"; [ -z "$NONCE" ] && exit 0
. "$(cd "$(dirname "$0")/../.." && pwd)/lib/toolpath.sh" 2>/dev/null || true
command -v jq >/dev/null 2>&1 || exit 0

# transcripts touched in the last day only — the projects dir accumulates.
# Pod paths carry no spaces, so the unquoted ls expansion is safe here.
MATCHES="$(find "${HOME:-/home/agent}/.claude/projects" -name '*.jsonl' -mtime -1 2>/dev/null \
      | while IFS= read -r f; do grep -l "$NONCE" "$f" 2>/dev/null; done)"
[ -n "$MATCHES" ] || exit 0
TP="$(ls -t $MATCHES 2>/dev/null | head -1)"
{ [ -n "$TP" ] && [ -f "$TP" ]; } || exit 0

jq -c -R 'fromjson? // empty' "$TP" 2>/dev/null | jq -s '
  [.[] | select(.message.usage) | {id: (.message.id // .uuid), u: .message.usage}]
  | unique_by(.id)
  | {input: ([.[].u.input_tokens // 0] | add // 0),
     output: ([.[].u.output_tokens // 0] | add // 0),
     cache_read: ([.[].u.cache_read_input_tokens // 0] | add // 0),
     cache_creation: ([.[].u.cache_creation_input_tokens // 0] | add // 0),
     msgs: length}' 2>/dev/null
exit 0
