# Review-run bookkeeping

Read when the worklist's `read_set` names this file: `selfheals_due`,
`label_cleanups_due`, `prunes_due` or `status_resets_due` is non-empty, or a
`stall_alert` or `review_anomaly` is present. A `housekeeping_only` run reads this
file alone.

## Label bookkeeping (`selfheals_due`, `label_cleanups_due`)

Both run before the review loop, one log line each. A failed removal is logged,
never fatal — preflight re-emits the entry.

- **Self-heal** `{number, sha, ts, status}` → write the REVIEWS.md row
  `| <number> | <sha> | <ts> | SEE-GITHUB | <status> |`. `ts` is the
  GitHub-reported timestamp; use the remote body's verdict when you have it.
  Log `PR #<n>: self-healed REVIEWS.md from remote marker (<status>)`.
- **Same-SHA trigger cleanup** `{number, label, request}` → a trigger on a PR
  whose live HEAD is reviewed and whose description is unchanged since. Clear
  what the entry flags — `label: true` → remove the label, `request: true` →
  remove your pending review request (**Trigger removal**) — post nothing, and
  log `PR #<n>: re-review trigger present but nothing new since <short-sha> —
  cleared (<label / request / label + request>), no re-review`. An edited
  description arrives as a `reviews_due` entry instead
  ([review-rereview.md](review-rereview.md) → **Description-only re-review**).

## Pruning (`prunes_due`)

Preflight verified every entry `{number, state, dam_id}` CLOSED/MERGED. The
candidates are the REVIEWS.md rows and the PRs with step-2 files but no row.
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
3. Delete the PR's REVIEWS.md row when present, and its `work/SHEPHERD.md` row
   when present.
4. Log `PR #<n>: pruned (<state>)`.

## Trigger removal

Use REST — `gh pr edit` goes through GraphQL, which 401s in this pod (the
platform's auth proxy does not rewrite that code path), with the label name
URL-encoded as one path segment:

```bash
gh api -X DELETE "repos/$REPO/issues/<n>/labels/$(jq -rn --arg v "$REREVIEW_LABEL" '$v | @uri')" >/dev/null \
  || gh pr edit <n> --repo "$REPO" --remove-label "$REREVIEW_LABEL"
```

Pending review request — same-SHA cleanup only; a served request clears itself
when the review posts:

```bash
gh api -X DELETE "repos/$REPO/pulls/<n>/requested_reviewers" -f "reviewers[]=$BOT_LOGIN" >/dev/null
```

## Progress signal on GitHub (`review_progress`)

`review_progress: enabled` (missing = `disabled`) publishes progress as a
**commit status** on the reviewed SHA. One call per update, `context` =
`$REVIEW_MARKER`:

```bash
gh api -X POST "repos/$REPO/statuses/<sha>" -f state=<state> \
  -f context="$REVIEW_MARKER" -f description="<line>" >/dev/null
```

Add `-f target_url=<url>` on the rows that have one. `description` is one short
line — GitHub truncates past 140 characters.

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
- **`description` is ASCII.** The statuses API rejects 4-byte UTF-8
  (`Description doesn't accept 4-byte Unicode`), so severity words replace the
  emoji here; the review body keeps them.
- Write on the SHA the review locked at Check 1.
- Every terminal outcome is `success`, aborts included: `failure`/`error` would
  make the agent a merge gate the moment someone made the context a required
  check.
- `review-pr.sh` writes each row at the step that owns it; the manual fallback
  issues the same call at the same step.
- **Best-effort.** A failed write is logged (`progress_status`, warn) and
  changes nothing — never retried, never a reason to abort.

**`status_resets_due`** `{number, sha, reason}` — a locked review was abandoned
with the status left `pending` (`reason: draft`). Write the terminal row above,
then **delete the PR's REVIEWS.md row**; the `reviews/pr-<n>.md` history stays.
The missing row is what stops the reset repeating.

## Stalled-review rate alert (`stall_alert`)

Preflight counts the stalled reviews of the last 24 h — one per dead lock (PR,
lock time), however many `stale in_progress lock` takeover lines it left;
`per_day_7d` counts each stall on the UTC day of its first line. At or
above `stall_alert_threshold` (missing = `4`; `0`/`off` disables) it emits
`stall_alert: {count, threshold, prs, window_hours, per_day_7d}` — **once per
UTC day** (`work/.stall-alert-day`, claimed under a `mkdir` lock, so concurrent
heartbeats cannot double-send). One stall is normal (HEAD moved, pod restart); a
cluster means reviews are redone at full cost. Deliver it **once, after the
run's review work**, so the numbers include this run:

1. Chat UI: count, threshold, affected PR numbers, the `per_day_7d` trend.
2. Under `slack_notifications: enabled` **and** an `escalation_owner`, also DM
   that person — never the shared channel, roster-only mentions still apply.
3. Log `stall_alert_sent <count>`. A failed send is logged, never retried this
   run.

The alert is a signal, not a repair: never bulk-clear locks, re-review, or
change the threshold in response. Investigate per [logging.md](logging.md) →
triage; record a recurring cause as an operational lesson
([preferences.md](preferences.md)).

## Review anomaly alert (`review_anomaly`)

The harness adapter logs one `review_cost` event per finished review: the API
usage between its `locked` and `done` steps, subagents included, and the shape
of that window — `peak_ctx`, `repeats`, `max_out`, `failures`
([logging.md](logging.md) → **Harness adapters**). Preflight judges every
event newer than `work/.review-anomaly-seen` once (first contact: the last
24 h), under a `mkdir` claim. Each rule's limit is **max(floor, factor ×
median)** — the repo sets its own norm, the floor stops a count from alerting
on noise. A review at or over any limit is an entry:

