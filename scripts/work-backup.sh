#!/usr/bin/env bash
# work-backup.sh — durable backup / restore of the NFS-resident work/ state to
# the `work_repo` of work/CONFIG.md, performed ENTIRELY inside a private tmpfs
# clone so the shared work/ directory never has a .git mutated under concurrent
# runs. That concurrent .git rename-churn on the virtiofs-over-NFS home is the
# source of the "Stale file handle" (ESTALE) + .nfs* silly-rename failures.
# Details and rationale: docs/persistence.md.
#
#   work-backup.sh persist   # end of run: snapshot work/ -> commit -> push
#   work-backup.sh restore   # fresh volume: remote state -> work/ (data only)
#
# Pod-local transient files (mkdir locks, *.tmp, the benchmark run lock) are
# never carried in either direction; logs and every other work/ file are.
# A persist that would delete an append-only or unreconstructable record
# (PROTECTED below) is refused: that shape means work/ was never hydrated, and
# pushing it would move the backup tip past the history. An operator-intended
# deletion passes with WORK_BACKUP_ALLOW_DELETE=1.
#
# Durability model — nothing authoritative ever lives on tmpfs:
#   - live state      : work/ on the persistent home volume (survives restart)
#   - backup/history  : the `work_repo` remote (survives restart)
#   - tmpfs clone     : disposable scratch in /dev/shm, RAM-backed and WIPED on
#                       pod restart — so it is re-seeded from the remote on
#                       every call and never trusted to persist. Worst case (a
#                       restart between commit and push) loses only the not-yet
#                       -pushed snapshot; the data is still on work/ and the
#                       next run re-snapshots and pushes it.
# Concurrency: reviews stay fully parallel — only the backup step itself is
# serialized. Concurrent sessions in one pod share this clone, so persist takes
# a mkdir lock next to it (lock-or-skip: finding a fresh lock means another
# persist is running — skip; it snapshots the same shared work/ moments later,
# and the next run sweeps up any remainder. Stale locks from crashed runs
# expire by TTL). Across pods, concurrency is resolved at the remote: a
# rejected (non-fast-forward) push re-seeds from the new remote tip and retries
# in-run. work/ files are only ever READ here (via tar), never renamed, so no
# ESTALE.
#
# persist never fails the run: all its paths exit 0 (a missed backup is retried
# next run). restore reports its outcome by exit code for onboarding:
#   0 restored, every tracked file verified in work/ · 2 nothing to restore
#   (no work_repo, or an empty remote) · 1 failed (unreachable, copy error, or
#   a file that did not arrive intact).
# Requires: git, tar, coreutils. Sources scripts/log.sh for events.
set -u

MODE="${1:-persist}"
WORK="${WORK_DIR:-${HOME:-/home/agent}/work}"
# tmpfs scratch; overridable for testing. /dev/shm is the pod's only truly
# local (non-virtiofs) filesystem.
LOCAL="${WORK_BACKUP_LOCAL:-/dev/shm/cg-work-backup}"
BRANCH="${WORK_BACKUP_BRANCH:-main}"
RETRIES="${WORK_BACKUP_RETRIES:-3}"
LOCK="$LOCAL.lock"                                # sibling of the clone, tmpfs too
LOCK_TTL_MIN="${WORK_BACKUP_LOCK_TTL_MIN:-10}"    # a persist takes seconds

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_JOB="${LOG_JOB:-session}"
if ! . "$SCRIPT_DIR/log.sh" 2>/dev/null; then logev() { :; }; fi

say() { echo "work-backup: $*"; }

# The backup remote is `work_repo` in work/CONFIG.md — the same reader every
# other script uses (docs/config.md). Missing key = local-only persistence.
CONFIG="$WORK/CONFIG.md"
cfg() { sed -n "s/^- $1:[[:space:]]*//p" "$CONFIG" 2>/dev/null | head -1 \
        | sed -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//' \
              -e 's/^[`"'"'"']//' -e 's/[`"'"'"']$//'; }
WORK_REPO="$(cfg work_repo)"

# restore's exit code is its outcome (header); persist always exits 0
end() { [ "$MODE" = restore ] && exit "$1"; exit 0; }

if [ -z "$WORK_REPO" ]; then
  say "no work_repo in work/CONFIG.md — local-only, nothing to $MODE."
  end 2
fi
if ! command -v git >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1; then
  say "git/tar unavailable — skipping $MODE."; logev warn work_backup "git/tar unavailable — $MODE skipped"; end 1
fi

