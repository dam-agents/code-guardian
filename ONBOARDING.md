# Onboarding — first-run initialization

This runbook bootstraps a fresh code-guardian agent. **Run it only once per agent
instance**, at initialization. It is self-guarding: the first successful pass writes
a sentinel file, and every later run is a no-op. All steps are idempotent — if
onboarding fails partway, it is **safe to re-run from the top**.

Two git repositories exist after onboarding, and they must never overlap:

| Path | Repo | Purpose |
| --- | --- | --- |
| `/home/agent` | the **definition repo** (`origin`) — derived in Step 0 from this file's URL | The agent's definition (`CLAUDE.md`, `ONBOARDING.md`, `README.md`, `LICENSE`). Edit + push back (via PR) to evolve the agent. |
| `/home/agent/work` | `$GITHUB_REPO_WORK` (when set) | The agent's **runtime state** (`CONFIG.md`, `MEMORY.md`, `REVIEWS.md`, `reviews/`). |

`work/` is **git-ignored by the outer repo** (see `.gitignore`), so the inner repo
is never an embedded/nested repo of the definition repo — they are fully independent.

## Guard — skip if already onboarded

```bash
if [ -f "$HOME/.code-guardian-onboarded" ]; then
  echo "Already onboarded ($(cat "$HOME/.code-guardian-onboarded")); skipping onboarding."
  exit 0
fi
```

If the sentinel exists, **stop here**. It lives in `$HOME`, which persists across
pod restarts, so onboarding runs once per persistent volume, not once per heartbeat.

First make sure git auth is routed through `gh` (idempotent — same helper used for
PR clones and for both repos, since both are on github.com):

```bash
git config --global --replace-all credential."https://github.com".helper "" \
  && git config --global --add credential."https://github.com".helper "!gh auth git-credential"
```

---

## Step 0 — Prerequisites & repository resolution

### 0.1 Sanity check the GitHub connection

```bash
gh api user --jq .login
```

This must succeed and prints the login the agent acts as (needed again in Step 4).
If it fails, **stop**: tell the operator the GitHub connection/token is not working
and nothing can proceed until it is — don't attempt the remaining steps.

### 0.2 Derive the definition repo from this file's URL

You were given this runbook as a URL, e.g.
`https://github.com/OWNER/REPO/blob/main/ONBOARDING.md` (or its
`raw.githubusercontent.com/OWNER/REPO/main/ONBOARDING.md` form). The **definition
repo is that `OWNER/REPO`** — for a fork, that's the fork, never upstream. Derive
it from the URL; if you somehow don't have the URL (e.g. the file was pasted as
text), ask the operator which repo it came from. Validate and keep it for the rest
of the run:

```bash
gh api "repos/<owner/repo>" --jq .full_name   # must succeed
export DEFINITION_REPO="<owner/repo>"
```

It is persisted as `definition_repo` in `work/CONFIG.md` in Step 4 — it drives the
outer-repo `origin` (Step 1), future definition PRs, and the review footer link.

### 0.3 Resolve `GITHUB_REPO` (ask if unset)

```bash
echo "${GITHUB_REPO:-<unset>}"
```

- **Set** → continue.
- **Unset** → ask the operator:

  > Which GitHub repository should I review? Please give me the `owner/repo` slug
  > (e.g. `acme/widgets`).

  Validate the answer (`gh api "repos/<owner/repo>" --jq .full_name`; on failure,
  say what failed and ask again — never continue with an unvalidated slug), then
  `export GITHUB_REPO="<owner/repo>"` for this session. The durable copy is written
  to `work/CONFIG.md` as `github_repo:` in Step 4 (the env var, when later set on
  the platform — still the recommended setup — always wins over the stored value;
  see `CLAUDE.md` → **Load configuration once per run**).

### 0.4 Durable state (`GITHUB_REPO_WORK`) — inform, don't block

```bash
echo "${GITHUB_REPO_WORK:-<unset>}"
```

If unset, tell the operator once:

> `GITHUB_REPO_WORK` is not set, so my state (config, memory, review history) will
> live only on this volume. For durable, versioned state, create an empty repo and
> set `GITHUB_REPO_WORK=<owner/repo>` before onboarding. Should I continue
> local-only, or do you want to set it first?

If they want to set it, stop and let them re-trigger onboarding afterwards. If they
say continue — or don't reply — proceed local-only.

## Step 1 — Make `/home/agent` the definition repo (safely, at HOME root)

`/home/agent` is the agent's `$HOME`: it holds secrets and runtime dirs (`.ssh`,
`.claude`, `.config`, `work/`, …). We want a real git repo here so the agent can
edit its own definition and push it back to `$DEFINITION_REPO` — **without** git
ever tracking those secrets. The `.gitignore` in this repo is an *allowlist* (`/*`
ignores everything, then specific files are re-included), which is what makes a
repo-at-`$HOME` safe.

