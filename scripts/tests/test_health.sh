#!/usr/bin/env bash
# health.sh: the hourly rows and incidents that outlive the events log, the
# service status, the dashboard HTML, and its publish to the DAM Artifact
# Library — created once, then updated in place. Contract: docs/health.md.
. "$(dirname "$0")/helpers.sh"

MCP_URL="http://mcp.test/api/agents/a1/mcp"
HEALTH="$REPO_ROOT/scripts/health.sh"

ev() { # <secs-ago> <job> <level> <event> <msg> [run]
  mkdir -p "$WORK/logs"
  local ts; ts="$(iso_ago "$1")"
  jq -nc --arg ts "$ts" --arg job "$2" --arg lv "$3" --arg e "$4" --arg m "$5" --arg r "${6:-r1}" \
    '{ts:$ts, run:$r, job:$job, level:$lv, event:$e, msg:$m}' >> "$WORK/logs/events-${ts:0:10}.jsonl"
}
h_case() { # <case> [config lines…]
  new_case "$1"; shift
  base_config "$@" '- bot_display_name: Guardian'
  mkdir -p "$WORK/logs" "$SANDBOX/mcp"
  printf '{"mcpServers":{"platform-outbound":{"type":"http","url":"%s"}}}\n' "$MCP_URL" > "$FAKE_HOME/.mcp.json"
  : > "$SANDBOX/mcp.log"; echo '[]' > "$SANDBOX/cond.json"
}
henv() { env CURL_MCP_URL="$MCP_URL" CURL_MCP_LOG="$SANDBOX/mcp.log" CURL_MCP_DIR="$SANDBOX/mcp" \
  WORK_DIR="$WORK" HOME="$FAKE_HOME" TMPDIR="$SANDBOX" PATH="$T_DIR/bin:$PATH" "$@"; }
health() { OUT="$(henv bash "$HEALTH" "$@" 2>>"$STDERR_LOG")"; }
record() { health record "$SANDBOX/cond.json"; }
hours() { OUT="$(jq -sc . "$WORK/health/hours.jsonl" 2>/dev/null)"; }
status() { OUT="$(cat "$WORK/health/status.json" 2>/dev/null)"; }
incidents() { OUT="$(jq -sc . "$WORK/health/incidents.jsonl" 2>/dev/null)"; }
calls() { jq -s --arg t "$1" '[.[] | select(.method == "tools/call" and .params.name == $t)] | length' "$SANDBOX/mcp.log"; }
# a large page through `grep -q` on a pipe breaks the pipe: these read a file
has() { # <file> <fixed text> <description>
  if grep -qF -- "$2" "$1"; then printf 'ok   %s: %s\n' "$CASE" "$3"
  else printf 'FAIL %s: %s (%s not found)\n' "$CASE" "$3" "$2"; FAILED=1; fi
}
lacks() { # <file> <grep -E pattern> <description>
  if grep -qE -- "$2" "$1"; then printf 'FAIL %s: %s (%s found)\n' "$CASE" "$3" "$2"; FAILED=1
  else printf 'ok   %s: %s\n' "$CASE" "$3"; fi
}
check_eq() { # <actual> <expected> <description>
  if [ "$1" = "$2" ]; then printf 'ok   %s: %s\n' "$CASE" "$3"
  else printf 'FAIL %s: %s (got %s, want %s)\n' "$CASE" "$3" "$1" "$2"; FAILED=1; fi
}
# an instant early in the last full hour, so every event lands in one hour row
AGO=$(( $(date -u +%s) % 3600 + 1800 ))
H="$(iso_ago "$AGO")"; H="${H:0:13}"

