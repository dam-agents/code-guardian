# code-guardian

PR code review agent for any GitHub repository — the target repo is supplied at
runtime via the `GITHUB_REPO` environment variable. Built on the Claude Code
harness, uses the GitHub CLI (`gh`) to fetch open pull requests and produces a
structured review report delivered to the chat UI and the GitHub PR thread.
Optionally (opt-in at onboarding) it also nudges reviewers on Slack when PRs
wait too long for human review (the **PR Shepherd** role).

## How it works

Three independent schedules exist, and **all start with a deterministic
pre-flight script** ([`scripts/preflight.sh`](scripts/preflight.sh)). The
script only *detects* — it makes no GitHub writes and computes the run's
worklist; when the worklist is empty the agent never wakes up (idle
heartbeats are nearly free), and when there is work the agent performs all
of it per the `docs/` procedures:

- **Review heartbeat** (default every 10 minutes, 24/7): `preflight.sh
  review` lists open non-draft PRs in one REST call and decides per PR what
  is due — never-reviewed PRs get a first review automatically;
  already-reviewed PRs get a re-review **only on an explicit trigger**: the
  configured re-review label (`rereview_label`, default
  `code-guardian-review`) or, when `rereview_trigger` enables it, GitHub's
  "Re-request review" on the bot (new commits alone just flip the tracking
  row to `awaiting_label`). Same-HEAD PRs are skipped via `work/REVIEWS.md` plus the
  remote check for the embedded `<!-- <review_marker> headRefOid=... -->`
  marker (with self-heal when local state is missing); closed/merged PRs are
  verified per PR and queued for pruning; the artifact assignee gate is
  evaluated; the configured skills are installed only when a review is due,
  cached by their source repo's HEAD SHA. The agent then reads
  [`docs/review.md`](docs/review.md) + [`docs/skills.md`](docs/skills.md),
  fetches context and the diff, clones the branch, runs every configured
  review skill per its trigger, re-verifies HEAD freshness right before
  posting, posts one GitHub review (summary + inline comments, signed with
  **`bot_display_name`**, carrying the hidden dedup marker), removes the
  re-review label when the PR carried one, and records the review in
  `work/REVIEWS.md` and `work/reviews/pr-<number>.md`. Re-reviews are
  delta-only and concise: fixed/still-present findings as one-liners, full
  text only for new findings, no "looks good" bullets.
- **Shepherd sweep** (default hourly, working days/hours; exists only when
  Slack notifications were enabled at onboarding): `preflight.sh shepherd`
  classifies every open non-draft PR from independent reviews and applies
  the age gate / cooldown / escalation ladder; the agent applies each due
  nudge's ledger update (write-before-send) and sends it to the shared Slack
  channel (roster-only mentions, per
  [`docs/shepherd.md`](docs/shepherd.md)). The nudge rules are
  hour-granular, so the hourly work-hours cadence loses nothing versus a
  continuous one.
- **Weekly audit** (default Friday morning): `preflight.sh audit` computes
  7-day statistics (reviews, verdicts, nudges, heartbeat cadence) and
  deterministic health checks — GitHub auth and rate limit, missed
  heartbeats, error log lines, state consistency against the GitHub markers,
  stale locks, orphaned artifact gists, disk usage, skill freshness, roster
  sanity. The agent adds judgment checks (schedules, memory-rule compliance,
  lost nudges) and sends a traffic-light report to Slack (when enabled) and
  the chat UI — per [`docs/audit.md`](docs/audit.md). Gated by the
  `audit_report` config key (default `enabled`).

The agent definition is split so the always-loaded part stays small:
[`CLAUDE.md`](CLAUDE.md) holds the run types, the pre-flight contract, and
the hard invariants, while the detailed procedures live in [`docs/`](docs/)
and are read only when the corresponding work actually happens.

The definition is **versioned** ([`VERSION`](VERSION) +
[`CHANGELOG.md`](CHANGELOG.md)): at updates, on demand, and before any
self-modification the agent checks version freshness, applies the
changelog's upgrade steps, and warns the operator when the instance is
outdated — see [`docs/persistence.md`](docs/persistence.md) → **Definition
version & upgrade**.

