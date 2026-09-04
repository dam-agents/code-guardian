# Reviewing a PR

Read this file at the start of every **review run** — a worklist with
`reviews_due`, `label_cleanups_due`, `selfheals_due`, `prunes_due`,
`status_resets_due`, `urgent_alerts_due` or `mentions_due` non-empty, or a
`stall_alert`. Preflight decided; you act. `scripts/review-pr.sh` performs the
mechanical steps, and its two HEAD-freshness checks plus the pre-post dedup
re-check guard the window between preflight and post time.

## Label bookkeeping (`selfheals_due`, `label_cleanups_due`)

Both run before the review loop, one log line each. A failed removal is logged,
never fatal — preflight re-emits the entry.

- **Self-heal** `{number, sha, ts, status}` → write the REVIEWS.md row
  `| <number> | <sha> | <ts> | SEE-GITHUB | <status> |`. `ts` is the
  GitHub-reported timestamp; use the remote body's verdict when you have it.
  Log `PR #<n>: self-healed REVIEWS.md from remote marker (<status>)`.
- **Same-SHA trigger cleanup** `{number, label, request}` → a trigger on a PR
  whose live HEAD is reviewed and whose description is unchanged since. Clear
  what the entry flags — `label: true` → remove the label, `request: true` →
  remove your pending review request (**Trigger removal**) — post nothing, and
  log
  `PR #<n>: re-review trigger present but nothing new since <short-sha> — cleared (<label / request / label + request>), no re-review`.
  An edited description arrives as a `reviews_due` entry instead
  (**Description-only re-review**).

## Pruning (`prunes_due`)

Preflight verified every entry `{number, state, gist_id, dam_id}`
CLOSED/MERGED. Execute exactly this list — never from list absence, never a
bulk delete of `reviews/pr-*.md`. An entry without ids → read the
`<!-- artifact-gist: … -->` / `<!-- artifact-dam: … -->` markers from
`work/reviews/pr-<n>.md` before step 2 deletes it.

1. Artifacts, each failure logged and never blocking: `gist_id` →
   `gh gist delete <gist_id>`; `dam_id` → `delete_artifact {id: <dam_id>}`,
   skipped silently when the MCP tool is absent.
2. `rm -f work/reviews/pr-<n>.md work/reviews/pr-artifacts/pr-<n>.html`.
3. Delete the PR's REVIEWS.md row, and its `work/SHEPHERD.md` row when present.
4. Log `PR #<n>: pruned (<state>)`.

## Per-PR review sequence (`reviews_due`)

Every `review-pr.sh <cmd>` below is `bash "$HOME/scripts/review-pr.sh" <cmd>`.

Entry: `{number, head_sha, head_ref, title, author, kind, takeover, prior,
urgent, closed}`, plus `eta_seconds` under `review_progress: enabled`. `kind`
is `first` or `re-review`; `prior` holds the last review's
`{sha, ts, verdict}`. Keep the worklist order — urgent entries come first.
Finish one PR before the next.

a. **Prepare** — `review-pr.sh prepare <n>` (`--eta <seconds>` under
   `review_progress: enabled`, `--on-demand` for an on-demand review). Check 1
   against the live PR gives `outcome`:
   - `skip` — draft; closed, unless a `RAPID` lock still owes the full review
     (mode `closed`, **PR closed mid-review**); a `re-review` whose trigger is
     gone.
   - `stand_down` — a live holder owns the PR (**Live holder**).
   - `error` — retry once, then move on; no lock was written.
   - `ready` — it writes the `in_progress` lock row, logs `locked`, writes the
     progress status, fetches context and the diff into `$PR_DIR.diff` with a
     hunk index, clones the branch with its base ref ([skills.md](skills.md) →
     **Clone, credential helper, cleanup**), and renders the per-skill copies,
     briefs and context pack.

   The live trigger follows `rereview_trigger` and sets the scope: label →
   `full: true`, else delta (**Re-review output**). The JSON also carries
   `kind`, `full`, `urgent`, `prior`, `files[]`, `skills{}`, `delta`,
   `profile_slice`, `history_slice`, `memory_due`, `structure_changed` and
   `paths`. `urgent: true` → **phase 1** (**Urgent PRs**) before step b.
b. **Orient** — read `memory_due`, `profile_slice` and `history_slice`
   ([profile.md](profile.md)); a `verify_live` row means read the live file,
   not the row. `paths.pack` lists per changed code file its dependents, its
   tests and its changed lines; `paths.context` holds the PR context
   (**PR context**).
c. **Review the diff** — `$PR_DIR.diff`, file by file in `files[]` order:
   classes `code`, `test`, `docs`, `config`. The noise classes (`lockfile`,
   `snapshot`, `build`, `vendored`, `minified`, `sourcemap`, `generated`) are
   not reviewed as code and get one `### Summary` line:
   `_<N> generated/lockfile file(s) not reviewed: <paths, or the classes when more than five>._`