# --- hourly rows: every counter, no free text -----------------------------------------
h_case h_rows
ev "$AGO" review info precheck "review gate: nothing to do"
ev "$AGO" review error precheck "review gate: preflight could not decide — <!channel>"
ev "$AGO" monitor info precheck "monitor gate: nothing to do"
ev "$AGO" session info tokens "in=1 out=2"
ev "$AGO" session info review_step "PR #4 abc1234 done"
ev "$AGO" session info review_step "PR #4 abc1234 locked"
ev "$AGO" session info review_step "PR #4 skill:code-review done"
ev "$AGO" session error api_failure "overloaded: 529 <@U0123ABCD>"
ev "$AGO" session error api_failure "invalid_request: prompt too long"
ev "$AGO" review error preflight "could not list open PRs on acme/widgets (API error: HTTP 502)"
ev "$AGO" review warn gh_api "PR #4: state check did not respond — prune skipped this run"
ev "$AGO" session warn classifier_block "Bash [rm -rf /] — Blocked"
ev "$AGO" session error tool_failure "Bash exit 1"
ev "$AGO" review warn pod_boot "pod restarted since last run"
ev "$AGO" session error work_backup "push failed"
ev "$AGO" monitor info monitor_direct "sent 1 alert(s)"
ev "$AGO" monitor error monitor_direct "failed: transport failure"
record
hours
assert_jq '.[] | select(.h == "'"$H"'") | .gate == {"review": 2, "monitor": 1} and .gate_err == 1 and .sessions == 1
  and .reviews == 1 and .model_fail == 1 and .gh_fail == 1 and .gh_warn == 1 and .classifier == 1 and .tool_fail == 1
  and .pod_boots == 1 and .backup_err == 1 and .direct_sent == 1 and .direct_fail == 1 and .errors == 7 and .warns == 3' \
  'one hour row counts every signal; a skill step is no review; agent-side API errors are not model failures'
OUT="$(cat "$WORK/health/hours.jsonl")"
assert_out_absent 'channel|U0123ABCD|rm -rf|acme|529' 'no free text of an event reaches a row'

# --- the rows outlive the events log; old rows age out -------------------------------------
h_case h_keep
ev "$AGO" review info precheck "review gate: nothing to do"
OLD="$(jq -rn --argjson e "$(( $(date -u +%s) - 91 * 86400 ))" '$e | strftime("%Y-%m-%dT%H")')"
KEPT="$(jq -rn --argjson e "$(( $(date -u +%s) - 30 * 86400 ))" '$e | strftime("%Y-%m-%dT%H")')"
mkdir -p "$WORK/health"
jq -nc --arg o "$OLD" --arg k "$KEPT" '{h: $o, gate: {review: 12}}, {h: $k, gate: {review: 9}}' > "$WORK/health/hours.jsonl"
record
rm -f "$WORK"/logs/events-*.jsonl
ev 60 review info precheck "review gate: nothing to do"
record
hours
assert_jq '(map(.h) | index("'"$KEPT"'")) != null and (map(.h) | index("'"$OLD"'")) == null' 'a row past 90 days goes, a younger one stays'
assert_jq 'any(.[]; .h == "'"$H"'" and .gate.review == 1)' 'an hour whose events file is gone keeps its row'

h_case h_backfill
for d in 5 3 1; do ev $(( d * 86400 )) review info precheck "review gate: nothing to do"; done
ev 60 review info precheck "review gate: nothing to do"
record
hours
assert_jq 'length == 4' 'first contact backfills every retained events file'

h_case h_catch_up
for d in 4 3 2; do ev $(( d * 86400 )) review info precheck "review gate: nothing to do"; done
ev 60 review info precheck "review gate: nothing to do"
mkdir -p "$WORK/health"
jq -nc --argjson e "$(( $(date -u +%s) - 4 * 86400 ))" '{h: ($e | strftime("%Y-%m-%dT%H")), gate: {review: 1}}' > "$WORK/health/hours.jsonl"
record
hours
assert_jq 'length == 4' 'a monitor that was down for days reads every file since its newest row'

h_case h_midnight
# a stored full hour 23 of an older day, and one event of that hour that landed
# in the next day's file (logev stamps before it picks the file)
D2="$(jq -rn --argjson e "$(( $(date -u +%s) - 2 * 86400 ))" '$e | strftime("%Y-%m-%d")')"
D3="$(jq -rn --argjson e "$(( $(date -u +%s) - 3 * 86400 ))" '$e | strftime("%Y-%m-%d")')"
mkdir -p "$WORK/health"
jq -nc --arg h "${D3}T23" '{h: $h, gate: {review: 6}}' > "$WORK/health/hours.jsonl"
jq -nc --arg h "${D2}T01" '{h: $h, gate: {review: 1}}' >> "$WORK/health/hours.jsonl"
jq -nc --arg ts "${D3}T23:59:59.990Z" '{ts: $ts, run: "r", job: "review", level: "info", event: "precheck", msg: "x"}' > "$WORK/logs/events-$D2.jsonl"
ev 60 review info precheck "review gate: nothing to do"
record
hours
assert_jq '.[] | select(.h == "'"${D3}T23"'") | .gate.review == 6' 'a fragment of an hour in the next day file never replaces its stored row'

