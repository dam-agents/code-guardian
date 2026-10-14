#!/usr/bin/env bash
# Mention detection: @-mention pickup, ledger dedup, bot-thread replies,
# human-thread replies ignored, Bot-type authors ignored, config off switch,
# the author-association gate (mention_authors), the scan floor marker.
. "$(dirname "$0")/helpers.sh"

# scan window start without a marker — MUST mirror preflight.sh (7 days back,
# day-rounded)
msince() {
  local s=$(( $(date -u +%s) - 7*86400 ))
  printf '%sT00:00:00Z' "$(date -u -d "@$s" +%Y-%m-%d 2>/dev/null || date -u -r "$s" +%Y-%m-%d)"
}
MS="$(msince)"

# ASSOC (default MEMBER) is the author_association the comment carries
ic_comment() { # <id> <author> <type> <body> <issue-number>
  jq -n --argjson id "$1" --arg a "$2" --arg t "$3" --arg b "$4" --argjson n "$5" --arg assoc "${ASSOC:-MEMBER}" \
    '{id:$id, user:{login:$a, type:$t}, author_association:$assoc, body:$b,
      created_at:"2026-08-07T09:00:00Z", html_url:("https://example.test/c/"+($id|tostring)),
      issue_url:("https://api.github.com/repos/acme/widgets/issues/"+($n|tostring))}'
}
rc_comment() { # <id> <author> <type> <body> <pr-number> <in_reply_to|null>
  jq -n --argjson id "$1" --arg a "$2" --arg t "$3" --arg b "$4" --argjson n "$5" --argjson r "$6" --arg assoc "${ASSOC:-MEMBER}" \
    '{id:$id, user:{login:$a, type:$t}, author_association:$assoc, body:$b, in_reply_to_id:$r,
      created_at:"2026-08-07T09:05:00Z", html_url:("https://example.test/rc/"+($id|tostring)),
      pull_request_url:("https://api.github.com/repos/acme/widgets/pulls/"+($n|tostring))}'
}
# the scan asks page by page; a case that serves only page 1 leaves later pages
# unstubbed, which the stub answers as unusable and the scan reads as the end
ic_fx() { ic_page 1; }
rc_fx() { rc_page 1; }
ic_page() { ic_at "$MS" "$1"; }
rc_page() { rc_at "$MS" "$1"; }
ic_at() { jq -s . | fx "api repos/acme/widgets/issues/comments?since=$1&per_page=100&sort=created&direction=desc&page=${2:-1}"; }
rc_at() { jq -s . | fx "api repos/acme/widgets/pulls/comments?since=$1&per_page=100&sort=created&direction=desc&page=${2:-1}"; }

# the scan floor marker (docs/mentions.md)
mark() { head -1 "$WORK/.mention-scan-since" 2>/dev/null; }
t_epoch() { date -u -d "$1" +%s 2>/dev/null || date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s; }
mark_between() { local e; e="$(t_epoch "$(mark)")" || return 1; [ "$e" -ge "$1" ] && [ "$e" -le "$2" ]; }
assert_cmd() { # <description> <command…> — passes when the command succeeds
  local d="$1"; shift
  if "$@"; then printf 'ok   %s: %s\n' "$CASE" "$d"
  else printf 'FAIL %s: %s (marker: %s)\n' "$CASE" "$d" "$(mark)"; show_stderr; FAILED=1; fi
}
# the permission GET answers for every account; these have no access
no_access() { local l; for l in "$@"; do
  printf '{"permission":"none","role_name":"none"}' | fx "api repos/$TEST_REPO/collaborators/$l/permission"; done; }

# --- @-mention in an issue comment → mentions_due -----------------------------
new_case mention_due
base_config
ic_comment 101 alice User "@test-bot you invented a convention we do not have" 7 | ic_fx
run_preflight review
assert_jq '.nothing_to_do == false' 'mention alone wakes the run'
assert_jq '.mentions_due | length == 1' 'exactly one mention due'
assert_jq '.mentions_due[0] | .comment_id == 101 and .number == 7 and .thread == "conversation" and .author == "alice" and .in_reply_to == null' 'entry fields'
assert_jq '.read_set == ["docs/review.md","docs/mentions.md","work/MEMORY.md","work/LESSONS.md"]' 'a mention-only run reads review.md for the reply style, not the review core'
assert_cmd 'a due mention older than 7 days holds the next floor at the 7-day floor' [ "$(mark)" = "$MS" ]

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

