# The schedule gate and the worklist

Read this file when a run has no worklist from the gate — the ungated audit,
the direct session, a gate that broke — when a pass printed no JSON, or when
the operator asks about the gate or a worklist key. A gated run already holds
its worklist and follows [runbook.md](runbook.md) alone.

## The schedule gate

Every gated schedule — all of them except the audit — carries a `precheck`:
`scripts/precheck.sh <mode>` runs one pass — `scripts/preflight.sh <mode>`, or
`scripts/monitor.sh` for the monitor ([monitor.md](monitor.md)) — *before* the
platform starts a session and turns the answer into an exit code, so a tick
with no work costs no model call at all. A started run receives the gate's
stdout: the `worklist: <path>` line, the due keys, and the pass's `logs` to
echo.

- **Read that file and never run `preflight.sh` (or `monitor.sh`) again this
  run.** One fire is one pass: the `done → awaiting_label` flip and the
  monitor's claims (alert claims, the once-per-UTC-day stall-alert claim, the
  anomaly-alert marker) are already spent, so a second pass answers with less
  than the first.
- **Bookkeeping alone waits.** `selfheals_due`, `prunes_due` and
  `status_resets_due` never open the gate by themselves: they ride along with
  the next run that has work of its own, and start a run of their own only after
  6 hours of waiting or 10 pending items. That run's worklist carries
  `housekeeping_only: true` and reads the short set ([runbook.md](runbook.md) →
  **Review run** step 2).
- A gated idle tick produces no chat line. `HEARTBEAT.log` and the structured
  log are its record ([logging.md](logging.md)), read by the audit's
  `heartbeats` check and the monitor's `heartbeat_gap` alert. The gate logs
  outside a session, so its `precheck` event and the pass it drives carry their
  own run id and the session carries another — read one fire as that pair
  ([logging.md](logging.md) → **The events log**).
- The gate broke — a crash, a pass over the gate's own 100 s budget (its prompt
  names the last logged step), the platform's two-minute limit, or a preflight
  that could not decide (no target repo, no answer from the GitHub API) — and the
  session starts anyway; its prompt names the reason. Run the entry command
  yourself.
- **A runtime without precheck support ignores the field**: every fire starts
  a session with nothing from the gate in its prompt, and the same fallback
  applies — the run is correct, only the saving is missing. The fix is a
  runtime upgrade (operator-only).
- **The audit is never gated** (its script cannot answer "nothing to do" while
  `audit_report` is enabled) and neither is the direct session: both run the
  **Entry command** below.

## The pre-flight contract

**Entry command:** `bash "$HOME/scripts/preflight.sh" <mode>` — `review`,
`shepherd`, `audit`, `benchmark` or `survey`; `bash "$HOME/scripts/monitor.sh"`
for the monitor — for a run whose prompt carries no worklist path. Cadence,
gate and task text per run: ONBOARDING Step 6.

**The script detects, it never acts** — no GitHub writes, no commits, no
pushes. It lists open non-draft PRs in one REST call and computes every
decision:

- same-SHA dedup, in-progress locks (50-min TTL; takeover only when the holder
  is also silent — [review-mechanics.md](review-mechanics.md) → **Live
  holder**);
- the **re-review trigger gate** (label and/or review request per
  `rereview_trigger`, and `rereview_delta_label`), urgent-label flagging and
  ordering;
- remote marker dedup (anchored + unanchored), verified prune candidates, the
  artifact gate (assignee or `artifact_label`), the ledger-deduped mention scan;
- shepherd classifications with the full nudge ladder and merge-conflict
  flagging.

It also installs the configured skills (SHA-cached) when a review or artifact
is due, and, with a review due, refreshes the project profile and attaches each
entry's inventory ([profile.md](profile.md)). Its local writes are bookkeeping
alone, listed in the script's header — [preflight.sh](../scripts/preflight.sh),
and [monitor.sh](../scripts/monitor.sh) for the monitor's pass.

It prints one JSON object — through the gate above, or on stdout in an ungated
run.