# --- incidents: open, closed, point, recovery notices left out -------------------------------
h_case h_incidents
cat > "$SANDBOX/cond.json" <<EOF
[{"id":"github:$(iso_ago 900)","kind":"github_unavailable","first":"$(iso_ago 900)","last":"$(iso_ago 300)","count":2,"errors":{"auth":2},"open":true},
 {"id":"model:x:recovered","kind":"model_recovered","needs":"model:x","first":"$(iso_ago 9000)","last":"$(iso_ago 8000)","open":false},
 {"id":"heartbeat:$(iso_ago 7200)","kind":"heartbeat_gap","last":"$(iso_ago 7200)","silent_minutes":120,"limit_minutes":90},
 {"id":"post_blocked:r:7","kind":"review_post_blocked","pr":7,"ts":"$(iso_ago 600)","reason":"<!channel>"}]
EOF
record
incidents
assert_jq 'length == 3 and (map(.kind) | sort) == ["github_unavailable","heartbeat_gap","review_post_blocked"]' 'one incident per condition; a recovery notice is none'
assert_jq '(.[] | select(.kind == "github_unavailable") | .open == true and .end == null and .detail == {"count": 2, "errors": {"auth": 2}})
  and (.[] | select(.kind == "review_post_blocked") | .open == false and .detail == {"pr": 7})' 'an outage is open; a refused post is a closed point'
OUT="$(cat "$WORK/health/incidents.jsonl")"
assert_out_absent 'channel' 'the reason text is not kept'
echo '[]' > "$SANDBOX/cond.json"
record
incidents
assert_jq 'all(.[]; .open == false) and (.[] | select(.kind == "heartbeat_gap") | .end != null)' 'a condition that cleared closes its incident'

# --- the service status ------------------------------------------------------------------------
h_case h_status '- work_repo: acme/widgets-state'
ev 60 review info precheck "review gate: nothing to do"
cat > "$SANDBOX/cond.json" <<EOF
[{"id":"model:a","kind":"model_unavailable","first":"$(iso_ago 900)","last":"$(iso_ago 300)","open":true},
 {"id":"github:a","kind":"github_unavailable","first":"$(iso_ago 900)","last":"$(iso_ago 300)","open":true},
 {"id":"heartbeat:a","kind":"heartbeat_gap","last":"$(iso_ago 7200)"},
 {"id":"harness:hooks","kind":"harness_drift","parts":["hooks"]},
 {"id":"backup:a","kind":"backup_failing","first":"$(iso_ago 30000)"}]
EOF
HB_LAST="2026-10-12T08:00:00Z" henv bash "$HEALTH" record "$SANDBOX/cond.json" >/dev/null 2>>"$STDERR_LOG"
status
assert_jq '[.services[] | "\(.key)=\(.state)"] == ["platform=down","harness=warn","model=down","github=down","classifier=ok","backup=down","slack=na"]' 'each condition sets its service'
assert_jq '.sig == "platform=down,harness=warn,model=down,github=down,classifier=ok,backup=down,slack=na"' 'the signature names every state'
assert_jq '.services[0].note | contains("2026-10-12T08:00:00Z")' 'the platform note names the last review-gate tick'
h_case h_status_quiet
ev 60 review info precheck "review gate: nothing to do"
ev 600 session error api_failure "server_error: 503"
record
status
assert_jq '[.services[] | "\(.key)=\(.state)"] == ["platform=ok","harness=ok","model=warn","github=ok","classifier=ok","backup=na","slack=na"]' 'a recent failure under the threshold is a warning; no work_repo is not used'
h_case h_status_direct '- monitor_slack_direct: enabled'
record
status
assert_jq '.services[] | select(.key == "slack") | .state == "warn" and (.note | contains("slack_notifications is not enabled"))' 'an opt-in that cannot send is a warning with its reason'