d. **Run every configured review skill** per [skills.md](skills.md):
   `review-pr.sh step <n> "fanned out (n=<N>)"`, one subagent per skill with
   status `run`, then `review-pr.sh collect <n>` for the audit lines, form
   warnings and `skill_timing`. Verify candidates (**Full-file
   verification**), sweep siblings (**Sibling sweep**), then
   `review-pr.sh step <n> verified`. On a re-review,
   `review-pr.sh delta <n> findings.json` classifies your findings against the
   prior `findings-json` — `fixed` / `still` / `new`, `suppressed` by
   overrides, `ambiguous` pairs left to you — and returns the
   `### Changes since last review` skeleton.
e. **Compose** `body.md` (`### Summary` … `### Verdict` — **Output format**),
   `findings.json` (the `findings-json` array) and, for inline-carried
   findings, `comments.json` (`[{path, line, side, body[, start_line]}]`, each
   `body` the full text — **Mapping findings to inline comments**). Output the
   review to the chat UI.
f. **Post** — `review-pr.sh post <n> --verdict <VERDICT> --body body.md
   --findings findings.json [--comments comments.json]`. It runs Check 2 and
   the dedup re-check, maps each inline comment against the hunk index
   (outside a hunk or past the cap of 25 → moved under
   `### Findings not anchorable inline`, `inline: false` in `findings-json`),
   posts the payload (**Posting the GitHub review**), removes
   `$REREVIEW_LABEL`, dismisses a stale approval, appends the body to
   `reviews/pr-<n>.md`, writes the `done` row and terminal status, logs
   `posted <verdict>` and `done`, and deletes clone, copies, diff and state —
   exactly once. Outcomes: `posted` (`url`, `moved_to_summary`,
   `label_removed`, `dismissed_approval`) · `aborted` (**Error handling**) ·
   `duplicate` (the marker is already on GitHub; the row self-heals with its
   timestamp) · `closed_*` (**PR closed mid-review**). Then evaluate the
   configured watch rules ([watches.md](watches.md)).
g. **Any other end of a PR** — a transient failure after its retry, a decision
   not to post — `review-pr.sh abort <n> <reason>` (**Error handling**).

Every entry ends `posted`, `duplicate`, `closed_filed`, `closed_discarded` or
`aborted`.

**Progress logging.** Each milestone appends a `review_step` event
([logging.md](logging.md)). The last event of a PR pins where a stall stopped;
consecutive timestamps give per-step durations.

- `review-pr.sh` writes them as it performs them: `locked`, `cloned`
  (`prepare`) · `locked (refresh, …)`, `fanned out (n=<N>)`, `verified`
  (`step`) · `rapid posted` (`rapid`) · `posted <verdict>`, `done` (`post`) ·
  `aborted <reason>` (`post` / `abort`). The adapter hook derives
  `skill:<name> done` ([logging.md](logging.md) → **Harness adapters**).
- `fanned out (n=<N>)` goes immediately before the fan-out, `verified`
  immediately after verification. They bound three durations: the skill phase,
  the verification window, and compose-plus-Check-2. Per-skill durations come
  from `skill_timing` ([skills.md](skills.md) → **Invocation & audit log**).
- In the manual fallback the hook still derives `cloned`, `posted <verdict>`,
  `locked` / `done` / `aborted (lock released)` from the commands that perform
  them (**Review tracking state**). The rest is yours, chained onto the step's
  own command:

  ```bash
  . "$HOME/scripts/log.sh" && LOG_JOB=review logev info review_step "PR #<n> <sha-short> <step>"
  ```

- Log a step you are unsure about — duplicates are harmless, a missing event is
  invisible to the `Stop` hook and reads as a review that never finished. The
  filename and `msg` shape are a contract ([logging.md](logging.md) →
  **The shape is a contract**).

**Lock heartbeat.** Before each of steps c, d, e and f,
`review-pr.sh step <n> "<what comes next>"` rewrites the PR's REVIEWS.md row
with the **current** UTC time (same fields, status stays `in_progress`) and
logs `locked (refresh, …)`; step d's two milestones are `step` calls too. The
timestamp is the age preflight measures and the event is the liveness signal it
reads (**Live holder**), so a review that refreshes never crosses the TTL.

**Completion enforcement.** The `Stop` hook reads these events back at end of
turn: a PR logged `locked` this run with no later `done` / `aborted <reason>`
is a turn ending mid-pipeline, so the hook refuses the stop and names the PRs,
their last step, and what is still owed. `rapid posted` and `skill:<name> done`
are **not** terminal. It blocks up to **3 times per run**, the last attempt
leading with the explicit-abort route, then allows the stop and logs
`enforcement exhausted`. It makes no GitHub calls and no state writes, and is
never a reason to pad review content.

