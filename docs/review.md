# Reviewing a PR

Read this file when the worklist's `read_set` names it — `reviews_due`,
`mentions_due` or `ci_failures_due` non-empty — or before an on-demand review.
Preflight decided; you act. `scripts/review-pr.sh` performs the mechanical
steps, and its two HEAD-freshness checks plus the pre-post dedup re-check guard
the window between preflight and post time. The cases a first review rarely
meets have their own files, read on their trigger:
[review-rereview.md](review-rereview.md),
[review-urgent.md](review-urgent.md),
[review-bookkeeping.md](review-bookkeeping.md),
[review-on-demand.md](review-on-demand.md) and
[review-mechanics.md](review-mechanics.md).

## Per-PR review sequence (`reviews_due`)

Every `review-pr.sh <cmd>` below is `cd "$HOME" && bash
"$HOME/scripts/review-pr.sh" <cmd>`. Each call prints one JSON `outcome`: judge
the call by it, never by the exit status. Write the payload files (`body.md`,
`findings.json`, `comments.json`, `meta.json`, `rapid.md`) in the PR's context
directory, `${TMPDIR:-/tmp}/review-pr-<n>.ctx/`, and pass them by absolute
path — `post` and `abort` delete that directory.

Entry: `{number, head_sha, head_ref, title, author, kind, takeover, prior,
urgent, closed}`, plus `eta_seconds` under `review_progress: enabled`. `kind`
is `first` or `re-review`; `prior` holds the last review's
`{sha, ts, verdict}`. Keep the worklist order — urgent entries come first.
Finish one PR, inside its hold, before the next ([runbook.md](runbook.md) →
**Review run**, step 5).

a. **Prepare** — `review-pr.sh prepare <n>` (`--eta <seconds>` under
   `review_progress: enabled`, `--on-demand` for an on-demand review). Check 1
   against the live PR gives `outcome`:
   - `skip` — draft; closed, unless a `RAPID` lock still owes the full review
     (mode `closed`, [review-urgent.md](review-urgent.md) → **PR closed
     mid-review**); a `re-review` whose trigger is gone.
   - `stand_down` — a live holder owns the PR
     ([review-mechanics.md](review-mechanics.md) → **Live holder**).
   - `error` — retry once, then move on; no lock was written.
   - `ready` — it writes the `in_progress` lock row, logs `locked`, writes the
     progress status, fetches context and the diff into `$PR_DIR.diff` with a
     hunk index, clones the branch with its base ref ([skills.md](skills.md) →
     **Clone, credential helper, cleanup**), and renders the per-skill copies,
     briefs, context pack and risk prescan.

   The live trigger follows `rereview_trigger` and sets the scope: label →
   `full: true`, else delta ([review-rereview.md](review-rereview.md) →
   **Re-review output**). The JSON also carries `kind`, `full`, `urgent`,
   `prior`, `files[]`, `skills{}`, `delta`, `profile_slice`, `history_slice`,
   `memory_due`, `structure_changed` and `paths`. `urgent: true` → **phase 1**
   ([review-urgent.md](review-urgent.md) → **Urgent PRs**) before step b.
b. **Orient** — read `memory_due`, `profile_slice` and `history_slice`
   ([profile.md](profile.md)); a `verify_live` row means read the live file,
   not the row. A non-null `carry` is a first review a HEAD move discarded —
   its findings are this review's starting point: read
   [review-rereview.md](review-rereview.md) → **Carried review after a HEAD
   move**. `paths.pack` lists per changed code file its dependents, its
   tests and its changed lines; `paths.context` holds the PR context
   (**PR context**); `paths.risk` names the changed files in sensitive areas
   and the added lines that ask for a second look — orientation, never
   evidence ([profile.md](profile.md) → **What it is, and is not**).
c. **Review the diff** — file by file in `files[]` order: classes `code`,
   `test`, `docs`, `config`. Read each entry's `diff` — that file's own section
   of `$PR_DIR.diff` — once; the whole diff stays for the tools. The noise
   classes (`lockfile`, `snapshot`, `build`, `vendored`, `minified`,
   `sourcemap`, `generated`) carry no `diff`, are not reviewed as code and get
   one `### Summary` line:
   `_<N> generated/lockfile file(s) not reviewed: <paths, or the classes when more than five>._`
   Read what does not depend on an earlier result in one call: several
   slices, `context` and `sweep` lookups, `grep` and `sed -n` of the clone go
   into one Bash command or into parallel tool calls of one response.
   Then `review-pr.sh guard <n>` (**Guarding a running review**).
