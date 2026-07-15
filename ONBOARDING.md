# Onboarding — first-run initialization

This runbook bootstraps a fresh code-guardian agent. **Run it only once per agent
instance**, at initialization. It is self-guarding: the first successful pass writes
a sentinel file, and every later run is a no-op.

Two git repositories exist after onboarding, and they must never overlap:

| Path | Repo | Purpose |
| --- | --- | --- |
| `/home/agent` | `dam-agents/code-guardian` (`origin`) | The agent's **definition** (`CLAUDE.md`, `ONBOARDING.md`, `README.md`). Edit + push back to evolve the agent. |
| `/home/agent/work` | `$GITHUB_REPO_WORK` (when set) | The agent's **runtime state** (`CONFIG.md`, `MEMORY.md`, `REVIEWS.md`, `reviews/`). |

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

## Step 0 — Resolve `GITHUB_REPO` (ask if unset)

Everything below (and every review run) needs to know which repository to review.
Check the environment first:

```bash
echo "${GITHUB_REPO:-<unset>}"
```

- **Set** → nothing to do, continue to Step 1.
- **Unset** → ask the operator in the chat UI **before doing anything else**:

  > Which GitHub repository should I review? Please give me the `owner/repo` slug
  > (e.g. `acme/widgets`).

  Then, with the operator's answer:

  1. **Validate it** — the slug must exist and be reachable with the current token:

     ```bash
     gh api "repos/<owner/repo>" --jq .full_name
     ```

     If this fails (404, no access), tell the operator what failed and ask again.
     Do not continue with an unvalidated slug.
  2. **Set it for this session** so the rest of this runbook (Steps 4, 5) and
     the rest of this run can use `$GITHUB_REPO` normally:

     ```bash
     export GITHUB_REPO="<owner/repo>"
     ```

  3. **Persist it** — an exported variable dies with the session, and the agent
     cannot set platform environment variables itself. The durable copy goes into
     `work/CONFIG.md` as `github_repo: <owner/repo>` — but `work/` is not
     provisioned yet at this point, so **remember the value and write it in
     Step 4** (which creates `CONFIG.md` anyway). Runtime resolution order is:
     `$GITHUB_REPO` env var → `github_repo` in `work/CONFIG.md` → `gh repo view`
     fallback (see `CLAUDE.md` → **Load configuration once per run**), so the
     env var — if the operator later sets it on the platform, which is still
     the recommended setup — always wins over the stored value.

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

`work/` holds `CONFIG.md`, `MEMORY.md`, `REVIEWS.md`, and `reviews/`. How it is
provisioned depends on whether a dedicated state repo is configured.

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
    git -C /home/agent/work config user.email "code-guardian@agents.local"
    echo "work/ hydrated from $GITHUB_REPO_WORK"
  else
    echo "WARNING: clone of $GITHUB_REPO_WORK failed; falling back to local-only provisioning (3b)."
    rm -rf "$tmp"
  fi
