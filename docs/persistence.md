# Persisting `work/` & evolving the definition

Read this file when you need the details behind the end-of-run commit, when
the operator asks to update the agent or check its version, or when the
operator asks for a change to the agent definition itself.

## Two stores: shared live state + durable backup

| Path | Kind | Holds |
| --- | --- | --- |
| `/home/agent` (outer) | git repo, remote `$DEFINITION_REPO` (`origin`) | Definition: `CLAUDE.md`, `AGENTS.md`, `ONBOARDING.md`, `README.md`, `docs/`, `scripts/`, `VERSION`, `CHANGELOG.md`, `.gitignore`, `.github/`, `LICENSE`. |
| `/home/agent/work` | **plain data directory** (no `.git`) | Live runtime state (`CONFIG.md`, `MEMORY.md`, `REVIEWS.md`, `reviews/`, `logs/`, ledgers). Shared across concurrent runs; the source of truth. |
| `$GITHUB_REPO_WORK` | git remote | Durable, versioned **backup** of `work/`. Written only via a disposable tmpfs clone (below). |

`work/` is **not** a git repo. The home volume is virtiofs over a host NFS
export, and a `.git` there — rewritten by every commit while another concurrent
run holds a ref open — is what produces `Stale file handle` (ESTALE) and
`.nfs*` silly-rename corruption. So all git plumbing happens off the shared
volume, in a private per-pod tmpfs clone under `/dev/shm`; `work/` itself is
only ever read.

The outer `.gitignore` is an allowlist (`/*` then re-include the definition
files), so **all** of `work/` and the HOME secrets (`.ssh`, `.claude`,
`.config`) are invisible to the outer repo — nothing under `work/` is tracked.
A fresh volume seeds `work/` from the templates in `ONBOARDING.md` (Step 3b) or
restores it from the backup remote; a definition update
(`git reset --hard "origin/$DEF_BRANCH"`) never collides with live runtime
state. **Never run `git clean` in `/home/agent`** and never `git add` outside
the allowlist (the `work/` backup's `git add -A` is confined to the tmpfs clone,
never the home tree).

## Backup & restore (`scripts/work-backup.sh`)

`scripts/preflight.sh` never commits or pushes — its local bookkeeping
(`awaiting_label` flips, shepherd table updates, log lines) is written straight
to the `work/` files and stays on the volume until backed up. At the end of
every run where the agent did work, it runs — as the very last action, only
when `$GITHUB_REPO_WORK` is set:

```bash
LOG_JOB=<mode> bash "$HOME/scripts/work-backup.sh" persist
```

The script (full rationale in its header) snapshots the current `work/` files
into a **disposable tmpfs clone**, commits, and pushes — re-seeding that clone
from the remote on every call so a wiped tmpfs (RAM-backed, gone on pod
restart) never matters. Nothing authoritative lives on tmpfs: the live state is
`work/` (persistent), the history is the remote (persistent). Concurrency is
resolved at the remote — a rejected non-fast-forward push re-seeds from the new
tip and retries in-run; `work/` (all pods write the same files) is authoritative
and every push converges to it. Within one pod, concurrent sessions share the
clone, so the persist step itself is serialized by a mkdir lock next to it
(lock-or-skip: a skipped persist is safe — the running one snapshots the same
shared `work/` moments later, and the next run sweeps up any remainder). Never
force-push; a push that fails all retries
is logged and retried next run — not a run failure, because the data is safe on
`work/`.

`restore` is the inverse — remote → `work/` (data only, never a `.git`) — run
once on a fresh volume when the templates aren't enough (`ONBOARDING.md`
Step 3a).

## Tracked branch

`definition_branch` in `work/CONFIG.md` (missing = `main`) is the branch of
`$DEFINITION_REPO` **this instance runs from** — its update source and the branch
`/home/agent` stays on. It is a deployment choice, per agent.

It is **not** a repo-wide convention: `main` remains the repository's development
branch and release history — the base of every definition PR (**Evolving the agent
definition** below) and the changelog that only grows
([self-modification.md](self-modification.md) §12). Use `DEF_BRANCH` for "where
does this instance's code come from", `main` for "how does the repo evolve".

```bash
DEF_BRANCH="$(cfg definition_branch)"; DEF_BRANCH="${DEF_BRANCH:-main}"
```

**Staying on it.** The audit's `definition_version` check warns when the
checkout sits on a different branch. Switching is a **direct-session** action
(never a heartbeat) and must not destroy work:

