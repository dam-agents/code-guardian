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
  already-reviewed PRs get a re-review **only on an explicit trigger** (the
  `rereview_label`, or GitHub's "Re-request review" when `rereview_trigger`
  enables it — new commits alone just flip the tracking row to
  `awaiting_label`). Same-HEAD PRs are skipped via `work/REVIEWS.md` plus
  the remote dedup-marker check (with self-heal); closed/merged PRs are
  verified per PR and queued for pruning; PRs carrying the optional
  `urgent_label` jump the queue and get a rapid preliminary review before
  the full one. The agent then follows
  [`docs/review.md`](docs/review.md) + [`docs/skills.md`](docs/skills.md):
  context + diff, clone, every configured review skill, HEAD freshness
  re-verified right before posting, one GitHub review (summary + inline
  comments, signed with **`bot_display_name`**, carrying the hidden dedup
  marker), label bookkeeping, tracking in `work/REVIEWS.md` and
  `work/reviews/pr-<number>.md`. Reviews are concise and assume
  agent-written, agent-read code. Re-review scope follows the trigger: the
  label requests a complete review of the whole PR, a review request or
  on-demand ask a delta-only one. The same
  heartbeat also picks up comments and PR descriptions addressed to the bot
  — an @-mention or a
  reply in one of its inline review threads — and answers them: questions
  get a reply, explicit review feedback is recorded to memory (and confirmed
  in the reply), and "please re-review" is served on demand
  ([`docs/mentions.md`](docs/mentions.md), `mention_replies` key).
- **Shepherd sweep** (default hourly, working days/hours; exists only when
  Slack notifications were enabled at onboarding): `preflight.sh shepherd`
  classifies every open non-draft PR from independent reviews and applies
  the age gate / cooldown / escalation ladder, flagging PRs with merge
  conflicts for an author-directed rebase nudge (approved PRs included);
  the agent sends each due
  nudge to the shared Slack channel and records it in the ledger
  immediately after the send (send-then-record; roster-only mentions, per
  [`docs/shepherd.md`](docs/shepherd.md)). The nudge rules are
  hour-granular, so the hourly work-hours cadence loses nothing versus a
  continuous one.
- **Weekly audit** (default Friday morning): `preflight.sh audit` computes
  7-day statistics (reviews, verdicts, nudges, heartbeat cadence) and
  deterministic health checks — GitHub auth and rate limit, missed
  heartbeats, error log lines, state consistency against the GitHub markers,
  stale locks, orphaned artifact gists, disk usage, skill freshness, roster
  sanity, 👍/👎 reactions on the bot's comments. The agent adds judgment
  checks (schedules, memory-rule compliance, nudge integrity, lessons from
  👎-flagged findings) and sends a traffic-light report to Slack (when enabled) and
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

Feedback the user gives — in chat, or in a PR comment addressed to the bot —
is persisted into `work/MEMORY.md` (global) or
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
   The agent derives its *definition repo* — host included, so a GitHub
   Enterprise URL works the same — from this URL (stored as `definition_repo` in
   `work/CONFIG.md`), so a fork's agent stays pinned to the fork; it never
   resets itself to upstream.
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

Independently of this opt-in, **anyone** in the connected channel — or in a
GitHub comment @-mentioning the bot — can ask the agent to review a specific
PR (equivalent to adding the re-review label), including restarting a stuck
review — see `docs/review.md` → **On-demand review**. Any other change
request from a channel is declined and automatically filed as a tracking
issue on the definition repo, with the link in the reply (`CLAUDE.md` →
**Instruction sources & trust boundary**).

## Configuration

### Environment variables

| Variable | Required | Description |
| --- | --- | --- |
| `GITHUB_REPO` | Recommended | `[host/]owner/repo` of the repository whose PRs are reviewed. **If unset, the agent asks for the slug at the very start of onboarding**, validates it, and persists it to `work/CONFIG.md` (`github_repo:` key) — the env var, when later set, always takes precedence over the stored value. Last-resort fallback is the repo detected via `gh repo view` in the working directory. |
| `GITHUB_REPO_WORK` | No | `[host/]owner/repo` of a separate repository that backs the agent's persistent state (`work/`). **When set**, `work/` is a plain data directory that the agent backs up to this repo after every run via a disposable tmpfs clone (never a `.git` on the shared volume — see `docs/persistence.md`). **When unset**, the agent reconstructs review-tracking state on init from its own marker-carrying reviews already posted on `GITHUB_REPO`, and persistence is local-only (the `/workspace` PVC). |

