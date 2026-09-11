# Weekly trends — the accumulated metrics artifact

Read this file on the audit's trend step, or when the operator asks about the
trend artifact.

The weekly audit already measures the agent; this artifact **keeps** those
numbers. Every audit appends one week of measured facts, and the report renders
the whole history — a summary of the latest week against the previous one and
against the 4-week average, inline charts, and one table row per week — so a
regression or an improvement is visible in time. It costs two script calls per
audit: no model calls, and no API call beyond the publish.

## Layout (`work/audit/`)

```
last-worklist.json           # preflight's audit worklist, overwritten every audit
weeks/<ts>.json              # one measured week (append-only)
weeks/<week>-backfill.json   # one reconstructed week (append-only)
TRENDS.md                    # derived index table + the publish-id markers
report.html                  # the accumulated report, regenerated every audit
```

`weeks/*.json` is the record and is **append-only**: a file is written once and
never edited or deleted. `TRENDS.md` and `report.html` are **derived views**,
regenerated from those files on every append, so a new column or an updated
price table reaches every past week.

One row per ISO week (`2026-W37`). An `audit` row supersedes a `backfill` row
of the same week in both views; both files stay on disk.

## Procedure (audit task 32)

1. **Extras** — write the values only the session knows to a temp file:
   `{"ttfr_median_min": <task 22 median>, "model": "<exact session model id>",
   "memory_lines": <task 30 total>}`. Omit a key you did not measure; never
   write a placeholder number.
2. **Append** — `bash "$HOME/scripts/audit-trend.sh" append "$HOME/work/audit" <extras file>`.
   It reads `last-worklist.json`, writes the week file, regenerates `TRENDS.md`
   and prints the week-over-week delta line plus the resolved surfaces.
3. **Report** —
   `bash "$HOME/scripts/audit-trend.sh" report "$HOME/work/audit" > "$HOME/work/audit/report.html"`.
4. **Publish** to the surfaces of `audit_trend` ([config.md](config.md)), each
   independently, updated in place so the URL stays stable:
   - `dam` — the DAM Artifact Library through its MCP tools, title
     `<bot_display_name> weekly trends`, exactly the sub-steps of
     [artifact.md](artifact.md) → **Procedure** 2b; the id lives in the
     TRENDS.md marker `<!-- audit-trend-dam: <id> -->`. Best-effort: tools not
     registered or any sub-step failing → log and continue.
   - `gist` — the persistent secret gist of
     [benchmark.md](benchmark.md) → **Running the benchmark** phase 2 step 9,
     with the marker `<!-- audit-trend-gist: <id> -->` and the file name
     `report.html`.
   - `off` — regenerate locally and publish nothing.
5. **Report it** — the delta line and the artifact URL go on the audit report's
   *Trend* line ([audit.md](audit.md)). A failed publish is logged; the local
   `report.html` is current regardless.

Then delete the temp extras file. The append is the trend artifact's only
write, and it never touches state outside `work/audit/`.

## Metrics

| Group | Metrics | Source |
| --- | --- | --- |
| Volume | reviews (first / re-review), open PRs, `awaiting_label` backlog | `stats.reviews`, `stats.open_prs`, `stats.awaiting_label` |
| Quality | verdict split, findings raised by severity, findings per review, acceptance ratio, 👍/👎 | `stats.findings`, `stats.reactions` |
| Speed | time-to-first-review, review duration, slowest phase | extras, `stats.reviews.duration` / `.phases` |
| Cost | heartbeats and idle share, tokens, spend per week, spend per review | `stats.heartbeats`, `stats.tokens`, the price table |
| Stability | stalled runs of locked runs, wasted output tokens, error and warn events, check counts | `stats.stalls`, `stats.log_events`, `checks[]` |

A metric the week did not measure renders `—`. Zero is written only where zero
was measured. Volume and quality are counted from the review ledger
([review.md](review.md) → **Review ledger**).

## Cost

Spend is a **token estimate**, priced by the operator-maintained
`## Benchmark model prices` table — the one table both reports read
([benchmark.md](benchmark.md) → **Model prices**), through
`scripts/lib/prices.sh`. Pricing happens at render time, so the whole history
reprices when the table changes and a cost delta reflects usage, not a price
move.

Tokens are priced per recorded model: the `tokens` event carries the model that
produced the session's messages, and `stats.tokens.by_model` splits the week by
it. Tokens under a model the table does not price are **excluded** and the cell
is marked `≥` — a floor, never a guess. Events written before the model was
recorded arrive as `unknown` and are priced with the extras' session model.

## Backfill (one-time, operator ask)

`bash "$HOME/scripts/audit-trend.sh" backfill "$HOME/work/audit" "$HOME/work/reviews"`
reconstructs the weeks the review record covers: review and verdict counts,
raised findings by severity, and the acceptance bullets. It reads the ledger
and the history files through `scripts/lib/review-records.sh`, which parses
each `findings-json` as the one line [review.md](review.md) → **Summary body
format** writes, so that shape and this parser change together. Everything
measured from the event log (time, tokens, cost, heartbeats, stalls) has a
14-day retention and stays absent. A week already on record is never
overwritten, so the command is safe to repeat.

## Reading it

`bash "$HOME/scripts/audit-trend.sh" index "$HOME/work/audit"` prints every
week's derived row as JSON — the same numbers the report shows, for an operator
question about one metric without opening the artifact.
