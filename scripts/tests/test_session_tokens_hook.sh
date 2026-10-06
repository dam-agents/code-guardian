#!/usr/bin/env bash
# SessionEnd hook (log-session-tokens.sh): one `tokens` event per run, summed
# over the session transcript and its subagents' transcripts, deduped by
# message id (docs/logging.md → Harness adapters).
. "$(dirname "$0")/helpers.sh"

HOOK="$REPO_ROOT/scripts/harness/claude-code/log-session-tokens.sh"

usage_line() { # <id> <input> <output> <cache_read> <cache_creation>
  jq -nc --arg id "$1" --argjson i "$2" --argjson o "$3" --argjson cr "$4" --argjson cc "$5" \
    '{type:"assistant", message:{id:$id, model:"claude-opus-5-5",
      usage:{input_tokens:$i, output_tokens:$o, cache_read_input_tokens:$cr, cache_creation_input_tokens:$cc}}}'
}
run_hook() { # <transcript>
  jq -nc --arg t "$1" '{hook_event_name:"SessionEnd", session_id:"s-tok", transcript_path:$t}' \
    | WORK_DIR="$WORK" bash "$HOOK" >/dev/null 2>&1
}
tokens_msg() { jq -r 'select(.event=="tokens") | .msg' "$EVENTS" 2>/dev/null | tail -1; }
expect_msg() { # <grep -E pattern> <description>
  if tokens_msg | grep -qE -- "$1"; then printf 'ok   %s: %s\n' "$CASE" "$2"
  else printf 'FAIL %s: %s\n     msg: %s\n' "$CASE" "$2" "$(tokens_msg)"; FAILED=1; fi
}
setup() { # <case-name>
  new_case "$1"
  base_config
  mkdir -p "$WORK/logs" "$SANDBOX/projects"
  EVENTS="$WORK/logs/events-$(date -u +%Y-%m-%d).jsonl"; : > "$EVENTS"
  TP="$SANDBOX/projects/s-tok.jsonl"
}

# --- no subagents: the main transcript alone ------------------------------------
setup tokens_main_only
{ usage_line m1 10 100 1000 500; usage_line m1 10 100 1000 500; usage_line m2 5 50 2000 0; } > "$TP"
run_hook "$TP"
expect_msg '^input=15 output=150 cache_read=3000 cache_creation=500 msgs=2 model=claude-opus-5-5 subagents=0$' \
  'main transcript summed and deduped, subagents=0, no sub_tokens'

# --- subagents: summed into the totals, their share appended --------------------
setup tokens_with_subagents
{ usage_line m1 10 100 1000 500; usage_line m2 5 50 2000 0; } > "$TP"
mkdir -p "${TP%.jsonl}/subagents"
usage_line a1 1 10 100 50 > "${TP%.jsonl}/subagents/agent-a1.jsonl"
# a2 repeats the parent's m2 (a layout that embeds usage twice) — counted once,
# on the main side
{ usage_line a2 2 20 200 70; usage_line m2 5 50 2000 0; } > "${TP%.jsonl}/subagents/agent-a2.jsonl"
echo '{"agentType":"review-skill"}' > "${TP%.jsonl}/subagents/agent-a1.meta.json"
run_hook "$TP"
expect_msg '^input=18 output=180 cache_read=3300 cache_creation=620 msgs=4 model=claude-opus-5-5 ' \
  'totals include both subagents, a repeated message id once'
expect_msg ' subagents=2 sub_tokens=in:3,out:30,cr:300,cw:120$' \
  'subagent count and share appended (meta files ignored, shared message on the main side)'

# --- the audit's capture still reads the event -----------------------------------
# preflight.sh audit (TOKENS_WEEK) captures the leading fields; the appended
# ones must not shift what it reads
if tokens_msg | jq -Re 'capture("input=(?<i>[0-9]+) output=(?<o>[0-9]+) cache_read=(?<cr>[0-9]+) cache_creation=(?<cc>[0-9]+)( +msgs=[0-9]+)?( +model=(?<m>[^ ]+))?")
     | .i == "18" and .o == "180" and .m == "claude-opus-5-5"' >/dev/null 2>&1 \
   && [ "$(tokens_msg | jq -Rr 'capture("output=(?<o>[0-9]+)").o')" = 180 ]; then
  printf 'ok   %s: audit captures read the totals and the model\n' "$CASE"
else
  printf 'FAIL %s: audit capture misreads the extended msg: %s\n' "$CASE" "$(tokens_msg)"; FAILED=1
fi

# --- not a deployed instance: no event --------------------------------------------
setup tokens_no_config
rm -f "$WORK/CONFIG.md"
usage_line m1 1 1 1 1 > "$TP"
run_hook "$TP"
if [ ! -s "$EVENTS" ]; then printf 'ok   %s: no CONFIG.md, no event\n' "$CASE"
else printf 'FAIL %s: event written without CONFIG.md\n' "$CASE"; FAILED=1; fi

finish
