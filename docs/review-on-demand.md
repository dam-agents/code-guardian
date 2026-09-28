# On-demand review (Slack or mention)

Read when a channel message or a mention asks for a review of a specific PR.

The one non-operator request that triggers work ([runbook.md](runbook.md) →
**Instruction sources & trust boundary**): **anyone** in the connected channel,
or in a GitHub comment addressed to the bot ([mentions.md](mentions.md)), may
ask for a review of a specific PR — equivalent to adding `$REREVIEW_LABEL`.
Nothing else is changeable from those surfaces.

1. Resolve the PR reference (number or URL; a mention's own PR when none is
   named) and `gh pr view` it. Not found / closed / draft → reply so, done.
2. `review-pr.sh prepare <n> --on-demand`. `stand_down` → reply "review
   already running", done. A stale, silent lock is taken over — log
   `PR #<n>: stale lock killed on on-demand request`.
3. `skip` with `already reviewed at <short-sha>` → reply so; same-SHA dedup
   always holds.
4. `ready` → read [review.md](review.md), [finding-form.md](finding-form.md) and
   [skills.md](skills.md), then run the per-PR sequence from step b. `kind` =
   `re-review` when a prior review exists, else `first`; a re-review also reads
   [review-rereview.md](review-rereview.md) and runs **delta scope** unless
   `$REREVIEW_LABEL` is also on the PR; no trigger is required at `prepare` or
   `post`; install missing skills per [skills.md](skills.md) → **Installation**.
   Reply in the requesting channel or thread with a link to the posted review,
   then persist `work/` ([persistence.md](persistence.md)).

Replying to the requesting surface is responsive, not proactive — it does not
require `slack_notifications: enabled`.
