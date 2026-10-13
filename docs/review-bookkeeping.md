# Review-run bookkeeping

Read when the worklist's `read_set` names this file: `selfheals_due`,
`label_cleanups_due`, `prunes_due` or `status_resets_due` is non-empty. A
`housekeeping_only` run reads this file alone.

## Label bookkeeping (`selfheals_due`, `label_cleanups_due`)

Both run before the review loop, one log line each. A failed removal is logged,
never fatal — preflight re-emits the entry.

- **Self-heal** `{number, sha, ts, status}` → write the REVIEWS.md row with
  `review-pr.sh row <number> <sha> <ts> SEE-GITHUB <status>`. `ts` is the
  GitHub-reported timestamp; use the remote body's verdict when you have it.
  Log `PR #<n>: self-healed REVIEWS.md from remote marker (<status>)`.
- **Same-SHA trigger cleanup** `{number, label, request, delta_label}` → a
  trigger on a PR whose live HEAD is reviewed and whose description is
  unchanged since. Clear what the entry flags — `label: true` → remove
  `$REREVIEW_LABEL`, `delta_label: true` → remove `$REREVIEW_DELTA_LABEL`,
  `request: true` → remove your pending review request (**Trigger removal**) —
  post nothing, and log `PR #<n>: re-review trigger present but nothing new
  since <short-sha> — cleared (<the cleared triggers, joined by " + ">), no
  re-review`. An edited
  description arrives as a `reviews_due` entry instead
  ([review-rereview.md](review-rereview.md) → **Description-only re-review**).

## Pruning (`prunes_due`)

Preflight verified every entry `{number, state, dam_id}` CLOSED/MERGED. The
candidates are the REVIEWS.md rows and the PRs with step-2 files or a
`work/MENTIONS.md` `body-<n>` row but no REVIEWS.md row.
Execute exactly this list — never from list absence, never a bulk delete of
`reviews/pr-*.md`. An entry without an id → read the
`<!-- artifact-dam: … -->` marker from `work/reviews/pr-<n>.md` before step 2
deletes it.

1. Artifact, a failure logged and never blocking: `dam_id` →
   `delete_artifact {id: <dam_id>}`, skipped silently when the MCP tool is
   absent.
2. `rm -f work/reviews/pr-<n>.md work/reviews/pr-<n>.carry.json
   work/reviews/pr-artifacts/pr-<n>.html` — the PR's ledger rows stay
   ([review-mechanics.md](review-mechanics.md) → **Review ledger**).
3. Delete the PR's REVIEWS.md row (`review-pr.sh row <n> --delete`), and its
   `work/SHEPHERD.md` row and `work/MENTIONS.md` `body-<n>` row when present.
4. Log `PR #<n>: pruned (<state>)`.

## Trigger removal

Use REST — `gh pr edit` goes through GraphQL, which 401s in this pod (the
platform's auth proxy does not rewrite that code path), with the label name
URL-encoded as one path segment:

```bash
gh api -X DELETE "repos/$REPO/issues/<n>/labels/$(jq -rn --arg v "$REREVIEW_LABEL" '$v | @uri')" >/dev/null \
  || gh pr edit <n> --repo "$REPO" --remove-label "$REREVIEW_LABEL"
```

`$REREVIEW_DELTA_LABEL` the same way. `review-pr.sh post` removes both labels
when the review posts.

Pending review request — a served request clears itself when `bot_login` posts
the review. When the token posts as another login (a GitHub App token),
`review-pr.sh post` removes it. The same-SHA cleanup removes it with:

```bash
gh api -X DELETE "repos/$REPO/pulls/<n>/requested_reviewers" -f "reviewers[]=$BOT_LOGIN" >/dev/null
```

## Progress signal on GitHub (`review_progress`)

`review_progress: enabled` (missing = `disabled`) publishes progress on the
reviewed SHA under the name `$REVIEW_MARKER`: a **check run** for a GitHub App
token, a **commit status** for a user token, the other one when the first is
refused ([github-access.md](github-access.md) → **Progress signal channel**).
`pending` is a check run `in_progress` and `success` a completed one. One write
per update, always through the script:

```bash
bash "$HOME/scripts/review-pr.sh" progress <n> <sha> <state> "<line>" [<url>]
```

`<url>` is the row's `target_url`. `description` is one short line — GitHub
truncates past 140 characters. A check run also keeps every line as a timeline
in its summary and tells people how to request the next round
([github-access.md](github-access.md) → **Progress signal channel**). The CI rollup never counts this signal as a
check of the commit ([ci-triage.md](ci-triage.md)).

| Written at | `state` | `description` | `target_url` |
| --- | --- | --- | --- |
| `prepare` — lock written | `pending` | `queued <HH:MM>Z · fetching diff and clone<eta>` | — |
| `prepare` — clone finished | `pending` | `reviewing since <HH:MM>Z · diff + <k> skill(s)<eta>` | — |
| Urgent phase 1 — rapid posted | `pending` | `rapid review: approved · full review running` (or `changes requested`) | the rapid review |
| `post` — review posted | `success` | `<VERDICT> · <a> critical, <b> warning, <c> suggestion · took <m>m` | the posted review |
| `post` / `abort` — posting aborted | `success` | `no review posted — <reason>; retrying next heartbeat` | — |
| PR closed mid-review | `success` | `PR closed · <n> <scope> finding(s) in issue #<i>` | the issue |
| `status_resets_due` entry | `success` | `review abandoned — resumes when the PR is ready` | — |

- `<eta>` is ` · usually ~<N> min` from `eta_seconds` — whole minutes, minimum
  1, omitted when the field is `null`.
- **`description` is ASCII**: severity words, no emoji — the statuses API
  rejects 4-byte UTF-8.
- Write on the SHA the review locked at Check 1.
- Every terminal outcome is `success`, aborts included, so the status never
  gates a merge.
- `review-pr.sh` writes each row at the step that owns it; the manual fallback
  runs `review-pr.sh progress` at the same step.
- **Best-effort.** A failed write is logged (`progress_status`, warn) and
  changes nothing — never retried, never a reason to abort.

**`status_resets_due`** `{number, sha, reason}` — a locked review was abandoned
with the status left `pending` (`reason: draft`). Write the terminal row above,
then **delete the PR's REVIEWS.md row** (`review-pr.sh row <n> --delete`); the
`reviews/pr-<n>.md` history stays.

## Self-check

- **Bookkeeping** — every `selfheals_due` / `label_cleanups_due` /
  `prunes_due` / `status_resets_due` entry executed and logged; every status
  reset on its terminal `success` row, its REVIEWS.md row deleted.
