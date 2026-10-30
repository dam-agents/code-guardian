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
with its default applied (`null` for a missing key without one), `skills_table`
(`[{skill, source, trigger, section}]`) and `watch_rules`
(`[{id, watch_for, notify, note}]`). Runs read their values from it; the reader
below is for the manual fallback and the direct session.

## Keys

**Session model** — no key. The platform sets the model of every session: on
DAM the agent's model settings and each schedule's `model`, which the operator
sets there. The agent never chooses a session's model: it carries a registered
schedule's `model` unchanged when ONBOARDING Step 6 re-creates that schedule,
gives the benchmark's sub-agents and trial sessions its own session's model
unless the operator names another ([benchmark.md](benchmark.md) →
**Isolation**, **Trial runs**), and chooses the model of the benchmark judge
call under `benchmark_judge: auto` ([benchmark.md](benchmark.md) →
**Choosing the judge**).

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
- **`bot_login`** — the GitHub account people mention and request for
  this agent; the token may post as another login, such as a GitHub App
  ([github-access.md](github-access.md)). **Required.** Missing → the
  `review-request` trigger and mention handling are off.
- **`bot_display_name`** — signature name (default `Code Guardian`). Cosmetic
  only, never used for dedup.
- **`review_marker`** — prefix of the hidden dedup marker
  `<!-- <review_marker> headRefOid=<full-sha> -->` in every posted review.
  **Required, and immutable once the first review is posted** — a later change
  request is refused with the reason.

### Review triggers & delivery

