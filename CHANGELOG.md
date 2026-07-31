# Changelog

Agent-facing history: per version, a **Changed** block and an **Upgrade**
block — the idempotent steps a deployed instance applies when crossing that
version. Consumed by the version check
([docs/persistence.md](docs/persistence.md) → **Definition version &
upgrade**); authoring rules:
[docs/self-modification.md](docs/self-modification.md) §12.

## 2.4.0 — 2026-07-31

**Changed:**
- New harness adapter **`scripts/harness/claude-code/enforce-review-completion.sh`**,
  registered by `install.sh` as a **`Stop` hook**: at end of turn it reads this
  run's own `review_step` events and refuses the stop (exit 2, stderr shown to
  the model) when a PR was `locked` without a later `done` / `aborted <reason>`,
  naming the PRs and the steps still owed. `rapid posted` and `skill:<name>
  done` are explicitly non-terminal, so an urgent PR's rapid pass and a skill's
  "report to the user" can no longer end a run. This makes the existing
  never-end-mid-pipeline invariant enforced rather than merely stated — a stall
  used to leave an `in_progress` lock until the 30-min TTL and a takeover.
  Fires once per turn (`stop_hook_active` guard), makes no GitHub calls and no
  state writes, logs one `review_incomplete` warn, and no-ops on a
  non-deployed instance. Home: docs/review.md → **Completion enforcement**.
- Audit `harness_adapter` check now verifies **all three** adapter hooks and
  names the missing ones — it passed on a partially-registered instance before,
  so an upgrade that never re-ran `install.sh` went unnoticed.
- Tests: `scripts/tests/test_stop_hook.sh` (12 assertions over the hook's
  terminal-step logic, loop guard and no-op paths) plus two
  `harness_adapter` cases in `test_audit_stats.sh`.

**Upgrade:**
Docs are re-read per run, but the hook only exists once registered — one
idempotent step:
1. Re-run `bash "$HOME/scripts/harness/claude-code/install.sh"` (safe to
   re-run; it rewrites only its own hook entries). Effective from the **next**
   session; the audit's `harness_adapter` check warns until then.

## 2.3.0 — 2026-07-31