### `work/CONFIG.md` — instance configuration

The agent definition is project-agnostic: everything specific to one deployment
lives in `work/CONFIG.md`, which **onboarding fills in interactively at init**
(auto-detecting what it can, asking for the rest). Exact per-key semantics are
documented in `CLAUDE.md` → **Runtime configuration**; summary:

| Key | Filled at onboarding by | Purpose |
| --- | --- | --- |
| `github_repo` | Step 0 answer (only when the `GITHUB_REPO` env var is unset) | Fallback target-repo reference (`[host/]owner/repo`); the env var always wins. |
| `definition_repo` | derived from the ONBOARDING.md URL, host included | The repo this agent definition came from (fork-aware), `[host/]owner/repo` — outer-repo `origin`, target of definition PRs, review-footer link. |
| `definition_branch` | derived from the ONBOARDING.md URL, else `main` | Branch of `definition_repo` **this instance runs from** — its update source and the branch the checkout is kept on. A per-agent deployment choice; definition PRs are still based on `main`. |
| `bot_login` | auto-detected via `gh api user`, confirmed | GitHub login the agent acts as — artifact assignee gate, gist URLs, "independent reviewer" classification. |
| `bot_display_name` | asked (default `Code Guardian`) | Name the agent signs reviews with. Cosmetic only. |
| `review_marker` | asked (default `code-guardian:review`) | Prefix of the hidden dedup marker in every posted review. **Immutable once the first review is posted.** |
| `rereview_label` | asked (default `code-guardian-review`) | PR label that requests a **complete** re-review of the whole PR — without a trigger, new commits are not re-reviewed. The agent removes the label once the re-review is posted. |
| `rereview_trigger` | asked with `rereview_label` (default `label`, key omitted then) | How re-reviews are requested: `label`, `review-request` (GitHub's "Re-request review" on the bot; needs the bot as a collaborator), or `both`. A served review request clears itself when the review posts. |
| `urgent_label` | asked with the labels (default: off, key omitted) | Optional **human-managed** label marking a PR urgent — its due reviews jump the queue and run rapid-first: a fast preliminary review posts immediately, the full review follows; with Slack enabled a newly urgent PR also gets one immediate roster-mentioning alert (`docs/review.md` → **Urgent PRs**). |
| `review_progress` | asked (default `disabled`, key omitted then) | Publishes each review's progress to the PR as a commit status on the reviewed SHA — started, in progress with an ETA from past reviews, and a terminal outcome linking to the posted review (`docs/review.md` → **Progress signal on GitHub**). Always `success` when it finishes, so it never gates a merge; the `context` is the instance's `review_marker`. |
| `mention_replies` | defaulted to `enabled` | GitHub comments addressed to the bot (@-mention, or a reply in its inline review threads) are answered every heartbeat — questions get replies, explicit review feedback is recorded to memory, review requests are served (`docs/mentions.md`). |
| `artifact_skill` | defaulted to `pr-artifact@dam-agents/dam` (`none` to disable) | Visual-artifact skill **with its own source** (`<skill>@<[host/]owner/repo>`); `none` disables the feature. |
| `artifact_targets` | defaulted to `gist` (`gist,dam` to also publish to the DAM Artifact Library) | Comma-separated publish surfaces for the artifact (`gist`, `dam`). `gist` requires a `github.com` target repo and is dropped elsewhere; `dam` is best-effort behind the owner's experimental flag — listed-but-unavailable is skipped, never fails the run. |
| `## Review skills` table | defaulted to the public set (issue-fit + doc-drift + typescript-engineering + react-ui-engineering), operator-adjustable, every row validated | Per-PR review skills: name, **per-skill source** (`[host/]owner/repo` to install from, or `harness`), trigger (`always` or extension list), and the review-section heading. CLAUDE.md defines only the mechanics; this table defines *what* runs *when* and *from where*. |
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
- **GitHub hosts:** every repo reference is `[<host>/]<owner>/<repo>`, so the
  target repo, this definition, the skill sources, and `GITHUB_REPO_WORK` may
  each live on a different host — `github.com` or a GitHub Enterprise instance.
  Each host in play must be authenticated separately
  (`gh auth login --hostname <host>`, operator-only) and reachable from the pod;
  a non-`github.com` target host is persisted as `GH_HOST` at onboarding. The
  `gist` artifact surface is `github.com`-only (`docs/artifact.md`).
- **GitHub identity:** the agent posts reviews, comments, and gists as the
  account behind its token. Use a **dedicated machine/bot account** (not a
  personal one) that is a collaborator on the target repo with permission to
  review PRs. Note that GitHub ignores review requests/approvals from a PR's
  own author — the bot account must not be the one opening the PRs it reviews.
- **Token scopes:** the single place these are specified.

  | Scope | Required? | What needs it |
  | --- | --- | --- |
  | `repo` | **yes** | PRs, reviews, comments, labels and issues on `GITHUB_REPO`; push to `GITHUB_REPO_WORK` and the definition repo |
  | `gist` | yes, unless artifacts are off | Create/delete the **visual artifact** gists (`artifact_skill: none` → not needed) |
  | `read:org` | optional | Onboarding only: lists your org's **teams** to seed the reviewer roster. Without it onboarding falls back to the repo's top contributors; no scheduled run uses it |

  The audit's `token_scopes` check asserts the required ones only. A missing
  scope is **operator-only** to fix — the agent reports it and never works
  around it.
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

- **`GITHUB_REPO_WORK` set** — `work/` is a plain data directory backed up to that
  repo after every run (via a disposable tmpfs clone, never a `.git` on the shared
  volume), giving durable, versioned, cross-pod history.
- **`GITHUB_REPO_WORK` unset** — `REVIEWS.md` and `reviews/` are reconstructed from
  the agent's marker-carrying reviews on `GITHUB_REPO`; `MEMORY.md` (long-term
  memory, not derivable from PRs) starts from the seed template embedded in
  `ONBOARDING.md` (Step 3b).

