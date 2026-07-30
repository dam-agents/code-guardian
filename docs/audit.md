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
4. The script's checks cover: GitHub auth + rate limit, **token scopes**
   (`token_scopes` — the scopes README → **Token scopes** marks required;
   widening a token is **operator-only**, so report a missing scope with what it
   breaks and never work around it) and **CLI dependencies** (`cli_deps`), work-repo push
   backlog, heartbeat gaps, weekly log errors, structured-events triage
   (`events_errors`, `recurring_errors`) + harness adapter presence +
   14-day log retention cleanup ([logging.md](logging.md)), stale locks,
   duplicate rows,
   prune backlog, orphan history files, marker cross-verification
   (state drift), orphaned gists, `/tmp` leftovers, disk, skill freshness,
   roster presence, definition cleanliness, and definition version currency
   (`definition_version` — outdated/half-adopted definition → warn).
   Anything below is **yours**.

### B. Platform & schedules

5. `mcp__platform-outbound__list_schedules`: the review heartbeat, the
   shepherd sweep (when `slack_notifications: enabled`), and this audit job
   all exist and are **enabled**, crons matching ONBOARDING Step 6.
   Missing/disabled → **fail** (a dead schedule is invisible to every other
   check — the heartbeat-gap check catches the past, this catches the future).
6. Slack connectivity — no separate probe: sending the report *is* the test
   (send failure → fail + fall back to chat UI).
7. Artifact feature (when `artifact_skill` configured): report the configured
   `artifact_targets` (default `gist`). When it lists `dam`, are the DAM MCP
   tools (`create_artifact*`) registered this session? Absent → **info**, not
   a failure (the DAM surface is best-effort by design) — but report the flag
   state so the operator knows which surfaces artifacts currently get.

### C. Review pipeline correctness (sample up to 3 reviews posted this week)

For each sampled review (from `reviews/pr-<n>.md`, cross-checked on GitHub):

8. The posted review carries the trailing full-SHA **marker line**.
9. **Skill audit completeness**: one section per configured skill that
   should have run per its trigger (or a legitimate skip); no silently
   missing skill sections.
10. **Re-reviews are delta-only**: `### Changes since last review` present,
   Findings = 🆕 only, one-line carryovers, no repeated `✅ Looks good`.
11. **Memory compliance**: `work/MEMORY.md` Custom Rules and Ignore List
    respected; nothing from the Ignore List flagged.
12. **Overrides respected**: no finding dismissed in that PR's
    `## PR-local overrides` reappeared in a later review of the same PR.
13. **Feedback operationalized**: every `Feedback Log` entry in MEMORY.md
    has a matching Custom Rule / Ignore List entry (feedback that was
    recorded but never turned into a rule is a silent regression).

### D. Shepherd health (when Slack is enabled)

14. **Lost nudges**: ledger rows with `last_nudge_at` in the audit week vs
    send-failure lines in the weekly logs — write-before-send means a failed
    send is claimed but never delivered. Any found → **warn** with PR list
    (the operator may nudge manually).
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

### H. Report & wrap-up

26. **Memory consolidation** — before composing the report, run
    [preferences.md → Weekly memory consolidation](preferences.md)
    (merge / promote / compress-or-drop, bounds, `[from user]` protection)
    and put its one-line delta into the report under *Week in numbers*.

One message, this shape (tight — counts and one-liners, no prose):

```
🩺 *<bot_display_name> weekly audit* — <date> · 🟢 N ok · 🟡 N warn · 🔴 N fail

*Week in numbers* (since <stats.since>)
• Reviews: <total> (<first> first / <re_review> re) — ✅<approve> ⚠️<comment> ❌<request_changes>
• Median time-to-first-review: <m> min · Open PRs: <open_prs> · awaiting_label: <n>
• Nudges: <claimed> claimed / <lost> lost · reviewed ≤48h after nudge: <x>/<y> · held/L4: <list or none>
• Heartbeats: <total> (<idle> idle) · Artifacts: <generated>
• Log: <stats.log_events.errors> errors / <stats.log_events.warns> warns (recurring: <event×N, … or "none">)
• Tokens: <stats.tokens.output> out / <stats.tokens.cache_read> cache-read across <stats.tokens.runs> runs (omit when runs = 0)
• Memory: merged <x> · promoted <y> · dropped <z> (or "no consolidation needed")

*Checks*
🔴 <id> — <detail>          ← every fail (script + tasks above)
🟡 <id> — <detail>          ← every warn
🟢 all other checks passed (<count>)

*Action needed*: <one line per item needing a human, or "none">
```

- **Slack enabled** → `mcp__platform-outbound__send_channel_message`
  (`channel: "slack"`, omit `chatId`); failure → full report to the chat UI
  + log. **Slack disabled** → chat UI only. Always echo to the chat UI.
- Append one line to `work/AUDIT.log`
  (`<ISO> ok=<n> warn=<n> red=<n> sent=<slack|chat>` — never the substrings
  "fail"/"error", the log-grep would flag them next week), then commit & push
  `work/` per CLAUDE.md. No state repairs beyond the memory consolidation
  (task 26) and no GitHub writes except a task-3 tracking issue — findings are
  reported, not fixed.
