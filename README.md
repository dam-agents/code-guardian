# code-guardian

PR code review agent for any GitHub repository. The target repo is named at
onboarding and stored in `work/CONFIG.md`. Built on the Claude Code harness, it
uses the GitHub CLI (`gh`) to fetch open pull requests and delivers a structured
review to the chat UI and the GitHub PR thread. Optionally — opt-in at
onboarding — it also nudges reviewers on Slack when PRs wait too long for human
review (the **PR Shepherd** role).

## How it works

Five kinds of scheduled run exist, and **all start with the deterministic
pre-flight script** [`scripts/preflight.sh`](scripts/preflight.sh). The script
only *detects*: it makes no GitHub writes and computes the run's worklist. With
work, the agent performs all of it per the [`docs/`](docs/) procedures.

An empty worklist starts no session at all. Every schedule except the weekly
audit runs the pre-flight as its platform **`precheck`**
([`scripts/precheck.sh`](scripts/precheck.sh)): the gate's exit code decides
whether the model is woken, so idle heartbeats — about three quarters of all
ticks — cost nothing, and a started run receives the worklist the gate already
computed instead of recomputing it. Bookkeeping that nobody waits on — prunes,
self-heals, status resets — does not wake the model on its own either: it
rides along with the next run that has real work
([`docs/worklist.md`](docs/worklist.md) → **The schedule gate**).

**Review heartbeat** — every 5 minutes inside the active window (default
Mon–Fri 08–21 platform time), hourly in the quiet hours outside it.
`preflight.sh review` lists open non-draft PRs in one REST call and decides per
PR what is due:

- Never-reviewed PRs get a first review automatically. Already-reviewed PRs get
  a re-review **only on an explicit trigger** — the `rereview_label`, or
  GitHub's "Re-request review" when `rereview_trigger` enables it. New commits
  alone just flip the tracking row to `awaiting_label`.
- Same-HEAD PRs are skipped via `work/REVIEWS.md` plus the remote dedup-marker
  check, with self-heal. Closed and merged PRs are verified per PR and queued
  for pruning. PRs carrying the optional `urgent_label` jump the queue and get
  a rapid, criticals-only review that approves when it finds no critical,
  before the full one.
- The agent then follows [`docs/review.md`](docs/review.md) +
  [`docs/skills.md`](docs/skills.md): context and diff, clone, every configured
  review skill, HEAD freshness re-verified right before posting, one GitHub
  review (summary + inline comments, signed with `bot_display_name`, carrying
  the hidden dedup marker), label bookkeeping, and tracking in
  `work/REVIEWS.md` and `work/reviews/pr-<number>.md`. Reviews are concise and
  assume agent-written, agent-read code. Re-review scope follows the trigger:
  the label asks for the whole PR again, a review request or on-demand ask for
  the delta only.
- The same heartbeat answers comments and PR descriptions addressed to the bot:
  questions get a reply, explicit review feedback is recorded to memory and
  confirmed in the reply, and "please re-review" is served on demand
  ([`docs/mentions.md`](docs/mentions.md)).
- With the admin's opt-in (`auto_merge`, off by default), the same heartbeat
  merges a PR a person labeled with `auto_merge_label` once the review approved
  it as a quick check and every gate holds — clean mergeable state, green
  checks, size cap, no `.github/` or sensitive path
  ([`docs/auto-merge.md`](docs/auto-merge.md)).
- With the admin's opt-in (`agent_fixes`, off by default), a person's
  `agent_fix_label` asks for one round in which the agent fixes its own
  blocking findings and pushes one commit to the PR branch — never to a fork,
  never past a commit pushed meanwhile; such a PR never auto-merges
  ([`docs/agent-fixes.md`](docs/agent-fixes.md)).

**Shepherd sweep** — hourly on working days and hours; exists only when Slack
notifications were enabled. `preflight.sh shepherd` classifies every open
non-draft PR from independent reviews and applies the age gate, cooldown and
escalation ladder, flagging merge-conflicted PRs for an author-directed rebase
nudge. The agent sends each due nudge to the shared Slack channel and records
it immediately after the send — send-then-record, roster-only mentions
([`docs/shepherd.md`](docs/shepherd.md)). A reviewer nudge carries the
review's triage — estimated minutes, what a person must judge, what was
checked — and `shepherd_scope: needs_human` skips PRs the review called a
quick check.

