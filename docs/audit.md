# Weekly audit — health check & report

Read this file on every **audit run** (`preflight.sh audit` returned
`nothing_to_do: false`). The script gathered the 7-day `stats` and `checks`;
you walk the task list, add the judgment checks and send the report.

**The audit fixes nothing.** Its only outward writes are the report, the
tracking issue of task 3 and the trend publish of task 36; its only local
writes beyond `AUDIT.log` are memory (lessons per
[preferences.md](preferences.md), task 34), the profile notes (task 35) and
the trend append (task 36). Routine findings (pending prunes, stale locks) heal
through the review heartbeat's worklist; everything else goes to the operator.
Never skip a task: one impossible this week (missing data, API error) is a
`warn` with the reason.

## Task list

### A. Script findings (from the worklist — triage, never recompute)

1. Walk every `checks[]` entry. Every `fail` and `warn` appears in the report;
   never summarize a `fail` away — except a `memory_budget` warn or fail that
   task 34 brought inside every bound (`bash "$HOME/scripts/preflight.sh"
   memory` prints `"over_budget": false` after it): it counts as `ok` and its
   delta is the *Memory* line. Give each `recurring_errors` signature one line
   with count, sample message and likely cause, reading the matching events in
   `work/logs/` ([logging.md](logging.md)) when the cause is not obvious.
2. `stats` sanity: zero reviews in a week with open PRs and heartbeats running
   → investigate (trigger gate stuck? decision bug?) and report.
3. **Diagnose the week's failures** — `failures[]`, one entry per signature
   (`event`, `tool`, `error`, `count`, `first`, `last`) of **every
   `level: error` event**, heartbeats included. **You find the cause**, per
   entry, cheapest first:
   - **Already fixed?** `last` older than a shipped fix → one line, move on.
   - Otherwise read a few matching events (`grep` the `msg` in `work/logs/`)
     and classify: **environment** (missing binary, scope, MCP binding — note
     to [preferences.md](preferences.md) → **Operational lessons**), **agent
     mistake** (bad quoting, wrong path — a lesson), or **definition bug** (a
     documented command, snippet or procedure that cannot work as written).
   - One line per signature: count + what failed + cause + the fix, or `cause
     unclear` with what you ruled out — never a guess.
   - **A definition bug gets an anonymous issue on `$DEFINITION_REPO`**, filed
     per [runbook.md](runbook.md) → **Definition-repo issues**, title
     `[audit] <symptom>`, one per signature (`exists` returns the open one).
     The report line carries the finding with its evidence and the issue link,
     or `issue withheld` with the reason (`disabled`, `blocked`, `error`). The
     fix is the operator's ([self-modification.md](self-modification.md)).
4. Every other script check ([preflight.sh](../scripts/preflight.sh) audit
   mode — connectivity, scopes, deps, state, logs, hygiene, disk space and
   inodes of every volume a run writes to, skills, roster, definition
   currency, benchmark integrity, work repo visibility, memory budget, profile
   currency, open definition issues) is triaged per task 1, never recomputed.
   Operator-only, never worked around:
   - a missing **token scope** — report what it breaks (README → **Token
     scopes**);
   - a `work_repo_visibility` **fail** — **Action needed**: the `work/` backup
     is public; never change the visibility yourself;
   - a `benchmark_fixtures` **fail** — **Action needed**: the scores are
     invalid until the set is retired ([benchmark.md](benchmark.md) →
     **Retiring a fixture set**); never retire it yourself.

   Everything below is **yours**.

### B. Platform & schedules