# --- the dashboard -------------------------------------------------------------------------------
h_case h_report '- bot_display_name: <script>x</script>'
ev "$AGO" review info precheck "review gate: nothing to do"
ev 60 review info precheck "review gate: nothing to do"
mkdir -p "$WORK/health"
jq -nc --argjson e "$(( $(date -u +%s) - 3 * 86400 ))" '{h: ($e | strftime("%Y-%m-%dT%H")), gate: {review: 12}}' > "$WORK/health/hours.jsonl"
record
henv bash "$HEALTH" report > "$SANDBOX/page.html" 2>>"$STDERR_LOG"
P="$SANDBOX/page.html"
has "$P" '<title>Agent health</title>' 'a full page'
has "$P" '&lt;script&gt;x&lt;/script&gt; — health' 'the display name is escaped'
lacks "$P" '<script>x' 'and never raw'
has "$P" 'class="tile ok"' 'the status tiles'
has "$P" 'Last 7 days, per hour' 'the hourly charts'
has "$P" '<td>no_gate_tick</td>' 'hours with no gate tick are an incident of their own'
lacks "$P" 'https?://' 'no external asset'
h_case h_report_default_name
grep -v 'bot_display_name' "$WORK/CONFIG.md" > "$SANDBOX/config.md" && mv "$SANDBOX/config.md" "$WORK/CONFIG.md"
record
henv bash "$HEALTH" report > "$SANDBOX/page.html" 2>>"$STDERR_LOG"
has "$SANDBOX/page.html" '<h1>Code Guardian — health</h1>' 'a missing display name reads as the documented default'

# --- publish: create once, then update in place ----------------------------------------------------
h_case h_publish '- health_dashboard: dam'
ev 60 review info precheck "review gate: nothing to do"
record
health due && check_eq due due 'never published: due' || check_eq "not due" due 'never published: due'
jq -nc '{content: [{type: "text", text: ([
    {name: "code-guardian-review", spec: {enabled: true}, status: {lastResult: "success", lastRun: "2026-10-12T08:00:00.000Z",
      lastPrecheckError: "token ghp_abcdefghijklmnopqrstuvwxyz0123456789 <b>x</b> on acme/widgets", precheckFailedCount: 2}},
    {name: "<img src=x onerror=alert(1)>", spec: {enabled: false}, status: {lastResult: "precheck exited 2: see acme/widgets"}}] | tojson)}]}' \
  > "$SANDBOX/mcp/list_schedules.json"
echo '{"content":[{"type":"text","text":"{\"id\":\"art-1\",\"shareUrl\":\"https://dam.example.test/a/s1\"}"}]}' > "$SANDBOX/mcp/create_artifact.json"
health publish
assert_jq '.status == "published" and .id == "art-1" and .share_url == "https://dam.example.test/a/s1"' 'the first publish creates the artifact'
check_eq "$(jq -rs '[.[] | select(.params.name == "create_artifact")][0].params.arguments | "\(.title)|\(.type)|\(.visibility)|\(.file_name)"' "$SANDBOX/mcp.log")" \
  'Guardian health|html|public|health.html' 'with its title, type and visibility'
jq -rs '[.[] | select(.params.name == "create_artifact")][0].params.arguments.content' "$SANDBOX/mcp.log" > "$SANDBOX/sent.html"
has "$SANDBOX/sent.html" '<td>code-guardian-review</td><td>true</td><td>2026-10-12T08:00:00.000Z</td><td>success</td><td class="n">0</td><td class="n">2</td><td>yes</td>' 'the schedules table: name, state, a result class and counts'
has "$SANDBOX/sent.html" '<td>(other)</td><td>false</td><td>—</td><td>failed</td>' 'a name outside its pattern and a failed result class'
lacks "$SANDBOX/sent.html" 'ghp_|<b>x|acme/widgets|onerror|precheck exited' 'DAM text never reaches the page'
OUT="$(cat "$WORK/health/state.json")"
assert_jq '.artifact_id == "art-1" and .share_url == "https://dam.example.test/a/s1" and .status_sig != null' 'the id, the URL and the status are kept'
health due && check_eq due "not due" 'just published, same status: not due' || check_eq "not due" "not due" 'just published, same status: not due'
jq '.status_sig = "platform=down"' "$WORK/health/state.json" > "$WORK/s.json" && mv "$WORK/s.json" "$WORK/health/state.json"
health due && check_eq due due 'a status change: due' || check_eq "not due" due 'a status change: due'
jq --arg t "$(iso_ago 11000)" '.published_at = $t | .status_sig = "x"' "$WORK/health/state.json" > "$WORK/s.json" && mv "$WORK/s.json" "$WORK/health/state.json"
record
jq --arg s "$(jq -r .sig "$WORK/health/status.json")" '.status_sig = $s' "$WORK/health/state.json" > "$WORK/s.json" && mv "$WORK/s.json" "$WORK/health/state.json"
health due && check_eq due due 'three hours old: due' || check_eq "not due" due 'three hours old: due'
echo '{"content":[{"type":"text","text":"{\"id\":\"art-1\",\"shareUrl\":\"https://dam.example.test/a/s1\"}"}]}' > "$SANDBOX/mcp/update_artifact.json"
health publish
assert_jq '.status == "published"' 'the next publish updates'
check_eq "$(calls create_artifact),$(calls update_artifact)" '1,1' 'in place, with no second artifact'
check_eq "$(jq -rs '[.[] | select(.params.name == "update_artifact")][0].params.arguments.id' "$SANDBOX/mcp.log")" 'art-1' 'by the kept id'

