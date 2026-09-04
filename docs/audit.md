# Weekly audit — health check & report

Read this file on every **audit run** (`preflight.sh audit` returned
`nothing_to_do: false`). The script gathered the deterministic facts (7-day
`stats` + `checks`); you walk the task list — verify, add the judgment checks,
compute the derived metrics, send the report.

**The audit fixes nothing.** Its only GitHub write is a tracking issue for a
definition bug found in task 3, and its one local write beyond `AUDIT.log` is
the memory consolidation of task 29. Routine findings (pending prunes, stale
locks) heal on the next heartbeat; everything else goes to the operator. A
skipped task is an incomplete audit — a task that is impossible this week
(missing data, API error) is reported as `warn` with the reason, never dropped.

## Task list

### A. Script findings (from the worklist — triage, never recompute)

1. Walk every `checks[]` entry. Every `fail` and `warn` appears in the report;
   never summarize a `fail` away. Give each `recurring_errors` signature one
   line with count, sample message and likely cause — read the matching events
   in `work/logs/` ([logging.md](logging.md)) when the cause is not obvious.
2. `stats` sanity: zero reviews in a week with open PRs and heartbeats running
   → investigate (trigger gate stuck? decision bug?) and report.
3. **Diagnose the week's failures** — `failures[]`, one entry per signature
   (`event`, `tool`, `error`, `count`, `first`, `last`), grouped from **every
   `level: error` event** past runs wrote, heartbeats included. The script
   groups; **you find the cause**. Per entry, cheapest first:
   - **Already fixed?** `last` older than a shipped fix → say so in one line
     and move on. Never re-diagnose a dead signature.
   - Otherwise read a few matching events (`grep` the `msg` in `work/logs/`),
     then classify: **environment** (missing binary, scope, MCP binding — the
     durable note goes to [preferences.md](preferences.md) → **Operational
     lessons**), **agent mistake** (bad quoting, wrong path — a lesson, not a
     bug), or **definition bug** (a documented command, snippet or procedure
     that cannot work as written).
   - Report one line per signature: count + what failed + cause + the fix.
     Unresolved after a genuine attempt → `cause unclear` with what you ruled
     out. Never pad the report with a guess.
   - **A definition bug gets an issue on `$DEFINITION_REPO`** — title
     `[audit] <short symptom>`, body: signature, count, window, the evidence,
     the proposed fix, and that it came from the weekly audit. **Search open
     issues first; one issue per signature, never a duplicate.** Best-effort: a
     failure is logged and the report still carries the finding. This issue is
     the audit's *only* definition-repo write; the fix itself takes the
     operator ([self-modification.md](self-modification.md)).
4. Everything else the script checks is already in `checks[]` — connectivity,
   scopes, CLI deps, state consistency, logs, hygiene, skills, roster,
   definition currency, benchmark fixture and results integrity, the memory
   budget, the profile's currency, the definition repo's open-issue backlog
   (see [preflight.sh](../scripts/preflight.sh) audit mode). Triage per task 1,
   do not recompute. Two special cases:
   - A missing **token scope** is **operator-only**: report what it breaks
     (README → **Token scopes**), never work around it.
   - A `benchmark_fixtures` **fail** means the scores are invalid until the set
     is retired and replaced. Report it as **Action needed**
     ([benchmark.md](benchmark.md) → **Retiring a fixture set**); never retire
     it yourself.

   Everything below is **yours**.

### B. Platform & schedules

