#!/usr/bin/env bash
# work-backup.sh — durable backup / restore of the NFS-resident work/ state to
# $GITHUB_REPO_WORK, performed ENTIRELY inside a private tmpfs clone so the
# shared work/ directory never has a .git mutated under concurrent runs. That
# concurrent .git rename-churn on the virtiofs-over-NFS home is the source of
# the "Stale file handle" (ESTALE) + .nfs* silly-rename failures. Details and
# rationale: docs/persistence.md.
#
#   work-backup.sh persist   # end of run: snapshot work/ -> commit -> push
#   work-backup.sh restore   # fresh volume: remote state -> work/ (data only)
#
# Durability model — nothing authoritative ever lives on tmpfs:
#   - live state      : work/ on the persistent home volume (survives restart)
#   - backup/history  : the $GITHUB_REPO_WORK remote (survives restart)
#   - tmpfs clone     : disposable scratch in /dev/shm, RAM-backed and WIPED on
#                       pod restart — so it is re-seeded from the remote on
#                       every call and never trusted to persist. Worst case (a
#                       restart between commit and push) loses only the not-yet
#                       -pushed snapshot; the data is still on work/ and the
#                       next run re-snapshots and pushes it.
# Concurrency is resolved at the remote: each pod backs up from its own tmpfs
# clone and pushes; a rejected (non-fast-forward) push re-seeds from the new
# remote tip and retries in-run. work/ files are only ever READ here (via tar),
# never renamed, so no ESTALE.
#
# Never fails the run: all error paths exit 0 (a missed backup is retried next
# run). Requires: git, tar, coreutils. Sources scripts/log.sh for events.
set -u

MODE="${1:-persist}"
WORK="${WORK_DIR:-${HOME:-/home/agent}/work}"
# tmpfs scratch; overridable for testing. /dev/shm is the pod's only truly
# local (non-virtiofs) filesystem.
LOCAL="${WORK_BACKUP_LOCAL:-/dev/shm/cg-work-backup}"
BRANCH="${WORK_BACKUP_BRANCH:-main}"
RETRIES="${WORK_BACKUP_RETRIES:-3}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_JOB="${LOG_JOB:-session}"
if ! . "$SCRIPT_DIR/log.sh" 2>/dev/null; then logev() { :; }; fi

say() { echo "work-backup: $*"; }

if [ -z "${GITHUB_REPO_WORK:-}" ]; then
  say "GITHUB_REPO_WORK unset — local-only, nothing to $MODE."
  exit 0
fi
if ! command -v git >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1; then
  say "git/tar unavailable — skipping $MODE."; logev warn work_backup "git/tar unavailable — $MODE skipped"; exit 0
fi

REMOTE_URL="${WORK_BACKUP_REMOTE:-https://github.com/$GITHUB_REPO_WORK}"

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
  ( cd "$WORK" && tar -c --exclude='./.git' --exclude='.nfs*' -f - . ) \
    | ( cd "$LOCAL" && tar -xf - ) || return 1
  return 0
}

persist() {
  local attempt=0 rc
  while [ "$attempt" -lt "$RETRIES" ]; do
    attempt=$((attempt + 1))
    seed_clone || { logev warn work_backup "seed failed (attempt $attempt)"; continue; }
    sync_in    || { logev warn work_backup "sync failed (attempt $attempt)"; continue; }
    ( cd "$LOCAL" || exit 1
      git add -A || exit 3
      if git diff --cached --quiet; then exit 42; fi   # nothing to persist
      git commit -q -m "chore(work): persist state $(date -u +%Y-%m-%dT%H:%M:%SZ)" || exit 3
    ); rc=$?
    if [ "$rc" -eq 42 ]; then say "nothing to persist."; return 0; fi
    if [ "$rc" -ne 0 ]; then logev warn work_backup "commit failed (attempt $attempt)"; continue; fi
    if ( cd "$LOCAL" && git push -q origin "HEAD:$BRANCH" 2>/dev/null ); then
      say "pushed (attempt $attempt)."; logev info work_backup "pushed work/ (attempt $attempt)"; return 0
    fi
    say "push rejected (attempt $attempt) — re-seeding from remote tip."
    logev warn work_backup "push rejected (attempt $attempt) — retrying"
  done
  say "push failed after $RETRIES attempt(s); state is safe on work/, retry next run."
  logev error work_backup "push failed after $RETRIES attempts — retry next run"
  return 0
}

restore() {
  seed_clone || { say "restore: could not reach remote — leaving work/ as-is."; logev warn work_backup "restore: remote unreachable"; return 0; }
  # copy data (never .git) from the local clone into work/. Restore targets a
  # fresh/empty volume; it does not delete pre-existing local files.
  if ( cd "$LOCAL" && git rev-parse HEAD >/dev/null 2>&1 ); then
    ( cd "$LOCAL" && tar -c --exclude='./.git' -f - . ) | ( cd "$WORK" && tar -xf - ) \
      && { say "restored work/ from remote."; logev info work_backup "restored work/ from remote"; } \
      || { say "restore copy failed."; logev warn work_backup "restore copy failed"; }
  else
    say "remote is empty — nothing to restore."
  fi
  return 0
}

mkdir -p "$WORK" 2>/dev/null || true
case "$MODE" in
  persist) persist ;;
  restore) restore ;;
  *) say "unknown mode '$MODE' (use persist|restore)"; exit 0 ;;
esac
