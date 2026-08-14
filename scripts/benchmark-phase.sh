#!/usr/bin/env bash
# benchmark-phase.sh — measure one benchmark review phase (docs/benchmark.md).
#
#   benchmark-phase.sh begin <state-dir> <label> <nonce>
#   benchmark-phase.sh end   <state-dir> <label> <nonce>   -> {"seconds":N,"tokens":…}
#
# `begin` stamps the phase start (epoch + a token snapshot); `end` prints the
# measured pair the results file records:
#
#   {"seconds": <end-epoch minus start-epoch>,
#    "tokens": {input,output,cache_read,cache_creation,msgs} | null}
#
# The agent never does this arithmetic itself. Hand-derived timings (e.g. from
# file mtimes) look identical to measured ones in the results file but are not
# comparable across runs, so the measurement lives here and the run only calls
# it. `tokens` is null exactly when the harness gives no usable snapshot —
# an honest gap, never an estimate. A missing `begin` stamp is an error, not a
# zero: a silently-zero phase would understate the cost the benchmark exists
# to track.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SNAP="$SCRIPT_DIR/harness/claude-code/usage-snapshot.sh"

ACTION="${1:-}"; STATE="${2:-}"; LABEL="${3:-}"; NONCE="${4:-}"
[ -n "$ACTION" ] && [ -n "$STATE" ] && [ -n "$LABEL" ] && [ -n "$NONCE" ] || {
  printf 'usage: benchmark-phase.sh begin|end <state-dir> <label> <nonce>\n' >&2; exit 2; }
case "$LABEL" in (*[!A-Za-z0-9._-]*) printf 'label must be [A-Za-z0-9._-]\n' >&2; exit 2;; esac

T="$STATE/$LABEL.t0"; S="$STATE/$LABEL.s0"

case "$ACTION" in
  (begin)
    mkdir -p "$STATE" || { printf 'cannot create state dir %s\n' "$STATE" >&2; exit 2; }
    date -u +%s > "$T" || exit 2
    bash "$SNAP" "$NONCE" > "$S" 2>/dev/null || : > "$S"
    printf 'phase %s started\n' "$LABEL"
    ;;
  (end)
    [ -r "$T" ] || { printf 'no start stamp for phase %s (call begin first)\n' "$LABEL" >&2; exit 2; }
    now="$(date -u +%s)"; t0="$(cat "$T")"
    case "$t0" in (''|*[!0-9]*) printf 'corrupt start stamp for %s\n' "$LABEL" >&2; exit 2;; esac
    s1="$(bash "$SNAP" "$NONCE" 2>/dev/null || true)"
    s0="$(cat "$S" 2>/dev/null || true)"
    # tokens only when BOTH snapshots parsed — a one-sided delta would be wrong
    if [ -n "$s0" ] && [ -n "$s1" ]; then
      tok="$(jq -n --argjson a "$s0" --argjson b "$s1" \
        '{input: ($b.input - $a.input), output: ($b.output - $a.output),
          cache_read: ($b.cache_read - $a.cache_read),
          cache_creation: ($b.cache_creation - $a.cache_creation),
          msgs: ($b.msgs - $a.msgs)}' 2>/dev/null || printf 'null')"
    else
      tok=null
    fi
    jq -n --argjson s "$((now - t0))" --argjson t "${tok:-null}" '{seconds: $s, tokens: $t}'
    rm -f "$T" "$S"
    ;;
  (*) printf 'usage: benchmark-phase.sh begin|end <state-dir> <label> <nonce>\n' >&2; exit 2;;
esac