d. **Run every configured review skill** per [skills.md](skills.md):
   `review-pr.sh step <n> "fanned out (n=<N>)"`, one subagent per skill with
   status `run`, then `review-pr.sh collect <n>` for the audit lines, form
   warnings and `skill_timing`. Verify every blocking finding, yours and the
   skills' (**Full-file verification**), sweep siblings (**Sibling sweep**),
   then `review-pr.sh step <n> verified`. On a re-review,
   `review-pr.sh delta <n> <ctx>/findings.json` classifies your findings against
   `prior_findings` and returns the `### Changes since last review` block and
   `annotated` — your array with every `status` filled in
   ([review-rereview.md](review-rereview.md) → **Re-review output**).
e. **Compose** — `review-pr.sh compose-brief <n>` prints this PR's contract: the
   `body.md` skeleton with its header, its `### Changes since last review` line
   and its skill sections in table order, the `findings.json`, `meta.json` and
   `comments.json` rules quoted from their home in
   [review-mechanics.md](review-mechanics.md), this PR's paths, overrides and
   memory rules, and anything the conversation added since the lock (**Guarding
   a running review**). Write `body.md` (`### Summary` … `### Verdict` —
   **Output format**), `findings.json` (a re-review posts delta's `annotated`
   file), `meta.json` and, for inline-carried findings, `comments.json`
   (`[{path, line, side, body[, start_line]}]`, each `body` the full text). Then
   `review-pr.sh step <n> composed`, and output the review to the chat UI.
f. **Post** — `review-pr.sh post <n> --verdict <VERDICT> --body <ctx>/body.md
   --findings <ctx>/findings.json [--comments <ctx>/comments.json] [--meta
   <ctx>/meta.json]`, as `compose-brief` prints it; a re-review passes
   `--findings <ctx>/findings.annotated.json`. It
   runs Check 2 and the dedup re-check, maps each inline comment against the
   hunk index (outside a hunk or past the cap of 25 → moved under
   `### Findings not anchorable inline`, `inline: false` in `findings-json`),
   posts the payload ([review-mechanics.md](review-mechanics.md) → **Posting
   the GitHub review**), removes
   `$REREVIEW_LABEL`, dismisses a stale approval, appends the body to
   `reviews/pr-<n>.md`, writes the `done` row and terminal status, logs
   `posted <verdict>` and `done`, and deletes clone, copies, diff and state —
   exactly once. Outcomes: `posted` (`url`, `moved_to_summary`,
   `anchors_nulled`, `label_removed`, `dismissed_approval`) · `aborted`
   (**Error handling**) · `duplicate` (the marker is already on GitHub; the row
   self-heals with its timestamp) · `closed_*` (read
   [review-urgent.md](review-urgent.md) → **PR closed mid-review**). Then
   evaluate the configured watch rules ([watches.md](watches.md)), and under
   `ci_triage: enabled` triage a failing check on the posted SHA
   ([ci-triage.md](ci-triage.md)).
g. **Any other end of a PR** — a transient failure after its retry, a decision
   not to post — `review-pr.sh abort <n> <reason>` (**Error handling**).

Every entry ends `posted`, `duplicate`, `closed_filed`, `closed_discarded` or
`aborted`.

**Progress logging.** Each milestone appends a `review_step` event
([logging.md](logging.md)). The last event of a PR pins where a stall stopped;
consecutive timestamps give per-step durations.

- `review-pr.sh` writes them as it performs them: `locked`, `cloned`
  (`prepare`) · `locked (refresh, …)`, `fanned out (n=<N>)`, `verified`,
  `composed` (`step`) · `delta settled (…)` (`delta`) · `rapid posted`
  (`rapid`) · `posted <verdict>`, `done` (`post`) · `aborted <reason>`
  (`post` / `abort`). The adapter hook derives `skill:<name> done`
  ([logging.md](logging.md) → **Harness adapters**).
- `fanned out (n=<N>)` goes immediately before the fan-out, `verified`
  immediately after verification, `composed` once body and findings are
  written. With `delta settled (…)` they bound one duration per phase: the
  diff review, the skills with their verification, the delta round, the
  compose, and the post. Per-skill durations come from `skill_timing`
  ([skills.md](skills.md) → **Invocation & audit log**).