Establish the repo in place (do **not** `git clone` into `$HOME` — clone needs an
empty dir; instead init + fetch + hard-reset, which never touches untracked files):

```bash
cd /home/agent

if [ ! -d /home/agent/.git ]; then
  git init -q
  git remote add origin "https://github.com/$DEFINITION_REPO.git"
else
  git remote set-url origin "https://github.com/$DEFINITION_REPO.git"
fi
git fetch -q origin main
git reset --hard origin/main      # syncs tracked files (CLAUDE.md, etc.) to the definition repo's main
git branch --set-upstream-to=origin/main main 2>/dev/null || true
```

> **NEVER run `git clean` in `/home/agent`** and never `git add` un-allowlisted paths
> — both could capture or delete `.ssh`, `.claude`, `work/`, etc. `git reset --hard`
> only rewrites *tracked* files and leaves untracked HOME contents alone, which is
> why it is safe here. The allowlist `.gitignore` keeps `git status` / `git add -A`
> scoped to the definition files.

## Step 2 — Detach `work/` from the outer repo (locally)

The definition repo still tracks the `work/` seed files (`MEMORY.md`, `REVIEWS.md`)
— that keeps the repo self-documenting and its in-repo links valid. But on this
volume `work/` is runtime state managed independently (Step 3), so the outer repo
must stop *reacting* to changes under it:

