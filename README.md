# code-guardian

PR code review agent for any GitHub repository — the target repo is supplied at
runtime via the `GITHUB_REPO` environment variable. Built on the Claude Code
harness, uses the GitHub CLI (`gh`) to fetch open pull requests and produces a
structured review report delivered to chat UI, Slack, and the GitHub PR thread.

## How it works

On every run, the agent:

1. Installs (or refreshes) the `doc-drift` skill from the upstream URL so
   per-PR documentation checks are available.
2. Reads learned review preferences from `work/MEMORY.md`.
3. Reads the review history from `work/REVIEWS.md`.
4. Lists open, non-draft PRs in the configured repository (`$GITHUB_REPO`, or
   the repo detected by `gh repo view` in the working directory).
5. Skips PRs already reviewed at the same HEAD commit — using both a local
   check (REVIEWS.md) and a remote check (GitHub comment thread for the
   embedded `<!-- dam:review headRefOid=... -->` marker).
6. For each new or updated PR:
   - Re-fetches `headRefOid` / `isDraft` to guard against stale snapshots.
   - Reviews the diff against the configured criteria (correctness, security,
     performance, maintainability, architecture, tests).
   - Clones the PR branch into `/tmp/dam-pr-<number>/` and runs the
     `doc-drift` skill against it.
   - Re-verifies HEAD freshness one more time right before posting.
   - Outputs the structured review to the chat UI.
   - Sends the full review to Slack via
     `mcp__dam-outbound__send_channel_message` (one PR = one message).
   - Posts the same review as a GitHub PR comment signed as **DAM**, with
     a hidden SHA marker used for deduplication on future runs.
   - Updates `work/REVIEWS.md` and appends to `work/reviews/pr-<number>.md`.
   - Deletes the local clone before moving on to the next PR.
7. Walks through an end-of-run self-check to verify every step was completed.

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
2. **Set the environment variables** — at minimum `GITHUB_REPO` (the repo to
   review), and optionally `GITHUB_REPO_WORK` (a repo to back the agent's
   persistent state). See the table below.
3. **Grab the link to [`ONBOARDING.md`](ONBOARDING.md)** — it is:
   `https://github.com/dam-agents/code-guardian/blob/main/ONBOARDING.md`
4. **Tell the agent**, in its first message:

   > Here is a file — read it and set yourself up according to it: https://github.com/dam-agents/code-guardian/blob/main/ONBOARDING.md

That is enough for a complete initialization. The agent reads the runbook and,
in one pass, checks out its own definition, wires up `work/`, registers the
every-10-minutes review schedule, and marks itself onboarded so it never repeats
the process. From then on it runs the review pipeline on schedule.

## Configuration

### Environment variables

| Variable | Required | Description |
| --- | --- | --- |
| `GITHUB_REPO` | **Yes** | `owner/repo` slug of the repository whose PRs are reviewed. If unset, the agent falls back to the repo detected via `gh repo view` in the working directory. |
| `GITHUB_REPO_WORK` | No | `owner/repo` slug of a separate repository that backs the agent's persistent state (`work/`). **When set**, `work/` is a git clone of this repo and the agent commits & pushes its state there after every run. **When unset**, the agent reconstructs review-tracking state from the DAM reviews already on `GITHUB_REPO` on init, and persistence is local-only (the `/workspace` PVC). |

### Connections

- A **GitHub** connection must be granted so that `gh` can authenticate (the
  Envoy sidecar injects the OAuth token on outbound GitHub requests). The same
  token is used for `GITHUB_REPO`, `GITHUB_REPO_WORK`, and this definition repo.
- A **Slack** connection must be wired up for
  `mcp__platform-outbound__send_channel_message` to reach a channel; without it,
  Slack delivery fails but the rest of the review pipeline still runs.

## Persistence

`work/MEMORY.md`, `work/REVIEWS.md`, and `work/reviews/` hold the agent's learned
preferences and review history. They live on the `/workspace` PVC at runtime
(mounted as `/home/agent/work/`), so they survive pod restarts. How `work/` is
seeded depends on `GITHUB_REPO_WORK` (see above):

- **`GITHUB_REPO_WORK` set** — `work/` is a clone of that repo; state is committed
  and pushed back after every run, giving durable, versioned, cross-pod history.
- **`GITHUB_REPO_WORK` unset** — `REVIEWS.md` and `reviews/` are reconstructed from
  the DAM reviews on `GITHUB_REPO`; `MEMORY.md` (long-term memory, not derivable
  from PRs) starts from the seed scaffold committed to this repo.

`work/` is kept independent of this definition repo (it is git-ignored / detached
at the top level), so the two never collide — see `CLAUDE.md` →
**Two repos, one inside the other**.

## Files

- [`CLAUDE.md`](CLAUDE.md) — full operating manual loaded by the agent.
- [`ONBOARDING.md`](ONBOARDING.md) — first-run setup runbook (see **Setup** above).
- [`work/MEMORY.md`](work/MEMORY.md) — seed file for learned review preferences.
- [`work/REVIEWS.md`](work/REVIEWS.md) — seed file for the per-PR review index.
