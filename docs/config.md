# Runtime configuration — `work/CONFIG.md`

Read this file when a run has no preflight `config` object (the manual
fallback), when the operator asks to change or explain a value, or when a
definition change adds a key ([self-modification.md](self-modification.md) §2).

**This definition is project-agnostic.** Every instance-specific value lives in
`work/CONFIG.md`, created at onboarding (ONBOARDING Step 4) and loaded once at
run start. Each key is one `- <key>: <value>` bullet parsed by the `cfg()`
reader below (surrounding backticks or quotes and trailing `#` comments are
stripped); the rest of the file is prose the runtime ignores. Structure and
connectivity are verified by
`bash "$HOME/scripts/verify-onboarding.sh" [--live]` (ONBOARDING Step 7).

**Every repo reference — `github_repo`, `definition_repo`, `work_repo`, a skill
source — is `[<host>/]<owner>/<repo>`.** Three segments name the GitHub host
(`github.example.com/acme/widgets`), two use the ambient default (`$GH_HOST`,
else `github.com`). Target, definition, skills and work backup may each sit
on a different host. While any host is not `github.com`, write every
reference with its host, `github.com/…` included, so a fresh volume without
the shell's `GH_HOST` resolves it the same (`verify-onboarding.sh` checks
it). `GH_HOST` is exported to the **target** host, and cross-host calls pass
`--hostname` (`gh api`) or `[HOST/]OWNER/REPO`
(`gh pr`/`gh issue`/`gh label -R`).

## In the worklist

`config` — one object per review or shepherd run with work: every key below
with its default applied (`null` for a missing key without one),
`artifact_skill` as effective (`none` when off), `skills_table`
(`[{skill, source, trigger, section}]`) and `watch_rules`
(`[{id, watch_for, notify, note}]`). Runs read their values from it; the reader
below is for the manual fallback and the direct session.

## Keys

### Identity & repositories

- **`github_repo`** — the target-repo reference, written at onboarding.
  **Required**: a missing key stops every run at pre-flight unless the
  last-resort `gh repo view` resolves one.
- **`work_repo`** — the repo that backs `work/` up
  ([persistence.md](persistence.md)). **Missing = local-only persistence**: the
  live state stays on the volume and `scripts/work-backup.sh` is a no-op. The
  key must exist before a restore can run, so onboarding writes it first
  (ONBOARDING Step 3a).
- **`definition_repo`** — the repo this definition was installed from
  (fork-aware). Outer-repo `origin`, target of definition PRs, review-footer
  link. Written at onboarding, which a restore re-installs from; a run with the
  key missing falls back to `git -C "$HOME" remote get-url origin`.
- **`definition_branch`** — the branch of `definition_repo` this instance runs
  from ([persistence.md](persistence.md) → **Tracked branch**). **Missing =
  `main`.** Operator-only to change.
- **`bot_login`** — the GitHub account people mention, assign and request for
  this agent; the token may post as another login, such as a GitHub App
  ([github-access.md](github-access.md)). **Required.** Missing → the
  artifact's assignee trigger, the `review-request` trigger and mention
  handling are off.
- **`bot_display_name`** — signature name (default `Code Guardian`). Cosmetic
  only, never used for dedup.
- **`review_marker`** — prefix of the hidden dedup marker
  `<!-- <review_marker> headRefOid=<full-sha> -->` in every posted review.
  **Required, and immutable once the first review is posted** — a later change
  request is refused with the reason.

### Review triggers & delivery

- **`rereview_label`** — the GitHub label a human adds to request a **complete**
  re-review of the whole PR (default `code-guardian-review`). The other triggers
  get a delta re-review ([review-rereview.md](review-rereview.md) → **Re-review
  output**). First reviews never need it; the agent removes it once the request
  is served. New commits without a trigger flip the tracking row to
  `awaiting_label`.
- **`rereview_trigger`** — what requests a re-review: `label` |
  `review-request` (a pending GitHub review request for `bot_login`) | `both`.
  **Missing = `label`.** `review-request` needs `bot_login` as a user account
  that is a repo collaborator: GitHub cannot request a review from a GitHub App.
  `bot_login` missing or a GitHub App → label-only with one log line. A served
  review request clears itself when the review posts.
