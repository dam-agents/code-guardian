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
(`git reset --hard "origin/$DEF_BRANCH"`) from ever colliding with live runtime
state.
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

## Tracked branch

`definition_branch` in `work/CONFIG.md` (missing = `main`) is the branch of
`$DEFINITION_REPO` this instance follows — **the update source, the base of
definition PRs, and the branch `/home/agent` stays on**. Use it wherever a
branch name is needed; never hard-code `main`:

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

Definition changes (`CLAUDE.md`, `docs/`, `scripts/`, `ONBOARDING.md`,
`README.md`, `VERSION`, `CHANGELOG.md`) go through **branch + PR on
`$DEFINITION_REPO` — never a direct push to the tracked branch, never
auto-merge**, and only when deliberately asked — never as part of a heartbeat.
The base is always `definition_branch` (**Tracked branch** above):

```bash
git -C /home/agent fetch origin "$DEF_BRANCH"
git -C /home/agent checkout -b "fix/<short-slug>" "origin/$DEF_BRANCH"
git -C /home/agent add -- CLAUDE.md ONBOARDING.md README.md VERSION CHANGELOG.md .gitignore LICENSE docs scripts
git -C /home/agent commit -m "<describe the change>"
git -C /home/agent push -u origin "fix/<short-slug>"
gh pr create --repo "$DEFINITION_REPO" --base "$DEF_BRANCH" --head "fix/<short-slug>" \
  --title "<title>" --body "<what and why>"
```

After the PR merges, return the checkout to the tracked branch (**Tracked
branch** above) so the next run isn't left on a feature branch.

The agent's job ends at "PR opened". Use fresh descriptive branch names;
runtime state never goes to this repo.
