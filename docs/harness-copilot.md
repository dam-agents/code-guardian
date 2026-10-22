# Harness: Copilot

What is specific to the Copilot harness (GitHub Copilot coding agent on DAM).
The contract all harnesses share is [logging.md](logging.md) →
**Harness adapters**.

- **Detected by** `PLATFORM_HARNESS=copilot` (`scripts/lib/harness.sh`).
  Version: `COPILOT_CLI_BINARY_VERSION`, recorded by the benchmark as
  `copilot <version>` — never a version borrowed from another harness's CLI
  installed on the same pod.
- **Run id:** `scripts/log.sh` and `scripts/review-pr.sh` read no Copilot
  session id, so every shell command carries `export CG_RUN_ID=<id>;`
  ([logging.md](logging.md) → **The events log**).
- **Session state** `~/.copilot/session-state/<session-id>/`
  (`COPILOT_AGENT_SESSION_ID`), its events in `events.jsonl`; the definition
  reads none of it.
- **Subagents:** Copilot's own. The skill fan-out and the benchmark's reviewer
  subagents use a built-in agent; the definition installs no custom agent
  profile. Where a subagent cannot start, review inline
  ([benchmark.md](benchmark.md) → **Segmented run**).
- **Skills:** repo-sourced skills install into `~/.claude/skills/`, which the
  DAM image links to `~/.agents/skills/`, a personal skills directory Copilot
  reads. To run a skill, read its `SKILL.md` and follow it.
- **Platform tools:** the definition names them
  `mcp__platform-outbound__<tool>`; on Copilot, call the platform-outbound
  server's `<tool>` as the session's tool list names it.
- **Tokens:** no usage snapshot exists for Copilot
  (`scripts/harness/copilot/`), so the benchmark records `tokens: null` and
  the audit, the trends and the health dashboard report tokens as not
  measured.
- **Effort:** Copilot exposes no reasoning-effort variable, so the benchmark
  records `effort: "unknown"` and that run gets no delta.
- **Adapter:** none. The agent logs tool failures itself
  ([logging.md](logging.md) → **Who writes what**, duty 4).
