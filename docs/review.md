# Reviewing a PR

Read this file at the start of every **review run** (a run whose preflight
worklist has any of `reviews_due` / `label_cleanups_due` / `selfheals_due` /
`prunes_due` / `urgent_alerts_due` / `mentions_due` non-empty). Preflight
already made every decision — you perform the actions, with
`scripts/review-pr.sh` doing the mechanical steps, the two HEAD-freshness
checks and the pre-post dedup re-check included: they guard the race windows
that open between preflight and post time.

## Label bookkeeping (`selfheals_due`, `label_cleanups_due`)

Do these before the review loop; one log line each.

- **Self-heal** (`selfheals_due` entry `{number, sha, ts, status}`): write the
  REVIEWS.md row `| <number> | <sha> | <ts> | SEE-GITHUB | <status> |` (the
  GitHub-reported timestamp, verdict from the remote review body if you have
  it handy — `SEE-GITHUB` otherwise). `status` is `done` (marker found at the
  live HEAD) or `awaiting_label` (marker found at an older SHA, no active
  re-review trigger). Log
  `PR #<n>: self-healed REVIEWS.md from remote marker (<status>)`.
- **Same-SHA trigger cleanup** (`label_cleanups_due` entry
  `{number, label, request}`): a re-review trigger sits on a PR whose live
  HEAD is already reviewed **and whose description has not been edited since**
  — nothing to review (an edited description arrives as a `reviews_due` entry
  instead, **Description-only re-review** below). Clear what the entry flags —
  `label: true` → remove the label, `request: true` → remove your pending
  review request (commands under **Trigger removal** below) — and log
  `PR #<n>: re-review trigger present but nothing new since <short-sha> — cleared (<label / request / label + request>), no re-review`.
  Post nothing. A failed removal is logged, not fatal (preflight re-emits it
  next run).

## Pruning (`prunes_due`)

Each entry `{number, state, gist_id, dam_id}` was verified CLOSED/MERGED by
preflight this run — execute exactly this list, nothing more. Both artifact
ids come from the entry (preflight reads them from the history file's
`<!-- artifact-gist: ... -->` / `<!-- artifact-dam: ... -->` markers); if an
entry omits them, read the markers from `work/reviews/pr-<n>.md` yourself
before step 2 deletes it:

1. Artifact cleanup (each failure = log, continue — never blocks the prune):
   - `gist_id` non-null → `gh gist delete <gist_id>`.
   - `dam_id` non-null → `delete_artifact {id: <dam_id>}` via the MCP tool
     (skip silently when the tool isn't registered this session — flag off).
2. `rm -f work/reviews/pr-<n>.md work/reviews/pr-artifacts/pr-<n>.html`.
3. Delete the PR's row from REVIEWS.md, and its row from `work/SHEPHERD.md`
   when that file exists.
4. Log `PR #<n>: pruned (<state>)`.

Never prune anything not in `prunes_due`; never bulk-delete.

## Per-PR review sequence (`reviews_due`)

Each entry: `{number, head_sha, head_ref, title, author, kind, takeover,
prior, urgent, closed}` — plus `eta_seconds` under `review_progress: enabled`
(**Progress signal on GitHub** below). `kind` is `first` or `re-review`; `prior` carries
the last review's `{sha, ts, verdict}` when one exists; `urgent`/`closed`
route through **Urgent PRs** / **PR closed mid-review** below (urgent entries
come first in the worklist — keep that order). Complete ALL steps before the
next PR:

a. **Prepare** — `bash "$HOME/scripts/review-pr.sh" prepare <n>` (`--eta
   <seconds>` from the entry under `review_progress: enabled`; `--on-demand`
   for an on-demand review). It performs Check 1 from the live PR: draft →
   `skip`; closed → `skip` (the next heartbeat prunes) unless a `RAPID` lock
   still owes the full review (mode `closed`, **PR closed mid-review**); a
   `re-review` whose trigger is gone → `skip` (the trigger is live per
   `rereview_trigger` — `$REREVIEW_LABEL` in the labels and/or `bot_login`
   among the requested reviewers — and it sets the scope: label → `full:
   true`, else delta, **Re-review output**); a live holder → `stand_down`
   (**Live holder**). Then it writes the `in_progress` lock row (fresh SHA,
   current UTC time), logs `locked`, writes the progress status, fetches the
   PR context and the diff into `$PR_DIR.diff` with a hunk index, clones the
   branch with its base ref ([skills.md](skills.md) → **Clone, credential
   helper, cleanup**), makes the per-skill copies and briefs, and builds the
   context pack. Its JSON carries `outcome` (`ready` | `skip` | `stand_down`
   | `error`), `kind`, `full`, `urgent`, `prior`, `files[]` (classified),
   `skills{}` (per skill `run` | `no-matching-files` | `clone-failed`, routed
   files, brief, workdir), `delta` (the re-review range, **Re-review
   output**), `profile_slice`, `history_slice`, `memory_due`,
   `structure_changed`, `paths`. `error` → retry once, then move on (no lock
   was written). `urgent: true` → **phase 1** (**Urgent PRs**) before b.
b. **Orient.** Read the `memory_due` files and the entry's `profile_slice` and
   `history_slice` ([profile.md](profile.md)); a `verify_live` row names a
   source this PR changes — read the live file, not the row. `paths.pack`
   lists, per changed code file, its dependents, its tests and its changed
   lines; `paths.context` holds body, comments, reviews and inline threads
   with your own past reviews dropped and bots flagged (**PR context**).
c. **Review the diff** — `$PR_DIR.diff`, file by file in the order of
   `files[]`: the `code`, `test`, `docs` and `config` classes. The noise
   classes (`lockfile`, `snapshot`, `build`, `vendored`, `minified`,
   `sourcemap`, `generated`) are not reviewed as code and get one line in
   `### Summary`: `_<N> generated/lockfile file(s) not reviewed: <paths, or
   the classes when more than five>._`
d. **Run every configured review skill** per [skills.md](skills.md):
   `review-pr.sh step <n> "fanned out (n=<N>)"`, one subagent per skill with
   status `run` — its prompt is the brief file `prepare` wrote — then
   `review-pr.sh collect <n>`: the audit lines (one per configured skill, echo
   them), form warnings, the `skill_timing` event. Verify your candidates
   (**Full-file verification**) with `review-pr.sh context <n> <path> <line>`
   — the numbered surrounding code, and whether the line lies inside this
   PR's hunks — and sweep siblings with `review-pr.sh sweep <n> '<regex>'`
   (**Sibling sweep**); then `review-pr.sh step <n> verified`. On a re-review,
   `review-pr.sh delta <n> findings.json` classifies your findings against the
   prior `findings-json` — `fixed` / `still` / `new`, `suppressed` by PR-local
   overrides, `ambiguous` pairs left to you — and returns the `### Changes
   since last review` skeleton (**Re-review output**).
e. **Compose**: `body.md` (the structured review from `### Summary` to
   `### Verdict` — **Output format**), `findings.json` (the `findings-json`
   array) and, for inline-carried findings, `comments.json` — `[{path, line,
   side, body[, start_line]}]` with each comment's full text (**Mapping
   findings to inline comments**). Output the review to the chat UI.