# --- reply in an App-rooted thread: due only when its review is marked --------
new_case alias_thread_reply
base_config
seed_identity 'acme-app[bot]'
{ rc_comment 200 'acme-app[bot]' Bot "🟡 **Warning:** unchecked null" 9 null | jq '.pull_request_review_id = 700'
  rc_comment 201 bob User "this is intentional" 9 200
  rc_comment 210 'acme-app[bot]' Bot "another agent's note" 9 null | jq '.pull_request_review_id = 701'
  rc_comment 211 carol User "thanks" 9 210; } | rc_fx
printf '{"id":700,"body":"review\\n<!-- cg:review headRefOid=aaa -->"}' | fx 'api repos/acme/widgets/pulls/9/reviews/700'
printf '{"id":701,"body":"another agent"}' | fx 'api repos/acme/widgets/pulls/9/reviews/701'
run_preflight review
assert_jq '[.mentions_due[].comment_id] == [201]' 'only the reply under a marked alias review is due'
assert_jq '.config.github_identity == {login:"acme-app[bot]", kind:"app"}' 'the token identity in the worklist config'

# --- an unreadable thread-root review: not due now, retried next run ----------
new_case bot_thread_review_unreadable
base_config
seed_identity 'acme-app[bot]'
C1="$(iso_ago 1800)"
{ rc_comment 200 'acme-app[bot]' Bot "🟡 **Warning:** unchecked null" 9 null | jq '.pull_request_review_id = 700'
  rc_comment 201 bob User "this is intentional" 9 200 | jq --arg t "$C1" '.created_at = $t'; } | rc_fx
fx_fail 'api repos/acme/widgets/pulls/9/reviews/700' 1
run_preflight review
assert_jq '.mentions_due == []' 'no reply is due on an unread review'
assert_jq '[.logs[] | select(test("unreadable — reply 201 retried next run"))] | length == 1' 'the skip is logged'
assert_cmd 'the reply left for the next run holds the floor at its created_at' [ "$(mark)" = "$C1" ]

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
B=$(date -u +%s); run_preflight review; A=$(date -u +%s)
assert_jq '.mentions_due | length == 1' 'body mention due'
assert_jq '.mentions_due[0] | .comment_id == "body-4" and .thread == "body" and .number == 4 and .author == "alice"' 'body entry fields'
assert_cmd 'a PR description, read from the open-PR list, does not hold the floor' mark_between $((B - 900)) $((A - 900))

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
assert_cmd 'no scan floor is written' [ ! -e "$WORK/.mention-scan-since" ]

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
full_page 1; full_page 2
# the last comment of page 3 is the oldest the scan reads: the log line names it
{ i=1; while [ "$i" -le 99 ]; do ic_comment "$((3000 + i))" bob User "@test-bot page 3 item $i" 7; i=$((i + 1)); done
  ic_comment 3100 bob User "@test-bot page 3 item 100" 7 | jq '.created_at = "2026-08-01T12:34:56Z"'; } | ic_page 3
run_preflight review
assert_jq '.mentions_due | length == 300' 'three pages are scanned, no more'
assert_out_contains 'still full after 3 pages' 'the run says the window was not exhausted'
assert_out_contains 'back to 2026-08-01T12:34:56Z' 'the run says how far back the scan reached'

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

# --- a surface that does not answer is not a quiet surface ---------------------
# An empty surface and a surface whose first page faulted produce the same
# worklist, and the empty one is the normal week — so the fault says so.
new_case mention_surface_unreadable
base_config
ic_comment 101 alice User "@test-bot ping" 7 | ic_fx
fx_fail "api repos/acme/widgets/pulls/comments?since=$MS&per_page=100&sort=created&direction=desc&page=1"
run_preflight review
assert_jq '.mentions_due | length == 1' 'the surface that answered still yields its mention'
assert_out_contains 'review-comment surface did not answer' 'the silent surface is logged, never read as quiet'
assert_cmd 'no scan floor is written' [ ! -e "$WORK/.mention-scan-since" ]