**Changed:**
- Weekly audit gains the **`definition_issues`** check: preflight counts open
  issues on `definition_repo` (PRs filtered out) and reports them — `ok` at
  zero, `warn` with numbers + titles otherwise, `warn` when the repo is
  unresolvable or the list unreadable. The agent's own tracking issues
  (`[audit]`, `[channel request]`) wait for the operator; this keeps them
  from being forgotten (e.g. issue #31 sat unnoticed).

**Upgrade:**
Nothing — docs are re-read per run; the check lives in the script.

## 2.2.1 — 2026-07-31

**Changed:**
- docs/review.md Check 1 now states only the working REST form. The rationale
  stays here and in issue #33: the GraphQL `reviewRequests` field of
  `gh pr view --json` intermittently demands `read:org`, which the token
  deliberately lacks (`repo` + `gist`), silently missing review-request
  re-review triggers (9 `tool_failure` events in the 2026-07-31 audit week);
  the REST endpoint (`requested_reviewers`) is what `scripts/preflight.sh`
  has always used, with zero failures on record. The REST switch itself
  shipped in 2.2.0; the trigger gate is unchanged. Fixes #33.

**Upgrade:**
Nothing — docs are re-read per run.

## 2.2.0 — 2026-07-31

**Changed:**
- New optional `work/CONFIG.md` key **`urgent_label`** (missing = off): a
  **human-managed** GitHub label that makes a PR's due reviews jump the queue
  and run **rapid-first** — a fast preliminary review (diff-only, 🔴-critical
  findings only, clearly marked, own `<review_marker>:rapid` dedup marker,
  `event: COMMENT`) posts immediately, then the normal full review follows in
  the same run. Applies to every review kind while the label is present; the
  agent never adds or removes the label, and the label is a delivery modifier,
  never a review trigger. Preflight flags entries `urgent: true` and orders
  them first; a died run resumes via the `RAPID` verdict on the `in_progress`
  lock row. Home: docs/review.md → **Urgent PRs**.
- **PR closed mid-review** (any review, urgent or not): a review finished
  after its PR closed is no longer just discarded — with ≥1 🔴 Critical
  finding the agent files one deduplicated GitHub issue (marker
  `<review_marker>:issue`), linked to the PR and assigned to its author.
  Preflight emits a closed PR whose row is a `RAPID` lock as a review entry
  flagged `closed: true` instead of a prune, so an owed full review survives
  the closure. Home: docs/review.md → **PR closed mid-review**.
- **Review style defaults** (docs/review.md → **Criteria & review style**):
  reviews are concise (1–2 sentences per finding); code is assumed
  agent-written and agent-read — human-readability/structure nits are out of
  scope unless they create real defect risk; 🟢 suggestions only for
  substantial improvements; the summary never repeats inline-comment text
  (inline-carried findings appear as one-liners in `### Findings`).
- **Immediate urgent Slack alert** (`urgent_alerts_due`): when preflight first
  sees an urgent-labeled PR (no `urgent-announced` marker in its history file)
  and `slack_notifications: enabled`, the agent posts one alert to the shared
  channel **before any other run work** — mentioning roster members (filtered
  to online when a presence lookup is available this session, otherwise all;
  never anyone outside `work/DEVELOPERS.md`). Marker write before send; once
  per PR. Home: docs/review.md → **Urgent PRs**.
- **`findings-json`**: every posted full review now carries a one-line
  machine-readable copy of its `### Findings` (status/severity/file/line/
  inline/summary per finding) in a hidden HTML comment above the dedup marker
  — authors are agents too; re-reviews match deltas against it (text-parse
  fallback for older reviews). Home: docs/review.md → **Summary body format**.
- **Findings-acceptance metric**: audit `stats` gains
  `findings: {fixed, still_present}` counted from this week's re-review
  bullets; the report shows `fixed/(fixed+still)` and task 26 judges it
  (memory consolidation renumbered to task 27).
- **Deterministic test suite + CI**: `scripts/tests/` (offline stub tests for
  `preflight.sh` — fake `gh`/`curl`, sandboxed `work/`; `bash
  scripts/tests/run.sh`) and `.github/workflows/ci.yml` (syntax, tests,
  VERSION↔CHANGELOG consistency, doc-link resolution on every PR) — §9's
  validation sweep, mechanized. `.github/` joins the `.gitignore` allowlist
  and the definition-PR path list; self-modification.md §9 now requires the
  test run, and a `preflight.sh` behavior change updates its test case in the
  same PR.
- Fixes: `iso2epoch`'s BSD fallback now parses the trailing `Z` as UTC
  (`date -j -u`) — lock ages were computed with a timezone skew on macOS dev
  machines (the GNU pod path was always correct). Check 1 in docs/review.md
  now uses the REST PR endpoint (`requested` field) — the branch form of the
  GraphQL `reviewRequests` fix tracked in issue #33.
- Consolidation pass (behavior unchanged): skills.md trust-boundary paragraph,
  audit.md task-4 check list, review.md self-check, and README's heartbeat
  overview deduplicated down to their single homes.

**Upgrade:**
Docs are re-read per run. Optional: to enable urgent handling, add
`urgent_label: <label>` to `work/CONFIG.md` (create the label on the target
repo if missing) — a missing key keeps the feature off; urgent Slack alerts
need nothing beyond the existing `slack_notifications: enabled` + roster.

## 2.1.0 — 2026-07-30

**Changed:**
- `scripts/preflight.sh`: **bug fix** — the `## Review skills` table was read
  with an unbounded `sed` range, so every table *after* it in `work/CONFIG.md`
  (e.g. `## Watch rules`) was parsed as skill rows; the phantom skills reported
  `install-failed` on every review run and in the weekly `skill_*` checks. Both
  call sites now use one `cfg_table <heading>` helper that stops at the next
  `## ` heading.
- Audit gains a **failure diagnosis** pass: preflight groups **every `level:
  error` event** of the past week — failed tool calls, skill installs, sends, API
  decisions — into `failures[]` signatures (`event`/`tool`/`error`, volatile bits
  normalized, each dated `first`/`last`), and the agent diagnoses every one:
  cause + fix per signature, classified environment / agent mistake / definition
  bug, with a deduplicated `[audit]` tracking issue on `definition_repo` for the
  last kind (docs/audit.md task 3). The issue is the audit's only GitHub write.
  Counting errors was never enough — nothing asked *why*.
- Audit gains two precondition checks: `token_scopes` (asserts the scopes the
  scheduled runs actually need — a missing one is operator-only and breaks PR
  state/posting or artifact publishing) and `cli_deps` (required commands
  present). Scopes are specified in one place only: README → **Token scopes**.
- ONBOARDING Step 0 verifies both at setup, and records that OS packages cannot
  be installed on the pod — `awk`, `diff`, and a login-shell `python3` are
  deliberately not required by this definition.
- New runtime state file `work/LESSONS.md` — verified environment facts and
  recurring failure modes, read in review runs (CLAUDE.md step 2), written when a
  root cause is reproduced. Third memory route in
  [docs/preferences.md](docs/preferences.md) → **Operational lessons**; seeded by
  ONBOARDING Step 3b.
- New `work/CONFIG.md` key **`definition_branch`** (missing = `main`): the branch
  of `definition_repo` **an instance runs from** — its update source and the branch
  `/home/agent` is kept on, so a deployment can follow something other than `main`.
  The `definition_version` check warns when the checkout sits elsewhere. A per-agent
  deployment choice only: `main` remains the repository's development branch, the
  base of every definition PR, and the owner of the changelog. Home:
  docs/persistence.md → **Tracked branch**; onboarding derives it from the runbook
  URL.
- **CHANGELOG is append-only, per entry** (docs/self-modification.md §12): a
  branch may keep editing **its own** not-yet-released entry across commits, but
  every older entry already on `main` is immutable — even from a branch — and once
  an entry reaches `main` nothing about it ever changes again; corrections are new
  entries. This *replaces* the previous rule that had an overtaken branch re-date
  the entry which overtook it; an overtaken branch now re-numbers and re-dates
  **its own** pending entry instead.

**Upgrade:**
Docs are re-read per run and the parse fix lives in the script; an instance that
saw phantom `install-failed` skills (one per non-skill CONFIG table row) stops
seeing them. Two idempotent state steps:
1. If `work/LESSONS.md` is missing, create it from the ONBOARDING Step 3b template
   (an existing file is never overwritten — it holds diagnoses that aren't
   reconstructable).
2. If `work/CONFIG.md` has no `definition_branch:` key, append it with the branch
   the checkout is currently on (`git -C /home/agent rev-parse --abbrev-ref HEAD`,
   or `main` when that is detached/unavailable) — recording the status quo, never
   switching branches as part of the upgrade.

## 2.0.0 — 2026-07-29

**Changed:**
- `work/` is now a **plain data directory (no `.git`)**. Backup to
  `$GITHUB_REPO_WORK` moved to the new `scripts/work-backup.sh`
  (`persist` | `restore`), which runs entirely inside a disposable `/dev/shm`
  tmpfs clone — the shared virtiofs/NFS volume is never git-mutated, eliminating
  the `Stale file handle` (ESTALE) + `.nfs*` silly-rename corruption from
  concurrent runs. Nothing authoritative lives on tmpfs (re-seeded from the
  remote every call; robust to pod restart). Concurrency is resolved at the
  remote with an in-run push retry, so reviews still run fully in parallel — no
  run-lock. Only the persist step itself is serialized within the pod
  (concurrent sessions share the clone): a mkdir lock next to the clone,
  lock-or-skip with a stale-lock TTL — a skipped persist is safe, `work/` stays
  the source of truth and the next run backs it up.
- `restore` filters `.nfs*` junk a pre-2.0.0 layout may have committed to the
  backup remote; a new `nfs_junk` audit check counts `.nfs*` files under
  `work/` (docs/audit.md).
- Onboarding provisions `work/` as a data dir and restores via
  `work-backup.sh restore`; all end-of-run "commit & push" steps
  (CLAUDE.md review/shepherd/audit, docs) now call `work-backup.sh persist`;
  the preflight `work_repo` audit check asserts the no-`.git` invariant;
  persistence.md / README.md updated to the new model.

**Upgrade:**
1. If `$GITHUB_REPO_WORK` is set **and** `work/.git` exists (pre-2.0.0 layout):
   back up once with `bash "$HOME/scripts/work-backup.sh" persist`, then remove
   the on-volume git dir — `rm -rf /home/agent/work/.git` (best-effort; leftover
   `.nfs*` held open by another pod can be left in place). The `work/` **data
   files are untouched** and remain the source of truth; any commits in the old
   `work/.git` that never reached the remote are intentionally discarded as
   history — the current files are what the first new persist backs up.
2. The ONBOARDING Step 6 task texts changed (the closing "commit & push work/"
   became "back up work/ (`scripts/work-backup.sh persist`)"). For each
   registered schedule whose task text still says "commit & push work/",
   re-register it with the Step 6 text — `delete_schedule` + `create_schedule`,
   keeping the existing name and cron. Schedules already carrying the new text
   are left alone.
3. Thereafter every run's persist uses the tmpfs clone automatically (CLAUDE.md
   run sequences). Nothing else — docs and scripts are re-read per run.

