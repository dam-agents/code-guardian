#!/usr/bin/env bash
# bench-lock.sh — the benchmark run lock (docs/benchmark.md → **Running the
# benchmark**): one TTL and one age read for every reader (preflight.sh's
# benchmark gate and tmp sweep, benchmark-core.sh new-version).

# a scored run never legitimately runs longer than this
BENCH_LOCK_TTL_MIN=360

# Minutes since the lock was taken: from its first line `<ISO> <nonce>`; when
# that line is empty, unparsable or in the future, from the file's mtime.
# Prints nothing when neither measures an age.
bench_lock_age_m() { # <lock-file>
  local iso t="" now
  now="$(date -u +%s)"
  iso="$(head -1 "$1" 2>/dev/null | cut -d' ' -f1)"
  if [ -n "$iso" ]; then
    t="$(date -u -d "$iso" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" +%s 2>/dev/null || true)"
  fi
  case "$t" in (''|*[!0-9]*) t="";; esac
  [ -n "$t" ] && [ "$t" -le "$now" ] || t="$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || true)"
  case "$t" in (''|*[!0-9]*) return 0;; esac
  [ "$t" -le "$now" ] || return 0
  printf '%s\n' $(( (now - t) / 60 ))
}

# Exit 0 when the lock is live: younger than the TTL, or of no measurable age
# (an unmeasurable lock never reads as stale). Prints the age in minutes, or
# `?` when it is not measurable.
bench_lock_live() { # <lock-file>
  local a
  a="$(bench_lock_age_m "$1")"
  printf '%s\n' "${a:-?}"
  [ -z "$a" ] || [ "$a" -lt "$BENCH_LOCK_TTL_MIN" ]
}