**Stalled-review rate alert.** Preflight counts the
`stale in_progress lock` takeovers of the last 24 h. At or above
`stall_alert_threshold` (missing = `4`; `0`/`off` disables) it emits
`stall_alert: {count, threshold, prs, window_hours, per_day_7d}` — **once per
UTC day** (`work/.stall-alert-day`, claimed under a `mkdir` lock, so concurrent
heartbeats cannot double-send). One stall is normal (HEAD moved, pod restart); a cluster means
reviews are redone at full cost. Deliver it **once, after the run's review
work**, so the numbers include this run:

1. Chat UI: count, threshold, affected PR numbers, the `per_day_7d` trend.
2. Under `slack_notifications: enabled` **and** an `escalation_owner`, also DM
   that person — never the shared channel, roster-only mentions still apply.
3. Log `stall_alert_sent <count>`. A failed send is logged, never retried this
   run.

The alert is a signal, not a repair: never bulk-clear locks, re-review, or
change the threshold in response. Investigate per [logging.md](logging.md) →
triage; record a recurring cause as an operational lesson
([preferences.md](preferences.md)).

### Trigger removal

Use REST — `gh pr edit` goes through GraphQL, which 401s in this pod (the
platform's auth proxy does not rewrite that code path):

```bash
gh api -X DELETE "repos/$REPO/issues/<n>/labels/$REREVIEW_LABEL" >/dev/null \
  || gh pr edit <n> --repo "$REPO" --remove-label "$REREVIEW_LABEL"
```

Pending review request — same-SHA cleanup only; a served request clears itself
when the review posts:

```bash
gh api -X DELETE "repos/$REPO/pulls/<n>/requested_reviewers" -f "reviewers[]=$BOT_LOGIN" >/dev/null
```

## Progress signal on GitHub (`review_progress`)

`review_progress: enabled` (missing = `disabled`) publishes progress as a
**commit status** on the reviewed SHA. One call per update, `context` =
`$REVIEW_MARKER`:

```bash
gh api -X POST "repos/$REPO/statuses/<sha>" -f state=<state> \
  -f context="$REVIEW_MARKER" -f description="<line>" >/dev/null
```

Add `-f target_url=<url>` on the rows that have one. `description` is one short
line — GitHub truncates past 140 characters.

| Written at | `state` | `description` | `target_url` |
| --- | --- | --- | --- |
| `prepare` — lock written | `pending` | `queued <HH:MM>Z · fetching diff and clone<eta>` | — |
| `prepare` — clone finished | `pending` | `reviewing since <HH:MM>Z · diff + <k> skill(s)<eta>` | — |
| Urgent phase 1 — rapid posted | `pending` | `rapid preliminary review posted · full review running` | the rapid review |
| `post` — review posted | `success` | `<VERDICT> · <a> critical, <b> warning, <c> suggestion · took <m>m` | the posted review |
| `post` / `abort` — posting aborted | `success` | `no review posted — <reason>; retrying next heartbeat` | — |
| PR closed mid-review | `success` | `PR closed · <n> critical finding(s) in issue #<i>` | the issue |
| `status_resets_due` entry | `success` | `review abandoned — resumes when the PR is ready` | — |

- `<eta>` is ` · usually ~<N> min` from `eta_seconds` — whole minutes, minimum
  1, omitted when the field is `null`.
- **`description` is ASCII.** The statuses API rejects 4-byte UTF-8
  (`Description doesn't accept 4-byte Unicode`), so severity words replace the
  emoji here; the review body keeps them.
- Write on the SHA the review locked at Check 1.
- Every terminal outcome is `success`, aborts included: `failure`/`error` would
  make the agent a merge gate the moment someone made the context a required
  check.
- `review-pr.sh` writes each row at the step that owns it; the manual fallback
  issues the same call at the same step.
- **Best-effort.** A failed write is logged (`progress_status`, warn) and
  changes nothing — never retried, never a reason to abort.

**`status_resets_due`** `{number, sha, reason}` — a locked review was abandoned
with the status left `pending` (`reason: draft`). Write the terminal row above,
then **delete the PR's REVIEWS.md row**; the `reviews/pr-<n>.md` history stays.
The missing row is what stops the reset repeating.

## Urgent PRs — rapid-first delivery

`urgent_label` (missing = off) names a **human-managed** label — the agent
never adds or removes it. While it is on a PR, every due review of it runs
rapid-first: preflight flags the entry `urgent: true` and orders it first,
Check 1 re-verifies the label and reviews normally when it is gone.

**Immediate Slack alert (`urgent_alerts_due`, once per PR).** Preflight emits
`{number, title, author, url}` for every open urgent PR whose history file
lacks an `urgent-announced` marker, only under
`slack_notifications: enabled`. Send these **before any other run work**:

1. Mention roster members (`work/DEVELOPERS.md`) with a `slack_id` — filtered
   to those online when a presence lookup is available, otherwise all.
   **Never anyone outside the roster** ([shepherd.md](shepherd.md) →
   **Hard rules**).
2. `mcp__platform-outbound__send_channel_message`:
   `🚨 **<bot_display_name>** — URGENT: PR #<n> "<title>" by <author> needs eyes now (\`<urgent_label>\`). <@id1> <@id2> … Rapid review incoming. <url>`
3. **Write the marker immediately after a successful send** —
   `<!-- urgent-announced: <ISO timestamp> -->` into `reviews/pr-<n>.md`,
   creating the file with its title heading when missing. A failed send writes
   no marker and is logged; the next heartbeat re-emits the alert.
4. Log `PR #<n>: urgent alert sent (<k> mentioned)`.

**Phase 1 — rapid preliminary review**, right after `prepare` returns, before
orientation and skills. Optimize for delivery speed.

1. Review the diff only (`$PR_DIR.diff`; on a re-review prefer the range since
   the prior review) for **🔴 Critical findings only**.
2. Write `rapid.md`, body only, no inline comments:

   ```
   ⚡ **<bot_display_name>** — ⏱️ Rapid preliminary review @ `<sha-short>`

   > Fast pass triggered by the `<urgent_label>` label — critical checks
   > only. **The full review follows.**

   ### Critical findings
   - 🔴 **Critical:** <one-liner> (`file:line`)
   ```

   No criticals → the section body is `_None found at rapid-review depth._`
3. `review-pr.sh rapid <n> --body rapid.md`. It dedups on the **rapid marker**
   `<!-- <review_marker>:rapid headRefOid=<full-sha> -->` at the live HEAD
   (`already_posted` → go to phase 2), posts one `event: COMMENT` review with
   the marker appended, sets the REVIEWS.md verdict cell to `RAPID` with a
   fresh timestamp (status stays `in_progress`), logs `rapid posted`, and
   writes the progress status.

**Phase 2 — the full review, immediately after** — the normal sequence from
step b. The `:rapid` marker is invisible to the normal dedup, so the full
review posts as usual; watch rules evaluate once, after it. A rapid post is
**never** terminal. A died run is recovered by the stale-lock takeover —
verdict `RAPID` tells the next run to skip phase 1.

## PR closed mid-review — critical findings become an issue

Applies to **every** review. `post` finding the PR `CLOSED`/`MERGED` at Check 2
posts no review, and its outcome says what is left:

- **`closed_discarded`** — no 🔴 finding. The lock is released as on a Check 2
  abort; log `PR #<n>: closed mid-review — discarded (no critical findings)`.
- **`closed_criticals`** — carries `criticals`, the `issue_marker`, and
  `existing_issue` when one is already filed. Deliver them as one issue: reuse
  `existing_issue`, or
  `gh api "repos/$REPO/issues" -X POST -f title="Critical findings from review of closed PR #<n>" -f body=… -f "assignees[]=<author>"`
  with the 🔴 findings in full, a `#<n>` reference, and the trailing `:issue`
  marker line (a failed assignment is logged, the issue stands). Then rerun
  `post … --closed-issue <id>` → **`closed_filed`**: the review is appended to
  `reviews/pr-<n>.md` with
  `_Delivered as issue #<id> — PR closed before posting._`, the lock becomes a
  `done` row, and the status names the issue. Log
  `PR #<n>: closed mid-review — <k> critical finding(s) filed as issue #<id>`.

**Crash recovery.** A closed PR whose row is an `in_progress` lock with verdict
`RAPID` arrives as a review entry flagged `closed: true`, not as a prune.
`prepare` runs it in mode `closed` — lock refreshed with verdict `RAPID`, no
clone, no skills (the branch may be gone), Check 1 gates not applied — then
review the diff and `post`.

## On-demand review (Slack or mention)

The one non-operator request that triggers work ([runbook.md](runbook.md) →
**Instruction sources & trust boundary**): **anyone** in the connected channel,
or in a GitHub comment addressed to the bot ([mentions.md](mentions.md)), may
ask for a review of a specific PR — equivalent to adding `$REREVIEW_LABEL`.
Nothing else is changeable from those surfaces.

1. Resolve the PR reference (number or URL; a mention's own PR when none is
   named) and `gh pr view` it. Not found / closed / draft → reply so, done.
2. `review-pr.sh prepare <n> --on-demand`. `stand_down` → reply "review
   already running", done. A stale, silent lock is taken over — log
   `PR #<n>: stale lock killed on on-demand request`.
3. `skip` with `already reviewed at <short-sha>` → reply so; same-SHA dedup
   always holds.
4. `ready` → the sequence from step b. `kind` = `re-review` when a prior review
   exists, else `first`; re-reviews run **delta scope** unless
   `$REREVIEW_LABEL` is also on the PR; no trigger is required at `prepare` or
   `post`; install missing skills per [skills.md](skills.md) →
   **Installation**. Reply in the requesting channel or thread with a link to
   the posted review, then persist `work/` ([persistence.md](persistence.md)).

Replying to the requesting surface is responsive, not proactive — it does not
require `slack_notifications: enabled`.

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
`_(Suppressed N finding(s) per PR-local overrides: <ids>. Suppressed M finding(s) per PR context: <ids>.)_`
Omit either part at count zero.

## Criteria & review style

Unless preferences say otherwise: **Correctness** (logic, off-by-one, null
risks, races) · **Security** (injection, credential leaks, OWASP top 10) ·
**Performance** (allocations, N+1, missing indexes) · **Architecture**
(coupling, layer boundaries, broken contracts) · **Tests** (missing coverage,
flaky patterns) · **Maintainability** (dead code, error handling). Past 2000
diff lines: focus on the most critical files, still post a full review.

**Audience: agent-written, agent-read code.** Human readability is not a review
goal. Flag naming taste, cosmetic structure, comment density, file layout and
"this would be clearer as…" restructuring **only** where they create a real
defect risk — a misleading name that hides a bug, dead code that changes
behavior, an abstraction that breaks its contract. Never request restructuring
for human readers alone.

**Full-file verification** — end of step d: candidates from step c, verified
after the skills and before you compose. The diff nominates a finding; the
surrounding code confirms it. Re-check each candidate with
`review-pr.sh context <n> <path> <line> [radius]`, which prints **numbered
source text** (±40 lines by default) and whether the line lies inside this PR's
hunks — `no` marks a pre-existing problem, at most one 🟢 line. Read the whole
file only when that range leaves the question open. Keep what survives, drop
what you doubt: a false positive costs more credibility than a missed nit. No
clone (`clone-failed`) → verify against the diff context you have.

**Sibling sweep** — same pass. For each surviving 🔴/🟡, check the files this PR
changes for more occurrences of the same defect class:
`review-pr.sh sweep <n> '<regex>'` returns the hits in changed files and a
count in untouched code. Report them as **one** finding listing every location,
so one fix round closes the class. An occurrence in untouched code is a
pre-existing problem ([finding-form.md](finding-form.md)). On a delta
re-review both passes cover only the files changed since the prior review.

**Language: ASD-STE100 (Simplified Technical English).** Write every outward
text — reviews, inline comments, issues, mention replies, chat, Slack — in STE
style: one topic per sentence (aim ≤ 20 words), active voice, simple tenses,
one term per concept, no idioms, no synonym variation. STE governs wording,
never content.

**Finding form.** Every finding — yours or a skill's — follows
[finding-form.md](finding-form.md).

## Output format (first reviews)

```
## PR #<number>: <title>
**Author:** <login> | **Branch:** <head> → <base> | **Changes:** +<additions> −<deletions> (<files> files)

### Summary
<1-2 sentence summary of what the PR does>

### Findings
<findings, per finding-form.md>
- ✅ **Looks good:** <description>

### <section — one per configured review skill that ran, in table order>
<that skill's findings, per finding-form.md (or its clean-run line)>

### Verdict
<APPROVE / REQUEST_CHANGES / COMMENT> — <one sentence justification>
```

`### Findings` is the canonical, complete list on first reviews, and it **never
repeats inline text**: an inline-carried finding appears here as one line —
severity + short label + `file:line` — while its description, rationale and
suggestion block live only in the inline comment. Summary-only findings keep
their full text here. One format for every channel (chat UI, GitHub body,
history file); the one-liners carry the next re-review's delta matching.

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

## Re-review output (trigger-gated; new commits or an edited description)

The trigger sets the scope:

- **`$REREVIEW_LABEL` → complete re-review** (`full: true`): review the
  **entire PR** at the live HEAD, at first-review depth. Output = the
  first-review format with `### Changes since last review` inserted.
  `### Findings` lists **all current findings** in full, new and still-present;
  `✅ Fixed` stay one-liners in the block. Inline comments map only `🆕 New`
  findings; skill sections post in full. `findings-json` carries
  `new`/`still`/`fixed` as found.
- **Review request / on-demand ask → delta re-review** (`full: false`): the
  delta only, per the conciseness rules below.

**Description-only re-review** (`description_changed: true`): an edited body
answers the trigger, so the diff and SHA are the reviewed ones. `post` reads
the earlier marker at this SHA as the prior being superseded, and an abort
restores the `done` row. Re-read the body (**PR context: body, comments,
reviews**) and redo the review against it: a removed justification no longer
suppresses its finding, an added one now does. `Previous HEAD` is the same SHA
— write `description edited, no new commits` on that line and let the buckets
carry the rest. No change in substance → say so in one line.

Both scopes: `review-pr.sh delta <n> findings.json` matches your findings
against the prior `findings-json` line in `reviews/pr-<n>.md` (older reviews
without one: parse the visible text yourself) and returns this block with its
`fixed` / `still` / `new` buckets, the `suppressed` overrides and the
`ambiguous` pairs you decide. Insert it between `### Summary` and
`### Findings`:

```
### Changes since last review
Previous HEAD: <short-sha> (<timestamp>) — verdict <PREV_VERDICT>[ — unreachable, reviewed the whole PR]

- ✅ **Fixed:** <one-liner> (`file:line`)
- 🔁 **Still present:** <one-liner> (`file:line`)
- 🆕 **New:** <description> (`file:line`)
```

Delta-scope depth (steps c–d):

- **One compare call decides the range, and `prepare` makes it.** Its base is
  the `headRefOid=` of the last review marker; the result is `delta` =
  `{base, status, reachable, files[]}`. `status: ahead` with a `patch` per file
  → `reachable: true`, delta depth on `delta.files[]`. `status: identical`, or
  the base already at HEAD → `reachable: true` with an empty `files[]`, the
  description-only case. Anything else — `diverged` / `behind`, 404, 300 files,
  a file without `patch` — → `reachable: false`: review at complete depth in
  the delta output format, with ` — unreachable, reviewed the whole PR`
  appended to the `Previous HEAD` line.
- **Candidates come from the range's hunks only** (`gh api
  "repos/$REPO/compare/<delta.base>...<head-sha>"`, or read them in the clone),
  in files the PR diff touches. A hunk whose added lines are absent from the PR
  diff arrived with a base-branch merge and is not a candidate; the full PR
  diff is context for reading them. A description-only re-review has an empty
  range: candidates, verification, sweep and extension-skill routing all use
  the full PR diff, re-read against the edited body.
- **Each prior finding is settled at its anchor.** Read every `file:line` of
  the prior `findings-json` at HEAD — from the clone, or via
  `gh api "repos/$REPO/contents/<path>?ref=<head-sha>" -H 'Accept: application/vnd.github.raw'`
  — and classify it `fixed` or `still` (moved code is `still`, at its new
  line). A `line: null` finding is settled by re-reading its file.
- **Verification and the sweep cover the range's files.** `prepare` already
  routed extension-triggered skills from that list ([skills.md](skills.md) →
  **Triggers & file routing**); `always` skills run unchanged. A skill routed
  no file is skipped `no-matching-files` (section omitted) and its prior
  findings are settled from the prior review — blocking ones through
  `findings-json`, 🟢 through its prior section text — as one-liners in the
  buckets above.

Delta-scope conciseness (all channels):

- Only non-empty buckets, every entry a **single line**. Never re-expand a
  carryover's description, rationale, **Fix:** or suggestion.
- `### Findings` lists **only `🆕 New` findings**, inline-carried ones as
  one-liners. No `✅ Looks good` on re-reviews, ever. Nothing new → the section
  body is `_No new findings at this HEAD._`
- The **Verdict weighs all current findings** — new, still-present and skill
  findings alike: an unfixed 🔴 keeps `REQUEST_CHANGES` even as a one-liner.
- Skill sections condense the same way: unchanged findings collapse into
  `🔁 <N> finding(s) from the previous review still present (see review at <short-sha>)`,
  full text only for new findings, clean-run lines as-is.
- Inline eligibility: mapping rule 5.

Prior review file missing → skip the block, review as a first review, and
append `(no prior review on file)` to `### Summary`.

## Review tracking state

**REVIEWS.md** — one row per PR:
`| <number> | <headRefOid> | <ISO timestamp> | <verdict> | <status> |`

- `status`: `in_progress` (lock; verdict `-`, or `RAPID` after an urgent PR's
  rapid review — timestamp = lock/rapid-post time) · `done` (timestamp = post
  time) · `awaiting_label` (a `done` review exists, newer commits arrived, no
  trigger yet).
- An `awaiting_label` row keeps the **SHA, verdict and timestamp of the last
  posted review** — the one row whose timestamp is not the write time.
  Preflight writes this flip; you write it only to restore it on a re-review
  abort.
- Every other timestamp is the actual UTC write time
  (`date -u +%Y-%m-%dT%H:%M:%SZ`) — never rounded, reused or fabricated.
- The lock is best-effort (**50-min TTL**, `LOCK_TTL_MIN` in
  [preflight.sh](../scripts/preflight.sh)); the remote dedup check stays
  authoritative.
- `review-pr.sh` writes every row (`prepare` locks, `step` refreshes, `rapid`
  sets `RAPID`, `post` / `abort` finish). In the manual fallback, rewrite the
  PR's line in place; rows are full of `|`, so give sed another delimiter:

  ```bash
  sed -E "s#^\| *<n> \|.*#| <n> | <sha> | <ts> | <verdict> | <status> |#" work/REVIEWS.md \
    > work/REVIEWS.md.tmp && mv work/REVIEWS.md.tmp work/REVIEWS.md
  ```

  Keep this row shape — the adapter derives `locked`, `done` and
  `aborted (lock released)` from it (**Progress logging**).

### Live holder — a lock past its TTL that is still working

**The TTL bounds a crash, not a slow review.** A lock past `LOCK_TTL_MIN` is
only a candidate: preflight reads the holder's `run` id from its
`review_step … locked` event and emits `takeover` **only when that run has
logged nothing for `HOLDER_QUIET_MIN` minutes** (20 — above the 16.7-min
longest gap a healthy review shows; both values in
[preflight.sh](../scripts/preflight.sh)). Otherwise the PR is omitted and
logged `holder … active — left running`. The check is a local log read. Two
signals must both go quiet: the row timestamp (**Lock heartbeat**) and the
event stream.

- **As the holder you own the PR to a terminal state whatever your lock age.**
  Keep refreshing and finish. Step f is the safety: a second job that posted at
  your SHA turns your run into a self-healing abort, so no duplicate posts.
- **As the taker, Check 1 re-checks exclusivity for every entry, whatever its
  `takeover` flag.** `takeover: true` means preflight saw no life, not proof of
  death; `takeover: false` only means its snapshot saw no lock, and that
  snapshot can predate your arrival by minutes. `prepare` re-checks first: the
  PR lives when a tree, diff or state of `/tmp/review-pr-<n>*` is younger than
  `HOLDER_QUIET_MIN`, or when another run logged a `review_step` on it inside
  that window. Then it stands down — `outcome: stand_down`, nothing touched,
  `holder alive at Check 1 — stood down` logged — and you take the next PR. An
  older tree with no such event is a dead run's leftover and is reclaimed; the
  lock write comes after this check. Standing down protects a finished
  fan-out, which the reclaim's `rm -rf` would destroy ([skills.md](skills.md) →
  **Clone, credential helper, cleanup**).

