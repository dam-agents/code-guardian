#!/usr/bin/env bash
# health.sh — the agent's technical history and health dashboard
# (docs/health.md). The monitor's pass drives it on every tick.
#
#   health.sh record <conditions.json>  -> hourly rows, incidents, service status
#   health.sh report                    -> the dashboard HTML on stdout
#   health.sh due                       -> rc 0 when a publish is due
#   health.sh publish                   -> the dashboard to the DAM Artifact
#                                          Library, updated in place; {status, …}
#
# record keeps what the 14-day events log loses: one row of counts per UTC hour
# (work/health/hours.jsonl) and one row per incident (work/health/incidents.jsonl),
# both for HEALTH_KEEP_DAYS, plus the current state of each service
# (work/health/status.json). It reads the events log and the conditions the
# monitor found this tick; it makes no network call. The rows hold counts,
# classes, times and PR numbers only — never an event's free text.
#
# Requires: bash, jq, grep/sed/cut/tr/sort, GNU or BSD date. No awk.

set -u
export LC_ALL=C

MODE="${1:-}"
HOME_DIR="${HOME:-/home/agent}"
WORK="${WORK_DIR:-$HOME_DIR/work}"
CONFIG="$WORK/CONFIG.md"
DIR="$WORK/health"
HOURS="$DIR/hours.jsonl"
INCIDENTS="$DIR/incidents.jsonl"
STATUS="$DIR/status.json"
PUB="$DIR/state.json"            # {artifact_id, share_url, published_at, status_sig}
SCHEDULES="$DIR/schedules.json"  # the last list_schedules answer, trimmed
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NOW_EPOCH=$(date -u +%s)
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
HEALTH_KEEP_DAYS=90
PUBLISH_EVERY_S=10800            # a dashboard with no status change is republished after this

LOG_JOB=monitor
if ! . "$SCRIPT_DIR/log.sh" >/dev/null 2>&1; then logev() { :; }; fi
LOG_DIR="${LOG_DIR:-$WORK/logs}"
. "$SCRIPT_DIR/lib/common.sh"
BOT_NAME="$(cfg bot_display_name)"; BOT_NAME="${BOT_NAME:-Code Guardian}"

# scratch of this process, removed on any exit (a gate that stops the pass)
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/cg-health.XXXXXX" 2>/dev/null)" || TMPD=""
trap '[ -n "$TMPD" ] && rm -rf "$TMPD"' EXIT

# replaces <path> with what <producer…> prints, only when the producer
# succeeded: a failed jq never empties a record
write_from() { # <path> <producer…>
  local f="$1"; shift
  [ -n "$TMPD" ] || return 1
  if ( set -o pipefail; "$@" ) > "$TMPD/out" 2>/dev/null; then mv "$TMPD/out" "$f" 2>/dev/null
  else rm -f "$TMPD/out"; logev warn health "${f##*/} not updated this tick"; return 1; fi
}

