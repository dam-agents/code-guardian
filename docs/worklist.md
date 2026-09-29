# The schedule gate and the worklist

Read this file when a run has no worklist from the gate — the ungated audit,
the direct session, a gate that broke — when preflight printed no JSON, or when
the operator asks about the gate or a worklist key. A gated run already holds
its worklist and follows [runbook.md](runbook.md) alone.

## The schedule gate

Every gated schedule — all of them except the audit — carries a `precheck`:
`scripts/precheck.sh <mode>` runs preflight *before* the platform starts a
session and turns the answer into an exit code, so a tick with no work costs no
model call at all. A started run receives the gate's stdout: the
`worklist: <path>` line, the due keys, and preflight's `logs` to echo.

- **Read that file and never run `preflight.sh` again this run.** One fire is
  one preflight pass: the `done → awaiting_label` flip and the once-per-UTC-day
  stall-alert claim are already spent, so a second pass answers with less than
  the first.
- **Bookkeeping alone waits.** `selfheals_due`, `prunes_due` and
  `status_resets_due` never open the gate by themselves: they ride along with
  the next run that has work of its own, and start a run of their own only after
  6 hours of waiting or 10 pending items. That run's worklist carries
  `housekeeping_only: true` and reads the short set ([runbook.md](runbook.md) →
  **Review run** step 2). A `stall_alert` never waits — its once-per-UTC-day
  claim is spent the moment preflight detects it.
- A gated idle tick produces no chat line. `HEARTBEAT.log` and the structured
  log are its record ([logging.md](logging.md)), and the audit's heartbeat-gap
  check reads them. The gate logs outside a session, so its `precheck` event and
  the preflight pass it drives carry their own run id and the session carries
  another — read one fire as that pair ([logging.md](logging.md) → **The events
  log**).
- The gate broke — a crash, the platform's two-minute limit, or a preflight that
  could not decide (no target repo, no answer from the GitHub API) — and the
  session starts anyway; its prompt names the reason. Run the entry command
  yourself.
- **An agent runtime older than the platform's precheck support ignores the
  field**: the session starts with nothing from the gate in its prompt, so the
  same fallback applies and the run is correct — only the saving is missing. The
  fix is a runtime upgrade (operator-only), never a change to the run.
- **The audit is never gated** (its worklist always carries work) and neither is
  the direct session: both run the **Entry command** below.

## The pre-flight contract

**Entry command:** `bash "$HOME/scripts/preflight.sh" <mode>` — `review`,
`shepherd`, `audit`, `benchmark` or `survey`. A run executes it only when its
prompt carries no worklist path: the ungated audit, the direct session, a gate
that broke. Cadence, gate and task text per run: ONBOARDING Step 6.

**The script detects, it never acts** — no GitHub writes, no commits, no
pushes. It lists open non-draft PRs in one REST call and computes every
decision:

- same-SHA dedup, in-progress locks (50-min TTL; takeover only when the holder
  is also silent — [review-mechanics.md](review-mechanics.md) → **Live
  holder**);
- the **re-review trigger gate** (label and/or review request per
  `rereview_trigger`), urgent-label flagging and ordering;
- remote marker dedup (anchored + unanchored), verified prune candidates, the
  artifact assignee gate, the ledger-deduped mention scan;
- shepherd classifications with the full nudge ladder and merge-conflict
  flagging.

It also installs the configured skills (SHA-cached) when a review or artifact
is due, and, with a review due, refreshes the project profile and attaches each
entry's inventory ([profile.md](profile.md)).