f. **Post** — `bash "$HOME/scripts/review-pr.sh" post <n> --verdict <VERDICT>
   --body body.md --findings findings.json [--comments comments.json]`. It
   performs Check 2 and the pre-post dedup re-check, maps every inline comment
   against the hunk index (outside the hunks or beyond the cap of 25 → moved
   to the summary under `### Findings not anchorable inline`, its
   `findings-json` entry set to `inline: false`), assembles the payload
   (**Posting the GitHub review**), posts with the documented 422 handling,
   removes `$REREVIEW_LABEL` when present, dismisses a stale approval on a
   re-review below `APPROVE`, appends the posted body to `reviews/pr-<n>.md`,
   writes the `done` row and the terminal progress status, logs `posted
   <verdict>` and `done`, and deletes the clone, its copies, the diff and the
   state — exactly once. Outcomes: `posted` (`url`, `moved_to_summary`,
   `label_removed`, `dismissed_approval`) · `aborted` (HEAD moved, draft,
   trigger withdrawn, the dedup check unreadable after its retry, 422
   `commit_id`, post failed after one retry — the lock
   released per kind: `first` deletes the row, `re-review` restores the prior
   row — `awaiting_label`, or `done` for a same-SHA re-review; log the reason
   in the chat UI) · `duplicate`
   (this marker is already on GitHub — the row self-healed with its
   timestamp) · `closed_*` (**PR closed mid-review**). Then evaluate any
   configured watch rules ([watches.md](watches.md)).
g. **Anything else that ends the PR** — a transient failure after its retry,
   a decision not to post — `bash "$HOME/scripts/review-pr.sh" abort <n>
   <reason>`: the lock released per kind, the abort status, `aborted
   <reason>` logged, everything cleaned up. Every entry ends in `posted`,
   `duplicate`, `closed_filed` / `closed_discarded`, or `aborted`.

Under `review_progress: enabled` this sequence also publishes its progress to
the PR — **Progress signal on GitHub** below.

**Progress logging (stall diagnosis).** A session that dies mid-review must
leave a trace of where it stopped, so each milestone of this sequence appends a
`review_step` event to the structured log ([logging.md](logging.md)). The last
event logged for a PR pins the exact step a stall stopped at; consecutive
timestamps give per-step durations.

**Every step is logged for you.** `review-pr.sh` writes them as it performs
them — `locked` and `cloned` (`prepare`), `locked (refresh, …)`, `fanned out
(n=<N>)` and `verified` (`step`), `rapid posted` (`rapid`), `posted <verdict>`
and `done` (`post`), `aborted <reason>` (`post` / `abort`) — and the
`PostToolUse` adapter hook derives `skill:<name> done` from each subagent call
([logging.md](logging.md) → **Harness adapters**). In the manual fallback
(no script) the hook still derives `cloned`, `posted <verdict>` and `locked` /
`done` / `aborted (lock released)` from the commands that perform them
(**Review tracking state**), and the rest is yours, chained onto the step's
existing command:

```bash
. "$HOME/scripts/log.sh" && LOG_JOB=review logev info review_step "PR #<n> <sha-short> <step>"
```
The `Stop` hook below judges terminality on `locked` / `done` /
`aborted <reason>`, which is why the event's filename and `msg` shape are a
contract — a step written any other way is invisible to the hook and reads as a
review that never finished ([logging.md](logging.md) → **The shape is a
contract**).

**The two step-d events bound the phases that dominate a slow review.**
`fanned out (n=<N>)` goes immediately before the skill fan-out and `verified`
immediately after full-file verification, so three durations become readable:
fan-out to first collected output (the skill phase), `verified` to `posted`
(compose plus Check 2), and the verification window between them. Per-skill
durations come from the output-file mtimes, not from `skill:<name> done`
([skills.md](skills.md) → **Invocation & audit log**).

**Lock heartbeat — refresh the row as you go.** Before each of steps c, d, e
and f, `review-pr.sh step <n> "<what comes next>"` rewrites your PR's
REVIEWS.md row with the **current** UTC time (same fields otherwise, status
stays `in_progress`) and logs `locked (refresh, <what comes next>)`; the
`fanned out (n=<N>)` and `verified` milestones of step d are `step` calls too.
Cheap, and it is what keeps a long review from *looking* abandoned: the
timestamp is the age preflight measures and the event is the liveness signal it
reads (**Live holder** below). A review that refreshes never crosses the TTL at
all.

**When the adapter is not active, every step is yours** — a non-Claude-Code
harness, or the audit's `harness_adapter` check warning that
`log-review-step.sh` is unregistered. Duplicate events are harmless (the hook
reads steps as a set), so when in doubt, log it.

