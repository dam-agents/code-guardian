# Reviewing a PR

Read this file when the worklist's `read_set` names it — `reviews_due`,
`mentions_due`, `ci_failures_due` or `fixes_due` non-empty — or before an
on-demand review. `scripts/review-pr.sh` performs the mechanical steps and the
guards. **The review itself is yours:** every finding, its verification, its
severity and the verdict come from your own reading of the code. A command's
output — the risk prescan, a `sweep` hit, a noise class, a `delta` match — is
a lead: read the code it points at before it adds, drops or changes anything
in the review. Rare cases, read on their trigger:
[review-rereview.md](review-rereview.md), [review-urgent.md](review-urgent.md),
[review-bookkeeping.md](review-bookkeeping.md),
[review-on-demand.md](review-on-demand.md); the posted payload and the
tracking state: [review-mechanics.md](review-mechanics.md).

## Per-PR review sequence (`reviews_due`)

Every `review-pr.sh <cmd>` below is `cd "$HOME" && bash
"$HOME/scripts/review-pr.sh" <cmd>`. Each call prints one JSON `outcome`: judge
the call by it, never by the exit status (0 on every outcome); the other
fields come only with the expected outcome. Write the payload files
(`body.md`, `findings.json`, `comments.json`, `meta.json`, `rapid.md`) in
`${TMPDIR:-/tmp}/review-pr-<n>.ctx/` and pass them by absolute path (cleanup:
[skills.md](skills.md) → **Clone, credential helper, cleanup**). Work the
entries one PR at a time, inside its hold, in the order of
[runbook.md](runbook.md) → **Review run** step 5; `prepare` reads the live PR
and takes from the entry only the `number` and, under `review_progress:
enabled`, `eta_seconds`.

a. **Prepare** — `review-pr.sh prepare <n>` (`--eta <eta_seconds>` under
   `review_progress: enabled`, `--on-demand` for an on-demand review). Check 1
   against the live PR gives `outcome`:
   - `skip` — a draft without a review label
     ([worklist.md](worklist.md) → **The pre-flight contract**); closed, unless
     a `RAPID` lock still owes the full review (mode `closed`,
     [review-urgent.md](review-urgent.md) → **PR closed mid-review**); a
     `re-review` whose trigger is gone; an on-demand ask at an already-reviewed
     HEAD.
   - `stand_down` — another live run holds the PR or owns its review
     ([worklist.md](worklist.md) → **PR holds**,
     [review-mechanics.md](review-mechanics.md) → **Live holder**). A run
     without the PR's hold gets it from `prepare`.
   - `error` — retry once, then move on; no lock was written.
   - `ready` — lock row written and `locked` logged, progress status written,
     context and diff fetched (`$PR_DIR.diff`, with a hunk index), branch
     cloned with its base ref, per-skill worktrees, briefs, context pack and
     risk prescan rendered.

   The live trigger (`rereview_trigger`, `rereview_delta_label`, an unseen
   `guide_label`, a guide this head owes — [artifact.md](artifact.md) →
   **Review guide**) sets the scope ([review-rereview.md](review-rereview.md)
   → **Re-review output**). The JSON also carries `kind`, `full`, `urgent`,
   `prior`, `prior_findings`, `carry`, `delta`, `files[]`, `skills{}`,
   `profile_slice`, `history_slice`, `memory_due`, `structure_changed`,
   `rapid_posted` and `paths`. `urgent: true` without `rapid_posted` →
   **phase 1** ([review-urgent.md](review-urgent.md) → **Urgent PRs**) first.
b. **Orient** — read `memory_due`, `profile_slice` and `history_slice`
   ([profile.md](profile.md)); a `verify_live` row means read the live file.
   A non-null `carry` is the starting point ([review-rereview.md](review-rereview.md)
   → **Carried review after a HEAD move**). `paths.pack` lists per changed code
   file its dependents, tests and changed lines; `paths.context` holds the PR
   context (**PR context**); `paths.risk` names the changed files in sensitive
   areas, the added lines that ask for a second look and the weakened gates —
   orientation, never evidence ([profile.md](profile.md) → **What it is, and
   is not**).
