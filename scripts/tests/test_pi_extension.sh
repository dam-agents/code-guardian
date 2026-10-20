#!/usr/bin/env bash
# pi extension (scripts/harness/pi/extension.ts, docs/harness-pi.md → Adapter):
# loads the TypeScript file in Node (type stripping, Node >= 22.6) against a
# fake pi API, with the Claude Code hook scripts replaced by stubs that record
# their payloads, and checks each event's mapping, the stop continuation and
# the fail-open path. Without a Node that strips types the case reports a skip;
# CI installs one (.github/workflows/ci.yml).
. "$(dirname "$0")/helpers.sh"

NODE="${CG_TEST_NODE:-node}"
node_flags() { # prints the flag Node needs for .ts, or fails when it cannot run it
  local v major minor
  v="$("$NODE" --version 2>/dev/null)" || return 1
  v="${v#v}"; major="${v%%.*}"; minor="${v#*.}"; minor="${minor%%.*}"
  if [ "$major" -ge 23 ] 2>/dev/null; then printf '%s' "--no-warnings"
  elif [ "$major" -eq 22 ] && [ "$minor" -ge 6 ] 2>/dev/null; then printf '%s' "--experimental-strip-types --no-warnings"
  else return 1; fi
}

new_case pi_extension_events
if ! FLAGS="$(node_flags)"; then
  printf 'ok   %s: skipped — no Node >= 22.6 to load TypeScript (CI has one)\n' "$CASE"
  finish
fi

DEF="$SANDBOX/def"; CALLS="$SANDBOX/calls"; mkdir -p "$DEF/scripts/harness/pi" "$DEF/scripts/harness/claude-code" "$CALLS"
cp "$REPO_ROOT/scripts/harness/pi/extension.ts" "$DEF/scripts/harness/pi/"
# each stub records its payload and answers as STUB_<NAME> says: "<exit> <stderr>" or "sleep"
for s in guard-definition-issue log-tool-event log-review-step enforce-review-completion log-api-failure log-session-tokens; do
  cat > "$DEF/scripts/harness/claude-code/$s.sh" <<EOF
#!/usr/bin/env bash
cat > "$CALLS/$s.\$\$.json"
v="\${STUB_$(printf '%s' "$s" | tr 'a-z-' 'A-Z_'):-0}"
[ "\$v" = sleep ] && exec sleep 5
printf '%s' "\${v#* }" >&2
exit "\${v%% *}"
EOF
done
printf 'logev() { printf "%%s %%s %%s\\n" "$1" "$2" "$3" >> "%s/events"; }\n' "$CALLS" > "$DEF/scripts/log.sh"