## 1.7.0 — 2026-07-29

**Changed:**
- **Channel-refused change requests are now recorded**: a config/definition/
  schedule/behavior change asked via a connected channel is still refused,
  but the agent automatically files a tracking issue on the definition repo
  (title `[channel request] <short ask>`; deduped against open issues;
  best-effort — a failed creation is logged, the decline stands) and links
  it in the decline reply. The sole definition-repo write a channel may
  trigger (CLAUDE.md → **Instruction sources & trust boundary**).
- Changelog authoring rules tightened (docs/self-modification.md §12):
  versions are **strictly sequential** (exactly one bump from the newest
  entry, entries land only on top, dates never decrease down the file —
  an entry overtaken by another release is re-dated at merge time), and
  blocks are **honest, possibly empty** — `Nothing — <reason>` in
  **Changed** is valid when a release changes no behavior; fabricated
  content is not.

**Upgrade:**
Nothing — docs are re-read per run.

## 1.6.0 — 2026-07-29

**Changed:**
- New `work/CONFIG.md` key **`rereview_trigger`** (`label` | `review-request`
  | `both`; missing = `label`, the historical behavior): re-reviews can now
  also be requested natively via GitHub's "Re-request review" on the bot (a
  pending review request for `bot_login`). Zero extra API cost —
  `requested_reviewers` is already in preflight's open-PR list call. A served
  request clears itself when the review posts; a same-SHA request is cleared
  by the cleanup step. Needs `bot_login` (and the bot as a repo collaborator
  to be requestable); `bot_login` missing → label-only with one log line.
