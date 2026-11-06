# code-guardian

PR code review agent for any GitHub repository. The target repo is named at
onboarding and stored in `work/CONFIG.md`. It runs on the Claude Code, pi,
Bob and Copilot harnesses ([docs/logging.md](docs/logging.md) → **Harness adapters**),
uses the GitHub CLI (`gh`) to fetch open pull requests and delivers a structured
review to the chat UI and the GitHub PR thread. Optionally — opt-in at
onboarding — it also nudges reviewers on Slack when PRs wait too long for human
review (the **PR Shepherd** role).

## How it works

Every scheduled run starts with a deterministic detector —
[`scripts/preflight.sh`](scripts/preflight.sh), or
[`scripts/monitor.sh`](scripts/monitor.sh) for the health monitor — that makes
no GitHub writes and computes the run's worklist; the agent then does the work
per the [`docs/`](docs/) procedures. Every schedule except the weekly audit runs
its detector as the platform **`precheck`**
([`scripts/precheck.sh`](scripts/precheck.sh)), so an empty worklist starts no
session ([`docs/worklist.md`](docs/worklist.md) → **The schedule gate**). Each
session carries a title such as `Review PR #1457`
([`docs/runbook.md`](docs/runbook.md) → **Session titles**).

**Review heartbeat** — every 5 minutes by default (15 in quiet hours outside an
optional active window). A never-reviewed PR gets a first review; an
already-reviewed PR is re-reviewed only on an explicit trigger — the
`rereview_label`, `rereview_delta_label`, a GitHub review request under
`rereview_trigger`, or a `guide_label` no round saw yet. A draft is listed only
while it carries a review label; an `urgent_label` PR jumps the queue
rapid-first. The review follows [`docs/review.md`](docs/review.md) +
[`docs/skills.md`](docs/skills.md) and posts one GitHub review with a hidden
dedup marker. The same heartbeat answers comments addressed to the bot
([`docs/mentions.md`](docs/mentions.md)) and, with the admin's opt-ins, merges a
labeled quick-check PR ([`docs/auto-merge.md`](docs/auto-merge.md)) or fixes its
own findings on a labeled PR ([`docs/agent-fixes.md`](docs/agent-fixes.md)).

**Shepherd sweep** — hourly on working days and hours, Slack only. Sends due
reviewer and rebase nudges to the shared channel, roster-only mentions,
send-then-record ([`docs/shepherd.md`](docs/shepherd.md)).

**Health monitor** — every 15 minutes; a tick with no alert starts no session.
Detects outages, refusals, a silent schedule, a failing backup and stalled or
anomalous reviews from local logs; with the opt-ins it DMs its alerts itself and
publishes a health dashboard ([`docs/monitor.md`](docs/monitor.md),
[`docs/health.md`](docs/health.md)).

**Weekly audit** — Friday morning by default, under `audit_report`. 7-day
statistics, deterministic and judgment health checks, a traffic-light report to
the chat UI and Slack ([`docs/audit.md`](docs/audit.md)), and the accumulated
weekly trends artifact ([`docs/trends.md`](docs/trends.md)).

**Daily brief** — weekday mornings, under `daily_brief` and Slack: one message
of what the merged PRs changed ([`docs/brief.md`](docs/brief.md)).

**Codebase survey** — weekly in a quiet hour, under `survey`: a security pass
over one area of the repository as it stands
([`docs/survey.md`](docs/survey.md)).

**Model benchmark** — monthly, under `benchmark`: replays synthetic review
fixtures with seeded defects, scores them and republishes an accumulated report
([`docs/benchmark.md`](docs/benchmark.md)).

**The definition is split so the always-loaded part stays small.**
[`CLAUDE.md`](CLAUDE.md) holds the run types and the rule to read
[`docs/runbook.md`](docs/runbook.md) when there is work; every other procedure
lives in its own `docs/` file, read only when its work happens.

**The definition is versioned** ([`VERSION`](VERSION) +
[`CHANGELOG.md`](CHANGELOG.md)); instances apply the upgrade steps
([`docs/persistence.md`](docs/persistence.md) → **Definition version &
upgrade**).

**Feedback persists** in `work/MEMORY.md` or a PR's `## PR-local overrides`, and
the audit consolidates observed insights
([`docs/preferences.md`](docs/preferences.md)).

## Setup

On a platform whose starter kit catalog offers this repository, create the agent
from the **Code Guardian** kit ([`kit.yaml`](kit.yaml)): it grants the
connections, registers the schedules and points the first turn at
[`ONBOARDING.md`](ONBOARDING.md).

By hand:

1. **Create the agent** on the platform, with GitHub — and optionally Slack —
   connections granted (see **Connections**).
