#!/usr/bin/env bash
# monitor-direct.sh and the monitor's direct delivery: the exact text of every
# template, the type checks that keep any outside text out of a message, the
# opt-in and roster gates, the daily cap, the MCP call itself, and the tick
# that sends, acknowledges and starts no session — or fails and leaves the
# alerts to the session. Contract: docs/monitor.md → Direct delivery.
. "$(dirname "$0")/helpers.sh"

MCP_URL="http://mcp.test/api/agents/a1/mcp"
DIRECT="$REPO_ROOT/scripts/monitor-direct.sh"

ev() { # <secs-ago> <job> <level> <event> <msg> [run]
  mkdir -p "$WORK/logs"
  jq -nc --arg ts "$(iso_ago "$1")" --arg job "$2" --arg lv "$3" --arg e "$4" --arg m "$5" --arg r "${6:-r1}" \
    '{ts:$ts, run:$r, job:$job, level:$lv, event:$e, msg:$m}' >> "$WORK/logs/events-$(date -u +%Y-%m-%d).jsonl"
}
fail_ev() { ev "$1" session error api_failure "${2:-server_error}: 503 <!channel> see https://evil.test" "r$1"; }

# a case with the opt-in, Slack, a roster and the escalation owner; extra CONFIG lines pass through
direct_case() { # <case> [config lines…]
  new_case "$1"; shift
  # cfg reads the first line of a key, so a case's own lines come first
  base_config "$@" '- slack_notifications: enabled' '- monitor_slack_direct: enabled' '- escalation_owner: alice' \
    '- bot_display_name: Guardian'
  printf '| login | slack_id |\n|---|---|\n| alice | U0123ABCD |\n| bob | U0456EFGH |\n' > "$WORK/DEVELOPERS.md"
  mkdir -p "$WORK/logs" "$SANDBOX/mcp"
  printf '{"mcpServers":{"platform-outbound":{"type":"http","url":"%s"}}}\n' "$MCP_URL" > "$FAKE_HOME/.mcp.json"
  : > "$SANDBOX/mcp.log"
  ev 60 review info precheck "review gate: nothing to do"
}
mcp_env() { env CURL_MCP_URL="$MCP_URL" CURL_MCP_LOG="$SANDBOX/mcp.log" CURL_MCP_DIR="$SANDBOX/mcp" \
  WORK_DIR="$WORK" HOME="$FAKE_HOME" TMPDIR="$SANDBOX" PATH="$T_DIR/bin:$PATH" "$@"; }
direct() { OUT="$(mcp_env bash "$DIRECT" "$@" 2>>"$STDERR_LOG")"; }
monitor() { OUT="$(mcp_env bash "$REPO_ROOT/scripts/monitor.sh" "$@" 2>>"$STDERR_LOG")"; }
calls() { jq -s --arg t "${1:-send_channel_message}" '[.[] | select(.method == "tools/call" and .params.name == $t)] | length' "$SANDBOX/mcp.log"; }
sent_text() { jq -rs '[.[] | select(.params.name == "send_channel_message")] | last | .params.arguments.text' "$SANDBOX/mcp.log"; }
check_eq() { # <actual> <expected> <description>
  if [ "$1" = "$2" ]; then printf 'ok   %s: %s\n' "$CASE" "$3"
  else printf 'FAIL %s: %s\n     got:  %s\n     want: %s\n' "$CASE" "$3" "$1" "$2"; FAILED=1; fi
}
alerts() { cat > "$SANDBOX/alerts.json"; }

