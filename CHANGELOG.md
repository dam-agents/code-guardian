# Changelog

**Migration instructions, not a change log.** Per version, the idempotent
**Upgrade** steps a deployed instance applies when crossing it — what to run,
update, or change (schedules, config keys, state formats). Most versions need
nothing. What changed and why lives in the PR and commit history, not here.
Consumed by the version check ([docs/persistence.md](docs/persistence.md) →
**Definition version & upgrade**); authoring rules:
[docs/self-modification.md](docs/self-modification.md) §12.

Entries below 2.4.2 predate this format and also carry a **Changed** block;
they are released history and stay as written.

## 3.19.0 — 2026-09-03

**Upgrade:** Nothing — docs are re-read per run.

## 3.18.0 — 2026-09-03

**Upgrade:** Optional — the review heartbeat gains a second, slower cadence for
quiet hours. Four `work/CONFIG.md` keys drive it: `active_hours` and
`active_days` delimit the active window, `review_interval_active` (default `5`)
is the cadence inside it, `review_interval_quiet` (default `60`) the one
outside. Missing keys change nothing — the instance keeps the single schedule it
already has. To adopt: write the four keys, then re-register the review
schedules per [ONBOARDING.md](ONBOARDING.md) Step 6a, which replaces the one
existing `code-guardian-review-*` schedule with `…-review-active` plus the
`…-review-quiet` / `…-review-offdays` ones the window calls for —
`delete_schedule` the old one in the same step, or both cadences fire. The trade
to state when offering it: a PR opened in a quiet hour waits up to
`review_interval_quiet` minutes, an `urgent_label` one included.

## 3.17.0 — 2026-09-01

**Upgrade:** Nothing — docs are re-read per run. Skills whose trigger lists
overlap now all receive the shared files, so a `work/CONFIG.md`
`## Review skills` table that relied on row order to keep a skill away from an
extension needs that extension removed from its trigger list instead
([docs/skills.md](docs/skills.md) → **Triggers & file routing**);
**operator-only** to change, and the default table has no overlapping lists.

## 3.16.0 — 2026-09-01

**Upgrade:** Nothing — docs are re-read per run.

## 3.15.5 — 2026-09-01

**Upgrade:** Nothing — docs are re-read per run and the new detection is
computed by `scripts/preflight.sh` from live GitHub state.

## 3.15.4 — 2026-09-01

**Upgrade:** Nothing — docs are re-read per run.

## 3.15.3 — 2026-09-01

**Upgrade:** Nothing — the harness hooks are registered by path, so the edited
adapters take effect from the next session; docs are re-read per run.

## 3.15.2 — 2026-08-31

**Upgrade:** Nothing — docs are re-read per run.

## 3.15.1 — 2026-08-17

**Upgrade:** Nothing — the next benchmark run regenerates `report.html` in
place (its published URL is unchanged). To restyle it before then:
`bash "$HOME/scripts/benchmark-report.sh" "$HOME/work/benchmark" > "$HOME/work/benchmark/report.html"`.

## 3.15.0 — 2026-08-17

**Upgrade:**
- Offer the operator the optional `## Benchmark model prices` table in
  `work/CONFIG.md` ([docs/benchmark.md](docs/benchmark.md) → **Model
  prices**) — it enables the benchmark report's `est $` cost column; the
  offer only, never enable unasked.
- **Operator-only:** benchmark runs recorded under 3.14.x delegated
  execution undercounted tokens (subagent usage was not summed). If any
  exist in `work/benchmark/results/`, add one line under the RESULTS.md
  header marking those timestamps' token/cost columns non-comparable
  (same pattern as docs/benchmark.md → **Retiring a fixture set**, step 2);
  check first — the line may already be present.

## 3.14.1 — 2026-08-16

**Upgrade:** Nothing — docs are re-read per run.

## 3.14.0 — 2026-08-16

**Upgrade:** Nothing — scripts and docs are re-read per run. Benchmark
review execution is now delegated to per-phase reviewer subagents
([docs/benchmark.md](docs/benchmark.md) → Phase 1), so a full run fits one
session; the segmented mode remains as the no-subagent fallback. An
in-flight segmented run finishes under the version it started on before
adopting this one.

