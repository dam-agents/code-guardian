# Persisting `work/` & evolving the definition

Read this file when you need the details behind the end-of-run commit, when
the operator asks to update the agent or check its version, or when the
operator asks for a change to the agent definition itself.

## Two repos, one inside the other

| Path | Remote | Tracks |
| --- | --- | --- |
| `/home/agent` (outer) | `$DEFINITION_REPO` (`origin`) | Definition: `CLAUDE.md`, `ONBOARDING.md`, `README.md`, `docs/`, `scripts/`, `VERSION`, `CHANGELOG.md`, `.gitignore`, `LICENSE`. |
| `/home/agent/work` (inner) | `$GITHUB_REPO_WORK` | Runtime state. Exists as a repo only when the var is set. |

The outer `.gitignore` is an allowlist (`/*` then re-include the definition
files), so **all** of `work/` and the HOME secrets (`.ssh`, `.claude`,
`.config`) are invisible to the outer repo — nothing under `work/` is tracked.
A fresh volume seeds `work/MEMORY.md` and `work/REVIEWS.md` from the templates in
`ONBOARDING.md` (Step 3b); this keeps a definition update
(`git reset --hard origin/main`) from ever colliding with live runtime state.
Scope commands: inner state →
`git -C /home/agent/work`, definition → `git -C /home/agent`.
**Never run `git clean` in `/home/agent`** and never `git add` outside the
allowlist.

## Commit & push (end of run)

`scripts/preflight.sh` never commits or pushes — its local bookkeeping
(`awaiting_label` flips, shepherd table updates, log lines) sits uncommitted
until the next agent-active run. At the end of every run where the agent did
work, it commits & pushes as the very last action (this sweeps up the
script's bookkeeping too; quiet heartbeats stay durable on the volume until
then):

```bash
if [ -n "$GITHUB_REPO_WORK" ] && [ -d /home/agent/work/.git ]; then
  cd /home/agent/work || exit 1
  git config user.name  "code-guardian" 2>/dev/null || true
  git config user.email "code-guardian@agents.local" 2>/dev/null || true
  git add -A
  if git diff --cached --quiet; then
    echo "work/: nothing to persist."
  else
    git commit -m "chore(work): persist review state $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    git pull --rebase --autostash origin "$(git rev-parse --abbrev-ref HEAD)" \
      && git push origin "$(git rev-parse --abbrev-ref HEAD)" \
      || echo "WARNING: work/ push failed; committed locally, retry next run."
  fi
fi
```

Never force-push; a lost race or failed push is retried next run and is not
a run failure.

## Definition version & upgrade

`VERSION` (repo root, one line, semver) identifies the definition;
`work/VERSION` records the version this instance last adopted (missing =
treat as `1.0.0`, the version that introduced versioning). Scheduled runs
never touch versioning — everything here happens **in the direct session
only**, in exactly three situations:

- the operator asks to update the agent (or asks whether it is up to date),
- **always as the first step of any self-modification**
  (self-modification.md → section 8),
- the operator explicitly asks for a version/migration check.

**Version check:**

```bash
git -C /home/agent fetch -q origin main
git -C /home/agent show origin/main:VERSION 2>/dev/null | head -1   # latest
head -1 /home/agent/VERSION                                         # checked out
head -1 /home/agent/work/VERSION 2>/dev/null                        # adopted
```

- checked-out < latest → **tell the operator the agent is not up to date**
  (state both versions); update only when they ask — never silently.
- adopted ≠ checked-out → an update was pulled but its migration never ran →
  apply the migration (below) now.
- all three equal → report "up to date", done.

**Updating** (on the operator's request; never from a heartbeat):

```bash
git -C /home/agent reset --hard origin/main
```

(never `git clean` — CLAUDE.md → Hard invariants), then apply the migration
immediately in the same session.

**Applying the migration** (`from` = adopted version, `to` = checked-out):

1. Read `CHANGELOG.md`; collect the **Upgrade** blocks of every version
   greater than `from` and up to `to`, oldest first.
2. Apply them in order. Steps are idempotent (check before create), so a
   partially applied earlier attempt is safe to re-run. A step marked
   operator-only is not guessed at — surface it and continue with the rest.
3. Only after every applicable step succeeded, write `to` into
   `work/VERSION` (one line) and log
   `definition upgraded <from> → <to> (<n> step(s) applied)`. A failed
   step: log it, leave `work/VERSION` unchanged (the next check re-offers
   the migration), and tell the operator what failed.
4. `to` older than `from` (rollback) → apply nothing; just write `to`.

Then commit & push `work/` (the end-of-run persist above) so
`work/VERSION` is backed up like any other state file.

## Evolving the agent definition (outer repo)

**First read [self-modification.md](self-modification.md)** — it defines the
rules every definition change must obey (project-agnosticism, config
discipline, onboarding completeness, protected invariants, validation).

Definition changes (`CLAUDE.md`, `docs/`, `scripts/`, `ONBOARDING.md`,
`README.md`, `VERSION`, `CHANGELOG.md`) go through **branch + PR on
`$DEFINITION_REPO` — never a direct push to `main`, never auto-merge**, and
only when deliberately asked — never as part of a heartbeat. Every change
bumps `VERSION` and adds its `CHANGELOG.md` entry
(self-modification.md → **Versioning & changelog**):

```bash
git -C /home/agent fetch origin main
git -C /home/agent checkout -b "fix/<short-slug>" origin/main
git -C /home/agent add -- CLAUDE.md ONBOARDING.md README.md VERSION CHANGELOG.md .gitignore LICENSE docs scripts
git -C /home/agent commit -m "<describe the change>"
git -C /home/agent push -u origin "fix/<short-slug>"
gh pr create --repo "$DEFINITION_REPO" --base main --head "fix/<short-slug>" \
  --title "<title>" --body "<what and why>"
```

The agent's job ends at "PR opened". Use fresh descriptive branch names;
runtime state never goes to this repo.