5. `mcp__platform-outbound__list_schedules`: every schedule ONBOARDING Step 6
   defines for this config (review heartbeat `…-review-active` plus the
   `…-review-quiet` / `…-review-offdays` the cadence keys call for, shepherd,
   benchmark, survey, daily brief under their keys, monitor, this audit)
   exists, is **enabled**, and its cron matches Step 6. Missing or disabled →
   **fail**.
   - **Firing, not merely enabled:** `status.lastRun` within 1.5× the interval
     of **its own cron**, measured from that cron's last firing opportunity
     (walk back from now to the newest minute its day, hour and minute fields
     admit — `*/5 8-21 * * 1-5` read at 07:00 on a Friday → Thursday 21:55),
     and `status.lastResult` = `success`. Else **fail**, naming the schedule,
     its `lastRun` and `lastResult`.
   - A cron that contradicts the cadence keys → **warn** naming both values;
     config wins, the fix is re-registration (ONBOARDING Step 6a).
   - **Gates:** every Step 6 schedule except this audit carries
     `spec.precheck` = `bash "$HOME/scripts/precheck.sh" <its mode>`; missing
     or wrong, or a `precheck` on the audit → **warn** (worklist.md → **The
     schedule gate**).
   - **Models:** report each `spec.model`, `platform default` when none
     ([config.md](config.md) → **Session model**) — never a warn; the
     `session_models` check says what the runs actually ran on.
   - **Titles:** a `spec.sessionTitle` missing or different from its Step 6
     title ([runbook.md](runbook.md) → **Session titles**) → **warn** naming
     the schedule and both values.
   - An unrecognised schedule is the operator's → **info**, never a failure.
     One-time `code-guardian-review-pr-<n>` schedules are dispatched reviews
     ([runbook.md](runbook.md) → **Review run** step 1): not listed; one due
     this week (`spec.at`) in `state` `missed` or `failed` → **warn** naming
     its PR.
6. Slack connectivity — sending the report *is* the test (a send failure is a
   fail plus a fall back to the chat UI).
7. Review guide (a guide skill in `## Review skills`): DAM MCP tools
   (`create_artifact*`) not registered this session → **warn**: no guide can
   publish until the owner's experimental flag is on.

### C. Review pipeline correctness (sample up to 3 reviews posted this week)

Per sampled review, from `reviews/pr-<n>.md`, cross-checked on GitHub:

8. **Posted form** — the trailing full-SHA marker line is present, and the 🟢
   count is within its budget ([finding-form.md](finding-form.md)).
9. **Skill audit completeness** — one section (or a legitimate skip) per
   configured skill its trigger called for.
10. **Re-review scope matches the trigger** — `### Changes since last review`
    present; delta re-reviews keep Findings = 🆕 only with one-line carryovers
    and no repeated `✅ Looks good`; label-triggered ones list all current
    findings ([review-rereview.md](review-rereview.md) → **Re-review output**).
11. **Memory compliance** — MEMORY.md Custom Rules and Ignore List respected;
    nothing from the Ignore List flagged.
12. **Overrides respected** — no finding dismissed in that PR's
    `## PR-local overrides` reappeared in a later review of the same PR.
13. **Feedback operationalized** — every `Feedback Log` entry has a matching
    Custom Rule or Ignore List entry.

### D. Shepherd health (when Slack is enabled)

14. **Nudge integrity** — the same PR nudged twice inside its 20 h cooldown
    (`last_nudge_at` vs SHEPHERD.log, a crash between send and record), or
    `nudge_send` errors recurring across sweeps → **warn** with the PR list.
15. **Effectiveness** — of the PRs nudged this week (`stats.nudges.prs`), how
    many received a human review within 48 h? Report the ratio.
16. **Escalation surface** — list PRs `held` at L4 and PRs waiting > 7 days
    despite nudges: they need a human decision.
17. **Roster integrity** — `escalation_owner`, and `monitor_owner` when set,
    each resolve to a roster row with a valid `slack_id`
    (`^U[A-Z0-9]{6,}$`); count roster members without one.

### E. Review guide (when a guide skill is in `## Review skills`)

18. `stats.guides.skipped` > 0 → name the PRs and the reason of their `guide`
    warn events; the same `skill-errored` reason on several PRs → **warn**.
19. PRs with `guide_label` that got a review this week but no `guide` event
    for it → the label was not followed, **warn**.

### F. Configuration & definition integrity

20. `work/CONFIG.md` has every required key ([config.md](config.md):
    `bot_login`, `review_marker`), each key parses to a sane value, and the
    `## Review skills` rows are well-formed. `Tailored skill:` in
    `work/MEMORY.md` ([tailored-skill.md](tailored-skill.md) → **When**):
    `open` → one line that the offer waits for the operator; `pending` with a
    skill that `gh api "repos/<source>/contents/.agents/skills/<skill>"` now
    finds → one line asking the operator to activate it.
21. The definition checkout's `origin` matches `definition_repo`; note the
    current branch in the report.

### G. Trends & anomalies (compute, then judge)

