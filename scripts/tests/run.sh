#!/usr/bin/env bash
# run.sh [test-file…] — run the preflight stub tests: the named files (a name in
# this directory or a path from the caller's directory), or every test_*.sh.
# Deterministic, offline: gh/curl are stubbed via tests/bin. Used by the CI
# workflow (.github/workflows/ci.yml) and by self-modification validation
# (docs/self-modification.md §9). Exit 0 iff every assertion passed.
#
# One run per host at a time: concurrent suites on one machine slow each other
# down until none finishes. A run takes the lock dir CG_TEST_LOCK (default
# /tmp/cg-test-suite.lock — /tmp, not $TMPDIR, because $TMPDIR can differ per
# session on one host). A second run waits for it up to CG_TEST_LOCK_WAIT
# seconds (default 3600; 0 = fail at once) and names the holder on stderr. A
# lock whose holder PID is dead is reclaimed.
#
# Cases are sandbox-isolated (helpers.sh → new_case), so the files run
# concurrently: CG_TEST_JOBS workers, by default one per core clamped to 2..8.
# Serially the suite is ~740s on the pod and ~120s on a CI runner; the pod
# figure does not fit the 550s a caller typically allows it, and the slowest
# file alone is ~300s. Output is buffered per file so a parallel run reads
# exactly like a serial one, and the slowest files start first (SLOWEST below)
# so the tail does not decide the wall clock. Each worker announces its file on
# stderr as it starts, so a run that hangs still names the file it waits for.
# CG_TEST_JOBS=1 restores fully serial execution for debugging.
CALLER_DIR="$(pwd)"
cd "$(dirname "$0")" || exit 1
CHECKOUT="$(cd ../.. && pwd)"

