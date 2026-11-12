# Finding form

The shape every finding takes, whoever writes it — the diff review
([review.md](review.md)), a skill subagent's reformat ([skills.md](skills.md) →
**Invocation & audit log**), the benchmark reviewer
([benchmark.md](benchmark.md)), the survey ([survey.md](survey.md)). Every
rule binds every writer except those marked *review only*, which apply when the
review itself is composed. Wording follows ASD-STE100 ([review.md](review.md)
→ **Criteria & review style**).

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
  data loss. Grade by the worst consequence on that path, not by how likely
  its trigger is. Once the trigger and the consequence are shown, these are
  🔴 whatever condition the trigger needs: a secret or credential written to
  a log or an output; a weakened authentication or cryptographic check; a
  permission wider than the task needs; untrusted input in a shell command, a
  query or a path without escaping; shared state written and read
  concurrently without synchronization; a release or deploy gate that a
  failure can pass; unbounded concurrency or resource use.
- 🟡 **Warning** — a real defect with a bounded blast radius: a conditional
  path, degraded behavior, or changed logic. Usually 🟡: a UI
  state or guard defect that loses no data, a stale cache or memoized value,
  a bounded performance regression.
- 🟢 **Suggestion** — an improvement with no defect behind it. Missing test
  coverage is 🟢 at most: a change with no test, or with a test that does not
  exercise it. A weakened test or gate is a different defect and stays under
  Gate check ([review.md](review.md) → **Gate check**).

**Blocking severity needs a demonstration, not a defensible reading.** A 🔴 or
🟡 names the input or state that triggers the defect **and** the consequence.
State both from the code you read, or the finding is 🟢 or nothing. Suspicion,
the size of the change, and which source reported it never raise severity.

**A defect in text alone blocks only where a reader acts on the text.** A stale
or incomplete statement — an architecture page, a comment, a glossary entry, a
README, the PR body — is 🟡 only when that text is what another party
implements or operates against: a wire or API contract, a security or egress
boundary, an operator procedure, a migration step. Every other statement
defect is 🟢, whoever reported it. A freshness stamp, an enumeration count and
a diagram never block on their own.

**The approval bar.** 🔴 and 🟡 are blocking: they hold the verdict below
`APPROVE` until they are resolved. 🟢 never blocks. *Review only:* any 🔴 →
`REQUEST_CHANGES`, else any 🟡 → `COMMENT`, else `APPROVE` — over your
findings and every skill section together. With
`approve_after_rounds` set ([config.md](config.md)), from that review round of
the PR on: no 🔴 → `APPROVE`. The open 🟡 stay listed with their **Fix:**, and
the verdict sentence names the round limit; `compose-brief` names the round,
and `post` warns on another verdict.

**Blocking findings are complete and uncapped.** Report every 🔴 and 🟡 that
survives verification; a first review is the complete list of what is wrong
with the PR.

**🟢 budget per review: 3 when the review carries no 🔴 and no 🟡, otherwise
1.** The budget counts every 🟢 the review prints — `### Findings` and skill
sections together — and keeps the strongest. A late 🟡 graded 🟢 on a delta
re-review is outside it ([review-rereview.md](review-rereview.md)). *Review
only:* count what it dropped in `### Summary`: `_N suggestion(s) dropped under
the 🟢 budget._`

**One finding carries every location.** A finding merged by a sweep
([review.md](review.md) → **Sibling sweep**) names each location in its text and
lists them all in `also` ([review-mechanics.md](review-mechanics.md) → **Summary
body format**). A **Fix:** that reads as a rule — *every*, *each*, *all* —
carries that complete list; cannot enumerate → narrow the **Fix:** to the
locations you verified.

**A predicate finding names its grammar, not its shapes.** When the defect is
an incomplete predicate, allowlist or parser over a format — a block that
passes as pure, a line kind the mapping drops — the **Fix:** names the
format's every line or token kind and says: accept only what the mapping
uses, treat the rest as free text. The shapes you found are examples in the
description, never the list the fix works. Its `checks` entry `clean` names
every kind with the mapping field it reaches or `free text`.

**Concise by default (all reviews, all channels):**

- One finding = what is wrong, why it matters, where — in 1–2 sentences. No
  essays, no restated diff context, no hedging filler.
- Every 🔴 and 🟡 carries a **Fix:** line: the remedy, in 1–2 sentences,
  stated as a rule for the whole defect class, its scope named when more than
  one place is affected. A finding whose remedy you cannot state is not
  verified — drop it. *Review only:* the Fix line sits with the description
  (the inline comment when inline-carried, `### Findings` otherwise), above
  any ` ```suggestion ` block — `post` refuses an inline-carried finding's Fix
  line in `### Findings`.
- Findings anchor to this PR's diff. A pre-existing problem spotted in passing
  is at most one 🟢 line suggesting a separate issue.
- 🟢 only when the improvement is substantial. Style nits, micro-refactors and
  "consider…" filler are dropped entirely, not demoted.
- *Review only:* `✅ Looks good` — at most one bullet, only when it carries
  real information (a risky-looking change verified safe), never filler. None
  on re-reviews.
- *Review only:* `### Summary` stays 1–2 sentences.