# Never carried either way: pod-local transient state. Mirrored by SKIP_RE for
# the restore verification, which walks git's file list instead of tar's.
EXCLUDES=(--exclude='./.git' --exclude='.nfs*' --exclude='*.lock' --exclude='*.tmp' --exclude='./benchmark/.run-lock')
SKIP_RE='(^|/)\.nfs|\.lock(/|$)|\.tmp$|^benchmark/\.run-lock$'
# Append-only or unreconstructable records a persist may never delete
PROTECTED="CONFIG.md MEMORY.md LESSONS.md REVIEW-LEDGER.jsonl audit/weeks benchmark/RESULTS.md benchmark/results"

# work_repo is `[<host>/]<owner>/<repo>`: three segments name the host, two use
# the ambient default (docs/config.md)
case "$WORK_REPO" in
  (*/*/*) WORK_REF="$WORK_REPO";;
  (*)     WORK_REF="${GH_HOST:-github.com}/$WORK_REPO";;
esac
REMOTE_URL="${WORK_BACKUP_REMOTE:-https://$WORK_REF}"

# (Re)seed a usable clone in $LOCAL from the durable remote. tmpfs may be empty
# (fresh pod), stale, or a half-written clone (interrupted run) — validate and
# re-clone defensively so a wiped tmpfs never breaks us. Returns 1 only if we
# could neither clone nor init.
seed_clone() {
  if ! ( cd "$LOCAL" 2>/dev/null && git rev-parse --git-dir >/dev/null 2>&1 ); then
    rm -rf "$LOCAL" 2>/dev/null || true
    if ! git clone -q "$REMOTE_URL" "$LOCAL" 2>/dev/null; then
      # empty/nonexistent remote (first-ever backup): start a fresh repo
      rm -rf "$LOCAL" 2>/dev/null || true
      mkdir -p "$LOCAL" || return 1
      ( cd "$LOCAL" && git init -q && git remote add origin "$REMOTE_URL" ) || return 1
    fi
  fi
  ( cd "$LOCAL" || exit 1
    git config user.name  "code-guardian"        2>/dev/null || true
    git config user.email "code-guardian@agents.local" 2>/dev/null || true
    # move onto the latest remote tip when it exists; otherwise a new branch
    if git fetch -q origin "$BRANCH" 2>/dev/null; then
      git checkout -q -B "$BRANCH" FETCH_HEAD 2>/dev/null
    else
      git checkout -q -B "$BRANCH" 2>/dev/null || true
    fi
  ) || return 1
  return 0
}

# Mirror work/ into the local worktree (deletions included): wipe everything but
# .git, then lay down the current work/ state. tar keeps this a pure READ of the
# NFS files — git never renames them, so no ESTALE on work/.
sync_in() {
  find "$LOCAL" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} + 2>/dev/null || true
  ( cd "$WORK" && tar -c "${EXCLUDES[@]}" -f - . ) \
    | ( cd "$LOCAL" && tar -xf - ) || return 1
  return 0
}

# Serialize access to the shared clone $LOCAL (concurrent sessions share it, and
# two writers over one clone would race: checkout -B and the worktree wipe land
# under each other's git add). mkdir is atomic even on tmpfs/NFS; the lock dir's
# mtime is the last-progress time, refreshed each attempt, so a crashed run
# expires by TTL. HELD guards release so we only ever remove OUR lock (never a
# lock another session acquired after we skipped/released).
HELD=0
acquire_lock() {
  if mkdir "$LOCK" 2>/dev/null; then HELD=1; return 0; fi
  # Stale takeover must be atomic — a plain rm+mkdir lets two concurrent
  # stealers both "win" (each rm's the other's fresh lock). rename IS atomic:
  # of two `mv` on the same source, only the first succeeds (the source is gone
  # for the second), so exactly one stealer claims it.
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin "+$LOCK_TTL_MIN" 2>/dev/null)" ]; then
    local dead="$LOCK.stale.$$"
    if mv "$LOCK" "$dead" 2>/dev/null; then
      rm -rf "$dead" 2>/dev/null
      if mkdir "$LOCK" 2>/dev/null; then
        HELD=1
        say "stole a stale persist lock (>${LOCK_TTL_MIN}m — crashed persist)."
        logev warn work_backup "stale persist lock stolen"
        return 0
      fi
    fi
  fi
  return 1
}
release_lock() { [ "$HELD" = 1 ] && rm -rf "$LOCK" 2>/dev/null; HELD=0; return 0; }
# safety net: release on unexpected exit/signal (kill mid-run would otherwise
# leave the lock until TTL; a pod restart wipes tmpfs anyway). Idempotent via HELD.
trap 'release_lock' EXIT
trap 'exit' INT TERM

persist() {
  local rc
  if ! acquire_lock; then
    say "another persist is running — skipping; state stays on work/ and the next run backs it up."
    logev info work_backup "persist skipped — concurrent persist holds the lock"
    return 0
  fi
  do_persist; rc=$?
  release_lock
  return "$rc"
}

do_persist() {
  local attempt=0 rc
  while [ "$attempt" -lt "$RETRIES" ]; do
    attempt=$((attempt + 1))
    touch "$LOCK" 2>/dev/null || true   # refresh mtime: a slow run must not look stale
    seed_clone || { logev warn work_backup "seed failed (attempt $attempt)"; continue; }
    sync_in    || { logev warn work_backup "sync failed (attempt $attempt)"; continue; }
    ( cd "$LOCAL" || exit 1
      git add -A || exit 3
      if git diff --cached --quiet; then exit 42; fi   # nothing to persist
      if [ "${WORK_BACKUP_ALLOW_DELETE:-0}" != 1 ]; then
        # shellcheck disable=SC2086 # PROTECTED is a path list by design
        gone="$(git diff --cached -M --diff-filter=D --name-only -- $PROTECTED | head -5 | tr '\n' ' ')"
        [ -n "$gone" ] && { printf '%s' "$gone" > "$LOCAL.refused"; git reset -q --hard; exit 43; }
      fi
      git commit -q -m "chore(work): persist state $(date -u +%Y-%m-%dT%H:%M:%SZ)" || exit 3
    ); rc=$?
    if [ "$rc" -eq 42 ]; then say "nothing to persist."; return 0; fi
    if [ "$rc" -eq 43 ]; then
      gone="$(cat "$LOCAL.refused" 2>/dev/null)"; rm -f "$LOCAL.refused"
      say "refused: the snapshot deletes protected records (${gone% }) — work/ looks unhydrated; restore it first (docs/persistence.md → Backup & restore)."
      logev error work_backup "persist refused — snapshot deletes protected records: ${gone% }"
      return 0
    fi
    if [ "$rc" -ne 0 ]; then logev warn work_backup "commit failed (attempt $attempt)"; continue; fi
    if ( cd "$LOCAL" && git push -q origin "HEAD:$BRANCH" 2>/dev/null ); then
      say "pushed (attempt $attempt)."; logev info work_backup "pushed work/ (attempt $attempt)"; return 0
    fi
    say "push rejected (attempt $attempt) — re-seeding from remote tip."
    logev warn work_backup "push rejected (attempt $attempt) — retrying"
  done
  say "push failed after $RETRIES attempt(s) to $WORK_REF; state is safe on work/, retry next run."
  logev error work_backup "push to $WORK_REF failed after $RETRIES attempts — retry next run"
  return 0
}

restore() {
  # restore also drives $LOCAL, so serialize against a concurrent persist. It is
  # mandatory (onboarding), so wait briefly, then proceed best-effort rather than
  # skip — in practice it runs on a fresh volume before any schedule exists.
  local w=0 rc=0 n=0 bad=0 f
  while ! acquire_lock; do
    w=$((w + 1)); [ "$w" -ge 5 ] && { logev warn work_backup "restore proceeding without lock after wait"; break; }
    sleep 1
  done
  # seed_clone falls back to `git init` when it cannot clone, which would read
  # as an empty remote here — so reachability is probed first
  if ! git ls-remote -q "$REMOTE_URL" >/dev/null 2>&1 || ! seed_clone; then
    say "restore: could not reach remote — leaving work/ as-is."; logev warn work_backup "restore: remote unreachable"; release_lock; return 1
  fi
  # copy data into work/ — never .git, never transient state, and never
  # historical .nfs* junk a pre-2.0.0 layout may have committed. Restore
  # targets a fresh/empty volume; it does not delete pre-existing local files.
  if ( cd "$LOCAL" && git rev-parse HEAD >/dev/null 2>&1 ); then
    if ( cd "$LOCAL" && tar -c "${EXCLUDES[@]}" -f - . ) | ( cd "$WORK" && tar -xf - ); then
      # verify: every tracked file arrived byte-identical
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        n=$((n + 1)); cmp -s "$LOCAL/$f" "$WORK/$f" || bad=$((bad + 1))
      done <<EOF
$(cd "$LOCAL" && git -c core.quotepath=off ls-files | grep -Ev "$SKIP_RE")
EOF
      if [ "$bad" -eq 0 ]; then
        say "restored work/ from remote ($n files verified)."; logev info work_backup "restored work/ from remote ($n files verified)"
      else
        say "restore incomplete: $bad of $n files differ from the remote."; logev error work_backup "restore incomplete: $bad of $n files differ"; rc=1
      fi
    else
      say "restore copy failed."; logev warn work_backup "restore copy failed"; rc=1
    fi
  else
    say "remote is empty — nothing to restore."; rc=2
  fi
  release_lock
  return "$rc"
}

mkdir -p "$WORK" 2>/dev/null || true
case "$MODE" in
  persist) persist ;;
  restore) restore; exit $? ;;
  *) say "unknown mode '$MODE' (use persist|restore)"; exit 0 ;;
esac
