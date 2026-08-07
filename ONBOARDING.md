# Onboarding — first-run initialization

Bootstraps a fresh code-guardian agent, **once per agent instance**. Self-guarding via a sentinel; all steps are idempotent, so a failed run is safe to re-run from the top.

Two git repositories exist after onboarding and must never overlap:

| Path | Repo | Purpose |
| --- | --- | --- |
| `/home/agent` | the **definition repo** (`origin`) — derived in Step 0 from this file's URL | Agent definition (`CLAUDE.md`, `docs/`, `scripts/`, `ONBOARDING.md`, `README.md`, `LICENSE`). Evolved via PRs. |
| `/home/agent/work` | **plain data directory** (not a repo); backed up to `$GITHUB_REPO_WORK` when set | Runtime state (`CONFIG.md`, `MEMORY.md`, `REVIEWS.md`, `reviews/`). |

`work/` is git-ignored by the outer repo (allowlist `.gitignore`) and holds no `.git` of its own — backup runs off-volume via a tmpfs clone (`docs/persistence.md` → **Backup & restore**), so the two stay fully independent.

## Guard — skip if already onboarded

```bash
if [ -f "$HOME/.code-guardian-onboarded" ]; then
  echo "Already onboarded ($(cat "$HOME/.code-guardian-onboarded")); skipping onboarding."
  exit 0
fi
```

Sentinel exists → **stop here**. It lives in persistent `$HOME`, so onboarding runs once per volume, not per heartbeat.

Then route git auth through `gh` (idempotent; used for all github.com repos):

```bash
git config --global --replace-all credential."https://github.com".helper "" \
  && git config --global --add credential."https://github.com".helper "!gh auth git-credential"
```

## Step 0 — Prerequisites & repository resolution

1. **Sanity check:** `gh api user --jq .login` must succeed (it prints the bot login, needed in Step 4). If it fails, **stop** and tell the operator the GitHub connection/token is broken — nothing else can proceed.

   Then verify the preconditions the pipeline silently depends on — the weekly audit re-checks both (`token_scopes`, `cli_deps`):

   ```bash
   gh api user -i 2>/dev/null | sed -n 's/^[Xx]-[Oo][Aa]uth-[Ss]copes:[[:space:]]*//p'   # want: repo, gist
   for c in gh jq git sed grep cut tr date find; do command -v "$c" >/dev/null || echo "MISSING: $c"; done
   ```

   A missing **scope** is **operator-only** — report it and ask them to widen the token, don't work around it; which scopes are required and what each is for is in README → **Token scopes** (the optional one only affects the roster import below). A missing **command** blocks onboarding: report and stop. Installing OS packages is not possible on the pod (no package manager, no sudo, read-only prefixes) — `awk`, `diff`, and a login-shell `python3` are deliberately **not** required anywhere in this definition; keep it that way.
2. **Definition repo & branch** — derive `OWNER/REPO` **and the branch** from the URL of this runbook as given by the operator (`https://github.com/OWNER/REPO/blob/<branch>/ONBOARDING.md` or its raw form); for a fork that's the fork, never upstream. No URL available → ask. Validate (`gh api "repos/<owner/repo>" --jq .full_name`) and `export DEFINITION_REPO="<owner/repo>"`. Then `export DEF_BRANCH="<branch from the URL, else main>"` and validate it exists (`gh api "repos/$DEFINITION_REPO/branches/$DEF_BRANCH" --jq .name`) — invalid → say so and ask, never fall back silently. Persisted as `definition_repo` + `definition_branch` in Step 4; they drive the outer-repo `origin`, updates, definition PRs, and the review footer.
3. **`GITHUB_REPO`** — if the env var is unset, ask:

   > Which GitHub repository should I review? Please give me the `owner/repo` slug (e.g. `acme/widgets`).

   Validate the answer the same way (on failure explain and ask again — never continue unvalidated), then `export GITHUB_REPO=…` for this session. The durable copy goes to `work/CONFIG.md` (`github_repo:`) in Step 4; the env var, when later set on the platform (still the recommended setup), always wins.