| Rule | Field | Floor |
| --- | --- | --- |
| `cost` | tokens priced by `## Benchmark model prices` ([benchmark.md](benchmark.md) → **Model prices**), `unit: usd`; without a row weighted 1 / 5 / 0.1 / 1.25 (input / output / cache read / cache write), `unit: weighted_tokens` | none |
| `time` | `secs` | none |
| `context` | `peak_ctx` — the largest single API call's context | none |
| `repeats` | the most repeated identical tool call | 8 |
| `failures` | `tool_failure` events in the window | 5 |
| `output` | `max_out` — the largest tool result, in characters | 200 000 |

- **Factor** — `review_anomaly_factor` (missing = `4`; `0`/`off` disables the
  whole alert).
- **Median** — the same model's last 30 reviews before this one. It counts
  from 10 reviews on; before that a new repo is judged on the floors alone,
  and `cost`, `time` and `context` wait.
- **Baseline** — `work/REVIEW-USAGE.jsonl` keeps the last 30 judged reviews
  per model, so the median outlives the 14-day event retention and a quiet
  repo still reaches 10. First contact seeds it from every retained event.
- **Entry** — `review_anomaly: {factor, reviews: [{pr, sha, ts, model,
  reasons: [{rule, value, limit, median, ratio}], unit, cost, samples, secs,
  msgs, subagents, input, output, cache_read, cache_creation, peak_ctx,
  repeats, repeat_tool, max_out, failures, kind, size}]}`; `median` and
  `ratio` are `null` while the floor alone sets the limit; `kind` and `size`
  come from the review ledger, `null` when it has no row.

A chronic problem enters the median and stops alerting: the weekly audit's
review-shape line shows that drift ([audit.md](audit.md) task 37).

Deliver it **once, after the run's review work**, like the stall alert:

1. Chat UI: per review the PR, each broken rule with its value, limit and
   median, and the likely cause — `repeats` or many `msgs` on a small diff is a
   loop, `context` or high `cache_read` per message is a large context or
   memory, `output` is a huge file or API dump read whole, `failures` is a
   broken tool, many `subagents` is fan-out, a large `size` or a `first`
   review of a large PR is a legitimate cost.
2. Under `slack_notifications: enabled` **and** an `escalation_owner`, also DM
   that person the same lines — never the shared channel.
3. Log `review_anomaly_sent <n>`. A failed send is logged, never retried this
   run.

The alert is a signal, not a repair: never change the factor, memory or skills
in response. Investigate the run's events and transcript per
[logging.md](logging.md); record a verified cause as an operational lesson
([preferences.md](preferences.md)).

## Self-check

- **Bookkeeping** — every `selfheals_due` / `label_cleanups_due` /
  `prunes_due` / `status_resets_due` entry executed and logged; every status
  reset on its terminal `success` row, its REVIEWS.md row deleted.
- **`review_anomaly`** — every review reported with its rules, DM'd under
  Slack, `review_anomaly_sent` logged, nothing changed in response.
- **`stall_alert`** — reported, DM'd under Slack, `stall_alert_sent` logged, no
  state "repaired".