**Completion enforcement.** These events are also read back, at end of turn, by
the `Stop` harness hook ([logging.md](logging.md) → **Harness adapters**): a PR
logged `locked` in this run with no later `done` / `aborted <reason>` means the
turn is ending mid-pipeline, so the hook refuses the stop and names the PRs,
their last logged step, and the steps still owed. `rapid posted` and
`skill:<name> done` are **not** terminal. It blocks up to **3 times per run**
(counting its own past `review_incomplete` events), the final attempt leading
with the explicit-abort route, then allows the stop and logs
`enforcement exhausted` — a nudge, never a trap, and never a reason to pad
review content. It makes no GitHub calls and no state writes and enforces only
what the log already proves — a backstop for the invariant, never a substitute
for driving each PR to its terminal state. Missing `review_step` events blind
it: log them as the sequence says.

**Stalled-review rate alert.** Per-run enforcement can't see a *pattern* of
stalls, so preflight counts the `stale in_progress lock` takeovers of the last
24 h. At or above `stall_alert_threshold` (missing = `4`; `0`/`off` disables) it
emits `stall_alert: {count, threshold, prs, window_hours, per_day_7d}` — **once
per UTC day** (`work/.stall-alert-day`, claimed under a `mkdir` lock so
concurrent heartbeats can't double-send). `per_day_7d` carries per-day counts
over the retained window, so the report shows whether this is new or chronic. A
single stall is normal (HEAD moved, pod restart); a cluster means reviews are
being repeatedly redone at full cost. Live holders are no longer taken over
(**Live holder** below), so every counted takeover is a real death — a
slow-but-healthy pipeline can't inflate this number.
Deliver it **once per run, after the run's review work**, so the numbers include
this run:

1. Report it in the chat UI: count, threshold, affected PR numbers, and the
   `per_day_7d` trend.
2. Under `slack_notifications: enabled` **and** an `escalation_owner`, also DM
   that person (never the shared channel — this is operations, not team news;
   roster-only mentions still apply). Slack off or no owner → chat UI only.
3. Log `stall_alert_sent <count>` ([logging.md](logging.md)); a failed send is
   logged and never retried this run (the marker is already written).

The alert is a *signal, not a repair*: never bulk-clear locks, re-review, or
change a threshold in response — investigate per [logging.md](logging.md) →
triage, and treat a recurring cause as an operational lesson
([preferences.md](preferences.md)).

```bash
MARKER="<!-- $REVIEW_MARKER headRefOid=<full-sha> -->"
gh api "repos/$REPO/pulls/<n>/reviews" \
  --jq ".[] | select(.body != null) | select(.body | contains(\"$MARKER\")) | .submitted_at"
gh pr view <n> --repo "$REPO" --json comments \
  --jq ".comments[] | select(.body | contains(\"$MARKER\")) | .createdAt"
```

### Trigger removal

Label: prefer the REST call — `gh pr edit` goes through GraphQL, which 401s
in this pod (the platform's auth proxy doesn't rewrite that code path):

```bash
gh api -X DELETE "repos/$REPO/issues/<n>/labels/$REREVIEW_LABEL" >/dev/null \
  || gh pr edit <n> --repo "$REPO" --remove-label "$REREVIEW_LABEL"
```

Pending review request (same-SHA cleanup only — a served request clears
itself when the review posts):

```bash
gh api -X DELETE "repos/$REPO/pulls/<n>/requested_reviewers" -f "reviewers[]=$BOT_LOGIN" >/dev/null
```

## Progress signal on GitHub (`review_progress`)

`review_progress: enabled` in `work/CONFIG.md` (missing = `disabled`) publishes
the review's progress as a **commit status** on the SHA being reviewed, so the
PR shows that a review started, where it is, and roughly how long it takes.
One call per update, `context` = `$REVIEW_MARKER` (stable per instance, like
the marker itself):

```bash
gh api -X POST "repos/$REPO/statuses/<sha>" -f state=<state> \
  -f context="$REVIEW_MARKER" -f description="<line>" >/dev/null
```

Add `-f target_url=<url>` for the rows that have one. Keep `description` to one
short line — GitHub truncates it past 140 characters.

| Written at | `state` | `description` | `target_url` |
| --- | --- | --- | --- |
| `prepare` — lock written | `pending` | `queued <HH:MM>Z · fetching diff and clone<eta>` | — |
| `prepare` — clone finished | `pending` | `reviewing since <HH:MM>Z · diff + <k> skill(s)<eta>` | — |
| Urgent phase 1 — rapid posted | `pending` | `rapid preliminary review posted · full review running` | the rapid review |
| `post` — review posted | `success` | `<VERDICT> · <a> critical, <b> warning, <c> suggestion · took <m>m` | the posted review |
| `post` / `abort` — posting aborted | `success` | `no review posted — <reason>; retrying next heartbeat` | — |
| PR closed mid-review | `success` | `PR closed · <n> critical finding(s) in issue #<i>` | the issue |
| `status_resets_due` entry | `success` | `review abandoned — resumes when the PR is ready` | — |

- `<eta>` is ` · usually ~<N> min` from the entry's `eta_seconds` — whole
  minutes, minimum 1 — and is left out entirely when that field is `null`.
- **`description` is ASCII** — the statuses API rejects 4-byte UTF-8
  (`Description doesn't accept 4-byte Unicode`), so severity words replace the
  emoji here; the review body keeps them.
- Write on the SHA the review locked at Check 1, so a status never describes a
  commit it did not read.
- Every terminal outcome is `success`, aborts included: `failure`/`error` would
  turn the agent into a merge gate the moment someone makes the context a
  required check.
- **Written by `review-pr.sh`** at the step that owns the row (`prepare`,
  `rapid`, `post`, `abort`); the manual fallback issues the same call at the
  same step, chained onto the command that step already runs.
- **Best-effort throughout**: a failed write is logged
  (`progress_status`, warn — [logging.md](logging.md)) and changes nothing
  about the review; never retried, never a reason to abort.

**`status_resets_due`** — entries `{number, sha, reason}` for a PR whose locked
review was abandoned with a status left `pending` (`reason: draft` — the PR
became a draft, so no review will resume it). Per entry: write the terminal row
above, then **delete the PR's REVIEWS.md row** (the `reviews/pr-<n>.md` history
stays); the missing row is what keeps the reset from repeating.

## Urgent PRs — rapid-first delivery