h_case h_publish_refused '- health_dashboard: dam'
record
mkdir -p "$WORK/health"; echo '{"artifact_id":"art-1","share_url":"https://dam.example.test/a/s1"}' > "$WORK/health/state.json"
echo '{"isError":true,"content":[{"type":"text","text":"content too large"}]}' > "$SANDBOX/mcp/update_artifact.json"
health publish
assert_jq '.status == "failed" and (.reason | test("too large"))' 'any refusal but not found fails the publish'
check_eq "$(calls create_artifact)" 0 'and never creates a second public artifact'
OUT="$(cat "$WORK/health/state.json")"
assert_jq '.artifact_id == "art-1" and .share_url == "https://dam.example.test/a/s1" and .last_attempt != null and (.last_error | test("too large"))' 'the kept id and URL stay; the attempt is recorded'
health due && check_eq due "not due" 'a failed attempt backs off 30 min' || check_eq "not due" "not due" 'a failed attempt backs off 30 min'
h_case h_publish_empty_state '- health_dashboard: dam'
record
mkdir -p "$WORK/health"; : > "$WORK/health/state.json"
echo '{"content":[{"type":"text","text":"{\"id\":\"art-9\",\"shareUrl\":\"https://dam.example.test/a/s9\"}"}]}' > "$SANDBOX/mcp/create_artifact.json"
health publish
assert_jq '.status == "published" and .id == "art-9"' 'an empty state file publishes a new artifact'
OUT="$(cat "$WORK/health/state.json")"
assert_jq '.artifact_id == "art-9"' 'and records it'

h_case h_publish_gone '- health_dashboard: dam'
record
mkdir -p "$WORK/health"; echo '{"artifact_id":"art-old","share_url":"https://dam.example.test/a/old"}' > "$WORK/health/state.json"
echo '{"isError":true,"content":[{"type":"text","text":"artifact not found"}]}' > "$SANDBOX/mcp/update_artifact.json"
echo '{"content":[{"type":"text","text":"{\"id\":\"art-2\",\"shareUrl\":\"https://dam.example.test/a/s2\"}"}]}' > "$SANDBOX/mcp/create_artifact.json"
health publish
assert_jq '.status == "published" and .id == "art-2"' 'a refused update (the artifact was deleted) creates a new one'
h_case h_publish_down '- health_dashboard: dam'
record
mkdir -p "$WORK/health"; echo '{"artifact_id":"art-1"}' > "$WORK/health/state.json"
touch "$SANDBOX/mcp/fail"
health publish
assert_jq '.status == "failed" and .reason == "transport failure"' 'an unreachable endpoint fails the publish'
check_eq "$(calls create_artifact)" 0 'and never creates a duplicate'
h_case h_publish_off
record
health due && check_eq due "not due" 'health_dashboard missing: never due' || check_eq "not due" "not due" 'health_dashboard missing: never due'

# --- the monitor tick drives it ---------------------------------------------------------------------
h_case h_tick '- health_dashboard: dam'
ev 60 review info precheck "review gate: nothing to do"
echo '{"content":[{"type":"text","text":"{\"id\":\"art-1\",\"shareUrl\":\"https://dam.example.test/a/s1\"}"}]}' > "$SANDBOX/mcp/create_artifact.json"
OUT="$(henv bash "$REPO_ROOT/scripts/monitor.sh" 2>>"$STDERR_LOG")"
assert_jq '.nothing_to_do == true and .config.health_dashboard == "dam"' 'an idle tick stays idle'
check_eq "$(calls create_artifact)" 1 'and publishes the dashboard'
assert_file_contains "$WORK/logs/events-$(date -u +%Y-%m-%d).jsonl" '"event":"health","msg":"dashboard published → DAM art-1"' 'the publish is logged'
OUT="$(henv bash "$REPO_ROOT/scripts/monitor.sh" 2>>"$STDERR_LOG")"
check_eq "$(calls create_artifact),$(calls update_artifact)" '1,0' 'the next tick with the same status does not publish again'
[ -s "$WORK/health/hours.jsonl" ] && check_eq rows rows 'every tick records the history' || check_eq none rows 'every tick records the history'

finish