2. **Grab the link to [`ONBOARDING.md`](ONBOARDING.md)** — **from the repo or
   fork you actually deploy from**, for example
   `https://github.com/<your-org>/code-guardian/blob/main/ONBOARDING.md`. The
   agent derives `definition_repo` and `definition_branch` from this URL, host
   included, so a fork's agent stays pinned to the fork.
3. **Tell the agent**, in its first message:

   > Here is a file — read it and set yourself up according to it: https://github.com/<your-org>/code-guardian/blob/main/ONBOARDING.md

Onboarding checks out the definition, provisions `work/`, asks the
configuration questions, registers the schedules and writes a sentinel so it
never repeats.

**Slack notifications** are opt-in at onboarding (default off) and gate every
Slack message. A yes builds the reviewer roster `work/DEVELOPERS.md` — the only
people the agent may @-mention — with each member's Slack member ID. Without
Slack, reviews, reports and alerts still land in the chat UI and on GitHub.
Anyone in the connected channel, or an admitted GitHub mention, can ask for a
review ([`docs/review-on-demand.md`](docs/review-on-demand.md) → **On-demand
review**). An error report from a running environment teaches the review its
defect class ([`docs/escapes.md`](docs/escapes.md)); any other channel request
is declined
([`docs/runbook.md`](docs/runbook.md) → **Instruction sources & trust
boundary**).

## Configuration

The agent reads **no environment variables of its own**: every value lives in
`work/CONFIG.md`, which onboarding fills in. `GH_HOST` is the only ambient value
it honours, and only to name the default GitHub host.

### `work/CONFIG.md` — instance configuration

Per-key semantics are in [`docs/config.md`](docs/config.md); summary:

| Key | Filled at onboarding by | Purpose |
| --- | --- | --- |
| `github_repo` | Step 0 answer | Target repo (`[host/]owner/repo`) — the only source the runtime reads. |
| `work_repo` | Step 0 answer (optional) | Private repo backing `work/` up; omitted = local-only. |
| `definition_repo` | derived from the ONBOARDING.md URL, host included | The repo this definition came from (fork-aware): `origin`, definition PRs, review footer. |
| `definition_branch` | derived from the ONBOARDING.md URL, else `main` | Branch this instance runs from. |
| `bot_login` | auto-detected via GraphQL `viewer` (else `gh api user`), confirmed | Account people mention and request (`docs/github-access.md` → **Triggers by identity**). |
| `bot_display_name` | asked (default `Code Guardian`) | Review signature. |
| `review_marker` | asked (default `code-guardian:review`) | Dedup-marker prefix. **Immutable once the first review is posted.** |
| `rereview_label` | asked (default `code-guardian:rereview`) | Label that requests a **complete** re-review. |
| `rereview_trigger` | asked with `rereview_label` (default `label`) | `label`, `review-request` or `both`. |
| `rereview_delta_label` | asked (default off) | Label that requests a **delta** re-review. |
| `urgent_label` | asked with the labels (default off) | Human-managed label for rapid-first reviews (`docs/review-urgent.md` → **Urgent PRs**). |
| `review_progress` | asked (default `disabled`) | Progress check run or commit status on the PR (`docs/review-bookkeeping.md` → **Progress signal on GitHub**). |
| `approve_after_rounds` | asked (default off) | From this review round on, no open 🔴 approves; auto-merge still needs no open 🟡 (`docs/finding-form.md` → **The approval bar**). |
| `ci_triage` | asked (default `disabled`) | One comment explaining a failing check (`docs/ci-triage.md`). |
| `review_dispatch` | asked (default `enabled`) | Each PR after a heartbeat's first runs in its own session (`docs/worklist.md` → **Dispatch**). |
| `session_awareness` | defaulted to `enabled` | Platform session list for holds, dispatch and HEAD signals (`docs/sessions.md`). |
| `mention_replies` | asked (default `enabled`) | Answers GitHub comments addressed to the bot (`docs/mentions.md`). |
| `mention_authors` | asked (default `collaborators`) | Whose mentions are handled: `collaborators` or `anyone`. |
| `project_profile` | asked (default `enabled`) | Generated repository map `work/PROFILE.md` (`docs/profile.md`). |
| `guide_label` | asked with the review guide row (default off) | Label that asks for the review guide (`docs/artifact.md` → **Review guide**). |
| `## Review skills` table | defaulted to the public set (issue-fit + review-guide + doc-drift + typescript-engineering + react-ui-engineering), operator-adjustable, every row validated | Per-PR review skills: name, source, trigger (`always`, `issue` or an extension list), section (`docs/skills.md`); plus the offer of a tailored skill (`docs/tailored-skill.md`). |
| `## Watch rules` table | not filled — added later in chat when a team asks | "When a PR does X, notify Y" rules (`docs/watches.md`). |
| `slack_notifications` | asked (default `disabled`) | Gates all Slack activity. |
| `audit_report` | defaulted to `enabled` | Weekly health report. |
| `definition_issues` | asked (default `disabled`) | Anonymous tracking issues on the definition repo (`docs/runbook.md` → **Definition-repo issues**). |
| `benchmark` | asked (default off) | Monthly self-benchmark (`docs/benchmark.md`). |
| `benchmark_judge` | asked with `benchmark` (recommended answer `auto`; missing = `off`) | Judge of the LLM-judged scores: `auto`, a model id, or `off`. |
| `merge_ready_nudge` | asked with Slack (default `disabled`) | One "ready to land" line per approval (`docs/shepherd.md` → **Ready to land**). |
| `shepherd_scope` | asked with Slack (default `needs_human`) | `needs_human` or `all` (`docs/shepherd.md` → **Scope and brief**). |
| `human_review_paths` | asked with auto-merge or Slack (default none) | Sensitive globs: named to the triage call, never auto-merged. |
| `auto_merge`, `auto_merge_label`, `auto_merge_max_lines`, `auto_merge_method` | asked of the repo admin (default off) | Merge of a labeled quick-check PR that passes every gate (`docs/auto-merge.md`). |
| `agent_fixes`, `agent_fix_label` | asked of the repo admin (default off) | One fix round on a labeled PR (`docs/agent-fixes.md`). |
| `survey` | asked (default `disabled`) | Weekly security survey (`docs/survey.md`). |
| `survey_report` | asked with `survey` (default `dam`) | Survey artifact surface: `dam` or `off`. |
| `survey_report_findings` | asked with `survey_report: dam` (default `disabled`) | Findings on the public survey artifact, or an index only. |
| `survey_interval_days` | not set (= `7`) | Floor between two survey passes. |
| `daily_brief` | asked with Slack (default `disabled`) | Weekday Slack brief of merged PRs (`docs/brief.md`). |
| `brief_language` | asked with `daily_brief` (default `English`) | Brief language. |
| `audit_trend` | defaulted to `dam` | Weekly trend artifact surface: `dam` or `off`. |
| `benchmark_report` | asked with `benchmark` (default `dam`) | Benchmark report surface: `dam` or `off`. |
| `## Benchmark sufficiency` table | offered with `benchmark` (optional) | The bar per task tier (`docs/benchmark.md` → **Sufficiency by tier**). |
| `## Benchmark model prices` table | offered with `benchmark` (optional) | Per-MTok prices for `est $` columns (`docs/benchmark.md` → **Model prices**). |
| `active_hours`, `active_days`, `review_interval_active`, `review_interval_quiet` | asked (default 24/7: `00-23`, `Mon-Sun`, 5 min; 15 min quiet under a window) | Heartbeat cadence; source of the registered crons (`ONBOARDING.md` Step 6a). |
| `stall_alert_threshold` | not set (= `4`) | Stalled reviews per 24 h recorded as an incident; `0`/`off` disables. |
| `review_anomaly_factor` | not set (= `4`) | Anomalous-review factor over the model's median; `0`/`off` disables. |
| `model_alert_threshold` | not set (= `2`) | API-failure runs in one outage before an alert; `0`/`off` disables. |
| `github_alert_threshold` | not set (= `2`) | Failed PR listings in a row before an alert; `0`/`off` disables. |
| `classifier_alert_threshold` | not set (= `20`) | Classifier refusals per 24 h recorded as an incident; `0`/`off` disables. |
| `log_level` | not set (= `info`) | Events-log verbosity (`docs/logging.md`). |
| `escalation_owner` | asked (only when Slack enabled) | Roster member for nudge level 4 and fallback monitor DMs. |
| `monitor_owner` | asked with the escalation owner (default: not set) | Monitor DM target; not set = `escalation_owner`. |
| `monitor_slack_direct` | asked with the escalation owner (default `disabled`) | Monitor DMs its alerts itself (`docs/monitor.md` → **Direct delivery**). |
| `health_dashboard` | asked (default `off`) | `dam` publishes the health dashboard (`docs/health.md`). |

### Runtime requirements

- **Platform:** the DAM agent infrastructure — `$HOME` at `/home/agent` on a
  persistent `/workspace` volume, the outbound auth proxy for GitHub tokens, and
  the `mcp__platform-outbound__*` tools for schedules, one-time sessions,
  session titles and Slack. The monitor's opt-ins call that server from a
  script at the `platform-outbound` URL of `~/.mcp.json`
  (`scripts/lib/mcp.sh`); the benchmark uses the platform's Driver REST routes
  (`docs/benchmark.md` → **Isolation**). Running elsewhere requires adapting
  those assumptions.
