# Reviewing a PR

Read this file at the start of every **review run** (a run whose preflight
worklist has any of `reviews_due` / `label_cleanups_due` / `selfheals_due` /
`prunes_due` non-empty). Preflight already made every decision — you perform
the actions. Keep the two HEAD-freshness checks and the pre-post dedup
re-check below; they guard the race windows that open between preflight and
post time.

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
  HEAD is already reviewed — nothing to review. Clear what the entry flags —
  `label: true` → remove the label, `request: true` → remove your pending
  review request (commands under **Trigger removal** below) — and log
  `PR #<n>: re-review trigger present but no new commits since <short-sha> — cleared (<label / request / label + request>), no re-review`.
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

Each entry: `{number, head_sha, head_ref, title, author, kind, takeover, prior}`
— `kind` is `first` or `re-review`; `prior` carries the last review's
`{sha, ts, verdict}` when one exists. Complete ALL steps before the next PR:

a. **Check 1 — re-fetch state**: `gh pr view <n> --repo "$REPO" --json headRefOid,headRefName,isDraft,labels,reviewRequests`.
   Now draft → skip. On a `re-review`, no active re-review trigger still
   present → skip (request withdrawn; leave the `awaiting_label` row) — the
   trigger is live per `rereview_trigger`: `$REREVIEW_LABEL` in `labels`
   and/or a pending review request for `bot_login` in `reviewRequests`. Use
   the fresh
   SHA/branch as source of truth everywhere (clone, diff, skills, marker).
   Then **write the `in_progress` lock row** to REVIEWS.md (fresh SHA +
   current UTC time). `takeover: true` → overwrite the stale lock and log
   `PR #<n>: taking over stale in_progress lock`. Never lock a PR you're
   about to skip.
b. **Fetch PR context** (see below).
c. **Fetch the diff** (`gh pr diff <n> --repo "$REPO"`) and review it.
d. **Clone the branch and run every configured review skill** per
   [skills.md](skills.md) — one audit line per configured skill, no exceptions.
e. **Check 2 — re-verify** right before posting (same call as Check 1). SHA
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
k. **Delete the clone** (`rm -rf "$PR_DIR"`), exactly once per PR.

**Progress logging (stall diagnosis).** A session that dies mid-review (e.g.
ending the turn after a skill report — [skills.md](skills.md)) must leave a
trace of where it stopped: as each milestone of this sequence completes,
append one `review_step` event to the structured log
([logging.md](logging.md)) — chained onto the step's existing command, never
as a separate tool call:

```bash
. "$HOME/scripts/log.sh" && LOG_JOB=review logev info review_step "PR #<n> <sha-short> <step>"
```

with step ∈ `locked` (a) · `cloned` (d) · `skill:<name> done` (d, one per
configured skill) · `posted <verdict>` (h) · `done` (j) · `aborted <reason>`
(e). The last event logged for a PR pins the exact step a stall stopped at;
consecutive event timestamps give per-step durations.

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

## Slack-requested review (on-demand)

The one channel request that triggers work (CLAUDE.md → **Instruction
sources & trust boundary**): **anyone** in the connected channel may ask for
a review of a specific PR — equivalent to adding `$REREVIEW_LABEL`. Nothing
else about the agent is changeable from a channel — its writes stay within
`work/` state and the review itself; the definition repo is never touched.

1. Resolve the PR reference (number or URL); `gh pr view` — not found /
   closed / draft → reply so in the channel, done.
2. Row `in_progress`: fresh (< 30 min) → reply "review already running",
   done. Stale → the review is stuck: log
   `PR #<n>: stale lock killed on Slack request` and continue (the lock is
   overwritten in the next step).
3. Live HEAD already reviewed (row SHA or remote marker — snippet above) →
   reply "already reviewed at <short-sha>"; same-SHA dedup always holds.
4. Otherwise run the full per-PR sequence above (kind = `re-review` when a
   prior review exists, else `first`; install missing skills per the
   fallback in skills.md → Installation), reply in the channel with a link to
   the posted review, and persist `work/` (persistence.md).

Replying to the requesting channel is responsive, not proactive — it does
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

## Criteria

Unless preferences say otherwise: **Correctness** (logic, off-by-one, null
risks, races) · **Security** (injection, credential leaks, OWASP top 10) ·
**Performance** (allocations, N+1, missing indexes) · **Maintainability**
(dead code, naming, error handling) · **Architecture** (coupling, SRP, layer
boundaries) · **Tests** (missing coverage, flaky patterns). Very large diffs
(>2000 lines): focus on the most critical files but still post a full review.

## Output format (first reviews)

```
## PR #<number>: <title>
**Author:** <login> | **Branch:** <head> → <base> | **Changes:** +<additions> −<deletions> (<files> files)

### Summary
<1-2 sentence summary of what the PR does>

### Findings
- 🔴 **Critical:** <description> (`file:line`)
- 🟡 **Warning:** <description> (`file:line`)
- 🟢 **Suggestion:** <description> (`file:line`)
- ✅ **Looks good:** <description>

### <section — one per configured review skill that ran, in table order>
<verbatim skill output (or its clean-run line)>

### Verdict
<APPROVE / REQUEST_CHANGES / COMMENT> — <one sentence justification>
```

