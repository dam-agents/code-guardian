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
- **job** — `review` | `shepherd` | `audit` | `benchmark` | `session` (from `LOG_JOB`).
- **level** — `debug` | `info` | `warn` | `error`. `debug` lines are written
  only when `work/CONFIG.md` has `log_level: debug` (missing key = `info`).
- **event** — short machine-groupable token (`heartbeat`, `preflight`,
  `gh_api`, `skill_install`, `skill_timing`, `tool_failure`, `tool_use`, `review_step`,
  `review_incomplete`, `progress_status`, `mention_handled`, `stall_rate`,
  `stall_alert_sent`, `pod_boot`, `log_cleanup`, …); the audit groups recurring
  errors by it.
- **msg** — the human-readable message / error.

Writer: `scripts/log.sh` — source it, then `logev <level> <event> <msg>`.
It never fails a run (all error paths swallowed) and creates `work/logs/`
on first write.

### The shape is a contract, not a convention

Three readers parse these lines — the `Stop` hook, preflight's live-holder and
stall detection, and the audit's triage — so a line written any other way is
invisible to them, and an invisible terminal step reads as a review that never
finished. When `logev` is unavailable and a line is hand-rolled, it matches
exactly:

- **File** — `work/logs/events-<UTC YYYY-MM-DD>.jsonl` for the write day. No
  other name is ever read (`events-2026-08.jsonl`, `review-steps.log`: not read).
- **Object** — the seven fields above, one line, no trailing comma; `event` and
  `msg` are strings; `run` is the harness session id.
- **`review_step` `msg`** — `PR #<n> [<sha-short>] <step>`, the sha optional.
  `{"pr":42,"step":"done"}`, or `type` in place of `event`, parses as nothing.

### Tool path resolution (`scripts/lib/toolpath.sh`)

`log.sh` sources it, so anything sourcing `log.sh` inherits it; the harness
hooks source it explicitly, **above** their `command -v jq` guard.

Where `jq`/`gh` on `PATH` are symlinks to a version manager (mise shims on the
DAM pod), every exec re-resolves its toolchain — ~250 ms against ~17 ms for the
real binary. `preflight.sh` execs `jq` ~90× per run and the hooks fire per tool
call, so `toolpath_init` resolves each shimmed tool once per shell process (via
`mise bin-paths`, cached in `work/.cache/toolpaths` — a forked subprocess is
served from that file) and shadows it with a function calling the binary
directly.

- **`PATH` is never modified** — the offline suite stubs `gh` by prepending
  `scripts/tests/bin` to `PATH`, and a tool already resolving outside
  `*/shims/*` (test stub, operator override, fixed image) is left untouched.
- Unresolvable tools keep working through the shim; nothing here fails a run.
- `toolpath_shimmed` backs the audit's `tool_shims` check — a shimmed tool
  passes `cli_deps` but silently costs the tax, so the warning names it. **The
  real fix belongs in the pod image** (real bin dirs ahead of the shim dir on
  `PATH`); this is a workaround for an environment defect
  ([self-modification.md](self-modification.md) §5a).

## Who writes what

1. **`scripts/preflight.sh` (automatic)** — sources log.sh with
   `LOG_JOB=<mode>`: one `heartbeat` summary per run, every worklist `log`
   line (`preflight`, info), and errors it would otherwise swallow —
   unresolvable repo/API-list failures (`preflight`, error), silent GitHub
   API failures at decision sites (`gh_api`, warn), skill install failures
   (`skill_install`, error), and — once per pod restart — a `pod_boot` warn
   (an ephemeral `/tmp` sentinel is absent iff the pod restarted since the
   last run; $HOME persists, the rest of the filesystem is reset). Detect-only,
   never gates behavior; a run with no matching `heartbeat`/session activity
   after a `pod_boot` is a restart that interrupted work.