**`reviews/pr-<number>.md`** — per-PR history (`mkdir -p reviews`):

```markdown
# PR #<number>: <title>
<!-- artifact-gist: <GIST_ID> -->
<!-- artifact-dam: <DAM_ID> -->

## PR-local overrides

- [2026-04-23 from user] Ignore: null check on `src/auth.ts:42` — confirmed intentional

## Review at <headRefOid-short> — <ISO timestamp> — <VERDICT>

<full review body as posted, starting with ### Summary>

---
```

Title header and overrides stay at the top; reviews append below, oldest first,
separated by `---`. Update the header on a title change. The artifact markers
sit right after the title, one per line, overwritten in place by the artifact
step ([artifact.md](artifact.md)); omit a marker whose surface was not
published. Watch-rule markers (`<!-- watch-sent: <id> -->`,
[watches.md](watches.md)) follow on their own lines.

### Applying PR-local overrides

**Strictly scoped to their own PR.** Reload the list per PR, discard it before
the next. Suppress candidate findings matching an entry — same file plus
overlapping line, or the same backticked symbol in an entry naming the file
(`` `query()` `` in the finding, `` `query()` `` + `` `src/a.ts` `` in the
override) — and add the Summary audit note. Overrides only suppress, never add;
code that moved past its override lets the finding surface normally.

