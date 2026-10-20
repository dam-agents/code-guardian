# Harness: pi

What is specific to the pi harness (pi coding agent behind `pi-acp` on DAM).
The contract all harnesses share is [logging.md](logging.md) →
**Harness adapters**.

## Session

- **Detected by** `PI_CODING_AGENT=true` or `PLATFORM_HARNESS=pi`
  (`scripts/lib/harness.sh`). Run id: `PI_SESSION_ID`, the platform session id
  ([logging.md](logging.md) → **The events log**).
- **Model and effort:** `PI_PROVIDER`, `PI_MODEL` (the exact id the benchmark
  records as `model`), `PI_REASONING_LEVEL` (pi's thinking level, recorded as
  `effort`).
- **Transcripts** `~/.pi/agent/sessions/--<cwd>--/<ts>_<id>.jsonl`; assistant
  entries carry `message.usage` (`input`, `output`, `cacheRead`,
  `cacheWrite`).
- **Platform tools** are named `mcp__platform_outbound__<tool>` — the
  definition's `mcp__platform-outbound__<tool>` with `_` for `-`.
  `rename_session` and `schedule_once` with an `inSession` other than `fresh`
  need a session reference pi does not send; a refusal leaves the title as it
  is.

## Subagents

pi has none of its own. `scripts/harness/pi/subagents.sh <dir>` runs every
`<dir>/<name>.prompt` at once as a nested `pi -p` session in `$HOME` — this
session's provider, model and thinking level, the built-in tools only (no
platform tools), no context files — waits for all of them, writes
`<name>.reply` and prints one `{"name","exit","reply"}` line per subagent.
Each nested session file lands in `<session file>/subagents/`, the Claude Code
layout, so the run's `tokens` and `review_cost` events count it; each subagent
that ends logs `skill:<name> done` when its prompt names a configured skill.
Run it in the foreground with a shell timeout above its `CG_SUBAGENT_TIMEOUT`
(default 3600 s).

- **Skill fan-out** ([skills.md](skills.md) → **Invocation & audit log**):
  log `fanned out (n=<N>)`, write each `skills.<skill>.prompt` to
  `$PR_DIR.prompts/<skill>.prompt`, run `subagents.sh "$PR_DIR.prompts"`, then
  `review-pr.sh collect` as usual. A subagent with a non-zero `exit` is
  `skill-errored`.
- **Benchmark** ([benchmark.md](benchmark.md) → **Running the benchmark**):
  `subagents.sh` runs every prompt of its directory, so each call gets its
  own empty one — `$PR_DIR.prompts-<phase>` for a phase's skill prompts, then
  `$PR_DIR.reviewer-<phase>` for its reviewer brief, inside the phase
  bracket, emptied by the benchmark's `rm -rf` steps; the nonce in every
  prompt puts each nested transcript into the phase's tokens.
- **Judge** ([benchmark.md](benchmark.md) → **Phase 2** step 6): no subagent.
  `scripts/benchmark-judge.sh` runs it as one `claude -p` call per raw
  review, outside the phase brackets. It leaves no transcript, so its tokens
  are not in the phase's tokens. A pi pod needs the `claude` CLI and
  access to the `benchmark_judge` model; without them the judge stays null
  and the run keeps its deterministic scores.

## Skills

pi has no Skill tool: a skill is run by reading its `SKILL.md` and following
it. Repo-sourced skills install into `~/.claude/skills/`, which the DAM image
links to `~/.agents/skills/`, a directory pi reads.

## Adapter

`scripts/harness/pi/`:

- `extension.ts` — pi has no hooks; this extension turns pi's events into the
  Claude Code hook payloads and runs the Claude Code adapter's scripts
  ([harness-claude-code.md](harness-claude-code.md) → **Adapter**), so every
  rule has one implementation: `tool_call` (bash) → the definition-issue
  guard, which blocks the call; a failed `tool_result` → `tool_failure`; a bash
  `tool_result` → the `review_step` milestones and `review_cost`;
  `agent_before_settle` → completion enforcement, which continues the run, and
  the hold release, or `api_failure` when the run ended on an API error;
  `session_shutdown` (DAM closes an idle session) → the `tokens` event. A
  nested subagent session logs under its parent's run id and runs only the
  guard and the failure log. The scripts act on the definition the extension
  belongs to and its `work/`. A script that times out (30 s) or cannot start
  fails open, as a failed Claude Code hook does — the call goes through
  unchecked — and logs one `adapter_failure` warn that names it.
  `scripts/tests/test_pi_extension.sh` loads the extension in Node 24 and
  checks every mapping. An API error message maps onto the classes of
  [monitor.md](monitor.md) → **The `api_failure` classes**. CI's
  `typescript` job runs `tsc` with `tsconfig.json` against the pinned pi API;
  the pod installs no packages.
- `install.sh` — links `extension.ts` into `~/.pi/agent/extensions/`, which
  pi loads into every session; `--check` prints `pi-extension` when the link
  is not current. Run at onboarding Step 1b; the monitor checks it on every
  tick (`harness_drift`) and the audit's `harness_adapter` check on pi.
- `subagents.sh` — the subagent fan-out above.
- `usage-snapshot.sh` — the benchmark's per-phase token snapshot over every
  transcript holding the nonce; it sums with the Claude Code adapter's
  `usage-sum.jq`, which reads both transcript formats (`review-window.jq`
  too).

pi has no auto-mode classifier, so it logs no `classifier_block`.