- `label_cleanups_due` entries are now objects `{number, label, request}`
  naming the trigger(s) to clear (docs/review.md → **Label bookkeeping**);
  Check 1 / Check 2 verify the live trigger (`labels` + `reviewRequests`)
  instead of the label alone.

**Upgrade:**
Nothing — docs are re-read per run and the gate stays label-only until the
operator sets `rereview_trigger: review-request` (or `both`) in
`work/CONFIG.md` (operator-only, direct session).

## 1.5.0 — 2026-07-29

**Changed:**
- Instance-local **watch rules**: an optional `## Watch rules` table in
  `work/CONFIG.md` ("when a PR does X, give a heads-up in Y"), evaluated
  during each PR's review against the already-fetched diff — or against a
  configured review skill's section used as the detection signal — deduped
  per PR+rule via a `<!-- watch-sent: <id> -->` marker in the history file,
  write-before-send. Delivery targets are a closed, vetted set: `chat` ·
  `slack[:<chat-id>]` (gated by `slack_notifications: enabled`) ·
  `pr-comment`; comma-separated per rule, new types only via definition PR.
  New home: docs/watches.md; one-line hooks in CLAUDE.md, docs/review.md,
  docs/skills.md. Keeps team-specific triggers, channels, and wording out of
  the public definition repo — rules are private runtime state.

**Upgrade:**
- Nothing required — a missing/empty table means no watches. To add one, the
  operator asks in the direct session; the agent appends the row to
  `work/CONFIG.md` → `## Watch rules` (format in docs/watches.md). Cost: no
  new schedules or API calls — evaluation reuses the review's diff; one
  delivery per matched PR per target.

## 1.4.0 — 2026-07-28

**Changed:**
- `scripts/harness/claude-code/log-tool-event.sh`: `tool_failure` events now
  capture the fullest error context available (falling back through
  `tool_response` → error/stderr/stdout fields → the raw payload) so a failed
  call is never logged as bare `null` (docs/logging.md).
- `scripts/preflight.sh`: emits a once-per-restart `pod_boot` warn event via an
  ephemeral `/tmp` sentinel, making pod restarts (previously invisible)
  diagnosable (docs/logging.md).
- `docs/review.md` → **Error handling**: a transient tool failure (context
  fetch, clone, skill, post) is retried once; still failing → abort the PR
  **releasing its lock** (as a Check 2 failure), never leaving an
  `in_progress` lock behind, never retrying a call more than once. New
  CLAUDE.md invariant + review-run self-check line.

**Upgrade:** Nothing — the hook command path is unchanged, so the richer
`tool_failure` capture applies automatically from the next session; preflight
and docs are re-read per run.

## 1.3.0 — 2026-07-28

**Changed:**
- Unified structured logging (new home: `docs/logging.md`): all diagnostic
  events go to `work/logs/events-YYYY-MM-DD.jsonl` (`ts`/`run`/`job`/`level`/
  `event`/`msg`) via the new harness-agnostic `scripts/log.sh`. Preflight now
  logs a per-run heartbeat summary and its previously silent errors (API
  decision sites, skill installs); the new Claude Code harness adapter
  (`scripts/harness/claude-code/`, detected via `CLAUDECODE=1`, replaceable
  per-harness) auto-captures every failed tool call through
  `PostToolUseFailure`/`PostToolUse` hooks. New `log_level` config key
  (`info` default | `debug`); replaces `review_progress_log` — review
  milestones are now always-on `review_step` events. A `SessionEnd` hook
  additionally logs one `tokens` event per run (per-job API usage summed
  from the session transcript); the audit aggregates weekly totals into
  `stats.tokens` and the report.