## Posting the GitHub review

`review-pr.sh post` submits one PR review — summary and inline comments in a
single submission — from `body.md`, `findings.json` and `comments.json`
(step e). The payload it posts to `repos/$REPO/pulls/<n>/reviews`:

```json
{ "commit_id": "<full headRefOid>", "event": "<COMMENT | APPROVE | REQUEST_CHANGES>",
  "body": "<summary body — below>",
  "comments": [ {"path": "src/foo.ts", "line": 42, "side": "RIGHT", "body": "🟡 **Warning:** …"} ] }
```

`event` = the Verdict verbatim. `commit_id` = the reviewed `headRefOid`, the
server-side stale guard: GitHub 422s if HEAD moved, and `post` aborts.

### Summary body format

```
🛡️ **<bot_display_name>** — <verdict-emoji> Code Review @ `<headRefOid-short>`

<the full structured review>

---
_Review by [<bot_display_name>](https://<def_host>/<definition_repo>) · automated code guardian_

<!-- findings-json: [{"status":"new","severity":"critical","file":"src/auth.ts","line":42,"inline":true,"summary":"token compared with ==","fix":"compare tokens with a constant–time equality helper"}] -->
<!-- <review_marker> headRefOid=<full-sha> -->
```

Emoji: ✅ APPROVE, ⚠️ COMMENT, ❌ REQUEST_CHANGES. The trailing marker line is
**mandatory** — it drives dedup — and uses the full 40-char SHA.

