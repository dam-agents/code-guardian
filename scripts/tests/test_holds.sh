#!/usr/bin/env bash
# PR holds: a run holds only the PR it works on (review-pr.sh hold|release); a
# later preflight leaves a held PR to its holder and removes a hold whose run
# is quiet. Contract: docs/worklist.md → PR holds.
. "$(dirname "$0")/helpers.sh"

SHA1="1111111111111111111111111111111111111111"
RP="$REPO_ROOT/scripts/review-pr.sh"

# scan window start — MUST mirror preflight.sh (7 days back, day-rounded)
msince() {
  local s=$(( $(date -u +%s) - 7*86400 ))
  printf '%sT00:00:00Z' "$(date -u -d "@$s" +%Y-%m-%d 2>/dev/null || date -u -r "$s" +%Y-%m-%d)"
}
MS="$(msince)"
ic_comment() { # <id> <body> <issue-number>
  jq -n --argjson id "$1" --arg b "$2" --argjson n "$3" \
    '{id:$id, user:{login:"alice", type:"User"}, author_association:"MEMBER", body:$b,
      created_at:"2026-08-07T09:00:00Z", html_url:("https://example.test/c/"+($id|tostring)),
      issue_url:("https://api.github.com/repos/acme/widgets/issues/"+($n|tostring))}'
}
ic_fx() { jq -s . | fx "api repos/acme/widgets/issues/comments?since=$MS&per_page=100&sort=created&direction=desc&page=1"; }
hold() { # <n> <secs-ago> <run>
  mkdir -p "$WORK/.holds.lock"
  printf '%s\n%s\n' "$(iso_ago "$2")" "$3" > "$WORK/.holds.lock/$1"
}
run_event() { # <secs-ago> <run> [msg]
  mkdir -p "$WORK/logs"
  jq -nc --arg ts "$(iso_ago "$1")" --arg r "$2" --arg m "${3:-Bash [gh api]}" \
    '{ts:$ts, run:$r, job:"session", level:"debug", event:"tool_use", msg:$m}' \
    >> "$WORK/logs/events-$(date -u +%Y-%m-%d).jsonl"
}
run_rp() { # <run-id> <cmd> <n> → $OUT
  local run="$1"; shift
  OUT="$(GH_HOST="" WORK_DIR="$WORK" HOME="$FAKE_HOME" TMPDIR="$SANDBOX/tmp" LOG_RUN_ID="$run" \
         PATH="$T_DIR/bin:$PATH" bash "$RP" "$@" 2>/dev/null)"
}
assert_hold_run() { # <n> <run|-> <description>
  local got; got="$(sed -n 2p "$WORK/.holds.lock/$1" 2>/dev/null)"; got="${got:--}"
  if [ "$got" = "$2" ]; then printf 'ok   %s: %s\n' "$CASE" "$3"
  else printf 'FAIL %s: %s (hold owner %s, expected %s)\n' "$CASE" "$3" "$got" "$2"; FAILED=1; fi
}

# --- preflight: a live holder keeps its PR's review and mentions ---------------
new_case hold_alive_skips_pr
base_config
pr_json 1 "plain PR" '[]' "$SHA1" | open_prs_fx
ic_comment 101 "@test-bot please re-review" 1 | ic_fx
hold 1 3000 run-aaaaaaaa
run_event 300 run-aaaaaaaa
GH_CALLS_LOG="$SANDBOX/calls.log" run_preflight review
assert_jq '.nothing_to_do == true' 'the held PR starts no run'
assert_jq '.logs | any(contains("#1: held by run run-aaaa") and contains("left to that run"))' 'the skip names the holder'
assert_jq '[.logs[] | select(contains("left to that run"))] | length == 1' 'the PR is judged once for its review and its mention'
if grep -q 'pulls/1/files' "$SANDBOX/calls.log" 2>/dev/null; then
  printf 'FAIL %s: %s\n' "$CASE" 'the held PR costs no file-list call'; FAILED=1
else printf 'ok   %s: %s\n' "$CASE" 'the held PR costs no file-list call'; fi

