# Re-reviews and carried reviews

Read when the worklist's `read_set` names this file — a `reviews_due` entry of
`kind: re-review` — and when `prepare` returns a non-null `carry`.

## Re-review output (trigger-gated; new commits or an edited description)

The trigger sets the scope:

- **`$REREVIEW_LABEL` → complete re-review** (`full: true`): review the
  **entire PR** at the live HEAD, at first-review depth. Output = the
  first-review format with `### Changes since last review` inserted.
  `### Findings` lists **all current findings** in full, new and still-present;
  `✅ Fixed` stay one-liners in the block. Inline comments map only `🆕 New`
  and `🔎 Missed earlier` findings; skill sections post in full.
  `findings-json` carries `new`/`still`/`fixed` as found, `late` included.
- **Review request / on-demand ask → delta re-review** (`full: false`): the
  delta only, per the conciseness rules below.

**Description-only re-review** (`description_changed: true`): an edited body
answers the trigger, so the diff and SHA are the reviewed ones. `post` reads
the earlier marker at this SHA as the prior being superseded, and an abort
restores the `done` row. Re-read the body ([review.md](review.md) → **PR
context: body, comments,
reviews**) and redo the review against it: a removed justification no longer
suppresses its finding, an added one now does. `Previous HEAD` is the same SHA
— write `description edited, no new commits` on that line and let the buckets
carry the rest. No change in substance → say so in one line.

Both scopes: the prior `findings-json` array is `prior_findings` in the
prepare output, or the line in `reviews/pr-<n>.md` where no `prepare` ran, so
this round's findings are written against its anchors and its wording (history
older than the line: parse the visible text yourself).
`review-pr.sh delta <n> findings.json` matches them and returns this block,
the `fixed` / `still` / `new` buckets, the `suppressed` overrides, the
`ambiguous` pairs, and `annotated` — the path to your array with every
`status` filled in, which is what `post` takes.

- A matched pair is `still` when the summaries are similar, or when the
  severity is equal at the same line. Any other matched pair is `ambiguous`
  and carries `suggest` — `still` when the severity matches, else `new` — with
  its `index`, `distance` and `severity_match`. The block and `annotated`
  apply every `suggest` already.
- **Settle every `ambiguous` pair** before posting: keep its suggestion, or
  rerun `delta` once with `--settle <index>=<still|new>` for every pair you
  change. The rerun rebuilds the block, the buckets and `annotated`.
- **A `new` finding is aged by the range, not by the prior review.** `prepare`
  writes `age.json` from the compare call — the new-side hunk spans per file
  between the prior marker SHA and HEAD — on every re-review, complete ones
  included. A `new` finding with no anchor in a hunk of that range was already
  there at the prior SHA: `delta` lists it in `late[]`, sets `late: true` on
  it, and the block names it `🔎 Missed earlier`. Its description in
  `### Findings` starts with one sentence that says so, for example `This code
  was present at <prior short-sha>; the previous review did not report it.`
  A range that is not whole (`age_known: false`) ages nothing.
- **A defect the range causes from another file is new.** When a range change
  outside every anchor makes the finding true — a new caller, a changed
  default — rerun `delta` with `--fresh <index>` for that finding, in the same
  rerun as any `--settle`.

Insert the block between `### Summary` and `### Findings`:

```
### Changes since last review
Previous HEAD: <short-sha> (<timestamp>) — verdict <PREV_VERDICT>[ — unreachable, reviewed the whole PR]

- ✅ **Fixed:** <one-liner> (`file:line`)
- 🔁 **Still present:** <one-liner> (`file:line`)
- 🆕 **New:** <description> (`file:line`)
- 🔎 **Missed earlier:** <description> (`file:line`) — present at `<prior short-sha>`
```

Delta-scope depth ([review.md](review.md) steps c–d):

- **One compare call decides the range, and `prepare` makes it.** Its base is
  the `headRefOid=` of the last review marker; the result is `delta` =
  `{base, status, reachable, files[]}`, `files[]` the changed paths as plain
  strings. `status: ahead` with a `patch` per file
  → `reachable: true`, delta depth on `delta.files[]`. `status: identical`, or
  the base already at HEAD → `reachable: true` with an empty `files[]`, the
  description-only case. Anything else — `diverged` / `behind`, 404, 300 files,
  a file without `patch` — → `reachable: false`: review at complete depth in
  the delta output format, with ` — unreachable, reviewed the whole PR`
  appended to the `Previous HEAD` line.
- **A range that does not change the PR's own diff is not a review round.**
  `prepare` digests the diff it fetched and compares it with the digest the
  last review recorded ([review-mechanics.md](review-mechanics.md) → **Summary
  body format**); equal → `delta.own_change:
  false`, the range holds base-branch merges only. Skip steps c and d: no
  candidates, no skills, no sweep. Carry every open prior finding into the
  block as `🔁 Still present` one-liners, keep the prior verdict, and write
  `Range holds base-branch merges only — no change to this PR's own diff.`
  under the `Previous HEAD` line, with `_No new findings at this HEAD._` as
  `### Findings`. No prior digest (pre-4.1.0) → the normal delta round.