## 3.13.0 — 2026-08-16

**Upgrade:** Nothing — scripts and docs are re-read per run. A manual
benchmark run may now be segmented one-fixture-per-session
([docs/benchmark.md](docs/benchmark.md) → **Segmented run**); a paused
segmented run is marked by `work/benchmark/.run-notes-<ts>.md`, which gates
scheduled benchmark ticks until it finishes or ages past 7 days.

## 3.12.2 — 2026-08-14

**Upgrade:** Nothing — scripts and docs are re-read per run. A scored
benchmark run now takes `work/benchmark/.run-lock` and keys its phase state
by the run nonce, so two overlapping runs no longer corrupt each other's
measurements; a leftover lock from a crashed run expires after 6 h on its
own.

## 3.12.1 — 2026-08-14

**Upgrade:** Nothing — scripts and docs are re-read per run. A fixture set that
already validated stays valid; the new anchor-spacing check only reports
`manifest_spacing` failures on sets whose defects sit closer than 10 lines
apart in one file, which `benchmark-validate.sh fixture` now names.

## 3.12.0 — 2026-08-14

**Upgrade:** the benchmark now refuses to score a fixture set whose ground
truth leaks into the reviewed inputs, and refuses to record results that
drift from the documented shape. Under `benchmark: enabled`, run
`bash "$HOME/scripts/benchmark-validate.sh" fixture "$HOME/work/benchmark/fixture"/*/`
once: on `FAIL`, that set's scores are invalid — retire and replace it, and
mark the affected RESULTS.md rows non-comparable
(docs/benchmark.md → **Retiring a fixture set**; the retire/replace decision
is **operator-only**). The weekly audit re-checks both gates
(`benchmark_fixtures`, `benchmark_results`). No config keys change.

## 3.11.0 — 2026-08-14

**Upgrade:** adds the optional monthly self-benchmark of review quality, off
by default (docs/benchmark.md). Enable by writing `- benchmark: enabled` (and
optionally `- benchmark_judge: <pinned-model-id>`,
`- benchmark_report: gist`) to `work/CONFIG.md` and registering the
`code-guardian-benchmark-monthly` schedule per ONBOARDING.md Step 6d; the
first scheduled run creates the fixture set. Without the key, nothing
changes.

## 3.10.2 — 2026-08-14

**Upgrade:** Nothing — scripts are re-read per run; the next weekly audit
reclaims leftover clones of past dead sessions on its own.

## 3.10.1 — 2026-08-13

**Upgrade:** Nothing — the mention scan re-reads its query per run. Mentions
newer than a previously capped page become visible on the next heartbeat, and
`work/MENTIONS.md` dedups the ones already handled.

## 3.10.0 — 2026-08-12

**Upgrade:** Nothing — `scripts/lib/toolpath.sh` is sourced per run and builds
its own cache. The hooks pick it up from their next session with no
re-registration (`install.sh` registers paths, and none changed).

## 3.9.0 — 2026-08-12

**Upgrade:** From this version on, a migration crossing an **Upgrade** block
that introduces an off-by-default feature asks the operator once whether to
enable it, instead of silently leaving the key unwritten
([docs/persistence.md](docs/persistence.md) → **Definition version & upgrade**,
step 2). Nothing to run for this version itself — docs are re-read per run.

## 3.8.0 — 2026-08-12

**Upgrade:** Nothing — the lock TTL and the live-holder check live inside
`scripts/preflight.sh`, and existing `in_progress` rows are read unchanged. A
lock already past the old 30-min TTL is re-evaluated against the new one on the
next heartbeat; a review running across the update keeps its PR.

## 3.7.2 — 2026-08-11

**Upgrade:** Nothing — docs are re-read per run.

## 3.7.1 — 2026-08-11

**Upgrade:** The definition update itself deletes the renamed `AGENT.md`. One
step, idempotent: when `work/AGENTS.md` is missing, create it from the template
in [ONBOARDING.md](ONBOARDING.md) Step 3c.

## 3.7.0 — 2026-08-11

**Upgrade:** Run the verification once and apply every `FAIL` line's `fix:`
instruction (idempotent, read-only):

```bash
bash "$HOME/scripts/verify-onboarding.sh" --live
```