c. **Review the diff** — answer every `gates[]` hit first (**Gate check**),
   then file by file in `files[]` order: classes `code`, `test`, `docs`,
   `config`. Read each entry's `diff` (its section of `$PR_DIR.diff`) once.
   The noise classes (`lockfile`, `snapshot`, `build`, `vendored`, `minified`,
   `sourcemap`, `generated`) carry no `diff`, are not reviewed as code and get
   one `### Summary` line:
   `_<N> generated/lockfile file(s) not reviewed: <paths, or the classes when more than five>._`
   The class comes from the path: check it against each noise file's diff
   stat, and review hand-written code under a noise path as code. A lockfile
   that changes with no changed manifest beside it, or that changes a package
   source or registry host, gets its diff read under the **Security**
   criteria. Batch independent reads — slices, `context` and `sweep` lookups,
   `grep` and `sed -n` of the clone — into one Bash command or parallel tool
   calls. Read every file from the security view too, with or without a
   security skill: untrusted input reaching a query, a shell, a path or a
   template; a secret in code, a log or an error; an authorization check
   removed or skipped; a permission or exposure widened. Then `review-pr.sh
   guard <n>` (**Guarding a running review**).
d. **Run every configured review skill** per [skills.md](skills.md):
   `review-pr.sh step <n> "fanned out (n=<N>)"`, one subagent per skill with
   status `run`, then `review-pr.sh collect <n>`. Verify every blocking
   finding, yours and the skills' (**Full-file verification**), sweep
   siblings (**Sibling sweep**), then `review-pr.sh step <n> verified`. On a
   re-review, `review-pr.sh delta <n> <ctx>/findings.json` classifies your
   findings against `prior_findings` ([review-rereview.md](review-rereview.md)
   → **Re-review output**).
e. **Compose** — `review-pr.sh compose-brief <n>` prints this PR's contract:
   the `body.md` skeleton, the `findings.json`, `meta.json` and
   `comments.json` rules quoted from [review-mechanics.md](review-mechanics.md),
   this PR's paths, overrides and memory rules, and what the conversation
   added since the lock (**Guarding a running review**). Write `body.md`
   (**Output format**), `findings.json`, `meta.json` and, for inline-carried
   findings, `comments.json` (`[{path, line, side, body[, start_line]}]`, each
   `body` the full text). A `## Review guide` block in the brief → follow it
   and write the guide's one-line section, else drop the section
   ([artifact.md](artifact.md) → **Review guide**). Then `review-pr.sh step <n>
   composed`, and output the review to the chat UI.