**`nothing_to_do: true`** — what an ungated run reads on stdout, and what a
gated run reads when it falls back to the entry command (the gate broke, or the
worklist file is gone) → echo its `logs` to the chat UI as a one-line summary
("no new changes") and **end the run** — no state writes, no API calls, no
self-check narration.

**`error`** — preflight could not decide and exits 2 (the gate turns this into
a broken gate). Put the `error` text in the one chat line in place of "no new
changes", then end the run the same way.

**Otherwise you perform every action in the worklist**, per the referenced
`docs/` file:

| Key | What it is | Where |
| --- | --- | --- |
| `reviews_due` | PRs to review — `kind` (`first`/`re-review`), `prior`, and the `takeover` / `urgent` / `closed` / `full` / `description_changed` flags; urgent first. Each entry also carries its inventory: `files[]` (classified; `noise_count`, `files_truncated`), `profile_slice` (rows with `verify_live`), `structure_changed`, `history_slice`, `memory_due`, `skill_routing` | [review.md](review.md), [finding-form.md](finding-form.md), [skills.md](skills.md); plus [review-rereview.md](review-rereview.md) for a `re-review`, [review-urgent.md](review-urgent.md) for `urgent` / `closed`, [watches.md](watches.md) with `config.watch_rules` |
| `label_cleanups_due` | `{number, label, request, delta_label}` — a trigger with nothing new to review (no new commits **and** no description edit) → clear what it flags | review-bookkeeping.md → **Label bookkeeping** |
| `selfheals_due` | a remote marker with no local row → write the REVIEWS.md row | review-bookkeeping.md → **Label bookkeeping** |
| `prunes_due` | PRs verified CLOSED/MERGED → delete their state, artifact included | review-bookkeeping.md → **Pruning** |
| `ci_failures_due` | `{number, sha, url, checks[]}` — a reviewed PR whose checks failed on the reviewed SHA → one triage comment | [ci-triage.md](ci-triage.md) + [review.md](review.md) |
| `merges_due` | `{number, sha, method}` — a labeled PR that passed every auto-merge gate (only under `auto_merge: enabled`) → `review-pr.sh merge` | [auto-merge.md](auto-merge.md) |
| `fixes_due` | `{number, sha, findings}` — a labeled PR whose current review left blocking findings with a fix (only under `agent_fixes: enabled`) → one fix round | [agent-fixes.md](agent-fixes.md) + [review.md](review.md) |
| `status_resets_due` | a progress status left `pending` by an abandoned review (only under `review_progress: enabled`) → close it out, delete the row | review-bookkeeping.md → **Progress signal on GitHub** |
| `artifacts_due` | `{number, action, triggers}` — `action: generate` \| `retry_release`; `triggers` ⊆ `assignee`, `label` | [artifact.md](artifact.md) |
| `urgent_alerts_due` | urgent PRs not yet announced (only under `slack_notifications: enabled`) → mention-free Slack channel alert, **before any PR work** | review-urgent.md → **Urgent PRs** |
| `mentions_due` | human GitHub text addressed to the bot; ledger-deduped, gated by `mention_replies` → reply, record feedback, or serve a review request, **before the PR's review** | [mentions.md](mentions.md) + [review.md](review.md); [watches.md](watches.md) with `config.watch_rules` |
| `nudges_due` | Slack nudges with a precomputed `row_update`; the send-then-record step is yours | [shepherd.md](shepherd.md) |
| `stats`, `checks`, `failures` | audit mode: 7-day statistics, deterministic health checks, and the week's error events grouped into signatures for you to diagnose | [audit.md](audit.md) |
| `benchmark_due` | benchmark mode: `action: create_fixture` \| `run` | [benchmark.md](benchmark.md) |
| `survey_due` | survey mode: the area to read this run, with its history slice | [survey.md](survey.md) |
| `alerts_due`, `stall_alert`, `review_anomaly`, `direct`, `suppressed` | monitor mode: the alerts to report (each with its `id`), the stall and anomaly alerts, the direct send's result, the count of alerts already sent | [monitor.md](monitor.md) |
| `housekeeping_only` | present and `true` when the run carries bookkeeping alone → the short read set and the short self-check | **The schedule gate** |
| `dispatched` | `{number, by}`, present in a worklist `dispatch.sh plan` cut for one PR → the session takes that PR's hold first | [runbook.md](runbook.md) → **Review run** step 1 |
| `read_set` | review mode: the files this run reads before acting — the **Where** files of the due keys above, plus `work/MEMORY.md` and `work/LESSONS.md` | [runbook.md](runbook.md) → **Review run** |
| `skills` | per-skill install status (`installed`/`cached`/`harness`/`install-failed`) | [skills.md](skills.md) |
| `config` | every `work/CONFIG.md` key resolved with its default, plus the `skills_table` and `watch_rules` rows; present in a review or shepherd worklist with work. A monitor worklist carries its own keys alone | [config.md](config.md) |
| `memory` | the memory budget — each measure of MEMORY.md, LESSONS.md and the area files beside its limit, and `over_budget`; an overrun makes the audit's consolidation mandatory | [preferences.md](preferences.md) |
| `profile` | the profile's status (`current` \| `regenerated` \| `unverified` \| `unavailable` \| `disabled`, with mode, base and age) → echo one line; never a reason to skip a review | [profile.md](profile.md) |