2. **Harness adapter (automatic)** — every **failed tool call** of the agent
   becomes a `tool_failure` error event (tool name, truncated input, and the
   fullest error context available — `tool_response`, then error/stderr/stdout
   fields, then the raw `tool_input`/`tool_response` payload, so a failure is
   never logged as bare `null`). Exception: read-only inspect commands
   (`grep`/`rg`/`ls`/`find`/`test`/`command`/`stat`) answer "no match" with a
   non-zero exit — those land as info `tool_use` events, keeping the
   `failures[]` triage on real failures. The match is on the **basename of the
   command that set the exit status** — the last element of a `&&`/`;`/`|`
   chain — so `/usr/bin/grep …` and `cd … && grep …` are recognised as the
   inspects they are. Under `log_level: debug`, successful external
   calls (Bash
   `gh`/`git`/`curl` commands, `mcp__*` tools) also land as `tool_use`
   debug events with a truncated result. At session end, one **`tokens`**
   event records the run's API usage
   (`input=… output=… cache_read=… cache_creation=… msgs=…`, summed from the
   session transcript, deduped by message id) — since one scheduled run is
   one fresh session, this is per-job consumption; join on `run` with the
   `heartbeat` event for the job's mode. Best-effort: a hard-crashed session
   has no tokens event; subagent transcripts are not included. See
   **Harness adapters** below.
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
- `log-session-tokens.sh` — `SessionEnd` hook target: the per-run `tokens`
  event (duty 2 above).
- `log-review-step.sh` — `PostToolUse` (`Bash|Task`) hook target: derives the
  observable `review_step` milestones — `cloned`, `skill:<name> done`,
  `posted <verdict>` — from the tool call that performs them, so they survive a
  turn that ends before the agent logs them. Idempotent per (run, PR, step) via
  a `/tmp/.cg-steps-<session>` marker dir; the steps needing agent knowledge
  (`locked`, `done`, `aborted`) stay manual ([review.md](review.md) → **Progress
  logging**).
- `enforce-review-completion.sh` — `Stop` hook target: refuses a stop that
  would leave a PR locked without a terminal `review_step`, logging a
  `review_incomplete` warn per block ([review.md](review.md) → **Completion
  enforcement**).
- `install.sh` — registers the hooks in `~/.claude/settings.json`
  (idempotent; run at onboarding Step 1b and after definition updates that
  change the adapter; effective from the next session). On a non-Claude-Code
  harness it prints a notice and exits 0.

Registration is user-global, so every hook script no-ops unless
`$WORK/CONFIG.md` exists — they only ever act on sessions of a deployed
instance (nothing is logged until onboarding Step 4 writes the config, and
running `install.sh` on a developer machine stays harmless). Messages pass
`log_redact` (log.sh) before writing — well-known credential shapes
(GitHub/Slack tokens, bearer headers) are masked, per the no-secrets-in-logs
invariant.

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
- `work/MENTIONS.md` (the mention dedup ledger, [mentions.md](mentions.md))
  is trimmed to rows younger than 14 days — older rows are outside the
  7-day scan window and can never be re-emitted.
- `work/AUDIT.log` is exempt (one line per week).
- The cleanup itself is logged (`log_cleanup`, info). When `work/` is
  git-backed, older logs remain recoverable from the work repo's history.

The audit also triages the week's events — error/warn counts into `stats`,
`events_errors` + `recurring_errors` checks (an `event` recurring ≥3× in a
week is flagged) — and the report surfaces every one of them
([audit.md](audit.md)).

**Every `level: error` event** gets a second pass: the script groups them into
`failures[]` (`event`, `tool`, `error`, `count`, `first`, `last`), normalizing
SHAs, numbers, and `/tmp` paths so one root cause is one entry — and for
`tool_failure` also stripping the command text and keeping the tool name.
`first`/`last` date each signature: a `last` older than a shipped fix means it is
already resolved. The agent diagnoses each and may file a tracking issue
(audit.md task 3).

This is why **an error event's `msg` must carry its real error text** — a
placeholder (or a bare `null`) makes the signature undiagnosable, which is what
made the 1.4.0 `tool_failure` capture fix necessary.

## Reading the log

```bash
cat work/logs/events-*.jsonl | jq -c -R 'fromjson? // empty' \
  | jq -s '[.[] | select(.level=="error")] | group_by(.event) | map({event: .[0].event, n: length})'
jq -c -R 'fromjson? // empty' "work/logs/events-$(date -u +%Y-%m-%d).jsonl" | jq -c 'select(.run=="<run-id>")'
```

### Reading skill timings

`skill:<name> done` is derived from the subagent tool call **returning**, so a
parallel fan-out stamps every skill within milliseconds of the collection and
carries no per-skill duration — differencing those events measures nothing.
Read the phase from `review_step` `fanned out (n=<N>)` → `verified` → `posted`,
and per-skill finish times from the `skill_timing` event
([review.md](review.md) → **Progress logging**).