- **`rereview_label`** — the GitHub label a human adds to request a **complete**
  re-review of the whole PR (default `code-guardian:rereview`). The other triggers
  — the delta label, a review request, a `guide_label` that no review round
  saw yet — get a delta re-review ([review-rereview.md](review-rereview.md) → **Re-review
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
- **`session_awareness`** — `enabled` | `disabled`. **Missing = `enabled`.**
  The scripts read the platform's list of this agent's sessions and signal a
  review session whose PR got a new HEAD ([sessions.md](sessions.md)).
  `disabled`, or a platform without the tools, keeps the event-based rules.
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

### Skills, review guide, watches

- **`## Review skills` table** — the per-PR review skills; semantics in
  [skills.md](skills.md). Missing or empty → no review skills run (log once).
  A row whose skill is a guide skill — the bundled `review-guide`, in the
  default set — builds a visual page for the human reviewer of a
  `needs-human` PR and links it from the review; it publishes to the DAM
  Artifact Library ([skills.md](skills.md) → **Guide skills**,
  [artifact.md](artifact.md) → **Review guide**).
- **`guide_label`** — a GitHub label a human adds to ask for the review guide
  of a PR whatever the review's triage. **Missing = the triage alone
  decides.** The label stays on the PR and acts at each review round. When no
  review round saw it yet, it starts a delta round that publishes the guide
  ([artifact.md](artifact.md) → **Review guide**).
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
  changes a matching file has the match named to the reviewing agent's triage
  call and recorded in `triage.forced`
  ([review-mechanics.md](review-mechanics.md) → **Summary body format**), and
  never auto-merges.
- **`escalation_owner`** — roster login widened to at nudge level 4, and the
  fallback DM target of the monitor's alerts (`monitor_owner`, **Monitor**).
  Slack-only key, legitimately absent when Slack is disabled.
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
  security pass over one area of the repository as it stands: the security
  holes, data loss and reachable failures that a diff review cannot see. It
  reports only blocking findings — no suggestion, no refactor
  ([survey.md](survey.md)).
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
  weekly schedule never surveys twice in one week. The floor is 6 hours short
  of the full interval: the ledger records the end of a pass, so the next
  fire of the cron comes a few minutes before the interval is complete.
- **`daily_brief`** — `enabled` | `disabled`. **Missing = `disabled`.** One
  Slack message each weekday morning: user-facing news of the merged PRs by
  topic, then the technical changes with impact ([brief.md](brief.md)). Needs
  `slack_notifications: enabled`; without it nothing is sent. Weekend merges
  arrive on Monday.
- **`brief_language`** — the language of the brief, as a plain name
  (`English`, `Czech`). **Missing = `English`.** It sets the brief only;
  every other outward text stays in ASD-STE100.
- **`benchmark`** — `enabled` | `disabled`. **Missing = `disabled`.** The
  monthly self-benchmark: replays ≥5 simple and ≥3 complex synthetic review fixtures through the full
  pipeline and scores each output against its known defects; results
  accumulate in `work/benchmark/` ([benchmark.md](benchmark.md)). A run needs
  a non-public `work_repo` and a public definition repo
  ([benchmark.md](benchmark.md) → **Isolation**).
- **`benchmark_judge`** — the judge of the benchmark's LLM-judged quality
  scores: `auto` | a model id | `off`. **Missing = `off`** (deterministic
  scoring only). `auto` = the agent picks the judge once from the models this
  host serves and every later run uses that pick
  ([benchmark.md](benchmark.md) → **Choosing the judge**); a model id pins the
  operator's choice, by any name the host's model list matches (`opus-5`,
  another provider prefix; [benchmark.md](benchmark.md) → **Choosing the
  judge**). A name the host does not serve fails before the run. The judge
  runs as its own `claude -p` call, whatever model the reviews ran on ([benchmark.md](benchmark.md) → step 6), so the host needs
  the `claude` CLI, signed in (`claude auth login` once, or
  `ANTHROPIC_API_KEY`), or a `pi` CLI as the fallback on the same model;
  without them the run keeps deterministic scores only, and the monitor
  alerts `judge_unavailable`. A changed judge starts a new comparability
  window.
- **`benchmark_report`** — publish surface for the accumulated report
  artifact, updated in place so its URL stays stable: `dam` (default) | `off`,
  as `audit_trend`.
- **`## Benchmark model prices` table** — optional per-MTok USD prices keyed by
  model id; powers the `est $` column of the benchmark report and the weekly
  trend artifact, and the `cost` rule of the review anomaly alert
  ([benchmark.md](benchmark.md) → **Model prices**, [monitor.md](monitor.md) →
  **Review anomaly alert**).
  Missing = costs render "—".
- **`## Benchmark sufficiency` table** — optional bar per task tier (`simple`,
  `complex`: recall, precision, min_defects) that the report's sufficiency
  verdicts check ([benchmark.md](benchmark.md) → **Sufficiency by tier**).
  Missing table or tier = recall 0.8, precision 0.7, min_defects 20.

### Monitor

- **`stall_alert_threshold`** — stalled reviews (locked, never posted) within 24
  h that record one history incident, at most once per UTC day (no alert). **Missing = `4`**;
  `0`/`off` disables; an unparseable value falls back to `4`
  (monitor.md → **Stalled-review rate alert**).
- **`review_anomaly_factor`** — a review whose cost, time, peak context,
  repeated calls, failures or largest tool result reaches max(floor, this ×
  the median of its model's recent reviews) records one history incident (no
  alert). **Missing = `4`**; `0`/`off` disables the whole detector; a number of `1` or more, a
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
  h that record one history incident per UTC day (no alert); a refused review
  post is its own incident.
  **Missing = `20`**; `0`/`off` disables both; an unparseable value falls
  back to `20` (monitor.md → **The alerts**).
- **`monitor_owner`** — roster login the monitor's alert DMs go to, both the
  pass's direct delivery and the session's report. **Missing =
  `escalation_owner`**; a set login without a roster `slack_id` sends no DM
  and is reported ([monitor.md](monitor.md) → **Monitor run**). Slack-only
  key.
- **`monitor_slack_direct`** — `enabled` | `disabled`. **Missing =
  `disabled`.** The monitor's pass sends the due alerts itself as one
  templated DM to the monitor owner, with no model in the loop
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
  `review_interval_quiet` minutes (**missing = `15`**); both are divisors of
  60. An interval bounds how long a new PR or a trigger waits for its run; a
  tick with no work costs no model call.
  These four keys are the **source of truth for the registered cron
  schedules** (ONBOARDING Step 6a) and for the audit's cadence check.
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
REREVIEW_LABEL="$(cfg rereview_label)"; REREVIEW_LABEL="${REREVIEW_LABEL:-code-guardian:rereview}"
REREVIEW_DELTA_LABEL="$(cfg rereview_delta_label)"; GUIDE_LABEL="$(cfg guide_label)"
```

All `gh` commands use `--repo "$REPO"`. `REPO` resolving empty → stop and ask
the operator for the slug, never guess.

## Changing a value (direct session)

- Update the file and confirm — except `review_marker` after the first posted
  review, which is refused.
- On first Slack enablement, build the roster and register the shepherd
  schedule (ONBOARDING Step 4 items 8–9, Step 6b); on disablement, disable
  that schedule. `benchmark`, `survey` and `daily_brief` do the same with their
  schedules (Steps 6d, 6e, 6g).
- An edited cadence key takes effect once the schedules are reconciled per
  ONBOARDING Step 6.
- **Missing `work/CONFIG.md`** = not onboarded, or state lost: apply per-key
  defaults (Slack disabled, skills disabled, shepherd off), log it
  once, and continue with what still works.