fi
```

### 3b — `GITHUB_REPO_WORK` is NOT set → start from the local seeds

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

Review-tracking state (`REVIEWS.md`, `reviews/`) is **reconstructed from the target
repo in Step 5** — it needs the `review_marker` from `work/CONFIG.md`, which Step 4
creates first.

## Step 4 — Configure the agent (`work/CONFIG.md`, interactive)

The agent definition is **project-agnostic**: every instance-specific value lives in
`work/CONFIG.md`. The exact semantics of every key are documented in `CLAUDE.md` →
**Runtime configuration: `work/CONFIG.md`** — read that section before this step.
Gather each value below (some auto-detected, some asked in the chat UI), then write
the file.

**Re-onboarding note:** if Step 3a hydrated `work/` from `$GITHUB_REPO_WORK` and a
`CONFIG.md` already exists there, **keep its values** — only ask for keys that are
missing. Never silently overwrite operator-set configuration (especially
`review_marker` — see below).

1. **`github_repo`** — write it **only if Step 0 had to ask** (no `$GITHUB_REPO`
   env var): the validated slug from Step 0. Omit the key when the env var is set —
   the env var is authoritative and a stored copy would only drift.

2. **`bot_login`** — auto-detect the GitHub account this agent acts as:

   ```bash
   gh api user --jq .login
   ```

   Show it to the operator for confirmation — this is the login humans will assign
   to a PR to request a visual artifact, and the login excluded from "independent
   reviewer" classification.

3. **`bot_display_name`** — ask:

   > What name should I sign my reviews with? (Default: `Code Guardian`.)

4. **`review_marker`** — the identity prefix of the hidden dedup marker
   (`<!-- <review_marker> headRefOid=<sha> -->`) embedded in every posted review.
   Default: `code-guardian:review`. Ask:

   > Has this agent (or a predecessor bot) already posted reviews on the target
   > repo? If yes, give me the exact marker prefix it used — reusing it keeps the
   > old reviews visible to deduplication. If no, I'll use `code-guardian:review`.

   ⚠️ **This value is immutable once the first review has been posted** — changing
   it later makes every past review invisible to dedup and the agent would
   re-review every open PR. Say this to the operator when confirming the value.

5. **`skills_repo`** — ask:

   > Do you have a skills repository — an `owner/repo` that hosts
   > `.agents/skills/doc-drift/` and `.agents/skills/pr-artifact/` on `main`?
   > It powers the per-PR Documentation Check and the visual PR artifact. Answer
   > `none` to run without those two features.

   When a slug is given, validate it:

   ```bash
   gh api "repos/<owner/repo>/contents/.agents/skills" --jq '.[].name'
   ```

   If the path is missing or unreachable, tell the operator and ask again (or
   accept `none`). Write `skills_repo: none` explicitly when declined.

6. **Review skills (`## Review skills` table) and `artifact_skill`** — the
   per-PR review skills and the visual-artifact skill are fully config-driven
   (see `CLAUDE.md` → **Per-PR Review Skills** for the exact table semantics:
   `skill` / `source` / `trigger` / `section`, ordering = routing priority +
   section order). **Default to the current public set** — present this table
   to the operator and let them adjust (add rows for their own skills, remove
   rows, change triggers); most operators keep the default:

   ```markdown
   ## Review skills

   | skill | source | trigger | section |
   | --- | --- | --- | --- |
   | doc-drift | skills_repo | always | Documentation Check (doc-drift) |
   | typescript-engineering | harness | .ts,.mts,.cts,.js,.mjs,.cjs | TypeScript Engineering Review |
   | react-ui-engineering | harness | .tsx,.jsx | React UI Engineering Review |
   ```

   And the artifact skill default:

   ```markdown
   - artifact_skill: pr-artifact
   ```

   Consistency rules to enforce before writing:
   - When `skills_repo` is `none`, drop every `source: skills_repo` row from
     the default table (with the default set that removes `doc-drift`) and set
     `artifact_skill: none` — those skills have no install source.
   - For every remaining `source: skills_repo` skill (including
     `artifact_skill`), verify it exists in the skills repo:
     `gh api "repos/$SKILLS_REPO/contents/.agents/skills/<skill>"`. If missing,
     tell the operator and let them fix the row or drop it.
   - `source: harness` rows are kept as-is — they need no validation here (the
     harness provides them; if one is genuinely unavailable at runtime, the
     per-PR loop logs it as `skill-errored`).

7. **`slack_notifications`** — Slack delivery (the **PR Shepherd** reviewer
   nudging — see `CLAUDE.md` → **PR Shepherd: reviewer nudging via Slack**) is
   strictly **opt-in**. Ask:

   > Do you want Slack notifications? When enabled, I watch how long each open PR
   > waits for human review and nudge reviewers/authors in the shared Slack
   > channel, escalating over time. It needs a Slack connection and a developer
   > roster — I'll walk you through building one.

   - **"No" — or no reply in this session** → `slack_notifications: disabled`.
     Everything else (reviews, artifacts, pruning) works normally; only the PR
     Shepherd sweep is skipped. The operator can enable it later by saying so in
     chat — then re-run just this sub-step (ask, update `CONFIG.md`, build the
     roster below, pick the escalation owner).
   - **"Yes"** → `slack_notifications: enabled`, then build the developer roster
     and pick the escalation owner (below) before continuing.