**`findings-json`** — the machine-readable copy of `### Findings`, one line
right above the marker, in every posted full review. Per finding: `status`
(`new`|`still`|`fixed`; first reviews all `new`), `severity`
(`critical`|`warning`|`suggestion`), `file`, `line` (null when not anchorable),
`inline`, `summary` (≤ ~10 words), `fix` (the **Fix:** line in ≤ ~15 words;
`null` on `suggestion` and `fixed`). `critical` and `warning` are the blocking
set, so this line is the machine-readable approval bar the next re-review
checks against. Keep the JSON free of `--` sequences — HTML-comment safety, use
`–`. No findings → `[]`. Rapid reviews carry no such line. A pre-3.1.0 review
without `fix` parses as before.

### Mapping findings to inline comments

1. Inline-eligible = `(file, line)` inside a diff hunk: `path` repo-relative,
   `line` in the new file (`side: "RIGHT"`; `"LEFT"` + old line for deleted
   code); multi-line adds `start_line`, both ends in one hunk.
2. Outside every hunk, or no precise line → summary-only. `post` checks each
   comment against the hunk index and moves the ineligible ones under
   `### Findings not anchorable inline`, because otherwise the whole POST 422s.
3. `✅ Looks good` → summary-only, never inline (first reviews only).
4. **Cap 25 inline comments** — `post` keeps 🔴/🟡 first and moves excess 🟢 to
   the summary.
