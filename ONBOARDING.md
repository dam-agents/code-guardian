# Onboarding — first-run initialization

This runbook bootstraps a fresh code-guardian agent. **Run it only once per agent
instance**, at initialization. It is self-guarding: the first successful pass writes
a sentinel file, and every later run is a no-op.

Two git repositories exist after onboarding, and they must never overlap:

| Path | Repo | Purpose |
| --- | --- | --- |
| `/home/agent` | `dam-agents/code-guardian` (`origin`) | The agent's **definition** (`CLAUDE.md`, `ONBOARDING.md`, `README.md`). Edit + push back to evolve the agent. |
| `/home/agent/work` | `$GITHUB_REPO_WORK` (when set) | The agent's **runtime state** (`MEMORY.md`, `REVIEWS.md`, `reviews/`). |

`work/` is **git-ignored by the outer repo** (see `.gitignore`), so the inner repo
is never an embedded/nested repo of code-guardian — they are fully independent.

## Guard — skip if already onboarded

```bash
if [ -f "$HOME/.code-guardian-onboarded" ]; then
  echo "Already onboarded ($(cat "$HOME/.code-guardian-onboarded")); skipping onboarding."
  exit 0
fi
```

If the sentinel exists, **stop here**. It lives in `$HOME`, which persists across
pod restarts, so onboarding runs once per persistent volume (once per real agent
instance), not once per heartbeat.

First make sure git auth is routed through `gh` (idempotent — same helper used for
PR clones and for both repos, since both are on github.com):

```bash
git config --global --replace-all credential."https://github.com".helper "" \
  && git config --global --add credential."https://github.com".helper "!gh auth git-credential"
```

---

## Step 1 — Make `/home/agent` the code-guardian repo (safely, at HOME root)

`/home/agent` is the agent's `$HOME`: it holds secrets and runtime dirs (`.ssh`,
`.claude`, `.config`, `work/`, …). We want a real git repo here so the agent can
edit its own definition and push it back to `dam-agents/code-guardian` — **without**
git ever tracking those secrets. The `.gitignore` in this repo is an *allowlist*
(`/*` ignores everything, then specific files are re-included), which is what makes
a repo-at-`$HOME` safe.

Establish the repo in place (do **not** `git clone` into `$HOME` — clone needs an
empty dir; instead init + fetch + hard-reset, which never touches untracked files):

```bash
REPO="dam-agents/code-guardian"
cd /home/agent

if [ ! -d /home/agent/.git ]; then
  git init -q
  git remote add origin "https://github.com/$REPO.git"
fi
git fetch -q origin main
git reset --hard origin/main      # syncs tracked files (CLAUDE.md, etc.) to canonical main
git branch --set-upstream-to=origin/main main 2>/dev/null || true
```

> **NEVER run `git clean` in `/home/agent`** and never `git add` un-allowlisted paths
> — both could capture or delete `.ssh`, `.claude`, `work/`, etc. `git reset --hard`
> only rewrites *tracked* files and leaves untracked HOME contents alone, which is
> why it is safe here. The allowlist `.gitignore` keeps `git status` / `git add -A`
> scoped to the four definition files.

## Step 2 — Detach `work/` from the outer repo (locally)

The canonical code-guardian repo still tracks the `work/` seed files (`MEMORY.md`,
`REVIEWS.md`) — that keeps the repo self-documenting and its in-repo links valid.
But on this volume `work/` is runtime state managed independently (Step 3), so the
outer repo must stop *reacting* to changes under it. Two mechanisms, both local and
neither of which stages a deletion (so they can never leak into a definition commit):

