# Harness: Copilot

What is specific to the Copilot harness (GitHub Copilot coding agent on DAM).
The contract all harnesses share is [logging.md](logging.md) →
**Harness adapters**.

- **Detected by** `PLATFORM_HARNESS=copilot` (`scripts/lib/harness.sh`).
  Version: `COPILOT_CLI_BINARY_VERSION`, recorded by the benchmark as
  `copilot <version>` — never a version borrowed from another harness's CLI
  installed on the same pod.
- **Session state** `~/.copilot/session-state/<session-id>/`
  (`COPILOT_AGENT_SESSION_ID`), its events in `events.jsonl`; the definition
  reads none of it.
- **Tokens:** no usage snapshot exists for Copilot
  (`scripts/harness/copilot/`), so the benchmark records `tokens: null` and
  the audit, the trends and the health dashboard report tokens as not
  measured.
- **Effort:** Copilot exposes no reasoning-effort variable, so the benchmark
  records `effort: "unknown"` and that run gets no delta.
- **Adapter:** none. The agent logs tool failures itself
  ([logging.md](logging.md) → **Who writes what**, duty 4).
