# Weekly audit — health check & report

Read this file on every **audit run** (`preflight.sh audit` returned
`nothing_to_do: false`). Division of labor: the script gathered the
deterministic facts (7-day `stats` + `checks`); you walk the task list
below — verify, add the judgment checks, compute the derived metrics, and
send the report. The audit **fixes nothing**: its only GitHub write is a
tracking issue for a definition bug found in task 3, and its one local write
beyond `AUDIT.log` is the memory consolidation in the wrap-up. Routine findings (pending prunes, stale locks)
heal on the next heartbeat, everything else goes to the operator. A skipped task = an incomplete audit —
if one is impossible this week (missing data, API error), report it as
`warn` with the reason instead of dropping it silently.

## Task list

### A. Script findings (from the worklist — don't recompute, do triage)

1. Walk every `checks[]` entry; every `fail` and `warn` must appear in the
   report — never summarize a `fail` away. For each `recurring_errors`
   signature, give the report one line with count + sample message + likely
   cause — read the matching events in `work/logs/` ([logging.md](logging.md))
   when the cause isn't obvious.
2. `stats` sanity: zero reviews in a week with open PRs and heartbeats
   running → investigate (trigger gate stuck? decision bug?) and report.
3. **Diagnose the week's failures** — the worklist's `failures[]`, one entry per
   signature (`event`, `tool`, `error`, `count`, `first`, `last`) grouped from
   **every `level: error` event** past runs wrote, heartbeats included: failed
   tool calls (`tool_failure`, with the tool named), plus skill installs, sends,
   API decisions and anything else that logged an error
   ([logging.md](logging.md)). This is the audit's one *investigative* task: the
   script groups, **you find the cause**. Per entry, cheapest-first:
   - **Already fixed?** `last` older than a fix that has since shipped → say so
     in one line and move on. Never re-diagnose a dead signature.
   - Otherwise read a few matching events for context (`grep` the `msg` in
     `work/logs/`), then classify: **environment** (missing binary, scope, MCP
     binding — [preferences.md](preferences.md) → Operational lessons is where
     the durable note goes), **agent mistake** (bad quoting, wrong path — a
     lesson, not a bug), or **definition bug** (a documented command, snippet,
     or procedure that cannot work as written).
   - Report one line per signature: count + what failed + cause + the fix.
     Unresolved after a genuine attempt → say `cause unclear` with what you
     ruled out; never pad the report with a guess.
   - **A definition bug gets an issue on `$DEFINITION_REPO`** — title
     `[audit] <short symptom>`, body: signature + count + window, the evidence,
     the proposed fix, and that it came from the weekly audit. **Search open
     issues first; one issue per signature, never a duplicate.** Best-effort:
     a failure is logged and the report still carries the finding. The issue is
     the audit's *only* definition-repo write — it never edits, branches, or
     PRs; the fix itself takes the operator in the direct session
     ([self-modification.md](self-modification.md)).
4. Everything else the script checks (connectivity, scopes, CLI deps, state
   consistency, logs, hygiene, skills, roster, definition currency, the
   definition repo's open-issue backlog — see
   [preflight.sh](../scripts/preflight.sh) audit mode) is already in
   `checks[]` — triage per task 1, don't recompute. A missing **token scope**
   is **operator-only**: report what it breaks (README → **Token scopes**),
   never work around it. Everything below is **yours**.

### B. Platform & schedules

5. `mcp__platform-outbound__list_schedules`: the review heartbeat, the
   shepherd sweep (when `slack_notifications: enabled`), and this audit job all
   exist and are **enabled**, crons matching ONBOARDING Step 6.
   Missing/disabled → **fail** (a dead schedule is invisible to every other
   check — the heartbeat-gap check catches the past, this catches the future).
   **Each must also be firing, not merely enabled:** per entry, `status.lastRun`
   within 1.5× its own interval and `status.lastResult` = `success`. Enabled but
   not running, or a failing last result, is a **fail** — this is what notices a
   job that stopped silently. Name the offender, its `lastRun` and `lastResult`.
   Judge **only the schedules ONBOARDING Step 6 defines**; an operator may add
   temporary monitors of their own, and those are theirs to watch — report an
   unrecognised schedule as **info**, never a failure.
6. Slack connectivity — no separate probe: sending the report *is* the test
   (send failure → fail + fall back to chat UI).
7. Artifact feature (when `artifact_skill` configured): report the configured
   `artifact_targets` (default `gist`) and, when the script emitted an
   `artifact_targets` check, the surfaces it dropped for this host
   ([artifact.md](artifact.md)). When it lists `dam`, are the DAM MCP
   tools (`create_artifact*`) registered this session? Absent → **info**, not
   a failure (the DAM surface is best-effort by design) — but report the flag
   state so the operator knows which surfaces artifacts currently get.