**Weekly audit** — Friday morning by default, on while `audit_report` is
enabled (the default).
`preflight.sh audit` computes 7-day statistics and deterministic health checks
(auth and rate limit, missed heartbeats, error log lines, state consistency
against the GitHub markers, stale locks, disk usage, skill
freshness, roster sanity, 👍/👎 reactions). The agent adds the judgment checks —
schedules, memory-rule compliance, nudge integrity, lessons from 👎-flagged
findings — and sends a traffic-light report to Slack when enabled, and to the
chat UI always ([`docs/audit.md`](docs/audit.md)).

**Codebase survey** — weekly in a quiet hour, gated by `survey`. A review reads
a diff; a survey reads one area of the repository as it stands and reports what
a diff structurally cannot show. The area is chosen deterministically (never
surveyed first, then the oldest pass), the pass is capped before it starts, and
the history accumulates in one artifact with a stable URL
([`docs/survey.md`](docs/survey.md)).

**Weekly trends** — every audit also appends its measured week to
`work/audit/` and republishes one accumulated artifact: volume, findings and
their acceptance, latency, spend per week and per review, stalls and error
counts, plus the repository's own health — how much of what merged was
reviewed, median PR size, how long a PR waits for its first **human** review,
and which areas carry the findings — as a summary against the previous week
and the 4-week average, inline charts and one row per week. The history is
append-only, the report is regenerated from it, and the whole step is two
deterministic script calls — no model calls ([`docs/trends.md`](docs/trends.md)).

**Model benchmark** — the 1st of the month by default; exists only when the
`benchmark` key was enabled. The agent replays ≥5 synthetic review fixtures
with known seeded defects through its full pipeline, measures time and tokens
per review, scores each output against the fixture's manifest, and republishes
an accumulated report. Every result is kept forever with full provenance, so
review quality stays comparable across model, harness and definition versions,
and unrecorded **trial runs** score a feature branch during development. Two
deterministic gates
([`scripts/benchmark-validate.sh`](scripts/benchmark-validate.sh)) keep the
history trustworthy: a fixture set whose ground truth leaks into the reviewed
code is never scored, and results that drift from the documented shape never
enter it ([`docs/benchmark.md`](docs/benchmark.md)).

**The definition is split so the always-loaded part stays small.**
[`CLAUDE.md`](CLAUDE.md) holds only the run types and the rule to read
[`docs/runbook.md`](docs/runbook.md) once preflight reports work; the runbook
holds the run procedures and the hard invariants; every other procedure lives
in its own `docs/` file, read only when the matching work happens — a review
run reads exactly the `read_set` preflight computes for its worklist. An idle
heartbeat loads nothing.

**The definition is versioned** ([`VERSION`](VERSION) +
[`CHANGELOG.md`](CHANGELOG.md)). At updates, on demand, and before any
self-modification the agent checks version freshness, applies the changelog's
upgrade steps, and warns the operator when the instance is outdated
([`docs/persistence.md`](docs/persistence.md) → **Definition version &
upgrade**).

**Feedback persists.** What the user says in chat, or in a PR comment addressed
to the bot, goes to `work/MEMORY.md` (global) or to that PR's
`## PR-local overrides` (PR-specific), so later runs respect it and never
re-flag a dismissed finding. The agent also learns passively: generalizable
insights from human reviews and author replies are recorded as observed
insights, and the weekly audit consolidates them — merge, promote to rules,
drop stale — so memory stays useful and bounded
([`docs/preferences.md`](docs/preferences.md)).

## Setup

Bringing up a new code-guardian agent takes three steps — or one, on a
platform whose starter kit catalog offers this repository: creating the
agent from the **Code Guardian** kit grants the connections, registers the
schedules and points the first turn at [`ONBOARDING.md`](ONBOARDING.md),
which then asks for the repository to review.

Bringing it up by hand:

1. **Create the agent** on the platform, with GitHub — and optionally Slack —
   connections granted (see **Connections**).