Its only local writes are bookkeeping: the REVIEWS.md `done → awaiting_label`
flip, shepherd-ledger bookkeeping for rows with no nudge due, the housekeeping
batch's wait marker (`work/.housekeeping-since`), log lines
(`HEARTBEAT.log`, `SHEPHERD.log`, structured events per
[logging.md](logging.md)), the skill cache, the project profile
(`work/PROFILE.{json,md}` and its `/tmp` mirror), and the audit-mode cleanups
(14-day log retention, stale-clone sweep) plus that mode's own worklist at
`work/audit/last-worklist.json` ([trends.md](trends.md)).

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
| `label_cleanups_due` | `{number, label, request}` — a trigger with nothing new to review (no new commits **and** no description edit) → clear what it flags | review-bookkeeping.md → **Label bookkeeping** |
| `selfheals_due` | a remote marker with no local row → write the REVIEWS.md row | review-bookkeeping.md → **Label bookkeeping** |
| `prunes_due` | PRs verified CLOSED/MERGED → delete their state, artifact included | review-bookkeeping.md → **Pruning** |
| `ci_failures_due` | `{number, sha, url, checks[]}` — a reviewed PR whose checks failed on the reviewed SHA → one triage comment | [ci-triage.md](ci-triage.md) + [review.md](review.md) |
| `status_resets_due` | a progress status left `pending` by an abandoned review (only under `review_progress: enabled`) → close it out, delete the row | review-bookkeeping.md → **Progress signal on GitHub** |
| `artifacts_due` | `action: generate` \| `retry_unassign` | [artifact.md](artifact.md) |
| `urgent_alerts_due` | urgent PRs not yet announced (only under `slack_notifications: enabled`) → mention-free Slack channel alert, **before any other run work** | review-urgent.md → **Urgent PRs** |
| `mentions_due` | human GitHub text addressed to the bot; ledger-deduped, gated by `mention_replies` → reply, record feedback, or serve a review request, **before the review loop** | [mentions.md](mentions.md) + [review.md](review.md) |
| `nudges_due` | Slack nudges with a precomputed `row_update`; the send-then-record step is yours | [shepherd.md](shepherd.md) |
| `stats`, `checks`, `failures` | audit mode: 7-day statistics, deterministic health checks, and the week's error events grouped into signatures for you to diagnose | [audit.md](audit.md) |
| `benchmark_due` | benchmark mode: `action: create_fixture` \| `run` | [benchmark.md](benchmark.md) |
| `survey_due` | survey mode: the area to read this run, with its caps and history slice | [survey.md](survey.md) |
| `stall_alert` | `{count, threshold, prs, window_hours, per_day_7d}`, present only when stalled reviews in the last 24 h reached `stall_alert_threshold` (once per UTC day) → report it after the review work | review-bookkeeping.md → **Stalled-review rate alert** |
| `housekeeping_only` | present and `true` when the run carries bookkeeping alone → the short read set and the short self-check | **The schedule gate** |
| `read_set` | review mode: the files this run reads before acting — the **Where** files of the due keys above | [runbook.md](runbook.md) → **Review run** |
| `skills` | per-skill install status (`installed`/`cached`/`harness`/`install-failed`) | [skills.md](skills.md) |
| `config` | every `work/CONFIG.md` key resolved with its default, plus the `skills_table` and `watch_rules` rows; present whenever there is work | [config.md](config.md) |
| `memory` | the memory budget (`memory_lines`/120, `long_lines` past 120 chars, `insights`/15, `feedback`/20, `lessons_sections`/10, `over_budget`); an overrun makes the audit's consolidation mandatory | [preferences.md](preferences.md) |
| `profile` | the profile's status (`current` \| `regenerated` \| `unverified` \| `unavailable` \| `disabled`, with mode, base and age) → echo one line; never a reason to skip a review | [profile.md](profile.md) |

Script missing or failing (non-JSON output) → log it and do the equivalent work
manually per the `docs/` files; never silently skip a heartbeat.

## Runtime configuration: `work/CONFIG.md`

**This definition is project-agnostic**: every instance-specific value lives in
`work/CONFIG.md`. Key semantics, defaults, multi-host reference handling and
the `cfg()` reader are in [config.md](config.md).

- A run with work receives every key **resolved, defaults applied, tables as
  rows** in the worklist's `config` object. It reads `work/CONFIG.md` itself
  only in the manual fallback, or when the operator changes a value.
- Required keys: `github_repo`, `bot_login`, `review_marker` — the last
  **immutable once the first review is posted**.
- The target repo resolving empty → stop and ask the operator for the slug.
  Never guess.