`work/` is **not tracked** by this definition repo — the allowlist `.gitignore`
hides everything under `work/` at the top level, so the two never collide and a
definition update (`git reset --hard origin/main`) never touches live runtime
state. See `docs/persistence.md` → **Two stores: shared live state + durable backup**.
Treat `work/` as confidential: it may hold private data (roster Slack IDs,
preferences, logs), and it leaves the agent only via this backup or the
configured output surfaces (`CLAUDE.md` → **Hard invariants**).

## Files

- [`CLAUDE.md`](CLAUDE.md) — the slim core manual loaded by the agent on every
  run (run types, pre-flight contract, config semantics, hard invariants).
- [`scripts/preflight.sh`](scripts/preflight.sh) — deterministic pre-flight for
  both run types; detects work, never acts on GitHub.
- [`scripts/verify-onboarding.sh`](scripts/verify-onboarding.sh) — one-shot
  post-onboarding structure check (ONBOARDING Step 7): definition checkout +
  `work/` state files against the templates; prints `FAIL … — fix: …` lines
  for the agent to apply, offline and read-only.
- [`scripts/log.sh`](scripts/log.sh) + [`scripts/harness/`](scripts/harness/) —
  structured events log (`work/logs/events-*.jsonl`, 14-day retention) and the
  per-harness adapters that auto-capture failed tool calls (`docs/logging.md`).
- [`scripts/tests/`](scripts/tests/) + [`.github/workflows/ci.yml`](.github/workflows/ci.yml) —
  deterministic stub tests for `preflight.sh` (gh/curl faked, offline) and the
  CI that runs them plus the `docs/self-modification.md` §9 sweeps on every PR.
- [`.agents/skills/`](.agents/skills/) — review skills bundled with the
  definition (installed via a `## Review skills` row with `source` = the
  instance's `definition_repo`): [`issue-fit`](.agents/skills/issue-fit/SKILL.md)
  — does the diff deliver what the linked issue asked.
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
