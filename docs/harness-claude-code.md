# Harness: Claude Code

What is specific to the Claude Code harness. The contract all harnesses share
is [logging.md](logging.md) → **Harness adapters**.

## Session

- **Detected by** `CLAUDECODE=1`. Run id: `CLAUDE_CODE_SESSION_ID`
  ([logging.md](logging.md) → **The events log**). Effort: `CLAUDE_EFFORT`.
- **Transcripts** `~/.claude/projects/**/*.jsonl`, subagents' beside them
  in `<session>/subagents/`; `usage-sum.jq` sums them for the `tokens`
  event and the benchmark's phase snapshot (`usage-snapshot.sh`).
- **Platform tools** are named `mcp__platform-outbound__<tool>`.

## Subagents and skills

- **Subagents** are the harness's own (the Agent tool). The skill fan-out
  ([skills.md](skills.md) → **Invocation & audit log**) launches every skill's
  subagent in one message with subagent type `review-skill`; the benchmark's
  reviewer subagents use the default type.
- **Skills** are invoked with the Skill tool.

## Adapter

The pi adapter runs the hook scripts below from pi events
([harness-pi.md](harness-pi.md) → **Adapter**).


- `log-tool-event.sh` — hook target for `PostToolUseFailure` (all tools) and
  `PostToolUse` (external calls, debug).
- `log-session-tokens.sh` — `SessionEnd` target: the per-run `tokens` event.
- `log-review-step.sh` — `PostToolUse` (`Bash|Task`) target: derives the
  observable `review_step` milestones — `cloned`, `skill:<name> done`,
  `posted <verdict>`, and `locked` / `locked (refresh)` / `done` /
  `aborted (lock released)` from the REVIEWS.md row write in its documented
  shape — so they survive a turn that ends before the agent logs them.
  Idempotent per (run, PR, step) via a `/tmp/.cg-steps-<session>` marker dir;
  lock refreshes are logged every time, because they are the liveness signal.
  The steps that need the agent's decision (`fanned out`, `verified`,
  `aborted <reason>`) come from `review-pr.sh step` / `abort`, or from the
  agent in the manual fallback. It also logs one **`review_cost`** event
  per review, whoever logged its steps: the usage between this run's
  `<sha7> locked` and `<sha7> done` steps of the PR, summed like the `tokens`
  event, and the window's shape (`review-window.jq`, `tool_failure` events) —
  `PR #<n> <sha7> secs=… input=… output=… cache_read=… cache_creation=… msgs=…
  model=… subagents=<n new> peak_ctx=… repeats=… repeat_tool=… max_out=…
  failures=…`. An aborted review has none. The monitor judges it
  ([monitor.md](monitor.md) → **Review anomaly alert**).
- `log-permission-denied.sh` — `PermissionDenied` target: one
  `classifier_block` warn per auto-mode refusal, `<tool> [<command, or
  subagent type and description, or URL>] — <reason>`, capped at 300
  characters. Record only: it never asks the harness to retry.
- `log-api-failure.sh` — `StopFailure` target: one `api_failure` error per
  turn that ended on an API error the harness's own retries did not clear,
  `<class>: <detail>` (`server_error`, `overloaded`, `rate_limit`,
  `authentication_failed`, …). The monitor and the audit read both
  ([monitor.md](monitor.md)).
- `enforce-review-completion.sh` — `Stop` target: refuses a stop that would
  leave a PR locked without a terminal `review_step`, logging a
  `review_incomplete` warn per block ([review.md](review.md) → **Completion
  enforcement**); a stop it lets through releases the run's own PR holds
  ([worklist.md](worklist.md) → **PR holds**).
- `guard-definition-issue.sh` — `PreToolUse` (`Bash`) target: refuses, with
  exit 2 and the reason on stderr, a command that writes an issue of
  `definition_repo` by any path other than `scripts/definition-issue.sh`, and
  logs a `definition_issue` warn per block ([runbook.md](runbook.md) →
  **Definition-repo issues**). The definition repo is its slug as
  `work/CONFIG.md` (or `$HOME`'s origin) resolves it, a shell variable named
  after it (`$DEF`, `$DEFINITION_REPO`, `${DEF_REF#*/}`) or gh's
  `{owner}/{repo}`. It refuses a `gh issue` write (`create`, `comment`,
  `edit`, `close`, `reopen`, `delete`, `transfer`, `pin`, `unpin`, `lock`,
  `unlock`, `develop`) in any simple command of a compound one whose
  `-R`/`--repo` names that repo or that has no repository flag (gh resolves
  the checkout under `$HOME`); a `gh api` write to its `issues` endpoints
  (`-X`/`--method` `POST`, `PATCH`, `PUT` or `DELETE`, or fields without an
  explicit `GET`); a `curl` write to them (a write method or a data option);
  and an issue GraphQL mutation (`createIssue`, `updateIssue`, `addComment`,
  `closeIssue`, `reopenIssue`, `deleteIssue`, `transferIssue`) that names
  that repo, by slug or by owner and name, or no repository at all. Reads,
  the target repo's issues and every other tool pass; an unresolved
  definition repo guards nothing.
- `install.sh` — registers the hooks in `~/.claude/settings.json` (idempotent;
  run at onboarding Step 1b and after definition updates that change the
  adapter; effective from the next session). It also keeps the auto-mode
  classifier rules for the agent's documented writes outside the target repo —
  the anonymous tracking issue on `definition_repo` through
  `scripts/definition-issue.sh`, the `curl -X PUT` upload of every published
  report and artifact (`work/audit/`, `work/benchmark/`,
  `work/reviews/pr-artifacts/`, `work/survey/`),
  the review dispatch through `schedule_once`, and the review steps the
  classifier refused most (`review-pr.sh`, the `review-skill` subagent,
  `work-backup.sh`, the cleanup of review scratch) —
  as `autoMode.environment` / `autoMode.allow` entries tagged
  `[code-guardian]`, replacing only its own. It writes the tools of
  `denied-tools.txt` — tools neither a procedure nor a platform prompt (Kit
  Update: `report_kit_updated`, `cancel_kit_update`) calls — to
  `permissions.deny`, which
  removes their definitions from every request of every session and subagent,
  replacing only its own entries; and it installs `agents/review-skill.md` as
  `~/.claude/agents/review-skill.md`, the subagent type of the skill fan-out
  ([skills.md](skills.md) → **Invocation & audit log**), limited to the tools
  a skill run needs. `install.sh --check` prints the parts not current:
  `hooks`, `automode-rules` (the `[code-guardian]` rules differ from the ones
  this definition writes), `tool-deny`, `skill-agent`. On another harness it
  prints a notice and exits 0.

Registration is user-global, so every hook script no-ops unless
`$WORK/CONFIG.md` exists: they act only on sessions of a deployed instance.
`guard-definition-issue.sh` is the exception: it guards wherever it resolves a
definition repo, `$HOME`'s origin included, because onboarding runs from that
checkout before `CONFIG.md` exists.
Messages pass `log_redact` (log.sh) before writing — well-known credential
shapes (GitHub/Slack tokens, bearer headers) are masked, per the
no-secrets-in-logs invariant.

The weekly audit verifies the adapter matches the detected harness
(`harness_adapter` check): a Claude Code pod without registered hooks, current
auto-mode rules (the tracking-issue rule names `definition_repo`), the deny
list or a current `review-skill` agent is a warn. The monitor checks the same
parts on every tick (`harness_drift`, [monitor.md](monitor.md)).
