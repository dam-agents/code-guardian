#!/usr/bin/env bash
# review-records.sh — one record per posted review, read from the two places
# that hold them (docs/review.md → **Review ledger**).
#
#   review_records <reviews dir> <ledger file> [<since ISO>]   # JSONL on stdout
#
# Record: {src, pr, ts, sha, kind, verdict, bullets:{fixed,still},
#          findings:[{status,severity}] | null}
#
# `work/REVIEW-LEDGER.jsonl` is append-only and outlives the reviewed PR; the
# `reviews/pr-<n>.md` history files carry the same sections but only while the
# PR is open, because pruning deletes them. Both are read and deduped on
# (pr, ts) — the ledger row wins — so a review appended before the ledger
# existed counts once, and a merged PR's reviews keep counting after its file
# is gone. Every reader of these numbers comes through here; none parses
# `## Review at` on its own.
#
# Sourced by preflight.sh (audit stats) and audit-trend.sh (backfill). Needs jq.

# one object per `## Review at` section of one history file; $pr is its number
RR_HISTORY_JQ='
split("\n")
| reduce .[] as $l ({ secs: [], cur: null };
    if ($l | startswith("## Review at ")) then
      .secs = (if .cur then .secs + [.cur] else .secs end)
      | .cur = { src: "history", pr: $pr,
                 ts: ((($l | capture("(?<t>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)").t)?) // null),
                 sha: ((($l | capture("^## Review at (?<s>[0-9a-f]{7,40})").s)?) // null),
                 kind: null,
                 verdict: (if ($l | test("REQUEST_CHANGES")) then "REQUEST_CHANGES"
                           elif ($l | test("APPROVE")) then "APPROVE"
                           elif ($l | test("COMMENT")) then "COMMENT"
                           else null end),
                 bullets: { fixed: 0, still: 0 }, findings: null }
    elif .cur == null then .
    elif ($l | startswith("- ✅ **Fixed:**")) then .cur.bullets.fixed += 1
    elif ($l | startswith("- 🔁 **Still present:**")) then .cur.bullets.still += 1
    elif ($l | startswith("<!-- findings-json:")) then
      .cur.findings = ($l | sub("^<!--[ ]*findings-json:[ ]*"; "")
                          | sub("[ ]*-->[[:space:]]*$"; "")
                          | (fromjson? // null)
                          | if type == "array"
                            then [ .[] | select(type == "object")
                                   | { status: (.status // "unknown"),
                                       severity: (.severity // "unknown") } ]
                            else null end)
    else . end)
| (.secs + (if .cur then [.cur] else [] end))
# the first section of a file is that PR first review; the ledger carries the
# reviewed kind itself and overrides this on every row it wins
| to_entries | map(.value + { kind: (if .key == 0 then "first" else "re-review" end) })
| .[]
'

# normalize both sources into the record above, drop what falls outside the
# window, keep one row per (pr, ts)
RR_MERGE_JQ='
[ .[] | select(type == "object")
  | { src: (.src // "ledger"), pr: .pr, ts: .ts, sha: (.sha // null),
      kind: (.kind // null), verdict: (.verdict // null),
      bullets: { fixed: (.bullets.fixed? // 0), still: (.bullets.still? // 0) },
      findings: (if (.findings | type) == "array" then .findings else null end) }
  | select((.pr | type) == "number" and (.ts | type) == "string") ]
| map(select($since == "" or .ts >= $since))
| group_by([.pr, .ts])
| map(([ .[] | select(.src == "ledger") ] | first) // .[0])
| sort_by(.ts) | .[]
'

# the week's numbers from an array of the records above — one program, so the
# audit and the trend backfill can never disagree about what a week measured.
# Severity is the only finding attribute the review form carries, so it is the
# only breakdown available without a new field; a review written before
# `findings-json` is outside `json_reviews` and outside the split.
# `new`/`new_by_severity` count the findings the week *raised*, the volume
# metric the trend artifact tracks beside the acceptance ratio (docs/trends.md).
RR_AGG_JQ='
{ reviews: { total: length,
             first: ([.[] | select(.kind == "first")] | length),
             re_review: ([.[] | select(.kind != "first")] | length),
             prs: ([.[] | .pr] | unique | length),
             approve: ([.[] | select(.verdict == "APPROVE")] | length),
             comment: ([.[] | select(.verdict == "COMMENT")] | length),
             request_changes: ([.[] | select(.verdict == "REQUEST_CHANGES")] | length) },
  findings: ([.[] | .findings | select(type == "array")] as $r
    | ([$r[] | .[]]) as $e
    | { fixed: ([.[] | .bullets.fixed] | add // 0),
        still_present: ([.[] | .bullets.still] | add // 0),
        json_reviews: ($r | length),
        new: ([$e[] | select(.status == "new")] | length),
        new_by_severity: ([$e[] | select(.status == "new")]
                          | group_by(.severity // "unknown")
                          | map({ key: (.[0].severity // "unknown"), value: length }) | from_entries),
        by_severity: ([$e[] | select(.status == "fixed" or .status == "still")]
                      | group_by(.severity // "unknown")
                      | map({ key: (.[0].severity // "unknown"),
                              value: { fixed: ([.[] | select(.status == "fixed")] | length),
                                       still: ([.[] | select(.status == "still")] | length) } })
                      | from_entries) }) }
'

# the zero row of RR_AGG_JQ — a week that measured nothing, and the fallback a
# reader prints when the aggregation itself could not run
RR_AGG_ZERO='{"reviews":{"total":0,"first":0,"re_review":0,"prs":0,"approve":0,"comment":0,"request_changes":0},"findings":{"fixed":0,"still_present":0,"json_reviews":0,"new":0,"new_by_severity":{},"by_severity":{}}}'

review_records() { # <reviews dir> <ledger file> [<since ISO>]
  local rdir="${1:-}" ledger="${2:-}" since="${3:-}" f n
  {
    [ -n "$ledger" ] && [ -f "$ledger" ] && cat "$ledger" 2>/dev/null
    if [ -n "$rdir" ] && [ -d "$rdir" ]; then
      for f in "$rdir"/pr-*.md; do
        [ -f "$f" ] || continue
        n="${f##*/pr-}"; n="${n%.md}"
        case "$n" in (''|*[!0-9]*) continue;; esac
        jq -Rsc --argjson pr "$n" "$RR_HISTORY_JQ" "$f" 2>/dev/null
      done
    fi
  } | jq -sc --arg since "$since" "$RR_MERGE_JQ" 2>/dev/null
}
