# Reviewing a PR

Read this file at the start of every **review run** (a run whose preflight
worklist has any of `reviews_due` / `label_cleanups_due` / `selfheals_due` /
`prunes_due` / `urgent_alerts_due` / `mentions_due` non-empty). Preflight
already made every decision — you perform the actions. Keep the two HEAD-freshness checks and
the pre-post dedup re-check below; they guard the race windows that open
between preflight and post time.

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

a. **Check 1 — re-fetch state**:
   `gh api "repos/$REPO/pulls/<n>" --jq '{state, merged, headRefOid: .head.sha, headRefName: .head.ref, baseRefName: .base.ref, isDraft: .draft, labels: [.labels[].name], requested: [.requested_reviewers[]?.login]}'`.
   Now draft → skip. Now closed (`state` ≠ `open`) → skip (the next heartbeat
   prunes). On a `re-review`, no active re-review trigger still
   present → skip (request withdrawn; leave the `awaiting_label` row) — the
   trigger is live per `rereview_trigger`: `$REREVIEW_LABEL` in `labels`
   and/or `bot_login` in `requested`. The live trigger also sets the
   re-review **scope**: `$REREVIEW_LABEL` present → complete, else delta
   (preflight's `full` flag is the plan, the labels at Check 1 decide —
   **Re-review output** below).
   Re-verify `urgent` from the live labels (`$URGENT_LABEL` present). Use the
   fresh SHA/branch as source of truth everywhere (clone, diff, skills,
   marker). Then **re-check for a live holder — every entry, whatever its
   `takeover` flag** (**Live holder** below); one that lives → stand down.
   Only then **write the `in_progress` lock row** to REVIEWS.md (fresh SHA +
   current UTC time), logging `PR #<n>: taking over stale in_progress lock`
   when `takeover` was set. Never lock a PR you're about to skip. Entries flagged `closed: true` skip these gates — see
   **PR closed mid-review** below. Urgent entries now run **phase 1 (rapid
   preliminary review)** per **Urgent PRs** below, then continue with b.
b. **Fetch context, diff, and clone — as parallel tool calls in one message**;
   the three are independent. Context: see below. Diff:
   `gh pr diff <n> --repo "$REPO"`. Clone: [skills.md](skills.md) →
   **Clone, credential helper, cleanup**.
c. **Review the diff.**
d. **Run every configured review skill** per [skills.md](skills.md) — one audit
   line per configured skill, no exceptions. Then verify your candidate
   findings against the full files in the clone (**Full-file verification**
   below).
e. **Check 2 — re-verify** right before posting (same call as Check 1). Now
   closed (`state` ≠ `open`) → **PR closed mid-review** below (criticals
   become an issue, never a review). SHA
   moved, now draft, or (re-review) trigger withdrawn (same check as Check 1)
   → **abort posting**: no
   chat review, no GitHub review, no history append; **release the lock** —
   `first`: delete the row; `re-review`: restore the `awaiting_label` row
   (previous review's SHA/verdict/timestamp from `prior` /
   `reviews/pr-<n>.md`; unreadable → delete the row and let self-heal fix it
   later); delete the clone; log
   `PR #<n>: HEAD moved <old> → <new> mid-review (or became draft / trigger withdrawn) — discarding`; continue.
f. **Re-run the remote dedup check** for the reviewed SHA (both halves —
   reviews and legacy comments; snippet below). A hit → treat as Check 2
   failure + self-heal the row with the GitHub timestamp.
g. Output the structured review to the chat UI.
h. Post it to GitHub as a single PR review (below). Then evaluate any
   configured watch rules against this PR and send due heads-ups per
   [watches.md](watches.md).
i. **If `$REREVIEW_LABEL` is on the PR, remove it** (see **Trigger removal**
   below) — after every posted review, first reviews included (the request
   is served). Failure = log, not fatal. A pending review request needs no
   action here — GitHub clears it itself when your review posts.
j. **Replace the lock with a `done` row** — post-time UTC timestamp, final
   verdict.
