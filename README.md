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

## Configuration

- `GITHUB_REPO` — `owner/repo` slug to review. Defaults to the repo detected
  in the working directory via `gh repo view`.
- A GitHub connection must be granted to this agent so that `gh` can
  authenticate (the Envoy sidecar injects the OAuth token on outbound GitHub
  requests).
- A Slack connection must be wired up for `mcp__dam-outbound__send_channel_message`
  to reach a channel; without it, Slack delivery fails but the rest of the
  review pipeline still runs.

## Persistence

`work/MEMORY.md`, `work/REVIEWS.md`, and `work/reviews/` live on the
`/workspace` PVC at runtime (mounted as `/home/agent/work/`), so preferences
and review history survive pod restarts. The seed files committed to this
repo populate the initial state of the PVC.

## Files

- [`CLAUDE.md`](CLAUDE.md) — full operating manual loaded by the agent.
- [`work/MEMORY.md`](work/MEMORY.md) — seed file for learned review preferences.
- [`work/REVIEWS.md`](work/REVIEWS.md) — seed file for the per-PR review index.