# --- preflight: only the held PR is left out -----------------------------------
new_case hold_other_pr_served
base_config
{ ic_comment 101 "@test-bot why?" 7; ic_comment 102 "@test-bot and this?" 8; } | ic_fx
hold 7 3000 run-aaaaaaaa
run_event 300 run-aaaaaaaa
run_preflight review
assert_jq '[.mentions_due[].number] == [8]' 'the unrelated PR is served'
assert_hold_run 8 - 'preflight takes no hold'

# --- preflight: a hold whose run went quiet is removed -------------------------
new_case hold_quiet_released
base_config
ic_comment 101 "@test-bot why?" 7 | ic_fx
hold 7 7200 run-aaaaaaaa
run_event 3000 run-aaaaaaaa
run_preflight review
assert_jq '[.mentions_due[].number] == [7]' 'the mention is served again'
assert_jq '.logs | any(contains("#7: hold from") and contains("released"))' 'the release is logged'
assert_hold_run 7 - 'the dead hold file is gone'

# --- preflight: the fan-out window keeps a quiet holder alive ------------------
new_case hold_fanout_alive
base_config
ic_comment 101 "@test-bot why?" 7 | ic_fx
hold 7 7200 run-aaaaaaaa
run_event 2400 run-aaaaaaaa "PR #7 review_step fanned out (n=3)"
run_preflight review
assert_jq '.nothing_to_do == true' 'a holder in the skill fan-out keeps the PR'

# --- review-pr.sh: hold, a second run is refused, release ----------------------
new_case hold_acquire_release
base_config
run_rp run-aaaaaaaa hold 7
assert_jq '.outcome == "held_by_you"' 'a free PR is taken'
assert_hold_run 7 run-aaaaaaaa 'the hold names its run'
run_rp run-aaaaaaaa hold 7
assert_jq '.outcome == "held_by_you"' 'the owner takes it again'
run_rp run-bbbbbbbb hold 7
assert_jq '.outcome == "held_elsewhere" and (.why | contains("run-aaaa"))' 'another run is refused while the owner lives'
run_rp run-bbbbbbbb hold 8
assert_jq '.outcome == "held_by_you"' 'the other run takes an unrelated PR'
run_rp run-bbbbbbbb release 7
assert_hold_run 7 run-aaaaaaaa 'a run cannot release a hold it does not own'
run_rp run-aaaaaaaa release 7
assert_hold_run 7 - 'the owner releases it'
left="$(ls -A "$WORK/.holds.lock")"
[ "$left" = 8 ] && printf 'ok   %s: %s\n' "$CASE" 'no temporary hold file is left' \
  || { printf 'FAIL %s: %s (have: %s)\n' "$CASE" 'no temporary hold file is left' "$left"; FAILED=1; }

# --- review-pr.sh: an older hold whose run still logs is refused --------------
new_case hold_refused_live_owner
base_config
hold 7 3000 run-aaaaaaaa
run_event 300 run-aaaaaaaa
run_rp run-bbbbbbbb hold 7
assert_jq '.outcome == "held_elsewhere" and (.why | contains("last event"))' 'a live holder past its first minute keeps the PR'
assert_hold_run 7 run-aaaaaaaa 'the hold is unchanged'

# --- review-pr.sh: a dead hold is taken over ----------------------------------
new_case hold_takeover_dead
base_config
hold 7 7200 run-aaaaaaaa
run_event 3000 run-aaaaaaaa
run_rp run-bbbbbbbb hold 7
assert_jq '.outcome == "held_by_you"' 'a quiet holder loses the PR'
assert_hold_run 7 run-bbbbbbbb 'the new run owns the hold'

# --- review-pr.sh: without a run id the PR is worked unheld --------------------
new_case hold_no_run_id
base_config
OUT="$(GH_HOST="" WORK_DIR="$WORK" HOME="$FAKE_HOME" TMPDIR="$SANDBOX/tmp" LOG_RUN_ID="" CLAUDE_CODE_SESSION_ID="" \
       PATH="$T_DIR/bin:$PATH" bash "$RP" hold 7 2>/dev/null)"
assert_jq '.outcome == "held_by_you" and (.note | contains("not held"))' 'no run id degrades to no hold'
assert_hold_run 7 - 'no hold file written'

finish