Feedback the user gives is persisted into `work/MEMORY.md` (global) or
`work/reviews/pr-<number>.md` under `## PR-local overrides` (PR-specific), so
subsequent runs respect those preferences without re-flagging dismissed
findings. The agent also learns passively: generalizable insights from human
reviews, PR comments, and author replies are recorded as observed insights,
and the weekly audit consolidates them (merge, promote to rules, drop stale)
so memory stays useful and bounded while the agent improves over time — per
[`docs/preferences.md`](docs/preferences.md).

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
3. **Grab the link to [`ONBOARDING.md`](ONBOARDING.md)** — **from the repo (or
   fork) you actually deploy from**, e.g.
   `https://github.com/<your-org>/code-guardian/blob/main/ONBOARDING.md`.
   The agent derives its *definition repo* from this URL (stored as
   `definition_repo` in `work/CONFIG.md`), so a fork's agent stays pinned to the
   fork — it never resets itself to upstream.
4. **Tell the agent**, in its first message:

   > Here is a file — read it and set yourself up according to it: https://github.com/<your-org>/code-guardian/blob/main/ONBOARDING.md

That is enough for a complete initialization. The agent reads the runbook and,
in one pass, checks out its own definition, wires up `work/`, walks you through
a short configuration dialog (bot name, review marker, skills repo, Slack —
each value lands in `work/CONFIG.md`, see **Configuration** below), registers
the schedules (the every-10-minutes review heartbeat, the Friday audit, plus
the hourly work-hours shepherd sweep when Slack is enabled), and marks itself
onboarded
so it never repeats the process. From then on it runs on schedule.

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

Independently of this opt-in, **anyone** in the connected channel can ask the
agent to review a specific PR (equivalent to adding the re-review label),
including restarting a stuck review — see `docs/review.md` →
**Slack-requested review**.

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
| `definition_repo` | derived from the ONBOARDING.md URL | The repo this agent definition came from (fork-aware) — outer-repo `origin`, target of definition PRs, review-footer link. |
| `bot_login` | auto-detected via `gh api user`, confirmed | GitHub login the agent acts as — artifact assignee gate, gist URLs, "independent reviewer" classification. |
| `bot_display_name` | asked (default `Code Guardian`) | Name the agent signs reviews with. Cosmetic only. |
| `review_marker` | asked (default `code-guardian:review`) | Prefix of the hidden dedup marker in every posted review. **Immutable once the first review is posted.** |
| `rereview_label` | asked (default `code-guardian-review`) | PR label that requests a re-review of an already-reviewed PR — without a trigger, new commits are not re-reviewed. The agent removes the label once the re-review is posted. |
| `rereview_trigger` | asked with `rereview_label` (default `label`, key omitted then) | How re-reviews are requested: `label`, `review-request` (GitHub's "Re-request review" on the bot; needs the bot as a collaborator), or `both`. A served review request clears itself when the review posts. |
| `artifact_skill` | defaulted to `pr-artifact@dam-agents/dam` (`none` to disable) | Visual-artifact skill **with its own source** (`<skill>@<owner/repo>`); `none` disables the feature. |
| `artifact_targets` | defaulted to `gist` (`gist,dam` to also publish to the DAM Artifact Library) | Comma-separated publish surfaces for the artifact (`gist`, `dam`). `dam` is best-effort behind the owner's experimental flag — listed-but-unavailable is skipped, never fails the run. |
| `## Review skills` table | defaulted to the public set (doc-drift + typescript-engineering + react-ui-engineering), operator-adjustable, every row validated | Per-PR review skills: name, **per-skill source** (`owner/repo` to install from, or `harness`), trigger (`always` or extension list), and the review-section heading. CLAUDE.md defines only the mechanics; this table defines *what* runs *when* and *from where*. |
| `## Watch rules` table | not filled — added later in chat when a team asks | Instance-local "when a PR does X, give a heads-up in Y" rules, evaluated during reviews and delivered to vetted targets — chat UI, a Slack channel, or a comment on the PR (`docs/watches.md`). Keeps team-specific triggers and channels out of this public definition — rules are private runtime state. |
| `slack_notifications` | asked (default `disabled`) | Gates all Slack activity (PR Shepherd nudging, watch notifications). |
| `audit_report` | defaulted to `enabled` | Weekly health check + report (Slack when enabled, chat UI otherwise). |
| `log_level` | not set (= `info`) | Verbosity of the structured events log `work/logs/events-*.jsonl` (`docs/logging.md`); `debug` also records successful external tool calls. |
| `escalation_owner` | asked (only when Slack enabled) | Roster member @-mentioned at nudge level 4. |

### Runtime requirements

- **Platform:** the agent assumes the DAM agent infrastructure — `$HOME` at
  `/home/agent` on a persistent `/workspace` volume, the platform's outbound
  auth proxy for GitHub tokens, and the `mcp__platform-outbound__*` tools for
  schedules and Slack. Running elsewhere requires adapting those assumptions.
- **GitHub identity:** the agent posts reviews, comments, and gists as the
  account behind its token. Use a **dedicated machine/bot account** (not a
  personal one) that is a collaborator on the target repo with permission to
  review PRs. Note that GitHub ignores review requests/approvals from a PR's
  own author — the bot account must not be the one opening the PRs it reviews.
- **Token scopes:** the token must be able to read/write PRs, reviews, and
  comments on `GITHUB_REPO` (`repo`), push to `GITHUB_REPO_WORK` and the
  definition repo, create/delete **gists** (visual artifacts), and list org
  teams (`read:org`) for the roster import.
- **External services:** artifact links render via `htmlpreview.github.io`, a
  third-party service; "secret" gists are unlisted but publicly reachable by
  URL. With `artifact_targets: gist,dam` the artifact is also published to the
  platform's DAM Artifact Library (best-effort, behind the owner's
  experimental flag), whose `visibility:"public"` share URL is likewise
  reachable by anyone holding it (see `docs/artifact.md`).