- The weekly audit triages the events log (`events_errors` +
  `recurring_errors` checks, `log_events` stats, harness-adapter check; the
  report surfaces recurring/severe errors) and performs the log retention
  cleanup: events files older than 14 days deleted (weekly cadence → files
  are 14–21 days old when removed), `HEARTBEAT.log`/`SHEPHERD.log` trimmed
  in place to 14 days, `AUDIT.log` exempt.

**Upgrade:**
1. Run `bash "$HOME/scripts/harness/claude-code/install.sh"` (idempotent;
   prints a notice and exits on non-Claude-Code harnesses; hooks take effect
   from the next session).
2. In `work/CONFIG.md`: remove the `review_progress_log` key if present
   (replaced by `log_level`; if it was `enabled` and you want the extra
   detail, set `log_level: debug`). Delete `work/REVIEW-DEBUG.log` if
   present.
3. Nothing else — `work/logs/` is created on first write.
## 1.2.0 — 2026-07-27

**Changed:**
- Visual PR artifacts can dual-publish: a new `artifact_targets` config key
  (default `gist`; `gist,dam`) publishes the one on-disk HTML to a secret
  gist and/or the platform's DAM Artifact Library. DAM is best-effort behind
  the owner's experimental MCP flag — listed-but-unavailable logs and skips,
  never failing the run; pruning cleans up both surfaces
  (docs/artifact.md, docs/review.md → **Pruning**). Tracking files gain an
  `<!-- artifact-dam: <id> -->` marker alongside the gist marker; preflight
  reads both for prune ids and the `retry_unassign` idempotency guard.

**Upgrade:**
- Nothing required — `artifact_targets` missing = `gist`, the prior behavior.
  To opt this instance into the DAM surface, set `artifact_targets: gist,dam`
  in `work/CONFIG.md` (operator, in the direct session); DAM publishing then
  activates automatically whenever the artifact-library MCP tools are present.

## 1.1.1 — 2026-07-27

**Changed:**
- Trust boundary sharpened: channel/PR requests may only ever result in
  `work/` (runtime-state) writes and normal review output on the target
  repo — never any change to the definition repo (CLAUDE.md →
  **Instruction sources & trust boundary**).

**Upgrade:**
- Nothing — docs are re-read per run.

## 1.1.0 — 2026-07-27

**Changed:**
- Anyone in the connected channel can request a review of a specific PR —
  equivalent to adding the re-review label, including killing a stuck
  (stale-locked) review and re-running it (docs/review.md →
  **Slack-requested review**).

**Upgrade:**
- Nothing — docs are re-read per run.

## 1.0.0 — 2026-07-27

**Changed:**
- Versioning introduced: `VERSION`, this changelog, the check + migration
  procedure (docs/persistence.md), authoring rules
  (docs/self-modification.md §12), `work/VERSION` at ONBOARDING Step 7, and
  the weekly audit's `definition_version` drift check.

**Upgrade:**
- Nothing to apply — the check serving this migration just records the
  version (writes `work/VERSION`).

---

## Pre-versioning history (informative)

Definition PRs merged before versioning existed, with what a deployed
instance had to do — kept for operators updating very old instances. All
steps are idempotent; apply only what is missing, newest last:

- **PR #16 — deterministic preflight, split docs, dual schedules.** Entry
  commands of the schedules changed to `bash "$HOME/scripts/preflight.sh"
  <mode>`; re-register the review + shepherd schedules per ONBOARDING Step 6
  if they still use the old task text.
- **PR #17 — weekly audit (third run type).** Create the
  `code-guardian-audit-weekly` schedule per ONBOARDING Step 6c if missing.
  `work/CONFIG.md` needs no change (missing `audit_report` = `enabled`).
- **PR #19 — instruction-source trust boundary.** Nothing to configure.
  Recommended: re-state the channel-command policy once in the direct
  session so it also lands in `work/MEMORY.md`.
- **PR #20 — mid-pipeline stall fix + `review_progress_log`.** Nothing —
  the guardrail applies on the next run; the config key is opt-in
  (missing = `disabled`).
- **PR #21 — observed insights + weekly memory consolidation.** Nothing —
  docs are re-read per run; `MEMORY.md` gains its section on first insight.
- **PR #22 — untracked `work/` seeds.** Nothing — updating the definition
  checkout suffices; existing runtime files are preserved.