4. **`GITHUB_REPO_WORK`** — if unset, inform once, don't block:

   > `GITHUB_REPO_WORK` is not set, so my state (config, memory, review history) will live only on this volume. For durable, versioned state, create an empty repo and set `GITHUB_REPO_WORK=<owner/repo>` before onboarding. Should I continue local-only, or do you want to set it first?

   "Set it first" → stop and let them re-trigger onboarding. Otherwise (or no reply) → proceed local-only.

## Step 1 — Make `/home/agent` the definition repo (safely, at HOME root)

`/home/agent` is `$HOME` — it holds secrets (`.ssh`, `.claude`, `.config`) and `work/`. The repo's allowlist `.gitignore` (`/*`, then re-include only the definition files) is what makes a repo-at-`$HOME` safe. Do **not** `git clone` into `$HOME` (needs an empty dir) — init + fetch + hard-reset instead, which never touches untracked files:

`$DEF_BRANCH` is the branch **this instance runs from** — the one in the runbook URL the operator gave you, or `main`. It is persisted as `definition_branch` in Step 4 and used for updates and for keeping the checkout in place (docs/persistence.md → **Tracked branch**); definition PRs are still based on `main`:

```bash
cd /home/agent
export DEF_BRANCH="${DEF_BRANCH:-main}"
if [ ! -d /home/agent/.git ]; then
  git init -q
  git remote add origin "https://github.com/$DEFINITION_REPO.git"
else
  git remote set-url origin "https://github.com/$DEFINITION_REPO.git"
fi
git fetch -q origin "$DEF_BRANCH" || { echo "branch '$DEF_BRANCH' not found on $DEFINITION_REPO"; exit 1; }
git checkout -q -B "$DEF_BRANCH" "origin/$DEF_BRANCH"
git reset --hard "origin/$DEF_BRANCH"
git branch --set-upstream-to="origin/$DEF_BRANCH" "$DEF_BRANCH" 2>/dev/null || true
```

> **NEVER run `git clean` in `/home/agent`** and never `git add` un-allowlisted paths — either could capture or delete `.ssh`, `.claude`, `work/`, etc.

## Step 1b — Harness adapter (tool-call logging, completion enforcement)

Register the harness hooks — failed tool calls and per-run token usage into the
structured events log, plus the `Stop` hook that refuses a stop leaving a review
mid-pipeline ([docs/logging.md](docs/logging.md) → **Harness adapters**):

```bash
bash "$HOME/scripts/harness/claude-code/install.sh"
```

Idempotent; on a non-Claude-Code harness it prints a notice and exits 0 —
the agent then logs tool failures manually per docs/logging.md.

## Step 2 — Confirm `work/` is invisible to the outer repo

`work/` is independent runtime state and is **not** tracked by the definition repo — the allowlist `.gitignore` (`/*`, then re-include only the definition files) hides everything under `work/`. No detach step is needed; just confirm nothing leaks:

```bash
cd /home/agent
git status --porcelain   # MUST be clean — nothing under work/, .ssh, .claude, .config
```

If anything under `work/` (or `.ssh`, `.claude`, `.config`) shows up, **stop and fix `.gitignore` before continuing** — do not write the sentinel.

## Step 3 — Provision `work/` (runtime state)

**3a — `GITHUB_REPO_WORK` set** → restore prior state from the backup remote. `work/` is a **plain data directory, not a git clone** — backup happens off-volume via a tmpfs clone (`docs/persistence.md`), so restore just copies the remote's files in:

```bash
if [ -n "$GITHUB_REPO_WORK" ]; then
  mkdir -p /home/agent/work
  LOG_JOB=session bash "$HOME/scripts/work-backup.sh" restore
fi
```

If the remote is empty (first-ever deployment) the restore is a no-op — fall through to 3b to seed the templates; the first end-of-run `persist` creates the initial backup. Never make `work/` a git repo.