# ---------------------------------------------------------------- record ----
# One row per UTC hour: {h, gate: {<job>: ticks}, gate_err, sessions, reviews,
# model_fail, gh_fail, gh_warn, classifier, tool_fail, errors, warns,
# pod_boots, backup_err, direct_sent, direct_fail, top_errors: {<event>: n}}
ROW_JQ='
  def n(f): map(select(f)) | length;
  group_by(.ts[0:13]) | map({h: .[0].ts[0:13],
    gate: (map(select(.event == "precheck")) | group_by(.job) | map({key: .[0].job, value: length}) | from_entries),
    gate_err: n(.event == "precheck" and .level == "error"),
    sessions: n(.event == "tokens"),
    reviews: n(.event == "review_step" and (.msg | test("^PR #[0-9]+:? +([0-9a-f]{7,40} +)?done$"))),
    model_fail: n(.event == "api_failure" and ((.msg | capture("^(?<c>[a-z_]+):") | .c) // "unknown" | IN("invalid_request", "max_output_tokens") | not)),
    gh_fail: n(.event == "preflight" and .level == "error" and (.msg | startswith("could not list open PRs"))),
    gh_warn: n(.event == "gh_api" or (.event == "preflight" and .level == "warn" and (.msg | test("API error")))),
    classifier: n(.event == "classifier_block"),
    tool_fail: n(.event == "tool_failure"),
    errors: n(.level == "error"),
    warns: n(.level == "warn"),
    pod_boots: n(.event == "pod_boot"),
    backup_err: n(.event == "work_backup" and .level == "error"),
    direct_sent: n(.event == "monitor_direct" and .level == "info"),
    direct_fail: n(.event == "monitor_direct" and .level == "error"),
    top_errors: (map(select(.level == "error") | .event | select(test("^[a-z][a-z0-9_]{0,39}$")))
                 | group_by(.) | map({key: .[0], value: length}) | sort_by(-.value) | .[0:5] | from_entries)})'

# the hour rows of the daily events files <files…>, as one JSON array
hour_rows() { # <file…>
  cat "$@" 2>/dev/null | jq -c -R 'fromjson? // empty | select((.ts | type) == "string" and (.ts | length) >= 13)' \
    | jq -sc "$ROW_JQ"
}
# the stored rows, with the recomputed hours of the days read replaced: an hour
# of another day keeps its stored row (an event written past midnight lands in
# the next day's file, so that file holds a fragment of the hour)
merge_hours() { # <rows.json> <dates.json> <keep>
  { jq -cR 'fromjson? // empty' "$HOURS" 2>/dev/null || true; } | jq -c -s --slurpfile new "$1" --slurpfile d "$2" --arg keep "$3" '
    ($new[0] | map(select(.h[0:10] | IN($d[0][])))) as $n
    | ($n | map(.h)) as $hs
    | [ .[] | objects | select((.h | type) == "string" and .h >= $keep) ]
    | (map(select(.h | IN($hs[]) | not)) + $n) | unique_by(.h) | .[]'
}

record() { # <conditions.json>
  local cond="$1" files last keep
  mkdir -p "$DIR" 2>/dev/null && [ -n "$TMPD" ] || return 1
  [ -r "$cond" ] || cond=/dev/null
  # the daily files from the newest stored row's day on, so a monitor that was
  # down for days catches up; on first contact every retained one (backfill)
  last="$(tail -1 "$HOURS" 2>/dev/null | jq -r '.h // empty' 2>/dev/null)"
  files="$(ls "$LOG_DIR"/events-*.jsonl 2>/dev/null | sort | while IFS= read -r f; do
      d="${f##*/events-}"; d="${d%.jsonl}"
      { [ -z "$last" ] || [ ! "$d" \< "${last:0:10}" ]; } && printf '%s\n' "$f"
    done)"
  keep="$(epoch2iso $(( NOW_EPOCH - HEALTH_KEEP_DAYS * 86400 )) '%Y-%m-%dT%H')"
  printf '%s\n' "$files" | sed -n 's#.*/events-\(.*\)\.jsonl$#\1#p' | jq -R . | jq -sc . > "$TMPD/dates"
  if [ -n "$files" ]; then
    # shellcheck disable=SC2086 # one path per line, no blanks in a work/ path
    ( set -o pipefail; IFS=$'\n'; hour_rows $files ) > "$TMPD/rows" 2>/dev/null || { logev warn health "hour rows not computed this tick"; return 1; }
  else echo '[]' > "$TMPD/rows"; fi
  write_from "$HOURS" merge_hours "$TMPD/rows" "$TMPD/dates" "$keep"

  # incidents: the monitor's conditions, one row per alert id
  jq -c '.[]?' "$cond" > "$TMPD/cond" 2>/dev/null || : > "$TMPD/cond"
  write_from "$INCIDENTS" incidents_merge "$keep"
  write_from "$STATUS" status_now
}

incidents_merge() { # <keep>
  { jq -cR 'fromjson? // empty' "$INCIDENTS" 2>/dev/null || true; } | jq -c -s --slurpfile c "$TMPD/cond" \
      --arg now "$NOW_ISO" --arg keep "${1}:00:00Z" '
    def pick: {count, runs, errors, failures, silent_minutes, limit_minutes, threshold, pr, prs, parts, minutes}
      | with_entries(select(.value != null));
    def point: IN("classifier_spike", "review_post_blocked", "stall_alert", "review_anomaly");
    [ .[] | objects | select((.id | type) == "string") ] as $old
    | [ $c[] | select((.id | type) == "string" and (.kind | type) == "string" and (.kind | endswith("_recovered") | not)) ] as $cur
    | ($cur | map(.id)) as $ids
    | ($old | map(select(.id as $i | $ids | index($i) | not)
                  | if .open then . + {open: false, end: .last_seen} else . end))
      + [ $cur[] | . as $x | (($old | map(select(.id == $x.id)) | first) // {}) as $o
          | ((($x.kind | point) or ($x.open == false))) as $closed
          | {id: $x.id, kind: $x.kind,
             first: ($o.first // $x.first // $x.last // $x.ts // $now),
             last_seen: $now, open: ($closed | not),
             end: (if $closed then ($x.over_at // $x.last // $x.ts // $now) else null end),
             detail: ($x | pick)} ]
    | map(select(.last_seen >= $keep)) | sort_by(.first) | .[]'
}

# true when a harness adapter writes the per-run `tokens` event
# (docs/logging.md → Harness adapters): this process runs in a Claude Code
# session, or the Claude Code adapter's SessionEnd hook is installed — the
# monitor's gate runs outside the session
tokens_adapter() {
  if [ "${CLAUDECODE:-}" = "1" ] || jq -e '[.hooks.SessionEnd[]?.hooks[]?.command | strings
        | select(endswith("/log-session-tokens.sh"))] | length > 0' "$HOME_DIR/.claude/settings.json" >/dev/null 2>&1
  then echo true; else echo false; fi
}

# the service status: the conditions of this tick, the last hours' counts
status_now() {
  { jq -cR 'fromjson? // empty' "$HOURS" 2>/dev/null || true; } | jq -sc --slurpfile c "$TMPD/cond" \
      --arg now "$NOW_ISO" --argjson nowe "$NOW_EPOCH" --arg hb "${HB_LAST:-}" \
      --arg wr "$(cfg work_repo)" --arg direct "$(cfg monitor_slack_direct)" \
      --arg ready "$(bash "$SCRIPT_DIR/monitor-direct.sh" ready 2>/dev/null)" --argjson adapter "$(tokens_adapter)" '
    def since($s): map(select(.h >= ($nowe - $s * 3600 | strftime("%Y-%m-%dT%H"))));
    def sum(f): map(f // 0) | add // 0;
    def has($k): any($c[]; .kind == $k);
    def open($k): any($c[]; .kind == $k and .open == true);
    (since(2)) as $h2 | (since(6)) as $h6 | (since(24)) as $h24
    # without an adapter no session writes a `tokens` event: 24 h without one
    # measured nothing, never a zero
    | ($adapter or ($h24 | sum(.sessions)) > 0) as $measured
    | {ts: $now, tokens_adapter: $adapter, services: [
        {key: "platform", name: "DAM schedules",
         state: (if has("heartbeat_gap") then "down" elif ($h6 | sum(.pod_boots)) + ($h6 | sum(.gate_err)) > 0 then "warn" else "ok" end),
         note: "Last review-gate tick: \(if $hb == "" then "none on record" else $hb end). Pod restarts 24 h: \($h24 | sum(.pod_boots)). Broken gates 24 h: \($h24 | sum(.gate_err))."},
        {key: "harness", name: "Harness",
         state: (if has("harness_drift") then "warn" else "ok" end),
         note: ("Sessions 24 h: \(if $measured then $h24 | sum(.sessions) else "not measured (no tokens adapter on this harness)" end). Tool failures 24 h: \($h24 | sum(.tool_fail))."
               + (if has("harness_drift") then " Adapter not current: \([$c[] | select(.kind == "harness_drift") | .parts[]?] | join(", "))." else "" end))},
        {key: "model", name: "Model API",
         state: (if open("model_unavailable") then "down" elif ($h2 | sum(.model_fail)) > 0 then "warn" else "ok" end),
         note: "Failures 24 h: \($h24 | sum(.model_fail))."},
        {key: "github", name: "GitHub API",
         state: (if open("github_unavailable") then "down" elif ($h2 | sum(.gh_fail)) + ($h2 | sum(.gh_warn)) > 0 then "warn" else "ok" end),
         note: "Failed gate passes 24 h: \($h24 | sum(.gh_fail)). API warnings 24 h: \($h24 | sum(.gh_warn))."},
        {key: "classifier", name: "Auto-mode classifier",
         state: (if has("classifier_spike") or has("review_post_blocked") then "warn" else "ok" end),
         note: "Refusals 24 h: \($h24 | sum(.classifier))."},
        {key: "backup", name: "Work backup",
         state: (if $wr == "" then "na" elif has("backup_failing") then "down" elif ($h6 | sum(.backup_err)) > 0 then "warn" else "ok" end),
         note: (if $wr == "" then "No work_repo." else "Failed pushes 24 h: \($h24 | sum(.backup_err))." end)},
        {key: "slack", name: "Direct Slack alerts",
         state: (if $direct != "enabled" then "na" elif $ready != "" or ($h6 | sum(.direct_fail)) > 0 then "warn" else "ok" end),
         note: (if $direct != "enabled" then "Off." elif $ready != "" then "Enabled, but no send is possible: \($ready)." else "Sent 24 h: \($h24 | sum(.direct_sent)). Failed 24 h: \($h24 | sum(.direct_fail))." end)}]}
    | . + {sig: ([.services[] | "\(.key)=\(.state)"] | join(","))}'
}

# ---------------------------------------------------------------- report ----
report() {
  local status schedules body
  status="$(jq -c . "$STATUS" 2>/dev/null)"; [ -n "$status" ] || status='{"services":[]}'
  schedules="$(jq -c 'if type == "array" then . else [] end' "$SCHEDULES" 2>/dev/null)"; [ -n "$schedules" ] || schedules='null'
  body="$( { jq -cR 'fromjson? // empty' "$HOURS" 2>/dev/null | jq -sc .; jq -cR 'fromjson? // empty' "$INCIDENTS" 2>/dev/null | jq -sc .; } \
    | jq -rs --argjson status "$status" --argjson sched "$schedules" --argjson nowe "$NOW_EPOCH" --argjson keep "$HEALTH_KEEP_DAYS" '
    (.[0] // []) as $rows | (.[1] // []) as $inc
    | ($rows | map({key: .h, value: .}) | from_entries) as $byh
    | ($rows | map(.h) | min) as $start
    | def zero: {gate: {}, gate_err: 0, sessions: 0, reviews: 0, model_fail: 0, gh_fail: 0, gh_warn: 0,
                 classifier: 0, tool_fail: 0, errors: 0, warns: 0, pod_boots: 0, backup_err: 0,
                 direct_sent: 0, direct_fail: 0};
      def gate_n: (.gate // {}) | to_entries | map(.value) | add // 0;
      def esc: tostring | @html;
      # the last <n> hours, oldest first; an hour before the history began is null
      [ range($nowe / 3600 | floor - 167; $nowe / 3600 | floor + 1) | . * 3600 | strftime("%Y-%m-%dT%H") as $h
        | if $start == null or $h < $start then {label: $h, row: null} else {label: $h, row: ($byh[$h] // zero)} end ] as $hours
      | [ range($nowe / 86400 | floor - ($keep - 1); $nowe / 86400 | floor + 1) | . * 86400 | strftime("%Y-%m-%d") as $d
          | [ $rows[] | select(.h[0:10] == $d) ] as $r
          | if $start == null or $d < $start[0:10] then {label: $d, row: null}
            else {label: $d, row: (reduce $r[] as $x (zero;
                   reduce ($x | to_entries[] | select(.value | type == "number")) as $e (.; .[$e.key] += $e.value)
                   | .gate_n = ((.gate_n // 0) + ($x | gate_n))))} end ] as $days
      # one stacked bar chart: $series = [{name, color, f}] where f names a field or "gate_n"
      | def val($row; $f): if $row == null then null elif $f == "gate_n" then ($row.gate_n // ($row | gate_n)) else ($row[$f] // 0) end;
        def bars($pts; $series):
          ($pts | length) as $n
          | ([ $pts[] | .row as $r | [ $series[] | val($r; .f) // 0 ] | add ] | max // 0) as $peak
          | (if $peak <= 0 then 1 else $peak end) as $ymax
          | (282 / $n) as $w
          | "<svg viewBox=\"0 0 320 100\" role=\"img\">"
            + "<line class=\"ax\" x1=\"34\" y1=\"80\" x2=\"316\" y2=\"80\"/>"
            + "<text class=\"lb\" x=\"31\" y=\"17\" text-anchor=\"end\">\($ymax)</text>"
            + "<text class=\"lb\" x=\"31\" y=\"83\" text-anchor=\"end\">0</text>"
            + "<text class=\"lb\" x=\"34\" y=\"95\">\($pts[0].label | esc)</text>"
            + "<text class=\"lb\" x=\"316\" y=\"95\" text-anchor=\"end\">\($pts[-1].label | esc)</text>"
            + ([ $pts | to_entries[] | .key as $i | .value as $p
                 | (34 + $i * $w) as $x
                 | if $p.row == null then "<rect class=\"nodata\" x=\"\($x * 100 | round / 100)\" y=\"14\" width=\"\($w * 100 | round / 100)\" height=\"66\"><title>\($p.label | esc): no history yet</title></rect>"
                   else
                     (reduce $series[] as $s ({y: 80, out: ""};
                        (val($p.row; $s.f) // 0) as $v
                        | ($v / $ymax * 66) as $hgt
                        | if $v > 0 then .out += "<rect x=\"\($x * 100 | round / 100)\" y=\"\((.y - $hgt) * 100 | round / 100)\" width=\"\(([$w - 0.3, 0.4] | max) * 100 | round / 100)\" height=\"\($hgt * 100 | round / 100)\" fill=\"\($s.color)\"/>"
                               | .y -= $hgt
                          else . end) | .out)
                     + "<rect class=\"hit\" x=\"\($x * 100 | round / 100)\" y=\"14\" width=\"\($w * 100 | round / 100)\" height=\"66\"><title>\($p.label | esc)\n\([ $series[] | "\(.name): \(val($p.row; .f) // 0)" ] | join("\n") | esc)</title></rect>"
                   end ] | join(""))
            + "</svg>";
        def figure($pts; $title; $note; $series):
          "<figure><figcaption>\($title)</figcaption>"
          + (if ($series | length) > 1 then "<p class=\"legend\">" + ([$series[] | "<span style=\"color:\(.color)\">■</span> \(.name)"] | join(" · ")) + "</p>" else "" end)
          + bars($pts; $series) + "<p class=\"note\">\($note)</p></figure>";
        def charts($pts; $unit):
          "<div class=\"grid\">"
          + figure($pts; "Gate ticks per \($unit)"; "Every schedule fire that reached its gate. A run of zeros means that no schedule fired."; [{name: "ticks", color: "var(--c1)", f: "gate_n"}])
          + (if $status.tokens_adapter == false and ($pts | all(.row == null or (.row.sessions // 0) == 0))
             then figure($pts; "Reviews per \($unit)"; "Reviews that reached done. Sessions are not measured: no harness adapter writes the tokens event."; [{name: "reviews", color: "var(--c3)", f: "reviews"}])
             else figure($pts; "Sessions and reviews per \($unit)"; "Sessions that ended, and reviews that reached done."; [{name: "sessions", color: "var(--c1)", f: "sessions"}, {name: "reviews", color: "var(--c3)", f: "reviews"}]) end)
          + figure($pts; "Model API failures per \($unit)"; "Turns that ended on a provider or gateway error after the harness retries."; [{name: "failures", color: "var(--bad)", f: "model_fail"}])
          + figure($pts; "GitHub failures per \($unit)"; "Gate passes that could not list the open PRs, and partial API warnings."; [{name: "failed passes", color: "var(--bad)", f: "gh_fail"}, {name: "warnings", color: "var(--c2)", f: "gh_warn"}])
          + figure($pts; "Classifier refusals per \($unit)"; "Auto-mode classifier refusals of a tool call."; [{name: "refusals", color: "var(--c2)", f: "classifier"}])
          + figure($pts; "Errors and warnings per \($unit)"; "Every error and warning line of the events log."; [{name: "errors", color: "var(--bad)", f: "errors"}, {name: "warnings", color: "var(--c2)", f: "warns"}])
          + "</div>";
        def dur($a; $b): ((($b // "") | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601?) // null) as $e
          | ((($a // "") | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601?) // null) as $s
          | if $s == null or $e == null then "—" else (($e - $s) / 60 | floor) as $m
            | if $m >= 120 then "\($m / 60 | floor) h \($m % 60) min" else "\($m) min" end end;
        def detail: to_entries | map("\(.key)=\(.value | if type == "object" then (to_entries | map("\(.key):\(.value)") | join(",")) elif type == "array" then join(",") else tostring end)") | join(" ");
      # hours of the history with no gate tick at all, the current one excluded
      ([ if $start == null then empty else
           range(($start + ":00:00Z" | fromdateiso8601) / 3600; $nowe / 3600 | floor) | . * 3600 | strftime("%Y-%m-%dT%H") end ]
       | map(select(($byh[.] // zero) | gate_n == 0))
       | reduce .[] as $h ([]; if length > 0 and ((.[-1].to + ":00:00Z" | fromdateiso8601) + 3600 | strftime("%Y-%m-%dT%H")) == $h
                               then .[-1].to = $h else . + [{from: $h, to: $h}] end)
       | map({kind: "no_gate_tick", first: (.from + ":00:00Z"), open: false,
              end: ((.to + ":00:00Z" | fromdateiso8601) + 3600 | todate),
              detail: {hours: (((.to + ":00:00Z" | fromdateiso8601) - (.from + ":00:00Z" | fromdateiso8601)) / 3600 + 1)}})) as $silent
      | ($inc + $silent) as $inc
      | "<section class=\"tiles\">"
      + ([ $status.services[] | "<div class=\"tile \(.state | esc)\"><b><span class=\"dot\"></span>\(.name | esc)</b><span class=\"st\">\(.state | if . == "na" then "not used" else . end | esc)</span><p>\(.note | esc)</p></div>" ] | join(""))
      + "</section>"
      + "<h2>Last 7 days, per hour (UTC)</h2>" + charts($hours; "hour")
      + "<h2>Incidents</h2>"
      + (if ($inc | length) == 0 then "<p class=\"nodata\">No incident on record.</p>"
         else "<div class=scroll><table><thead><tr><th>Kind</th><th>Started (UTC)</th><th>Ended (UTC)</th><th class=\"n\">Duration</th><th>Facts</th></tr></thead><tbody>"
           + ([ $inc | sort_by(.first) | reverse[]
                | "<tr\(if .open then " class=\"open\"" else "" end)><td>\(.kind | esc)</td><td>\(.first | esc)</td>"
                  + "<td>\(if .open then "open" else (.end // "—") end | esc)</td>"
                  + "<td class=\"n\">\(dur(.first; (if .open then ($nowe | todate) else .end end)) | esc)</td>"
                  + "<td>\((.detail // {}) | detail | esc)</td></tr>" ] | join(""))
           + "</tbody></table></div>" end)
      + "<h2>Last \($keep) days, per day (UTC)</h2>" + charts($days; "day")
      + "<h2>Top errors, last 7 days</h2>"
      + ([ $rows[] | select(.h >= ($nowe - 7 * 86400 | strftime("%Y-%m-%dT%H"))) | (.top_errors // {}) | to_entries[] ]
         | group_by(.key) | map({k: .[0].key, v: (map(.value) | add)}) | sort_by(-.v) | .[0:10]
         | if length == 0 then "<p class=\"nodata\">No error lines.</p>"
           else "<div class=scroll><table><thead><tr><th>Event</th><th class=\"n\">Error lines</th></tr></thead><tbody>"
             + (map("<tr><td>\(.k | esc)</td><td class=\"n\">\(.v)</td></tr>") | join("")) + "</tbody></table></div>" end)
      + (if $sched == null then ""
         else "<h2>Schedules (DAM)</h2><div class=scroll><table><thead><tr><th>Name</th><th>Enabled</th><th>Last run (UTC)</th><th>Last result</th><th class=\"n\">Declined</th><th class=\"n\">Gate failures</th><th>Gate error on record</th></tr></thead><tbody>"
           + ([ $sched[] | "<tr><td>\(.name | esc)</td><td>\(.enabled | esc)</td><td>\(.lastRun // "—" | esc)</td><td>\(.result // "—" | esc)</td><td class=\"n\">\(.declined // 0 | esc)</td><td class=\"n\">\(.gateFailures // 0 | esc)</td><td>\(if .gateError then "yes" else "no" end)</td></tr>" ] | join(""))
           + "</tbody></table></div>" end)' 2>/dev/null)"
  [ -n "$body" ] || body='<p class="nodata">No history yet.</p>'
  . "$SCRIPT_DIR/lib/report-tip.sh"
  cat <<EOF
<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Agent health</title>
<style>
:root{
  color-scheme:light dark;
  --surface:#fcfcfb;--plane:#f9f9f7;--head:#f2f2f0;
  --ink:#0b0b0b;--ink-2:#52514e;--ink-muted:#898781;
  --rule:#e1e0d9;--rule-strong:#c3c2b7;
  --seq:#2a78d6;--good:#006300;--warn:#b8641f;--bad:#d03b3b;
  --c1:#2a78d6;--c2:#b8641f;--c3:#7c4dbf;
}
@media (prefers-color-scheme:dark){:root{
  --surface:#1a1a19;--plane:#0d0d0d;--head:#232322;
  --ink:#fff;--ink-2:#c3c2b7;--ink-muted:#898781;
  --rule:#2c2c2a;--rule-strong:#383835;
  --seq:#3987e5;--good:#0ca30c;--warn:#e0a03c;--bad:#e66767;
  --c1:#3987e5;--c2:#e0a03c;--c3:#a883e6;
}}
body{font-family:system-ui,-apple-system,'Segoe UI',sans-serif;margin:0 auto;
  padding:2rem 1rem;max-width:84rem;color:var(--ink);background:var(--plane);
  line-height:1.5;-webkit-text-size-adjust:100%}
h1{font-size:1.35rem;letter-spacing:-.01em;margin:0 0 .4rem}
h2{font-size:1.05rem;margin:2.2rem 0 .5rem;padding-bottom:.25rem;
  border-bottom:1px solid var(--rule-strong)}
p.meta{color:var(--ink-2);font-size:.82rem;max-width:60rem;margin:.3rem 0 1.4rem}
.tiles{display:grid;gap:.7rem;grid-template-columns:repeat(auto-fit,minmax(min(100%,15rem),1fr))}
.tile{background:var(--surface);border:1px solid var(--rule);border-left:4px solid var(--rule-strong);
  border-radius:6px;padding:.6rem .75rem}
.tile b{display:flex;align-items:center;gap:.45rem;font-size:.9rem}
.tile .dot{width:.6rem;height:.6rem;border-radius:50%;background:var(--ink-muted)}
.tile .st{font-size:.75rem;text-transform:uppercase;letter-spacing:.04em;color:var(--ink-2)}
.tile p{font-size:.78rem;color:var(--ink-2);margin:.3rem 0 0}
.tile.ok{border-left-color:var(--good)}.tile.ok .dot{background:var(--good)}
.tile.warn{border-left-color:var(--warn)}.tile.warn .dot{background:var(--warn)}
.tile.down{border-left-color:var(--bad)}.tile.down .dot{background:var(--bad)}
.grid{display:grid;gap:1rem;grid-template-columns:repeat(auto-fit,minmax(min(100%,26rem),1fr))}
figure{margin:0;padding:.7rem .8rem .5rem;background:var(--surface);
  border:1px solid var(--rule);border-radius:6px}
figcaption{font-size:.85rem;font-weight:600;margin-bottom:.1rem}
.legend{font-size:.75rem;color:var(--ink-2);margin:.1rem 0 .3rem}
.note{font-size:.72rem;color:var(--ink-muted);margin:.25rem 0 0}
.nodata{font-size:.78rem;color:var(--ink-muted)}
svg{width:100%;height:auto;display:block;overflow:visible}
svg .ax{stroke:var(--rule-strong);stroke-width:.8}
svg .lb{font-size:5.5px;fill:var(--ink-muted);font-family:system-ui,sans-serif}
svg rect.nodata{fill:var(--rule);opacity:.35}
svg .hit{fill:transparent}
svg .hit:hover{fill:color-mix(in srgb,var(--seq) 14%,transparent)}
.scroll{overflow-x:auto;background:var(--surface);border:1px solid var(--rule);border-radius:6px}
table{border-collapse:collapse;width:100%;font-size:.82rem;margin:0}
th,td{padding:.36rem .6rem;text-align:left;border-bottom:1px solid var(--rule);white-space:nowrap}
th{background:var(--head);font-weight:600;color:var(--ink-2)}
th.n,td.n{text-align:right;font-variant-numeric:tabular-nums}
tbody tr:last-child td{border-bottom:0}
tr.open td{color:var(--bad)}
${REPORT_TIP_CSS}
</style>
<h1>$(printf '%s' "$BOT_NAME" | jq -Rr @html) — health</h1>
<p class="meta">Updated ${NOW_ISO}. The monitor writes one row of counts per UTC hour and
one row per incident, and keeps them for ${HEALTH_KEEP_DAYS} days. A grey bar is an hour
before the history began. Point to a bar for its numbers. Semantics: docs/health.md.</p>
${body}
<script>
${REPORT_TIP_JS}
</script>
EOF
}

# --------------------------------------------------------------- publish ----
publish() {
  local args res rc id html
  . "$SCRIPT_DIR/lib/mcp.sh"
  . "$SCRIPT_DIR/lib/redact.sh"
  mkdir -p "$DIR" 2>/dev/null && [ -n "$TMPD" ] || { pub_failed "no scratch directory"; return 0; }
  args="$TMPD/args"
  # the schedules table: best-effort, only with time left for the publish
  # after it, and kept from the last answer when this one fails. DAM's own
  # text (the last result, the gate error) stays out: a class and counts only.
  if [ -z "${MCP_DEADLINE:-}" ] || [ $(( MCP_DEADLINE - $(date -u +%s) )) -ge 40 ]; then
    printf '{}' > "$args"
    if mcp_call list_schedules "$args" > "$TMPD/sched" 2>/dev/null; then
      write_from "$SCHEDULES" jq -c 'def t: if type == "string" and test("\\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]{5,15}Z\\z") then . else null end;
        def n: if type == "number" then . else 0 end;
        [ .[]? | select(type == "object")
          | {name: (.name | if type == "string" and test("\\A[A-Za-z0-9 ._:-]{1,80}\\z") then . else "(other)" end),
             enabled: (.spec.enabled == true), lastRun: (.status.lastRun | t),
             result: (.status.lastResult | if . == null then null elif . == "success" then "success"
                      elif type == "string" and startswith("held") then "held" else "failed" end),
             declined: (.status.declinedCount | n), gateFailures: (.status.precheckFailedCount | n),
             gateError: ((.status.lastPrecheckError // "") != "")} ]' "$TMPD/sched"
    fi
  fi
  html="$DIR/dashboard.html"
  report > "$TMPD/page" && mv "$TMPD/page" "$html" || { pub_failed "the page did not render"; return 0; }
  redact_file "$html" >/dev/null || { pub_failed "redaction did not run"; return 0; }
  if [ "$(wc -c < "$html")" -gt 1900000 ]; then pub_failed "the dashboard is over 1.9 MB"; return 0; fi
  id="$(jq -r '.artifact_id // empty' "$PUB" 2>/dev/null)"
  rc=1
  if [ -n "$id" ]; then
    jq -nc --arg id "$id" --rawfile c "$html" '{id: $id, content: $c}' > "$args"
    res="$(mcp_call update_artifact "$args")"; rc=$?
    # a new artifact only when the kept one is gone: any other refusal keeps
    # the share URL the DMs already carry
    if [ "$rc" -eq 3 ] && ! printf '%s' "$res" | grep -qi 'not found'; then
      pub_failed "update refused: $(printf '%s' "$res" | tr '\n' ' ' | cut -c1-120)"; return 0
    fi
  fi
  if [ -z "$id" ] || [ "$rc" -eq 3 ]; then
    jq -nc --arg t "$BOT_NAME health" --rawfile c "$html" \
      '{title: $t, content: $c, file_name: "health.html", type: "html", visibility: "public"}' > "$args"
    res="$(mcp_call create_artifact "$args")"; rc=$?
  fi
  case "$rc" in
    (0) ;;
    (1) pub_failed "no platform-outbound endpoint"; return 0;;
    (2) pub_failed "transport failure"; return 0;;
    (4) pub_failed "no answer after the call went out"; return 0;;
    (*) pub_failed "refused: $(printf '%s' "$res" | tr '\n' ' ' | cut -c1-120)"; return 0;;
  esac
  printf '%s' "$res" > "$TMPD/res"
  pub_state --slurpfile r "$TMPD/res" --arg sig "$(jq -r '.sig // ""' "$STATUS" 2>/dev/null)" '
    ($r[0] // {}) as $r
    | . + {artifact_id: ($r.id // .artifact_id), share_url: ($r.shareUrl // .share_url),
           published_at: $now, status_sig: $sig} | del(.last_attempt, .last_error)'
  jq -c '{status: "published", id: .artifact_id, share_url}' "$PUB" 2>/dev/null \
    || jq -nc '{status: "published"}'
}

# rewrites state.json by <jq filter> over its current content ({} when absent
# or broken), with $now bound; a failed filter keeps the file
pub_state() { # [jq args…] <filter>
  local filter="${*: -1}"
  write_from "$PUB" sh_jq_state "${@:1:$#-1}" "$filter"
}
sh_jq_state() {
  local filter="${*: -1}"
  { cat "$PUB" 2>/dev/null || true; } | jq -c -n --arg now "$NOW_ISO" "${@:1:$#-1}" \
    "((try input catch null) | objects // {}) | $filter"
}
pub_failed() { # <reason>
  pub_state --arg why "$1" '. + {last_attempt: $now, last_error: $why}'
  jq -nc --arg why "$1" '{status: "failed", reason: $why}'
}

# due: the dashboard is on, no failed attempt in the last 30 min, and the
# status changed or the last publish is old
publish_due() {
  [ "$(cfg health_dashboard)" = dam ] || return 1
  local at sig tried
  at="$(jq -r '.published_at // empty' "$PUB" 2>/dev/null)"
  sig="$(jq -r '.status_sig // empty' "$PUB" 2>/dev/null)"
  tried="$(jq -r '.last_attempt // empty' "$PUB" 2>/dev/null)"
  [ -n "$tried" ] && [ $(( NOW_EPOCH - $(iso2epoch "$tried") )) -lt 1800 ] && return 1
  [ -z "$at" ] && return 0
  [ "$sig" != "$(jq -r '.sig // ""' "$STATUS" 2>/dev/null)" ] && return 0
  [ $(( NOW_EPOCH - $(iso2epoch "$at") )) -ge "$PUBLISH_EVERY_S" ]
}

case "$MODE" in
  record) record "${2:-/dev/null}";;
  report) report;;
  publish) publish;;
  due) publish_due;;
  *) echo '{"error":"use health.sh record <conditions.json>|report|publish|due"}'; exit 2;;
esac
