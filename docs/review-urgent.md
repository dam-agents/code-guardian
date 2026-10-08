# Urgent and closed PRs

Read when the worklist's `read_set` names this file — a `reviews_due` entry
flagged `urgent` or `closed`, or `urgent_alerts_due` non-empty — and when
`post` returns a `closed_*` outcome.

## Urgent PRs — rapid-first delivery

`urgent_label` (missing = off) names a **human-managed** label — the agent
never adds or removes it. While it is on a PR, every due review of it runs
rapid-first: preflight flags the entry `urgent: true` and orders it first,
Check 1 re-verifies the label and reviews normally when it is gone.

**Immediate Slack alert (`urgent_alerts_due`, once per PR).** Preflight emits
`{number, title, author, url}` for every open urgent PR whose history file
lacks an `urgent-announced` marker, only under
`slack_notifications: enabled`. Send these **before any PR work**:

1. `mcp__platform-outbound__send_channel_message`, addressed to the channel
   alone — the alert carries no @-mention: `🚨 **<bot_display_name>** — URGENT:
   PR #<n> "<title>" by <author> needs eyes now (\`<urgent_label>\`). Rapid
   review incoming. <url>`
2. **Write the marker immediately after a successful send** —
   `<!-- urgent-announced: <ISO timestamp> -->` into `reviews/pr-<n>.md`,
   creating the file with its title heading when missing. A failed send writes
   no marker and is logged; the next heartbeat re-emits the alert.
3. Log `PR #<n>: urgent alert sent`.

**Phase 1 — rapid preliminary review**, right after `prepare` returns, before
orientation and skills. Optimize for delivery speed.

1. Review the diff only (`$PR_DIR.diff`; on a re-review prefer the range since
   the prior review) for **🔴 Critical findings only**. On a re-review, a 🔴
   of the prior review (its `findings-json` in `reviews/pr-<n>.md`) or of
   `prepare`'s `carry` that the range does not fix counts too and is listed.
   The verdict is `APPROVE` when there is none, `REQUEST_CHANGES` otherwise —
   🟡 and the check rollup never hold the rapid verdict.
2. Write `rapid.md`, body only, no inline comments:

   ```
   ⚡ **<bot_display_name>** — ⏱️ Rapid preliminary review @ `<sha-short>`

   > Fast pass triggered by the `<urgent_label>` label — critical checks of
   > the diff only. **The full review follows.**

   ### Critical findings
   - 🔴 **Critical:** <one-liner> (`file:line`)
   ```

   No criticals → the section body is `_None found at rapid-review depth._`,
   and the quote adds `This approval covers critical checks only. The full
   review can cancel it.`
3. `review-pr.sh rapid <n> --verdict <V> --body <ctx>/rapid.md`. It dedups on
   the **rapid marker** `<!-- <review_marker>:rapid headRefOid=<full-sha> -->`
   at the live HEAD (`already_posted` → go to phase 2), posts one review with
   `event: <V>` and the marker appended, sets the REVIEWS.md verdict cell to
   `RAPID` with a fresh timestamp (status stays `in_progress`), logs `rapid
   posted`, and writes the progress status. A `REQUEST_CHANGES` dismisses the
   agent's standing approvals of the PR
   ([review-rereview.md](review-rereview.md) → **Revoking a stale approval**).

**Phase 2 — the full review, immediately after** — the normal sequence from
[review.md](review.md) step b, skills and the full approval bar included. The
`:rapid` marker is invisible to the normal dedup, so the full review posts as
usual; a verdict below `APPROVE` revokes the rapid approval. Watch rules
evaluate once, after it. A rapid post is **never** terminal. A died run is
recovered by the stale-lock takeover — verdict `RAPID` tells the next run to
skip phase 1.

## PR closed mid-review — findings become an issue

Applies to **every** review. `post` finding the PR `CLOSED`/`MERGED` at Check 2
posts no review. Its `scope` is `blocking` (🔴 and 🟡) when the PR merged and
carries a standing rapid approval at the reviewed HEAD — it merged on critical
checks alone — and `critical` (🔴) otherwise. The outcome says what is left:

- **`closed_discarded`** — no finding in `scope`. The lock is released as on a
  Check 2 abort; log `PR #<n>: closed mid-review — discarded (no <scope>
  findings)`.
- **`closed_findings`** — carries `findings`, `issue_title`, the
  `issue_marker`, and `existing_issue` when one is already filed. Deliver them
  as one issue: reuse `existing_issue`, or `gh api "repos/$REPO/issues" -X POST
  -f title="<issue_title>" -f body=… -f "assignees[]=<author>"` with the
  findings in full, a `#<n>` reference, and the trailing `:issue` marker line (a
  failed assignment is logged, the issue stands). Then rerun `post …
  --closed-issue <id>` → **`closed_filed`**: the review is appended to
  `reviews/pr-<n>.md` with `_Delivered as issue #<id> — PR closed before
  posting._`, the lock becomes a `done` row, and the status names the issue.
  Log `PR #<n>: closed mid-review — <k> <scope> finding(s) filed as issue
  #<id>`.

**Crash recovery.** A closed PR whose row is an `in_progress` lock with verdict
`RAPID` arrives as a review entry flagged `closed: true`, not as a prune.
`prepare` runs it in mode `closed` — lock refreshed with verdict `RAPID`, no
clone, no skills (the branch may be gone), Check 1 gates not applied — then
review the diff and `post`.

## Self-check

- **Urgent entries** — rapid review posted or dedup-skipped **before** the full
  one, `APPROVE` exactly when it has no 🔴; `RAPID` row and `rapid posted` step
  recorded; a full verdict below `APPROVE` revoked the rapid approval; terminal
  only on the full review, the closed-PR issue, or an abort. **Closed
  entries** — no review posted, the `scope` findings in one deduped issue
  assigned to the author.
