# PR Shepherd — sending nudges

Read this file on every **shepherd run** whose preflight worklist has a
non-empty `nudges_due`. Runs only when `slack_notifications: enabled`.

`scripts/preflight.sh shepherd` has already done the deciding: classified
every open non-draft PR from **independent reviews** (not the bot, not the
author; only `APPROVED` silences — `CHANGES_REQUESTED` flips to
author-directed mode, a bare `COMMENTED` counts as awaiting), applied the 24h
age gate, the 20h per-PR cooldown, and the ≥2-day escalation tick, reset the
ladder (but never the clock) on class transitions, kept `held` rows held, and
updated the ledger's bookkeeping columns. **Rows with a due nudge were left
untouched** — advancing them is your write-before-send step.

## Hard rules

- **Send only what's in `nudges_due`, at most once each.** For every entry,
  **first** apply its `row_update` (`nudges`, `level`, `status`) plus
  `last_nudge_at` = the current UTC time to the PR's ledger row, **then**
  send. Write-before-send: a failed send after the write is logged (chat UI
  + `nudge_send` error event — [logging.md](logging.md)) and NOT retried
  this run — under-sending beats double-sending. Never
  re-fire a nudge preflight didn't emit.
- **Roster-only tagging.** Never @-mention anyone not in
  `work/DEVELOPERS.md`; the only `<@…>` ids ever emitted are roster
  `slack_id` values (the worklist's `mentions` array). Non-roster people
  (including a non-roster author in author-directed nudges) are named in
  plain text, never mentioned. Seed expertise in the roster is
  operator-authored — never overwrite it; only append to "Observed areas".
- **One shared channel, no DMs**: send via
  `mcp__platform-outbound__send_channel_message` (`channel: "slack"`, omit
  `chatId`).

## Target selection (`needs_target_selection: true`)

When a reviewer-directed nudge has no persisted targets and no requested
reviewer intersects the roster, pick **2 roster members** (1 if that's all
there is), mark them `*` (Slack-only suggestion, never requested on GitHub):

- Build keywords from the PR title + changed paths/extensions
  (`gh api "repos/$REPO/pulls/<n>/files?per_page=100" --jq '[.[].filename]'`).
- Score roster members by overlap with their expertise (seed + observed);
  exclude the author. Tie-break by contributor volume on the target repo
  (roster members only). Nothing scores → the two highest-volume roster
  contributors who aren't the author.
- **Persist the chosen pair** into the ledger row's `reviewers` cell before
  sending (deterministic targets: later sweeps reuse the cell instead of
  recomputing).

## Message templates (tone rises with level; always link the PR)

Wording follows ASD-STE100 ([review.md](review.md) → **Criteria & review
style**).

**Reviewer-directed** (`awaiting_review`):
- L1: `👀 PR #<n> "<title>" by <author> has been open <age> with no review yet. <@id1> <@id2> could you take a look? Focus: <focus>. <url>`
- L2: `⏰ Reminder — PR #<n> "<title>" is now <age> old and still unreviewed. <@id1> <@id2> a review would unblock <author>. Focus: <focus>. <url>`
- L3: `🚨 PR #<n> "<title>" has waited <age> for review. <@id1> <@id2> please prioritise this when you can. Focus: <focus>. <url>`
- L4: `📣 PR #<n> "<title>" by <author> has gone <age> without a review despite reminders. Looping in <@escalation-owner-slack-id> (<escalation_owner>) to help find a reviewer. Focus: <focus>. <url>`

**Author-directed** (`changes_requested`; never re-ping the reviewer):
- L1: `🔧 PR #<n> "<title>" has changes requested by <reviewer>. <@author> could you address the feedback and re-request review when ready? <url>`
- L2: `⏰ PR #<n> "<title>" still has open change requests from <reviewer>. <@author> a follow-up would move this forward. <url>`
- L3: `🚨 PR #<n> "<title>" has had requested changes unresolved for <age>. <@author> please push an update or reply to the reviewer. <url>`
- L4: `📣 PR #<n> "<title>" by <author> has sat with unresolved change requests for <age>. Looping in <@escalation-owner-slack-id> (<escalation_owner>). <@author> let's get this unblocked. <url>`

The focus line comes from the targets' expertise + the PR content. Level 4 =
widen + hold: include the `escalation` mention from the worklist when its
`slack_id` is present (missing → send without it and log); preflight marks
the row `held` afterwards — no further messages until the class changes.

## Expertise auto-refinement

While you're awake for a shepherd run: for each PR in the worklist authored
by a roster member, derive area keywords from its title + changed paths and
**append** genuinely new ones to that member's "Observed areas" in
`work/DEVELOPERS.md` (dedup, keep short, never touch seed expertise).

## Ledger & history

`work/SHEPHERD.md` is table-only — don't add narrative to it (per-sweep
history goes to `work/SHEPHERD.log`, append-only, never loaded into context).
Preflight maintains the bookkeeping columns; your ledger writes are exactly
two: the write-before-send `row_update` and persisting selected targets into
the `reviewers` cell (above).

## Shepherd-run self-check

Every send matched a `nudges_due` entry · every sent nudge's `row_update` was
written BEFORE the send (with a real UTC `last_nudge_at`) · only roster
`slack_id`s mentioned · targets persisted when selected · send failures
logged · observed areas appended additively · `work/` committed & pushed at
the end (per CLAUDE.md).