k. **Delete the clone, its per-skill copies, and the skill outputs**
   ([skills.md](skills.md) → **Clone, credential helper, cleanup**), exactly
   once per PR.

Under `review_progress: enabled` this sequence also publishes its progress to
the PR — **Progress signal on GitHub** below.

**Progress logging (stall diagnosis).** A session that dies mid-review must
leave a trace of where it stopped, so each milestone of this sequence appends a
`review_step` event to the structured log ([logging.md](logging.md)). The last
event logged for a PR pins the exact step a stall stopped at; consecutive
timestamps give per-step durations.

**Most steps are logged for you.** `cloned` (b), `skill:<name> done` (d) and
`posted <verdict>` (h) are derived by the `PostToolUse` adapter hook from the
tool call that performs them ([logging.md](logging.md) → **Harness adapters**) —
do not log them yourself. The three the harness cannot observe stay yours,
because only you know the PR and verdict behind a REVIEWS.md row edit — chained
onto the step's existing command, never as a separate tool call:

```bash
. "$HOME/scripts/log.sh" && LOG_JOB=review logev info review_step "PR #<n> <sha-short> <step>"
```

with step ∈ `locked` (a) · `fanned out (n=<N>)` and `verified` (d) ·
`done` (j) · `aborted <reason>` (e) — plus `rapid posted` (Urgent PRs phase 1).
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

**Lock heartbeat — refresh the row as you go.** Before each of steps c, d, e and
h, rewrite your PR's REVIEWS.md row with the **current** UTC time (same fields
otherwise, status stays `in_progress`) and log
`locked (refresh, <what comes next>)`. Cheap — one `sed` per milestone, chained
onto work you are already doing — and it is what keeps a long review from
*looking* abandoned: the timestamp is the age preflight measures and the event is
the liveness signal it reads (**Live holder** below). A review that refreshes
never crosses the TTL at all. Skipping it is what makes a healthy 50-minute
review indistinguishable from a dead one.

**When the adapter is not active, all nine steps are yours** — a non-Claude-Code
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
| a — lock written | `pending` | `queued <HH:MM>Z · fetching diff and clone<eta>` | — |
| b — clone finished | `pending` | `reviewing since <HH:MM>Z · diff + <k> skill(s)<eta>` | — |
| Urgent phase 1 — rapid posted | `pending` | `rapid preliminary review posted · full review running` | the rapid review |
| j — review posted | `success` | `<VERDICT> · <a> critical, <b> warning, <c> suggestion · took <m>m` | the posted review |
| e — posting aborted | `success` | `no review posted — <reason>; retrying next heartbeat` | — |
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
- **Chain each call onto the command that step already runs** — never a
  separate tool call.
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

**Phase 1 — rapid preliminary review.** Optimize for delivery speed; skip
everything skippable:

1. Dedup: run the marker check (snippet above) with the **rapid marker**
   `<!-- <review_marker>:rapid headRefOid=<full-sha> -->` at the live HEAD —
   found (or `prior.verdict` = `RAPID` at this SHA) → phase 1 already
   delivered, go straight to phase 2.
2. No clone, no skills, no artifact, no full context fetch. Review the diff
   only (`gh pr diff`; on re-reviews prefer the range since the prior review
   — `gh api "repos/$REPO/compare/<prior-sha>...<head-sha>"` — full diff as
   fallback) for **🔴 Critical findings only**.
3. Post immediately: single review, `event: COMMENT`, `commit_id` = reviewed
   HEAD, body only (no inline comments):

   ```
   ⚡ **<bot_display_name>** — ⏱️ Rapid preliminary review @ `<sha-short>`

   > Fast pass triggered by the `<urgent_label>` label — critical checks
   > only. **The full review follows.**

   ### Critical findings
   - 🔴 **Critical:** <one-liner> (`file:line`)

   <!-- <review_marker>:rapid headRefOid=<full-sha> -->
   ```

   No criticals → the section body is the single line
   `_None found at rapid-review depth._`