# --- the exact text of every template ---------------------------------------------
direct_case dir_golden
alerts <<'EOF'
[{"id":"model:2026-10-12T08:00:01.123Z","kind":"model_unavailable","first":"2026-10-12T08:00:01.123Z","last":"2026-10-12T08:40:00Z","count":3,"runs":2,"errors":{"server_error":2,"overloaded":1},"open":true,"sample":"503 upstream"},
 {"id":"model:2026-10-11T08:00:00Z","kind":"model_unavailable","first":"2026-10-11T08:00:00Z","last":"2026-10-11T08:20:00Z","count":2,"runs":2,"errors":{"authentication_failed":2},"open":false},
 {"id":"model:2026-10-10T08:00:00Z:recovered","kind":"model_recovered","needs":"model:2026-10-10T08:00:00Z","first":"2026-10-10T08:00:00Z","last":"2026-10-10T08:30:00Z","count":2,"runs":1,"errors":{"rate_limit":2},"open":false},
 {"id":"github:2026-10-12T08:05:00Z","kind":"github_unavailable","first":"2026-10-12T08:05:00Z","last":"2026-10-12T08:15:00Z","count":2,"errors":{"auth":2},"open":true},
 {"id":"github:2026-10-11T07:00:00Z:recovered","kind":"github_recovered","needs":"github:2026-10-11T07:00:00Z","first":"2026-10-11T07:00:00Z","last":"2026-10-11T07:30:00Z","over_at":"2026-10-11T07:40:00Z","minutes":40,"count":3,"errors":{"network":3},"open":false},
 {"id":"heartbeat:2026-10-12T06:00:00Z","kind":"heartbeat_gap","last":"2026-10-12T06:00:00Z","silent_minutes":130,"limit_minutes":90},
 {"id":"harness:automode-rules+hooks","kind":"harness_drift","parts":["automode-rules","hooks"]},
 {"id":"backup:2026-10-12T01:00:00Z","kind":"backup_failing","first":"2026-10-12T01:00:00Z","failures":4,"sample":"push to acme/widgets-state failed"},
 {"id":"classifier:2026-10-12","kind":"classifier_spike","count":21,"threshold":20,"runs":4,"by_tool":{"Bash":18,"Agent":3},"top":[{"pattern":"Bash rm -rf /","count":9}]},
 {"id":"post_blocked:r9:7","kind":"review_post_blocked","pr":7,"ts":"2026-10-12T08:10:00Z","reason":"Blocked by fast classifier"}]
EOF
direct render "$SANDBOX/alerts.json"
check_eq "$(printf '%s' "$OUT" | jq -r .text)" '**Guardian monitor** — 10 alerts
• **Model API unavailable** since 2026-10-12 08:00 UTC: 3 failures in 2 runs (server_error 2, overloaded 1). The last failure was at 2026-10-12 08:40 UTC. Cause: the model provider or the gateway. The agent does the missed review work after the API recovers.
• **Model API was unavailable** from 2026-10-11 08:00 UTC to 2026-10-11 08:20 UTC: 2 failures in 2 runs (authentication_failed 2). Cause: the credentials or the account. The operator must fix them.
• **Model API available again.** The outage started at 2026-10-10 08:00 UTC. The last failure was at 2026-10-10 08:30 UTC.
• **GitHub API unavailable** since 2026-10-12 08:05 UTC: 2 gate passes in a row could not list the open PRs (auth 2). Cause: the GitHub token is not valid. The operator must replace it.
• **GitHub API available again** at 2026-10-11 07:40 UTC, after 40 min.
• **Review gate silent:** no tick since 2026-10-12 06:00 UTC (130 min, limit 90 min). Do this: make sure that the review schedule is enabled and that its gate can start.
• **Harness adapter not current:** automode-rules, hooks. Do this: run `bash "$HOME/scripts/harness/claude-code/install.sh"`. The change applies from the next session.
• **Work backup failing:** 4 failed pushes since 2026-10-12 01:00 UTC. Do this: examine the access to the work repository.
• **Classifier refusals:** 21 in 24 h (threshold 20) in 4 runs. Tools: Bash 18, Agent 3. The events log has the patterns (event classifier_block).
• **Review post refused:** the classifier refused the review post of PR #7 at 2026-10-12 08:10 UTC. No later post of that PR exists. Do this: post the review again in a session, or add the missing auto-mode rule.' 'every template renders its exact text'
assert_jq '(.ids | length) == 10 and .skipped == []' 'every id is covered'
assert_out_absent 'upstream|acme/widgets-state|rm -rf|fast classifier' 'no free text of an alert reaches the message'

