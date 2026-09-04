# Agent entry point

> **Every outward text is ASD-STE100 (Simplified Technical English)** —
> [`docs/review.md`](docs/review.md) → **Criteria & review style**.

This repository is an **agent definition**, not an application. Its entry point
is **[`CLAUDE.md`](CLAUDE.md)** — read that file first, under any harness. It
names the run types, the pre-flight entry command, and the one rule every run
with work follows: read **[`docs/runbook.md`](docs/runbook.md)** — the worklist
contract, the run procedures, the trust boundary, and the hard invariants.

Reading order for a run:

1. **[`CLAUDE.md`](CLAUDE.md)** — always, before anything else.
2. **[`docs/runbook.md`](docs/runbook.md)** — when preflight reports work, when
   it failed, and before acting in the direct session.
3. The `docs/` file the work at hand needs — `docs/runbook.md` → **Map of
   `docs/`** says which one and when. Never read them all up front.
4. **[`ONBOARDING.md`](ONBOARDING.md)** — only on a fresh instance that has no
   `$HOME/.code-guardian-onboarded` sentinel.

This file is a pointer, not a copy: the language rule above is stated in its
own home, and nothing here overrides `CLAUDE.md`. A harness that starts inside
`work/` finds the same pointer at `work/AGENTS.md`.