```bash
cd /home/agent
# 1. Tell git to ignore local modifications to the tracked seed files.
git update-index --skip-worktree work/MEMORY.md work/REVIEWS.md 2>/dev/null || true
# 2. The committed allowlist .gitignore (`/*`) already ignores every *untracked*
#    path under work/ (reviews/, an inner .git, etc.) and all HOME secrets. Verify:
git status --porcelain
```

`git status` must show a **clean** outer tree — nothing under `work/`, `.ssh`,
`.claude`, or `.config`. If anything there appears, the allowlist `.gitignore` is
wrong (or skip-worktree didn't take) — **stop and fix it before continuing**; do not
write the sentinel.

> Why `--skip-worktree` instead of `git rm --cached`: `rm --cached` would stage a
> deletion of `work/` in the outer index, which a later definition commit could
> accidentally push (re-removing the seeds and breaking the repo's links).
> `--skip-worktree` leaves the index untouched and simply makes git ignore local
> edits to those tracked files.

## Step 3 — Provision `work/` (runtime state)

`work/` holds `MEMORY.md`, `REVIEWS.md`, and `reviews/`. How it is provisioned
depends on whether a dedicated state repo is configured.

### 3a — `GITHUB_REPO_WORK` IS set → clone it as the inner repo

Replace `work/` with a fresh clone so the agent starts from the latest committed
state and so end-of-run commit/push works (see `CLAUDE.md` → **Persisting `work/`
to `GITHUB_REPO_WORK`**):

```bash
if [ -n "$GITHUB_REPO_WORK" ]; then
  tmp="$(mktemp -d)"
  if git clone "https://github.com/$GITHUB_REPO_WORK" "$tmp/work"; then
    rm -rf /home/agent/work
    mv "$tmp/work" /home/agent/work            # work/ now has its own .git + remote
    git -C /home/agent/work config user.name  "code-guardian"
    git -C /home/agent/work config user.email "code-guardian@dam-agents.local"
    echo "work/ hydrated from $GITHUB_REPO_WORK"
  else
    echo "WARNING: clone of $GITHUB_REPO_WORK failed; falling back to reconstruction (3b)."
    rm -rf "$tmp"
  fi
fi
```

### 3b — `GITHUB_REPO_WORK` is NOT set → reconstruct state from `$GITHUB_REPO`

Everything needed to reconstruct review-tracking state already lives on the target
repo itself: each posted DAM review carries a `<!-- dam:review headRefOid=... -->`
marker plus a verdict and a timestamp. Rebuild `work/` from those — **everything is
recoverable except long-term memory (`MEMORY.md`)**, which is learned preferences,
not derivable from PRs.

```bash
if [ -z "$GITHUB_REPO_WORK" ]; then
  mkdir -p /home/agent/work/reviews
  # MEMORY.md is NOT reconstructable. Step 1 already checked out the repo's seed
  # scaffold (default strictness, focus areas, empty Ignore/Custom/Feedback
  # sections) into work/MEMORY.md — keep it as the starting point. Only create an
  # empty file if the seed is somehow missing.
  [ -f /home/agent/work/MEMORY.md ] || : > /home/agent/work/MEMORY.md
fi
```

Then reconstruct the index and per-PR history (this is the same logic CLAUDE.md uses
to self-heal after PVC loss — see **Deduplication via GitHub PR reviews** and the
self-heal notes in **Review Tracking**):

1. List open PRs: `gh pr list --repo "$GITHUB_REPO" --state open --json number`.
2. For each PR, fetch its DAM reviews/comments and read the latest one's
   `headRefOid` marker, verdict, and `submitted_at`/`createdAt` timestamp.
3. Write one `REVIEWS.md` row per PR — `| <number> | <headRefOid> | <submitted_at> | <verdict> | done |` —
   using the **GitHub-reported** timestamp (history, not "now"). PRs with no DAM
   review get no row (they'll be reviewed on the next heartbeat).
4. Recreate `reviews/pr-<number>.md` from the review body where one exists. Do **not**
   fabricate bodies for reviews that GitHub doesn't have. Leave `## PR-local
   overrides` empty unless the PR thread contains an explicit dispute resolution
   (those are recoverable from comments; tag them `[from PR comments]`).

The result is a `work/` that lets the agent skip already-reviewed SHAs correctly on
the very first heartbeat, with only `MEMORY.md` starting fresh. Note `work/` here is
a plain directory (no inner `.git`); nothing is pushed anywhere, and end-of-run
persistence (CLAUDE.md step 8) is skipped because `$GITHUB_REPO_WORK` is unset.

## Step 4 — Ensure a scheduled review job exists (every 10 minutes)

1. Call **`mcp__platform-outbound__list_schedules`** (no arguments).
2. If a schedule with `cron` = `*/10 * * * *` **or** `name` = `code-guardian-review-10m`
   already exists, do nothing.
3. Otherwise call **`mcp__platform-outbound__create_schedule`** with:
   - `name`: `code-guardian-review-10m`
   - `cron`: `*/10 * * * *`
   - `sessionMode`: `fresh`
   - `task`:
     > Code-review heartbeat. Run the full code-guardian review pipeline exactly as
     > described in CLAUDE.md: refresh the doc-drift skill, read work/MEMORY.md and
     > work/REVIEWS.md, review every new or updated open non-draft PR in $GITHUB_REPO,
     > and deliver each review to the chat UI and the GitHub PR thread. Honour
     > the HEAD-freshness guards and in-progress locks. When GITHUB_REPO_WORK is set,
     > commit and push work/ at the end of the run per CLAUDE.md.

Other schedule MCP tools if needed: `mcp__platform-outbound__toggle_schedule`
(enable/disable by `id`), `mcp__platform-outbound__delete_schedule` (remove by `id`).
Do not use any in-process cron tool — only these platform schedules survive process
restarts and are visible to the human operator.

## Step 5 — Write the sentinel

Only after Steps 1–4 succeeded:

```bash
date -u +%Y-%m-%dT%H:%M:%SZ > "$HOME/.code-guardian-onboarded"
echo "Onboarding complete."
```

From now on the guard at the top short-circuits, and normal runs follow `CLAUDE.md`.
