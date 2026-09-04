# Finding form

The shape every finding takes, whoever writes it — the diff review
([review.md](review.md)), a skill subagent's reformat ([skills.md](skills.md)
→ **Invocation & audit log**), the benchmark reviewer
([benchmark.md](benchmark.md)). The shape, the approval bar, and the
conciseness rules bind every writer; bullets marked *review only* apply when
the review itself is composed ([review.md](review.md)). Wording follows
ASD-STE100 ([review.md](review.md) → **Criteria & review style**).

One finding is one line, plus a **Fix:** line when it blocks; paths are
repo-relative:

```
- 🔴 **Critical:** <description> (`file:line`)
  **Fix:** <the remedy that resolves it>
```

🟡 **Warning:** takes the same shape; 🟢 **Suggestion:** is the description
line alone.

**The approval bar.** 🔴 and 🟡 are blocking — they hold the verdict below
`APPROVE` until they are resolved. 🟢 never blocks. Each blocking finding
carries the fix that resolves it, so the bar reads off the findings
themselves.

**Blocking findings are complete and uncapped.** Report every 🔴 and 🟡 that
survives verification, however many that is; a first review is the complete
list of what is wrong with the PR.

**🟢 budget per review: 3 when the review carries no 🔴 and no 🟡, otherwise
1.** The budget counts every 🟢 the review prints — `### Findings` and skill
sections together — and keeps the strongest. *Review only:* what it dropped
is counted in `### Summary`, `_N suggestion(s) dropped under the 🟢 budget._`,
so a section that reported 🟢 never reads as clean.

**Concise by default (all reviews, all channels):**

- One finding = what is wrong, why it matters, where — in 1–2 sentences. No
  essays, no restated diff context, no hedging filler.
- Every 🔴 and 🟡 carries a **Fix:** line — the remedy that resolves the
  finding, in 1–2 sentences. State it as a rule for the whole defect class,
  and name its scope when more than one place is affected. A finding whose
  remedy you cannot state is not verified — drop it. *Review only:* it sits
  with the description (the inline comment when the finding is
  inline-carried, `### Findings` otherwise), above any ` ```suggestion ` block.
- Findings anchor to this PR's diff; a pre-existing problem spotted in
  passing is at most one 🟢 line suggesting a separate issue.
- 🟢 **Suggestion** only when the improvement is substantial (a real
  correctness/security/performance/simplification win). Style nits,
  micro-refactors, and "consider…" filler are dropped entirely, not demoted.
- *Review only:* `✅ Looks good` — at most one bullet, only when it carries
  real information (e.g. a risky-looking change verified safe); never
  filler. None on re-reviews.
- *Review only:* `### Summary` stays 1–2 sentences.
