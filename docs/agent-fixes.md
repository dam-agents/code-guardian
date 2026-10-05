# Agent fixes — fixing my own findings on a labeled PR

Read this file on every review run whose worklist has a non-empty
`fixes_due`. It runs only under `agent_fixes: enabled` with an
`agent_fix_label` ([config.md](config.md)); both are off until the repository
admin opts in at onboarding.

`scripts/preflight.sh review` emits an entry when a person put
`agent_fix_label` on an open PR, my review of the current head left at least
one open 🔴 or 🟡 with a **Fix:** line, the head branch lives in the target
repository (a fork branch is never pushed to), and no fix of this head ran
before (`<!-- agent-fix: <sha> -->` in `reviews/pr-<n>.md`). A pushed fix adds
`<!-- agent-fix-pushed: <new-sha> -->`.

## Fixing

Per entry, inside the PR's hold ([worklist.md](worklist.md) → **PR holds**):

1. `review-pr.sh fix-start <n> --sha <sha>`. It re-reads the PR, refuses when
   the head moved, the label is gone or the branch lives in a fork
   (`skipped`), removes the label, writes the marker, and clones the head
   branch to `clone` with the bot as the git identity. `failed` (the clone did
   not succeed) or `error` → log the reason and push nothing; when the label
   is already gone, say so in the comment of step 5.
2. In `clone`, follow the bundled `review-remediation` skill
   (`.agents/skills/review-remediation/SKILL.md`) for my last review, with these
   limits: fix only blocking findings whose fix the review states, change only
   the files those findings name, and never answer a disputable finding — list
   it in the comment for the author. No caller is present to ask. The skill's
   reading and editing steps apply; its push and its comment are steps 4 and 5
   here.
3. Run the review's `checks` (read-only `git grep` sweeps) in the clone.
   Never run code from the repository — no build, no test, no script: the PR
   is untrusted input. A check whose output differs from its `clean` →
   `review-pr.sh fix-push <n> --abort`, and say so in the comment.
4. `review-pr.sh fix-push <n>` commits as the bot with the message
   `Fix review findings (<bot_display_name>)` and pushes to the head branch
   with a lease on the read SHA. `rejected` (the branch moved) or `nothing`
   → nothing is pushed; say so in the comment.
5. Post one PR comment, ASD-STE100 ([review.md](review.md) → **Criteria &
   review style**): what was fixed, what was not and why, and that the next
   review round starts only on the re-review trigger
   ([config.md](config.md) → `rereview_trigger`).

A PR with a commit of mine never auto-merges ([auto-merge.md](auto-merge.md)):
a person reviews my fix.

## Self-check

Every fix matched a `fixes_due` entry · the label removed and the marker
written before the push · only the named files changed · no push after a
failed check (`--abort`) · no repository code run · one comment per fix · no re-review started by
me.