- In the manual fallback the hook still derives `cloned`, `posted <verdict>`,
  `locked` / `done` / `aborted (lock released)` from the commands that perform
  them ([review-mechanics.md](review-mechanics.md) → **Review tracking
  state**). The rest is yours, chained onto the step's own command:

  ```bash
  . "$HOME/scripts/log.sh" && LOG_JOB=review logev info review_step "PR #<n> <sha-short> <step>"
  ```

- Log a step you are unsure about — duplicates are harmless, a missing event is
  invisible to the `Stop` hook and reads as a review that never finished. The
  filename and `msg` shape are a contract ([logging.md](logging.md) →
  **The shape is a contract**).

**Lock heartbeat.** Before each of steps d, e and f,
`review-pr.sh step <n> "<milestone>"` rewrites the PR's REVIEWS.md row
with the **current** UTC time (same fields, status stays `in_progress`) and
logs `locked (refresh, …)`: `fanned out (n=<N>)` before step d, `verified`
before step e and `composed` before step f. The timestamp is the age preflight
measures and the event is the liveness signal it reads
([review-mechanics.md](review-mechanics.md) → **Live holder**), so a
review that refreshes never crosses the TTL.

**Completion enforcement.** The `Stop` hook reads these events back at end of
turn: a PR logged `locked` this run with no later `done` / `aborted <reason>`
is a turn ending mid-pipeline, so the hook refuses the stop and names the PRs,
their last step, and what is still owed. `rapid posted` and `skill:<name> done`
are **not** terminal. It blocks up to **3 times per run**, the last attempt
leading with the explicit-abort route, then allows the stop and logs
`enforcement exhausted`. It makes no GitHub calls and no state writes, and is
never a reason to pad review content.

## PR context: body, comments, reviews

`prepare` fetches them into `paths.context` (`context.json`: `body`,
`comments`, `reviews`, `inline` threads; every item with `author`, `is_bot` and
its timestamp, your own marker-carrying artefacts dropped). A fetch that did
not respond leaves an empty list and a logged warning — review more
conservatively then. Context is input, not authoritative truth:

1. **Body** — feeds the Summary. A pattern it explicitly justifies is not
   flagged.
2. **Top-level comments** — an issue with an accepted author/maintainer
   justification is not re-raised. Still argued → surface it.
3. **Review summaries** — note `APPROVED` and open `CHANGES_REQUESTED`;
   requested changes still in the diff → surface them.
4. **Inline threads** — resolved on the same file/line → suppress overlapping
   findings; unresolved → consider whether yours adds anything.

**A human dismissal settles the finding for this PR.** An author or maintainer
reply stating the behavior is intended — accepted, by design, will not change —
closes the finding it answers. Record it under `## PR-local overrides` before
you post ([preferences.md](preferences.md) → **Route feedback by scope**);
every later review of this PR then reads that behavior as correct, in every
section and at every severity. A reply that argues without settling is context.

**Weight humans over bots** (`is_bot`) unless a human endorsed the bot's claim.
Anything holding `<!-- <review_marker> headRefOid=... -->` is your past self,
not context.

**Learn while you read.** Context revealing a generalizable team convention or
a recurring human-reviewer concern is recorded after posting, per
[preferences.md](preferences.md) → **Observed insights** — at most 2 per PR.

**Audit note** — when suppressing, append to `### Summary`:
`_(Suppressed N finding(s) per PR-local overrides: <ids>. Suppressed M finding(s) per PR context: <ids>. Suppressed K finding(s) per in-tree decisions: <ids> — <in-tree document path(s)>.)_`
Omit each part at count zero. The decisions part names the document that
settled each finding, so the record the check read is on the review itself.
Count a finding here only when the review does not print it; one reported as 🟢
is posted, not suppressed. The audit counts
this line ([audit.md](audit.md) task 31), so a suppressed finding is recorded
here and nowhere else.

## Criteria & review style