8. **`escalation_owner`** (only when Slack is enabled) — after the roster is built,
   ask:

   > Who should I escalate to when a PR stays unreviewed despite repeated
   > reminders (nudge level 4)? Pick one person from the roster.

   The answer must be a roster login **with a `slack_id`**. Write
   `escalation_owner: <login>`.

Then write `work/CONFIG.md` and show the final content to the operator:

```markdown
# Configuration

- github_repo: acme/widgets            # only when the env var was unset
- bot_login: acme-review-bot
- bot_display_name: Code Guardian
- review_marker: code-guardian:review
- skills_repo: acme/agent-skills       # or: none
- artifact_skill: pr-artifact          # or: none
- slack_notifications: enabled         # or: disabled
- escalation_owner: alice              # only when slack_notifications: enabled

## Review skills

| skill | source | trigger | section |
| --- | --- | --- | --- |
| doc-drift | skills_repo | always | Documentation Check (doc-drift) |
| typescript-engineering | harness | .ts,.mts,.cts,.js,.mjs,.cjs | TypeScript Engineering Review |
| react-ui-engineering | harness | .tsx,.jsx | React UI Engineering Review |
```

### Build the developer roster (`work/DEVELOPERS.md`) — only when Slack is enabled

The roster is the **only** set of people the agent may ever @-mention in Slack
(hard invariant — see `CLAUDE.md` → **Roster-only tagging**), so it must be seeded
now. Goal: one row per team member with GitHub `login`, Slack member id
(`slack_id`), display name, and a few seed expertise keywords.

1. **Fetch the team from GitHub.** Prefer an org team — the cleanest
   "whole project team" source:

   ```bash
   ORG="${GITHUB_REPO%%/*}"
   gh api "orgs/$ORG/teams" --jq '.[] | "\(.slug)\t\(.name)"'   # list teams
   ```

   Show the list and ask the operator which team to import, then fetch its members:

   ```bash
   gh api "orgs/$ORG/teams/<slug>/members?per_page=100" --jq '.[].login'
   ```

   **Fallback** — no org, no teams, or the calls 404 (user-owned repo, missing
   org scope): use the repository's top contributors instead:

   ```bash
   gh api "repos/$GITHUB_REPO/contributors?per_page=15" --jq '.[].login'
   ```

   Either way, show the resulting logins and let the operator remove anyone who
   doesn't belong (bots, one-off external contributors) or add missing logins.

2. **Draft the roster.** For each confirmed login, fetch the display name
   (`gh api "users/<login>" --jq '.name // .login'`) and seed a handful of
   expertise keywords from their recent activity in `$GITHUB_REPO` (titles and
   changed paths of their last few merged PRs). Rough is fine — the agent
   appends "Observed areas" automatically over time; only the operator edits
   seed expertise. Present the draft table in the chat UI.

3. **Ask for Slack member IDs.** These cannot be resolved automatically (the
   outbound Slack tool only sends messages, and GitHub emails are usually
   noreply). Ask the operator to paste one line per member:

   ```
   <login> = U0123ABCD
   ```

   Slack member IDs are found in Slack: open the person's profile → **⋮ (More)**
   → **Copy member ID**. Validate each id against `^U[A-Z0-9]{6,}$`. A member
   without a Slack id may stay in the roster (they can be named in plain text)
   but must never be @-mentioned.