On first reviews the summary `Findings` list is the canonical, complete list.

## Re-review output (trigger-gated; new commits since the last review)

Re-reviews are deliberately **concise** — they report the delta, never a
restatement of the previous review. Read the prior review from
`reviews/pr-<n>.md` first, then insert between `### Summary` and
`### Findings`:

```
### Changes since last review
Previous HEAD: <short-sha> (<timestamp>) — verdict <PREV_VERDICT>

- ✅ **Fixed:** <one-liner> (`file:line`)
- 🔁 **Still present:** <one-liner> (`file:line`)
- 🆕 **New:** <description> (`file:line`)
```

Conciseness rules (all output channels — chat UI, GitHub body, history file):

- Include only non-empty buckets; every bucket entry is a **single line**.
  Never re-expand a carryover's full description, rationale, or suggestion —
  its original review and inline thread already carry them.
- `### Findings` lists **only `🆕 New` findings**, in full. No `✅ Looks good`
  bullets on re-reviews — ever. Nothing new → the section body is the single
  line `_No new findings at this HEAD._`
- The **Verdict still weighs all current findings** — new *and*
  still-present, plus skill findings: an unfixed 🔴 keeps `REQUEST_CHANGES`
  even though it appears only as a one-liner under `### Changes since last
  review`.
- Skill sections (the runs stay mandatory, unchanged) are condensed the same
  way: findings unchanged from the prior review collapse into one line —
  `🔁 <N> finding(s) from the previous review still present (see review at <short-sha>)`
  — full text only for new findings; clean-run lines stay as-is.
- `🔁 Still present` findings are **summary-only** — never re-posted inline
  (their original thread persists; re-posting created duplicate threads);
  only `🆕 New` findings are inline-eligible (mapping rule 5).
- The canonical picture on a re-review is `### Changes since last review`
  (fixes + one-line carryovers) plus `### Findings` (new findings only).

Prior review file missing → skip the section, review as a first review (full
format), append `(no prior review on file)` to `### Summary`.

## Review tracking state

**REVIEWS.md** — one row per PR:
`| <number> | <headRefOid> | <ISO timestamp> | <verdict> | <status> |`

- `status` = `in_progress` (lock; verdict `-`; timestamp = lock time), `done`
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
- The lock is best-effort (30-min TTL; takeover flagged by preflight) — the
  remote dedup check stays authoritative.

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
_Review by [<bot_display_name>](https://github.com/<definition_repo>) · automated code guardian_


<!-- <review_marker> headRefOid=<full-sha> -->
```

Emoji: ✅ APPROVE, ⚠️ COMMENT, ❌ REQUEST_CHANGES. The trailing marker line is
**mandatory** (drives dedup) and uses the full 40-char SHA.

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

**Suggestion blocks**: for 🟢 (occasionally 🟡) findings with a small,
confident fix, append a ` ```suggestion ` block replacing exactly the
anchored line(s) — matching indentation, replacement lines only, one block
per comment.

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

Before declaring the run done, verify: every `selfheals_due` /
`label_cleanups_due` / `prunes_due` entry executed and logged · for every
reviewed PR: one GitHub review with the trailing full-SHA marker · skill
audit lines complete per [skills.md](skills.md) · Check 1 + Check 2 + pre-post
dedup re-check done (incl. the trigger check on re-reviews) · lock → `done` row
lifecycle correct (aborted re-reviews restored `awaiting_label`) · label
removed after every posted review on a labeled PR · re-reviews delta-only
(Findings = 🆕 only, one-line carryovers, no ✅ Looks good) · full review
appended to `reviews/pr-<n>.md` · overrides applied from that PR's file only ·
PR context fetched and used · observed insights recorded when context
revealed generalizable ones ([preferences.md](preferences.md)) · stale
approval dismissed when the verdict
dropped below APPROVE · clone deleted · artifacts (`artifacts_due`, see
[artifact.md](artifact.md)) published to each target in `artifact_targets`
with all surviving links in one comment (DAM best-effort — skipped-with-log
when the flag is off, never failing the run), every published surface's marker
recorded, and gist/DAM/HTML all cleaned up on prune · watch rules (when
configured) evaluated marker-before-send per [watches.md](watches.md) · per-PR
`review_step` events were logged (`locked` → `skill:… done` →
`posted`/`aborted`/`done` — [logging.md](logging.md)) so a mid-review stall is
diagnosable · **every `reviews_due` PR ran to a posted-or-aborted terminal
state — the run was never ended mid-pipeline (e.g. after a skill report)** ·
every transient tool failure retried once then aborted-with-lock-released (no
`in_progress` lock left behind) · all errors logged · no literal repo slug in
any output.