Unless preferences say otherwise: **Correctness** (logic, off-by-one, null
risks, races) · **Security** (injection, credential leaks, OWASP top 10) ·
**Performance** (allocations, N+1, missing indexes) · **Architecture**
(coupling, layer boundaries, broken contracts) · **Tests** (missing coverage,
flaky patterns) · **Maintainability** (dead code, error handling) ·
**Delivery** (a breaking change in an env var, a CLI flag, a config key or a
migration; a CI step that does not run what the change needs; a runtime
assumption about paths, permissions, time zone or the concurrency model). The
profile's `## Checks` rows say what CI runs, as orientation only
([profile.md](profile.md) → **What it is, and is not**). Past 2000 diff lines:
focus on the most critical files, still post a full review.

**Audience: agent-written, agent-read code.** Human readability is not a review
goal. Flag naming taste, cosmetic structure, comment density, file layout and
"this would be clearer as…" restructuring **only** where they create a real
defect risk — a misleading name that hides a bug, dead code that changes
behavior, an abstraction that breaks its contract. Never request restructuring
for human readers alone.

**Full-file verification** — end of step d: **every blocking finding, your
candidates from step c and the skills'**, verified before you compose. The diff
or the skill nominates it; the surrounding code confirms it. Re-check each with
`review-pr.sh context <n> <path> <line> [radius]`, which prints **numbered
source text** (±40 lines by default) and whether the line lies inside this PR's
hunks — `no` marks a pre-existing problem, at most one 🟢 line. Read the whole
file only when that range leaves the question open. Anchor every survivor on
the line its **Fix:** changes, read off that numbered output. What does not
clear the severity bar ([finding-form.md](finding-form.md)) is dropped when it
is your own candidate and **regraded to 🟢 when a skill reported it** — a skill
finding is never deleted. A false positive costs more credibility than a missed
nit. No clone (`clone-failed`) → verify against the diff context you have.

**Decision check** — same pass, for every surviving 🔴/🟡 that disputes a design
choice: an architecture, a protocol, a boundary, a trade-off. Read the in-tree
document that covers the changed path — the `profile_slice`'s `## Decisions`
and `## Docs` rows locate it, the copy in the clone is the evidence. No row
covers the path, or there is no profile at all ([profile.md](profile.md)) →
search the clone for a document under that path; find none and the finding
stands. A document that states the disputed behavior as intended settles the
finding: drop it when it is your own candidate, **regrade it to 🟢 when a skill
reported it** — the same rule as verification above. Either way cite the
document, and a 🟢 names the gap the document leaves. A document the diff
contradicts is a claim-sweep finding instead. Count each finding the check
settled in the audit note (**PR context**); the document is the record, so no
memory entry is written.

**Sibling sweep** — same pass. For each surviving 🔴/🟡, check the files this PR
changes for more occurrences of the same defect class:
`review-pr.sh sweep <n> '<regex>'` returns the hits in changed files and a
count in untouched code. Report them as **one** finding listing every location,
so one fix round closes the class, and carry those locations in the finding's
`also` ([review-mechanics.md](review-mechanics.md) → **Summary body format**).
An occurrence in untouched code is a
pre-existing problem ([finding-form.md](finding-form.md)). On a delta
re-review both passes cover only the files changed since the prior review, the
claim sweep excepted.

**Claim sweep** — for a finding whose class is *an in-tree statement about X is
false or incomplete*, the siblings sit outside the diff by construction, so the
sweep covers the whole clone: `review-pr.sh sweep <n> '<regex>' --tree` returns
each hit with its location. Read every hit that states the same rule —
architecture pages, glossary, README, chart and config comments, CLI and tool
descriptions, the PR body — and report the contradicted ones as **one** finding
carrying every location. A hit the diff does not contradict is not a finding.
The command that ran the sweep is this finding's `checks` entry
([review-mechanics.md](review-mechanics.md) → **Summary body
format**). The claim sweep is never narrowed to the delta range.

**Language: ASD-STE100 (Simplified Technical English).** Write every outward
text — reviews, inline comments, issues, mention replies, chat, Slack — in STE
style: one topic per sentence, active voice, simple tenses, one term per
concept, no idioms, no synonym variation. STE governs wording, never content.

**The sentence bar is 20 words.** Before you post, read your own prose back and
split every sentence above it; a sentence that carries two clauses about two
subjects becomes two sentences. Every posted review is measured against it
([audit.md](audit.md) task 32), and so is every benchmark run
([benchmark.md](benchmark.md)); the measurement reads prose only
(`scripts/lib/ste.sh`), and its 15 % threshold marks a week that regressed, not
the bar you write to.