`stats.reviews` and `stats.findings` count the week from the review ledger
([review-mechanics.md](review-mechanics.md) → **Review ledger**), `reviews.prs`
the PRs behind them; a `review_ledger` warn makes them a floor.

22. **Time-to-first-review** — the median, over this week's first reviews,
    from PR ready (`createdAt`/ready via one `gh pr view` per sampled PR) to
    review posted; > 1 h → investigate (heartbeat gaps? decision bug?).
    `stats.reviews.duration` is the review itself (`locked` → `done`); the
    rest is queue wait, which a cadence change moves.
23. **Review time by phase** — `stats.reviews.phases`: `{n, median_min}` per
    phase (`prepare`, `diff_review`, `skills`, `delta`, `compose`, `post` —
    [review.md](review.md) → **Progress logging**) over the runs whose two
    bounding milestones landed. Report the two largest and name a phase whose
    median grew. `delta` and `compose` past the `skills` median is time spent
    on bookkeeping, not code — record it per [preferences.md](preferences.md)
    and raise it with the operator.
24. **Verdict distribution** — the `verdict_shift` check compares the week's
    APPROVE and REQUEST_CHANGES shares (all and first reviews apart) with the
    four recorded weeks before it ([trends.md](trends.md)): a warn on a shift
    of ≥ 20 pp with |z| ≥ 2 (two-proportion z-test), naming the definition
    versions on both sides. On a warn, read up to 3 reviews on the moved side,
    decide whether the review changed (APPROVE over open findings, fewer
    findings at equal PR size) or the PRs did (size, first/re-review mix), and
    name the likely cause — a definition version, the production model (task
    27), a rule promoted this week — in *Action needed*. Without a warn, still
    flag ~100 % APPROVE in a busy week (rubber-stamping) or ~100 %
    REQUEST_CHANGES (over-strictness) with examples.
    **Overruled approvals** — `stats.overruled` and the `approve_overruled`
    check: PRs approved this week on which a person then requested changes on
    the approved commit, and merged reverts of an approved PR. Per PR, read
    the comment or revert, name the missed defect class, record it per
    [preferences.md](preferences.md), and list it in *Action needed*. A
    request that is not about a defect (scope, product) is reported as such
    and records nothing.
25. **`awaiting_label` backlog** — `stats.awaiting_label`: how many rows wait
    for a trigger and the oldest age. A large or old backlog → suggest
    re-review requests to the team as a process signal.
26. **Idle-tick pulse** — idle/total heartbeats from `stats` measures the
    **gate**, not spend: near zero with no reviews means something re-triggers
    work every run (worklist.md → **The schedule gate**).
    `stats.wakeups` counts the preflight and monitor passes that found work
    (direct session included), split `by_mode` and by the work carried
    (`by_work.<kind>` — `runs` and `items`; a run can carry several kinds).
    Name a kind whose `runs` grew without matching `items`. `unlabelled`
    (runs whose heartbeat names no kind) is stated once as a floor.
