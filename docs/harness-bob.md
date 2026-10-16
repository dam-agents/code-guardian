# Harness: Bob

What is specific to the Bob harness (IBM Bob Shell behind `bob acp` on DAM).
The contract all harnesses share is [logging.md](logging.md) →
**Harness adapters**.

- **Detected by** `PLATFORM_HARNESS=bob` (`scripts/lib/harness.sh`). No
  session id reaches a chat session: every shell command carries
  `export CG_RUN_ID=<id>;` ([logging.md](logging.md) → **The events log**).
- **Config** `~/.bob/`; `~/.bob/skills` is linked to `~/.agents/skills/`,
  where repo-sourced skills arrive through `~/.claude/skills/`.
- **Tokens:** Bob records none the definition can read, so the benchmark
  records `tokens: null` and the audit, the trends and the health dashboard
  report sessions and tokens as not measured.
- **Subagents:** Bob's own (DAM sets a subagent model for Bob); the skill
  fan-out uses its default subagent.
- **Adapter:** none. The agent logs tool failures itself
  ([logging.md](logging.md) → **Who writes what**, duty 4); a stopped run's
  holds expire by the **Live holder** windows
  ([review-mechanics.md](review-mechanics.md)); there is no completion
  enforcement, definition-issue guard, `review_cost`, `api_failure` or
  `classifier_block`.
