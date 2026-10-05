#!/usr/bin/env bash
# run.sh's suite lock and file selection: one suite per host, a live holder is
# waited for or named, a dead one is reclaimed, and named files run alone.
# Every case points CG_TEST_LOCK into its sandbox — the suite running this file
# holds the host lock itself.
. "$(dirname "$0")/helpers.sh"

# a test file of the case that records it ran -> its path
dummy_test() { # <name> <exit-code>
  printf '#!/usr/bin/env bash\necho "dummy %s ran"\ntouch "%s/%s.ran"\nexit %s\n' \
    "$1" "$SANDBOX" "$1" "$2" > "$SANDBOX/$1.sh"
  printf '%s' "$SANDBOX/$1.sh"
}

# hold the case's lock as <pid>
hold_lock() { # <pid>
  mkdir -p "$SANDBOX/lock"; printf '%s /checkouts/other\n' "$1" > "$SANDBOX/lock/owner"
}

run_suite() { # <lock-wait-seconds> <run.sh args…>
  local w="$1"; shift
  OUT="$(CG_TEST_LOCK="$SANDBOX/lock" CG_TEST_LOCK_WAIT="$w" \
    bash "$T_DIR/run.sh" "$@" 2>"$STDERR_LOG")"; RC=$?
}

assert_path() { # gone|kept <path> <description>
  local ok=0
  case "$1" in (gone) [ ! -e "$2" ] && ok=1;; (kept) [ -e "$2" ] && ok=1;; esac
  if [ "$ok" -eq 1 ]; then printf 'ok   %s: %s\n' "$CASE" "$3"
  else printf 'FAIL %s: %s (%s expected %s)\n' "$CASE" "$3" "$2" "$1"; FAILED=1; fi
}

new_case lock_free
f="$(dummy_test ok 0)"
run_suite 0 "$f"
assert_rc 0 'a free lock lets the run start'
assert_out_contains 'ALL TESTS PASSED' 'the named file passed'
assert_path kept "$SANDBOX/ok.ran" 'the named file ran'
assert_path gone "$SANDBOX/lock" 'the lock is released at exit'

new_case lock_held_live
f="$(dummy_test ok 0)"
hold_lock "$$"
run_suite 0 "$f"
assert_rc 1 'a live holder with no wait budget fails the run'
assert_out_contains "pid $$, checkout /checkouts/other" 'the failure names the holder'
assert_path gone "$SANDBOX/ok.ran" 'no test ran under a held lock'
assert_path kept "$SANDBOX/lock/owner" 'the holder keeps its lock'

new_case lock_waits_for_holder
f="$(dummy_test ok 0)"
sleep 3 & holder=$!
hold_lock "$holder"
run_suite 30 "$f"
assert_rc 0 'the run starts once the holder exits'
assert_file_contains "$STDERR_LOG" "waiting for the suite run of pid $holder" 'the wait names the holder'
assert_path kept "$SANDBOX/ok.ran" 'the named file ran after the wait'

new_case lock_dead_holder
f="$(dummy_test ok 0)"
sleep 0 & dead=$!; wait "$dead"
hold_lock "$dead"
run_suite 0 "$f"
assert_rc 0 'a dead holder is reclaimed'
assert_path kept "$SANDBOX/ok.ran" 'the named file ran after the reclaim'
assert_path gone "$SANDBOX/lock" 'the reclaimed lock is released at exit'

new_case lock_ownerless_stale
f="$(dummy_test ok 0)"
mkdir -p "$SANDBOX/lock"; touch -t 202001010000 "$SANDBOX/lock"
run_suite 0 "$f"
assert_rc 0 'a lock with no owner line after a minute is reclaimed'

new_case select_failing_file
ok="$(dummy_test ok 0)"; bad="$(dummy_test bad 1)"
run_suite 0 "$bad"
assert_rc 1 'a failing named file fails the run'
assert_out_contains 'TESTS FAILED' 'the verdict line says so'
assert_path gone "$SANDBOX/ok.ran" 'a file not named does not run'

new_case select_unknown_file
run_suite 0 "$SANDBOX/missing.sh"
assert_rc 1 'an unknown file fails the run'
assert_out_contains 'no such test file' 'the failure names the cause'
assert_path gone "$SANDBOX/lock" 'an unknown file fails before the lock is taken'

finish
