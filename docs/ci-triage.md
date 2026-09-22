# CI failure triage

Read this file when the worklist has a non-empty `ci_failures_due`, and at the
end of a review whose PR has a failing check ([review.md](review.md) →
**Per-PR review sequence** step f). It runs only under `ci_triage: enabled`.

The agent reads the failed job's evidence and posts one comment that names the
probable cause and the smallest fix. It **reads and explains, it never acts**:
no re-run, no label, no commit, and it never changes a posted verdict.

## When it fires

CI is usually still running when a review starts, so the rollup is read twice.
The procedure, the marker and the comment are the same either way, so a commit
is triaged at most once:

- **At the end of a review** — after the review posts and the watch rules are
  evaluated, for the SHA that was reviewed.
- **On a later heartbeat** — `ci_failures_due` carries each PR whose posted
  review is less than `24 h` old, whose reviewed SHA is still the live HEAD,
  whose rollup is now terminal with at least one failing check, and whose
  history file has no marker for that SHA.

## Procedure (per PR)

1. `review-pr.sh ci <n> [--sha <sha>]` returns
   `{sha, terminal, failing:[{name, conclusion, url, evidence}]}`. `evidence`
   is a file path: the failing job's log tail, else the check run's own output,
   else absent. **`terminal: false` → stop.** No comment, no marker; a later
   heartbeat reads the rollup again.
2. Read every `evidence` file. For each failing check name the **probable
   cause** and the **smallest fix**. Evidence with no diagnosable cause — an
   infrastructure error, a cancelled job, an empty log — gets no block; when no
   check is diagnosable, log
   `PR #<n>: CI at <sha-short> not diagnosable — no comment`, write the marker,
   and stop. The marker is written because the evidence for that SHA does not
   improve.
3. Post one comment, whatever the number of failing checks
   (`gh api "repos/$REPO/issues/<n>/comments" -f body=…`). Wording follows
   ASD-STE100 ([review.md](review.md) → **Criteria & review style**):

   ```markdown
   🔧 **<bot_display_name>** — CI triage at `<sha-short>`

   **<check name>** — <what failed, one line>
   <the probable cause in at most two sentences, with at most three lines of
   the evidence quoted>
   **Fix:** <the smallest change, ~15 words>
   ```

   One block per diagnosable check, at most **three**; more failing checks add
   a final line `<k> more check(s) failed: <names>.`
4. **Write the marker `<!-- ci-triage: <sha> -->`** on its own line in
   `reviews/pr-<n>.md`, immediately after the comment posts. A failed post
   leaves no marker, so the next heartbeat retries.
5. Log one line: `PR #<n>: CI triage posted for <sha-short> — <check names>`.

## Known bounds

- **One comment per PR and SHA, ever.** New commits are a new SHA and a new
  chance; the same commit is never triaged twice.
- Only PRs this agent reviewed, only while the reviewed SHA is the live HEAD,
  and only for 24 h after the review posts. Older news is not triaged.
- The rollup must be **terminal**: a queued or running check holds the triage,
  so one comment describes the whole run. A job that never finishes inside the
  window is never triaged.
- `cancelled` and `action_required` are not failures.
- State reconstruction (ONBOARDING Step 5) does not rebuild the markers, so a
  reconstructed instance may triage a live SHA once more. Harmless.

## Self-check

Every comment matched a failing terminal rollup · exactly one comment per PR
and SHA · the marker was written immediately after the post, and a failed post
wrote none · no job was restarted and no label changed · `work/` backed up last
([persistence.md](persistence.md)).