5. `mcp__platform-outbound__list_schedules`: the review heartbeat (one to three
   schedules — `…-review-active` plus the `…-review-quiet` /
   `…-review-offdays` ones the cadence keys call for), the shepherd sweep
   (under `slack_notifications: enabled`), the monthly benchmark (under
   `benchmark: enabled`) and this audit job all exist and are **enabled**, with
   crons matching ONBOARDING Step 6. Missing or disabled → **fail**.
   - **Each must also be firing, not merely enabled.** Per entry,
     `status.lastRun` within 1.5× the interval of **its own cron**, measured
     from that cron's last firing opportunity rather than from now, and
     `status.lastResult` = `success`. Reconstruct that opportunity by walking
     backwards from now to the newest minute the cron's day, hour and minute
     fields all admit — for `*/5 8-21 * * 1-5` read at 07:00 on a Friday,
     Thursday 21:55 — and measure the age from there. This is what keeps a
     window-limited schedule honest: a Friday-morning audit sees the active
     heartbeat's `lastRun` from the previous evening, which is correct for a
     `Mon-Fri 08-21` cron and would read as dead against wall clock.
   - Enabled but not running, or a failing last result → **fail**, naming the
     offender, its `lastRun` and its `lastResult`.
   - A registered cron that contradicts the cadence keys → **warn** naming both
     values. Config is the source of truth; the fix is to re-register the
     schedule (ONBOARDING Step 6a).
   - Judge **only the schedules ONBOARDING Step 6 defines**. An operator's own
     temporary monitor is theirs to watch — report an unrecognised schedule as
     **info**, never a failure.
6. Slack connectivity — no separate probe: sending the report *is* the test (a
   send failure is a fail plus a fall back to the chat UI).
7. Artifact feature (when `artifact_skill` is configured): report the
   configured `artifact_targets` and, when the script emitted an
   `artifact_targets` check, the surfaces it dropped for this host. When `dam`
   is listed, are the DAM MCP tools (`create_artifact*`) registered this
   session? Absent → **info**, not a failure, but report the flag state so the
   operator knows which surfaces artifacts get.

### C. Review pipeline correctness (sample up to 3 reviews posted this week)

Per sampled review, from `reviews/pr-<n>.md`, cross-checked on GitHub:

8. **Posted form** — the trailing full-SHA marker line is present, and the 🟢
   count is within its budget ([finding-form.md](finding-form.md)).
9. **Skill audit completeness** — one section per configured skill that should
   have run per its trigger, or a legitimate skip; no silently missing
   sections.
10. **Re-review scope matches the trigger** — `### Changes since last review`
    present; delta re-reviews keep Findings = 🆕 only with one-line carryovers
    and no repeated `✅ Looks good`; label-triggered ones list all current
    findings ([review.md](review.md) → **Re-review output**).
11. **Memory compliance** — MEMORY.md Custom Rules and Ignore List respected;
    nothing from the Ignore List flagged.
12. **Overrides respected** — no finding dismissed in that PR's
    `## PR-local overrides` reappeared in a later review of the same PR.
13. **Feedback operationalized** — every `Feedback Log` entry has a matching
    Custom Rule or Ignore List entry. Feedback recorded but never turned into a
    rule is a silent regression.

### D. Shepherd health (when Slack is enabled)

14. **Nudge integrity** — send-then-record means a crash between send and
    record repeats the nudge next sweep. Look for the same PR nudged twice
    inside its 20 h cooldown (`last_nudge_at` vs SHEPHERD.log), and for
    `nudge_send` error signatures recurring across sweeps. Either → **warn**
    with the PR list.
15. **Effectiveness** — of the PRs nudged this week (`stats.nudges.prs`), how
    many received a human review within 48 h? Report the ratio.
16. **Escalation surface** — list PRs currently `held` at L4 and PRs waiting
    > 7 days despite nudges. These need a human decision, not another nudge.
17. **Roster integrity** — `escalation_owner` resolves to a roster row with a
    valid `slack_id` (`^U[A-Z0-9]{6,}$`); count roster members without one
    (they can never be mentioned).

### E. Artifact pipeline (when `artifact_skill` is configured)

18. PRs with `$BOT_LOGIN` assigned right now that are **not** in this run's
    `artifacts_due`-equivalent state (assignment older than a few heartbeats
    with neither markers nor a fresh artifact) → pipeline stuck, **warn**.