2. **Grab the link to [`ONBOARDING.md`](ONBOARDING.md)** — **from the repo or
   fork you actually deploy from**, for example
   `https://github.com/<your-org>/code-guardian/blob/main/ONBOARDING.md`. The
   agent derives its *definition repo* from this URL, host included, so a
   GitHub Enterprise URL works the same; it is stored as `definition_repo`, so
   a fork's agent stays pinned to the fork and never resets itself to upstream.
3. **Tell the agent**, in its first message:

   > Here is a file — read it and set yourself up according to it: https://github.com/<your-org>/code-guardian/blob/main/ONBOARDING.md

That is a complete initialization. The agent checks out its own definition,
wires up `work/`, walks you through a short configuration dialog (bot name,
review marker, skills repo, Slack — each value lands in `work/CONFIG.md`),
registers the schedules (the review heartbeat on its two cadences, the Friday
audit, plus the hourly shepherd sweep, the monthly benchmark and the weekly
survey when their keys are enabled), and marks itself
onboarded so it never repeats the process.

### Slack notifications (optional, chosen at onboarding)

One onboarding question is: **do you want Slack notifications?** — the PR
Shepherd reviewer nudging.

- **No**, or no answer → the agent never touches Slack. Reviews still land in
  the chat UI and on GitHub; only the nudging is off.
- **Yes** → the agent walks you through building the reviewer roster
  (`work/DEVELOPERS.md`), the only set of people it may ever @-mention:
  1. It imports your team's GitHub logins from a **GitHub org team** (it lists
     the org's teams and you pick one), falling back to the repo's top
     contributors when there is no usable team. You can prune or extend the
     list.
  2. It drafts the roster with names and seed expertise keywords derived from
     each member's recent PRs.
  3. You paste each member's **Slack member ID** (in Slack: profile → ⋮ →
     *Copy member ID*), one `login = U…` line per member. Slack IDs cannot be
     resolved automatically.

The decision is stored in `work/CONFIG.md` and can be changed later by telling
the agent; it flips the flag, and builds the roster on first enable.

Independently of this opt-in, **anyone** in the connected channel — or, in a
GitHub comment @-mentioning the bot, an account `mention_authors` admits — can
ask the agent to review a specific PR, equivalent to adding the re-review
label, including restarting a stuck review (`docs/review-on-demand.md` →
**On-demand review**). Any other change
request from a channel is declined and automatically filed as a tracking issue
on the definition repo, with the link in the reply (`docs/runbook.md` →
**Instruction sources & trust boundary**).

## Configuration

The agent reads **no environment variables of its own**: onboarding asks for
the target repository and the optional state-backup repository and stores both
in `work/CONFIG.md` (`github_repo`, `work_repo`), which every scheduled run
reads from a fresh shell. `GH_HOST` is the only ambient value it honours, and
only to name the default GitHub host.

### `work/CONFIG.md` — instance configuration

The definition is project-agnostic: everything specific to one deployment lives
in `work/CONFIG.md`, which **onboarding fills in interactively**, auto-detecting
what it can and asking for the rest. Per-key semantics are in
[`docs/config.md`](docs/config.md); summary:

| Key | Filled at onboarding by | Purpose |
| --- | --- | --- |
| `github_repo` | Step 0 answer | Target-repo reference (`[host/]owner/repo`) — the only source the runtime reads. |
| `work_repo` | Step 0 answer (optional) | Repo backing `work/` up (`[host/]owner/repo`); omitted = local-only persistence (`docs/persistence.md`). |
| `definition_repo` | derived from the ONBOARDING.md URL, host included | The repo this definition came from (fork-aware) — outer-repo `origin`, target of definition PRs, review-footer link. |
| `definition_branch` | derived from the ONBOARDING.md URL, else `main` | Branch of `definition_repo` **this instance runs from**. A per-agent deployment choice; definition PRs are still based on `main`. |
| `bot_login` | auto-detected via `gh api user`, confirmed | GitHub login the agent acts as — artifact assignee gate, "independent reviewer" classification. |
| `bot_display_name` | asked (default `Code Guardian`) | Name the agent signs reviews with. Cosmetic only. |
| `review_marker` | asked (default `code-guardian:review`) | Prefix of the hidden dedup marker in every posted review. **Immutable once the first review is posted.** |
| `rereview_label` | asked (default `code-guardian-review`) | PR label that requests a **complete** re-review. Without a trigger, new commits are not re-reviewed. The agent removes the label once the re-review is posted. |
| `rereview_trigger` | asked with `rereview_label` (default `label`) | How re-reviews are requested: `label`, `review-request` (needs the bot as a collaborator), or `both`. A served review request clears itself. |
| `urgent_label` | asked with the labels (default off) | Optional **human-managed** label marking a PR urgent: its due reviews jump the queue and run rapid-first (a rapid pass without a critical finding approves), and with Slack enabled a newly urgent PR gets one immediate mention-free channel alert (`docs/review-urgent.md` → **Urgent PRs**). |
| `review_progress` | asked (default `disabled`) | Publishes each review's progress to the PR as a commit status on the reviewed SHA (`docs/review-bookkeeping.md` → **Progress signal on GitHub**). Always `success` when it finishes, so it never gates a merge; the `context` is the instance's `review_marker`. |
| `ci_triage` | asked (default `disabled`) | After a review posts, a failing check on the reviewed SHA gets one comment with the probable cause and the smallest fix (`docs/ci-triage.md`). Reads and explains only — it never restarts a job, changes a label, or changes a verdict. |
| `mention_replies` | defaulted to `enabled` | GitHub comments addressed to the bot are answered every heartbeat — replies, feedback recorded to memory, review requests served (`docs/mentions.md`). |
| `mention_authors` | defaulted to `collaborators` | Whose GitHub mentions are handled: repository owners, members and collaborators, or `anyone` (`docs/config.md`). |
| `project_profile` | defaulted to `enabled` | Generated map of the reviewed repository (`work/PROFILE.md`), kept current by a structural fingerprint and handed to every review and skill subagent — orientation only, never evidence (`docs/profile.md`). |
| `artifact_skill` | defaulted to `pr-artifact@dam-agents/dam` | Visual-artifact skill with its own source (`<skill>@<[host/]owner/repo>`), published to the DAM Artifact Library (best-effort behind the owner's experimental flag); `none` disables the feature. |
| `## Review skills` table | defaulted to the public set (issue-fit + doc-drift + typescript-engineering + react-ui-engineering), operator-adjustable, every row validated | Per-PR review skills: name, **per-skill source** (`[host/]owner/repo`, or `harness`), trigger (`always` or an extension list), and the review-section heading. The definition holds the mechanics; this table defines *what* runs *when* and *from where*. |
| `## Watch rules` table | not filled — added later in chat when a team asks | Instance-local "when a PR does X, give a heads-up in Y" rules, delivered to vetted targets: chat UI, a Slack channel, or a PR comment (`docs/watches.md`). Keeps team-specific triggers out of this public definition. |
| `slack_notifications` | asked (default `disabled`) | Gates all Slack activity (shepherd nudging, watch notifications). |
| `audit_report` | defaulted to `enabled` | Weekly health check and report (Slack when enabled, chat UI otherwise). |
| `benchmark` | asked (default off) | Monthly self-benchmark of the review pipeline on ≥5 synthetic fixtures with known defects, time and tokens measured per review (`docs/benchmark.md`). |
| `benchmark_judge` | asked with `benchmark` (default `off`) | Pinned model id for the LLM-judged quality scores; `off` = deterministic scoring only. |
| `merge_ready_nudge` | asked with Slack (default `disabled`) | One Slack line when a PR is approved, conflict-free, green and carries no open critical of the agent's own — once per approval, to the author (`docs/shepherd.md` → **Ready to land**). |
| `shepherd_scope` | asked with Slack (default `all`) | `needs_human` limits reviewer nudges to PRs whose current review did not call a quick check (`docs/shepherd.md` → **Scope and brief**). |
| `human_review_paths` | asked with auto-merge or Slack (default none) | Globs of files that always make a PR's triage `needs-human` (`docs/review-mechanics.md` → **Summary body format**). |
| `auto_merge`, `auto_merge_label`, `auto_merge_max_lines`, `auto_merge_method` | asked of the repo admin (default off) | Merges a PR a person labeled, that the review approved as a quick check and that passes every gate — clean mergeable state, green checks, size cap, no `.github/` or sensitive path (`docs/auto-merge.md`). |
| `agent_fixes`, `agent_fix_label` | asked of the repo admin (default off) | A person's label asks for one round in which the agent fixes its own blocking findings and pushes one commit to the PR branch, never to a fork; such a PR never auto-merges (`docs/agent-fixes.md`). |
| `survey` | asked (default `disabled`) | Weekly deep pass over one area of the repository — unreachable code, duplicated logic, untested paths, drift from the repo's own conventions and decision records (`docs/survey.md`). One area per run, capped, read-only: it never changes code and never posts on a PR. |
| `survey_report` | asked with `survey` (default `dam`) | Surface for the accumulated survey artifact, updated in place at a stable URL: `dam` or `off`. |
| `survey_interval_days` | not set (= `7`) | The floor between two survey passes, so a drifting cron never surveys twice in one interval. |
| `audit_trend` | defaulted to `dam` | Surface for the weekly trend artifact, updated in place at a stable URL: `dam` or `off`. |
| `benchmark_report` | asked with `benchmark` (default `dam`) | Surface for the accumulated report artifact, updated in place at a stable URL: `dam` or `off`. |
| `## Benchmark model prices` table | offered with `benchmark` (optional) | Per-MTok USD prices that price the `est $` columns of the benchmark report and the weekly trends (`docs/benchmark.md` → **Model prices**). |
| `active_hours`, `active_days`, `review_interval_active`, `review_interval_quiet` | asked (default Mon–Fri `08-21`, 5 min active / 60 min quiet) | The heartbeat's two cadences and the window between them. Each interval bounds how long a new PR waits for its run; a tick with no work costs one pre-flight pass and no model call, so the choice is latency, and the quiet interval is what a night or weekend PR waits. They are the source of truth for the registered crons (`ONBOARDING.md` Step 6a) — an edited key takes effect once the schedules are re-registered. |
| `stall_alert_threshold` | not set (= `4`) | Stalled reviews within 24 h that trigger one alert, at most once per UTC day; `0`/`off` disables. |
| `cost_alert_factor` | not set (= `4`) | A review costing more than this × the median of its model's last 30 reviews triggers one alert; `0`/`off` disables. |
| `log_level` | not set (= `info`) | Verbosity of the structured events log `work/logs/events-*.jsonl` (`docs/logging.md`); `debug` also records successful external tool calls. |
| `escalation_owner` | asked (only when Slack enabled) | Roster member @-mentioned at nudge level 4, and the DM target of the stalled-review alert. |

### Runtime requirements

- **Platform:** the agent assumes the DAM agent infrastructure — `$HOME` at
  `/home/agent` on a persistent `/workspace` volume, the platform's outbound
  auth proxy for GitHub tokens, and the `mcp__platform-outbound__*` tools for
  schedules and Slack. Running elsewhere requires adapting those assumptions.
- **GitHub hosts:** every repo reference is `[<host>/]<owner>/<repo>`, so the
  target repo, this definition, the skill sources and the `work_repo` backup may
  each live on a different host — `github.com` or a GitHub Enterprise instance.
  Each host in play must be authenticated separately
  (`gh auth login --hostname <host>`, operator-only) and reachable from the
  pod; a non-`github.com` target host is persisted as `GH_HOST` at onboarding.
- **GitHub identity:** the agent posts reviews and comments as the
  account behind its token. Use a **dedicated machine or bot account**, not a
  personal one, that is a collaborator on the target repo with permission to
  review PRs. GitHub ignores review requests and approvals from a PR's own
  author, so the bot account must not open the PRs it reviews.
- **Token scopes** — the single place these are specified:

  | Scope | Required? | What needs it |
  | --- | --- | --- |
  | `repo` | **yes** | PRs, reviews, comments, labels and issues on the target repo; push to the `work_repo` backup and the definition repo |
  | `read:org` | optional | Onboarding only: lists your org's **teams** to seed the reviewer roster. Without it onboarding falls back to the repo's top contributors; no scheduled run uses it |

  The audit's `token_scopes` check asserts the required ones only. A missing
  scope is **operator-only** to fix: the agent reports it and never works
  around it.
- **External services:** artifacts and reports publish to the platform's DAM
  Artifact Library (best-effort, behind the owner's experimental flag), whose
  `visibility:"public"` share URL is reachable by anyone holding it. The HTML
  passes a redaction pass before the publish (`docs/artifact.md`).

### Connections

- A **GitHub** connection must be granted so `gh` can authenticate (the Envoy
  sidecar injects the OAuth token on outbound GitHub requests). The same token
  serves the target repo, the `work_repo` backup and the definition repo.
- A **Slack** connection is **optional**, needed only when Slack notifications
  are enabled, so `mcp__platform-outbound__send_channel_message` can reach the
  shared channel. With notifications disabled — the default — the agent never
  calls Slack and the full review pipeline runs unaffected.

## Persistence

`work/MEMORY.md`, `work/REVIEWS.md` and `work/reviews/` hold the agent's
learned preferences and review history. `work/CONFIG.md` and — with Slack
enabled — `work/DEVELOPERS.md` (reviewer roster) and `work/SHEPHERD.md` (nudge
ledger) live alongside them. They sit on the `/workspace` PVC at runtime
(mounted as `/home/agent/work/`), so they survive pod restarts. How `work/` is
seeded depends on the `work_repo` key:

- **Set** — `work/` is a plain data directory backed up to that repo after
  every run, via a disposable tmpfs clone, giving durable, versioned,
  cross-pod history. Naming an existing backup at onboarding continues that
  agent: state and logs return verified, and the accumulated reports are
  published again (`docs/persistence.md` → **After a restore**).
- **Omitted** — `REVIEWS.md` and `reviews/` are reconstructed from the agent's
  marker-carrying reviews on the target repo; `MEMORY.md`, which is not
  derivable from PRs, starts from the seed template in `ONBOARDING.md`
  (Step 3b).

`work/` is **not tracked** by this definition repo: the allowlist `.gitignore`
hides everything under it, so the two never collide and a definition update
never touches live runtime state (`docs/persistence.md` → **Two stores: shared
live state + durable backup**). Treat `work/` as confidential — it may hold
private data (roster Slack IDs, preferences, logs), and it leaves the agent
only via this backup or the configured output surfaces (`docs/runbook.md` →
**Hard invariants**).

## Files

- [`CLAUDE.md`](CLAUDE.md) — the bootstrap loaded on every run: repo
  resolution, run types, and the rule to read the runbook once preflight
  reports work.
- [`docs/runbook.md`](docs/runbook.md) — the operating manual read only then:
  run procedures, trust boundary, hard invariants, and the map of `docs/`.
- [`docs/worklist.md`](docs/worklist.md) — the schedule gate, the entry
  command and the worklist contract, read by a run without a gated worklist.
- [`scripts/preflight.sh`](scripts/preflight.sh) — deterministic pre-flight for
  every run type; detects work, never acts on GitHub.
- [`scripts/precheck.sh`](scripts/precheck.sh) — the schedule gate: one
  pre-flight pass before the session starts, an exit code that skips an idle
  fire, and the worklist path a started run reads.
- [`scripts/verify-onboarding.sh`](scripts/verify-onboarding.sh) — one-shot
  post-onboarding check (ONBOARDING Step 7): definition checkout and `work/`
  state files against the templates, and with `--live` the environment a run
  needs (auth per host, repo access, re-review label, skill sources, one
  read-only `preflight.sh review`). Prints `FAIL … — fix: …` lines, read-only
  throughout.
- [`scripts/review-pr.sh`](scripts/review-pr.sh) — the mechanical half of one
  PR review: `prepare` (Check 1, lock, context, diff with hunk index, clone,
  skill briefs, the prior findings), `step`, `guard` (the live HEAD re-read at a
  phase boundary, so a commit landing mid-review stops the run before it pays
  for the phases below it), `context`, `sweep`, `collect`, `delta` (fixed/still/new plus the
  annotated findings, `--settle` for the ambiguous pairs), `compose-brief` (this PR's compose contract, with the
  conversation refreshed), `rapid`, `post` (Check 2, dedup, inline eligibility,
  payload, 422 handling, label, history, cleanup), `verify` (the self-check's
  mechanical lines, local reads only) and `abort`. The agent
  decides what the review says.
- [`scripts/profile.sh`](scripts/profile.sh) — the project profile: builds and
  refreshes `work/PROFILE.md` from the target repo's default branch
  (fingerprint-driven) and slices it per PR for the worklist.
- [`scripts/log.sh`](scripts/log.sh) +
  [`scripts/harness/`](scripts/harness/) — the structured events log
  (`work/logs/events-*.jsonl`, 14-day retention) and the per-harness adapters
  that auto-capture failed tool calls and, on Claude Code, keep unused tools
  out of every request.
- [`scripts/tests/`](scripts/tests/) +
  [`.github/workflows/ci.yml`](.github/workflows/ci.yml) — deterministic stub
  tests for `preflight.sh` (gh/curl faked, offline) and the CI that runs them
  plus the `docs/self-modification.md` §9 sweeps on every PR.
- [`.agents/skills/`](.agents/skills/) — skills bundled with the definition.
  Review skills install via a `## Review skills` row whose `source` is the
  instance's `definition_repo`:
  [`issue-fit`](.agents/skills/issue-fit/SKILL.md) — does the diff deliver what
  the linked issue asked.
  [`review-remediation`](.agents/skills/review-remediation/SKILL.md) is the
  author-side one: install it in whichever agent answers the reviews, to fix
  every blocking finding at every location and run the checks the review
  carries. It asks the caller about the findings a recorded decision of the
  pull request makes disputable, and disputes those in writing. Its `scripts/review-worklist.sh` reads all of that from the review
  over REST, and `--verify` checks the work against it before the push; the
  next review round stays the caller's to start.
  [`pr-open`](.agents/skills/pr-open/SKILL.md) is its first-push counterpart:
  it self-reviews the branch, declares the scope in the PR body and records
  the person's decisions in a hidden `author-decisions` block, which the
  reviewer reads.
- [`docs/`](docs/) — the procedures, read on demand:
  [`review.md`](docs/review.md), [`review-rereview.md`](docs/review-rereview.md),
  [`review-urgent.md`](docs/review-urgent.md),
  [`review-bookkeeping.md`](docs/review-bookkeeping.md),
  [`review-on-demand.md`](docs/review-on-demand.md),
  [`review-mechanics.md`](docs/review-mechanics.md),
  [`finding-form.md`](docs/finding-form.md),
  [`skills.md`](docs/skills.md), [`profile.md`](docs/profile.md),
  [`config.md`](docs/config.md), [`mentions.md`](docs/mentions.md),
  [`watches.md`](docs/watches.md), [`artifact.md`](docs/artifact.md),
  [`ci-triage.md`](docs/ci-triage.md), [`shepherd.md`](docs/shepherd.md),
  [`audit.md`](docs/audit.md), [`trends.md`](docs/trends.md),
  [`survey.md`](docs/survey.md), [`benchmark.md`](docs/benchmark.md),
  [`preferences.md`](docs/preferences.md),
  [`persistence.md`](docs/persistence.md), [`logging.md`](docs/logging.md),
  [`self-modification.md`](docs/self-modification.md).
- [`ONBOARDING.md`](ONBOARDING.md) — the first-run setup runbook; it also
  carries the `work/MEMORY.md` and `work/REVIEWS.md` seed templates (Step 3b).
- [`kit.yaml`](kit.yaml) — the starter kit this definition is offered as:
  the connections it asks for, the schedules it registers, the bundled
  skills and the seed. A catalog entry points here and the platform reads
  it at a commit, so the kit and the definition it describes move together.
- [`VERSION`](VERSION) + [`CHANGELOG.md`](CHANGELOG.md) — definition semver,
  bumped with every change, and the per-version upgrade steps instances apply.
- [`LICENSE`](LICENSE) — Apache License 2.0.

## License

Apache License 2.0 — see [`LICENSE`](LICENSE).