# --- mention_authors: an account outside the set is counted, never emitted ------
# author_association is what GitHub states about the commenter; the default set
# is OWNER, MEMBER and COLLABORATOR, so a stranger's mention wakes nothing, and
# a stranger's reply in a bot thread is counted the same way.
new_case mention_outsider_left_out
base_config
{ ASSOC=NONE ic_comment 101 stranger User "@test-bot please review this now" 7
  ic_comment 102 alice User "@test-bot ping" 7; } | ic_fx
{ rc_comment 200 test-bot User "🟡 **Warning:** unchecked null" 9 null
  ASSOC=CONTRIBUTOR rc_comment 201 drifter User "not intentional at all" 9 200; } | rc_fx
no_access stranger drifter
run_preflight review
assert_jq '.mentions_due | length == 1' 'only the member mention is due'
assert_jq '.mentions_due[0].comment_id == 102' 'the member mention is the one emitted'
assert_jq '.mentions_due[0] | has("admitted") | not' 'the gate flag stays out of the entry'
assert_jq '.config.mention_authors == "collaborators"' 'the default set is resolved into config'
assert_out_contains '2 mention(s) by accounts outside mention_authors (collaborators) left out' 'the left-out count is logged'
assert_jq '.logs | any(test("did not answer")) | not' 'an answered access check is no fault'

# --- mention_authors: anyone → every human account is handled ------------------
new_case mention_authors_anyone
base_config '- mention_authors: anyone'
{ ASSOC=NONE ic_comment 101 stranger User "@test-bot please review this now" 7
  ic_comment 102 alice User "@test-bot ping" 7; } | ic_fx
run_preflight review
assert_jq '.mentions_due | length == 2' 'both mentions are due'
assert_jq '.config.mention_authors == "anyone"' 'the key is resolved into config'
assert_jq '.logs | any(test("outside mention_authors")) | not' 'nothing is left out'

# --- outsiders alone wake no run; an unknown value reads as the default --------
new_case mention_outsider_alone
base_config '- mention_authors: everybody'
ASSOC=FIRST_TIME_CONTRIBUTOR ic_comment 101 stranger User "@test-bot hi" 7 | ic_fx
pr_json 4 "desc PR" '[]' "1111111111111111111111111111111111111111" \
  | jq '.author_association = "NONE" | .body = "@test-bot review please"' | open_prs_fx
add_row 4 "1111111111111111111111111111111111111111" "$(iso_ago 3600)" APPROVE done
no_access stranger alice
run_preflight review
assert_jq '.nothing_to_do == true' 'outsider mentions start no session'
assert_out_contains '2 mention(s) by accounts outside mention_authors (collaborators) left out' 'an unknown value falls back to the default set'

# --- a private org member reads as CONTRIBUTOR: the permission GET admits ------
# triage or more admits anywhere; read admits on a private repository only
new_case mention_private_member_admitted
base_config
{ ASSOC=CONTRIBUTOR ic_comment 101 hidden User "@test-bot ping" 7
  ASSOC=NONE ic_comment 102 reader User "@test-bot ping" 7
  ASSOC=NONE ic_comment 103 stranger User "@test-bot ping" 7; } | ic_fx
printf '{"permission":"write","role_name":"write"}' | fx "api repos/$TEST_REPO/collaborators/hidden/permission"
printf '{"permission":"read","role_name":"read"}' | fx "api repos/$TEST_REPO/collaborators/reader/permission"
printf '{"private":true}' | fx "api repos/$TEST_REPO"
no_access stranger
run_preflight review
assert_jq '[.mentions_due[].comment_id] == [101, 102]' 'write, and read on a private repository, are admitted'
assert_out_contains '1 mention(s) by accounts outside mention_authors (collaborators) left out' 'an account without access stays out'

new_case mention_public_reader_left_out
base_config
ASSOC=NONE ic_comment 102 reader User "@test-bot ping" 7 | ic_fx
printf '{"permission":"read","role_name":"read"}' | fx "api repos/$TEST_REPO/collaborators/reader/permission"
printf '{"private":false}' | fx "api repos/$TEST_REPO"
run_preflight review
assert_jq '.mentions_due | length == 0' 'read on a public repository is every account'

# --- a GitHub App bot_login: people mention its slug, with or without [bot] ----
new_case app_bot_login_mentions
base_config
sed -i.bak 's/^- bot_login: test-bot$/- bot_login: acme-app[bot]/' "$WORK/CONFIG.md"
{ ic_comment 301 alice User "@acme-app please re-review" 7
  ic_comment 302 bob User "cc @acme-app[bot]: is this right?" 8
  ic_comment 303 carol User "@acme-application is another account" 9
  ic_comment 304 dave User "@acme-appx is not the bot" 10; } | ic_fx
