# code-guardian

PR code review agent for any GitHub repository — the target repo is supplied at
runtime via the `GITHUB_REPO` environment variable. Built on the Claude Code
harness, uses the GitHub CLI (`gh`) to fetch open pull requests and produces a
structured review report delivered to the chat UI and the GitHub PR thread.
Optionally (opt-in at onboarding) it also nudges reviewers on Slack when PRs
wait too long for human review (the **PR Shepherd** role).

## How it works

On every run, the agent:

1. Loads `work/CONFIG.md` and installs (or refreshes) the configured skills —
   the per-PR review skills (`## Review skills` table) and the artifact skill —
   from the configured skills repository (`skills_repo`; when not configured,
   the repo-sourced skills are simply disabled, harness-provided ones still
   run).
2. Reads learned review preferences from `work/MEMORY.md`.
3. Reads the review history from `work/REVIEWS.md`.
4. Lists open, non-draft PRs in the configured repository (`$GITHUB_REPO`, or
   the repo detected by `gh repo view` in the working directory).
5. Skips PRs already reviewed at the same HEAD commit — using both a local
   check (REVIEWS.md) and a remote check (GitHub comment thread for the
   embedded `<!-- <review_marker> headRefOid=... -->` marker, where
   `<review_marker>` comes from `work/CONFIG.md`).
6. For each new or updated PR:
   - Re-fetches `headRefOid` / `isDraft` to guard against stale snapshots.
   - Reviews the diff against the configured criteria (correctness, security,
     performance, maintainability, architecture, tests).
   - Clones the PR branch into `/tmp/review-pr-<number>/` and runs every
     configured review skill against it per its trigger (`always` skills on the
     whole clone, extension-triggered skills on their routed changed files);
     each skill's output becomes its own section in the review.
   - Re-verifies HEAD freshness one more time right before posting.
   - Outputs the structured review to the chat UI.
   - Posts the review to GitHub as a single PR review signed with the
     configured **`bot_display_name`** — summary plus inline comments — with a
     hidden SHA marker used for deduplication on future runs.
   - Updates `work/REVIEWS.md` and appends to `work/reviews/pr-<number>.md`.
   - Deletes the local clone before moving on to the next PR.
7. **Only when Slack notifications are enabled** (`work/CONFIG.md`, set during
   onboarding): runs the **PR Shepherd sweep** — watches how long each open PR
   has waited for human review and nudges reviewers/authors in Slack,
   escalating over time. With notifications disabled the sweep is skipped
   entirely and the agent never touches Slack.
8. Walks through an end-of-run self-check to verify every step was completed.

Feedback the user gives is persisted into `work/MEMORY.md` (global) or
`work/reviews/pr-<number>.md` under `## PR-local overrides` (PR-specific), so
subsequent runs respect those preferences without re-flagging dismissed
findings.

See [`CLAUDE.md`](CLAUDE.md) for the full operating manual the agent loads
at startup.

## Setup

Bringing up a new code-guardian agent takes four steps:

1. **Create the agent** on the platform, with GitHub (and, optionally, Slack)
   connections granted — see **Configuration** below.
2. **Set the environment variables** — ideally `GITHUB_REPO` (the repo to
   review; if you skip it, the agent asks for the slug at the start of
   onboarding and stores it in `work/CONFIG.md`), and optionally
   `GITHUB_REPO_WORK` (a repo to back the agent's persistent state). See the
   table below.
3. **Grab the link to [`ONBOARDING.md`](ONBOARDING.md)** — it is:
   `https://github.com/dam-agents/code-guardian/blob/main/ONBOARDING.md`
4. **Tell the agent**, in its first message:

   > Here is a file — read it and set yourself up according to it: https://github.com/dam-agents/code-guardian/blob/main/ONBOARDING.md

That is enough for a complete initialization. The agent reads the runbook and,
in one pass, checks out its own definition, wires up `work/`, walks you through
a short configuration dialog (bot name, review marker, skills repo, Slack —
each value lands in `work/CONFIG.md`, see **Configuration** below), registers
the every-10-minutes review schedule, and marks itself onboarded so it never
repeats the process. From then on it runs the review pipeline on schedule.

### Slack notifications (optional, chosen at onboarding)

One of the onboarding questions is: **do you want Slack notifications?** — i.e.
the PR Shepherd reviewer nudging.

- **No** (or no answer) → the agent never touches Slack. Reviews still land in
  the chat UI and on GitHub; only the nudging is off.
- **Yes** → the agent walks you through building the reviewer roster
  (`work/DEVELOPERS.md`), the only set of people it may ever @-mention:
  1. It imports your team's GitHub logins from a **GitHub org team** (it lists
     the org's teams and you pick one), falling back to the repo's top
     contributors when there is no usable team. You can prune/extend the list.
  2. It drafts the roster with names and seed expertise keywords derived from
     each member's recent PRs.
  3. You paste each member's **Slack member ID** (in Slack: profile → ⋮ →
     *Copy member ID*), one `login = U…` line per member — Slack IDs cannot be
     resolved automatically.