4. Update the PR's REVIEWS.md row in place: status stays `in_progress`,
   verdict cell `RAPID`, fresh UTC timestamp (extends the lock). Log
   `review_step` `rapid posted`.

**Phase 2 — full review, immediately after** — the normal per-PR sequence
from step b. The `:rapid` marker is invisible to the normal dedup (different
prefix), so the full review posts as usual; watch rules evaluate once, after
the full review. A rapid post is **never** terminal: the PR is done only when
the full review posted or the entry aborted (a died run is recovered by the
stale-lock takeover — verdict `RAPID` tells the next run to skip phase 1).

## PR closed mid-review — critical findings become an issue

Applies to **every** review, urgent or not. When Check 2 (or the POST itself)
finds the PR `CLOSED`/`MERGED`, never post the review; instead:

- **≥1 🔴 Critical finding** (yours + skill sections) → deliver them as one
  GitHub issue:
  1. Dedup: `gh api "repos/$REPO/issues?state=all&per_page=100"` — any body
     containing `<!-- <review_marker>:issue headRefOid=<sha> -->` → already
     filed, skip creation.
  2. `gh api "repos/$REPO/issues" -X POST -f title="Critical findings from review of closed PR #<n>" -f body=… -f "assignees[]=<author>"`
     — body: the 🔴 findings in full, a `#<n>` reference (links the issue to
     the PR), and the trailing `:issue` marker line. A failed assignment is
     logged; the issue stands.
  3. Append the review to `reviews/pr-<n>.md` with a
     `_Delivered as issue #<id> — PR closed before posting._` note; replace
     the lock with a `done` row. Log
     `PR #<n>: closed mid-review — <k> critical finding(s) filed as issue #<id>`.
     The next heartbeat prunes the closed PR's state as usual.
- **No 🔴 findings** → discard exactly like a Check 2 abort (release the lock
  per kind); log `PR #<n>: closed mid-review — discarded (no critical findings)`.

Crash recovery: preflight emits a closed PR whose row is an `in_progress`
lock with verdict `RAPID` (rapid posted, full review still owed) as a review
entry flagged `closed: true` instead of a prune. Run it as phase 2 in
diff-only mode — refresh the lock (keep verdict `RAPID`), no clone, no skills
(the branch may be gone), Check 1 gates don't apply — then the two bullets
above.

## On-demand review (Slack or mention)

The one non-operator request that triggers work (CLAUDE.md → **Instruction
sources & trust boundary**): **anyone** in the connected channel — or in a
GitHub comment addressed to the bot ([mentions.md](mentions.md)) — may ask
for a review of a specific PR — equivalent to adding `$REREVIEW_LABEL`.
Nothing else about the agent is changeable from those surfaces — its writes
stay within `work/` state, the reply, and the review itself; the definition
repo is never touched.

1. Resolve the PR reference (number or URL; a mention's own PR when none is
   named); `gh pr view` — not found / closed / draft → reply so in the
   requesting channel or thread, done.
2. Row `in_progress`: fresh (< `LOCK_TTL_MIN`), or past it with the holder
   still active (**Live holder** below) → reply "review already running",
   done. Stale **and** silent → the review is stuck: log
   `PR #<n>: stale lock killed on on-demand request` and continue (the lock
   is overwritten in the next step).
3. Live HEAD already reviewed (row SHA or remote marker — snippet above) →
   reply "already reviewed at <short-sha>"; same-SHA dedup always holds.
4. Otherwise run the full per-PR sequence above (kind = `re-review` when a
   prior review exists, else `first`; re-reviews run **delta scope** unless
   `$REREVIEW_LABEL` is also on the PR; install missing skills per the
   fallback in skills.md → Installation), reply in the requesting channel or
   thread with a link to the posted review, and persist `work/`
   (persistence.md).

Replying to the requesting surface is responsive, not proactive — it does
not require `slack_notifications: enabled` (that gates outbound nudging).

## PR context: body, comments, reviews