run_preflight review
assert_jq '[.mentions_due[].comment_id] == [301, 302]' 'the slug and the [bot] login are mentions, longer logins are not'

# --- the scan floor: the marker is the `since`, a due mention holds it ---------
new_case mention_floor_from_marker
base_config
M1="$(iso_ago 3600)"; C1="$(iso_ago 1800)"
printf '%s\n' "$M1" > "$WORK/.mention-scan-since"
ic_comment 101 alice User "@test-bot ping" 7 | jq --arg t "$C1" '.created_at = $t' | ic_at "$M1"
GH_CALLS_LOG="$SANDBOX/calls.log" run_preflight review
assert_jq '[.mentions_due[].comment_id] == [101]' 'the scan reads since the marker'
assert_file_contains "$SANDBOX/calls.log" "pulls/comments?since=$M1&" 'the review-comment surface asks since the marker too'
assert_cmd 'a due mention holds the next floor at its created_at' [ "$(mark)" = "$C1" ]

new_case mention_floor_quiet
base_config
printf '%s\n' "$(iso_ago 3600)" > "$WORK/.mention-scan-since"
B=$(date -u +%s); run_preflight review; A=$(date -u +%s)
assert_jq '.nothing_to_do == true' 'a quiet scan'
assert_cmd 'the next floor is the scan start - 15 min' mark_between $((B - 900)) $((A - 900))

# --- a marker past 7 days, in the future or unreadable is the 7-day floor ------
for m in "$(iso_ago $((10 * 86400)))" "$(iso_ago -7200)" "not a time"; do
  new_case "mention_floor_invalid_marker"
  base_config
  printf '%s\n' "$m" > "$WORK/.mention-scan-since"
  ic_comment 101 alice User "@test-bot ping" 7 | ic_fx
  run_preflight review
  assert_jq '[.mentions_due[].comment_id] == [101]' "marker '$m' reads as the 7-day floor"
done

# --- an incomplete scan keeps the floor ----------------------------------------
new_case mention_floor_surface_down
base_config
M1="$(iso_ago 3600)"
printf '%s\n' "$M1" > "$WORK/.mention-scan-since"
fx_fail "api repos/acme/widgets/pulls/comments?since=$M1&per_page=100&sort=created&direction=desc&page=1"
run_preflight review
assert_out_contains 'review-comment surface did not answer' 'the silent surface is logged'
assert_cmd 'a surface that did not answer keeps the floor' [ "$(mark)" = "$M1" ]

new_case mention_floor_page_down
base_config
M1="$(iso_ago 3600)"
printf '%s\n' "$M1" > "$WORK/.mention-scan-since"
{ i=1; while [ "$i" -le 100 ]; do ic_comment "$((900 + i))" bob User "chatter $i" 7; i=$((i + 1)); done; } | ic_at "$M1" 1
fx_fail "api repos/acme/widgets/issues/comments?since=$M1&per_page=100&sort=created&direction=desc&page=2"
run_preflight review
assert_cmd 'a later page that did not answer keeps the floor' [ "$(mark)" = "$M1" ]

# --- a check that did not answer holds the floor; a 404 is an answer ----------
new_case mention_floor_root_unanswered
base_config
C1="$(iso_ago 1800)"
rc_comment 211 bob User "this is intentional" 9 210 | jq --arg t "$C1" '.created_at = $t' | rc_fx
fx_fail 'api repos/acme/widgets/pulls/comments/210'
run_preflight review
assert_jq '.mentions_due == []' 'no reply is due on an unread root'
assert_out_contains 'thread root 210 unreadable — reply 211 retried next run' 'the skip is logged'
assert_cmd 'the reply holds the floor at its created_at' [ "$(mark)" = "$C1" ]

new_case mention_floor_root_404
base_config
rc_comment 211 bob User "this is intentional" 9 210 | jq --arg t "$(iso_ago 1800)" '.created_at = $t' | rc_fx
fx_fail 'api repos/acme/widgets/pulls/comments/210'
fx_out 'api repos/acme/widgets/pulls/comments/210' '{"message":"Not Found","documentation_url":"https://docs.github.com/rest","status":"404"}'
B=$(date -u +%s); run_preflight review; A=$(date -u +%s)
assert_jq '.mentions_due == []' 'a reply under a deleted root is not due'
assert_jq '.logs | any(test("unreadable")) | not' 'a 404 is an answer, not a fault'
assert_cmd 'the reply holds no floor' mark_between $((B - 900)) $((A - 900))