4. **Write `work/DEVELOPERS.md`:**

   ```markdown
   # Developers roster

   _The only people the agent may @-mention in Slack (CLAUDE.md → PR Shepherd).
   Seed expertise is operator-provided — never overwrite or remove it; "Observed
   areas" are appended automatically by the agent._

   | login | slack_id | name | expertise (seed) | observed areas |
   | --- | --- | --- | --- | --- |
   | alice | U0123ABCD | Alice K. | frontend, react, accessibility | |
   ```

5. Confirm the result to the operator: how many members were imported and how
   many of them have a Slack id. Then return to Step 4's item 8 (pick the
   escalation owner).

## Step 5 — Reconstruct review state from `$GITHUB_REPO` (only when `GITHUB_REPO_WORK` is unset)

When `work/` is not backed by a state repo, everything needed to reconstruct
review-tracking state already lives on the target repo itself: each posted agent
review carries a `<!-- <review_marker> headRefOid=... -->` marker (using the
`review_marker` just written to `work/CONFIG.md`) plus a verdict and a timestamp.
Rebuild the tracking files from those — **everything is recoverable except
long-term memory (`MEMORY.md`)**, which is learned preferences, not derivable from
PRs. Skip this step entirely when `$GITHUB_REPO_WORK` is set (Step 3a already
hydrated the state).

1. List open PRs: `gh pr list --repo "$GITHUB_REPO" --state open --json number`.
2. For each PR, fetch its reviews/comments, filter to those whose body contains
   the `<review_marker>` marker, and read the latest one's `headRefOid`, verdict,
   and `submitted_at`/`createdAt` timestamp.
3. Write one `REVIEWS.md` row per PR — `| <number> | <headRefOid> | <submitted_at> | <verdict> | done |` —
   using the **GitHub-reported** timestamp (history, not "now"). PRs with no agent
   review get no row (they'll be reviewed on the next heartbeat).
4. Recreate `reviews/pr-<number>.md` from the review body where one exists. Do **not**
   fabricate bodies for reviews that GitHub doesn't have. Leave `## PR-local
   overrides` empty unless the PR thread contains an explicit dispute resolution
   (those are recoverable from comments; tag them `[from PR comments]`).

The result is a `work/` that lets the agent skip already-reviewed SHAs correctly on
the very first heartbeat, with only `MEMORY.md` starting fresh. Note `work/` here is
a plain directory (no inner `.git`); nothing is pushed anywhere, and end-of-run
persistence (CLAUDE.md step 8) is skipped because `$GITHUB_REPO_WORK` is unset.

## Step 6 — Ensure a scheduled review job exists (every 10 minutes)

1. Call **`mcp__platform-outbound__list_schedules`** (no arguments).
2. If a schedule with `cron` = `*/10 * * * *` **or** `name` = `code-guardian-review-10m`
   already exists, do nothing.
3. Otherwise call **`mcp__platform-outbound__create_schedule`** with:
   - `name`: `code-guardian-review-10m`
   - `cron`: `*/10 * * * *`
   - `sessionMode`: `fresh`
   - `task`:
     > Code-review heartbeat. Run the full code-guardian review pipeline exactly as
     > described in CLAUDE.md: load work/CONFIG.md, refresh the configured skills,
     > read work/MEMORY.md and work/REVIEWS.md, review every new or updated open
     > non-draft PR in the configured target repository, and deliver each review to
     > the chat UI and the GitHub PR thread. Honour the HEAD-freshness guards and
     > in-progress locks. When GITHUB_REPO_WORK is set, commit and push work/ at
     > the end of the run per CLAUDE.md.

Other schedule MCP tools if needed: `mcp__platform-outbound__toggle_schedule`
(enable/disable by `id`), `mcp__platform-outbound__delete_schedule` (remove by `id`).
Do not use any in-process cron tool — only these platform schedules survive process
restarts and are visible to the human operator.

## Step 7 — Write the sentinel

Only after Steps 1–6 succeeded:

```bash
date -u +%Y-%m-%dT%H:%M:%SZ > "$HOME/.code-guardian-onboarded"
echo "Onboarding complete."
```

From now on the guard at the top short-circuits, and normal runs follow `CLAUDE.md`.
