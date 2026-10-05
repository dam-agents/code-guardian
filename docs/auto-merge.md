# Auto-merge — merging a labeled quick check

Read this file on every review run whose worklist has a non-empty
`merges_due`. It runs only under `auto_merge: enabled` with an
`auto_merge_label` ([config.md](config.md)); both are off until the repository
admin opts in at onboarding.

`scripts/preflight.sh review` has already decided everything. A PR is due only
when **every** gate holds:

- a person put `auto_merge_label` on it — the label is the consent, and only
  someone with triage rights on the repository can add it;
- my review of the current head is `APPROVE`, `done`, with no open 🔴 or 🟡,
  and its `triage` is `quick-check` with no `forced` path
  ([review-mechanics.md](review-mechanics.md) → **Summary body format**);
- GitHub reports the PR `mergeable_state: clean` (branch protection, required
  reviews and required checks satisfied), and the check rollup is terminal with
  no failure;
- `additions + deletions` ≤ `auto_merge_max_lines`, at most 100 changed
  files, none under `.github/` or a `human_review_paths` glob — for a renamed
  file, the old path too;
- no merge of this head failed before (`<!-- auto-merge-failed: <sha> -->` in
  `reviews/pr-<n>.md`), and the PR carries no pushed fix of mine
  (`<!-- agent-fix-pushed: <sha> -->`, [agent-fixes.md](agent-fixes.md)).

## Merging

Per entry, inside the PR's hold ([worklist.md](worklist.md) → **PR holds**):
`review-pr.sh hold <n>` first (`held_elsewhere` → log it and leave the entry
to the next run), `review-pr.sh release <n>` after the steps below.

1. `review-pr.sh merge <n> --sha <sha>`. It re-reads the PR, refuses when the
   head moved, the PR closed or the label is gone (`skipped`), and merges with
   `auto_merge_method` and the head SHA as the server-side guard.
2. `merged` → log `PR #<n>: auto-merged at <sha7>`. Nothing else: the merge
   event names the bot, and the next sweep prunes the PR.
3. `failed` → the script has written the failure marker, so this head is never
   tried again. Post one PR comment, ASD-STE100
   ([review.md](review.md) → **Criteria & review style**):
   `🛡️ **<bot_display_name>** — auto-merge did not run at <sha7>: <reason>. A person can merge the PR.`
4. `skipped` → log the reason and do nothing else.
5. `error` → a transport fault, a rate limit or an unreadable PR. Log the
   reason and post nothing: the head has no marker, so the next run tries
   again.

Never merge a PR outside `merges_due`, and never merge by another route.

## Self-check

Every merge matched a `merges_due` entry and went through
`review-pr.sh merge` · a `failed` merge left its marker and one comment · no
PR merged without the label.