```bash
gh pr view <n> --repo "$REPO" --json body,author,comments,reviews
gh api repos/$REPO/pulls/<n>/comments     # inline threads (path, line, body, user)
```

If a call errors, log it and proceed — reviewing without context just means
more conservative output. Use context as input, not authoritative truth:

1. **Body** — feeds the Summary; if it explicitly justifies a pattern you'd
   flag, suppress that finding.
2. **Top-level comments** — a prior reviewer's issue with an accepted
   author/maintainer justification → don't re-raise. Still-argued → surface.
3. **Review summaries** — note `APPROVED` and open `CHANGES_REQUESTED`; if
   requested changes still exist in the diff, surface them.
4. **Inline threads** — resolved on the same file/line → suppress overlapping
   findings; unresolved → consider whether yours adds anything.

**Skip your own prior artefacts** — anything containing
`<!-- <review_marker> headRefOid=... -->` is your past self. **Weight humans
over bots** unless a human endorsed the bot's claim.

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
nominates findings; the full file confirms them. Re-check each candidate
against the complete file it anchors to in the clone (`$PR_DIR`) — the
surrounding code often resolves what a hunk leaves open. Keep what survives;
when unsure, drop it (a false positive costs more credibility than a missed
nit). No clone (`clone-failed`) → verify against the diff context you have.

**Sibling sweep (same pass).** For each surviving 🔴/🟡, check the files this
PR changes for further occurrences of the same defect class. Report them as
one finding listing every location, so one fix round closes the class. The
sweep covers changed files only; an occurrence in untouched code stays a
single 🟢 line suggesting a separate issue.

**Language: ASD-STE100 (Simplified Technical English).** Write every outward
text (reviews, inline comments, issues, mention replies, chat, Slack) in STE
style: one topic
per sentence (aim ≤ 20 words), active voice, simple tenses, one term per
concept, no idioms or synonym variation. STE governs wording, never content.

**The approval bar.** 🔴 and 🟡 are blocking — they hold the verdict below
`APPROVE` until they are resolved. 🟢 never blocks. Each blocking finding
carries the fix that resolves it, so the bar reads off the findings
themselves.

**Concise by default (all reviews, all channels):**

- One finding = what is wrong, why it matters, where — in 1–2 sentences. No
  essays, no restated diff context, no hedging filler.
- Every 🔴 and 🟡 carries a **Fix:** line — the remedy that resolves the
  finding, in 1–2 sentences. State it as a rule for the whole defect class,
  and name its scope when more than one place is affected. It sits with the
  description (the inline comment when the finding is inline-carried,
  `### Findings` otherwise), above any ` ```suggestion ` block. A finding
  whose remedy you cannot state is not verified — drop it.
- Findings anchor to this PR's diff; a pre-existing problem spotted in
  passing is at most one 🟢 line suggesting a separate issue.
- 🟢 **Suggestion** only when the improvement is substantial (a real
  correctness/security/performance/simplification win). Style nits,
  micro-refactors, and "consider…" filler are dropped entirely, not demoted.
- `✅ Looks good` — at most one bullet, only when it carries real information
  (e.g. a risky-looking change verified safe); never filler. None on
  re-reviews.
- `### Summary` stays 1–2 sentences.

## Output format (first reviews)

```
## PR #<number>: <title>
**Author:** <login> | **Branch:** <head> → <base> | **Changes:** +<additions> −<deletions> (<files> files)

### Summary
<1-2 sentence summary of what the PR does>

### Findings
- 🔴 **Critical:** <description> (`file:line`)
  **Fix:** <the remedy that resolves it>
- 🟡 **Warning:** <description> (`file:line`)
  **Fix:** <the remedy that resolves it>
- 🟢 **Suggestion:** <description> (`file:line`)
- ✅ **Looks good:** <description>

### <section — one per configured review skill that ran, in table order>
<that skill's findings, per **Concise by default** (or its clean-run line)>

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
the ones already reviewed. Re-read the body (**PR context: body, comments, reviews** above) and redo the review against it: a justification that has been removed no
longer suppresses its finding, and one that has been added now does. Scope
still follows the trigger. In `### Changes since last review`, `Previous HEAD`
is the same SHA — say `description edited, no new commits` on that line, and
let the buckets carry what the corrected description changed. Nothing changed
in substance → say so in one line rather than re-posting the previous review.