`urgent_label` in `work/CONFIG.md` (missing = feature off) names a
**human-managed** GitHub label — the agent never adds or removes it. While
the label is on a PR, every due review of it (any `kind`) runs rapid-first:
preflight flags the entry `urgent: true` and orders urgent entries ahead of
the rest; Check 1 re-verifies the label (gone → review normally).

**Immediate Slack alert (`urgent_alerts_due`, once per PR).** Preflight emits
`{number, title, author, url}` for every open urgent PR whose history file
lacks an `urgent-announced` marker — only under `slack_notifications:
enabled`. Send these **first, before any other run work**:

1. Mentions: roster members (`work/DEVELOPERS.md`) with a `slack_id` —
   filtered to those currently online when a Slack presence lookup is
   available this session, otherwise all of them. **Never anyone outside the
   roster** ([shepherd.md](shepherd.md) → Hard rules).
2. Send via `mcp__platform-outbound__send_channel_message`:
   `🚨 **<bot_display_name>** — URGENT: PR #<n> "<title>" by <author> needs eyes now (\`<urgent_label>\`). <@id1> <@id2> … Rapid review incoming. <url>`
3. **Write the marker immediately after the send succeeds**:
   `<!-- urgent-announced: <ISO timestamp> -->` into `reviews/pr-<n>.md`
   (create the file with its title heading if missing). A failed send
   writes no marker and is logged — the next heartbeat re-emits the alert.
4. Log `PR #<n>: urgent alert sent (<k> mentioned)`.

**Phase 1 — rapid preliminary review.** Optimize for delivery speed — right
after `prepare` returns, before orientation and skills:

1. Review the diff only (`$PR_DIR.diff`; on re-reviews prefer the range since
   the prior review — the compare call under **Re-review output** — full diff
   as fallback) for **🔴 Critical findings only**.
2. Write `rapid.md`, body only (no inline comments):

   ```
   ⚡ **<bot_display_name>** — ⏱️ Rapid preliminary review @ `<sha-short>`

   > Fast pass triggered by the `<urgent_label>` label — critical checks
   > only. **The full review follows.**

   ### Critical findings
   - 🔴 **Critical:** <one-liner> (`file:line`)
   ```

   No criticals → the section body is the single line
   `_None found at rapid-review depth._`
3. `bash "$HOME/scripts/review-pr.sh" rapid <n> --body rapid.md` — it dedups
   by the **rapid marker** `<!-- <review_marker>:rapid headRefOid=<full-sha> -->`
   at the live HEAD (`already_posted` → phase 1 was delivered, go straight to
   phase 2), posts a single `event: COMMENT` review with the marker appended,
   sets the REVIEWS.md verdict cell to `RAPID` with a fresh UTC timestamp
   (status stays `in_progress`), logs `rapid posted`, and writes the progress
   status.

**Phase 2 — full review, immediately after** — the normal per-PR sequence
from step b. The `:rapid` marker is invisible to the normal dedup (different
prefix), so the full review posts as usual; watch rules evaluate once, after
the full review. A rapid post is **never** terminal: the PR is done only when
the full review posted or the entry aborted (a died run is recovered by the
stale-lock takeover — verdict `RAPID` tells the next run to skip phase 1).

## PR closed mid-review — critical findings become an issue

Applies to **every** review, urgent or not. When `post` finds the PR
`CLOSED`/`MERGED` at Check 2, no review is posted; its outcome says what is
left:

- **`closed_discarded`** — no 🔴 finding in `findings.json`: the lock was
  released per kind, exactly like a Check 2 abort; log
  `PR #<n>: closed mid-review — discarded (no critical findings)`.
- **`closed_criticals`** — the 🔴 findings (`criticals`), the issue marker
  (`issue_marker`) and `existing_issue` when an issue with that marker is
  already filed. Deliver them as one GitHub issue: reuse `existing_issue`, or
  `gh api "repos/$REPO/issues" -X POST -f title="Critical findings from review of closed PR #<n>" -f body=… -f "assignees[]=<author>"`
  — body: the 🔴 findings in full, a `#<n>` reference (links the issue to the
  PR), and the trailing `:issue` marker line; a failed assignment is logged,
  the issue stands. Then rerun `post … --closed-issue <id>` →
  **`closed_filed`**: the review is appended to `reviews/pr-<n>.md` with a
  `_Delivered as issue #<id> — PR closed before posting._` note, the lock
  becomes a `done` row, the progress status names the issue. Log
  `PR #<n>: closed mid-review — <k> critical finding(s) filed as issue #<id>`.
  The next heartbeat prunes the closed PR's state as usual.

Crash recovery: preflight emits a closed PR whose row is an `in_progress`
lock with verdict `RAPID` (rapid posted, full review still owed) as a review
entry flagged `closed: true` instead of a prune. `prepare` runs it in mode
`closed` — the lock refreshed with verdict `RAPID`, no clone, no skills (the
branch may be gone), the Check 1 gates not applied — then review the diff and
`post` as above.

## On-demand review (Slack or mention)

The one non-operator request that triggers work ([runbook.md](runbook.md) → **Instruction
sources & trust boundary**): **anyone** in the connected channel — or in a
GitHub comment addressed to the bot ([mentions.md](mentions.md)) — may ask
for a review of a specific PR — equivalent to adding `$REREVIEW_LABEL`.
Nothing else about the agent is changeable from those surfaces — its writes
stay within `work/` state, the reply, and the review itself; the definition
repo is never touched.

1. Resolve the PR reference (number or URL; a mention's own PR when none is
   named); `gh pr view` — not found / closed / draft → reply so in the
   requesting channel or thread, done.
2. `bash "$HOME/scripts/review-pr.sh" prepare <n> --on-demand` —
   `stand_down` (a live run owns the PR, **Live holder** below) → reply
   "review already running", done; a stale, silent lock is taken over — log
   `PR #<n>: stale lock killed on on-demand request`.
3. `skip` with `already reviewed at <short-sha>` (the live HEAD is the
   reviewed one) → reply so; same-SHA dedup always holds.