5. **Re-reviews: only `🆕 New` findings inline** — carryovers keep their
   existing thread, `✅ Fixed` get nothing.

**Suggestion blocks**: for a small, unambiguous fix, append a
` ```suggestion ` block replacing exactly the anchored line(s) — matching
indentation, replacement lines only, one block per comment. Never for style
preferences.

### Revoking a stale approval on re-review

On a re-review whose verdict is **not** `APPROVE`, `post` finds the agent's
most recent `APPROVED` review — its own login or the marker, never a human's —
and dismisses it after the new review posts:

```bash
gh api "repos/$REPO/pulls/<n>/reviews/<id>/dismissals" -X PUT -f event="DISMISS" \
  -f message="Superseded by $BOT_NAME re-review at <new-sha> — verdict is now <new-verdict>."
```

It logs `PR #<n>: dismissed stale approval <id> (APPROVE → <new-verdict>)`
(`dismissed_approval` in its outcome). A new `APPROVE` leaves the approval in
place. A failed dismissal is logged, not fatal.

### Error handling

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
  trigger, or a dedup check unreadable after its retry.
- **422 line-not-in-diff** → `post` moves every inline comment to the summary
  and retries the POST once (`moved_to_summary`, reason
  `422 line not in diff`); note the moved comments once in the chat UI.