### C. Review pipeline correctness (sample up to 3 reviews posted this week)

For each sampled review (from `reviews/pr-<n>.md`, cross-checked on GitHub):

8. The posted review carries the trailing full-SHA **marker line**.
9. **Skill audit completeness**: one section per configured skill that
   should have run per its trigger (or a legitimate skip); no silently
   missing skill sections.
10. **Re-review scope matches the trigger**: `### Changes since last review`
   present; delta re-reviews (request/on-demand) keep Findings = 🆕 only with
   one-line carryovers and no repeated `✅ Looks good`; label-triggered ones
   list all current findings (review.md → **Re-review output**).
11. **Memory compliance**: `work/MEMORY.md` Custom Rules and Ignore List
    respected; nothing from the Ignore List flagged.
12. **Overrides respected**: no finding dismissed in that PR's
    `## PR-local overrides` reappeared in a later review of the same PR.
13. **Feedback operationalized**: every `Feedback Log` entry in MEMORY.md
    has a matching Custom Rule / Ignore List entry (feedback that was
    recorded but never turned into a rule is a silent regression).

### D. Shepherd health (when Slack is enabled)

14. **Nudge integrity**: send-then-record means a crash between send and
    record repeats the nudge next sweep — look for the same PR nudged twice
    inside its 20h cooldown (`last_nudge_at` vs SHEPHERD.log), and for
    `nudge_send` error signatures recurring across sweeps (a send that
    keeps failing keeps retrying). Either → **warn** with PR list.
15. **Effectiveness**: of the PRs nudged this week, how many received a
    human review within 48 h? Report the ratio — a persistently ignored
    shepherd is a process problem the operator should see.
16. **Escalation surface**: list PRs currently `held` at L4 and PRs waiting
    > 7 days despite nudges — these need a human decision, not another nudge.
17. **Roster integrity**: `escalation_owner` resolves to a roster row with a
    valid `slack_id` (`^U[A-Z0-9]{6,}$`); count roster members without a
    Slack id (they can never be mentioned).

### E. Artifact pipeline (when `artifact_skill` configured)

18. PRs with `$BOT_LOGIN` assigned right now that are **not** in this run's
    `artifacts_due`-equivalent state (assignment older than a few heartbeats
    with neither markers nor a fresh artifact) → pipeline stuck, **warn**.
19. Repeated `retry_unassign` log lines across the week for the same PR →
    the unassign keeps failing (permissions?), **warn**.

### F. Configuration & definition integrity

20. `work/CONFIG.md` has every key CLAUDE.md → **Runtime configuration**
    lists as required (`bot_login`, `review_marker`), and each present key
    parses to a sane value; the `## Review skills` table rows are well-formed.
21. The definition checkout's `origin` matches `definition_repo` (a platform
    reset to the wrong repo/branch would silently change behavior); note the
    current branch in the report.

### G. Trends & anomalies (derived metrics — compute, then judge)

22. **Time-to-first-review**: for this week's first reviews, median time
    from PR ready to review posted (PR `createdAt`/ready timestamp via one
    `gh pr view` per sampled PR). Report the median; > 1 h → investigate
    (heartbeat gaps? decision bug?).
23. **Verdict distribution**: ~100 % APPROVE across a busy week → possible
    rubber-stamping; ~100 % REQUEST_CHANGES → possible over-strictness.
    Either extreme → flag for the operator with examples.
24. **`awaiting_label` backlog**: count + age of rows waiting for a
    re-review trigger — a large/old backlog means the team isn't requesting
    re-reviews (label / review request); suggest it in the report (process
    signal, not a defect).
25. **Cost pulse**: idle-heartbeat ratio from `stats` (idle/total). A falling
    ratio means rising spend; a ratio near zero with no reviews means
    something re-triggers work every run — investigate.
26. **Findings acceptance**: `stats.findings` counts this week's re-review
    `✅ Fixed` vs `🔁 Still present` bullets. Report `fixed/(fixed+still)`;
    a persistently low ratio means findings the team doesn't act on — flag
    it with examples (a process signal for the operator, not a defect).