4. `ready` → the per-PR sequence above from step b (kind = `re-review` when a
   prior review exists, else `first`; re-reviews run **delta scope** unless
   `$REREVIEW_LABEL` is also on the PR — no trigger is required at `prepare`
   or `post`; install missing skills per the fallback in skills.md →
   Installation), reply in the requesting channel or thread with a link to
   the posted review, and persist `work/` (persistence.md).

Replying to the requesting surface is responsive, not proactive — it does
not require `slack_notifications: enabled` (that gates outbound nudging).

## PR context: body, comments, reviews

`prepare` fetches them into `paths.context` (`context.json`: `body`,
`comments`, `reviews`, `inline` threads — every item with `author`, `is_bot`
and its timestamp; your own marker-carrying artefacts already dropped). A
fetch that did not respond leaves an empty list and a logged warning —
reviewing without context just means more conservative output. Use context as
input, not authoritative truth:

1. **Body** — feeds the Summary; if it explicitly justifies a pattern you'd
   flag, suppress that finding.
2. **Top-level comments** — a prior reviewer's issue with an accepted
   author/maintainer justification → don't re-raise. Still-argued → surface.
3. **Review summaries** — note `APPROVED` and open `CHANGES_REQUESTED`; if
   requested changes still exist in the diff, surface them.
4. **Inline threads** — resolved on the same file/line → suppress overlapping
   findings; unresolved → consider whether yours adds anything.

**Weight humans over bots** (`is_bot`) unless a human endorsed the bot's
claim; anything containing `<!-- <review_marker> headRefOid=... -->` is your
past self and is not context.

**Learn while you read**: context revealing a generalizable team convention
or recurring human-reviewer concern is recorded after posting, per
[preferences.md → Observed insights](preferences.md) — no extra API calls,
only genuinely new insights, at most 2 per PR.

**Audit note** — when suppressing, append to `### Summary`:
`_(Suppressed N finding(s) per PR-local overrides: <ids>. Suppressed M finding(s) per PR context: <ids>.)_`
— omit either part when its count is zero.

## Criteria & review style

Unless preferences say otherwise: **Correctness** (logic, off-by-one, null
risks, races) · **Security** (injection, credential leaks, OWASP top 10) ·
**Performance** (allocations, N+1, missing indexes) · **Architecture**
(coupling, layer boundaries, broken contracts) · **Tests** (missing coverage,
flaky patterns) · **Maintainability** (dead code, error handling). Very large
diffs (>2000 lines): focus on the most critical files but still post a full
review.

**Audience: agent-written, agent-read code.** Assume the code under review
was written by AI agents and will be read and modified by AI agents.
Human-readability is not a review goal — naming taste, cosmetic structure,
comment density, file layout, and "this would be clearer as…" restructuring
are flagged **only** when they create a real defect risk (a misleading name
that hides a bug, dead code that changes behavior, an abstraction that breaks
its contract). Never request restructuring purely for human readers.

**Full-file verification (end of step d — candidates come from step c's diff
review, verification runs after the skills, before composing output).** The diff
nominates findings; the surrounding code confirms them. Re-check each candidate
against the code around it in the clone: `review-pr.sh context <n> <path>
<line> [radius]` prints **numbered source text** (±40 lines by default) and
whether the line lies inside this PR's hunks — `no` marks a pre-existing
problem, at most one 🟢 line. Read the whole file only when that range leaves
the question open. Keep what survives;
when unsure, drop it (a false positive costs more credibility than a missed
nit). No clone (`clone-failed`) → verify against the diff context you have.

**Sibling sweep (same pass).** For each surviving 🔴/🟡, check the files this
PR changes for further occurrences of the same defect class —
`review-pr.sh sweep <n> '<regex>'` returns the hits in the changed files and a
count in untouched code. Report them as
one finding listing every location, so one fix round closes the class. The
sweep covers changed files only; an occurrence in untouched code is a
pre-existing problem ([finding-form.md](finding-form.md)). On a delta
re-review both passes cover only the files changed since the prior review
(**Re-review output**).

**Language: ASD-STE100 (Simplified Technical English).** Write every outward
text (reviews, inline comments, issues, mention replies, chat, Slack) in STE
style: one topic
per sentence (aim ≤ 20 words), active voice, simple tenses, one term per
concept, no idioms or synonym variation. STE governs wording, never content.

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

`### Findings` is the canonical, complete list on first reviews, but **never
repeats inline text**: a finding that maps to an inline comment (rules below)
appears here as one line — severity + short label + `file:line` — while its
full description, rationale, and suggestion block live only in the inline
comment. Summary-only findings keep their full text here. One format for
every channel (chat UI, GitHub body, history file); the one-liners are enough
for re-review delta matching.

## Merging findings across sources

Your diff review and every skill section report into one review, so the same
defect can arrive more than once. Compose the output from all of them together:

- **One defect, one finding.** The same defect class at the same location from
  two sources appears **once** — keep the strongest severity, merge the
  locations into that one entry, and name the reporting sources in the
  description.
- Its home is the strongest place it qualifies for: `### Findings` plus an
  inline comment when it maps inline (**Mapping findings to inline comments**),
  otherwise the section of the first reporting skill in table order.
- A blocking finding that stays in a skill section is mirrored into
  `### Findings` as one line with its **Fix:**, so the bar stays complete.
- **Merging drops duplicates, never findings** — a defect reported by only one
  source always survives, whatever its severity, and there is no cap on how
  many a review may carry. Merging changes what the review prints, never what a
  skill reported: each skill keeps its own `findings=<N>` audit line
  ([skills.md](skills.md)).

## Re-review output (trigger-gated; new commits or an edited description)

The trigger sets the scope:

- **`$REREVIEW_LABEL` → complete re-review** (`full: true`): review the
  **entire PR** at the live HEAD, first-review depth — the label is the
  human's "look at all of it again". Output = the first-review format with
  the `### Changes since last review` block below inserted for continuity;
  `### Findings` lists **all current findings** in full (new and
  still-present; `✅ Fixed` stay one-liners in the block). Inline comments
  still map only `🆕 New` findings (carryovers keep their existing thread);
  skill sections post in full, not condensed. `findings-json` carries
  `new`/`still`/`fixed` statuses as found.