27. **Spend ground truth** — one `mcp__platform-outbound__get_metrics` call
    (`days: 7`, `granularity: "summary"`; `session` and `call` rows cap at
    200): the **cost the platform attributed**; `stats.tokens` priced by
    `## Benchmark model prices` is only an estimate. Report `totalCostUsd` and
    the `byModel` split — figures only, never raw rows — then judge:
    - **Price-table drift** — the estimate (task 36's `cost_usd`) over
      `totalCostUsd` outside **0.5×–2.0×** → **warn** with both figures and
      the model rows to re-check, judged once task 36 produced the number. The
      operator corrects the table ([benchmark.md](benchmark.md) → **Model
      prices**).
    - **Unpriced model** — a `byModel` model no table row matches → **warn**
      naming it (the model behind a `≥` cost cell); under 1 % of the week's
      `calls` it is harness-internal → one **info** line.
    - **Production model** — the `byModel` entry with the most `calls`;
      report it. A low-call, low-cost second model is harness-internal
      (session titles), not a model change.
    - `available: false`, or `sessionCount: 0` while `stats.wakeups.runs` > 0
      → one **info** line, `spend not measured on this deployment`, and task
      36's extras omit the key. Never a fail.
    - **Per review** — each figure over `stats.reviews.total`, 2 decimals,
      keeping a `≥`; omitted in a week with no review.
28. **Findings acceptance** — `stats.findings`: this week's re-review
    `✅ Fixed` vs `🔁 Still present` bullets. Report `fixed/(fixed+still)`; a
    persistently low ratio (findings the team does not act on) → flag with
    examples. `by_severity` splits the counts by `findings-json` severity over
    `json_reviews` reviews; a severity far below the others is the class to
    reconsider — record it per [preferences.md](preferences.md). `new` and
    `new_by_severity` count what the week **raised**. `late` counts raised
    findings an earlier round missed (`🔎 Missed earlier`); flag a rising
    share (rounds read too narrow) — except in a file a delta-scope round did
    not read, which is expected.
    **Trace every missed finding** — `late_items`, newest first (≤ 20; with
    `late` above 20 the trace is partial). Per item, read the PR's review
    before `sha` and the code at that review's SHA, and name in one line the
    class that covers it (a [review.md](review.md) criterion or a skill's
    catalogue class) and why that round missed it: a deterministic lead that
    does not match the code (name the pattern that would), a class absent
    from the catalogue, or a class present but not applied. Report causes
    grouped, repeats first. A missing pattern or class in a definition skill
    is a definition finding: file it per [runbook.md](runbook.md) →
    **Definition-repo issues**.
    Two checks judge the week against the four recorded weeks before it, like
    `verdict_shift`: `findings_shift` — new first-review findings per 100
    changed lines (`findings.density`, a PR counted up to 1000 lines), a warn
    when the rate halves or doubles and |z| ≥ 2; `late_shift` — the `late`
    share of `new`, a warn when it rises ≥ 10 pp to at least double the
    baseline and z ≥ 2. On either warn, read two reviews of the week and name
    the cause as task 24 does.
29. **Wasted reviews** — `stats.stalls`: reviews lost because the run died
    before posting. Report `stalled` of `total` locked runs by `by_cause`
    (`pod_restart` and `hard_kill` — the platform's; `terminated` — ended from
    outside mid-pipeline; `unclassified` — a `hard_kill` or `terminated` on a
    harness that measures no tokens, [logging.md](logging.md) → **Harness
    adapters**, with null `wasted_output_tokens`), `wasted_output_tokens`,
    `redone_prs` and `per_day`. Read `stalled` together with `aborted_clean`
    (rising clean aborts with falling stalls is the Stop hook working). Any
    non-zero `stalled` → **warn** naming the causes; a day above 15 % →
    **fail**. `wasted_output_tokens` is a **floor** (a `hard_kill` writes no
    `tokens` event): report it as "≥", never as a cheap week when
    `by_cause.hard_kill` is non-zero.
30. **Reaction feedback** — `stats.reactions` sums 👍/👎 on the bot's latest
    inline and issue comments ([github-access.md](github-access.md) → **Own
    content**). Per `down_urls` entry (≤ 10), read the thread: an explicit
    correction or dismissal → record it per [preferences.md](preferences.md),
    one report line per lesson; a 👎 with no readable reason is reported
    as-is. **`scanned: null` means the scan failed** (with a `reaction_scan`
    warn): say so instead of printing zeros.
31. **Refuted findings** — `stats.suppressed`: findings the week settled
    instead of posting, by what settled them (`overrides`, `context`,
    `decisions` — [review.md](review.md) → **PR context**); a floor, as a
    review without an audit note counts zero. A rising `decisions` share of
    `new` means the review argues with the repository's own design records:
    reconsider and record the class per [preferences.md](preferences.md), and
    name in *Action needed* the document argued with most. Then read every
    `## PR-local overrides` bullet added this week ([review.md](review.md) →
    **A human dismissal settles the finding for this PR**): a reason that is an
    in-tree document is a decision check that did not fire — name document and
    finding in *Action needed*; a reason that generalizes is routed per
    [preferences.md](preferences.md) → **Dispute resolutions from PR
    comments**.
32. **Review style** — `stats.ste` and the `review_style` check
    ([review.md](review.md) → **The sentence bar is 20 words**): over 15 % of
    sentences past 20 words → **warn**. Report share and average; a warn names
    the two longest reviews in *Action needed*.
33. **Project health** — `stats.project` measures the **repository**, from
    local state plus one list call. Report each figure, judge only what moved;
    an unmeasured figure is `null`, reported as unmeasured, never zero:
    - `coverage` — merged PRs of the week vs those this agent reviewed; under
      80 % → name the count, read against `awaiting_label` first.
    - `pr_size` — the median first-reviewed PR in files and lines; report a
      rise, never act on it.
    - `human_latency` — median hours from eligible to the first
      **independent** review, over PRs whose first review landed this week; a
      median over `n` < 3 is reported with `n` as an anecdote.
    - `conflicts` — PRs whose first merge conflict a sweep saw this week, once
      per PR life.
    - `rounds` — median reviews of this agent per PR merged this week, over
      its life; read a rise against `late_shift` (task 28).
    - `abandoned` — PRs closed unmerged this week whose last review of this
      agent did not approve.
    - `hot_areas` — the three directories with the most open findings, from
      the profile's history ([profile.md](profile.md)); orientation only.

    `human_latency` and `conflicts` come from `work/PR-EVENTS.jsonl`, which
    the shepherd sweep fills; without a shepherd schedule, say so once.

### H. Report & wrap-up

34. **Memory consolidation** — before composing the report, run
    [preferences.md](preferences.md) → **Weekly memory consolidation**,
    **mandatory with a `memory_budget` warn or fail**. It ends within the
    bounds, or *Action needed* names what remains; its one-line delta goes
    under *Week in numbers*. Collect meanwhile **what was newly learned** —
    MEMORY.md bullets tagged inside the stats window (Feedback Log, Observed
    Insights) plus the rules it promoted — for *Learned this week*, one
    compressed line each.
35. **Profile notes** — when `work/PROFILE-NOTES.md` exists
    ([profile.md](profile.md) → **Using it**): re-verify each row
    `work/PROFILE.md` marks `stale` against its live source (keep, reword or
    drop), drop `orphan` rows, and add a row when a lesson of the week
    generalizes to one code area (≤ 10 rows, two sentences each). Report the
    delta on the memory line (`notes: kept X · updated Y · dropped Z`).
36. **Trend artifact** — append the week and republish per
    [trends.md](trends.md); the delta line and URL fill the *Trend* line. A
    failed append or publish is a `warn` with the reason; the audit is
    complete regardless.
37. **Review shape** — `stats.review_shape`: the medians of `secs`, `msgs`,
    `peak_ctx`, `repeats`, `failures` and `max_out` this week vs the week
    before, the reviews this week's anomaly records named, and the stored
    baseline per model ([monitor.md](monitor.md) → **Review anomaly alert**).
    A median up by half or more at a similar review count → **warn** naming
    the field (a slow rise the alert's own median absorbs). A model below
    `baseline_min` is reported as `baseline n/10 — cost, time and context not
    judged yet`, never a warn.
38. **Classifier and model availability** — `stats.classifier` (`blocks`,
    `runs`, `by_day`, `by_tool`, `by_reason`, `top` patterns) behind the
    `classifier_blocks` check, and `stats.api_failures` (`failures`, `runs`,
    `by_class`, `outages`) behind `model_availability`. Per `top` pattern: a
    documented step of the agent (a script or subagent a procedure names) is
    an `autoMode.allow` rule the definition lacks — a **definition bug** with
    the proposed rule text, per task 3; anything else is a refusal that
    stands, one line with the reason. A shipped rule while `harness_adapter`
    names `automode-rules` is an install not re-run. Per outage: start,
    length, runs lost, classes; ≥ 2 outages a week, or an
    `authentication_failed` / `cloud_credential_error` /
    `oauth_org_not_allowed` / `account_on_hold` class → **Action needed**
    (operator-only).

One message, this shape — counts and one-liners, no prose; wording per
ASD-STE100 ([review.md](review.md) → **Criteria & review style**):

```
🩺 *<bot_display_name> weekly audit* — <date> · 🟢 N ok · 🟡 N warn · 🔴 N fail

*Week in numbers* (since <stats.since>)
• Reviews: <total> (<first> first / <re_review> re) — ✅<approve> ⚠️<comment> ❌<request_changes>
• Findings acceptance: <fixed>/<fixed+still_present> fixed by the next re-review (omit when both 0)
• Findings acceptance by severity: <sev> <fixed>/<fixed+still>, … (omit when by_severity is empty)
• Refuted before posting: <suppressed.total> — overrides <o> / context <c> / decisions <d> (a floor; omit when total = 0)
• Review style: <ste.sentences_over_20>/<ste.sentences> sentences over 20 words, average <ste.avg_sentence_words> (omit when ste.reviews = 0)
• Median time-to-first-review: <m> min (review itself <duration.median_min> min, n=<duration.n>) · Open PRs: <open_prs> · awaiting_label: <n>
• Review time by phase: <phase> <median_min> min (n=<n>) · <phase> <median_min> min (n=<n>) — the two largest (omit when every phase is unmeasured)
• Project — coverage: <project.coverage.reviewed>/<project.coverage.merged> merged PRs reviewed (<share>%) · median PR <pr_size.median_files> files / <median_lines> lines (n=<n>) · first human review <human_latency.median_hours>h (n=<n>) · merge conflicts: <conflicts> PRs · review rounds <rounds.median> (n=<n>) · abandoned after review: <abandoned> PRs (each figure "not measured" when null)
• Findings sit in: <hot_areas[].dir> <critical>🔴/<warning>🟡, … — top 3 (omit when empty)
• Nudges: <nudges.prs_nudged> PRs nudged (<nudges.prs>) · reviewed ≤48h after nudge: <x>/<y> · held/L4: <list or none>
• Reactions on my comments: 👍<up> · 👎<down> — <lessons recorded or "none"> (omit when scanned = 0; when scanned = null: `not measured this week`)
• Wake-ups: <wakeups.runs> — <kind> <runs>, … per by_work kind with runs > 0 (+<unlabelled> unlabelled — omit when 0; `not measured this week` when wakeups is null)
• Heartbeats: <total> (<idle> idle) · Guides: <stats.guides.published> published (+<stats.guides.skipped> skipped — omit when zero; omit the Guides part when no guide skill is in `## Review skills`; `not measured this week` when guides is null)
• Log: <stats.log_events.errors> errors / <stats.log_events.warns> warns (recurring: <event×N, … or "none">)
• Tokens: <stats.tokens.output> out / <stats.tokens.cache_read> cache-read / <stats.tokens.cache_creation> cache-write across <stats.tokens.runs> runs (omit when runs = 0; `not measured on this harness` when tokens is null) — token counts only; the *Spend* line prices them
• Spend: $<actual> actual (est $<cost_usd>) · per review $<actual/review> (est $<cost_usd/review>) · model: <top byModel id> ×<calls> — or `est $<cost_usd> · per review est $<cost_usd/review> · actual not measured on this deployment` (task 27); `not measured on this harness` when tokens is null and no actual was measured
• Review shape: <week.reviews> reviews — median <secs>s · <msgs> msgs · peak ctx <peak_ctx> · repeats <repeats> · failures <failures> · max out <max_out> (week before: <the changed fields, or "same">) · anomalies <anomalies> · baseline <model> <n>/<baseline_min> (omit the baseline part at or over the minimum; `not measured this week` when week.reviews = 0)
• Wasted reviews: <stalled>/<total> runs redone (<cause×N, …>) — ≥<wasted_output_tokens> out-tok thrown away (omit when null) · clean aborts: <aborted_clean> · worst day: <day> <n> — or `none of <total> runs` when stalled = 0
• Trend: <the append delta line> — <report url or "local only"> (or `not appended: <reason>`)
• Memory: archived <a> · distilled <w> · merged <x> · promoted <y> · dropped <z> (or "no consolidation needed") · notes: kept <k> · updated <u> · dropped <d> (omit without a notes file)

*Learned this week*
• <tag> <rule/insight in one line>   ← per task-34 entry, ≤5 lines (then "… +N more in MEMORY.md"); exactly `• nothing new` when the week added nothing

*Checks*
🔴 <id> — <detail>          ← every fail (script + tasks above)
🟡 <id> — <detail>          ← every warn
🟢 all other checks passed (<count>)

*Action needed*: <one line per item needing a human, or "none">
```

- **Always sent, green or not**, and always echoed to the chat UI. Under
  `slack_notifications: enabled` it goes to Slack every week via
  `mcp__platform-outbound__send_channel_message` (`channel: "slack"`, omit
  `chatId`); a failure sends the full report to the chat UI and logs.
- Append one line to `work/AUDIT.log`
  (`<ISO> ok=<n> warn=<n> red=<n> sent=<slack|chat>`), then back up `work/`
  ([persistence.md](persistence.md)).