f. **Post** — `review-pr.sh post <n> --verdict <VERDICT> --body <ctx>/body.md
   --findings <ctx>/findings.json [--comments <ctx>/comments.json] [--meta
   <ctx>/meta.json] --model <id>` as `compose-brief` prints it — `<id>` is this
   session's exact model id; a re-review passes `--findings
   <ctx>/findings.annotated.json`. It checks the body and findings against the
   format rules below (a mismatch → `outcome: "warnings"`, nothing posted),
   runs Check 2 and the dedup re-check, maps the inline comments
   ([review-mechanics.md](review-mechanics.md) → **Mapping findings to inline
   comments**), posts, removes the served triggers
   ([review-bookkeeping.md](review-bookkeeping.md) → **Trigger removal**),
   dismisses stale approvals, appends the body to `reviews/pr-<n>.md`, writes
   the `done` row and terminal status, logs `posted <verdict>` and `done`, and
   deletes clone, copies, diff and state — exactly once. Outcomes: `posted`
   (`url`, `event`, `moved_to_summary`, `anchors_nulled`, `warnings`,
   `label_removed`, `dismissed_approval`) · `warnings` · `aborted` (**Error
   handling**) · `duplicate` (the marker is already on GitHub; the row
   self-heals with its timestamp) · `closed_*`
   ([review-urgent.md](review-urgent.md) → **PR closed mid-review**). Then
   evaluate the watch rules ([watches.md](watches.md)) and, under `ci_triage:
   enabled`, triage a failing check on the posted SHA
   ([ci-triage.md](ci-triage.md)). A `draft: true` entry ends at the post
   ([worklist.md](worklist.md) → **The pre-flight contract**).
g. **Any other end of a PR** — a transient failure after its retry, a decision
   not to post — `review-pr.sh abort <n> <reason>` (**Error handling**).

Every locked entry ends `posted`, `duplicate`, `closed_filed`,
`closed_discarded`, `aborted`, `head_moved` or `state_damaged`. `warnings` is
a holding state: the lock and files stay until you rerun `post` with the files
fixed, rerun it with `--accept-warnings` to post them as they are, or run
`abort`.

**Progress logging.** Each milestone appends a `review_step` event
([logging.md](logging.md)); the last one pins where a stall stopped.

- `review-pr.sh` writes `locked`, `cloned` (`prepare`) · `locked (refresh,
  …)`, `fanned out (n=<N>)`, `verified`, `composed` (`step`) · `delta settled
  (…)` (`delta`) · `rapid posted` (`rapid`) · `posted <verdict>`, `done`
  (`post`) · `aborted <reason>` (`post`, `abort`, the phase guards). The
  adapter hook derives `skill:<name> done`
  ([harness-claude-code.md](harness-claude-code.md) → **Adapter**).
- Consecutive milestones bound one duration per phase (prepare, diff review,
  skills with their verification, delta, compose, post); per-skill durations
  come from `skill_timing` ([skills.md](skills.md) → **Invocation & audit
  log**).
- In the manual fallback the hook still derives `cloned`, `posted <verdict>`,
  `locked` / `done` / `aborted (lock released)` from the commands that perform
  them ([review-mechanics.md](review-mechanics.md) → **Review tracking
  state**). Log the rest yourself, chained onto the step's own command:

  ```bash
  . "$HOME/scripts/log.sh" && LOG_JOB=review logev info review_step "PR #<n> <sha-short> <step>"
  ```

- Log steps only for a PR this run locked; when unsure, log — a duplicate is
  harmless. The filename and `msg` shape are a contract
  ([logging.md](logging.md) → **The shape is a contract**).

**Lock heartbeat.** Each `review-pr.sh step <n> "<milestone>"` (steps d and
e) rewrites the PR's REVIEWS.md row with the **current** UTC time (same
fields, status `in_progress`) and logs `locked (refresh, …)` — the holder's
liveness ([review-mechanics.md](review-mechanics.md) → **Live holder**).

**Completion enforcement.** At end of turn the `Stop` hook refuses the stop
while a PR logged `locked` this run has no later `done` / `aborted <reason>`,
naming the PRs, their last step and what is still owed (`rapid posted` and
`skill:<name> done` are **not** terminal). It blocks up to **3 times per
run**, the last attempt leading with the explicit-abort route, then allows the
stop and logs `enforcement exhausted`. It makes no GitHub calls and is never a
reason to pad review content.

## PR context: body, comments, reviews

`prepare` fetches them into `paths.context` (`context.json`: `body`,
`comments`, `reviews`, `inline` threads; every item with `author`, `is_bot` and
its timestamp, your own marker-carrying artefacts dropped). A fetch that did
not respond leaves an empty list and a logged warning — review more
conservatively then. Context is input, not authoritative truth:

1. **Body** — feeds the Summary. A pattern it explicitly justifies is not
   flagged. Each entry of its hidden `<!-- author-decisions … -->` block is
   such a justification for its `scope`: a finding that only disputes that
   choice is not raised; a defect the entry's `why` does not cover still is.
   An entry never settles a `critical` finding: report it with the entry
   named in its description. A `Reviewer guide` section is the author's map:
   start where it points, check that its claims hold, let it justify nothing.
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
Omit each part at count zero. Count a finding only when the review does not
print it (one reported as 🟢 is posted, not suppressed). This line is the only
record of a suppressed finding; the audit counts it ([audit.md](audit.md)
task 31).

## Criteria & review style

Unless preferences say otherwise: **Correctness** (logic, off-by-one, null
risks, races) · **Security** (injection, credential leaks, OWASP top 10) ·
**Reliability** (an external call with no timeout or error handling, a retry
that is not idempotent, a swallowed error, a multi-step operation that a
failure leaves half-applied) · **Performance** (allocations, N+1, missing
indexes, an unbounded loop over input, blocking I/O on a hot path, no
pagination) · **Architecture** (coupling, layer boundaries, broken
contracts) · **Tests** (missing coverage, flaky patterns) · **Maintainability** (dead code, error handling) ·
**Delivery** (a breaking change in an env var, a CLI flag, a config key or a
migration; a CI step that does not run what the change needs; a runtime
assumption about paths, permissions, time zone or the concurrency model). The
profile's `## Checks` rows say what CI runs, as orientation only. Past 2000
diff lines: focus on the most critical files, still post a full review.

