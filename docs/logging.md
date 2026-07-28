# Structured logging — format, sources, retention

Read this file when writing log events, debugging a past run, replacing the
harness adapter, or handling the audit's log triage.

## The events log

One place for everything diagnostic: `work/logs/events-YYYY-MM-DD.jsonl`
(one file per UTC day), one JSON object per line:

```json
{"ts":"2026-07-28T09:14:02.123Z","run":"<run-id>","job":"review","level":"error","event":"gh_api","msg":"PR #42: state check failed — prune skipped this run"}
```

- **ts** — exact UTC write time (ms precision where the platform's `date`
  supports it).
- **run** — the run/job identifier: `LOG_RUN_ID` env → harness session id
  (`CLAUDE_CODE_SESSION_ID`) → start time + pid. Groups all lines of one run.
- **job** — `review` | `shepherd` | `audit` | `session` (from `LOG_JOB`).
- **level** — `debug` | `info` | `warn` | `error`. `debug` lines are written
  only when `work/CONFIG.md` has `log_level: debug` (missing key = `info`).
- **event** — short machine-groupable token (`heartbeat`, `preflight`,
  `gh_api`, `skill_install`, `tool_failure`, `tool_use`, `review_step`,
  `log_cleanup`, …); the audit groups recurring errors by it.
- **msg** — the human-readable message / error.

Writer: `scripts/log.sh` — source it, then `logev <level> <event> <msg>`.
It never fails a run (all error paths swallowed) and creates `work/logs/`
on first write.

## Who writes what

1. **`scripts/preflight.sh` (automatic)** — sources log.sh with
   `LOG_JOB=<mode>`: one `heartbeat` summary per run, every worklist `log`
   line (`preflight`, info), and errors it would otherwise swallow —
   unresolvable repo/API-list failures (`preflight`, error), silent GitHub
   API failures at decision sites (`gh_api`, warn), skill install failures
   (`skill_install`, error).
2. **Harness adapter (automatic)** — every **failed tool call** of the agent
   becomes a `tool_failure` error event (tool name, truncated input and
   error). Under `log_level: debug`, successful external calls (Bash
   `gh`/`git`/`curl` commands, `mcp__*` tools) also land as `tool_use`
   debug events with a truncated result. See **Harness adapters** below.
3. **The agent (manual)** — two duties:
   - **Review milestones**: the `review_step` events of
     [review.md](review.md) → Progress logging.
   - **Semantic failures hooks can't see** (the tool succeeded but the
     action failed): posting aborts, findings dropped to summary via 422,
     a failed Slack send or unassign, a failed `work/` push. Whenever a
     `docs/` procedure says "log it", log to the chat UI **and** append an
     event: chain onto the step's existing command — never a separate tool
     call —

     ```bash
     . "$HOME/scripts/log.sh" && LOG_JOB=review logev error post_failed "PR #42: 422 commit_id mismatch — discarded"
     ```

## Harness adapters (`scripts/harness/<name>/`)

All harness-specific code lives in its own directory, replaceable without
touching `scripts/log.sh` or any procedure. Adapter contract: capture the
agent's failed tool calls into `tool_failure` events automatically; when no
adapter is active, duty 3 above extends to logging tool failures manually.

**Claude Code** (`scripts/harness/claude-code/`) — detected by
`CLAUDECODE=1` in the environment:

- `log-tool-event.sh` — hook target for `PostToolUseFailure` (all tools)
  and `PostToolUse` (external calls, debug).
- `install.sh` — registers both hooks in `~/.claude/settings.json`
  (idempotent; run at onboarding Step 1b and after definition updates that
  change the adapter; effective from the next session). On a non-Claude-Code
  harness it prints a notice and exits 0.

The weekly audit verifies the adapter matches the detected harness
(`harness_adapter` check) — a Claude Code pod without registered hooks is a
warn.

## Retention — the weekly audit cleans up

Log cleanup happens **only in the audit run** (`preflight.sh audit`,
script-side), keeping at least 14 days:

- `work/logs/events-*.jsonl` files older than 14 days are deleted — with the
  weekly cadence a file is 14–21 days old when it dies.
- `work/HEARTBEAT.log` and `work/SHEPHERD.log` are trimmed in place to the
  last 14 days (unparseable lines are kept).
- `work/AUDIT.log` is exempt (one line per week).
- The cleanup itself is logged (`log_cleanup`, info). When `work/` is
  git-backed, older logs remain recoverable from the work repo's history.

The audit also triages the week's events — error/warn counts into `stats`,
`events_errors` + `recurring_errors` checks (an `event` recurring ≥3× in a
week is flagged) — and the report surfaces every one of them
([audit.md](audit.md)).

## Reading the log

```bash
cat work/logs/events-*.jsonl | jq -c -R 'fromjson? // empty' \
  | jq -s '[.[] | select(.level=="error")] | group_by(.event) | map({event: .[0].event, n: length})'
jq -c -R 'fromjson? // empty' "work/logs/events-$(date -u +%Y-%m-%d).jsonl" | jq -c 'select(.run=="<run-id>")'
```
