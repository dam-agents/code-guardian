# Review posting and tracking state

What `scripts/review-pr.sh` does for you: the posted payload, the tracking
rows, the history file and the ledger. `compose-brief` prints the two sections
step e needs; read the whole file in the manual fallback (which, under
`review_progress: enabled`, also writes the status rows of
[review-bookkeeping.md](review-bookkeeping.md) → **Progress signal on
GitHub**) or to write a history-file section yourself.

## Posting the GitHub review

`review-pr.sh post` submits one PR review — summary and inline comments in a
single submission — from `body.md`, `findings.json` and `comments.json`
([review.md](review.md) step e) to `repos/$REPO/pulls/<n>/reviews`:

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
(`scripts/lib/harness.sh`); an unknown part is left out. The trailing marker
line is **mandatory** — it drives dedup — and uses the full 40-char SHA.

**`findings-json`** — the machine-readable copy of `### Findings`, in every
posted full review; rapid reviews carry none. Per finding: `status`
(`new`|`still`|`fixed`; first reviews all `new`), `severity`
(`critical`|`warning`|`suggestion`), `file`, `line` (null when not
anchorable), `also` (the other locations of the same finding, `[{file,
line}]`; omitted when there is one), `late` (`true` on a `new` finding already
present at the prior reviewed SHA, [review-rereview.md](review-rereview.md) →
**Re-review output**; omitted otherwise), `inline`, `summary` (≤ ~10 words),
`fix` (the **Fix:** line in ≤ ~15 words; `null` on `suggestion` and `fixed`).
`critical` and `warning` are the blocking set the next re-review checks
against. Every anchor is a real line of the file it names — `post` warns on
one that is not, and nulls it only under `--accept-warnings`
(`anchors_nulled`). No `--` in the JSON (HTML-comment safety): `post` writes it
as `–`. No findings → `[]`. An older line without `fix` or `also` stays valid.

**`review-meta`** — machine state for the next round and for the author's fix
round, in every posted full review, never rendered in the body (the
`_N suggestion(s) dropped_` line stays). Absent, unparsable or missing a key →
every consumer keeps its behavior without it. `post` writes `diff_digest`
([review-rereview.md](review-rereview.md) → **Re-review output**) and
`rereview` — how the next round is requested: `trigger` (`rereview_trigger`,
[config.md](config.md)) with the `label` to add or the `login` to request a
review from, `null` where unused. You compose the rest in `meta.json` (`post
--meta`):

- `checks` — per blocking finding whose **Fix:** is a class rule: `for` is its
  `summary` verbatim, `run` the sweep that located the occurrences you
  confirmed, in portable form — `git grep -nE -e '<ERE>'` as it runs in a
  plain checkout of the branch, `-e` in place of `--` — and `clean` what a
  clean run prints (`no hits`, or the locations a hit is correct at). Commands
  that only read, never one that changes a file.
- `deferred` — every 🟢 the budget dropped ([finding-form.md](finding-form.md)),
  for the author's fix round (review-remediation reads it).
- `triage` — your call on whether a person must read this PR, for the shepherd
  ([shepherd.md](shepherd.md) → **Scope and brief**): `class` `needs-human` (a
  person must judge design, architecture, product behavior or a risk the
  review cannot settle) or `quick-check` (the review covered it; a person only
  confirms), `why` (≤ ~15 words, what the person must judge; `null` on a quick
  check), `verified` (≤ ~15 words, what this review already checked),
  `minutes` (your estimate of a human read). A changed file under
  `human_review_paths` ([config.md](config.md)) is a lead `compose-brief`
  names; `post` records the match in `forced` and keeps your `class`. An
  unknown or missing class reads as `needs-human`.

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
  posted review**. Preflight writes this flip; you write it only to restore it
  on a re-review abort. Every other timestamp is the actual UTC write time
  (`date -u +%Y-%m-%dT%H:%M:%SZ`) — never rounded, reused or fabricated.
- The lock is best-effort (**50-min TTL**, `LOCK_TTL_MIN` in
  [preflight.sh](../scripts/preflight.sh)); the remote dedup check stays
  authoritative.
