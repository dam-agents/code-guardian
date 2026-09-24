#!/usr/bin/env bash
# work-backup.sh: persist → restore round trip over a local bare remote.
# Restore reports its outcome by exit code and verifies every file; transient
# state never travels; a persist that would delete a protected record is
# refused unless the operator allows it.
. "$(dirname "$0")/helpers.sh"

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# one bare remote per case, reached through WORK_BACKUP_REMOTE
new_remote() { REMOTE="$SANDBOX/remote.git"; git init -q --bare "$REMOTE"; }

backup() { # <mode> [work-dir] — $OUT, $RC
  RC=0
  OUT="$(WORK_DIR="${2:-$WORK}" HOME="$FAKE_HOME" \
         WORK_BACKUP_REMOTE="$REMOTE" WORK_BACKUP_LOCAL="$SANDBOX/clone-$1-$RANDOM" \
         bash "$REPO_ROOT/scripts/work-backup.sh" "$1" 2>&1)" || RC=$?
}

remote_has() { git --git-dir="$REMOTE" cat-file -e "main:$1" 2>/dev/null; }

assert_true() { # <description> <command…>
  local d="$1"; shift
  if "$@"; then printf 'ok   %s: %s\n' "$CASE" "$d"
  else printf 'FAIL %s: %s (out: %.300s)\n' "$CASE" "$d" "$OUT"; FAILED=1; fi
}

seed_state() {
  base_config "- work_repo: acme/widgets-state"
  printf '# Review Preferences\n' > "$WORK/MEMORY.md"
  mkdir -p "$WORK/audit/weeks" "$WORK/benchmark/results" "$WORK/logs" "$WORK/reviews"
  printf '{"week":"2026-W38"}\n' > "$WORK/audit/weeks/20260920T000000Z.json"
  printf '| run |\n' > "$WORK/benchmark/RESULTS.md"
  printf '{}\n' > "$WORK/benchmark/results/20260920T000000Z.json"
  printf '{"event":"x"}\n' > "$WORK/logs/events-2026-09-20.jsonl"
  printf '# PR 7\n' > "$WORK/reviews/pr-7.md"
  # transient: never carried
  mkdir -p "$WORK/.stall-alert.lock"
  printf 'x\n' > "$WORK/MENTIONS.md.tmp"
  printf '2026-09-20T00:00:00Z n\n' > "$WORK/benchmark/.run-lock"
}

new_case restore-round-trip
new_remote; seed_state
backup persist
assert_true "persist pushed the audit week" remote_has audit/weeks/20260920T000000Z.json
assert_true "persist pushed the logs" remote_has logs/events-2026-09-20.jsonl
assert_true "persist left the benchmark run lock out" eval '! remote_has benchmark/.run-lock'
assert_true "persist left *.tmp out" eval '! remote_has MENTIONS.md.tmp'
FRESH="$SANDBOX/fresh-work"; mkdir -p "$FRESH"
printf -- '- work_repo: acme/widgets-state\n' > "$FRESH/CONFIG.md"   # ONBOARDING Step 3a
backup restore "$FRESH"
assert_rc 0 "restore of a populated remote exits 0"
assert_out_contains "files verified" "restore reports the verification"
assert_true "restored the benchmark index" cmp -s "$WORK/benchmark/RESULTS.md" "$FRESH/benchmark/RESULTS.md"
assert_true "restored the logs" test -f "$FRESH/logs/events-2026-09-20.jsonl"
assert_true "restored no transient lock" test ! -e "$FRESH/benchmark/.run-lock"

new_case restore-empty-remote
new_remote; base_config "- work_repo: acme/widgets-state"
backup restore
assert_rc 2 "restore of an empty remote exits 2"

new_case restore-unreachable
base_config "- work_repo: acme/widgets-state"; REMOTE="$SANDBOX/does-not-exist.git"
backup restore
assert_rc 1 "restore of an unreachable remote exits 1"

new_case restore-no-work-repo
new_remote; base_config
backup restore
assert_rc 2 "restore without work_repo exits 2"

new_case persist-refuses-protected-delete
new_remote; seed_state
backup persist
rm -f "$WORK/audit/weeks/20260920T000000Z.json" "$WORK/MEMORY.md"
backup persist
assert_out_contains "refused" "persist refuses a snapshot that deletes protected records"
assert_true "the audit week stays on the remote" remote_has audit/weeks/20260920T000000Z.json
RC=0; OUT="$(WORK_DIR="$WORK" HOME="$FAKE_HOME" WORK_BACKUP_REMOTE="$REMOTE" \
  WORK_BACKUP_LOCAL="$SANDBOX/clone-allow" WORK_BACKUP_ALLOW_DELETE=1 \
  bash "$REPO_ROOT/scripts/work-backup.sh" persist 2>&1)"
assert_true "WORK_BACKUP_ALLOW_DELETE=1 lets the deletion through" eval '! remote_has audit/weeks/20260920T000000Z.json'

new_case persist-allows-prune
new_remote; seed_state
backup persist
rm -f "$WORK/reviews/pr-7.md" "$WORK/logs/events-2026-09-20.jsonl"
backup persist
assert_out_absent "refused" "a pruned PR file and an expired log are not protected"
assert_true "the pruned PR file left the remote" eval '! remote_has reviews/pr-7.md'

finish