19. Repeated `retry_unassign` lines across the week for the same PR → the
    unassign keeps failing (permissions?), **warn**.

### F. Configuration & definition integrity

20. `work/CONFIG.md` has every key [config.md](config.md) lists as required
    (`bot_login`, `review_marker`), each present key parses to a sane value,
    and the `## Review skills` rows are well-formed.
21. The definition checkout's `origin` matches `definition_repo`; note the
    current branch in the report.

### G. Trends & anomalies (compute, then judge)

22. **Time-to-first-review** — for this week's first reviews, the median time
    from PR ready to review posted (PR `createdAt`/ready timestamp via one
    `gh pr view` per sampled PR). Report the median; > 1 h → investigate
    (heartbeat gaps? decision bug?). `stats.reviews.duration` is the review
    itself (`locked` → `done`); the rest of the median is queue wait, which is
    what a cadence change moves.
23. **Verdict distribution** — ~100 % APPROVE across a busy week is possible
    rubber-stamping; ~100 % REQUEST_CHANGES is possible over-strictness. Either
    extreme → flag it with examples.
24. **`awaiting_label` backlog** — count and age of rows waiting for a trigger.
    A large or old backlog means the team is not requesting re-reviews; suggest
    it in the report as a process signal.
25. **Cost pulse** — the idle-heartbeat ratio from `stats` (idle/total). A
    falling ratio means rising spend; a ratio near zero with no reviews means
    something re-triggers work every run.
26. **Findings acceptance** — `stats.findings` counts this week's re-review
    `✅ Fixed` vs `🔁 Still present` bullets. Report `fixed/(fixed+still)`; a
    persistently low ratio means findings the team does not act on — flag it
    with examples. `by_severity` splits the same counts by the severity
    `findings-json` carries, over `json_reviews` reviews. A severity whose
    ratio is far below the others is the finding class to reconsider — record
    it per [preferences.md](preferences.md).
27. **Wasted reviews** — `stats.stalls`: reviews thrown away because the run
    died before posting. Report `stalled` of `total` locked runs split by
    `by_cause` (`pod_restart` / `hard_kill` / `terminated`),
    `wasted_output_tokens`, `redone_prs` and `per_day`. The split matters: the
    three causes have different owners — `pod_restart` and `hard_kill` are
    platform, `terminated` is a session ended from outside mid-pipeline. Rising
    `aborted_clean` while `stalled` falls is the Stop hook working, so read the
    two together, never `stalled` alone. Any non-zero `stalled` is a **warn**
    with the causes named; a day above 15 % is a **fail**. Runs still in flight
    are excluded by the script. `wasted_output_tokens` is a **floor**: it sums
    the per-run `tokens` events, which a `hard_kill` never got to write —
    report it as "≥", and never read a low figure as a cheap week when
    `by_cause.hard_kill` is non-zero.
28. **Reaction feedback** — `stats.reactions` sums 👍/👎 on the bot's latest
    inline and issue comments. For each `down_urls` entry (≤ 10): read the
    thread; an explicit correction or dismissal → record it per
    [preferences.md](preferences.md) and give the report one line per recorded
    lesson. A 👎 with no readable reason is reported as-is, never guessed at.
    **`scanned: null` means the scan failed, not that there were no
    reactions** — it arrives with a `reaction_scan` warn, and the report says
    so instead of printing zeros.

### H. Report & wrap-up

29. **Memory consolidation** — before composing the report, run
    [preferences.md](preferences.md) → **Weekly memory consolidation**.
    **Mandatory when `checks[]` carries a `memory_budget` warn or fail.** It
    ends within the bounds, or the report's *Action needed* names what remains.
    Put its one-line delta under *Week in numbers*. While consolidating,
    collect **what was newly learned** — MEMORY.md bullets whose tag date falls
    inside the stats window (Feedback Log, Observed Insights) plus the rules
    this consolidation promoted. They fill *Learned this week*, one compressed
    line each.