# --- the operator-action templates ------------------------------------------------
direct_case dir_golden_operator
alerts <<'JSON'
[{"id":"dispatch:2026-10-15T14:52:00Z","kind":"dispatch_refused","first":"2026-10-15T14:52:00Z","last":"2026-10-15T16:00:00Z","count":12,"runs":9,"prs":14},
 {"id":"gh_write:2026-10-13","kind":"github_write_denied","first":"2026-10-13T12:00:00Z","last":"2026-10-13T20:00:00Z","count":413,"by_event":{"progress_status":412,"post_failed":1}},
 {"id":"identity:2026-10-14T14:08:21Z","kind":"github_identity_changed","changed_at":"2026-10-14T14:08:21Z","login":"new-app[bot]","token_kind":"app","previous":"old-app[bot]","previous_kind":"app"}]
JSON
direct render "$SANDBOX/alerts.json"
check_eq "$(printf '%s' "$OUT" | jq -r .text)" '**Guardian monitor** — 3 alerts
• **Review dispatch refused** since 2026-10-15 14:52 UTC: the platform refused 12 dispatches in 9 runs (14 PRs). Each run keeps its PRs and reviews them one after another. Do this: read the reason in the events log (event dispatch_refused) and correct the platform setting.
• **GitHub refused a call** 413 times in 24 h with HTTP 403 (progress_status 412, post_failed 1). Cause: the token has no permission for the call. Do this: run `bash "$HOME/scripts/github-access.sh"` in the direct session and give the token the missing permission.
• **GitHub token changed** at 2026-10-14 14:08 UTC: the token now acts as a different app account. Do this: run `bash "$HOME/scripts/github-access.sh"` in the direct session.' 'the operator-action templates render their exact text'
assert_out_absent 'new-app|old-app' 'no login reaches the message'

direct_case dir_golden_judge
alerts <<'JSON'
[{"id":"judge:claude-opus-5","kind":"judge_unavailable","model":"claude-opus-5","cause":"not_signed_in","reason":"the '/opt/bin/claude' CLI on this host is not signed in"},
 {"id":"judge:x","kind":"judge_unavailable","model":"x","cause":"no_cli","reason":"no 'claude' CLI on this host"},
 {"id":"judge:y","kind":"judge_unavailable","model":"y","cause":"see https://evil.test"}]
JSON
direct render "$SANDBOX/alerts.json"
check_eq "$(printf '%s' "$OUT" | jq -r .text)" '**Guardian monitor** — 2 alerts
• **Benchmark judge unavailable:** the claude CLI on the host is not signed in, and the host has no pi CLI. The benchmark runs score without the judge until you fix it. Do this: run `claude auth login` on the host once, or set ANTHROPIC_API_KEY.
• **Benchmark judge unavailable:** the host has no claude CLI and no pi CLI. The benchmark runs score without the judge until you fix it. Do this: install the claude CLI on the host.' 'the judge template renders its exact text'
assert_jq '.skipped == ["judge:y"]' 'an unknown cause is skipped'
assert_out_absent '/opt/bin' 'the free-text reason never reaches the message'

# --- a value outside its type skips the alert, never reaches the text ---------------
direct_case dir_injection
alerts <<'EOF'
[{"id":"a1","kind":"github_unavailable","first":"2026-10-12T08:05:00Z <!channel>","last":"2026-10-12T08:15:00Z","count":2,"errors":{"auth":2},"open":true},
 {"id":"a2","kind":"model_unavailable","first":"2026-10-12T08:00:00Z","last":"2026-10-12T08:40:00Z","count":3,"runs":2,"errors":{"<@U0123ABCD>":3},"open":true},
 {"id":"a3","kind":"harness_drift","parts":["hooks","see https://evil.test"]},
 {"id":"a4","kind":"review_post_blocked","pr":"7 @here","ts":"2026-10-12T08:10:00Z"},
 {"id":"a5","kind":"heartbeat_gap","last":"2026-10-12T06:00:00Z","silent_minutes":-5,"limit_minutes":90},
 {"id":"a6","kind":"backup_failing","first":"2026-10-12T01:00:00Z","failures":1.5},
 {"id":"a7","kind":"github_recovered","over_at":"2026-10-11T07:40:00Z","minutes":"40"},
 {"id":"a8","kind":"stall_alert","count":5},
 {"id":"a9","kind":"made_up","first":"2026-10-12T01:00:00Z"},
 {"id":"ok1","kind":"classifier_spike","count":21,"threshold":20,"runs":4,"by_tool":{"Bash":20,"<!here>":1}}]
