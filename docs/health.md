# Health — the technical history and the dashboard

Read this file when the operator asks why the agent did not run, about a past
outage or about the health dashboard, or before a change to what the monitor
records.

The monitor's pass (`scripts/monitor.sh`, [monitor.md](monitor.md)) drives
`scripts/health.sh` on every tick. It keeps the technical facts that the
14-day events log loses, and it shows them on one page. No model call.

## Records (`work/health/`)

```
hours.jsonl       # one row of counts per UTC hour, 90 days
incidents.jsonl   # one row per monitor condition, 90 days
status.json       # the state of each service at the last tick
state.json        # the published dashboard: artifact_id, share_url, published_at, status_sig
schedules.json    # the last list_schedules answer, trimmed
dashboard.html    # the last published page
```

- **Hour row** — each tick recomputes the hours of the daily events files from
  the newest row's day on and replaces the rows of those days; the first tick
  backfills every retained file. A row stays when its events file is gone, and
  a record is never rewritten from a failed computation.

  | Field | Counts, per UTC hour |
  | --- | --- |
  | `gate` | `precheck` events per job — the schedule fires that reached their gate |
  | `gate_err` | `precheck` errors — a gate that broke |
  | `sessions` / `reviews` | `tokens` events / `review_step … done` |
  | `model_fail` | `api_failure` of the availability classes ([monitor.md](monitor.md) → **The alerts**) |
  | `gh_fail` / `gh_warn` | gate passes that could not list the open PRs / `gh_api` and preflight API-error warnings |
  | `classifier` / `tool_fail` | `classifier_block` / `tool_failure` |
  | `errors` / `warns` / `top_errors` | every error and warn line; the five most frequent error events |
  | `pod_boots` / `backup_err` | `pod_boot` / `work_backup` errors |
  | `direct_sent` / `direct_fail` | `monitor_direct` info / error ([monitor.md](monitor.md) → **Direct delivery**) |

- **Incident** — `{id, kind, first, last_seen, open, end, detail}`, one per
  condition id of the monitor. An outage or a condition is open until it
  clears; a classifier day, a refused post, a stall alert and an anomaly are
  closed points. A recovery notice is no incident.
- Rows hold counts, class words, UTC times, PR numbers and adapter parts only —
  never the text of an event.

## Service status

| Service | `down` | `warn` |
| --- | --- | --- |
| DAM schedules | `heartbeat_gap` | a `pod_boot` or a broken gate in 6 h |
| Harness | — | `harness_drift` |
| Model API | an open `model_unavailable` | a model failure in 2 h |
| GitHub API | an open `github_unavailable` | a failed gate pass or an API warning in 2 h |
| Auto-mode classifier | — | `classifier_spike`, `review_post_blocked` |
| Work backup | `backup_failing` | a push error in 6 h |
| Direct Slack alerts | — | the opt-in cannot send, or a failed send in 6 h |

Otherwise `ok`; `na` for the backup without `work_repo` and for direct alerts
without `monitor_slack_direct: enabled`. `status_sig` joins every state.

## The dashboard

`bash "$HOME/scripts/health.sh" report` prints one self-contained page: the
service tiles, the per-hour charts of 7 days, the incidents, the per-day charts
of 90 days, the top error events of 7 days and the DAM schedules (name,
enabled, last run, a result class and counts — DAM's error text stays out).
The incident table adds `no_gate_tick` — a run of history hours with no gate
tick at all.

**Why did the agent not run at T?** Read the hour rows and incidents of T:

- no gate tick → no schedule fired: the platform or the pod (`pod_boots`,
  `no_gate_tick`, the schedules table);
- `gate_err` → the gate broke (the `precheck` events of that hour);
- `gh_fail` → GitHub; `model_fail` → the model; `classifier` → refusals;
- gate ticks and no session → nothing was due.

## Publish (`health_dashboard: dam`)

- The monitor's pass publishes when `status_sig` changed since the last
  publish, or the last publish is 3 h old — never within 30 min of a failed
  attempt, and never in a tick whose direct send found the endpoint down.
- It calls the platform-outbound MCP tools itself (`scripts/lib/mcp.sh`):
  `list_schedules` for the schedules table (best-effort), then
  `update_artifact {id, content}` on the kept id — a new version under the same
  share URL — or `create_artifact {title: "<bot_display_name> health", type:
  "html", visibility: "public"}` when no id is kept or the update answers
  `not found`. Any other failure creates nothing and keeps the share URL.
- Every request of the pass ends 15 s before the gate's budget; the schedules
  call runs only with 40 s left.
- The page passes `redact_file` before the publish, and its share URL is public
  to anyone holding it (README → **Runtime requirements**).
- Each publish logs a `health` event: `dashboard published → DAM <id>`, or
  `dashboard not published: <reason>` (warn). The share URL ends every direct
  DM.

**Cost** — no token. A tick reads the daily events files since the newest row
(two on a running monitor, about 1 s on the pod); a publish adds up to three
MCP calls, at most once per status change or 3 h.