- **Review request / on-demand ask → delta re-review** (`full: false`):
  report the delta only, never a restatement of the previous review — the
  conciseness rules below.

**Description-only re-review** (`description_changed: true`): the trigger is
answered by an edited PR body, not by new commits — the diff and the SHA are
the ones already reviewed, so `post` reads the earlier review's marker at this
SHA as the prior being superseded, not as a duplicate, and an abort restores
the `done` row. Re-read the body (**PR context: body, comments, reviews** above) and redo the review against it: a justification that has been removed no
longer suppresses its finding, and one that has been added now does. Scope
still follows the trigger. In `### Changes since last review`, `Previous HEAD`
is the same SHA — say `description edited, no new commits` on that line, and
let the buckets carry what the corrected description changed. Nothing changed
in substance → say so in one line rather than re-posting the previous review.

Both scopes: `review-pr.sh delta <n> findings.json` matches your findings
against the prior review's `findings-json` line in `reviews/pr-<n>.md` (older
reviews without one: parse the visible text yourself) and returns the block
below with its `fixed` / `still` / `new` buckets, the `suppressed` overrides
and the `ambiguous` pairs you decide; then insert it between `### Summary` and
`### Findings`:

```
### Changes since last review
Previous HEAD: <short-sha> (<timestamp>) — verdict <PREV_VERDICT>[ — unreachable, reviewed the whole PR]

- ✅ **Fixed:** <one-liner> (`file:line`)
- 🔁 **Still present:** <one-liner> (`file:line`)
- 🆕 **New:** <description> (`file:line`)
```

Delta-scope review depth (steps c–d):

- **One compare call decides the range, and `prepare` makes it** — its base
  is the `headRefOid=` of the last review marker in `reviews/pr-<n>.md`, and
  the result comes back as `delta` = `{base, status, reachable, files[]}`.
  `status: ahead` with a `patch` on every file → `reachable: true` and delta
  depth on `delta.files[]`. `status: identical` (or the base already at HEAD)
  → `reachable: true` with an empty `files[]`, the description-only case
  below. Any other outcome — `diverged` / `behind` (force-pushed away), 404,
  300 files or a file without `patch` (truncated) → `reachable: false`: review
  at complete depth in the delta output format, with ` — unreachable, reviewed
  the whole PR` appended to the `Previous HEAD` line.
- **Candidates come from the range's hunks only** (`gh api
  "repos/$REPO/compare/<delta.base>...<head-sha>"` for the patches, or read
  them in the clone), in files the PR diff touches; a hunk whose added lines are absent from the PR diff arrived with
  a base-branch merge and is not a candidate. The full PR diff is context
  for reading them. A description-only re-review has an empty range:
  candidates, verification, the sweep and extension-skill routing all use
  the full PR diff and its changed files, re-read against the edited body.
- **Each prior finding is settled at its anchor**: read every `file:line` of
  the prior `findings-json` at HEAD — from the clone, or without one via
  `gh api "repos/$REPO/contents/<path>?ref=<head-sha>" -H 'Accept: application/vnd.github.raw'`
  — and classify it `fixed` / `still` (code that moved is `still`, at its
  new line); a `line: null` finding is settled by re-reading its file.
- **Full-file verification and the sibling sweep cover the range's files.**
  `prepare` has already routed extension-triggered skills from that same list
  ([skills.md](skills.md) → **Triggers & file routing**); `always` skills run
  unchanged. A skill
  routed no file is skipped `no-matching-files` (section omitted); its prior
  findings are settled from the prior review — blocking ones through
  `findings-json`, 🟢 through its prior section text — and appear as
  one-liners in the buckets above.

Delta-scope conciseness rules (all output channels — chat UI, GitHub body,
history file):

- Include only non-empty buckets; every bucket entry is a **single line**.
  Never re-expand a carryover's full description, rationale, **Fix:**, or
  suggestion — its original review and inline thread already carry them.
- `### Findings` lists **only `🆕 New` findings** (inline-carried ones as
  one-liners — Output format above). No `✅ Looks good` bullets on re-reviews
  — ever. Nothing new → the section body is the single line
  `_No new findings at this HEAD._`
- The **Verdict still weighs all current findings** — new *and*
  still-present, plus skill findings: an unfixed 🔴 keeps `REQUEST_CHANGES`
  even though it appears only as a one-liner under `### Changes since last
  review`.
- Skill sections (runs per the depth rules above) are condensed
  the same way: findings unchanged from the prior review collapse into one line —
  `🔁 <N> finding(s) from the previous review still present (see review at <short-sha>)`
  — full text only for new findings; clean-run lines stay as-is.
- Inline eligibility: mapping rule 5 (only `🆕 New`; carryovers keep their
  existing thread).

Prior review file missing → skip the section, review as a first review (full
format), append `(no prior review on file)` to `### Summary`.

## Review tracking state

**REVIEWS.md** — one row per PR:
`| <number> | <headRefOid> | <ISO timestamp> | <verdict> | <status> |`

- `status` = `in_progress` (lock; verdict `-`, or `RAPID` once an urgent PR's
  rapid preliminary review posted — timestamp = lock/rapid-post time), `done`
  (timestamp = post time), or `awaiting_label` (a `done` review exists but
  newer commits arrived; waiting for a re-review trigger — `$REREVIEW_LABEL`,
  or a pending review request for `bot_login` when `rereview_trigger`
  enables it).
- An `awaiting_label` row keeps the **SHA, verdict, and timestamp of the last
  posted review** — the one row type whose timestamp is not the write time.
  Preflight writes this flip; you never do (except when restoring it on a
  re-review abort).
- All other timestamps are the actual UTC write time
  (`date -u +%Y-%m-%dT%H:%M:%SZ`) — never rounded, reused, or fabricated.
- The lock is best-effort (**50-min TTL**, `LOCK_TTL_MIN` in
  [preflight.sh](../scripts/preflight.sh); takeover flagged by preflight only
  when the holder is *also* silent — **Live holder** below) — the remote dedup
  check stays authoritative.