**Escaped defect classes** — each line under `## Escaped Defect Classes` in
`work/MEMORY.md` and the `memory_due` files is a class that already failed in
a running environment ([escapes.md](escapes.md)): apply its check to every
changed hunk it can match. A hit is graded like any finding.

**Audience** — the `Audience:` line of `work/MEMORY.md` → `## Review Style`;
no line = `agent-written, agent-read code`. For agent-read code, flag naming
taste, cosmetic structure, comment density, file layout and "this would be
clearer as…" restructuring **only** where they create a real defect risk — a
misleading name that hides a bug, dead code that changes behavior, an
abstraction that breaks its contract. Any other audience (`people read and
maintain this code`) makes them **Maintainability** findings, 🟢 unless they
create such a risk.

**Full-file verification** — end of step d: **every blocking finding, your
candidates from step c and the skills'**, verified before you compose. Re-check
each with `review-pr.sh context <n> <path> <line> [radius]`: **numbered source
text** (±40 lines by default) and whether the line lies inside this PR's hunks
(`no` = a pre-existing problem, [finding-form.md](finding-form.md)). Read the
whole file only when that range leaves the question open. Anchor every
survivor on the line its **Fix:** changes, read off that output. What does not
clear the severity bar ([finding-form.md](finding-form.md)) is dropped when it
is your own candidate and **regraded to 🟢 when a skill reported it** — a skill
finding is never deleted. No clone (`clone-failed`) → verify against the diff
context you have.

**Dependency check** — same pass, for every surviving 🔴/🟡 that states what
a third-party package provides: an API that is missing, deprecated, renamed,
or has another signature or behavior. Your memory of a package is not
evidence; versions change their API. Read the version the changed package
declares (its manifest, then the lockfile entry); its `checks` entry is that
read, for example `git grep -n '"<package>"' -- <manifest>`. Settle the finding only by evidence at that version:

- **The PR keeps the version** and the base branch already uses the same API
  (`git grep`) → drop the finding, or regrade a skill's to 🟢.
- **A source at the declared version** — the package's typings or changelog
  in the clone, or its documentation for that version — shows the claim → it
  stands and names the version and the source; shows the opposite → drop or
  regrade as above.
- **The PR changes the version** and no source is readable → the severity
  stays, and the finding names the version change.
- **Else** — no source, the version unchanged, no base usage → 🟢 at most.

**Decision check** — same pass, for every surviving 🔴/🟡 that disputes a design
choice: an architecture, a protocol, a boundary, a trade-off. Read the in-tree
document that covers the changed path — the `profile_slice`'s `## Decisions`
and `## Docs` rows locate it, the clone's copy is the evidence; no row or no
profile → search the clone under that path; no document → the finding stands.
A document that states the disputed behavior as intended settles the finding:
drop or regrade it as in verification, cite the document, and let a 🟢 name
the gap it leaves. A document the diff contradicts is a claim-sweep finding
instead. Count each settled finding in the audit note, naming the document;
no memory entry is written.

**Sibling sweep** — same pass. For each surviving 🔴/🟡,
`review-pr.sh sweep <n> '<regex>'` returns the hits of its defect class in
changed files and a count in untouched code. Read each hit with `context` and
keep it only where the same defect holds; look for occurrences the regex
cannot match too (another spelling, another call shape). Report the confirmed
ones as **one** finding ([finding-form.md](finding-form.md) → **One finding
carries every location**); one in untouched code is a pre-existing problem.

**Block sweep** — same pass. A finding that checks one field of a structured
block — a container security context, a resource spec, a permission set, a
schema entry — against a constraint in another file (a cluster policy, a chart
value, a schema; in the diff or not) checks **every field of that block**
against it, on every scope, and reports the conflicting fields as **one**
finding, each extra field in `also`.

**Gate check** — before the code, read every `gates[]` hit of `paths.risk`:
a test skipped, focused or deleted, assertions removed, a failing CI step or
a lint or type check silenced, a coverage threshold changed. Ask: does the PR
still test what it changes? A hit the body or the code justifies (a removed
feature, a flaky test with an issue) is no finding; one that lets the changed
behavior pass unchecked is 🟡, 🔴 when it opens a release or deploy gate. Ask
the same of a weakened gate `gates[]` missed, and of a test whose assertion
now expects the new output: confirm the new value from the code.

