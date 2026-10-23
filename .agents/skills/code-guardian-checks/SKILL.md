---
name: code-guardian-checks
description: >
  Review checks for dam-agents/code-guardian: conventions, tests, invariants.
  Each check is a rule the repository states or its maintainers chose. Use when
  reviewing a pull request of code-guardian — "code-guardian checks",
  "repository rules" — or as a configured review skill of an automated review
  agent.
---
<!-- code-guardian-row: | code-guardian-checks | dam-agents/code-guardian | .md,.sh,.yaml | Code Guardian Checks | -->

# Code Guardian checks

Checks a pull request against the rules below. Read the diff
(`git diff origin/<base>...HEAD`) and only the files a rule names. Report
only a rule that the diff breaks; the general review covers the rest.

## Rules

### Conventions
- The reading order in `AGENTS.md` holds: no up-front read is added before `CLAUDE.md`, `docs/runbook.md` (a run with work), or the one `docs/` file the work needs (source: `AGENTS.md`)
- Every scheduled run reads `docs/runbook.md` before any other action (source: `CLAUDE.md`)
- Every outward text — review, comment, issue, chat — is ASD-STE100 (Simplified Technical English) (source: `CLAUDE.md`, `docs/review.md`)
- A definition file (`CLAUDE.md`, `AGENTS.md`, `docs/**`, `scripts/**`, `kit.yaml`, `ONBOARDING.md`) changes only with the docs update that `docs/self-modification.md` names (source: `CLAUDE.md`, `docs/self-modification.md`)

### Tests
- A new or changed `scripts/<name>.sh` has its test at `scripts/tests/test_<name>.sh`, of the kind its neighbors already use (source: `scripts/tests`)
- No test waits on time or reads the real clock; it uses a fixed fixture (source: `scripts/tests`)
- No unit test calls a real network or service; it stubs the call (source: `scripts/tests`)
- No focused or skipped test is committed without a reason in the test or the PR body (source: `scripts/tests`)
- A test asserts its result; it does not only run the code (source: `scripts/tests`)

### Invariants
- Nothing under `work/` is committed: `.gitignore` ignores the top level and re-includes only the definition files (source: `.gitignore`)
- A posted review carries `<!-- <review_marker> headRefOid=<full-sha> -->` (source: `docs/review-mechanics.md`)
- Every gated schedule in `kit.yaml` has a `precheck`, and its task names the `CLAUDE.md` run it follows (source: `kit.yaml`)

## Report

One bullet per broken rule: what is wrong, where (`path:line`), the fix.
No broken rule → `✅ No findings.`

## Cost bounds

The diff and the files a rule names; no walk of the tree.
