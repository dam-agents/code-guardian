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
Run it in the foreground with a shell timeout above its
`CG_SUBAGENT_TIMEOUT` (default 3600 s).

- **Skill fan-out** ([skills.md](skills.md) → **Invocation & audit log**):
  log `fanned out (n=<N>)`, write each `skills.<skill>.prompt` to
  `$PR_DIR.prompts/<skill>.prompt`, run `subagents.sh "$PR_DIR.prompts"`, then
  `review-pr.sh collect` as usual. A subagent with a non-zero `exit` is
  `skill-errored`.
- **Benchmark** ([benchmark.md](benchmark.md) → **Running the benchmark**):
  each phase's skill prompts go into one directory and its reviewer brief
  into another, run one after the other inside the phase bracket; the nonce
  in every prompt puts each nested transcript into the phase's tokens. The
  judge runs the same way, on the session model.

## Skills

pi has no Skill tool: a skill is run by reading its `SKILL.md` and following
it. Repo-sourced skills install into `~/.claude/skills/`, which the DAM image
links to `~/.agents/skills/`, a directory pi reads.

## Adapter

- `subagents.sh` — the subagent fan-out above.
- `usage-snapshot.sh` + `usage-sum.jq` — the benchmark's per-phase token
  snapshot over every transcript holding the nonce, in the shape of the Claude
  Code one.

No hooks: no `tool_failure` capture, `tokens` event, `review_cost`,
`skill:<name> done`, `api_failure`, `classifier_block`, completion
enforcement, definition-issue guard or hold release at stop. The agent logs
tool failures itself ([logging.md](logging.md) → **Who writes what**, duty 4);
holds of a stopped run expire by the **Live holder** windows
([review-mechanics.md](review-mechanics.md)); the audit, the trends and the
health dashboard report sessions and tokens as not measured.