The decision is stored in `work/CONFIG.md` and can be changed later simply by
telling the agent — it will flip the flag (and build the roster on first
enable).

## Configuration

### Environment variables

| Variable | Required | Description |
| --- | --- | --- |
| `GITHUB_REPO` | Recommended | `owner/repo` slug of the repository whose PRs are reviewed. **If unset, the agent asks for the slug at the very start of onboarding**, validates it, and persists it to `work/CONFIG.md` (`github_repo:` key) — the env var, when later set, always takes precedence over the stored value. Last-resort fallback is the repo detected via `gh repo view` in the working directory. |
| `GITHUB_REPO_WORK` | No | `owner/repo` slug of a separate repository that backs the agent's persistent state (`work/`). **When set**, `work/` is a git clone of this repo and the agent commits & pushes its state there after every run. **When unset**, the agent reconstructs review-tracking state on init from its own marker-carrying reviews already posted on `GITHUB_REPO`, and persistence is local-only (the `/workspace` PVC). |

### `work/CONFIG.md` — instance configuration

The agent definition is project-agnostic: everything specific to one deployment
lives in `work/CONFIG.md`, which **onboarding fills in interactively at init**
(auto-detecting what it can, asking for the rest). Exact per-key semantics are
documented in `CLAUDE.md` → **Runtime configuration**; summary:

| Key | Filled at onboarding by | Purpose |
| --- | --- | --- |
| `github_repo` | Step 0 answer (only when the `GITHUB_REPO` env var is unset) | Fallback target-repo slug; the env var always wins. |
| `bot_login` | auto-detected via `gh api user` | GitHub login the agent acts as — artifact assignee gate, gist URLs, "independent reviewer" classification. |
| `bot_display_name` | asked (default `Code Guardian`) | Name the agent signs reviews with. Cosmetic only. |
| `review_marker` | asked (default `code-guardian:review`) | Prefix of the hidden dedup marker in every posted review. **Immutable once the first review is posted.** |
| `skills_repo` | asked (`none` to disable) | Repo hosting installable skills under `.agents/skills/<name>/`; unset/`none` disables every repo-sourced skill. |
| `artifact_skill` | defaulted to `pr-artifact` (`none` when no skills repo) | Skill generating the visual PR artifact for assigned PRs; `none` disables the feature. |
| `## Review skills` table | defaulted to the public set (doc-drift + typescript-engineering + react-ui-engineering), operator-adjustable | Per-PR review skills: name, source (`skills_repo`/`harness`), trigger (`always` or extension list), and the review-section heading. CLAUDE.md defines only the mechanics; this table defines *what* runs *when*. |
| `slack_notifications` | asked (default `disabled`) | Gates all Slack activity (PR Shepherd nudging). |
| `escalation_owner` | asked (only when Slack enabled) | Roster member @-mentioned at nudge level 4. |

### Connections

- A **GitHub** connection must be granted so that `gh` can authenticate (the
  Envoy sidecar injects the OAuth token on outbound GitHub requests). The same
  token is used for `GITHUB_REPO`, `GITHUB_REPO_WORK`, and this definition repo.
- A **Slack** connection is **optional** — it is only needed when Slack
  notifications are enabled during onboarding (see **Setup** above), so that
  `mcp__platform-outbound__send_channel_message` can reach the shared channel.
  With notifications disabled (the default when the question is unanswered),
  the agent never calls Slack and the full review pipeline runs unaffected.

## Persistence

`work/MEMORY.md`, `work/REVIEWS.md`, and `work/reviews/` hold the agent's learned
preferences and review history. `work/CONFIG.md` (instance configuration — see
above) and — when Slack is enabled — `work/DEVELOPERS.md` (reviewer roster) and
`work/SHEPHERD.md` (per-PR nudge ledger) live alongside them and persist the
same way. They live on the `/workspace` PVC at runtime
(mounted as `/home/agent/work/`), so they survive pod restarts. How `work/` is
seeded depends on `GITHUB_REPO_WORK` (see above):

- **`GITHUB_REPO_WORK` set** — `work/` is a clone of that repo; state is committed
  and pushed back after every run, giving durable, versioned, cross-pod history.
- **`GITHUB_REPO_WORK` unset** — `REVIEWS.md` and `reviews/` are reconstructed from
  the agent's marker-carrying reviews on `GITHUB_REPO`; `MEMORY.md` (long-term
  memory, not derivable from PRs) starts from the seed scaffold committed to this
  repo.

`work/` is kept independent of this definition repo (it is git-ignored / detached
at the top level), so the two never collide — see `CLAUDE.md` →
**Two repos, one inside the other**.

## Files

- [`CLAUDE.md`](CLAUDE.md) — full operating manual loaded by the agent.
- [`ONBOARDING.md`](ONBOARDING.md) — first-run setup runbook (see **Setup** above).
- [`work/MEMORY.md`](work/MEMORY.md) — seed file for learned review preferences.
- [`work/REVIEWS.md`](work/REVIEWS.md) — seed file for the per-PR review index.
