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

# --- review-pr.sh: the next hold gives back the one before ---------------------
new_case hold_next_releases_previous
base_config
run_rp run-aaaaaaaa hold 7
run_rp run-bbbbbbbb hold 9
run_rp run-aaaaaaaa hold 8
assert_jq '.outcome == "held_by_you"' 'the next PR is taken'
assert_hold_run 7 - 'the previous hold is given back without a release'
assert_hold_run 9 run-bbbbbbbb 'the hold of another run is kept'
run_rp run-aaaaaaaa hold 9
assert_jq '.outcome == "held_elsewhere"' 'a PR another run holds is refused'
assert_hold_run 8 - 'a refused hold also gives back the one before'
if cat "$WORK"/logs/events-*.jsonl 2>/dev/null | grep -q 'PR #7: released — this run moves on to PR #8'; then
  printf 'ok   %s: %s\n' "$CASE" 'the release is logged'
else printf 'FAIL %s: %s\n' "$CASE" 'the release is logged'; FAILED=1; fi

# --- review-pr.sh: the run id without a harness session id ---------------------
# docs/logging.md → The events log: the session passes the gate's id on as
# CG_RUN_ID, one shell after the other; a harness session id wins over it
rp_as() { # <session-id> <cg-run-id> <cmd> <n> → $OUT
  local sid="$1" cg="$2"; shift 2
  OUT="$(env -u LOG_RUN_ID GH_HOST="" WORK_DIR="$WORK" HOME="$FAKE_HOME" TMPDIR="$SANDBOX/tmp" \
         CLAUDE_CODE_SESSION_ID="$sid" CG_RUN_ID="$cg" PATH="$T_DIR/bin:$PATH" bash "$RP" "$@" 2>/dev/null)"
}
new_case hold_no_run_id
base_config
rp_as "" "" hold 7
assert_jq '.outcome == "error" and (.error | contains("no run id")) and (.error | contains("export CG_RUN_ID="))' \
  'without a run id the hold is refused, and the refusal says how to pass one'
assert_hold_run 7 - 'no hold file written'
rp_as "" "" step 7 verified
assert_jq '.outcome == "error" and (.error | contains("no run id"))' 'a review step refuses without a run id too'

new_case hold_gate_run_id
base_config
GATE=review-20261014T100000Z-41
rp_as "" "$GATE" hold 7
assert_jq '.outcome == "held_by_you"' 'the gate run id takes the hold'
assert_hold_run 7 "$GATE" 'the hold names the gate run id'
if jq -e -s --arg r "$GATE" 'any(.[]; .run == $r and .event == "hold" and (.msg | contains("PR #7: held by this run")))' \
     "$WORK/logs/events-$(date -u +%Y-%m-%d).jsonl" >/dev/null 2>&1; then
  printf 'ok   %s: %s\n' "$CASE" 'its events carry the gate run id'
else printf 'FAIL %s: %s\n' "$CASE" 'its events carry the gate run id'; FAILED=1; fi
rp_as "" "$GATE-pr9" hold 7
assert_jq '.outcome == "held_elsewhere" and (.why | contains("held by run '"$GATE"',"))' \
  'a dispatched session is another run, and the why names the gate run id whole'
rp_as "" "$GATE" release 7
assert_hold_run 7 - 'a later shell of the same run releases the hold'
rp_as 0b8c6e1f-1111-4222-8333-444455556666 "$GATE" hold 8
assert_hold_run 8 0b8c6e1f-1111-4222-8333-444455556666 'a harness session id wins over CG_RUN_ID'
rp_as "" "$GATE" hold 8
assert_jq '.outcome == "held_elsewhere" and (.why | contains("held by run 0b8c6e1f,"))' 'a session id is named by its first 8 characters'

finish
