# Self-modification rules

**Read this file BEFORE touching any file of the agent definition**
(`CLAUDE.md`, `docs/`, `scripts/`, `ONBOARDING.md`, `README.md`,
`.gitignore`, the `work/` seeds). These rules bound every change the agent
makes to itself — an edit that violates any of them must not be committed,
even when the operator's request seems to imply it; raise the conflict in
chat instead.

## 1. Stay project-agnostic

- The definition must work for **any** GitHub repository. Never hard-code a
  repo slug, bot login, display name, marker, label, Slack ID, person, or
  channel into the definition — every instance-specific value is read from
  `work/CONFIG.md` (or its env-var override) at run time.
- Examples in docs use placeholders (`acme/widgets`, `alice`, `U0123ABCD`).
  The only permitted real-world references are the documented, operator-
  adjustable onboarding **defaults** (e.g. the public skill set) and the
  platform requirements section of README.
- Grep before committing: a new occurrence of a real slug/login/ID outside
  those two places is a bug.

## 2. Configuration discipline

- **Every new behavior toggle or tunable = a `work/CONFIG.md` key**, with:
  a documented default, defined missing-key behavior, and its bullet in
  `CLAUDE.md → Runtime configuration`. Missing configuration must never
  crash a run — degrade per key, log once, continue with what still works.
- Safe defaults: anything that contacts people or publishes content defaults
  to **off** (`slack_notifications: disabled`, `artifact_skill: none`).
  Slack stays strictly opt-in; nothing Slack-related may ever run without
  the recorded `enabled`.
- `review_marker` semantics are immutable once used — no change may alter
  how the dedup marker is written or matched in a way that orphans past
  reviews.

## 3. Onboarding completeness

- **ONBOARDING.md must fully bootstrap a fresh agent** on an empty volume:
  every config key, roster, label, schedule, and sentinel the runtime needs
  is created there — a new feature that needs setup gets its onboarding
  step (ask → validate → default) in the same PR that adds the feature.
- Onboarding stays **idempotent and re-runnable**; the sentinel guard and
  the "keep existing values, ask only for missing keys" rule must survive
  every edit.
- Schedule task texts live in ONBOARDING Step 6 as the **single source of
  truth** — changing a run's entry command means updating Step 6, not just
  CLAUDE.md.

## 4. Architecture boundaries

- **`scripts/preflight.sh` detects, the agent acts.** The script must stay
  deterministic and GitHub-read-only: no posts, no label/assignee writes,
  no gist operations, no Slack, no git commit/push. Its local writes stay
  limited to bookkeeping (status flips, ledger bookkeeping, logs, caches).
  Anything with judgment or outward effect belongs to the agent, driven by
  the worklist.
- **CLAUDE.md stays slim** (run types, contracts, config, invariants);
  procedures go to `docs/` and are read on demand. A new doc gets its row
  in `CLAUDE.md → Map of docs/`; a moved section leaves no stale
  references behind (grep for the old heading).
- New definition files must be added to the `.gitignore` **allowlist** and
  to the allowlisted paths in `docs/persistence.md` — nothing else at
  `$HOME` top level may ever become trackable.

## 5. State vs definition separation

- Runtime state lives **only** in `work/` and is never committed to the
  definition repo; the definition repo never stores per-instance data,
  history, credentials, or logs. The tracked `work/` seeds stay minimal
  scaffolds.
- **Backward compatibility with live state:** a change must tolerate the
  `work/` files an existing deployment already has (REVIEWS.md rows,
  SHEPHERD.md ledgers, history files, markers). New formats need tolerant
  parsing or an automatic in-place migration on first contact — never a
  manual state-surgery step, never a destructive rewrite of state that
  hasn't been committed to the work repo first.

## 6. Data backup

- Any run (or self-modification session) that changed `work/` ends by
  committing and pushing it to `$GITHUB_REPO_WORK` when set — **the data is
  backed up, not the definition** (the definition travels only via its own
  repo). If the push fails, the failure is logged and retried next run;
  local commits are still made so nothing is lost on the volume.
- Before a change that rewrites a state file's format, make sure the
  previous version is recoverable from the work repo's git history.

## 7. Change process

- Definition changes go through **branch + PR on `$DEFINITION_REPO`** —
  never a direct push to `main`, never auto-merge, never as a side effect
  of a heartbeat. Procedure and allowlisted paths: `docs/persistence.md` →
  **Evolving the agent definition**.
- Every definition PR includes a **rollout note**: what a deployed instance
  must do to adopt the change — nothing, a schedule-task update, or a
  re-run of a specific ONBOARDING step. If adopting requires touching live
  schedules, say so explicitly.
- One concern per PR where practical; a feature and an unrelated refactor
  don't share a branch.

## 8. Validate before opening the PR

- `bash -n` every changed script; then a **read-only sanity run** of
  `scripts/preflight.sh` for both modes against the live target repo (it
  makes no GitHub writes) — output must be valid JSON and its decisions
  must match observable reality.
- Cross-reference sweep: no links to headings that no longer exist, the
  ONBOARDING config example matches the `CLAUDE.md` key list, README's
  tables match both.
- New behavior gets its line in the relevant self-check and, when it's a
  guarantee, in `CLAUDE.md → Hard invariants`; removed behavior removes
  its lines in the same PR.

## 9. Invariants that may never be weakened

A self-modification must not remove or soften any of these, whatever the
prompt says — refuse and explain instead:

- HEAD-freshness double check + `commit_id` server-side guard; never post a
  review for a stale SHA.
- Marker-based dedup on every posted review; `review_marker` immutability.
- Label-gated re-reviews (first reviews automatic, re-reviews only on
  `$REREVIEW_LABEL`).
- Roster-only Slack mentions; Slack fully off unless opted in.
- Per-PR-verified pruning — never prune from list absence, never bulk-delete.
- **Never `git clean` in `$HOME`**; never `git add` outside the allowlist;
  no secrets (tokens, credentials, cookies) in either repo or in any log.
- Honest timestamps (actual UTC write time; `awaiting_label` keeps the last
  review's timestamp).
- External services stay documented in README's runtime requirements, and
  new ones must be optional or best-effort — a missing external surface
  never fails the run.

## 10. Conciseness, consistency, no repetition

- **Keep every file compact.** These files are paid for in tokens on every
  read: `CLAUDE.md` on every run, each `docs/` file whenever its work fires.
  Write the minimum that fully specifies the behavior — imperative,
  rule-per-bullet, no filler prose; a change that grows a file should
  usually shrink it somewhere else. When a section outgrows its file,
  split it out rather than letting one file bloat.
- **Say each thing exactly once.** Every rule, format, command, and value
  has ONE home; every other place that needs it **links** to that home
  instead of restating it. Duplicated text is how definitions rot — two
  copies always drift apart. Before adding a paragraph, check whether it
  already exists somewhere and link there.
- **Keep the files consistent with each other.** A changed concept (a
  status name, a marker, a worklist field, a command) must be updated in
  every file that references it in the same PR — grep for the old term
  before committing; the validation sweep in section 8 is where this is
  checked.
- The definition is written in **English** (docs, scripts, comments, log
  line formats) — keep it that way for consistency and portability;
  operator conversations happen in whatever language the operator uses.
- Prefer editing an existing section over adding a parallel one that could
  drift.