- **Candidates come from the range's hunks only** (`gh api
  "repos/$REPO/compare/<delta.base>...<head-sha>"`, or read them in the clone),
  in files the PR diff touches. A hunk whose added lines are absent from the PR
  diff arrived with a base-branch merge and is not a candidate; the full PR
  diff is context for reading them. A description-only re-review has an empty
  range: candidates, verification, sweep and extension-skill routing all use
  the full PR diff, re-read against the edited body.
- **Each prior finding is settled at its anchor.** Read every `file:line` of
  `prior_findings` at HEAD — from the clone, or via `gh api
  "repos/$REPO/contents/<path>?ref=<head-sha>" -H 'Accept:
  application/vnd.github.raw'` — and classify it `fixed` or `still` (moved code
  is `still`, at its new line). A `line: null` finding is settled by re-reading
  its file.
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
- `### Findings` lists **only `🆕 New` and `🔎 Missed earlier` findings**,
  inline-carried ones as one-liners. No `✅ Looks good` on re-reviews, ever.
  Nothing new → the section body is `_No new findings at this HEAD._`
- The **Verdict weighs all current findings** — new, still-present and skill
  findings alike: an unfixed 🔴 keeps `REQUEST_CHANGES` even as a one-liner.
- Skill sections condense the same way: unchanged findings collapse into `🔁 <N>
  finding(s) from the previous review still present (see review at
  <short-sha>)`, full text only for new findings, clean-run lines as-is.
- Inline eligibility: [review-mechanics.md](review-mechanics.md) →
  **Mapping findings to inline comments**, rule 5.

Prior review file missing → skip the block, review as a first review, and
append `(no prior review on file)` to `### Summary`.

## Carried review after a HEAD move

A review whose HEAD moved is never published — the marker SHA must be the live
HEAD. Its findings are still work, so the abort writes them to
`reviews/pr-<n>.carry.json` (`{sha, ts, hops, kind, run, findings}`) and the
next review of that PR starts from them. `prepare` resolves the carry with one
compare call and reports it as `carry`:
`{sha, ts, hops, kind, run, reachable, files[], findings[]}`.

- **The work is delta-scope, the output is the kind's own.** Review
  `carry.files` — the range between the carried SHA and HEAD — at first-review
  depth. Extension-triggered skills route from that range, `always` skills run
  over the whole clone, exactly as on a delta re-review
  ([skills.md](skills.md) → **Triggers & file routing**). A carried re-review
  posts as a re-review: the carry range wins over the delta range — it is the
  narrower one and the carried findings cover everything before it — and
  `delta` classifies them with the rest against the same unchanged prior.
- **An empty `carry.files` means HEAD's tree is back at the carried SHA** (it
  returned there, or a commit and its revert). The carried findings are
  current, there is no range to review, and every skill routes over the whole
  PR as on any first review.
- **Settle every carried finding at its anchor** at the live HEAD, the way a
  re-review settles a prior (**Re-review output**): read its `file:line`, keep
  it when the defect is still there, drop it when the range fixed it. A
  `line: null` finding is settled by re-reading its file.
- **Never name the carry.** Nothing was published, so a first review is the
  plain [review.md](review.md) → **Output format** — no
  `### Changes since last review`, no `🔁`, no
  `✅ Fixed`, every `findings-json` entry `status: "new"` — and a re-review is
  the format its trigger sets. A carried finding is reported as what it is — a
  finding — not as a carryover.
- **`carry: null` means review the whole PR.** `prepare` drops a carry whose
  range is not `ahead`, is 300 files or larger, has a file without a patch,
  whose `hops` passed 3, or whose `kind` is not this run's; each drop is logged
  with its reason. A carry with no findings holds the hop and run counters
  only: it is kept, and the review runs at full scope.
- `post` deletes the carry once the review is published, and when the PR closes
  mid-review. Pruning deletes it with the rest of the PR's state
  ([review-bookkeeping.md](review-bookkeeping.md) → **Pruning**).

## Revoking a stale approval

When a review's verdict is **not** `APPROVE` — a first review or a re-review
from `post`, or a rapid `REQUEST_CHANGES` ([review-urgent.md](review-urgent.md)
→ **Urgent PRs**) — the script dismisses every standing `APPROVED` review of the
agent on the PR (its own login, its review marker or its rapid marker, never a
human's) after the new review posts:

```bash
gh api "repos/$REPO/pulls/<n>/reviews/<id>/dismissals" -X PUT -f event="DISMISS" \
  -f message="Superseded by $BOT_NAME review at <new-sha> — verdict is now <new-verdict>."
```

It logs `PR #<n>: dismissed stale approval <id> (APPROVE → <new-verdict>)` per
dismissal (`dismissed_approval`, the last id, in its outcome). A new `APPROVE`
leaves the approvals in place. A failed dismissal is logged, not fatal.