**3b — unset, or the 3a restore was empty/failed** → `mkdir -p /home/agent/work/reviews`, then create the seed files from the **templates below** only if missing (never overwrite an existing `MEMORY.md` or `LESSONS.md` — they hold long-term knowledge that isn't reconstructable). Review-tracking rows are reconstructed in Step 5 (needs the `review_marker` from Step 4 first); the empty `REVIEWS.md` header just needs to exist.

```bash
mkdir -p /home/agent/work/reviews
if [ ! -f /home/agent/work/MEMORY.md ]; then
  cat > /home/agent/work/MEMORY.md <<'EOF'
# Review Preferences

## Review Style
- Default strictness: medium
- Default verbosity: concise (suitable for chat UI)
- Tone: professional, constructive

## Focus Areas
- Correctness
- Security
- Performance
- Maintainability
- Architecture
- Tests

## Ignore List
_(Nothing ignored yet — user feedback will populate this)_

## Custom Rules
_(No custom rules yet — user feedback will populate this)_

## Observed Insights
_(Learned from human reviews, PR comments, and author replies — consolidated weekly at audit)_

## Feedback Log
_(No feedback yet — entries will be added as the user provides feedback)_
EOF
fi
if [ ! -f /home/agent/work/REVIEWS.md ]; then
  cat > /home/agent/work/REVIEWS.md <<'EOF'
# Reviewed PRs

| PR | Commit | Timestamp | Verdict | Status |
|----|--------|-----------|---------|--------|
EOF
fi
if [ ! -f /home/agent/work/LESSONS.md ]; then
  cat > /home/agent/work/LESSONS.md <<'EOF'
# Operational Lessons

_Verified environment facts and recurring failure modes — written when a root
cause is reproduced, read in review runs. Scope and rules:
`docs/preferences.md` → **Operational lessons**._

_(Nothing yet — entries are added as failures are diagnosed.)_
EOF
fi
```

## Step 4 — Configure the agent (`work/CONFIG.md`, interactive)

The definition is project-agnostic: every instance-specific value lives in `work/CONFIG.md` — exact key semantics in `CLAUDE.md` → **Runtime configuration** (read it first). Gather the values below, then write the file and show it to the operator (target shape = the example at the end).

**Re-onboarding note:** if Step 3a brought an existing `CONFIG.md`, **keep its values** and only ask for missing keys — never silently overwrite operator-set config (especially `review_marker`).

1. **`github_repo`** — only if Step 0.3 had to ask (env var unset). Omit otherwise — a stored copy would only drift.
2. **`definition_repo`** and **`definition_branch`** — always write both Step 0.2 values (write `definition_branch` even when it is `main`, so the tracked branch is explicit).
3. **`bot_login`** — the login from Step 0.1. Confirm with the operator, stating the consequence:

   > I'll act as GitHub user **<login>** — reviews will be posted and signed by this account, and assigning it to a PR requests a visual artifact. If this is a personal account, consider a dedicated machine/bot account instead.

4. **`bot_display_name`** — ask: *What name should I sign my reviews with? (Default: `Code Guardian`.)*
5. **`review_marker`** — dedup-marker prefix (`<!-- <review_marker> headRefOid=<sha> -->`), default `code-guardian:review`. Ask:

   > Has this agent (or a predecessor bot) already posted reviews on the target repo? If yes, give me the exact marker prefix it used — reusing it keeps the old reviews visible to deduplication. If no, I'll use `code-guardian:review`.

   ⚠️ Tell the operator the value is **immutable once the first review is posted** — changing it later would make every past review invisible to dedup.
6. **`rereview_label`** — the PR label that requests a re-review (`CLAUDE.md` → **Runtime configuration** + `docs/review.md`), default `code-guardian-review`. Ask:

   > First reviews are automatic, but re-reviews after new commits run **only** when someone adds a label to the PR — the label requests a complete review of the whole PR, and I remove it once it is posted. Which label name should I watch for? (Default: `code-guardian-review`.)

   If the label doesn't exist on the target repo yet, create it: `gh label create "<label>" --repo "$GITHUB_REPO" --description "Request a code-guardian re-review" --color FBCA04` (failure = tell the operator to create it manually; not blocking).

   Then ask about **`rereview_trigger`** — how re-reviews are requested: `label` (default) | `review-request` (GitHub's "Re-request review" on **<bot_login>**; needs the bot as a repo collaborator) | `both`. Write the key only when the answer differs from `label`.

   Then ask about **`urgent_label`** — an optional, human-managed label marking a PR urgent: its due reviews jump the queue and are delivered rapid-first (fast preliminary review, then the full one — `docs/review.md` → **Urgent PRs**), and with `slack_notifications: enabled` a newly found urgent PR gets one immediate Slack alert mentioning roster members. Default: off (omit the key). If the operator names one, validate/create it the same way as the re-review label.

   Then **`mention_replies`** — GitHub comments that @-mention **<bot_login>** (or reply in its inline review threads) get handled every heartbeat: questions answered, review feedback recorded to memory, review requests served (`docs/mentions.md`). Default `enabled`; write the key only when the operator wants `disabled`.
7. **Review skills + `artifact_skill`** — fully config-driven (`docs/skills.md`); **each skill carries its own `source`** (`harness`, or the `owner/repo` it installs from; artifact format `<skill>@<owner/repo>` or `none`). Present the default public set (see the example below — `issue-fit` ships in this definition repo, so its `source` is the instance's `definition_repo`) and let the operator adjust rows, triggers, and sources. **Validate every row before writing:**
   - Repo-sourced rows + artifact skill: `gh api "repos/<source>/contents/.agents/skills/<skill>"` must succeed — otherwise let the operator fix or drop the row.
   - Harness rows: the skill must appear in your available-skills list — otherwise drop the row after confirming (a missing harness skill would just log `skill-errored` on every PR).
   - An empty table + `artifact_skill: none` is valid — plain reviews only.
   - When the artifact skill is enabled, ask which surfaces to publish to — `artifact_targets` (default `gist`; `gist,dam` also publishes to the DAM Artifact Library, best-effort behind the owner's experimental flag — [docs/artifact.md](docs/artifact.md)). Omit the key with `artifact_skill: none`.
8. **`slack_notifications`** — strictly opt-in (gates the PR Shepherd nudging). Ask:

   > Do you want Slack notifications? When enabled, I watch how long each open PR waits for human review and nudge reviewers/authors in the shared Slack channel, escalating over time. It needs a Slack connection and a developer roster — I'll walk you through building one.

   **No / no reply** → `disabled`; everything else works, only the shepherd sweep is skipped (can be enabled later in chat — then re-run this sub-step + roster + item 9 + Step 6b). **Yes** → `enabled`, then build the roster (below) and pick the escalation owner.
9. **`escalation_owner`** (Slack only, after the roster exists) — ask: *Who should I escalate to when a PR stays unreviewed despite repeated reminders (nudge level 4)? Pick one person from the roster.* Must be a roster login **with a `slack_id`**.

Final shape:

```markdown
# Configuration

- github_repo: acme/widgets            # only when the env var was unset
- definition_repo: acme/code-guardian
- definition_branch: main              # branch this instance runs from (PRs still target main)
- bot_login: acme-review-bot
- bot_display_name: Code Guardian
- review_marker: code-guardian:review
- rereview_label: code-guardian-review # PR label that requests a re-review
- rereview_trigger: label              # label (default) | review-request | both
- urgent_label: urgent                 # optional; omit = off — rapid-first reviews for labeled PRs
- mention_replies: enabled             # @-mention replies + feedback capture (default); or: disabled
- artifact_skill: pr-artifact@dam-agents/dam   # or: none
- artifact_targets: gist               # gist (default) | gist,dam ; omit with artifact_skill: none
- slack_notifications: enabled         # or: disabled
- audit_report: enabled                # weekly health report; or: disabled
- escalation_owner: alice              # only when slack_notifications: enabled
- stall_alert_threshold: 4             # stalled reviews per 24h that alert; 0/off disables

## Review skills

| skill | source | trigger | section |
| --- | --- | --- | --- |
| issue-fit | acme/code-guardian | always | Issue Fit |
| doc-drift | dam-agents/dam | always | Documentation Check (doc-drift) |
| typescript-engineering | dam-agents/dam | .ts,.mts,.cts,.js,.mjs,.cjs | TypeScript Engineering Review |
| react-ui-engineering | dam-agents/dam | .tsx,.jsx | React UI Engineering Review |
```

### Build the developer roster (`work/DEVELOPERS.md`) — only when Slack is enabled

The roster is the **only** set of people the agent may ever @-mention (`docs/shepherd.md` → **Hard rules**). One row per member: `login`, `slack_id`, name, seed expertise keywords.

1. **Fetch the team from GitHub** — prefer an org team; list them (`ORG="${GITHUB_REPO%%/*}"; gh api "orgs/$ORG/teams" --jq '.[] | "\(.slug)\t\(.name)"'`), let the operator pick one, then `gh api "orgs/$ORG/teams/<slug>/members?per_page=100" --jq '.[].login'`. **Fallback** (no org/teams/404): `gh api "repos/$GITHUB_REPO/contributors?per_page=15" --jq '.[].login'`. Show the logins; the operator removes bots/one-off contributors or adds missing people.
2. **Draft the roster** — display names via `gh api "users/<login>" --jq '.name // .login'`; seed a few expertise keywords from each member's recent PRs in `$GITHUB_REPO` (rough is fine — the agent appends "Observed areas" over time; only the operator edits seed expertise). Present the draft.
3. **Ask for Slack member IDs** (not resolvable automatically) — one `login = U0123ABCD` line per member; found in Slack: profile → **⋮ (More)** → **Copy member ID**. Validate against `^U[A-Z0-9]{6,}$`. A member without an id may stay (named in text) but is never @-mentioned.
4. **Write `work/DEVELOPERS.md`:**

   ```markdown
   # Developers roster

   _The only people the agent may @-mention in Slack (docs/shepherd.md).
   Seed expertise is operator-provided — never overwrite or remove it; "Observed
   areas" are appended automatically by the agent._

   | login | slack_id | name | expertise (seed) | observed areas |
   | --- | --- | --- | --- | --- |
   | alice | U0123ABCD | Alice K. | frontend, react, accessibility | |
   ```

5. Confirm the result (members imported, how many have a Slack id), then return to Step 4 item 9.

## Step 5 — Reconstruct review state (only when `work/` was not hydrated in 3a)

Skip when Step 3a restored the state from `$GITHUB_REPO_WORK`; run it on the 3b path (env var unset, or the restore was empty/failed). Otherwise rebuild the tracking files from the target repo — every posted agent review carries the `<!-- <review_marker> headRefOid=... -->` marker (Step 4's value) plus verdict and timestamp. **Everything is recoverable except `MEMORY.md`.**

1. `gh pr list --repo "$GITHUB_REPO" --state open --json number`.
2. Per PR, fetch reviews/comments, filter by the marker, take the latest one's `headRefOid`, verdict, and `submitted_at`/`createdAt`.
3. Write one `REVIEWS.md` row per PR — `| <number> | <headRefOid> | <submitted_at> | <verdict> | done |` — with the **GitHub-reported** timestamp (history, not "now"). PRs with no agent review get no row.
4. Recreate `reviews/pr-<number>.md` from review bodies that exist — never fabricate. `## PR-local overrides` stays empty unless the thread contains an explicit dispute resolution (tag `[from PR comments]`).

The agent then skips already-reviewed SHAs correctly on the very first heartbeat. `work/` stays a plain directory; end-of-run persistence is skipped.

## Step 6 — Ensure the scheduled jobs exist

Two independent schedules (the shepherd one only when `slack_notifications: enabled`). Check with `mcp__platform-outbound__list_schedules` first — a schedule whose `name` starts with the same prefix already exists → skip creating it. Never use an in-process cron tool — only platform schedules survive restarts and are visible to the operator.

**6a — Review heartbeat.** Ask: *How often should I check for new PRs? Default is every 10 minutes.* Create `name: code-guardian-review-<cadence-shorthand>` (e.g. `…-10m`), cron default `*/10 * * * *`, `sessionMode: fresh`, `task`:

   > Review heartbeat. Run `bash "$HOME/scripts/preflight.sh" review` first. If its JSON says nothing_to_do, report its logs in one line and end the run. Otherwise follow CLAUDE.md → "Review run": read docs/review.md and docs/skills.md, apply the bookkeeping arrays (self-heals, label cleanups, prunes), review every PR in reviews_due (chat UI + GitHub review with the marker; honour the HEAD-freshness checks, locks, and the re-review label gate, removing the label after posting), handle artifacts_due per docs/artifact.md, and back up work/ at the end (`scripts/work-backup.sh persist`) when GITHUB_REPO_WORK is set.

**6b — Shepherd sweep** (only when Slack is enabled; create it later if Slack is enabled in chat). Ask: *During which hours and days should I nudge reviewers on Slack? Default is hourly, Mon–Fri, 07–18 (platform timezone).* Create `name: code-guardian-shepherd-<cadence-shorthand>` (e.g. `…-1h-workdays`), cron default `0 7-18 * * 1-5`, `sessionMode: fresh`, `task`:

   > Shepherd sweep. Run `bash "$HOME/scripts/preflight.sh" shepherd` first. If its JSON says nothing_to_do, report its logs in one line and end the run. Otherwise follow CLAUDE.md → "Shepherd run": read docs/shepherd.md, send exactly the nudges in nudges_due to the shared Slack channel (roster-only mentions), apply each sent nudge's row_update to the ledger immediately after its send (send-then-record), and back up work/ (`scripts/work-backup.sh persist`) when GITHUB_REPO_WORK is set.

**6c — Weekly audit.** Ask: *When should I send the weekly health report? Default is Friday 07:00 (platform timezone).* Create `name: code-guardian-audit-weekly`, cron default `0 7 * * 5`, `sessionMode: fresh`, `task`:

   > Weekly audit. Run `bash "$HOME/scripts/preflight.sh" audit` first. If its JSON says nothing_to_do, report its logs in one line and end the run. Otherwise follow CLAUDE.md → "Audit run": read docs/audit.md, add the agent-side checks (schedules, memory compliance, nudge integrity, reaction feedback), compose the health report from stats + checks, send it to Slack when slack_notifications is enabled (chat UI always), append the AUDIT.log line, and back up work/ (`scripts/work-backup.sh persist`) when GITHUB_REPO_WORK is set.

(`toggle_schedule` / `delete_schedule` exist for management.) Nudging cadence note: the nudge rules are hour-granular (24h age gate, 20h cooldown, 2-day escalation), so an hourly work-hours sweep loses nothing versus a continuous one — it only stops burning tokens at night and on weekends.

## Step 7 — Record the version, write the sentinel, report

Only after Steps 1–6 succeeded. `work/VERSION` records the adopted definition version (used by the version check — `docs/persistence.md` → **Definition version & upgrade**):

```bash
head -1 "$HOME/VERSION" > "$HOME/work/VERSION"
date -u +%Y-%m-%dT%H:%M:%SZ > "$HOME/.code-guardian-onboarded"
echo "Onboarding complete."
```

Then give the operator a short **onboarding summary** in the chat UI:

1. The final `work/CONFIG.md` (verbatim).
2. What runs where: target repo, review cadence, shepherd cadence (when Slack is on), audit day, state persistence (`GITHUB_REPO_WORK` or local-only).
3. Day-to-day usage: the first review of every open non-draft PR lands automatically (chat UI + GitHub); after new commits a re-review happens **only** when someone adds the **`<rereview_label>`** label to the PR (a complete review of the whole PR; the agent removes the label once it is posted), re-requests **`<bot_login>`**'s review on GitHub (when `rereview_trigger` is `review-request`/`both`), or asks for it in the connected Slack channel or in a comment @-mentioning **`<bot_login>`** (both delta-only — docs/review.md → **On-demand review**); labeling a PR **`<urgent_label>`** (when configured) makes its reviews jump the queue, rapid-preliminary-first; assigning **`<bot_login>`** to a PR requests a visual artifact (when configured); feedback/dismissals are given simply by saying so in chat (global → `MEMORY.md`, PR-specific → that PR's overrides) — and @-mentioning **`<bot_login>`** in any PR/issue comment or PR description gets a reply, with review feedback recorded to memory (`docs/mentions.md`); team-specific watch rules ("when a PR does X, give a heads-up in Y" — a Slack channel, the chat UI, or a PR comment) can be added any time in chat (`docs/watches.md`); any config value can be changed in chat later — except `review_marker` once reviews exist.

From now on the guard short-circuits and normal runs follow `CLAUDE.md`.