- `review-pr.sh` writes every row (`prepare` locks, `step` refreshes, `rapid`
  sets `RAPID`, `post` / `abort` finish, `row` the bookkeeping rows), one
  writer at a time with preflight (`with_state_lock` in
  [common.sh](../scripts/lib/common.sh)). In the manual fallback, rewrite the
  PR's line in place, keeping this row shape (the adapter derives `locked`,
  `done` and `aborted (lock released)` from it); rows are full of `|`, so give
  sed another delimiter:

  ```bash
  sed -E "s#^\| *<n> *\|.*#| <n> | <sha> | <ts> | <verdict> | <status> |#" work/REVIEWS.md \
    > work/REVIEWS.md.tmp && mv work/REVIEWS.md.tmp work/REVIEWS.md
  ```

### Live holder — a lock past its TTL that is still working

**The TTL bounds a crash, not a slow review.** Preflight emits `takeover` for
a lock past `LOCK_TTL_MIN` **only when no run is a live holder of the PR**.
The core rule: a run with a `locked` step on the PR holds it while its newest
`review_step` there is non-terminal ([review.md](review.md) → **Completion
enforcement**) and its newest event of any kind is inside `HOLDER_QUIET_MIN`
(20) — `FANOUT_QUIET_MIN` (60) while that event is `fanned out (n=…)`,
calibrated against `stats.reviews.phases.skills` ([audit.md](audit.md) task
23). A run that ended, or never locked the PR, holds nothing. With no `locked`
step since the lock (it can predate log retention), a recent event naming the
PR counts as life when its run has not ended the PR. The platform's session
list decides first where it knows the holder's session
([sessions.md](sessions.md) → **Uses**), else the local log. Both the row
timestamp ([review.md](review.md) → **Lock heartbeat**) and the event stream
must go quiet. A live holder's PR is omitted and logged `holder … — left
running`. Rule and windows: [lib/holds.sh](../scripts/lib/holds.sh).

- **As the holder you own the PR to a terminal state whatever your lock age.**
  Keep refreshing and finish; step f's dedup re-check turns your post into
  `duplicate` if a second job posted at your SHA.
- **As the taker, Check 1 re-checks exclusivity for every entry, whatever its
  `takeover` flag** (preflight's snapshot can predate your arrival). `prepare`
  stands down — `outcome: stand_down`, nothing touched, `holder alive at Check
  1 — stood down` logged; take the next PR — while a foreign run is a live
  holder by the core rule over every retained event (a `locked` step at any age
  counts) and the session list does not show it idle. With no such holder it
  stands down while a tree, diff or state of `/tmp/review-pr-<n>*` is younger
  than `HOLDER_QUIET_MIN`. A holder the list shows idle is dead with its tree:
  a run killed inside the skill fan-out logs no stop event, so its
  `fanned out (n=…)` window would otherwise hold the PR for the full hour. A
  leftover of a dead run is reclaimed
  ([skills.md](skills.md) → **Clone, credential helper, cleanup**) before the
  lock write.

**`reviews/pr-<number>.md`** — per-PR history (`mkdir -p reviews`):

```markdown
# PR #<number>: <title>
<!-- artifact-guide: <DAM_ID> <sha7> <share-url> -->

## PR-local overrides

- [2026-04-23 from user] Ignore: null check on `src/auth.ts:42` — confirmed intentional

## Review at <headRefOid-short> — <ISO timestamp> — <VERDICT>

<full review body as posted, starting with ### Summary>

---
```

Title header and overrides stay at the top; reviews append below, oldest first,
separated by `---`. Update the header on a title change. The guide marker
sits right after the title, overwritten in place by `review-pr.sh guide`, and
is omitted when no guide was published; `post` writes `<!-- guide-label-seen
-->` after a round's section ([artifact.md](artifact.md) → **Review guide**).
Watch-rule markers (`<!-- watch-sent: <id> -->`, [watches.md](watches.md))
follow on their own lines.

**Review ledger** — `work/REVIEW-LEDGER.jsonl`, the append-only record of
posted reviews, one line per review, written by `review-pr.sh` with the
history section:

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
posted prose against the sentence bar, `findings[]` adds `late: true` with
the finding's `file`, `line` and `summary` where set, and `size` is the PR
itself — a count GitHub had not finished computing is `null`, never `0`
([audit.md](audit.md) → task 33). A row written before a field existed lacks
it, and the audit reads each as a floor.

Pruning deletes the history file; the ledger row stays. Every reader
([audit.md](audit.md), [trends.md](trends.md)) goes through
`scripts/lib/review-records.sh`, which unions the ledger with the history files
still on disk and keeps one record per `(pr, ts)`. Retention: 180 days
([logging.md](logging.md) → **Retention**). Only the audit trims this file.
