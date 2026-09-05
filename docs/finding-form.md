# Finding form

The shape every finding takes, whoever writes it — the diff review
([review.md](review.md)), a skill subagent's reformat ([skills.md](skills.md) →
**Invocation & audit log**), the benchmark reviewer
([benchmark.md](benchmark.md)). The shape, the severity bar, the approval bar
and the conciseness rules bind every writer; bullets marked *review only* apply
when the review itself is composed. Wording follows ASD-STE100
([review.md](review.md) → **Criteria & review style**).

One finding is one line, plus a **Fix:** line when it blocks; paths are
repo-relative:

```
- 🔴 **Critical:** <description> (`file:line`)
  **Fix:** <the remedy that resolves it>
```

🟡 **Warning:** takes the same shape; 🟢 **Suggestion:** is the description
line alone.

**Severity:**

- 🔴 **Critical** — a reachable path gives a wrong result, a security hole, or
  data loss.
- 🟡 **Warning** — a real defect with a bounded blast radius: a conditional
  path, degraded behavior, or changed logic with no test.
- 🟢 **Suggestion** — an improvement with no defect behind it.

**Blocking severity needs a demonstration, not a defensible reading.** A 🔴 or
🟡 names the input or state that triggers the defect **and** the consequence.
State both from the code you read, or the finding is 🟢 or nothing. Suspicion,
the size of the change, and which source reported it never raise severity.

**The approval bar.** 🔴 and 🟡 are blocking: they hold the verdict below
`APPROVE` until they are resolved. 🟢 never blocks. Each blocking finding
carries the fix that resolves it, so the bar reads off the findings themselves.

**Blocking findings are complete and uncapped.** Report every 🔴 and 🟡 that
survives verification, however many that is. A first review is the complete
list of what is wrong with the PR.

**🟢 budget per review: 3 when the review carries no 🔴 and no 🟡, otherwise
1.** The budget counts every 🟢 the review prints — `### Findings` and skill
sections together — and keeps the strongest. *Review only:* what it dropped is
counted in `### Summary`, `_N suggestion(s) dropped under the 🟢 budget._`, so
a section that reported 🟢 never reads as clean.

**One finding carries every location.** A finding merged by the sibling sweep
([review.md](review.md) → **Sibling sweep**) names each location in its text
and lists them all in `also` ([review.md](review.md) → **Summary body
format**), so one entry never reads as one site.

**Concise by default (all reviews, all channels):**

- One finding = what is wrong, why it matters, where — in 1–2 sentences. No
  essays, no restated diff context, no hedging filler.
- Every 🔴 and 🟡 carries a **Fix:** line: the remedy that resolves the
  finding, in 1–2 sentences, stated as a rule for the whole defect class, with
  its scope named when more than one place is affected. A finding whose remedy
  you cannot state is not verified — drop it. *Review only:* the Fix line sits
  with the description (the inline comment when the finding is inline-carried,
  `### Findings` otherwise), above any ` ```suggestion ` block.
- Findings anchor to this PR's diff. A pre-existing problem spotted in passing
  is at most one 🟢 line suggesting a separate issue.
- 🟢 only when the improvement is substantial. Style nits, micro-refactors and
  "consider…" filler are dropped entirely, not demoted.
- *Review only:* `✅ Looks good` — at most one bullet, only when it carries
  real information (a risky-looking change verified safe), never filler. None
  on re-reviews.
- *Review only:* `### Summary` stays 1–2 sentences.