**Claim sweep** — for a finding whose class is *an in-tree statement about X is
false or incomplete*, sweep the whole clone, never only the delta range:
`review-pr.sh sweep <n> '<regex>' --tree`. Read every hit that states the same
rule — architecture pages, glossary, README, chart and config comments, CLI
and tool descriptions, the PR body — and report the ones the diff contradicts
as **one** finding; the sweep command is its `checks` entry
([review-mechanics.md](review-mechanics.md) → **Summary body format**).

**Language: ASD-STE100 (Simplified Technical English).** Write every outward
text — reviews, inline comments, issues, mention replies, chat, Slack — in STE
style: one topic per sentence, active voice, simple tenses, one term per
concept, no idioms, no synonym variation. STE governs wording, never content.

**The sentence bar is 20 words.** Before you post, split every sentence of
your prose above it; two clauses about two subjects become two sentences. The
audit ([audit.md](audit.md) task 32) and the benchmark
([benchmark.md](benchmark.md)) measure posted reviews against it.

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

One format for every channel (chat UI, GitHub body, history file).
`### Findings` is the complete list on first reviews and **never repeats
inline text**: an inline-carried finding is one line — severity + short label
+ `file:line` — its description, rationale and suggestion block only in the
inline comment; summary-only findings keep their full text. `post` warns on a
section with more findings on a second line, or more **Fix:** lines, than
`findings-json` holds findings not carried inline (on a delta re-review only
its `new` ones); a ` ```suggestion ` block counts as a second line. A complete
re-review lists every finding in full and is not checked.

**`_Limits: …_`** — the conditions this review ran under, as facts, never a
score or a confidence: a failed clone, a skill that did not run or stopped at
its time budget, a PR context that did not load, a diff past 2000 lines.
`compose-brief` puts it in the skeleton from this run's state (nothing to
report, no line); `post` warns on a body that drops it.

**`### For the human reviewer`** — the last section, when a blocking finding
comes from a design decision of the PR itself: three or four plain sentences,
no jargon, for a person who reads nothing else — what the PR decided, what
that puts at risk, what to settle before the single fixes matter. Concepts
only, never files, lines, symbols or severities; every claim is a finding the
review already made.

## Merging findings across sources

Your diff review and every skill section compose into one review:

- **One defect, one finding, one place.** The same defect class at the same
  location from two sources appears **once**: the strongest severity, the
  locations merged, its description ending `Reported by <skill section>.` per
  reporting skill.
- Its home is `### Findings` when it is blocking or maps inline, else the
  section of the first reporting skill in table order — no copy, no "merged
  into" line elsewhere. A skill section left with no finding prints its
  clean-run line.
- **Merging drops duplicates, never findings.** 🔴 and 🟡 are uncapped, 🟢
  survive within their budget ([finding-form.md](finding-form.md)); each skill
  keeps its own `findings=<N>` audit line ([skills.md](skills.md)). `post`
  warns on a body that prints more 🔴/🟡 lines than `findings-json` holds open
  blocking findings.

## Guarding a running review

The live HEAD is re-read at each phase boundary; a review whose HEAD moved
stops at the first boundary past the move.

- **Where.** `collect`, `delta` and `compose-brief` guard themselves; call
  `review-pr.sh guard <n>` at the end of the diff review. Check 1 and Check 2
  bracket the sequence.
- **`outcome: "head_moved"`** — the lock is released per kind, clone and state
  are deleted, and the work is carried ([review-rereview.md](review-rereview.md)
  → **Carried review after a HEAD move**): a complete finding set from
  `delta` and `post`, the hop and run counters from earlier guards;
  `carried` says whether there were findings.
- **`restart: true` → `prepare` the PR again in this run** and review the new
  HEAD from the top. **`restart: false`** (this run already restarted it) →
  next worklist entry; the heartbeat takes the PR.
- An unreadable API leaves the review running; Check 2 still gates the post.
- **The prepared state is checked before it is read.** `prepare` keeps a copy
  of `$CTX/pr.json` outside `$CTX`; every later command restores a damaged
  state file from it. With no usable copy → **`outcome: "state_damaged"`**:
  nothing is released or deleted, and the heartbeat's takeover of a dead run
  takes the lock.

**A comment or an edited description never discards the work.**
`compose-brief` re-reads the body, comments and reviews, rewrites
`paths.context` and names what moved; fold it into the review. Inline threads
are not re-read — they hang off the diff at the guarded SHA.