30. **Profile notes** — when `work/PROFILE-NOTES.md` exists
    ([profile.md](profile.md) → **Using it**): re-verify each row
    `work/PROFILE.md` marks `stale` against its live source (keep, reword or
    drop), drop `orphan` rows, and add a row when a lesson of the week
    generalizes to one code area — at most 10 rows, two sentences each. Report
    the delta on the memory line (`notes: kept X · updated Y · dropped Z`).

One message, this shape — counts and one-liners, no prose; wording per
ASD-STE100 ([review.md](review.md) → **Criteria & review style**):

```
🩺 *<bot_display_name> weekly audit* — <date> · 🟢 N ok · 🟡 N warn · 🔴 N fail

*Week in numbers* (since <stats.since>)
• Reviews: <total> (<first> first / <re_review> re) — ✅<approve> ⚠️<comment> ❌<request_changes>
• Findings acceptance: <fixed>/<fixed+still_present> fixed by the next re-review (omit when both 0)
• Findings acceptance by severity: <sev> <fixed>/<fixed+still>, … (omit when by_severity is empty)
• Median time-to-first-review: <m> min (review itself <duration.median_min> min, n=<duration.n>) · Open PRs: <open_prs> · awaiting_label: <n>
• Nudges: <nudges.prs_nudged> PRs nudged (<nudges.prs>) · reviewed ≤48h after nudge: <x>/<y> · held/L4: <list or none>
• Reactions on my comments: 👍<up> · 👎<down> — <lessons recorded or "none"> (omit when scanned = 0; when scanned = null: `not measured this week`)
• Heartbeats: <total> (<idle> idle) · Artifacts: <generated>
• Log: <stats.log_events.errors> errors / <stats.log_events.warns> warns (recurring: <event×N, … or "none">)
• Tokens: <stats.tokens.output> out / <stats.tokens.cache_read> cache-read / <stats.tokens.cache_creation> cache-write across <stats.tokens.runs> runs (omit when runs = 0) — token counts only; the priced view is the benchmark report's ([benchmark.md](benchmark.md) → **Model prices**)
• Wasted reviews: <stalled>/<total> runs redone (<cause×N, …>) — ≥<wasted_output_tokens> out-tok thrown away · clean aborts: <aborted_clean> · worst day: <day> <n> — or `none of <total> runs` when stalled = 0
• Memory: distilled <w> · merged <x> · promoted <y> · dropped <z> (or "no consolidation needed") · notes: kept <k> · updated <u> · dropped <d> (omit without a notes file)

*Learned this week*
• <tag> <rule/insight in one line>   ← per task-29 entry, ≤5 lines (then "… +N more in MEMORY.md"); exactly `• nothing new` when the week added nothing

*Checks*
🔴 <id> — <detail>          ← every fail (script + tasks above)
🟡 <id> — <detail>          ← every warn
🟢 all other checks passed (<count>)

*Action needed*: <one line per item needing a human, or "none">
```

- **Always sent, green or not.** Under `slack_notifications: enabled` the
  report goes to Slack **every week**, an all-🟢 zero-stall one included: it is
  the standing signal that the agent is alive and auditing itself, so its
  absence is itself the alert. Send via
  `mcp__platform-outbound__send_channel_message` (`channel: "slack"`, omit
  `chatId`); a failure sends the full report to the chat UI and logs. Slack
  disabled → chat UI only. Always echo to the chat UI.
- Append one line to `work/AUDIT.log`
  (`<ISO> ok=<n> warn=<n> red=<n> sent=<slack|chat>` — never the substrings
  "fail" or "error", which next week's log grep would flag), then back up
  `work/` ([persistence.md](persistence.md)). No state repairs beyond tasks
  29–30, and no GitHub writes except the task-3 tracking issue.