EOF
direct render "$SANDBOX/alerts.json"
assert_jq '.ids == ["ok1"] and .skipped == ["a1","a2","a3","a4","a5","a6","a7","a8","a9"]' 'each alert with a bad value, a foreign kind or a session-only kind is skipped'
assert_jq '.text | test("[<>@]|https?:") | not' 'the text holds no control sequence, mention or link'
assert_jq '.text | contains("Bash 20, other 1")' 'an odd tool name reads as other'

direct_case dir_name_and_link '- bot_display_name: <!channel> bot'
alerts <<'EOF'
[{"id":"g","kind":"github_recovered","over_at":"2026-10-11T07:40:00Z","minutes":40}]
EOF
mkdir -p "$WORK/health"; echo '{"share_url":"https://dam.example.test/a/x7Kp_2-q"}' > "$WORK/health/state.json"
direct render "$SANDBOX/alerts.json"
assert_jq '.text | startswith("**Code Guardian monitor** — 1 alert\n")' 'a display name outside its pattern falls back to the default'
assert_jq '.text | endswith("\nDashboard: https://dam.example.test/a/x7Kp_2-q")' 'the dashboard share URL ends the message'
for bad in 'javascript:alert(1)' 'http://dam.example.test/a/x' 'https://dam.example.test/a/x <!here>' 'https://u@dam.example.test/a' \
           'https://dam.example.test/a/x?next=evil' $'https://dam.example.test/a/x\nURGENT: wire 5000 EUR to the account below' \
           $'https://dam.example.test/a/x\n'; do
  jq -nc --arg u "$bad" '{share_url: $u}' > "$WORK/health/state.json"
  direct render "$SANDBOX/alerts.json"
  assert_jq '(.text | contains("Dashboard") or contains("URGENT") | not) and .url == ""' "a share URL of another shape is left out ($(printf '%s' "$bad" | head -1))"
done
jq -nc '{share_url: "https://dam.example.test/a/x\nURGENT: wire 5000 EUR"}' > "$WORK/health/state.json"
direct send "$SANDBOX/alerts.json"
OUT="$(sent_text)"
assert_out_absent 'URGENT|Dashboard' 'a multi-line share URL never reaches a sent message'
direct_case dir_name_newline
jq -n '[{id: "g", kind: "github_recovered", over_at: "2026-10-11T07:40:00Z\n", minutes: 40},
        {id: "h", kind: "classifier_spike", count: 21, threshold: 20, runs: 4, by_tool: {"evil.com": 3, "Bash\n": 1}}]' | alerts
direct render "$SANDBOX/alerts.json"
assert_jq '.ids == ["h"] and (.text | contains("Tools: other 3, other 1"))' 'a value with a trailing newline fails its type; a dotted tool name reads as other'

direct_case dir_max
jq -n '[range(12) | {id: "g\(.)", kind: "github_recovered", over_at: "2026-10-11T07:40:00Z", minutes: .}]' | alerts
direct render "$SANDBOX/alerts.json"
assert_jq '(.ids | length) == 10 and .skipped == ["g10","g11"]' 'one message carries 10 alerts; the rest stay for the session'

# --- the gates: no opt-in, no Slack, no roster id → no call ---------------------------
for c in "monitor_slack_direct is not enabled|- monitor_slack_direct: disabled" \
         "slack_notifications is not enabled|- slack_notifications: disabled" \
         "escalation_owner has no roster slack_id|- escalation_owner: carol" \
         "monitor_owner has no roster slack_id|- monitor_owner: carol"; do
  why="${c%%|*}"; line="${c#*|}"
  new_case "dir_gate_${why%% *}"
  base_config "$line" '- slack_notifications: enabled' '- monitor_slack_direct: enabled' '- escalation_owner: alice'
  printf '| login | slack_id |\n|---|---|\n| alice | U0123ABCD |\n' > "$WORK/DEVELOPERS.md"
  printf '{"mcpServers":{"platform-outbound":{"type":"http","url":"%s"}}}\n' "$MCP_URL" > "$FAKE_HOME/.mcp.json"
  mkdir -p "$SANDBOX/mcp"; : > "$SANDBOX/mcp.log"
  echo '[{"id":"g","kind":"github_recovered","over_at":"2026-10-11T07:40:00Z","minutes":40}]' | alerts
  direct send "$SANDBOX/alerts.json"
  assert_jq '.status == "off" and .reason == "'"$why"'"' "off: $why"
  check_eq "$(calls)" 0 'and no call reached the endpoint'
