# Changelog

Agent-facing history: per version, a **Changed** block and an **Upgrade**
block — the idempotent steps a deployed instance applies when crossing that
version. Consumed by the version check
([docs/persistence.md](docs/persistence.md) → **Definition version &
upgrade**); authoring rules:
[docs/self-modification.md](docs/self-modification.md) §12.

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
