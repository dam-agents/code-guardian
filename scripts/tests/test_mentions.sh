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
# the scan asks page by page; a case that serves only page 1 leaves later pages
# unstubbed, which the stub answers as unusable and the scan reads as the end
ic_fx() { ic_page 1; }
rc_fx() { rc_page 1; }
ic_page() { jq -s . | fx "api repos/acme/widgets/issues/comments?since=$MS&per_page=100&sort=created&direction=desc&page=$1"; }
rc_page() { jq -s . | fx "api repos/acme/widgets/pulls/comments?since=$MS&per_page=100&sort=created&direction=desc&page=$1"; }

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

# --- @-mention in a PR description → mentions_due (thread body) ----------------
new_case body_mention
base_config
pr_json 4 "desc PR" '[]' "1111111111111111111111111111111111111111" \
  | jq '.body = "@test-bot is the retry loop here intentional?"' | open_prs_fx
add_row 4 "1111111111111111111111111111111111111111" "$(iso_ago 3600)" APPROVE done
run_preflight review
assert_jq '.mentions_due | length == 1' 'body mention due'
assert_jq '.mentions_due[0] | .comment_id == "body-4" and .thread == "body" and .number == 4 and .author == "alice"' 'body entry fields'

# --- body mention deduped by its ledger row ------------------------------------
new_case body_mention_deduped
base_config
pr_json 4 "desc PR" '[]' "1111111111111111111111111111111111111111" \
  | jq '.body = "@test-bot ping"' | open_prs_fx
add_row 4 "1111111111111111111111111111111111111111" "$(iso_ago 3600)" APPROVE done
printf '| body-4 | 4 | 2026-08-07T09:30:00Z | answer |\n' > "$WORK/MENTIONS.md"
run_preflight review
assert_jq '.mentions_due | length == 0' 'ledger row dedups the body mention'

# --- mention_replies: disabled → no scan ---------------------------------------
new_case mentions_disabled
base_config '- mention_replies: disabled'
ic_comment 101 alice User "@test-bot ping" 7 | ic_fx
run_preflight review
assert_jq '.nothing_to_do == true' 'disabled key turns the scan off'

# --- page cap: the scan asks newest-first, so a full page keeps fresh mentions -
# The fixture key encodes the query string: it resolves only when the request
# carries sort=created&direction=desc. An ascending scan on a repo whose window
# holds more than 100 comments never reaches the newest ones.
new_case mention_page_cap_newest_first
base_config
{ for i in $(seq 1 99); do ic_comment "$((400+i))" carol User "ordinary chatter $i" 7; done
  ic_comment 999 alice User "@test-bot please look at this" 7; } | ic_fx
run_preflight review
assert_jq '.mentions_due | length == 1' 'mention on a full page is still found'
assert_jq '.mentions_due[0].comment_id == 999' 'the newest-first page carries the mention'
assert_jq '.logs | any(test("still full after")) | not' 'one full page is followed, not reported as truncated'

# --- a full page is followed to the next one -----------------------------------
# One page holds 100 comments; a busy week overflows it and a mention on page 2
# used to be invisible until it aged out of the window.
new_case mention_second_page
base_config
{ i=1; while [ "$i" -le 100 ]; do ic_comment "$((900 + i))" bob User "chatter $i" 7; i=$((i + 1)); done; } | ic_page 1
ic_comment 777 alice User "@test-bot the finding on line 12 is wrong" 7 | ic_page 2
run_preflight review
assert_jq '[.mentions_due[] | .comment_id] | index(777) != null' 'a mention on the second page is picked up'
assert_jq '.mentions_due | length == 1' 'the first page of chatter mentions nobody'

# --- the bound holds: a repo fuller than the cap is reported, not scanned on ---
new_case mention_page_cap
base_config
full_page() { local p="$1" i=1; { while [ "$i" -le 100 ]; do ic_comment "$((p * 1000 + i))" bob User "@test-bot page $p item $i" 7; i=$((i + 1)); done; } | ic_page "$p"; }
full_page 1; full_page 2; full_page 3
run_preflight review
assert_jq '.mentions_due | length == 300' 'three pages are scanned, no more'
assert_out_contains 'still full after 3 pages' 'the run says the window was not exhausted'

# --- a page larger than one argv entry is still scanned -------------------------
# Real comment bodies are long: one page of 100 review comments clears 400 KiB,
# while a single argv entry is capped at 128 KiB (MAX_ARG_STRLEN, well under
# ARG_MAX). Passing the merged page array via `--argjson` therefore died with
# "Argument list too long" and the scan degraded to zero mentions on exactly the
# busy repos that need it. The body size is what makes this case bite — a
# fixture of short comments stays under the cap and passes either way.
new_case mention_page_over_argv_limit
base_config
BIG="$(head -c 3000 /dev/zero | tr '\0' 'x')"
{ i=1; while [ "$i" -le 99 ]; do rc_comment "$((7000 + i))" bob User "chatter $i $BIG" 9 null; i=$((i + 1)); done
  rc_comment 7999 alice User "@test-bot buried in a fat page $BIG" 9 null; } | rc_fx
run_preflight review
assert_jq '.mentions_due | length == 1' 'the mention on an oversized page is found'
assert_jq '.mentions_due[0].comment_id == 7999' 'the right comment survived the merge'

finish
