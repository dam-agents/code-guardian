# Changelog

Agent-facing history: per version, a **Changed** block and an **Upgrade**
block — the idempotent steps a deployed instance applies when crossing that
version. Consumed by the version check
([docs/persistence.md](docs/persistence.md) → **Definition version &
upgrade**); authoring rules:
[docs/self-modification.md](docs/self-modification.md) §12.

## 2.0.0 — 2026-07-28

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
