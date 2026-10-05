# Agent fixes — fixing the agent's own findings on a labeled PR

Read this file on every review run whose worklist has a non-empty
`fixes_due`. It runs only under `agent_fixes: enabled` with an
`agent_fix_label` ([config.md](config.md)); both are off until the repository
admin opts in at onboarding.

`scripts/preflight.sh review` emits an entry when a person put
`agent_fix_label` on an open PR, the agent's review of the current head left
at least one open 🔴 or 🟡 with a **Fix:** line, the head branch lives in the
target repository (a fork branch is never pushed to), and no fix of this head
ran before (`<!-- agent-fix: <sha> -->` in `reviews/pr-<n>.md`). A pushed fix
adds `<!-- agent-fix-pushed: <new-sha> -->`.

## Fixing

Per entry, between `review-pr.sh hold <n>` and `review-pr.sh release <n>`
([worklist.md](worklist.md) → **PR holds**; `held_elsewhere` → log it and
leave the entry to the next run):

1. `review-pr.sh fix-start <n> --sha <sha>`. It re-reads the PR, refuses when
   the head moved, the label is gone or the branch lives in a fork
   (`skipped`), removes the label, clones the head branch to `clone` with the
   bot as the git identity, and writes the marker. `skipped` or `error` → log
   the reason and stop; nothing was consumed, so a later run can retry.
   `failed` (the clone did not succeed after the label was removed) → push
   nothing and go to step 5: the head carries no marker, so the person can
   add the label again.
2. In `clone`, follow the bundled `review-remediation` skill
   (`.agents/skills/review-remediation/SKILL.md`) for the agent's last review,
   with these limits: fix only blocking findings whose fix the review states,
   change only the files those findings name, and never answer a disputable
   finding — list it in the comment for the author. No caller is present to
   ask. The skill's reading and code-editing steps apply; the PR body stays as
   it is, and the skill's push and comment are steps 4 and 5 here.
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

A PR with a pushed agent fix never auto-merges
([auto-merge.md](auto-merge.md)): a person reviews the fix.

## Self-check

Every fix matched a `fixes_due` entry · the label removed and the marker
written before the push · only the named files changed · no push after a
failed check (`--abort`) · no repository code run · one comment per started
round · no re-review started by the agent.