```bash
git -C /home/agent status --porcelain          # must be empty; otherwise stop and ask
git -C /home/agent fetch -q origin "$DEF_BRANCH"
git -C /home/agent checkout "$DEF_BRANCH" 2>/dev/null \
  || git -C /home/agent checkout -b "$DEF_BRANCH" "origin/$DEF_BRANCH"
git -C /home/agent reset --hard "origin/$DEF_BRANCH"     # never `git clean`
git -C /home/agent branch --set-upstream-to="origin/$DEF_BRANCH" "$DEF_BRANCH" 2>/dev/null || true
```

Uncommitted changes or an unmerged local branch → **stop and surface it**; a
switch never discards unpushed work. A missing remote branch is reported to the
operator, not created. Working on a definition PR legitimately parks the
checkout on a feature branch — that warn is expected until the PR merges.
Changing the key itself is operator-only, and a version check follows it (the
new branch may carry a different `VERSION`).

## Definition version & upgrade

`VERSION` (repo root, one line, semver) identifies the definition;
`work/VERSION` is the version this instance last adopted (missing =
`1.0.0`). Heartbeats never touch versioning (the weekly audit only
*reports* drift — its `definition_version` check); acting happens **in the
direct session only**: an operator-requested update or version check, and
always before any self-modification (self-modification.md §8).

**Check:**

```bash
git -C /home/agent fetch -q origin "$DEF_BRANCH"
git -C /home/agent show "origin/$DEF_BRANCH:VERSION" 2>/dev/null | head -1  # latest
head -1 /home/agent/VERSION                                                 # checked out
head -1 /home/agent/work/VERSION 2>/dev/null                                # adopted
```

Checked-out < latest → **tell the operator the agent is not up to date**
(state both versions); update only when they ask, never silently —
`git -C /home/agent reset --hard "origin/$DEF_BRANCH"` (never `git clean`), then
migrate in the same session. Adopted ≠ checked-out → migrate now. All
equal → report "up to date".

**Migration** (`from` = adopted, `to` = checked-out):

1. Apply the `CHANGELOG.md` **Upgrade** blocks of every version in
   `(from, to]`, oldest first. Steps are idempotent (check before create),
   so re-running a partial attempt is safe; an operator-only step is
   surfaced, never guessed at.
2. Only after every applicable step succeeded, write `to` into
   `work/VERSION` and log `definition upgraded <from> → <to> (<n> step(s))`.
   A failed step: log + tell the operator, leave `work/VERSION` unchanged
   (re-offered at the next check).
3. Rollback (`to` < `from`) → apply nothing; just write `to`.

Commit & push `work/` afterwards (section above).

## Evolving the agent definition (outer repo)

**First read [self-modification.md](self-modification.md)** — it defines the
rules every definition change must obey (project-agnosticism, config
discipline, onboarding completeness, protected invariants, validation).

Definition changes (`CLAUDE.md`, `docs/`, `scripts/`, `.agents/`,
`ONBOARDING.md`, `README.md`, `VERSION`, `CHANGELOG.md`) go through **branch + PR on
`$DEFINITION_REPO` — never a direct push to `main`, never auto-merge**, and only
when deliberately asked — never as part of a heartbeat. **`main` is the
repository's development branch and the base of every definition PR**, whatever
`definition_branch` a given instance runs:

```bash
git -C /home/agent fetch origin main
git -C /home/agent checkout -b "fix/<short-slug>" origin/main
git -C /home/agent add -- CLAUDE.md AGENTS.md ONBOARDING.md README.md VERSION CHANGELOG.md .gitignore LICENSE docs scripts .agents .github
git -C /home/agent commit -m "<describe the change>"
git -C /home/agent push -u origin "fix/<short-slug>"
gh pr create --repo "$DEF_HOST/$DEFINITION_REPO" --base main --head "fix/<short-slug>" \
  --title "<title>" --body "<what and why>"
```

The definition repo may sit on a different GitHub host than the target repo, so
**every definition-repo call names its host** — `-R "$DEF_HOST/$DEFINITION_REPO"`
for `gh pr`/`gh issue`, `--hostname "$DEF_HOST"` for `gh api` (CLAUDE.md →
**Runtime configuration**). The outer-repo `origin` URL already carries it, so
plain `git fetch`/`push` need nothing extra.

After the PR merges, return the checkout to this instance's `definition_branch`
(**Tracked branch** above) so the next run isn't left on a feature branch.

The agent's job ends at "PR opened". Use fresh descriptive branch names;
runtime state never goes to this repo.