If it reports `config-github_repo`, add `- github_repo: <[host/]owner/repo>`
to `work/CONFIG.md` — a scheduled run carries no session exports, so an
instance relying on a session-only `$GITHUB_REPO` stops at pre-flight.

## 3.6.0 — 2026-08-11

**Upgrade:** Nothing — docs are re-read per run.

## 3.5.0 — 2026-08-10

**Upgrade:** Existing instances keep working unchanged — a bare `owner/repo`
reference still resolves to `github.com`. To move any repo onto another GitHub
host, do the following, all idempotent:

1. Authenticate the host — `gh auth login --hostname <host>` (**operator-only**),
   then `gh auth setup-git`.
2. Host-prefix the reference in `work/CONFIG.md` (`github_repo`,
   `definition_repo`, a `## Review skills` source) or in the platform's
   `GITHUB_REPO` / `GITHUB_REPO_WORK` env var: `<host>/<owner>/<repo>`.
3. When the **target** repo's host is not `github.com`, append
   `export GH_HOST=<host>` to `~/.bashrc` if that line is absent, and point
   `origin` at the definition host:
   `git -C "$HOME" remote set-url origin "https://<def-host>/<owner/repo>.git"`.
4. A non-`github.com` target repo drops the `gist` artifact surface
   ([docs/artifact.md](docs/artifact.md)); with `artifact_targets: gist` only,
   the artifact feature turns itself off and the weekly audit reports it. Set
   `artifact_targets: dam` or `artifact_skill: none` to make that explicit.

## 3.4.0 — 2026-08-10

**Upgrade:** Optional, operator-only — the progress signal is off unless asked
for. To enable it on a deployed instance, add `- review_progress: enabled` to
`work/CONFIG.md` (any other value, or the missing key, keeps it off). Nothing
else: the commit-status `context` is the existing `review_marker`, and no state
format changed.

## 3.3.0 — 2026-08-10

**Upgrade:** Nothing — docs are re-read per run. Reviews posted before this
version carry a `findings-json` line without the new `fix` field; re-reviews
parse them as before.

## 3.2.0 — 2026-08-07
**Upgrade:** Nothing — docs are re-read per run.

## 3.1.0 — 2026-08-07

**Upgrade:**
Nothing mandatory — the check runs at onboarding (ONBOARDING Step 7).
Optionally run `bash "$HOME/scripts/verify-onboarding.sh"` once (offline,
read-only) and apply the `fix:` instruction of any `FAIL` line, re-running
until it prints `PASS`.

## 3.0.0 — 2026-08-07

**Upgrade:**
1. Update the shepherd and audit schedule task texts to the current
   ONBOARDING Step 6 wording (6b: nudges are sent first and recorded in the
   ledger immediately after the send; 6c: the agent-side check list is now
   "schedules, memory compliance, nudge integrity, reaction feedback").
   Idempotent — skip a schedule that already matches or does not exist (no
   shepherd schedule when Slack is disabled).
2. Nothing else is mandatory — the mention scan starts with the next review
   heartbeat (`mention_replies` missing = `enabled`) and the
   `work/MENTIONS.md` ledger is created on first use. **operator-only
   (optional):** add `- mention_replies: disabled` to `work/CONFIG.md` to
   turn mention handling off.

## 2.7.0 — 2026-08-05

**Upgrade:**
Nothing for the review-procedure changes — docs are re-read per run.
**operator-only (optional):** enable the bundled `issue-fit` skill by adding
`| issue-fit | <definition_repo> | always | Issue Fit |` to
`work/CONFIG.md → ## Review skills` (row semantics: `docs/skills.md`). New
onboardings get it by default.

## 2.6.0 — 2026-08-05

**Upgrade:**
Nothing — the metric is computed by `preflight.sh` and the report is composed
per docs, both read fresh each run. Weekly-report delivery is unchanged: still
sent to Slack every week under `slack_notifications: enabled`.

## 2.5.2 — 2026-08-03

**Upgrade:**
Nothing — the corrected sentence prescribes no action, and the version check
reads only **Upgrade** blocks.

## 2.5.1 — 2026-08-03

**Upgrade:**
Nothing — `install.sh` already chmods the hook it registers, so 2.5.0 works
either way.

