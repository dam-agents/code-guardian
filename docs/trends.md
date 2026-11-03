# Weekly trends — the accumulated metrics artifact

Read this file on the audit's trend step, or when the operator asks about the
trend artifact.

Every audit appends one week of measured facts; the report renders the whole
history — the latest week against the previous one and the 4-week average,
charts, one row per week. No API call beyond the publish.

## Layout (`work/audit/`)

```
last-worklist.json           # preflight's audit worklist, overwritten every audit
weeks/<ts>.json              # one measured week (append-only)
weeks/<week>-backfill.json   # one reconstructed week (append-only)
TRENDS.md                    # derived index table + the publish-id markers
report.html                  # the accumulated report, regenerated every audit
```

`weeks/*.json` is the **append-only** record (written once, never edited or
deleted); `TRENDS.md` and `report.html` are views regenerated on every append.
One row per ISO week (`2026-W37`); an `audit` row supersedes a `backfill` row
of the same week in both views, both files staying on disk.

## Procedure (audit task 36)

1. **Extras** — write the values only the session knows to a temp file:
   `{"ttfr_median_min": <task 22 median>, "model": "<production model id>",
   "actual_cost_usd": <task 27 totalCostUsd>, "memory_lines": <task 34
   total>}`. `model` is task 27's busiest `byModel` entry, else this
   session's own id. Omit a key you did not measure; never a placeholder.
2. **Append** — `bash "$HOME/scripts/audit-trend.sh" append "$HOME/work/audit" <extras file>`.
   It reads `last-worklist.json`, writes the week file, regenerates `TRENDS.md`
   and prints the week-over-week delta line plus the resolved surface.
3. **Report** —
   `bash "$HOME/scripts/audit-trend.sh" report "$HOME/work/audit" > "$HOME/work/audit/report.html"`.
4. **Publish** per `audit_trend` ([config.md](config.md)), updated in place so
   the URL stays stable:
   - `dam` — the DAM Artifact Library, title `<bot_display_name> weekly
     trends`, the upload and publish of [artifact.md](artifact.md) →
     **Steps** 3–4; the id lives in the TRENDS.md marker
     `<!-- audit-trend-dam: <id> -->`. Best-effort: tools absent or any
     sub-step failing → log and continue.
   - `off` — publish nothing.
5. **Report it** — the delta line and the URL go on the audit report's
   *Trend* line ([audit.md](audit.md)).

Then delete the temp extras file. Nothing outside `work/audit/` is written.

## Metrics

| Group | Metrics | Source |
| --- | --- | --- |
| Volume | reviews (first / re-review), open PRs, `awaiting_label` backlog, review guides published | `stats.reviews`, `stats.open_prs`, `stats.awaiting_label`, `stats.guides` |
| Quality | verdict split, APPROVE and REQUEST_CHANGES shares (all and first reviews), APPROVE overruled by a person, findings raised by severity, findings per review and per 100 changed lines, missed-earlier share, acceptance ratio, 👍/👎 | `stats.reviews`, `stats.overruled`, `stats.findings`, `stats.reactions` |
| Speed | time-to-first-review, review duration, slowest phase | extras, `stats.reviews.duration` / `.phases` |
| Cost | heartbeats and idle share, wake-ups by work (reviews / mention replies), tokens, estimated spend per week and per review, actual spend | `stats.heartbeats`, `stats.wakeups`, `stats.tokens`, the price table, extras |
| Runs | finished sessions, run length (median, mean, p90; review runs apart), cost per run (median, mean), cache hit ratio — per week and per day | `stats.sessions` (below) |
| Stability | stalled runs of locked runs, wasted output tokens, error and warn events, check counts, the fullest volume (space, inodes), the size of `work/` | `stats.stalls`, `stats.log_events`, `checks[]`, `stats.disk` |
| Project | review coverage of merged PRs, median PR size, time to first **human** review, PRs that hit a merge conflict, review rounds per merged PR, PRs abandoned after review, the three areas carrying the most open findings | `stats.project` ([audit.md](audit.md) → task 33) |

An unmeasured metric (including weeks recorded before it existed) renders
`—`; zero only where zero was measured. Volume, quality and project come from
the review ledger ([review-mechanics.md](review-mechanics.md) → **Review
ledger**), the project group also from `work/PR-EVENTS.jsonl` and one list
call of merged PRs.

## Runs

`stats.sessions` keeps one record per finished session of the week — `{day,
job, min, model, input, output, cache_read, cache_creation, reviews}`, from the
session's `tokens` event and its own events ([logging.md](logging.md)). `job`
is the run's most common `job` other than `session`, else `session`; `min`
is the transcript's wall time (`secs=`), else the span of the run's events;
`reviews` counts the PRs it posted. Records stay raw: run figures and the
per-day table derive at render time and reprice with the table. A crashed
session has no `tokens` event and no record; an unreadable `tokens` event
leaves its session out with a `sessions_unparsed` warn naming the run. Without
a `tokens` adapter `stats.sessions` is null and run figures render `—`
([logging.md](logging.md) → **Harness adapters**).

The audit's `verdict_shift`, `findings_shift` and `late_shift` baselines are
the four recorded weeks before ([audit.md](audit.md) → tasks 24, 28); a
derived row keeps the counts behind each share, so baselines pool counts,
never averages of shares.

## Cost

Spend is a **token estimate**, priced at render time by the
`## Benchmark model prices` table ([benchmark.md](benchmark.md) → **Model
prices**) through `scripts/lib/prices.sh`.

Tokens are priced per recorded model (`stats.tokens.by_model`, from the
`tokens` event). Tokens under an unpriced model are **excluded** and the cell
is marked `≥` — a floor, never a guess; `unknown` (events from before the
model was recorded) is priced with the extras' model. `actual_cost_usd`
([audit.md](audit.md) → task 27) renders beside the estimate, `—` where
telemetry is absent or no longer retained.

## Backfill (one-time, operator ask)

`bash "$HOME/scripts/audit-trend.sh" backfill "$HOME/work/audit"
"$HOME/work/reviews"` reconstructs the weeks the review record covers (review
and verdict counts, raised findings by severity, acceptance bullets) from the
ledger and history files via `scripts/lib/review-records.sh`; event-log
metrics stay absent. A week on record is never overwritten, so it is safe to
repeat.

## Reading it

`bash "$HOME/scripts/audit-trend.sh" index "$HOME/work/audit"` prints every
week's derived row as JSON — for an operator question about one metric.