- `review-pr.sh` writes every row (`prepare` locks, `step` refreshes,
  `rapid` sets `RAPID`, `post` / `abort` finish). In the manual fallback, row
  edits (lock, `done`, `awaiting_label` restore) rewrite the PR's line in
  place; rows are full of `|`, so give sed a different delimiter:

  ```bash
  sed -E "s#^\| *<n> \|.*#| <n> | <sha> | <ts> | <verdict> | <status> |#" work/REVIEWS.md \
    > work/REVIEWS.md.tmp && mv work/REVIEWS.md.tmp work/REVIEWS.md
  ```

  Keep this row shape in the command — the harness adapter derives `locked`,
  `done` and `aborted (lock released)` from it (**Progress logging**).

### Live holder — a lock past its TTL that is still working

**The TTL bounds a crash, not a slow review.** A lock past `LOCK_TTL_MIN` is
only a *candidate*: preflight reads the holder's `run` id from its
`review_step … locked` event and emits `takeover` **only when that run has
logged nothing for `HOLDER_QUIET_MIN` minutes** (20 — above the longest gap a
healthy review shows between events, measured at 16.7 min; both values in
[preflight.sh](../scripts/preflight.sh)). Otherwise the PR is omitted and logged
`holder … active — left running`. The check is a local log read, no API call.

So two independent things must both go quiet before a takeover: the row's
timestamp (**Lock heartbeat** above) and the event stream. A holder doing either
keeps its PR.

The holder finishes because it is *further along* than any fresh job: letting it
post is both the fastest delivery and the only way to keep the work — a
takeover's first act is `prepare`'s reclaim of `/tmp/review-pr-<n>*`
([skills.md](skills.md) → **Clone, credential helper, cleanup**), which destroys
a finished fan-out before any judgement applies.

**As the holder you own the PR to a terminal state whatever your lock age** — a
lock past the TTL is never a reason to abandon or skip posting; keep refreshing
(**Lock heartbeat** above) and finish. Safety is already guaranteed by step f —
if a second job posted at your SHA meanwhile, the pre-post dedup check turns your
run into a self-healing abort, so no duplicate can post.

**As the taker, exclusivity is re-checked at Check 1 for every entry, whatever
its `takeover` flag.** `takeover: true` means "preflight saw no life", not proof
of death — the holder may wake between preflight and you. `takeover: false`
means only that the worklist's snapshot saw no lock: on a busy heartbeat that
snapshot predates your arrival by minutes, and another run may have locked the
PR in between. `review-pr.sh prepare` re-checks it before anything else: the
PR lives when a tree, diff or state of `/tmp/review-pr-<n>*` is younger than
20 minutes (`HOLDER_QUIET_MIN`), or when another run logged a `review_step` on
this PR within those 20 minutes. Then it stands down — `outcome: stand_down`,
nothing touched, `holder alive at Check 1 — stood down` logged — and you
continue with the next PR. A tree older than that with no such event is a dead
run's leftover and is reclaimed; the lock write comes only after this check.

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

Title header + overrides stay at the top; reviews append below, oldest first,
separated by `---`. On title change, update the header. The
`<!-- artifact-gist: ... -->` and `<!-- artifact-dam: ... -->` markers (when
present) sit right after the title, each on its own line, overwritten in place
by the artifact step ([artifact.md](artifact.md)); pruning reads both to clean
up the gist and the DAM artifact. Omit a marker line when that surface wasn't
published. Watch-rule dedup markers (`<!-- watch-sent: <id> -->`,
[watches.md](watches.md)) follow on their own lines when present.

### Applying PR-local overrides

**Strictly scoped to their own PR.** Reload the list fresh per PR; discard
before the next PR. Suppress candidate findings matching an entry (same file
+ overlapping line, or the same backticked symbol in an entry naming the file —
`` `query()` `` in the finding and `` `query()` `` + `` `src/a.ts` `` in the
override) and add the Summary audit note. Overrides
only suppress, never add; if the code moved so an override no longer matches,
the finding surfaces normally.

## Posting the GitHub review

`review-pr.sh post` submits one PR review — summary and inline comments in a
single submission — from three inputs: `body.md` (**Output format**, from
`### Summary` to `### Verdict`), `findings.json` (the `findings-json` array
below) and `comments.json` (`[{path, line, side, body[, start_line]}]`, one
entry per inline-carried finding, `body` its full text). The payload it
builds and posts to `repos/$REPO/pulls/<n>/reviews`:

```json
{ "commit_id": "<full headRefOid>", "event": "<COMMENT | APPROVE | REQUEST_CHANGES>",
  "body": "<summary body — below>",
  "comments": [ {"path": "src/foo.ts", "line": 42, "side": "RIGHT", "body": "🟡 **Warning:** …"} ] }
```

`event` = the Verdict verbatim; `commit_id` = the reviewed `headRefOid`
(server-side stale guard — GitHub 422s if HEAD moved, and `post` aborts).

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
**mandatory** (drives dedup) and uses the full 40-char SHA.