## Applying PR-local overrides

**Strictly scoped to their own PR.** Reload the list per PR, discard it before
the next. Suppress candidate findings matching an entry — same file plus
overlapping line, or the same backticked symbol in an entry naming the file
(`` `query()` `` in the finding, `` `query()` `` + `` `src/a.ts` `` in the
override) — and add the Summary audit note. Overrides only suppress, never add;
code that moved past its override lets the finding surface normally.

## Error handling

- **Transient tool failure** (network error, timeout, 5xx, rate limit) →
  **retry once**, then abort the PR; never retry twice — the next heartbeat
  picks it up fresh. `review-pr.sh` does this for its own calls; a failure in
  your own steps → `review-pr.sh abort <n> <reason>`. A failed context fetch,
  clone or skill run degrades instead (**PR context**, [skills.md](skills.md)).
  An abort releases the lock per kind — `first` deletes the row, `re-review`
  restores the prior row — deletes clone and state, writes the abort status
  and logs `aborted <reason>`. Log `PR #<n>: <step> failed after retry —
  aborted, lock released` in the chat UI and continue with the next PR. Never
  leave an `in_progress` lock behind, except after `state_damaged`.
- **Abort also on** a HEAD that moved (a phase guard reports it as
  `head_moved`), a draft without a review label, a withdrawn re-review
  trigger, or a dedup check unreadable after its retry.
- **422 line-not-in-diff** → `post` moves every inline comment to the summary
  and retries the POST once (`moved_to_summary`, reason
  `422 line not in diff`); note the moved comments once in the chat UI.
- **422 commit_id mismatch** → HEAD moved: `post` aborts as a Check 2 failure.
- **422 own pull request** → `post` retries once as `COMMENT`
  ([github-access.md](github-access.md) → **Own pull request**).

## Review-run self-check

Before you declare the run done:

- **Per reviewed PR, mechanical** — chain `&& review-pr.sh verify <n>` onto
  the PR's last `review-pr.sh` command (`post`, `abort`, or the one that
  returned `head_moved` or `state_damaged`): it checks the last lock cycle's
  terminal step, milestones, `skill_timing`, row, history file, ledger and
  cleanup. `ok` settles those; each `fail` of `issues` names what to repair;
  `not_locked` = this run took no lock on the PR; `error` names the lines to
  check by hand.
- **Per reviewed PR, judgement** — every rule above and in the files it links
  held; in particular: one marker-carrying review after Check 1, Check 2,
  dedup, trigger and live-holder checks · context, overrides, dismissals and
  insights handled · `memory_due`, orientation and script leads read in the
  code · every escaped defect class applied · gate hits answered, noise
  excluded · every blocking finding verified, swept, dependency- and
  decision-checked, its class-rule **Fix:** mirrored into
  `findings-json`, `review-meta.checks` and `.deferred`, `meta.json` with a
  `triage` · the guide recorded before the post ([artifact.md](artifact.md)) ·
  re-review pairs, `late` and carried findings settled
  ([review-rereview.md](review-rereview.md)) · every phase guard run, every
  `head_moved` honoured, a compose-time context change folded in · every
  `post` warning fixed or accepted on purpose · skill audit lines complete,
  widened scopes logged, sections merged with no finding lost or doubled ·
  served trigger label removed, stale approval dismissed · from round
  `approve_after_rounds` on, no open 🔴 → APPROVE · every sentence inside the
  20-word bar.
- **Style** — findings concise and diff-anchored, 🟢 within budget
  ([finding-form.md](finding-form.md)); re-review scope matched the trigger;
  `### For the human reviewer` written when due, free of files, lines and
  symbols.
- **Watch rules** — evaluated send-then-marker ([watches.md](watches.md)).
- **`ci_triage: enabled`** — every `ci_failures_due` entry and every review
  that ended on a failing check answered post-then-marker
  ([ci-triage.md](ci-triage.md)).
- **`review_progress: enabled`** — every locked PR on a terminal `success`
  status.
- **Every `reviews_due` PR reached a terminal state**, and **every PR hold this
  run took is released** (`review-pr.sh release <n>`).
- **Every `dispatch[]` entry started or kept**, the session renamed
  ([runbook.md](runbook.md) → **Review run** step 1).