new_case mention_floor_access_unanswered
base_config
C1="$(iso_ago 1800)"
ASSOC=NONE ic_comment 101 hidden User "@test-bot ping" 7 | jq --arg t "$C1" '.created_at = $t' | ic_fx
fx_fail "api repos/$TEST_REPO/collaborators/hidden/permission"
run_preflight review
assert_jq '.mentions_due == []' 'the mention is left out this run'
assert_out_contains '1 mention(s) by accounts outside mention_authors (collaborators) left out' 'and counted as left out'
assert_out_contains 'access check of hidden did not answer' 'the fault is logged'
assert_cmd 'the mention holds the floor at its created_at' [ "$(mark)" = "$C1" ]

# --- a 404 or a 403 refusal is an answer; a rate-limit 403 is not -------------
# A token without push access gets the 403 refusal on every call.
new_case mention_floor_access_404
base_config
ASSOC=NONE ic_comment 101 hidden User "@test-bot ping" 7 | jq --arg t "$(iso_ago 1800)" '.created_at = $t' | ic_fx
fx_fail "api repos/$TEST_REPO/collaborators/hidden/permission"
fx_out "api repos/$TEST_REPO/collaborators/hidden/permission" '{"message":"Not Found","documentation_url":"https://docs.github.com/rest","status":"404"}'
B=$(date -u +%s); run_preflight review; A=$(date -u +%s)
assert_out_contains '1 mention(s) by accounts outside mention_authors (collaborators) left out' 'a 404 is no access'
assert_jq '.logs | any(test("did not answer")) | not' 'a 404 is an answer, not a fault'
assert_cmd 'the mention holds no floor' mark_between $((B - 900)) $((A - 900))

new_case mention_floor_access_no_push
base_config
ASSOC=NONE ic_comment 101 hidden User "@test-bot ping" 7 | jq --arg t "$(iso_ago 1800)" '.created_at = $t' | ic_fx
fx_fail "api repos/$TEST_REPO/collaborators/hidden/permission"
fx_out "api repos/$TEST_REPO/collaborators/hidden/permission" '{"message":"Must have push access to view collaborator permission.","documentation_url":"https://docs.github.com/rest","status":"403"}'
B=$(date -u +%s); run_preflight review; A=$(date -u +%s)
assert_out_contains '1 mention(s) by accounts outside mention_authors (collaborators) left out' 'the push-access refusal is no access'
assert_jq '.logs | any(test("did not answer")) | not' 'the refusal is an answer, not a fault'
assert_cmd 'the mention holds no floor' mark_between $((B - 900)) $((A - 900))

new_case mention_floor_access_rate_limited
base_config
C1="$(iso_ago 1800)"
ASSOC=NONE ic_comment 101 hidden User "@test-bot ping" 7 | jq --arg t "$C1" '.created_at = $t' | ic_fx
fx_fail "api repos/$TEST_REPO/collaborators/hidden/permission"
fx_out "api repos/$TEST_REPO/collaborators/hidden/permission" '{"message":"API rate limit exceeded for user ID 1.","documentation_url":"https://docs.github.com/rest","status":"403"}'
run_preflight review
assert_out_contains 'access check of hidden did not answer' 'a rate limit is no answer'
assert_cmd 'the mention holds the floor at its created_at' [ "$(mark)" = "$C1" ]

# --- a read answer whose repository visibility does not answer -----------------
new_case mention_floor_visibility_unanswered
base_config
C1="$(iso_ago 1800)"
ASSOC=NONE ic_comment 101 reader User "@test-bot ping" 7 | jq --arg t "$C1" '.created_at = $t' | ic_fx
printf '{"permission":"read","role_name":"read"}' | fx "api repos/$TEST_REPO/collaborators/reader/permission"
fx_fail "api repos/$TEST_REPO"
run_preflight review
assert_jq '.mentions_due == []' 'the mention is left out this run'
assert_out_contains 'access check of reader did not answer' 'the fault is logged'
assert_cmd 'the mention holds the floor at its created_at' [ "$(mark)" = "$C1" ]

finish
