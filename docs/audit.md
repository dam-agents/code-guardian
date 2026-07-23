# Weekly audit — health check & report

Read this file on every **audit run** (`preflight.sh audit` returned
`nothing_to_do: false`). The script already computed the 7-day `stats` and
the deterministic `checks` (connectivity, heartbeat cadence, log errors,
state consistency incl. GitHub marker cross-verification, orphaned gists,
disk, skill freshness, roster, definition cleanliness). Your job: the
judgment checks, the report, the send. The audit is **read-only + report** —
it fixes nothing itself; routine findings (pending prunes, stale locks) heal
on the next heartbeat, everything else goes to the operator.

## Agent-side checks (add each as an ok/warn/fail line)

1. **Schedules** — `mcp__platform-outbound__list_schedules`: the review
   heartbeat, the shepherd sweep (only when `slack_notifications: enabled`),
   and this audit job all exist and are enabled, with crons matching
   ONBOARDING Step 6. Missing/disabled → **fail** (a dead schedule is
   invisible to every other check).
2. **Memory compliance** — read `work/MEMORY.md`; sample up to 3 reviews
   posted this week (from `reviews/pr-<n>.md`) and verify the Custom Rules
   and Ignore List were respected (e.g. re-reviews delta-only, no repeated
   `✅ Looks good`, ignored patterns not flagged). Also verify no finding
   dismissed in a PR's `## PR-local overrides` reappeared in a later review
   of that PR. Violations → **warn** with the concrete example.
3. **Lost nudges** — for ledger rows whose `last_nudge_at` falls in the
   audit week, check the weekly logs for a matching send-failure line
   (write-before-send means a failed send is claimed but never delivered).
   Any found → **warn** listing the PRs (the operator may nudge manually).

## Report

One message, this shape (keep it tight — counts and one-liners, no prose):

```
🩺 *<bot_display_name> weekly audit* — <date> · 🟢 N ok · 🟡 N warn · 🔴 N fail

*Week in numbers* (since <stats.since>)
• Reviews: <total> (<first> first / <re_review> re) — ✅<approve> ⚠️<comment> ❌<request_changes>
• Open PRs: <open_prs> · Nudges: <nudges_claimed> · Heartbeats: <total> (<idle> idle)

*Checks*
🔴 <id> — <detail>          ← every fail
🟡 <id> — <detail>          ← every warn
🟢 all other checks passed (<count>)

*Action needed*: <one line per fail/warn that needs a human, or "none">
```

- **Slack enabled** → send via `mcp__platform-outbound__send_channel_message`
  (`channel: "slack"`, omit `chatId`) — the send itself is the Slack
  connectivity check. Send failure → post the full report to the chat UI
  instead and log the failure.
- **Slack disabled** → chat UI only (the audit never requires Slack).
- Always echo the report to the chat UI as well.

## Wrap-up

Append one line to `work/AUDIT.log`
(`<ISO> ok=<n> warn=<n> fail=<n> sent=<slack|chat>`), then commit & push
`work/` per CLAUDE.md. Never write to GitHub or modify state files beyond
this — findings are reported, not repaired.