- **`rereview_delta_label`** — a GitHub label a human adds to request a **delta**
  re-review: the changes since the last review, as a review request asks
  ([review-rereview.md](review-rereview.md) → **Re-review output**). **Missing =
  off.** It works with every `rereview_trigger` value and every token, so it is
  the delta trigger of a GitHub App `bot_login` ([github-access.md](github-access.md)
  → **Triggers by identity**). The agent removes it once the request is served.
  With `rereview_label` also on the PR, the re-review is complete.
- **`urgent_label`** — a **human-managed** label marking a PR urgent; the agent
  never adds or removes it. While present, the PR's due reviews jump the queue
  and run **rapid-first**: a rapid pass without a 🔴 finding approves the PR
  before the full review (review-urgent.md → **Urgent PRs**). **Missing =
  off.** Not a review trigger — it only modifies how an already-due review is
  delivered.
- **`review_progress`** — `enabled` | `disabled`. **Missing = `disabled`.**
  Publishes each review's progress as a check run or a commit status on the reviewed SHA
  (`context` = `review_marker`): started, in progress with an ETA, terminal
  outcome (review-bookkeeping.md → **Progress signal on GitHub**). Best-effort —
  a failed write never affects the review.
- **`ci_triage`** — `enabled` | `disabled`. **Missing = `disabled`.** After a
  review posts, a failing check on the reviewed SHA gets one comment naming the
  probable cause and the smallest fix ([ci-triage.md](ci-triage.md)). It never
  restarts a job or changes a verdict.
- **`review_dispatch`** — `enabled` | `disabled`. **Missing = `enabled`.** A
  review run that finds several PRs keeps its first and starts every other PR
  at once in a one-time session of its own through the platform's
  `schedule_once` ([runbook.md](runbook.md) → **Review run** step 1,
  [worklist.md](worklist.md) → **Dispatch**). `disabled` keeps every PR in the
  run that found it, one after another.
- **`review_model`** — a model name from the agent's model settings (Claude
  Code: `fable` | `opus` | `sonnet` | `haiku`) | `default`. **Missing =
  `default`.** The model of every session this agent's schedules start: each
  ONBOARDING Step 6 schedule and each dispatched review carries it as its
  `model`. `default` pins none, and the platform decides — on DAM the
  harness Default where the harness has one, else the agent's current model;
  it is the only value on a harness that cannot switch a session's model, and
  it is read in any letter case. A name the harness refuses fails each run
  after its gate ran. The audit compares the registered schedules and the
  week's runs against the key and reports a failing last result
  ([audit.md](audit.md) task 5); a run's model id matches it by the
  price-table rule ([benchmark.md](benchmark.md) → **Model prices**).
- **`mention_replies`** — `enabled` | `disabled`. **Missing = `enabled`.**
  GitHub comments addressed to the bot are answered, their review feedback
  recorded, and review requests in them served
  ([mentions.md](mentions.md)). Needs `bot_login`.