done
direct_case dir_gate_bad_id
printf '| login | slack_id |\n|---|---|\n| alice | <!channel> |\n' > "$WORK/DEVELOPERS.md"
echo '[{"id":"g","kind":"github_recovered","over_at":"2026-10-11T07:40:00Z","minutes":40}]' | alerts
direct send "$SANDBOX/alerts.json"
assert_jq '.status == "off"' 'a roster slack_id outside its pattern is no target'
check_eq "$(calls)" 0 'and no call reached the endpoint'
direct ready
check_eq "$OUT" 'escalation_owner has no roster slack_id' 'ready names the same reason'

# --- the send itself ----------------------------------------------------------------------
direct_case dir_send
echo '[{"id":"g","kind":"github_recovered","over_at":"2026-10-11T07:40:00Z","minutes":40}]' | alerts
direct ready
check_eq "$OUT" '' 'ready is empty when a send can happen'
direct send "$SANDBOX/alerts.json"
assert_jq '.status == "sent" and .ids == ["g"]' 'a send reports the ids it delivered'
check_eq "$(calls)" 1 'one tools/call per send'
check_eq "$(jq -rs '[.[] | select(.params.name == "send_channel_message")][0].params.arguments | "\(.channel) \(.chatId)"' "$SANDBOX/mcp.log")" \
  'slack U0123ABCD' 'a DM to the escalation owner, never the shared channel'
check_eq "$(jq -rs '[.[] | .method] | join(",")' "$SANDBOX/mcp.log")" 'initialize,notifications/initialized,tools/call' 'the MCP handshake precedes the call'
check_eq "$(sent_text)" '**Guardian monitor** — 1 alert
• **GitHub API available again** at 2026-10-11 07:40 UTC, after 40 min.' 'the sent text is the rendered text'

direct_case dir_send_monitor_owner '- monitor_owner: bob'
echo '[{"id":"g","kind":"github_recovered","over_at":"2026-10-11T07:40:00Z","minutes":40}]' | alerts
direct send "$SANDBOX/alerts.json"
assert_jq '.status == "sent"' 'a set monitor_owner sends'
check_eq "$(jq -rs '[.[] | select(.params.name == "send_channel_message")][0].params.arguments.chatId' "$SANDBOX/mcp.log")" \
  'U0456EFGH' 'the DM goes to the monitor owner, not the escalation owner'

direct_case dir_refused
echo '{"isError":true,"content":[{"type":"text","text":"channel not found"}]}' > "$SANDBOX/mcp/send_channel_message.json"
echo '[{"id":"g","kind":"github_recovered","over_at":"2026-10-11T07:40:00Z","minutes":40}]' | alerts
direct send "$SANDBOX/alerts.json"
assert_jq '.status == "failed" and .ids == [] and (.reason | test("refused: channel not found"))' 'a refusal of the tool is a failed send'
touch "$SANDBOX/mcp/fail"
direct send "$SANDBOX/alerts.json"
assert_jq '.status == "failed" and .reason == "transport failure"' 'an unreachable endpoint is a failed send'
rm -f "$FAKE_HOME/.mcp.json"
direct send "$SANDBOX/alerts.json"
assert_jq '.status == "failed" and .reason == "no platform-outbound endpoint"' 'no endpoint configured is a failed send'

direct_case dir_server_request
echo '[{"id":"g","kind":"github_recovered","over_at":"2026-10-11T07:40:00Z","minutes":40}]' | alerts
touch "$SANDBOX/mcp/ping-send_channel_message"
echo '{"isError":true,"content":[{"type":"text","text":"channel not found"}]}' > "$SANDBOX/mcp/send_channel_message.json"
direct send "$SANDBOX/alerts.json"
assert_jq '.status == "failed" and (.reason | test("channel not found"))' 'a server request with the call id is not the answer: the refusal behind it counts'
rm -f "$SANDBOX/mcp/send_channel_message.json"
direct send "$SANDBOX/alerts.json"
assert_jq '.status == "sent"' 'and a success behind it is a send'