27. **Wasted reviews**: `stats.stalls` — reviews thrown away because the run
    died before posting, so a later heartbeat had to redo them. `stalled` of
    `total` locked runs, split by `by_cause` (`pod_restart` / `hard_kill` /
    `terminated`), `wasted_output_tokens`, `redone_prs`, and `per_day` for the
    trend. Report the split, not just the count — the three causes have
    different owners: `pod_restart` and `hard_kill` are platform, `terminated`
    is a session ended from outside mid-pipeline. Rising `aborted_clean` while
    `stalled` falls is the Stop hook working (an explicit abort frees the lock
    immediately instead of waiting out its TTL) — read the two together, never
    `stalled` alone. Any non-zero `stalled` is a **warn** with the causes named;
    a day above 15 % is a **fail**. Runs still in flight (last event newer than
    the 30-min lock TTL) are excluded by the script, so a live review is never
    counted as a stall. `wasted_output_tokens` is a **floor, not the true cost**:
    it sums the per-run `tokens` events, which a `hard_kill` never got to write —
    report it as "≥", and never read a low figure as a cheap week when
    `by_cause.hard_kill` is non-zero.

28. **Reaction feedback**: `stats.reactions` sums 👍/👎 on the bot's latest
    inline and issue comments (the two surfaces whose REST lists carry
    reactions). For each `down_urls` entry (≤ 10): read the thread; an
    explicit correction or dismissal → record it per
    [preferences.md](preferences.md) (same routes as mention feedback) and
    give the report one line per recorded lesson. A 👎 with no readable
    reason is reported as-is, never guessed at.

### H. Report & wrap-up

29. **Memory consolidation** — before composing the report, run
    [preferences.md → Weekly memory consolidation](preferences.md)
    (merge / promote / compress-or-drop, bounds, `[from user]` protection)
    and put its one-line delta into the report under *Week in numbers*.
    While consolidating, collect **what was newly learned**: MEMORY.md
    bullets whose tag date falls inside the stats window (Feedback Log,
    Observed Insights) plus the rules this consolidation promoted — they
    fill the report's *Learned this week* block, one compressed line each.

One message, this shape (tight — counts and one-liners, no prose; wording per
ASD-STE100 — [review.md](review.md) → **Criteria & review style**):

```
🩺 *<bot_display_name> weekly audit* — <date> · 🟢 N ok · 🟡 N warn · 🔴 N fail

*Week in numbers* (since <stats.since>)
• Reviews: <total> (<first> first / <re_review> re) — ✅<approve> ⚠️<comment> ❌<request_changes>
• Findings acceptance: <fixed>/<fixed+still_present> fixed by the next re-review (omit when both 0)
• Median time-to-first-review: <m> min · Open PRs: <open_prs> · awaiting_label: <n>
• Nudges: <claimed> claimed · reviewed ≤48h after nudge: <x>/<y> · held/L4: <list or none>
• Reactions on my comments: 👍<up> · 👎<down> — <lessons recorded or "none"> (omit when scanned = 0)
• Heartbeats: <total> (<idle> idle) · Artifacts: <generated>
• Log: <stats.log_events.errors> errors / <stats.log_events.warns> warns (recurring: <event×N, … or "none">)
• Tokens: <stats.tokens.output> out / <stats.tokens.cache_read> cache-read across <stats.tokens.runs> runs (omit when runs = 0)
• Wasted reviews: <stalled>/<total> runs redone (<cause×N, …>) — ≥<wasted_output_tokens> out-tok thrown away · clean aborts: <aborted_clean> · worst day: <day> <n> — or `none of <total> runs` when stalled = 0 (state the zero; the report always sends, so an absent line reads as "not measured")
• Memory: merged <x> · promoted <y> · dropped <z> (or "no consolidation needed")

*Learned this week*
• <tag> <rule/insight in one line>   ← per task-29 entry, ≤5 lines (then "… +N more in MEMORY.md"); exactly `• nothing new` when the week added nothing

*Checks*
🔴 <id> — <detail>          ← every fail (script + tasks above)
🟡 <id> — <detail>          ← every warn
🟢 all other checks passed (<count>)

*Action needed*: <one line per item needing a human, or "none">
```

- **Always sent, green or not.** Under `slack_notifications: enabled` the weekly
  report goes to Slack **every week**, including an all-🟢 zero-stall one — it is
  the standing signal that the agent is alive and auditing itself, so its absence
  is itself the alert. Never suppress it for being uneventful.
  → `mcp__platform-outbound__send_channel_message` (`channel: "slack"`, omit
  `chatId`); failure → full report to the chat UI + log. **Slack disabled** →
  chat UI only. Always echo to the chat UI.
- Append one line to `work/AUDIT.log`
  (`<ISO> ok=<n> warn=<n> red=<n> sent=<slack|chat>` — never the substrings
  "fail"/"error", the log-grep would flag them next week), then back up
  `work/` per CLAUDE.md. No state repairs beyond the memory consolidation
  (task 29) and no GitHub writes except a task-3 tracking issue — findings are
  reported, not fixed.