- **`mention_authors`** — whose GitHub mentions are handled: `collaborators`
  (the comment's `author_association` is `OWNER`, `MEMBER` or `COLLABORATOR`)
  | `anyone`. **Missing = `collaborators`**; any other value reads as
  `collaborators`. GitHub reads a private organization member as
  `CONTRIBUTOR` or `NONE` when the token cannot see the membership, so an
  author the association leaves out gets one
  `repos/<repo>/collaborators/<login>/permission` GET per run: `triage` or more
  admits, `read` admits on a private repository only. Preflight emits the
  mentions the set admits and logs the count it left out
  ([mentions.md](mentions.md)).

### Skills, artifacts, watches

- **`## Review skills` table** — the per-PR review skills; semantics in
  [skills.md](skills.md). Missing or empty → no review skills run (log once).
- **`artifact_skill`** — `<skill>@<[host/]owner/repo>`, or `none`/missing = the
  artifact feature is off entirely. The artifact publishes to the DAM Artifact
  Library, best-effort behind the owner's experimental flag
  ([artifact.md](artifact.md)).
- **`artifact_label`** — a GitHub label a human adds to request the artifact of
  a PR, beside the assignment of `bot_login`. **Missing = the assignment
  alone.** A GitHub App cannot be assigned, so the label is the artifact
  trigger of a GitHub App `bot_login`. The agent removes it once the artifact
  is published.
- **`## Watch rules` table** — instance-local "when a PR does X, give a
  heads-up in Y" rules, evaluated during reviews and delivered to a closed set
  of vetted targets (`chat`, `slack[:<chat-id>]`, `pr-comment`) —
  [watches.md](watches.md). Missing or empty = no watches; Slack targets
  require `slack_notifications: enabled`.
- **`project_profile`** — `enabled` (default) | `disabled`. Keeps
  `work/PROFILE.md` — the generated map of the reviewed repository — current on
  every heartbeat with a review due, for each `reviews_due` entry's profile
  slice ([profile.md](profile.md)). Orientation only, never evidence; its
  absence never blocks a review.

### Auto-merge (off until the admin opts in)

- **`auto_merge`** — `enabled` | `disabled`. **Missing = `disabled`.** Merges a
  PR that a person labeled with `auto_merge_label` and that passes every gate
  of [auto-merge.md](auto-merge.md). Only the repository admin enables it
  (ONBOARDING Step 4).
- **`auto_merge_label`** — the **human-managed** consent label. Required while
  `auto_merge` is `enabled`; missing → auto-merge stays off, logged once per
  run.
- **`auto_merge_max_lines`** — the largest `additions + deletions` that merges.
  **Missing or not a number = `100`.**
- **`auto_merge_method`** — `squash` | `merge` | `rebase`. **Missing =
  `squash`**; an unknown value is logged and reads as `squash`.

### Agent fixes (off until the admin opts in)

- **`agent_fixes`** — `enabled` | `disabled`. **Missing = `disabled`.** A PR a
  person labeled with `agent_fix_label` gets one round in which the agent
  fixes its own open blocking findings and pushes to its branch
  ([agent-fixes.md](agent-fixes.md)). Only the repository admin enables it
  (ONBOARDING Step 4).
- **`agent_fix_label`** — the **human-managed** label that asks for one round;
  the agent removes it when the round starts. Required while `agent_fixes` is
  `enabled`; missing → agent fixes stay off, logged once per run.

### Slack, audit, survey, benchmark

- **`slack_notifications`** — `enabled` | `disabled`. Gates everything Slack.
  **Missing file or key = `disabled`** — never send Slack messages without a
  recorded opt-in.
- **`merge_ready_nudge`** — `enabled` | `disabled`. **Missing = `disabled`.**
  An approved PR with no conflict, a green check rollup and no open critical of
  the agent's own gets **one** Slack message saying it is ready to land
  ([shepherd.md](shepherd.md) → **Ready to land**). Needs
  `slack_notifications: enabled` like every other nudge, and reads the rollup
  through the same reader as the CI triage.
- **`shepherd_scope`** — `all` | `needs_human`. **Missing = `all`.** Which PRs
  get reviewer-directed nudges: every waiting PR, or only those whose last
  review of the current head did not call a quick check
  ([shepherd.md](shepherd.md) → **Scope and brief**). Author-directed,
  conflict and ready-to-land nudges are never filtered.
- **`human_review_paths`** — comma-separated shell globs (`*` crosses `/`),
  for example `` `migrations/*, src/auth/*` ``. **Missing = none.** A PR that
  changes a matching file always records triage `needs-human`
  ([review-mechanics.md](review-mechanics.md) → **Summary body format**) and
  never auto-merges.
- **`escalation_owner`** — roster login widened to at nudge level 4, and the DM
  target of the monitor's alerts. Slack-only key, legitimately absent when
  Slack is disabled.
- **`audit_report`** — `enabled` (default) | `disabled`. Gates the weekly audit
  run. The report goes to Slack only under `slack_notifications: enabled`,
  otherwise to the chat UI.
- **`audit_trend`** — publish surface for the weekly trend artifact, updated
  in place so its URL stays stable: `dam` (default) | `off`. `dam` is
  best-effort as in [artifact.md](artifact.md); `off` keeps the history and
  the local report and publishes nothing ([trends.md](trends.md)). Any other
  value publishes to `dam` and is logged.
- **`definition_issues`** — `enabled` | `disabled`. **Missing = `disabled`.**
  Whether the agent files anonymous tracking issues on `definition_repo` — the
  weekly audit's definition bugs and the channel-refused change requests —
  through `scripts/definition-issue.sh` ([runbook.md](runbook.md) →
  **Definition-repo issues**). Off, the findings stay in the audit report and
  the chat UI.
- **`survey`** — `enabled` | `disabled`. **Missing = `disabled`.** The weekly
  deep pass over one area of the repository: what a diff cannot show —
  unreachable code, duplicated logic, untested paths, drift from the
  repository's own conventions and decision records ([survey.md](survey.md)).
- **`survey_report`** — publish surface for the accumulated survey artifact,
  updated in place so its URL stays stable: `dam` (default) | `off`, as
  `audit_trend`.
- **`survey_report_findings`** — `enabled` | `disabled`. **Missing =
  `disabled`.** Whether the survey artifact shows the findings themselves —
  severity, summary, **Fix:** line and the code location as a link to the
  commit the pass read — under each area, or stays an index of areas and
  passes. The artifact is public to anyone with its URL
  ([artifact.md](artifact.md)), so a finding on it is a disclosure: enable it
  only for a repository whose code, and whose weak points, may be read there.
- **`survey_interval_days`** — the floor between two passes. **Missing = `7`**;
  an unparseable value falls back to `7`. It bounds a drifting cron, so a
  weekly schedule never surveys twice in one week.
- **`benchmark`** — `enabled` | `disabled`. **Missing = `disabled`.** The
  monthly self-benchmark: replays ≥5 synthetic review fixtures through the full
  pipeline and scores each output against its known defects; results
  accumulate in `work/benchmark/` ([benchmark.md](benchmark.md)).
- **`benchmark_judge`** — pinned model id for the benchmark's LLM-judged
  quality scores; `off`/missing = deterministic scoring only. A changed judge
  starts a new comparability window.
- **`benchmark_report`** — publish surface for the accumulated report
  artifact, updated in place so its URL stays stable: `dam` (default) | `off`,
  as `audit_trend`.
- **`## Benchmark model prices` table** — optional per-MTok USD prices keyed by
  model id; powers the `est $` column of the benchmark report and the weekly
  trend artifact, and the `cost` rule of the review anomaly alert
  ([benchmark.md](benchmark.md) → **Model prices**, [monitor.md](monitor.md) →
  **Review anomaly alert**).
  Missing = costs render "—".

### Monitor

- **`stall_alert_threshold`** — stalled reviews (locked, never posted) within 24
  h that trigger one alert, at most once per UTC day. **Missing = `4`**;
  `0`/`off` disables; an unparseable value falls back to `4`
  (monitor.md → **Stalled-review rate alert**).
- **`review_anomaly_factor`** — a review whose cost, time, peak context,
  repeated calls, failures or largest tool result reaches max(floor, this ×
  the median of its model's recent reviews) alerts once. **Missing = `4`**;
  `0`/`off` disables the whole anomaly alert; a number of `1` or more, a
  decimal too, sets it; any other value falls back to `4`
  (monitor.md → **Review anomaly alert**).
- **`model_alert_threshold`** — runs that ended on an API failure within one
  outage before the monitor alerts. **Missing = `2`**; `0`/`off` disables;
  an unparseable value falls back to `2` (monitor.md → **The alerts**).
- **`github_alert_threshold`** — consecutive gate passes that could not list
  the open PRs before the monitor alerts. **Missing = `2`**; `0`/`off`
  disables; an unparseable value falls back to `2` (monitor.md → **The
  alerts**).
- **`classifier_alert_threshold`** — auto-mode classifier refusals within 24
  h that alert once per UTC day; a refused review post alerts on its own.
  **Missing = `20`**; `0`/`off` disables both; an unparseable value falls
  back to `20` (monitor.md → **The alerts**).
- **`monitor_slack_direct`** — `enabled` | `disabled`. **Missing =
  `disabled`.** The monitor's pass sends the due alerts itself as one
  templated DM to `escalation_owner`, with no model in the loop
  ([monitor.md](monitor.md) → **Direct delivery**). Needs
  `slack_notifications: enabled` and the owner's roster `slack_id`; without
  them the session delivers.
- **`health_dashboard`** — `dam` | `off`. **Missing = `off`**, and any other
  value reads as `off`. The monitor's pass publishes the health dashboard to
  the DAM Artifact Library and updates it in place ([health.md](health.md) →
  **Publish**). `off` keeps the history and publishes nothing.

### Cadence & diagnostics

- **`active_hours`**, **`active_days`**, **`review_interval_active`**,
  **`review_interval_quiet`** — the review heartbeat's two cadences.
  `active_hours` (`HH-HH`, platform timezone, both ends inclusive; **missing =
  `00-23`**) and `active_days` (`Mon-Fri` | `Mon-Sun` | a comma list;
  **missing = `Mon-Sun`**) delimit the **active window**; every hour outside it
  is a quiet hour. Inside the window the heartbeat runs every
  `review_interval_active` minutes (**missing = `5`**), in quiet hours every
  `review_interval_quiet` minutes (**missing = `60`**); both are divisors of
  60. An interval bounds how long a new PR or a trigger waits for its run; a
  tick with no work costs no model call ([worklist.md](worklist.md) → **The
  schedule gate**). These four keys are the **source of truth for the
  registered cron schedules** (ONBOARDING Step 6a) and for the audit's
  cadence check.
- **`log_level`** — `info` (default) | `debug`. Verbosity of
  `work/logs/events-*.jsonl` ([logging.md](logging.md)); `debug` additionally
  records successful external tool calls. Diagnostic only, never gating
  behavior.

## Reader (manual fallback and direct session)

```bash
CONFIG=/home/agent/work/CONFIG.md
. /home/agent/scripts/lib/common.sh   # the scripts' own cfg, refhost, refslug — before the re-export below
TARGET="$(cfg github_repo)"; TARGET="${TARGET:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
REPO_HOST="$(refhost "$TARGET")"; REPO="$(refslug "$TARGET")"; export GH_HOST="$REPO_HOST"
BOT_LOGIN="$(cfg bot_login)"; BOT_NAME="$(cfg bot_display_name)"; BOT_NAME="${BOT_NAME:-Code Guardian}"
REVIEW_MARKER="$(cfg review_marker)"
DEF_REF="$(cfg definition_repo)"; DEF_HOST="$(refhost "$DEF_REF")"; DEFINITION_REPO="$(refslug "$DEF_REF")"
REREVIEW_LABEL="$(cfg rereview_label)"; REREVIEW_LABEL="${REREVIEW_LABEL:-code-guardian-review}"
REREVIEW_DELTA_LABEL="$(cfg rereview_delta_label)"; ARTIFACT_LABEL="$(cfg artifact_label)"
```

All `gh` commands use `--repo "$REPO"`. `REPO` resolving empty → stop and ask
the operator for the slug, never guess.

## Changing a value (direct session)

- Update the file and confirm — except `review_marker` after the first posted
  review, which is refused.
- On first Slack enablement, build the roster and register the shepherd
  schedule (ONBOARDING Step 4 items 8–9, Step 6b); on disablement, disable
  that schedule. `benchmark` and `survey` do the same with their schedules
  (Steps 6d, 6e).
- An edited cadence key or `review_model` takes effect once the schedules are
  reconciled per ONBOARDING Step 6.
- **Missing `work/CONFIG.md`** = not onboarded, or state lost: apply per-key
  defaults (Slack disabled, skills disabled, artifact and shepherd off), log it
  once, and continue with what still works.