Both scopes: read the prior review from
`reviews/pr-<n>.md` first — match findings against its `findings-json` line
when present (older reviews without one: parse the visible text) — then
insert between `### Summary` and `### Findings`:

```
### Changes since last review
Previous HEAD: <short-sha> (<timestamp>) — verdict <PREV_VERDICT>

- ✅ **Fixed:** <one-liner> (`file:line`)
- 🔁 **Still present:** <one-liner> (`file:line`)
- 🆕 **New:** <description> (`file:line`)
```

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
- Skill sections (the runs stay mandatory, unchanged) are condensed the same
  way: findings unchanged from the prior review collapse into one line —
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
- Row edits (lock, `done`, `awaiting_label` restore) rewrite the PR's line in
  place; rows are full of `|`, so give sed a different delimiter:

  ```bash
  sed -E "s#^\| *<n> \|.*#| <n> | <sha> | <ts> | <verdict> | <status> |#" work/REVIEWS.md \
    > work/REVIEWS.md.tmp && mv work/REVIEWS.md.tmp work/REVIEWS.md
  ```

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
takeover's first act is step b's `rm -rf "$PR_DIR" "$PR_DIR".out "$PR_DIR".s-*`
([skills.md](skills.md) → **Clone, credential helper, cleanup**), which destroys
a finished fan-out before any judgement applies.

**As the holder you own the PR to a terminal state whatever your lock age** — a
lock past the TTL is never a reason to abandon or skip posting; keep refreshing
(**Lock heartbeat** above) and finish. Safety is already guaranteed by step e —
if a second job posted at your SHA meanwhile, the pre-post dedup check turns your
run into a self-healing abort, so no duplicate can post.

**As the taker, exclusivity is re-checked at Check 1 for every entry, whatever
its `takeover` flag.** `takeover: true` means "preflight saw no life", not proof
of death — the holder may wake between preflight and you. `takeover: false`
means only that the worklist's snapshot saw no lock: on a busy heartbeat that
snapshot predates your arrival by minutes, and another run may have locked the
PR in between. Any one of these signals means the PR lives:

```bash
ls -d "$PR_DIR" "$PR_DIR".out "$PR_DIR".s-* 2>/dev/null        # a tree this run did not create
jq -c -R 'fromjson? // empty' work/logs/events-$(date -u +%Y-%m-%d).jsonl 2>/dev/null \
  | jq -c --arg n "PR #<n> " --arg me "${LOG_RUN_ID:-$CLAUDE_CODE_SESSION_ID}" \
      'select((.msg|startswith($n)) and .run != $me)' | tail -3   # a foreign run on this PR
```

plus a REVIEWS.md row timestamp newer than the worklist's `prior.ts`. Then
**stand down before the `rm -rf`**: touch neither the row nor `/tmp`, log
`PR #<n>: holder alive at Check 1 — stood down`, continue with the next PR.
Step b's `rm -rf` is destructive and runs first, so this check must precede
both it and the lock write — never only on takeovers.

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
+ overlapping line, or same symbol) and add the Summary audit note. Overrides
only suppress, never add; if the code moved so an override no longer matches,
the finding surfaces normally.

## Posting the GitHub review

Single PR review (summary + inline comments in one submission):

```bash
cat > "/tmp/review-post-<n>.json" <<'JSON'
{
  "commit_id": "<full headRefOid>",
  "event": "<COMMENT | APPROVE | REQUEST_CHANGES>",
  "body": "<summary markdown — see below>",
  "comments": [
    {"path": "src/foo.ts", "line": 42, "side": "RIGHT", "body": "🟡 **Warning:** ..."}
  ]
}
JSON
gh api "repos/$REPO/pulls/<n>/reviews" -X POST --input "/tmp/review-post-<n>.json"
rm -f "/tmp/review-post-<n>.json"
```

