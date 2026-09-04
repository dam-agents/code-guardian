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
# fixtures are per page — preflight walks pages newest-first under a budget
ic_page() { jq -s . | fx "api repos/acme/widgets/issues/comments?since=$MS&per_page=100&sort=created&direction=desc&page=$1"; }
rc_page() { jq -s . | fx "api repos/acme/widgets/pulls/comments?since=$MS&per_page=100&sort=created&direction=desc&page=$1"; }
ic_fx() { ic_page 1; }
rc_fx() { rc_page 1; }

# <count> filler comments in ONE jq call, ids from <first-id>, one per line
ic_bulk() { # <first-id> <count> <author> <body> <issue-number>
  jq -n -c --argjson f "$1" --argjson c "$2" --arg a "$3" --arg b "$4" --argjson n "$5" \
    '[range($f; $f+$c) | {id:., user:{login:$a, type:"User"}, body:$b,
      created_at:"2026-08-07T09:00:00Z", html_url:("https://example.test/c/"+(.|tostring)),
      issue_url:("https://api.github.com/repos/acme/widgets/issues/"+($n|tostring))}] | .[]'
}
rc_bulk() { # <first-id> <count> <author> <body> <pr-number>
  jq -n -c --argjson f "$1" --argjson c "$2" --arg a "$3" --arg b "$4" --argjson n "$5" \
    '[range($f; $f+$c) | {id:., user:{login:$a, type:"User"}, body:$b, in_reply_to_id:null,
      created_at:"2026-08-07T09:05:00Z", html_url:("https://example.test/rc/"+(.|tostring)),
      pull_request_url:("https://api.github.com/repos/acme/widgets/pulls/"+($n|tostring))}] | .[]'
}

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

# --- newest-first: a full first page still carries the freshest mentions -------
# The fixture key encodes the query string: it resolves only when the request
# carries sort=created&direction=desc. An ascending scan on a repo whose window
# holds more than 100 comments never reaches the newest ones.
new_case mention_page_cap_newest_first
base_config
{ ic_bulk 401 99 carol "ordinary chatter" 7
  ic_comment 999 alice User "@test-bot please look at this" 7; } | ic_fx
run_preflight review
assert_jq '.mentions_due | length == 1' 'mention on a full page is still found'
assert_jq '.mentions_due[0].comment_id == 999' 'the newest-first page carries the mention'
assert_jq '.logs | any(test("past .* pages")) | not' 'a covered window reports no truncation'

# --- a full page is followed to the next one ----------------------------------
# The bot's own inline comments fill the review-comment page, so the human reply
# lives on page 2; a single-page scan would never see it.
new_case mention_pagination
base_config
rc_bulk 500 100 test-bot "🟡 **Warning:** unchecked null" 9 | rc_page 1
{ rc_comment 700 test-bot User "🟡 **Warning:** off-by-one" 9 null
  rc_comment 701 bob User "@test-bot this one is intentional" 9 700; } | rc_page 2
run_preflight review
assert_jq '.mentions_due | length == 1' 'the mention on page 2 is reached'
assert_jq '.mentions_due[0].comment_id == 701' 'entry comes from the second page'

# --- the page budget is bounded, and an exhausted budget says how far it got ---
new_case mention_budget_exhausted
base_config
for pg in 1 2 3 4 5 6; do
  rc_bulk "$((1000 * pg))" 100 test-bot "🟡 **Warning:** noise" 9 | rc_page "$pg"
done
run_preflight review
assert_jq '.logs | any(test("review comments past 5 pages"))' 'the exhausted budget is reported'
assert_jq '.logs | any(test("covered back to 2026-08-07T09:05:00Z"))' 'the log names the oldest covered comment'

# --- a full page of realistic comments exceeds a single execve argument --------
# 100 review comments carry ~250 KB of body and diff_hunk — past Linux's 128 KiB
# MAX_ARG_STRLEN. Passed as --argjson the whole scan fails silently and every
# mention is dropped; the scan must read its pages from stdin.
new_case mention_large_page
base_config
BIG="$(jq -rn '[range(0;2500)] | map("x") | join("")')"
{ rc_bulk 800 99 test-bot "$BIG" 9
  rc_comment 899 bob User "@test-bot $BIG" 9 null; } | rc_page 1
run_preflight review
assert_jq '.mentions_due | length == 1' 'the mention survives an oversized page'
assert_jq '.mentions_due[0].comment_id == 899' 'entry comes from the oversized page'

finish