**Finding form.** Every finding — yours or a skill's — follows
[finding-form.md](finding-form.md).

## Output format (first reviews)

```
## PR #<number>: <title>
**Author:** <login> | **Branch:** <head> → <base> | **Changes:** +<additions> −<deletions> (<files> files)

### Summary
<1-2 sentence summary of what the PR does>
_Limits: <what this review could not read>._

### Findings
<findings, per finding-form.md>
- ✅ **Looks good:** <description>

### <section — one per configured review skill that ran, in table order>
<that skill's findings, per finding-form.md (or its clean-run line)>

### Verdict
<APPROVE / REQUEST_CHANGES / COMMENT> — <one sentence justification>

### For the human reviewer
<3-4 plain sentences; only when a design decision drives a blocking finding>
```

`### Findings` is the canonical, complete list on first reviews, and it **never
repeats inline text**: an inline-carried finding appears here as one line —
severity + short label + `file:line` — while its description, rationale and
suggestion block live only in the inline comment. Summary-only findings keep
their full text here. One format for every channel (chat UI, GitHub body,
history file); the one-liners carry the next re-review's delta matching.

**`_Limits: …_`** — the conditions this review ran under, as facts, never a
score or a confidence: a clone that failed, a skill that did not run, a PR
context that did not load, a diff past 2000 lines.
`review-pr.sh compose-brief` composes the line from this run's own state and
prints it in the skeleton — nothing to report, no line — and `post` refuses a
body that drops it.

**`### For the human reviewer`** — the last section, written when a blocking
finding comes from a design decision of the PR itself. Three or four sentences
of plain English, no jargon, for a person who reads nothing else: what the PR
decided, what that decision puts at risk, and what to settle before the single
fixes matter. Name concepts, never files, lines, symbols or severities. It
judges nothing new — every claim in it is a finding the review already made,
and it is the one text addressed to a person.

## Merging findings across sources

Your diff review and every skill section report into one review, so the same
defect can arrive twice. Compose from all of them together:

- **One defect, one finding.** The same defect class at the same location from
  two sources appears **once**: keep the strongest severity, merge the
  locations into that entry, name the reporting sources in the description.
- Its home is the strongest place it qualifies for — `### Findings` plus an
  inline comment when it maps inline, else the section of the first reporting
  skill in table order.
- A blocking finding that stays in a skill section is mirrored into
  `### Findings` as one line with its **Fix:**, so the bar stays complete.
- **Merging drops duplicates, never findings.** A defect from one source always
  survives; 🔴 and 🟡 are uncapped, 🟢 survive within their budget
  ([finding-form.md](finding-form.md)). Each skill keeps its own
  `findings=<N>` audit line whatever the merge prints ([skills.md](skills.md)).

## Guarding a running review

The live HEAD is re-read at each phase boundary, and a review whose HEAD moved
stops at the first boundary past the move.

- **Where.** `collect`, `delta` and `compose-brief` guard themselves; the end
  of the diff review has no command of its own, so call `review-pr.sh guard
  <n>` there. Check 1 and Check 2 bracket the sequence.
- **`outcome: "head_moved"`** — the lock is released per kind, clone and state
  are deleted, and the work is carried ([review-rereview.md](review-rereview.md)
  → **Carried review after a HEAD move**).
  `carried` says whether there were findings to carry; a move before the first
  finding carries the hop and run counters alone.
- **`restart: true` → `prepare` the PR again in this run** and review the new
  HEAD from the top. **`restart: false`** — this run already restarted this PR
  — move to the next worklist entry and leave the PR to the heartbeat.
- **Only a complete finding set is carried:** `delta` and `post` carry theirs
  unasked, the earlier guards carry the counters.
- An unreadable API leaves the review running; Check 2 still gates the post.

**A comment or an edited description never discards the work.**
`compose-brief` re-reads the body, comments and reviews, rewrites
`paths.context` and names what moved; fold it into the review you are about to
write. Inline threads are not re-read — they hang off the diff at the guarded
SHA.

## Applying PR-local overrides

**Strictly scoped to their own PR.** Reload the list per PR, discard it before
the next. Suppress candidate findings matching an entry — same file plus
overlapping line, or the same backticked symbol in an entry naming the file
(`` `query()` `` in the finding, `` `query()` `` + `` `src/a.ts` `` in the
override) — and add the Summary audit note. Overrides only suppress, never add;
code that moved past its override lets the finding surface normally.