direct_case dir_unknown
echo '[{"id":"g","kind":"github_recovered","over_at":"2026-10-11T07:40:00Z","minutes":40}]' | alerts
touch "$SANDBOX/mcp/hang-send_channel_message"
direct send "$SANDBOX/alerts.json"
assert_jq '.status == "unknown" and .ids == ["g"] and .attempted == true' 'a call with no answer has an unknown outcome'
direct_case dir_deadline
echo '[{"id":"g","kind":"github_recovered","over_at":"2026-10-11T07:40:00Z","minutes":40}]' | alerts
OUT="$(MCP_DEADLINE=$(( $(date -u +%s) + 2 )) mcp_env bash "$DIRECT" send "$SANDBOX/alerts.json" 2>>"$STDERR_LOG")"
assert_jq '.status == "failed" and .reason == "transport failure"' 'with under 3 s to the deadline, nothing is sent'
check_eq "$(wc -l < "$SANDBOX/mcp.log" | tr -d ' ')" 0 'and no request starts'

direct_case dir_cap
now=$(date -u +%s)
jq -n --argjson n "$now" '{alerts: {}, direct: [range(12) | $n - 600 - .]}' > "$WORK/MONITOR.json"
echo '[{"id":"g","kind":"github_recovered","over_at":"2026-10-11T07:40:00Z","minutes":40}]' | alerts
direct send "$SANDBOX/alerts.json"
assert_jq '.status == "capped"' '12 direct messages in 24 h cap the next'
check_eq "$(calls)" 0 'and no call reached the endpoint'
jq -n --argjson n "$now" '{alerts: {}, direct: [range(12) | $n - 90000 - .]}' > "$WORK/MONITOR.json"
direct send "$SANDBOX/alerts.json"
assert_jq '.status == "sent"' 'messages older than 24 h do not count'

# --- the tick: send, acknowledge, no session ------------------------------------------------
direct_case dir_tick
fail_ev 600; fail_ev 300
monitor
assert_jq '.direct.status == "sent" and .alerts_due == [] and .nothing_to_do == true' 'a sent alert leaves the worklist, and nothing is left to do'
check_eq "$(calls)" 1 'one message'
assert_jq '.config.monitor_slack_direct == "enabled"' 'the worklist carries the key'
OUT="$(sent_text)"
assert_out_absent '<!channel>|evil\.test|503' 'the API error text of the events never reaches the message'
OUT="$(cat "$WORK/MONITOR.json")"
assert_jq '(.alerts | to_entries | map(select(.value.kind == "model_unavailable" and .value.sent != null)) | length) == 1 and (.direct | length) == 1' 'the alert is acknowledged, and the message counts against the cap'
monitor
check_eq "$(calls)" 1 'the next tick sends nothing again'
assert_jq '.suppressed == 1' 'it counts the alert as reported'
assert_file_contains "$WORK/logs/events-$(date -u +%Y-%m-%d).jsonl" '"event":"monitor_direct".*sent 1 alert(s) to the monitor owner: model_unavailable' 'the send is logged'

direct_case dir_tick_monitor_owner '- monitor_owner: bob'
fail_ev 600; fail_ev 300
monitor
assert_jq '.direct.status == "sent"' 'the pass sends to the monitor owner'
assert_jq '.config.monitor_owner == "bob"' 'the worklist carries the key'
check_eq "$(jq -rs '[.[] | select(.params.name == "send_channel_message")][0].params.arguments.chatId' "$SANDBOX/mcp.log")" \
  'U0456EFGH' 'and the DM goes to that owner'

direct_case dir_tick_gate
fail_ev 600; fail_ev 300
OUT=""; RC=0
OUT="$(mcp_env bash "$REPO_ROOT/scripts/precheck.sh" monitor 2>>"$STDERR_LOG")" || RC=$?
assert_rc 1 'with every alert sent, the gate starts no session'
check_eq "$(calls)" 1 'and the gate pass sent the one message'