### Connections

- A **GitHub** connection must be granted so that `gh` can authenticate (the
  Envoy sidecar injects the OAuth token on outbound GitHub requests). The same
  token is used for `GITHUB_REPO`, `GITHUB_REPO_WORK`, and the definition repo.
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
  memory, not derivable from PRs) starts from the seed template embedded in
  `ONBOARDING.md` (Step 3b).

`work/` is **not tracked** by this definition repo — the allowlist `.gitignore`
hides everything under `work/` at the top level, so the two never collide and a
definition update (`git reset --hard origin/main`) never touches live runtime
state. See `docs/persistence.md` → **Two repos, one inside the other**.

## Files

- [`CLAUDE.md`](CLAUDE.md) — the slim core manual loaded by the agent on every
  run (run types, pre-flight contract, config semantics, hard invariants).
- [`scripts/preflight.sh`](scripts/preflight.sh) — deterministic pre-flight for
  both run types; detects work, never acts on GitHub.
- [`scripts/log.sh`](scripts/log.sh) + [`scripts/harness/`](scripts/harness/) —
  structured events log (`work/logs/events-*.jsonl`, 14-day retention) and the
  per-harness adapters that auto-capture failed tool calls (`docs/logging.md`).
- [`docs/`](docs/) — detailed procedures, read on demand:
  [`review.md`](docs/review.md), [`skills.md`](docs/skills.md),
  [`artifact.md`](docs/artifact.md), [`shepherd.md`](docs/shepherd.md),
  [`preferences.md`](docs/preferences.md), [`persistence.md`](docs/persistence.md), [`audit.md`](docs/audit.md),
  [`logging.md`](docs/logging.md),
  [`self-modification.md`](docs/self-modification.md).
- [`ONBOARDING.md`](ONBOARDING.md) — first-run setup runbook (see **Setup** above);
  also carries the `work/MEMORY.md` and `work/REVIEWS.md` seed templates (Step 3b).
- [`VERSION`](VERSION) + [`CHANGELOG.md`](CHANGELOG.md) — definition semver
  (bumped with every change) and the per-version upgrade steps instances
  apply.
- [`LICENSE`](LICENSE) — Apache License 2.0.

## License

Apache License 2.0 — see [`LICENSE`](LICENSE).
