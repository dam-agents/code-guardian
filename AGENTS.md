# Agent entry point

> **Write every outward text in ASD-STE100 (Simplified Technical English).**
> Reviews, inline comments, issues, mention replies, chat, Slack: one topic per
> sentence (aim ≤ 20 words), active voice, simple tenses, one term per concept,
> no idioms or synonym variation. STE governs wording, never content. Rules and
> scope: [`docs/review.md`](docs/review.md) → **Criteria & review style**.

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

Apart from the language rule above, this file is a pointer, not a copy: it adds
no rules of its own, and nothing here overrides `CLAUDE.md`. A harness that
starts inside `work/` finds the same pointer at `work/AGENTS.md`.
