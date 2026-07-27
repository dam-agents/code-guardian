# Changelog

Agent-facing changelog of this definition. Every entry records what changed
and — in its **Upgrade** block — the idempotent steps a deployed instance
applies when crossing that version. Consumed by the version check that runs
on an operator-requested update, on demand, and always before any
self-modification: when `work/VERSION` is behind `VERSION`, the agent applies
the Upgrade blocks oldest-first per
[docs/persistence.md](docs/persistence.md) → **Definition version & upgrade**.
Authoring rules (bump semantics, entry template):
[docs/self-modification.md](docs/self-modification.md) → **Versioning &
changelog**.

## 1.0.0 — 2026-07-27

**Changed:**
- Versioning introduced: `VERSION` file, this changelog, the version check +
  upgrade procedure in docs/persistence.md (runs at operator-requested
  updates, on demand, and before every self-modification — never from
  review/shepherd heartbeats), authoring rules in docs/self-modification.md
  §12, and `work/VERSION` written at ONBOARDING Step 7. The weekly audit
  gains the `definition_version` check — an outdated or half-adopted
  definition surfaces as a `warn` in the audit report (Slack when enabled).

**Upgrade:**
- Nothing to apply — the check serving this migration just records the
  version (writes `work/VERSION`). A missing `work/VERSION` is treated as
  version `1.0.0`.

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