direct_case dir_tick_fails
touch "$SANDBOX/mcp/fail-send_channel_message"
fail_ev 600; fail_ev 300
monitor
assert_jq '.direct.status == "failed" and ([.alerts_due[] | select(.kind == "model_unavailable")] | length) == 1 and .nothing_to_do == false' 'a failed send leaves the alert to the session'
assert_file_contains "$WORK/logs/events-$(date -u +%Y-%m-%d).jsonl" '"level":"error","event":"monitor_direct"' 'and logs the failure'
OUT="$(cat "$WORK/MONITOR.json")"
assert_jq '[.alerts[] | select(.sent != null)] == [] and ((.direct // []) | length) == 0' 'nothing is acknowledged'
rm -f "$SANDBOX/mcp/fail-send_channel_message"
ID="$(jq -r '.alerts | keys[0]' "$WORK/MONITOR.json")"
jq --arg id "$ID" '.alerts[$id].claimed = "2020-01-01T00:00:00Z"' "$WORK/MONITOR.json" > "$WORK/m.json" && mv "$WORK/m.json" "$WORK/MONITOR.json"
monitor
assert_jq '.direct.status == "sent"' 'after the claim expires, the next tick sends it directly'

direct_case dir_tick_unknown
touch "$SANDBOX/mcp/hang-send_channel_message"
fail_ev 600; fail_ev 300
monitor
assert_jq '.direct.status == "unknown" and .alerts_due == [] and .nothing_to_do == true' 'an unknown outcome holds the alert: no session sends it a second time'
OUT="$(cat "$WORK/MONITOR.json")"
assert_jq '[.alerts[] | select(.sent != null)] == [] and (.direct | length) == 1' 'it is not acknowledged, and the attempt counts against the cap'
rm -f "$SANDBOX/mcp/hang-send_channel_message"
monitor
check_eq "$(calls)" 1 'inside the claim, no second call'
ID="$(jq -r '.alerts | keys[0]' "$WORK/MONITOR.json")"
jq --arg id "$ID" '.alerts[$id].claimed = "2020-01-01T00:00:00Z"' "$WORK/MONITOR.json" > "$WORK/m.json" && mv "$WORK/m.json" "$WORK/MONITOR.json"
monitor
assert_jq '.direct.status == "sent"' 'after the claim, the pass sends it again'

direct_case dir_tick_refusals_capped
echo '{"isError":true,"content":[{"type":"text","text":"not_in_channel"}]}' > "$SANDBOX/mcp/send_channel_message.json"
now=$(date -u +%s)
jq -n --argjson n "$now" '{alerts: {}, direct: [range(11) | $n - 600 - .]}' > "$WORK/MONITOR.json"
fail_ev 600; fail_ev 300
monitor
assert_jq '.direct.status == "failed"' 'a refused call fails'
OUT="$(cat "$WORK/MONITOR.json")"
assert_jq '(.direct | length) == 12' 'and counts against the cap, so refusals cannot loop past it'

direct_case dir_tick_session_kinds '- stall_alert_threshold: 1'
fail_ev 600; fail_ev 300
ev 400 review warn preflight "PR #12: stale in_progress lock (locked 2026-10-12T00:00:00Z) — taken over"
monitor
assert_jq '.direct.status == "sent" and has("stall_alert") and .nothing_to_do == false' 'a stall alert still starts the session that analyses it'

direct_case dir_tick_idle
monitor
assert_jq '.nothing_to_do == true and (has("direct") | not)' 'an idle tick has no direct result'
check_eq "$(wc -l < "$SANDBOX/mcp.log" | tr -d ' ')" 0 'and makes no call at all'

direct_case dir_tick_off '- monitor_slack_direct: disabled'
fail_ev 600; fail_ev 300
monitor
assert_jq '(has("direct") | not) and ([.alerts_due[] | select(.kind == "model_unavailable")] | length) == 1' 'without the opt-in the session delivers, as before'
check_eq "$(wc -l < "$SANDBOX/mcp.log" | tr -d ' ')" 0 'and no call reaches the endpoint'

finish
