#!/usr/bin/env bash
# The suite lock (suite-lock.sh) and run.sh's file selection: one suite per
# host, a live holder is waited for or named, a dead one is reclaimed, an
# undeletable one is waited for, docker.sh holds the lock too, and named files
# run alone.
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

new_case lock_dead_undeletable
if [ "$(id -u)" -eq 0 ]; then
  printf 'ok   %s: skipped as root (root can delete a mode-555 dir)\n' "$CASE"
else
  f="$(dummy_test ok 0)"
  sleep 0 & dead=$!; wait "$dead"
  hold_lock "$dead"; chmod 555 "$SANDBOX/lock"
  # a watchdog ends a run that spins, so a regression fails instead of hanging
  CG_TEST_LOCK="$SANDBOX/lock" CG_TEST_LOCK_WAIT=0 \
    bash "$T_DIR/run.sh" "$f" > "$SANDBOX/out" 2>"$STDERR_LOG" & run=$!
  ( sleep 20; kill "$run" ) >/dev/null 2>&1 & dog=$!
  wait "$run"; RC=$?; kill "$dog" 2>/dev/null; wait "$dog" 2>/dev/null
  OUT="$(cat "$SANDBOX/out")"; chmod 755 "$SANDBOX/lock"
  assert_rc 1 'an undeletable dead lock is waited for up to the budget, then fails'
  assert_out_contains "pid $dead" 'the failure names the dead holder'
  assert_path gone "$SANDBOX/ok.ran" 'no test ran under the undeletable lock'
fi

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

new_case select_path_with_space
f="$(dummy_test ok 0)"; mkdir "$SANDBOX/a b"; cp "$f" "$SANDBOX/a b/ok.sh"
OUT="$(cd "$SANDBOX/a b" && CG_TEST_LOCK="$SANDBOX/lock" CG_TEST_LOCK_WAIT=0 \
  bash "$T_DIR/run.sh" ok.sh 2>"$STDERR_LOG")"; RC=$?
assert_rc 1 'a resolved path with whitespace fails the run'
assert_out_contains 'path has whitespace' 'the failure names the cause'

# a docker stub: `info` and `image inspect` pass; `run` records whether the
# host lock was held, drains the archive and reports a pass
docker_stub() {
  mkdir -p "$SANDBOX/dbin"
  printf '#!/usr/bin/env bash\ncase "$1" in (run)\n  [ -f "%s/lock/owner" ] && touch "%s/docker-locked"\n  touch "%s/docker-ran"; cat >/dev/null; echo "ALL TESTS PASSED";;\nesac\nexit 0\n' \
    "$SANDBOX" "$SANDBOX" "$SANDBOX" > "$SANDBOX/dbin/docker"
  chmod +x "$SANDBOX/dbin/docker"
}

run_docker() { # <lock-wait-seconds>
  OUT="$(PATH="$SANDBOX/dbin:$PATH" CG_TEST_LOCK="$SANDBOX/lock" CG_TEST_LOCK_WAIT="$1" \
    bash "$T_DIR/docker.sh" 2>"$STDERR_LOG")"; RC=$?
}

new_case docker_takes_lock
docker_stub
run_docker 0
assert_rc 0 'docker.sh runs with a free lock'
assert_path kept "$SANDBOX/docker-locked" 'the container runs under the host lock'
assert_path gone "$SANDBOX/lock" 'docker.sh releases the lock at exit'

new_case docker_waits_for_holder
docker_stub
hold_lock "$$"
run_docker 0
assert_rc 1 'docker.sh fails on a live holder with no wait budget'
assert_out_contains "pid $$, checkout /checkouts/other" 'the failure names the holder'
assert_path gone "$SANDBOX/docker-ran" 'no container starts under a held lock'
assert_path kept "$SANDBOX/lock/owner" 'the holder keeps its lock'

finish