```bash
cd /home/agent
# 1. Ignore local modifications to the tracked seed files.
git update-index --skip-worktree work/MEMORY.md work/REVIEWS.md 2>/dev/null || true
# 2. The committed allowlist .gitignore (`/*`) already ignores every *untracked*
#    path under work/ and all HOME secrets. Verify:
git status --porcelain
```

`git status` must show a **clean** outer tree — nothing under `work/`, `.ssh`,
`.claude`, or `.config`. If anything there appears, **stop and fix it before
continuing**; do not write the sentinel.

> Why `--skip-worktree` instead of `git rm --cached`: `rm --cached` would stage a
> deletion of `work/` that a later definition commit could accidentally push.
> `--skip-worktree` leaves the index untouched.

## Step 3 — Provision `work/` (runtime state)

`work/` holds `CONFIG.md`, `MEMORY.md`, `REVIEWS.md`, and `reviews/`.

### 3a — `GITHUB_REPO_WORK` IS set → clone it as the inner repo

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
  # MEMORY.md is NOT reconstructable — keep the seed scaffold Step 1 checked out.
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

1. **`github_repo`** — write it **only if Step 0.3 had to ask** (no `$GITHUB_REPO`
   env var): the validated slug. Omit the key when the env var is set — the env var
   is authoritative and a stored copy would only drift.

2. **`definition_repo`** — always write the value derived in Step 0.2.

3. **`bot_login`** — the login from Step 0.1 (`gh api user --jq .login`). Confirm it
   with the operator and say the consequence out loud:

   > I'll act as GitHub user **<login>** — reviews will be posted and signed by this
   > account, and assigning it to a PR requests a visual artifact. If this is a
   > personal account, consider a dedicated machine/bot account instead.

4. **`bot_display_name`** — ask:

   > What name should I sign my reviews with? (Default: `Code Guardian`.)

5. **`review_marker`** — the identity prefix of the hidden dedup marker
   (`<!-- <review_marker> headRefOid=<sha> -->`) embedded in every posted review.
   Default: `code-guardian:review`. Ask:

   > Has this agent (or a predecessor bot) already posted reviews on the target
   > repo? If yes, give me the exact marker prefix it used — reusing it keeps the
   > old reviews visible to deduplication. If no, I'll use `code-guardian:review`.

   ⚠️ **This value is immutable once the first review has been posted** — changing
   it later makes every past review invisible to dedup and the agent would
   re-review every open PR. Say this to the operator when confirming the value.

6. **Review skills (`## Review skills` table) and `artifact_skill`** — fully
   config-driven (see `CLAUDE.md` → **Per-PR Review Skills**). **Each skill carries
   its own `source`**: `harness` (provided by the platform) or an `owner/repo` the
   skill installs from (`.agents/skills/<skill>/` on `main`). Present the default
   public set and let the operator adjust (add their own skills, remove rows,
   change triggers or sources):

   ```markdown
   ## Review skills

   | skill | source | trigger | section |
   | --- | --- | --- | --- |
   | doc-drift | dam-agents/dam | always | Documentation Check (doc-drift) |
   | typescript-engineering | harness | .ts,.mts,.cts,.js,.mjs,.cjs | TypeScript Engineering Review |
   | react-ui-engineering | harness | .tsx,.jsx | React UI Engineering Review |
   ```

   And the artifact skill default (format `<skill>@<owner/repo>`, or `none`):

   ```markdown
   - artifact_skill: pr-artifact@dam-agents/dam
   ```

   **Validate every row before writing:**
   - **Repo-sourced rows (and the artifact skill):** the skill must exist at its
     source — `gh api "repos/<source>/contents/.agents/skills/<skill>"`. If missing
     or unreachable, tell the operator and let them fix the row or drop it.
   - **Harness rows:** the skill must actually be present in your available-skills
     list. If it isn't (this platform doesn't provide it), tell the operator and
     drop the row after confirmation — a configured-but-missing harness skill would
     just log `skill-errored` on every PR.
   - The operator may end up with an empty table and `artifact_skill: none` — valid;
     the agent then does plain reviews only.

7. **`slack_notifications`** — Slack delivery (the **PR Shepherd** reviewer
   nudging — see `CLAUDE.md` → **PR Shepherd: reviewer nudging via Slack**) is
   strictly **opt-in**. Ask:

   > Do you want Slack notifications? When enabled, I watch how long each open PR
   > waits for human review and nudge reviewers/authors in the shared Slack
   > channel, escalating over time. It needs a Slack connection and a developer
   > roster — I'll walk you through building one.

   - **"No" — or no reply in this session** → `slack_notifications: disabled`.
     Everything else works normally; only the PR Shepherd sweep is skipped. The
     operator can enable it later in chat — then re-run just this sub-step (ask,
     update `CONFIG.md`, build the roster below, pick the escalation owner).
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
- definition_repo: acme/code-guardian
- bot_login: acme-review-bot
- bot_display_name: Code Guardian
- review_marker: code-guardian:review
- artifact_skill: pr-artifact@dam-agents/dam   # or: none
- slack_notifications: enabled         # or: disabled
- escalation_owner: alice              # only when slack_notifications: enabled

## Review skills

| skill | source | trigger | section |
| --- | --- | --- | --- |
| doc-drift | dam-agents/dam | always | Documentation Check (doc-drift) |
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
long-term memory (`MEMORY.md`)**. Skip this step entirely when `$GITHUB_REPO_WORK`
is set (Step 3a already hydrated the state).

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
   (tag those `[from PR comments]`).

The result lets the agent skip already-reviewed SHAs correctly on the very first
heartbeat, with only `MEMORY.md` starting fresh. `work/` here is a plain directory
(no inner `.git`); end-of-run persistence (CLAUDE.md step 8) is skipped.

## Step 6 — Ensure a scheduled review job exists

Ask the operator how often reviews should run:

> How often should I check for new PRs? Default is every 10 minutes.

Use the answer as `<cadence>` below (default `*/10 * * * *`).

1. Call **`mcp__platform-outbound__list_schedules`** (no arguments).
2. If a schedule whose `name` starts with `code-guardian-review` already exists,
   do nothing.
3. Otherwise call **`mcp__platform-outbound__create_schedule`** with:
   - `name`: `code-guardian-review-<cadence-shorthand>` (e.g. `code-guardian-review-10m`)
   - `cron`: the chosen cadence
   - `sessionMode`: `fresh`
   - `task`:
     > Code-review heartbeat. Run the full code-guardian review pipeline exactly as
     > described in CLAUDE.md: load work/CONFIG.md, refresh the configured skills,
     > read work/MEMORY.md and work/REVIEWS.md, review every new or updated open
     > non-draft PR in the configured target repository, and deliver each review to
     > the chat UI and the GitHub PR thread. Honour the HEAD-freshness guards and
     > in-progress locks. When GITHUB_REPO_WORK is set, commit and push work/ at
     > the end of the run per CLAUDE.md.

Other schedule MCP tools if needed: `mcp__platform-outbound__toggle_schedule`,
`mcp__platform-outbound__delete_schedule`. Do not use any in-process cron tool —
only these platform schedules survive process restarts and are visible to the
operator.

## Step 7 — Write the sentinel and report

Only after Steps 1–6 succeeded:

```bash
date -u +%Y-%m-%dT%H:%M:%SZ > "$HOME/.code-guardian-onboarded"
echo "Onboarding complete."
```

Then give the operator a short **onboarding summary** in the chat UI:

1. The final `work/CONFIG.md` content (verbatim).
2. What runs where: target repo, review cadence, state persistence
   (`GITHUB_REPO_WORK` or local-only), Slack on/off.
3. How to use the agent day-to-day:
   - Reviews land automatically on every open non-draft PR (chat UI + GitHub).
   - **Visual artifact:** assign **`<bot_login>`** to a PR — the next heartbeat
     generates and links it (only when `artifact_skill` is configured).
   - **Feedback:** dismiss findings or set preferences by just saying so in chat —
     global feedback lands in `MEMORY.md`, PR-specific in that PR's overrides.
   - **Config changes:** ask in chat any time (e.g. enabling Slack later) — only
     `review_marker` is immutable once reviews exist.

From now on the guard at the top short-circuits, and normal runs follow `CLAUDE.md`.