**PR holds** — a run holds only the PR it works on, and does that PR's
mentions and review in one hold (`work/.holds.lock/<n>`, taken and given back
by `review-pr.sh hold|release`, [lib/holds.sh](../scripts/lib/holds.sh));
`hold <n>` also gives back every other hold of the run, so a run holds at most
one PR — plus the PR of an on-demand review, whose hold `prepare` takes and
[review-on-demand.md](review-on-demand.md) gives back. Preflight drops the
`reviews_due` and `mentions_due` entries of a PR another live run holds, and
logs why; the first run after the release serves them. A hold whose run is quiet by the **Live holder** windows
([review-mechanics.md](review-mechanics.md)) is dead and removed; the `Stop`
hook releases the holds a finished run still owns ([logging.md](logging.md) →
**Harness adapters**).

**Dispatch** — under `review_dispatch: enabled` (the default), the run that
receives a worklist with several PRs keeps its first PR, in the order of
[runbook.md](runbook.md) → **Review run** steps 5 to 10, and starts every other
PR at once in a one-time session of its own: `dispatch.sh plan` cuts one unit
worklist per PR next to the gate's file — that PR's entries from every per-PR
key, its urgent alert and its bookkeeping rows included, `dispatched: {number,
by}`, and a `read_set` of its own — and prints the exact `name`
(`code-guardian-review-pr-<n>`), `task`, `sessionTitle` and `model` (the
config's `review_model`, absent under `default`) of each
`mcp__platform-outbound__schedule_once` call. The task carries the PR number and
the unit's path alone. `dispatch.sh rest` then writes the run's own worklist
without the PRs the platform accepted and prints its session title; a PR it
refused stays in the run. The new session takes its PR's hold first; a PR whose
session never starts is the next heartbeat's
([scripts/dispatch.sh](../scripts/dispatch.sh)).

`dispatch.sh` derives the titles from PR numbers and work alone, for a
dispatched session's `sessionTitle` and the `title` of `rest`
([runbook.md](runbook.md) → **Session titles**): `Review PR #<n>`
(`Re-review PR #<n>`, `Review urgent PR #<n>`), `Answer mention on #<n>`,
`Publish artifact for PR #<n>`, `Triage CI on PR #<n>`, `Merge PR #<n>`,
`Fix findings on PR #<n>`; `Review PRs #<n>, #<m>` for several kept PRs;
with none, `Report review alerts` when `urgent_alerts_due` is due, else
`Tidy review state`.

## Runtime configuration: `work/CONFIG.md`

A run with work reads every key resolved in the worklist's `config` object,
and `work/CONFIG.md` itself only in the manual fallback or on an operator
change. Semantics, defaults, required keys and the `cfg()` reader:
[config.md](config.md).