cat > "$SANDBOX/driver.mjs" <<'EOF'
const ext = await import(process.argv[2]);
const handlers = {};
ext.default({ on: (name, fn) => { handlers[name] = fn; } });
const ctx = { sessionManager: { getSessionId: () => "sess-1", getSessionFile: () => "/tmp/sess-1.jsonl" } };
const fire = (name, event) => handlers[name] ? handlers[name](event, ctx) : undefined;
const out = {};
const step = process.argv[3];
if (step === "guard") out.r = await fire("tool_call", { type: "tool_call", toolName: "bash", input: { command: "gh issue create -R acme/def" } });
if (step === "read") out.r = await fire("tool_call", { type: "tool_call", toolName: "read", input: { path: "/x" } });
if (step === "fail") out.r = await fire("tool_result", { toolName: "bash", input: { command: "cat /nope" }, content: [{ type: "text", text: "No such file" }], isError: true });
if (step === "bash") out.r = await fire("tool_result", { toolName: "bash", input: { command: "echo hi" }, content: [{ type: "text", text: "hi" }], isError: false });
if (step === "stop") out.r = await fire("agent_before_settle", { outcome: "completed", continue: false, entries: [], context: { contextMessages: [] } });
if (step.startsWith("error:")) out.r = await fire("agent_before_settle", { outcome: "error", continue: false, entries: [], context: { contextMessages: [{ role: "assistant", stopReason: "error", errorMessage: step.slice(6) }] } });
if (step === "shutdown") out.r = await fire("session_shutdown", { reason: "quit" });
console.log(JSON.stringify(out.r ?? null));
EOF
drive() { # <step> [env…] — the handler's return value in $OUT
  OUT="$(env "${@:2}" "$NODE" $FLAGS "$SANDBOX/driver.mjs" "$DEF/scripts/harness/pi/extension.ts" "$1" 2>"$STDERR_LOG")"
}
payload() { cat "$CALLS"/"$1".*.json 2>/dev/null | tail -1; }
clear_calls() { rm -f "$CALLS"/*.json "$CALLS/events"; }

drive guard STUB_GUARD_DEFINITION_ISSUE="2 use definition-issue.sh"
assert_jq '.block == true and .reason == "use definition-issue.sh"' 'a guard exit 2 blocks the bash call with its reason'
OUT="$(payload guard-definition-issue)"
assert_jq '.tool_name == "Bash" and .tool_input.command == "gh issue create -R acme/def" and .session_id == "sess-1"' 'the guard gets the Claude Code PreToolUse payload'
clear_calls
drive read
[ -z "$(payload guard-definition-issue)" ] && printf 'ok   %s: a non-bash call skips the guard\n' "$CASE" \
  || { printf 'FAIL %s: the guard ran for read\n' "$CASE"; FAILED=1; }
drive guard STUB_GUARD_DEFINITION_ISSUE=sleep CG_PI_HOOK_TIMEOUT_MS=300
assert_jq '. == null' 'a guard that times out lets the call through (fail open)'
if grep -q '^warn adapter_failure guard-definition-issue.sh timed out' "$CALLS/events" 2>/dev/null; then
  printf 'ok   %s: the timed-out guard logs one adapter_failure warn\n' "$CASE"
else printf 'FAIL %s: no adapter_failure event: %s\n' "$CASE" "$(cat "$CALLS/events" 2>/dev/null)"; FAILED=1; fi
clear_calls
drive fail
OUT="$(payload log-tool-event)"
assert_jq '.hook_event_name == "PostToolUseFailure" and .tool_name == "Bash" and .error == "No such file"' 'a failed tool result is a PostToolUseFailure'
drive bash
OUT="$(payload log-review-step)"
assert_jq '.hook_event_name == "PostToolUse" and .transcript_path == "/tmp/sess-1.jsonl" and .tool_response.stdout == "hi"' 'a bash result feeds the review-step hook'
drive stop STUB_ENFORCE_REVIEW_COMPLETION="2 finish PR #7"
assert_jq '.continue == true and .entries[0].type == "custom_message" and .entries[0].content == "finish PR #7"' 'a blocked stop continues the run with the reason'
drive stop
assert_jq '. == null' 'a stop the hook lets through settles'
drive "error:429 Too Many Requests"
OUT="$(payload log-api-failure)"
assert_jq '.error == "rate_limit" and .error_details == "429 Too Many Requests"' 'an API error run logs its class'
clear_calls
drive "error:ExpiredTokenException: The security token included in the request is expired (403)"
OUT="$(payload log-api-failure)"
assert_jq '.error == "cloud_credential_error"' 'a cloud credential error keeps its class before a plain 403'
clear_calls
drive "error:403 OAuth authentication is currently not allowed for this organization"
OUT="$(payload log-api-failure)"
assert_jq '.error == "oauth_org_not_allowed"' 'an OAuth organization refusal keeps its class before a plain 403'
clear_calls
drive "error:403 Your account is on hold"
OUT="$(payload log-api-failure)"
assert_jq '.error == "account_on_hold"' 'an account on hold keeps its class before a plain 403'
drive shutdown
OUT="$(payload log-session-tokens)"
assert_jq '.session_id == "sess-1" and .transcript_path == "/tmp/sess-1.jsonl"' 'session end writes the tokens event'
clear_calls
drive bash CG_PI_PARENT_SESSION=parent-9
drive guard CG_PI_PARENT_SESSION=parent-9
[ -z "$(payload log-review-step)" ] && printf 'ok   %s: a nested session logs no review steps\n' "$CASE" \
  || { printf 'FAIL %s: a nested session ran the review-step hook\n' "$CASE"; FAILED=1; }
OUT="$(payload guard-definition-issue)"
assert_jq '.session_id == "parent-9"' 'a nested session runs under its parent run id'

finish