- **422 commit_id mismatch** → HEAD moved: `post` aborts as a Check 2 failure.

## Review-run self-check

Before you declare the run done:

- **Bookkeeping** — every `selfheals_due` / `label_cleanups_due` /
  `prunes_due` entry executed and logged.
- **Mentions** ([mentions.md](mentions.md)) — handled before the review loop;
  ledger row immediately after each entry's actions; every entry terminal
  (`feedback + reply` / `answer` / `review` / `no-action` / `send-failed`) with
  its `mention_handled` event; every explicit correction stored and named in
  the reply.
- **Per reviewed PR** — one GitHub review carrying the full-SHA marker · Check
  1, Check 2 and the dedup re-check done, the re-review trigger check included
  · a `post` or `abort` outcome, lock lifecycle correct (aborted re-reviews
  restored `awaiting_label`, no `in_progress` left) · row refreshed at each
  milestone · live holder re-checked before the lock write · label removed
  after a posted review on a labeled PR · skill audit lines complete
  ([skills.md](skills.md)) · review appended to `reviews/pr-<n>.md` · overrides
  applied from that PR's file only · context fetched and used, a human
  dismissal in it recorded as an override before posting · observed insights
  recorded ([preferences.md](preferences.md)) · `memory_due` read before
  reviewing · orientation used for where to look only, `verify_live` rows read
  live, no finding citing the profile ([profile.md](profile.md)) · noise files
  excluded with their Summary line · candidates verified and sibling-swept ·
  every open 🔴/🟡 carrying a class-rule **Fix:**, mirrored into
  `findings-json` · skill sections reformatted and merged with no finding lost
  · stale approval dismissed when the verdict dropped below APPROVE · clone,
  copies, diff and state deleted · `review_step` events logged (`locked` →
  `fanned out (n=<N>)` → `verified` → `posted`/`aborted`/`done`) with
  `skill_timing`.
- **Style** — findings concise and diff-anchored, inline text never repeated in
  the summary; every verified 🔴/🟡 reported, 🟢 within budget
  ([finding-form.md](finding-form.md)); re-review scope matched the trigger.
- **Urgent entries** — rapid review posted or dedup-skipped **before** the full
  one; `RAPID` row and `rapid posted` step recorded; terminal only on the full
  review, the closed-PR issue, or an abort. **Closed entries** — no review
  posted, criticals in one deduped issue assigned to the author.
- **Artifacts** ([artifact.md](artifact.md)) — published to each
  `artifact_targets` surface, one comment with the surviving links, markers
  recorded.
- **Watch rules** — evaluated send-then-marker ([watches.md](watches.md)).
- **`review_progress: enabled`** — every locked PR on a terminal `success`
  status; `status_resets_due` closed out and their rows deleted.
- **`stall_alert`** — reported, DM'd under Slack, `stall_alert_sent` logged, no
  state "repaired".
- **Every `reviews_due` PR reached a terminal state** — the run never ended
  mid-pipeline, for example after a skill report; all errors logged; no
  unexpanded `$GITHUB_REPO` in any output.
