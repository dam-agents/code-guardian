# Review posting and tracking state

What `scripts/review-pr.sh` does for you: the posted payload, the tracking
rows, the history file and the ledger. `compose-brief` prints the two sections
step e needs (**Summary body format**, **Mapping findings to inline comments**).
Read the whole file in the manual fallback, or to write a history-file section
yourself; under `review_progress: enabled` the manual fallback also writes the
status rows of [review-bookkeeping.md](review-bookkeeping.md) → **Progress
signal on GitHub**.

## Posting the GitHub review

`review-pr.sh post` submits one PR review — summary and inline comments in a
single submission — from `body.md`, `findings.json` and `comments.json`
([review.md](review.md) step e). The payload it posts to
`repos/$REPO/pulls/<n>/reviews`:

```json
{ "commit_id": "<full headRefOid>", "event": "<COMMENT | APPROVE | REQUEST_CHANGES>",
  "body": "<summary body — below>",
  "comments": [ {"path": "src/foo.ts", "line": 42, "side": "RIGHT", "body": "🟡 **Warning:** …"} ] }
```

`event` = the Verdict verbatim, except on a pull request the token's own login
opened: there it is `COMMENT`, and the body names the verdict
([github-access.md](github-access.md) → **Own pull request**). `commit_id` =
the reviewed `headRefOid`, the server-side stale guard: GitHub 422s if HEAD
moved, and `post` aborts.

### Summary body format

```
🛡️ **<bot_display_name>** — <verdict-emoji> Code Review @ `<headRefOid-short>`

<the full structured review>

---
_Review by [<bot_display_name>](https://<def_host>/<definition_repo>) · automated code guardian · `<model>` on <harness>_

<!-- findings-json: [{"status":"new","severity":"critical","file":"src/auth.ts","line":42,"also":[{"file":"src/session.ts","line":18}],"inline":true,"summary":"token compared with ==","fix":"compare tokens with a constant–time equality helper"}] -->
<!-- review-meta: {"diff_digest":"<12 hex>","checks":[{"for":"token compared with ==","run":"git grep -nE -e 'token ==|== token'","clean":"no hits"}],"deferred":[{"file":"src/session.ts","line":18,"note":"<≤ ~12 words>"}],"rereview":{"trigger":"label","label":"<rereview_label>","login":null}} -->
<!-- <review_marker> headRefOid=<full-sha> -->
```

Emoji: ✅ APPROVE, ⚠️ COMMENT, ❌ REQUEST_CHANGES. The footer names the model
(`post --model`, else `PI_MODEL` / `ANTHROPIC_MODEL`) and the harness
(`scripts/lib/harness.sh`) that wrote the review; an unknown part is left
out. The trailing marker line is **mandatory** — it drives dedup — and uses
the full 40-char SHA.

**`findings-json`** — the machine-readable copy of `### Findings`, in every
posted full review. Per finding: `status` (`new`|`still`|`fixed`; first
reviews all `new`), `severity` (`critical`|`warning`|`suggestion`), `file`,
`line` (null when not anchorable), `also` (the sibling-sweep locations of the
same finding, `[{file, line}]`; omitted when there is one), `late` (`true` on
a `new` finding that was already present at the prior reviewed SHA,
[review-rereview.md](review-rereview.md) → **Re-review output**; omitted
otherwise), `inline`, `summary` (≤ ~10 words), `fix` (the **Fix:** line in
≤ ~15 words; `null` on `suggestion` and `fixed`). `critical` and `warning` are
the blocking set, so this line is the machine-readable approval bar the next
re-review checks against. Every anchor is a real line of the file it names —
`post` nulls one that is not and reports it. No `--` in the JSON (HTML-comment
safety): `post` writes it as `–`. No findings → `[]`. Rapid reviews carry no
such line. An older line without `fix` or `also` stays valid.

**`review-meta`** — machine state for the next round and for the author's fix
round, in every posted full review. Never rendered: nothing in it appears in
the review body, and the `_N suggestion(s) dropped_` line stays. The line
absent, unparsable or missing a key → every consumer keeps the behavior it had
without it. `post` writes `diff_digest`
([review-rereview.md](review-rereview.md) → **Re-review output**) and `rereview`
itself — how the next round is
requested: `trigger` (`rereview_trigger`, [config.md](config.md)) with the
`label` to add or the `login` to request a review from, `null` where the
trigger does not use it; you compose the rest in `meta.json` (`post --meta`).
`checks` — per blocking finding whose **Fix:** is a class rule: `for` is that
finding's `summary` verbatim, `run` the sweep that verified the class in its
portable form — `git grep -nE -e '<ERE>'` as it runs in a plain checkout of
the branch, `-e` in place of `--` — and `clean` what a clean run prints
(`no hits`, or the locations a hit is correct at); commands that only read,
never a command that changes a file. `deferred` — every 🟢 the budget dropped
([finding-form.md](finding-form.md)), for the author's fix round
(review-remediation reads it). `triage` — your call on whether a person must
read this PR, for the shepherd ([shepherd.md](shepherd.md) → **Scope and brief**):
`class` `needs-human` (a person must judge design, architecture, product
behavior or a risk the review cannot settle) or `quick-check` (the review
covered it; a person only confirms), `why` (≤ ~15 words, what the person must
judge; `null` on a quick check), `verified` (≤ ~15 words, what this review
already checked), `minutes` (your estimate of a human read). `post` forces
`needs-human` when a changed file matches `human_review_paths`
([config.md](config.md)) and records the match in `forced`; an unknown class
reads as `needs-human`.

### Mapping findings to inline comments

