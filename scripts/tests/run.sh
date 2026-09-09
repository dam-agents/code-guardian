#!/usr/bin/env bash
# run.sh — run every preflight stub test (scripts/tests/test_*.sh).
# Deterministic, offline: gh/curl are stubbed via tests/bin. Used by the CI
# workflow (.github/workflows/ci.yml) and by self-modification validation
# (docs/self-modification.md §9). Exit 0 iff every assertion passed.
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
cd "$(dirname "$0")" || exit 1

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

ORDER=""
for t in $SLOWEST; do
  [ -f "$t" ] && ORDER="$ORDER $t"
done
for t in test_*.sh; do
  case " $ORDER " in (*" $t "*) continue;; esac
  ORDER="$ORDER $t"
done

OUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cg-run.XXXXXX")" \
  || { echo "TESTS FAILED: no output directory"; exit 1; }
trap 'rm -rf "$OUT_DIR"' EXIT

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
  printf '.. %s\n' "$1" >&2
  bash "$1" > "$OUT_DIR/$1.out" 2>&1
  printf '%s' "$?" > "$OUT_DIR/$1.rc"
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
  [ -f "$OUT_DIR/$t.out" ] && cat "$OUT_DIR/$t.out"
  trc="$(cat "$OUT_DIR/$t.rc" 2>/dev/null)"
  # no .rc means the worker died without reporting — a failure, not a pass
  [ "$trc" = "0" ] || { rc=1; [ -n "$trc" ] || echo "FAIL $t: worker produced no exit code"; }
done

if [ "$rc" -eq 0 ]; then echo "ALL TESTS PASSED"; else echo "TESTS FAILED"; fi
exit "$rc"