`event` = the Verdict verbatim; `commit_id` **must** be the reviewed
`headRefOid` (server-side stale guard — GitHub 422s if HEAD moved).

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
2. Not in any hunk / no precise line → summary-only (else the whole POST 422s).
3. `✅ Looks good` → summary-only, never inline (first reviews only — none on
   re-reviews at all).
4. **Cap ~25 inline comments** — prioritize 🔴/🟡, demote excess 🟢.
5. **Re-reviews: only `🆕 New` findings inline** — carryovers keep their
   existing thread; `✅ Fixed` get nothing.

**Suggestion blocks**: for findings with a small, unambiguous fix, append a
` ```suggestion ` block replacing exactly the anchored line(s) — matching
indentation, replacement lines only, one block per comment. Never for style
preferences.

### Revoking a stale approval on re-review

On any re-review whose verdict is **not** `APPROVE`:

1. Find the agent's most recent `APPROVED` review (body carries the marker —
   never touch a human's). None → done.
2. After the new review posts:
   `gh api "repos/$REPO/pulls/<n>/reviews/<id>/dismissals" -X PUT -f event="DISMISS" -f message="Superseded by $BOT_NAME re-review at <new-sha> — verdict is now <new-verdict>."`
3. Log `PR #<n>: dismissed stale approval <id> (APPROVE → <new-verdict>)`.

New verdict `APPROVE` → leave it. A failed dismissal is logged, not fatal.

### Error handling

- **Transient tool failure** (context fetch, clone, skill run, post — network
  error, timeout, 5xx, rate-limit) → **retry once**. Still failing → **abort
  the PR and release its lock** exactly as a Check 2 failure does (step e:
  `first` deletes the row, `re-review` restores `awaiting_label`), delete the
  clone, log `PR #<n>: <step> failed after retry — aborted, lock released`,
  continue with the next PR. Never leave an `in_progress` lock behind on a
  failure, and never retry a call more than once (a stuck call must not burn
  the run — the next heartbeat picks the PR up fresh).
- **422 line-not-in-diff** → move the named entries to summary-only, retry
  the POST; never retry the same payload blindly. Note dropped comments once
  in the chat UI.
- **422 commit_id mismatch** → HEAD moved: same handling as Check 2 failure.

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
  Check 1 + Check 2 + pre-post dedup done (incl. the trigger check on
  re-reviews) · lock → `done` lifecycle correct (aborted re-reviews restored
  `awaiting_label`; no `in_progress` left behind) · lock row refreshed at each
  milestone (**Lock heartbeat**) · every entry re-checked for a live holder
  before the lock write and the clone `rm -rf`, standing down instead of
  displacing it (**Live holder**) · label removed after every
  posted review on a labeled PR · skill audit lines complete
  ([skills.md](skills.md)) · full review appended to `reviews/pr-<n>.md` ·
  overrides applied from that PR's file only · PR context fetched and used;
  observed insights recorded ([preferences.md](preferences.md)) · candidate
  findings full-file-verified and sibling-swept over the changed files ·
  every open 🔴/🟡 carries a **Fix:** stated as a class rule, mirrored into
  `findings-json` · skill sections reformatted to the finding form and merged
  across sources with no finding lost (**Merging findings across sources**) ·
  stale approval dismissed when the verdict
  dropped below APPROVE · clone + per-skill copies deleted ·
  `review_step` events logged (`locked` → `fanned out (n=<N>)` → `verified` →
  `posted`/`aborted`/`done`) with the collected `skill_timing`
  ([logging.md](logging.md)).
- Style: findings concise and diff-anchored, inline text never repeated in
  the summary; re-review scope matched the trigger — label = complete (all
  current findings, 🆕-only inline), request/on-demand = delta (Findings =
  🆕 only, one-line carryovers, no ✅).
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
