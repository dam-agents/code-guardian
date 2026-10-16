# Monitor — the agent's health alerts

Read on every **monitor run** (the `code-guardian-monitor-15m` schedule,
ONBOARDING Step 6f). The review heartbeat decides review work only; every
health alert is the monitor's. `scripts/precheck.sh monitor` runs
`scripts/monitor.sh` once per fire: local files only — the events log, the
review usage baseline, the review ledger, the harness settings — no GitHub
call, no write beyond its own bookkeeping and the technical history
([health.md](health.md)). Its only outward calls are the opt-in **Direct
delivery** below and the opt-in dashboard publish ([health.md](health.md) →
**Publish**). An idle fire starts no session.

## The alerts

| Kind | Condition | Clears when |
| --- | --- | --- |
| `model_unavailable` | `model_alert_threshold` (missing = `2`; `0`/`off` disables) runs ended on an availability-class `api_failure` in one outage — failures less than 60 min apart; `open` while the last is under 60 min old | — (one alert per outage) |
| `model_recovered` | the outage is over (60 min without a failure) and its `model_unavailable` went out while it was still open | — (once per outage) |
| `github_unavailable` | `github_alert_threshold` (missing = `2`; `0`/`off` disables) gate passes in a row that could not list the open PRs (preflight's `could not list open PRs` error); `open` until a review or shepherd pass lists them again | — (one alert per outage) |
| `github_recovered` | that pass came, and the outage's `github_unavailable` went out while it was still open | — (once per outage) |
| `classifier_spike` | `classifier_alert_threshold` (missing = `20`; `0`/`off` disables both classifier alerts) `classifier_block` events in 24 h | — (once per UTC day) |
| `review_post_blocked` | the classifier refused a `review-pr.sh post` in the last 24 h, and no later `posted` step of that PR exists | — (once per run and PR) |
| `harness_drift` | an adapter's `install.sh --check` names a part that is not current (Claude Code: `hooks`, `automode-rules`, `tool-deny`, `skill-agent`; pi: `pi-extension`) | the checks print nothing |
| `heartbeat_gap` | no review-gate `precheck` or `heartbeat` event for 1.5 × `review_interval_quiet` (at least 60 min) | the gate ticks again |
| `backup_failing` | under a `work_repo`, a `work_backup` error no later push cleared for 6 h | the next push |
| `dispatch_refused` | `dispatch_refused` events ([runbook.md](runbook.md) → **Review run** step 1) since the last accepted dispatch: the first 60 min old, the newest under 24 h old | the next accepted dispatch, or 24 h without a refusal |
| `github_write_denied` | a script's warn or error line in 24 h that quotes a GitHub `HTTP 403` — a rate limit, the gate's list failure and the harness hooks' events aside | — (once per UTC day) |
| `github_identity_changed` | `work/GITHUB.json` → `changed_at` in the last 7 days ([github-access.md](github-access.md) → **Identity**) | — (once per change) |
| `stall_alert` | **Stalled-review rate alert** below | — (once per UTC day) |
| `review_anomaly` | **Review anomaly alert** below | — (once per review) |

The availability classes are every `api_failure` class except
`invalid_request` and `max_output_tokens`, which an agent request causes. The
events come from the harness hooks `StopFailure` (`api_failure`) and
`PermissionDenied` (`classifier_block`) ([harness-claude-code.md](harness-claude-code.md) → **Adapter**). A GitHub failure's class comes from the error text: `auth`
(HTTP 401), `rate_limit`, `access` (HTTP 403/404), `server_error` (HTTP 5xx),
`network`, `unknown`. The weekly audit counts the week's refusals and model
outages ([audit.md](audit.md) task 38).

**The ledger** — `work/MONITOR.json`, `{alerts: {<id>: {kind, first, claimed,
sent}}}`, one writer at a time. An `alerts_due` entry is claimed when emitted
and is due again 30 min later until `monitor.sh ack <id>…` records it as
sent. A sent alert is never emitted again: each tick counts it in
`suppressed` and logs `suppressed <n> alert(s) already reported`. A condition
kind that clears leaves the ledger, so its return alerts again. A row stays
while a tick still finds its alert, else 14 days after its claim or send;
`alerts_due` holds one entry per id. `stall_alert` and `review_anomaly` keep
their own detection-time claims (below), not the ledger.

## Monitor run

1. Read the worklist. Each `alerts_due` entry carries its `id`, its `kind` and
   the facts of its row above; `stall_alert` and `review_anomaly` are
   worklist keys of their own. Under **Direct delivery** `alerts_due` holds
   only what the pass did not send, and `direct` says why.
2. Send **one message** for the whole run, in the chat UI: one line per
   alert — what happened, when (UTC), the numbers, the likely cause and the
   one operator action, if any:
   - `model_unavailable` / `model_recovered` — first and last failure, runs
     lost, the classes (`server_error`, `overloaded` → the provider or the
     gateway; `authentication_failed`, `cloud_credential_error` →
     credentials, operator-only; `rate_limit`, `billing_error` → quota or
     budget). Missed review work recovers on the next heartbeat by itself.
   - `classifier_spike` / `review_post_blocked` — the top patterns and the
     reasons; a documented step of the agent is an `autoMode.allow` rule
     missing from the definition
     ([harness-claude-code.md](harness-claude-code.md) → **Adapter**), anything else is a refusal that stands.
   - `github_unavailable` / `github_recovered` — first and last failed pass,
     the classes (`auth`, `access` → the token, operator-only; `rate_limit` →
     quota; `server_error`, `network` → GitHub or the network). Missed review
     work recovers on the next heartbeat by itself.
   - `harness_drift` — `bash "$HOME/scripts/harness/claude-code/install.sh"`
     (`pi-extension`: `scripts/harness/pi/install.sh`) is the fix; it takes
     effect from the next session.
   - `heartbeat_gap` — the review schedule is disabled, deleted or its gate
     cannot start (`list_schedules`; [worklist.md](worklist.md) → **The
     schedule gate**).
   - `backup_failing` — the sample error; [persistence.md](persistence.md).
   - `dispatch_refused` — the platform's reason from the `dispatch_refused`
     events; a platform setting is the operator's to correct, a cap clears
     by itself.
   - `github_write_denied` / `github_identity_changed` — the events and the
     login; the operator runs `scripts/github-access.sh` in the direct
     session and gives the token the missing permission
     ([github-access.md](github-access.md)).
   - `stall_alert` / `review_anomaly` — per their sections below.
3. Under `slack_notifications: enabled` **and** an `escalation_owner`, also DM
   that person the same message — never the shared channel; roster-only
   mentions still apply.
4. **After the send**, `bash "$HOME/scripts/monitor.sh" ack <every id of
   alerts_due>`, and log `stall_alert_sent <count>` / `review_anomaly_sent
   <n>` for those. A failed send is logged and not acknowledged: the next tick
   after the claim retries it.
5. Back up `work/` (`scripts/work-backup.sh persist`).

The monitor is a signal, not a repair: never clear locks, re-review, change a
threshold, edit settings or re-run a refused action in response.

## Direct delivery (`monitor_slack_direct: enabled`)

The monitor's pass sends the due alerts itself, with no model in the loop
(`scripts/monitor-direct.sh`), so a model outage or a classifier refusal
cannot stop them.

- **Gate** — `monitor_slack_direct: enabled`, `slack_notifications: enabled`
  and an `escalation_owner` with a roster `slack_id`. Otherwise the session
  delivers, per **Monitor run**.
- **Message** — one Slack DM to the escalation owner
  (`send_channel_message`, `chatId` = the roster id), never the shared
  channel: a header, one bullet per alert from a fixed template, at most 10
  alerts, and the dashboard share URL when one is kept
  ([health.md](health.md)). `stall_alert` and `review_anomaly` need an
  analysis and stay with the session.
- **Type checks** — every value is a UTC time, a whole number, a class word,
  an adapter part or a PR number; an alert with any other value is skipped and
  stays due for the session. The text of an event — error details, commands,
  reasons — is never in the message. The finished text holds no `<`, `>`, `@`,
  link or code fence except the share URL, or it is not sent.
- **Cap** — 12 direct calls per 24 h, each attempt counted
  (`work/MONITOR.json` → `direct`); past it the session delivers.
- **After the send** — the pass acknowledges the sent ids, removes them from
  `alerts_due` and logs `monitor_direct` (info); a tick with nothing left
  starts no session. A failed send logs `monitor_direct` (error), acknowledges
  nothing and leaves the alerts to the session; an alert nobody acknowledged
  is due again 30 min later, and that pass tries the send again. A call that
  went out with no answer (`unknown`) may have arrived: its alerts leave this
  worklist unacknowledged, so no second message follows in the same tick, and
  the pass after their claim sends them again.
- **Preview** — `bash "$HOME/scripts/monitor-direct.sh" render <file>` prints
  the message for a JSON array of `alerts_due` entries;
  `monitor-direct.sh ready` prints why a send cannot happen, or nothing.

## Stalled-review rate alert (`stall_alert`)

The monitor counts the stalled reviews of the last 24 h — one per dead lock
(PR, lock time), however many `stale in_progress lock` takeover lines it left;
`per_day_7d` counts each stall on the UTC day of its first line. At or above
`stall_alert_threshold` (missing = `4`; `0`/`off` disables) it emits
`stall_alert: {count, threshold, prs, window_hours, per_day_7d}` — **once per
UTC day** (`work/.stall-alert-day`, claimed under a `mkdir` lock at
detection). Report count, threshold, the PR numbers and the `per_day_7d`
trend; investigate per [logging.md](logging.md) and record a recurring cause
as an operational lesson ([preferences.md](preferences.md)).

## Review anomaly alert (`review_anomaly`)

The harness adapter logs one `review_cost` event per finished review: the API
usage between its `locked` and `done` steps, subagents included, and the shape
of that window — `peak_ctx`, `repeats`, `max_out`, `failures`
([harness-claude-code.md](harness-claude-code.md) → **Adapter**). The monitor judges every
event of the last 24 h newer than `work/.review-anomaly-seen` once, under a
`mkdir` claim. Each rule's limit is **max(floor, factor × median)**. A review
at or over any limit is an entry:

| Rule | Field | Floor |
| --- | --- | --- |
| `cost` | tokens priced by `## Benchmark model prices` ([benchmark.md](benchmark.md) → **Model prices**), `unit: usd`; without a row weighted 1 / 5 / 0.1 / 1.25 (input / output / cache read / cache write), `unit: weighted_tokens` | none |
| `time` | `secs` | none |
| `context` | `peak_ctx` — the largest single API call's context | none |
| `repeats` | the most repeated identical tool call | 8 |
| `failures` | `tool_failure` events in the window | 5 |
| `output` | `max_out` — the largest tool result, in characters; a result the harness saved to a file counts at its stated full size | 200 000 |

- **Factor** — `review_anomaly_factor` (missing = `4`; `0`/`off` disables the
  whole alert).
- **Median** — the same model's last 30 reviews before this one. It counts
  from 10 reviews on; before that a new repo is judged on the floors alone,
  and `cost`, `time` and `context` wait.
- **Baseline** — `work/REVIEW-USAGE.jsonl` keeps the last 30 judged reviews
  per model, beyond the 14-day event retention. First contact seeds it from
  every retained event.
- **Entry** — `review_anomaly: {factor, reviews: [{pr, sha, ts, model,
  reasons: [{rule, value, limit, median, ratio}], unit, cost, samples, secs,
  msgs, subagents, input, output, cache_read, cache_creation, peak_ctx,
  repeats, repeat_tool, max_out, failures, kind, size}]}`; `median` and
  `ratio` are `null` while the floor alone sets the limit; `kind` and `size`
  come from the review ledger, `null` when it has no row.

Report per review the PR, each broken rule with its value, limit and median,
and the likely cause — `repeats` or many `msgs` on a small diff is a loop,
`context` or high `cache_read` per message is a large context or memory,
`output` is a huge file or API dump, `failures` is a broken tool, many
`subagents` is fan-out, a large `size` or a `first` review of a large PR is a
legitimate cost. A chronic problem enters the median and stops alerting: the
weekly audit's review-shape line shows that drift ([audit.md](audit.md)
task 37).

## Self-check

- Every `alerts_due` entry is in the one message, and acknowledged after the
  send — never before, never on a failed send. A directly sent alert is not
  in the worklist and gets no second message.
- `stall_alert` / `review_anomaly` reported with their facts and their
  `_sent` line logged.
- Nothing repaired, re-run or reconfigured in response.