## Error handling

- **Transient tool failure** (context fetch, clone, skill run, post — network
  error, timeout, 5xx, rate limit) → **retry once**, then abort the PR.
  `review-pr.sh` does this for its own calls; a failure in your own steps ends
  the PR with `review-pr.sh abort <n> <reason>`. Either path releases the lock
  per kind — `first` deletes the row, `re-review` restores the prior row —
  deletes clone and state, writes the abort status, and logs
  `aborted <reason>`. Log
  `PR #<n>: <step> failed after retry — aborted, lock released` in the chat UI
  and continue with the next PR. Never leave an `in_progress` lock behind, and
  never retry a call twice: the next heartbeat picks the PR up fresh.
- **Abort also on** a HEAD that moved, a PR gone draft, a withdrawn re-review
  trigger, or a dedup check unreadable after its retry. A phase guard reports
  the HEAD move as `head_moved`, not `aborted` (**Guarding a running review**).
- **422 line-not-in-diff** → `post` moves every inline comment to the summary
  and retries the POST once (`moved_to_summary`, reason
  `422 line not in diff`); note the moved comments once in the chat UI.
- **422 commit_id mismatch** → HEAD moved: `post` aborts as a Check 2 failure.

## Review-run self-check

Before you declare the run done:

- **Per reviewed PR, mechanical** — chain `&& review-pr.sh verify <n>` onto
  the PR's last `review-pr.sh` command: `post`, `abort`, or the one that
  returned `head_moved`. It checks the last lock cycle's terminal step,
  milestones, `skill_timing`, row, history file, ledger and cleanup in one
  call. `ok` settles those lines; every `fail` check of `issues` names what to
  repair; `not_locked` means this run took no lock on the PR; `error` names the
  lines to check by hand.
- **Per reviewed PR** — one GitHub review carrying the full-SHA marker · Check
  1, Check 2 and the dedup re-check done, the re-review trigger check included
  · row refreshed at each milestone · live holder re-checked before the lock
  write · label removed after a posted review on a labeled PR · skill audit
  lines complete ([skills.md](skills.md)) · overrides applied from that PR's
  file only · context fetched and used, a human
  dismissal in it recorded as an override before posting · observed insights
  recorded ([preferences.md](preferences.md)) · `memory_due` read before
  reviewing · orientation used for where to look only, `verify_live` rows read
  live, no finding citing the profile or the risk prescan
  ([profile.md](profile.md)) · noise files excluded with their Summary line ·
  every blocking finding verified, the
  skills' included, and sibling-swept with its `also` locations, a statement
  finding claim-swept over the clone, a design finding checked against the
  in-tree decision that covers its path and counted in the audit note when it
  settled (**Decision check**) · every open 🔴/🟡 carrying a class-rule
  **Fix:** whose every member is enumerated
  ([finding-form.md](finding-form.md)), mirrored into `findings-json`, with its
  sweep command in `review-meta.checks` and every dropped 🟢 in
  `review-meta.deferred` · every delta `ambiguous` pair settled before the post ·
  every phase guard run and every `head_moved` honoured — restarted once, else
  left to the heartbeat · a compose-time context change folded into the review ·
  every carried finding settled at its anchor and reported as `new`, the carry
  never named · skill sections reformatted and merged with no finding lost ·
  stale approval dismissed when the verdict dropped below APPROVE · every sentence of the posted prose inside the 20-word
  bar (**The sentence bar is 20 words**).
- **Style** — findings concise and diff-anchored, inline text never repeated in
  the summary; every verified 🔴/🟡 reported, 🟢 within budget
  ([finding-form.md](finding-form.md)); re-review scope matched the trigger;
  `### For the human reviewer` written when a design decision drives a blocking
  finding, and free of files, lines and symbols.
- **Watch rules** — evaluated send-then-marker ([watches.md](watches.md)).
- **`ci_triage: enabled`** — every `ci_failures_due` entry and every review
  that ended on a failing check answered post-then-marker
  ([ci-triage.md](ci-triage.md)).
- **`review_progress: enabled`** — every locked PR on a terminal `success`
  status.
- **Every `reviews_due` PR reached a terminal state** — the run never ended
  mid-pipeline, for example after a skill report.
- **Every PR hold this run took is released** (`review-pr.sh release <n>`).
