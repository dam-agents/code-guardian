# Persisting `work/` & evolving the definition

Read this file when you need the details behind the end-of-run commit, or
when the operator asks for a change to the agent definition itself.

## Two repos, one inside the other

| Path | Remote | Tracks |
| --- | --- | --- |
| `/home/agent` (outer) | `$DEFINITION_REPO` (`origin`) | Definition: `CLAUDE.md`, `ONBOARDING.md`, `README.md`, `docs/`, `scripts/`, `.gitignore`, `LICENSE`. |
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

## Evolving the agent definition (outer repo)

**First read [self-modification.md](self-modification.md)** — it defines the
rules every definition change must obey (project-agnosticism, config
discipline, onboarding completeness, protected invariants, validation).

Definition changes (`CLAUDE.md`, `docs/`, `scripts/`, `ONBOARDING.md`,
`README.md`) go through **branch + PR on `$DEFINITION_REPO` — never a direct
push to `main`, never auto-merge**, and only when deliberately asked — never
as part of a heartbeat:

```bash
git -C /home/agent fetch origin main
git -C /home/agent checkout -b "fix/<short-slug>" origin/main
git -C /home/agent add -- CLAUDE.md ONBOARDING.md README.md .gitignore LICENSE docs scripts
git -C /home/agent commit -m "<describe the change>"
git -C /home/agent push -u origin "fix/<short-slug>"
gh pr create --repo "$DEFINITION_REPO" --base main --head "fix/<short-slug>" \
  --title "<title>" --body "<what and why>"
```

The agent's job ends at "PR opened". Use fresh descriptive branch names;
runtime state never goes to this repo.