**`findings-json`** — machine-readable copy of the review's `### Findings`
(the code's authors are agents too), on one line right above the marker, in
every posted full review. One object per finding: `status`
(`new`|`still`|`fixed` — first reviews all `new`), `severity`
(`critical`|`warning`|`suggestion`), `file`, `line` (null when not
anchorable), `inline` (got an inline comment), `summary` (short label, ≤ ~10
words), `fix` (the **Fix:** line condensed to ≤ ~15 words; `null` on
`suggestion` and on `fixed` entries). `critical` and `warning` are the
blocking set — this line is the machine-readable approval bar the next
re-review checks against. Keep the JSON free of `--` sequences (HTML-comment
safety — use `–`). Empty findings → `[]`. Rapid preliminary reviews don't
carry it. A prior review without `fix` (pre-3.1.0) parses as before.

### Mapping findings to inline comments

1. Inline-eligible = `(file, line)` inside a diff hunk: `path` repo-relative,
   `line` in the new file (`side: "RIGHT"`; `"LEFT"` + old line for deleted
   code); multi-line: `start_line`, both ends in the same hunk.
2. Not in any hunk / no precise line → summary-only: `post` checks every
   comment against the hunk index and moves the ineligible ones under
   `### Findings not anchorable inline` (else the whole POST 422s).
3. `✅ Looks good` → summary-only, never inline (first reviews only — none on
   re-reviews at all).
4. **Cap 25 inline comments** — `post` keeps 🔴/🟡 first and moves the excess
   🟢 to the summary.
5. **Re-reviews: only `🆕 New` findings inline** — carryovers keep their
   existing thread; `✅ Fixed` get nothing.

**Suggestion blocks**: for findings with a small, unambiguous fix, append a
` ```suggestion ` block replacing exactly the anchored line(s) — matching
indentation, replacement lines only, one block per comment. Never for style
preferences.

### Revoking a stale approval on re-review

On any re-review whose verdict is **not** `APPROVE`, `post` finds the agent's
most recent `APPROVED` review (its own login or the marker — never a human's)
and, after the new review posts, dismisses it —
`gh api "repos/$REPO/pulls/<n>/reviews/<id>/dismissals" -X PUT -f event="DISMISS" -f message="Superseded by $BOT_NAME re-review at <new-sha> — verdict is now <new-verdict>."`
— logging `PR #<n>: dismissed stale approval <id> (APPROVE → <new-verdict>)`
(`dismissed_approval` in its outcome). New verdict `APPROVE` → left in place.
A failed dismissal is logged, not fatal.

### Error handling

- **Transient tool failure** (context fetch, clone, skill run, post — network
  error, timeout, 5xx, rate-limit) → **retry once**. `review-pr.sh` retries
  its own calls once and then aborts the PR with the lock released (`post`
  outcome `aborted`); a failure in your own steps ends the PR with
  `review-pr.sh abort <n> <reason>`, which does the same (`first` deletes the
  row, `re-review` restores the prior row; clone and state deleted;
  `aborted <reason>` logged). Log `PR #<n>: <step> failed after retry —
  aborted, lock released` in the chat UI and continue with the next PR. Never
  leave an `in_progress` lock behind, and never retry a call more than once —
  the next heartbeat picks the PR up fresh.
- **422 line-not-in-diff** → `post` moves every inline comment to the summary
  and retries the POST once (`moved_to_summary`, reason `422 line not in
  diff`); note the moved comments once in the chat UI.
- **422 commit_id mismatch** → HEAD moved: `post` aborts as a Check 2 failure.

## Review-run self-check

Before declaring the run done, verify:

- Bookkeeping: every `selfheals_due` / `label_cleanups_due` / `prunes_due`
  entry executed and logged.
- Mentions (`mentions_due`, [mentions.md](mentions.md)): handled before the
  review loop, ledger row immediately after every action
  (send-then-record), each entry ended in `feedback + reply` / `answer` /
  `review` / `no-action` / `send-failed` with its `mention_handled` event —
  and every explicit correction has its memory write, named in the reply.
- Per reviewed PR: one GitHub review with the trailing full-SHA marker ·
  Check 1 + Check 2 + pre-post dedup done by `prepare` / `post` (incl. the
  trigger check on re-reviews) · every entry ended in a `post` or `abort`
  outcome — lock → `done` lifecycle correct (aborted re-reviews restored
  `awaiting_label`; no `in_progress` left behind) · lock row refreshed at each
  milestone (**Lock heartbeat**) · every entry re-checked for a live holder
  before the lock write, standing down instead of displacing it (**Live
  holder**) · label removed after every posted review on a labeled PR · skill
  audit lines complete
  ([skills.md](skills.md)) · full review appended to `reviews/pr-<n>.md` ·
  overrides applied from that PR's file only · PR context fetched and used;
  observed insights recorded ([preferences.md](preferences.md)) · `memory_due`
  files read before reviewing · orientation (`profile_slice`, `history_slice`,
  `work/PROFILE.md`) used for where to look only — `verify_live` rows read from
  the live file, no finding cites the profile ([profile.md](profile.md)) · noise
  files excluded with their Summary line · candidate findings verified against
  the surrounding code and sibling-swept over the changed files ·
  every open 🔴/🟡 carries a **Fix:** stated as a class rule, mirrored into
  `findings-json` · skill sections reformatted to the finding form and merged
  across sources with no finding lost (**Merging findings across sources**) ·
  stale approval dismissed when the verdict
  dropped below APPROVE · clone, per-skill copies, diff and state deleted by
  `post` / `abort` ·
  `review_step` events logged (`locked` → `fanned out (n=<N>)` → `verified` →
  `posted`/`aborted`/`done`) with the collected `skill_timing`
  ([logging.md](logging.md)).
- Style: findings concise and diff-anchored, inline text never repeated in
  the summary; re-review scope matched the trigger — label = complete (all
  current findings, 🆕-only inline), request/on-demand = delta (Findings =
  🆕 only, one-line carryovers, no ✅; candidates, verification, sweep and
  extension-skill routing from the changes since the prior review).
- Urgent entries: rapid preliminary posted (or dedup-skipped) **before** the
  full review; `RAPID` row + `rapid posted` step recorded; terminal = full
  review posted (or closed-PR issue / abort). Closed entries: no review
  posted; criticals → one deduped issue assigned to the author.
- Artifacts (`artifacts_due`, [artifact.md](artifact.md)): published to each
  target in `artifact_targets` (DAM best-effort, never failing the run), one
  comment with the surviving links, markers recorded, cleanup on prune.
- Watch rules (when configured) evaluated send-then-marker
  ([watches.md](watches.md)).
- Under `review_progress: enabled`: every locked PR ended on a terminal
  `success` status, `status_resets_due` entries closed out and their rows
  deleted (**Progress signal on GitHub**).
- `stall_alert` (when present): reported in the chat UI, DM'd to
  `escalation_owner` under Slack, `stall_alert_sent` logged — and no state
  "repaired" in response.
- **Every `reviews_due` PR reached a posted-or-aborted terminal state — the
  run never ended mid-pipeline** (e.g. after a skill report); transient
  failures retried once then aborted-with-lock-released · all errors logged ·
  no unexpanded `$GITHUB_REPO` in any output.