# Resolve the named files before anything waits on the lock: a typo fails now.
PICKED=""
for a in "$@"; do
  case "$a" in (*[[:space:]]*) echo "TESTS FAILED: test file path has whitespace: $a"; exit 1;; esac
  # a bare name is a file of this directory; anything else is a path
  if [ "${a#*/}" = "$a" ] && [ -f "$a" ]; then PICKED="$PICKED $a"; continue; fi
  p="$a"; case "$p" in (/*) ;; (*) p="$CALLER_DIR/$a";; esac
  [ -f "$p" ] || { echo "TESTS FAILED: no such test file: $a"; exit 1; }
  PICKED="$PICKED $p"
done

# A 1-core report would restore the serial wall clock this run exists to avoid,
# and a 64-core one would start every file at once; the work is subprocess-bound
# either way, so the useful range is narrow.
jobs="${CG_TEST_JOBS:-}"
if [ -z "$jobs" ]; then
  jobs="$(nproc 2>/dev/null || echo 4)"
  case "$jobs" in (''|*[!0-9]*) jobs=4;; esac
  [ "$jobs" -lt 2 ] && jobs=2
  [ "$jobs" -gt 8 ] && jobs=8
fi
case "$jobs" in (''|*[!0-9]*|0) jobs=1;; esac

# Long poles first, longest to shortest — measured on the pod, 2026-09-09.
# A name that no longer exists is skipped; a new test file not listed here
# still runs, just after the ones that are.
SLOWEST="test_review_pr.sh test_profile.sh test_mentions.sh test_audit_stats.sh"

ORDER="$PICKED"
if [ -z "$ORDER" ]; then
  for t in $SLOWEST; do
    [ -f "$t" ] && ORDER="$ORDER $t"
  done
  for t in test_*.sh; do
    case " $ORDER " in (*" $t "*) continue;; esac
    ORDER="$ORDER $t"
  done
fi

LOCK="${CG_TEST_LOCK:-/tmp/cg-test-suite.lock}"
LOCK_WAIT="${CG_TEST_LOCK_WAIT:-3600}"
case "$LOCK_WAIT" in (''|*[!0-9]*) LOCK_WAIT=3600;; esac
OWNED=0

# the holder's "<pid> <checkout>" line, or empty while it is being written
lock_owner() { cat "$LOCK/owner" 2>/dev/null; }

# `ps -p` sees a holder of another user too; `kill -0` where ps is missing
pid_alive() { # <pid>
  if command -v ps >/dev/null 2>&1; then ps -p "$1" >/dev/null 2>&1
  else kill -0 "$1" 2>/dev/null; fi
}

# take the lock; wait for a live holder, reclaim a dead one -> rc 1 on timeout
take_lock() {
  local waited=0 owner pid told=0
  while :; do
    if mkdir "$LOCK" 2>/dev/null; then
      printf '%s %s\n' "$$" "$CHECKOUT" > "$LOCK/owner"
      OWNED=1; return 0
    fi
    if [ ! -d "$LOCK" ]; then
      echo "warning: cannot create $LOCK; this run is not locked" >&2
      return 0
    fi
    owner="$(lock_owner)"; pid="${owner%% *}"
    case "$pid" in (*[!0-9]*) pid="";; esac
    if [ -n "$pid" ] && ! pid_alive "$pid"; then
      # reclaim only the lock judged dead, never one a waiter took meanwhile
      [ "$(lock_owner)" = "$owner" ] && rm -rf "$LOCK"
      continue
    fi
    # no owner line a minute after the mkdir: the holder died in between
    if [ -z "$pid" ] && [ -n "$(find "$LOCK" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
      rm -rf "$LOCK"; continue
    fi
    if [ "$waited" -ge "$LOCK_WAIT" ]; then
      echo "TESTS FAILED: another suite run holds $LOCK (pid ${pid:-?}, checkout ${owner#* }) after ${waited}s"
      return 1
    fi
    if [ "$told" -eq 0 ]; then
      printf '.. waiting for the suite run of pid %s (checkout %s)\n' "${pid:-?}" "${owner#* }" >&2
      told=1
    fi
    sleep 1; waited=$((waited + 1))
  done
}

trap 'rm -rf "${OUT_DIR:-}"; [ "$OWNED" -eq 1 ] && rm -rf "$LOCK"' EXIT
take_lock || exit 1

OUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cg-run.XXXXXX")" \
  || { echo "TESTS FAILED: no output directory"; exit 1; }

# helpers.sh sweeps its own sandboxes on EXIT, which covers a TERM from a
# `timeout` too — but not SIGKILL, where no trap runs and every cg-test.* dir
# of the killed run stays behind. Sweeping leftovers older than the longest
# plausible run keeps /tmp from filling up over many killed runs, and never
# touches a sandbox belonging to a suite running concurrently with this one.
find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'cg-test.*' -type d -mmin +60 \
  -exec rm -rf {} + 2>/dev/null
find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'cg-run.*' -type d -mmin +60 \
  -exec rm -rf {} + 2>/dev/null

# one worker: run the file, keep its output and its exit code side by side
run_one() { # <test-file>
  local k="${1//\//_}"   # a path's slashes would point outside OUT_DIR
  printf '.. %s\n' "$1" >&2
  bash "$1" > "$OUT_DIR/$k.out" 2>&1
  printf '%s' "$?" > "$OUT_DIR/$k.rc"
  return 0   # the verdict travels in the .rc file, never in the worker's status
}

# Throttle to $jobs workers by waiting on the oldest one. `wait -n` would free
# whichever finishes first, but it needs bash 4.3 and this suite also runs on
# macOS bash 3.2 (helpers.sh), where it fails and a bare `wait` would drain
# every worker — leaving the rest of the files to run one at a time, silently.
# SLOWEST-first ordering keeps the oldest worker the longest-running one, so
# the two policies pick nearly the same job.
PIDS=""
for t in $ORDER; do
  run_one "$t" &
  PIDS="$PIDS $!"
  set -- $PIDS
  if [ "$#" -ge "$jobs" ]; then
    wait "$1"
    shift
    PIDS="$*"
  fi
done
wait

rc=0
for t in $ORDER; do
  echo "== $t"
  k="${t//\//_}"
  [ -f "$OUT_DIR/$k.out" ] && cat "$OUT_DIR/$k.out"
  trc="$(cat "$OUT_DIR/$k.rc" 2>/dev/null)"
  # no .rc means the worker died without reporting — a failure, not a pass
  [ "$trc" = "0" ] || { rc=1; [ -n "$trc" ] || echo "FAIL $t: worker produced no exit code"; }
done

if [ "$rc" -eq 0 ]; then echo "ALL TESTS PASSED"; else echo "TESTS FAILED"; fi
exit "$rc"
