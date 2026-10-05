# suite-lock.sh — the host-wide stub-suite lock, sourced by run.sh and
# docker.sh. One suite per host at a time: concurrent suites on one machine
# slow each other down until none finishes.
#
# The lock dir is CG_TEST_LOCK (default /tmp/cg-test-suite.lock — /tmp, not
# $TMPDIR, because $TMPDIR can differ per session on one host). A second run
# waits for it up to CG_TEST_LOCK_WAIT seconds (default 3600; 0 = fail at once)
# and names the holder on stderr. A lock whose holder PID is dead, or that has
# no owner line a minute after its mkdir, is reclaimed; a lock this run cannot
# delete is waited for like a live one.
#
# The caller sets CHECKOUT, calls take_lock, and releases at exit:
#   trap 'release_lock' EXIT; take_lock || exit 1

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
      [ "$(lock_owner)" = "$owner" ] || continue
      rm -rf "$LOCK" 2>/dev/null && continue
    fi
    # no owner line a minute after the mkdir: the holder died in between
    if [ -z "$pid" ] && [ -n "$(find "$LOCK" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
      rm -rf "$LOCK" 2>/dev/null && continue
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

release_lock() { if [ "$OWNED" -eq 1 ]; then rm -rf "$LOCK"; fi; }
