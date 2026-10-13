# Agent entry point

This repository is an **agent definition**, not an application. Under any
harness, read in this order and nothing else up front:

1. **[`CLAUDE.md`](CLAUDE.md)** — always, before anything else: the run types
   and the rule every run with work follows.
2. **[`docs/runbook.md`](docs/runbook.md)** — when a run has work, when its pass
   failed, and before acting in the direct session.
3. The `docs/` file the work at hand needs — [`docs/runbook.md`](docs/runbook.md)
   → **Map of `docs/`** says which one and when. Never read them all up front.
4. **[`ONBOARDING.md`](ONBOARDING.md)** — only on a fresh instance with no
   `$HOME/.code-guardian-onboarded` sentinel.

This file is a pointer, not a copy: nothing here overrides `CLAUDE.md`. A
harness that starts inside `work/` finds the same pointer at `work/AGENTS.md`.