- **GitHub hosts:** every repo reference is `[<host>/]<owner>/<repo>`, so each
  may live on `github.com` or a GitHub Enterprise instance. Each host must be
  authenticated (`gh auth login --hostname <host>`, operator-only) and
  reachable from the pod.
- **GitHub identity:** a user token or a GitHub App installation token
  (`docs/github-access.md`). Use a **dedicated machine or bot account** that is a
  collaborator on the target repo and does not open the PRs it reviews
  (`docs/github-access.md` → **Own pull request**).
- **Token scopes** — the single place these are specified:

  | Scope | Required? | What needs it |
  | --- | --- | --- |
  | `repo` | **yes** | PRs, reviews, comments, labels and issues on the target repo; push to the `work_repo` backup and the definition repo |
  | `read:org` | optional | Onboarding only: lists your org's **teams** to seed the reviewer roster. Without it onboarding falls back to the repo's top contributors; no scheduled run uses it |

  The audit's `token_scopes` check asserts the required ones only. A missing
  scope is **operator-only** to fix. A fine-grained or **GitHub App** token has
  permissions instead (`docs/github-access.md` → **Feature map**).
- **External services:** artifacts and reports publish to the platform's DAM
  Artifact Library (best-effort), whose `visibility:"public"` share URL is
  reachable by anyone holding it; the HTML passes a redaction pass first
  (`docs/artifact.md`).

### Connections

- **GitHub** — required; the Envoy sidecar injects the token on outbound GitHub
  requests. One token serves the target repo, the `work_repo` backup and the
  definition repo.
- **Slack** — optional, needed only when Slack notifications are enabled
  (`mcp__platform-outbound__send_channel_message`).

## Persistence

`work/` — config, memory, review history, roster, ledgers, logs — lives on the
`/workspace` volume and is backed up to `work_repo` after every run, or, when
omitted, rebuilt from the agent's marker-carrying reviews (all but `MEMORY.md`).
The allowlist `.gitignore` keeps it out of the definition repo. Treat it as
confidential ([`docs/persistence.md`](docs/persistence.md) → **Two stores:
shared live state + durable backup**, [`docs/runbook.md`](docs/runbook.md) →
**Hard invariants**).

## Files

- [`CLAUDE.md`](CLAUDE.md) — the bootstrap loaded on every run.
- [`docs/runbook.md`](docs/runbook.md) — run procedures, trust boundary, hard
  invariants and the map of `docs/` (**Map of `docs/`**).
- [`docs/worklist.md`](docs/worklist.md) — the schedule gate, the entry command
  and the worklist contract.
- [`scripts/preflight.sh`](scripts/preflight.sh),
  [`scripts/monitor.sh`](scripts/monitor.sh),
  [`scripts/precheck.sh`](scripts/precheck.sh) — the detectors and the schedule
  gate.
- [`scripts/review-pr.sh`](scripts/review-pr.sh) — the mechanical half of one PR
  review; the agent decides what the review says.
- [`scripts/verify-onboarding.sh`](scripts/verify-onboarding.sh) — read-only
  post-onboarding check (ONBOARDING Step 7).
- [`scripts/log.sh`](scripts/log.sh) + [`scripts/harness/`](scripts/harness/) —
  the structured events log and the per-harness adapters.
- The other [`scripts/`](scripts/) state their contract in their header and
  their `docs/` home.
- [`scripts/tests/`](scripts/tests/) +
  [`.github/workflows/ci.yml`](.github/workflows/ci.yml) — offline stub tests
  and the CI that runs them with the `docs/self-modification.md` §9 sweeps.
- [`.agents/skills/`](.agents/skills/) — bundled skills
  ([`docs/skills.md`](docs/skills.md) → **Where a skill lives**):
  [`issue-fit`](.agents/skills/issue-fit/SKILL.md) and
  [`review-guide`](.agents/skills/review-guide/SKILL.md) (review skills,
  [docs/artifact.md](docs/artifact.md) → **Review guide**),
  [`review-remediation`](.agents/skills/review-remediation/SKILL.md) and
  [`pr-open`](.agents/skills/pr-open/SKILL.md) (the author side),
  [`code-guardian-checks`](.agents/skills/code-guardian-checks/SKILL.md) (this
  repository's tailored skill, [docs/tailored-skill.md](docs/tailored-skill.md)),
  and [`agent-engineering`](.agents/skills/agent-engineering/SKILL.md) (review
  of agent definitions).
- [`ONBOARDING.md`](ONBOARDING.md) — the first-run setup runbook and the `work/`
  seed templates (Step 3b).
- [`kit.yaml`](kit.yaml) — the starter kit: connections, schedules, bundled
  skills, seed.
- [`VERSION`](VERSION) + [`CHANGELOG.md`](CHANGELOG.md) — definition semver and
  per-version upgrade steps.

## License

Apache License 2.0 — see [`LICENSE`](LICENSE).
