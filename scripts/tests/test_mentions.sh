#!/usr/bin/env bash
# Mention detection: @-mention pickup, ledger dedup, bot-thread replies,
# human-thread replies ignored, Bot-type authors ignored, config off switch.
. "$(dirname "$0")/helpers.sh"

# scan window start — MUST mirror preflight.sh (7 days back, day-rounded)
msince() {
  local s=$(( $(date -u +%s) - 7*86400 ))
  printf '%sT00:00:00Z' "$(date -u -d "@$s" +%Y-%m-%d 2>/dev/null || date -u -r "$s" +%Y-%m-%d)"
}
MS="$(msince)"

ic_comment() { # <id> <author> <type> <body> <issue-number>
  jq -n --argjson id "$1" --arg a "$2" --arg t "$3" --arg b "$4" --argjson n "$5" \
    '{id:$id, user:{login:$a, type:$t}, body:$b,
      created_at:"2026-08-07T09:00:00Z", html_url:("https://example.test/c/"+($id|tostring)),
      issue_url:("https://api.github.com/repos/acme/widgets/issues/"+($n|tostring))}'
}
rc_comment() { # <id> <author> <type> <body> <pr-number> <in_reply_to|null>
  jq -n --argjson id "$1" --arg a "$2" --arg t "$3" --arg b "$4" --argjson n "$5" --argjson r "$6" \
    '{id:$id, user:{login:$a, type:$t}, body:$b, in_reply_to_id:$r,
      created_at:"2026-08-07T09:05:00Z", html_url:("https://example.test/rc/"+($id|tostring)),
      pull_request_url:("https://api.github.com/repos/acme/widgets/pulls/"+($n|tostring))}'
}
ic_fx() { jq -s . | fx "api repos/acme/widgets/issues/comments?since=$MS&per_page=100"; }
rc_fx() { jq -s . | fx "api repos/acme/widgets/pulls/comments?since=$MS&per_page=100"; }

# --- @-mention in an issue comment → mentions_due -----------------------------
new_case mention_due
base_config
ic_comment 101 alice User "@test-bot you invented a convention we do not have" 7 | ic_fx
run_preflight review
assert_jq '.nothing_to_do == false' 'mention alone wakes the run'
assert_jq '.mentions_due | length == 1' 'exactly one mention due'
assert_jq '.mentions_due[0] | .comment_id == 101 and .number == 7 and .thread == "conversation" and .author == "alice" and .in_reply_to == null' 'entry fields'

# --- ledger row → deduped ------------------------------------------------------
new_case mention_deduped
base_config
ic_comment 101 alice User "@test-bot ping" 7 | ic_fx
printf '| 101 | 7 | 2026-08-07T09:30:00Z | answer |\n' > "$WORK/MENTIONS.md"
run_preflight review
assert_jq '.nothing_to_do == true' 'ledger row dedups the mention'

# --- reply in a bot-rooted inline thread (no @-mention) → due ------------------
new_case bot_thread_reply
base_config
{ rc_comment 200 test-bot User "🟡 **Warning:** unchecked null" 9 null
  rc_comment 201 bob User "this is intentional, see the guard above" 9 200; } | rc_fx
run_preflight review
assert_jq '.mentions_due | length == 1' 'reply to bot thread due'
assert_jq '.mentions_due[0] | .comment_id == 201 and .thread == "inline" and .in_reply_to == 200' 'inline entry fields'

# --- reply in a human-rooted thread + a Bot-type author → nothing --------------
new_case irrelevant_comments
base_config
{ rc_comment 300 carol User "human root comment" 9 null
  rc_comment 301 bob User "reply to a human" 9 300
  rc_comment 302 ci-bot Bot "@test-bot automated noise" 9 null; } | rc_fx
run_preflight review
assert_jq '.mentions_due | length == 0' 'human threads and Bot accounts ignored'

# --- mention_replies: disabled → no scan ---------------------------------------
new_case mentions_disabled
base_config '- mention_replies: disabled'
ic_comment 101 alice User "@test-bot ping" 7 | ic_fx
run_preflight review
assert_jq '.nothing_to_do == true' 'disabled key turns the scan off'

finish