1. Inline-eligible = `(file, line)` inside a diff hunk: `path` repo-relative,
   `line` in the new file (`side: "RIGHT"`; `"LEFT"` + old line for deleted
   code); multi-line adds `start_line`, both ends in one hunk. A finding with
   `also` locations takes one comment per location, each counted toward the
   cap and the priority of rule 4.
2. Outside every hunk, or no precise line → summary-only. `post` checks each
   comment against the hunk index and moves the ineligible ones under
   `### Findings not anchorable inline` (`inline: false` in `findings-json`).
3. `✅ Looks good` → summary-only, never inline (first reviews only).
4. **Cap 25 inline comments** — `post` keeps the most severe and moves the
   rest to the summary.
5. **Re-reviews: only `🆕 New` and `🔎 Missed earlier` findings inline** —
   carryovers keep their existing thread, `✅ Fixed` get nothing.

**Suggestion blocks** — strongly recommended on every inline finding whose fix
is local and unambiguous (about 5 lines or fewer): a ` ```suggestion ` block
that replaces exactly the anchored line(s) — matching indentation,
replacement lines only, one block per comment. Never for style preferences.

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
  sets `RAPID`, `post` / `abort` finish, `row` the bookkeeping rows), and it
  and preflight write one at a time (`with_state_lock` in
  [common.sh](../scripts/lib/common.sh)). In the manual fallback, rewrite the
  PR's line in place; rows are full of `|`, so give sed another delimiter:

  ```bash
  sed -E "s#^\| *<n> *\|.*#| <n> | <sha> | <ts> | <verdict> | <status> |#" work/REVIEWS.md \
    > work/REVIEWS.md.tmp && mv work/REVIEWS.md.tmp work/REVIEWS.md
  ```

  Keep this row shape — the adapter derives `locked`, `done` and
  `aborted (lock released)` from it ([review.md](review.md) → **Progress
  logging**).

### Live holder — a lock past its TTL that is still working

**The TTL bounds a crash, not a slow review.** A lock past `LOCK_TTL_MIN` is
only a candidate: preflight emits `takeover` **only when no run is a live
holder of the PR** in the events since the lock. The core rule: a run with a
`locked` step on the PR is its holder; it still owes the PR while its newest
`review_step` there is non-terminal ([review.md](review.md) → **Completion
enforcement**), and it is alive while its newest event of any kind is inside
`HOLDER_QUIET_MIN` (20). A run that ended releases the PR at once, however
many milestones it logged first; a run that never locked it holds nothing.
Preflight's fallback: with no `locked` step since the lock (it can predate log
retention after a crash), a recent event naming the PR counts as life when
its run has not ended the PR. A live holder's PR is omitted and logged
`holder … — left running`. The check is a local log read; the rule and its
windows live in [lib/holds.sh](../scripts/lib/holds.sh). Two signals must both
go quiet: the row timestamp ([review.md](review.md) → **Lock heartbeat**) and
the event stream.

**The skill fan-out has its own window.** A holder whose newest event is
`fanned out (n=…)` is blocked on its subagents until `verified`, and stays
alive for `FANOUT_QUIET_MIN` (60) instead; calibrate the value against
`stats.reviews.phases.skills` ([audit.md](audit.md) task 23).

- **As the holder you own the PR to a terminal state whatever your lock age.**
  Keep refreshing and finish. Step f's dedup re-check is the safety: a second
  job that posted at your SHA turns your post into `duplicate`.
- **As the taker, Check 1 re-checks exclusivity for every entry, whatever its
  `takeover` flag.** `takeover: true` means preflight saw no life, not proof of
  death; `takeover: false` only means its snapshot saw no lock, and that
  snapshot can predate your arrival by minutes. `prepare` re-checks first: the
  PR lives when a tree, diff or state of `/tmp/review-pr-<n>*` is younger than
  `HOLDER_QUIET_MIN`, or when another run is a live holder by the core rule
  above, read over every retained event (a `locked` step at any age counts).
  Then it stands down — `outcome: stand_down`, nothing touched,
  `holder alive at Check 1 — stood down` logged — and you take the next PR.
  An older tree with no such event is a dead run's leftover and is reclaimed
  ([skills.md](skills.md) → **Clone, credential helper, cleanup**); the lock
  write comes after this check.

**`reviews/pr-<number>.md`** — per-PR history (`mkdir -p reviews`):

```markdown
# PR #<number>: <title>
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

**Review ledger** — `work/REVIEW-LEDGER.jsonl`, the append-only record of the
reviews that were posted, one line per review, written by `review-pr.sh`
together with the history section above:

```json
{"src":"ledger","pr":42,"ts":"<ISO>","sha":"<short>","kind":"first|re-review",
 "verdict":"APPROVE|COMMENT|REQUEST_CHANGES","size":{"files":3,"additions":40,"deletions":5},
 "def":"<definition VERSION>",
 "bullets":{"fixed":0,"still":0},
 "suppressed":{"overrides":0,"context":0,"decisions":0,"total":0},
 "ste":{"sentences":0,"avg_sentence_words":null,"sentences_over_20":0,"v":2},
 "findings":[{"status":"new","severity":"critical"}]}
```

`def` is the definition version that wrote the review, `suppressed` counts
the audit note ([review.md](review.md) → **PR context**), `ste` measures the
posted prose against the sentence bar, `findings[]` adds `late: true` where
set, and `size` is the PR itself — a count GitHub had not finished computing
is `null`, never `0` ([audit.md](audit.md) → task 33). A row written before a
field existed carries none of it, and the audit reads each as a floor.

Pruning deletes the history file; the ledger row stays. Every reader
([audit.md](audit.md), [trends.md](trends.md)) goes through
`scripts/lib/review-records.sh`, which unions the ledger with the history files
still on disk and keeps one record per `(pr, ts)`. Retention: 180 days
([logging.md](logging.md) → **Retention**). Only the audit trims this file.