## 2.5.0 — 2026-08-03

**Upgrade:**
1. Run `bash "$HOME/scripts/harness/claude-code/install.sh"` (idempotent) — it
   registers the new `log-review-step.sh` `PostToolUse` hook. **Required:**
   without it the derived `review_step` events are never written, and
   docs/review.md now tells the agent not to log them manually. The audit's
   `harness_adapter` check warns by name until it is registered; effective from
   the next session.
2. No state migration — the events log is append-only and the new events share
   the existing `review_step` shape.

## 2.4.2 — 2026-08-03

**Upgrade:**
The `Stop` hook's new behavior is effective from the next session — no step if
the hook is already registered. If the audit's `harness_adapter` check warns it
is missing, run `bash "$HOME/scripts/harness/claude-code/install.sh"` once
(idempotent).

## 2.4.1 — 2026-07-31

**Changed:**
- `scripts/preflight.sh`: a `work/.stall-alert.lock` directory left behind by a
  run killed inside the claim section suppressed every future stall alert,
  silently and permanently. A lock older than 5 minutes is now removed as stale
  before the claim (the section is a few local commands, so a legitimate holder
  is never that old).
- `scripts/harness/claude-code/enforce-review-completion.sh`: the `Stop` hook
  read only today's UTC event file, so a run that locked a PR before UTC
  midnight and stopped after it escaped enforcement. It now also reads
  yesterday's file — the run-id filter already scopes events to the current
  run, so this only widens the window, never the runs considered.
- Tests: stale/fresh claim-lock cases in `test_stall_alert.sh`,
  midnight-spanning cases in `test_stop_hook.sh`.

**Upgrade:**
Nothing — scripts run from the updated checkout; the `Stop` hook is registered
by path, so no re-registration is needed.

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
- The hook stops each *individual* stall but can't see a **pattern**, so
  preflight gains the **stalled-review rate alert**: it counts `stale
  in_progress lock` takeovers over the last 24 h and, at or above the new
  `stall_alert_threshold` key (missing = `4`; `0`/`off` disables; unparseable
  falls back to `4`), emits `stall_alert: {count, threshold, prs, window_hours,
  per_day_7d}` — **once per UTC day** (`work/.stall-alert-day`, claimed under a
  `mkdir` lock so concurrent heartbeats can't double-send); `per_day_7d` gives
  the per-day trend, so one bad day reads differently from a chronic one. The
  agent reports it after its review work (so the count includes this run): chat
  UI always, plus a DM to `escalation_owner` under `slack_notifications:
  enabled` — never the shared channel, since this is operations, not team news.
  A due alert alone makes a run non-idle. The four days before this change ran
  1 / 6 / 17 / 5 stalls a day, entirely unreported. The alert is a signal, never
  a repair: no lock clearing, no re-review. Home: docs/review.md →
  **Stalled-review rate alert**.
- Audit `harness_adapter` check now verifies **all three** adapter hooks and
  names the missing ones — it passed on a partially-registered instance before,
  so an upgrade that never re-ran `install.sh` went unnoticed.
- Tests: `scripts/tests/test_stop_hook.sh` (12 assertions over the hook's
  terminal-step logic, loop guard and no-op paths), `test_stall_alert.sh`
  (15 assertions — threshold boundary, distinct-PR list, per-day trend, marker
  + released lock, once-per-day dedup, 24 h window edge, stale marker,
  custom/off/garbage threshold values, and that ordinary fresh-lock skips never
  count), plus two `harness_adapter` cases in `test_audit_stats.sh`.

**Upgrade:**
Docs are re-read per run and the default stall threshold needs no
configuration. Two idempotent steps:
1. Re-run `bash "$HOME/scripts/harness/claude-code/install.sh"` (safe to
   re-run; it rewrites only its own hook entries) — the `Stop` hook only exists
   once registered. Effective from the **next** session; the audit's
   `harness_adapter` check warns until then.
2. Optional: to tune or silence the rate alert, set `stall_alert_threshold:
   <n|off>` in `work/CONFIG.md` (missing key = `4`). Slack delivery
   additionally needs the existing `slack_notifications: enabled` +
   `escalation_owner`; without them the alert still reaches the chat UI.

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
