#!/usr/bin/env bash
# Escaped defects (docs/escapes.md): scripts/escape.sh validates and appends
# the ledger, finds a key again, counts the audit's week, and turns stack
# frames into blame leads with their merged PRs.
. "$(dirname "$0")/helpers.sh"

esc() { OUT="$(PATH="$T_DIR/bin:$PATH" TMPDIR="$SANDBOX" bash "$REPO_ROOT/scripts/escape.sh" "$@" 2>/dev/null)"; }
row() { printf '%s' "$1" > "$SANDBOX/row.json"; }

# --- a valid row is stamped and appended ---------------------------------------
new_case escape_record
base_config
row '{"key":"TypeError|read x of undefined|src/api/user.ts:load","env":"prod","source":"slack:C0123ABCD",
      "pr":12,"confidence":"confirmed","review":"missed","class":"Unchecked response field","rule":"added"}'
esc record "$WORK" "$SANDBOX/row.json"
assert_jq '.outcome == "recorded" and (.row.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$"))' 'the row gets the write time'
assert_jq '.row.recurrence == false' 'a missing recurrence is false'
check_eq "$(grep -c '' "$WORK/ESCAPES.jsonl")" "1" 'one line in the ledger'
row '{"key":"k2","env":"dev","source":"chat","confidence":"not_code","review":"not_visible","rule":"none"}'
esc record "$WORK" "$SANDBOX/row.json"
assert_jq '.outcome == "recorded" and .row.pr == null and .row.class == null and .row.paths == []' 'a not_code report records without PR, class or paths'
check_eq "$(grep -c '' "$WORK/ESCAPES.jsonl")" "2" 'the ledger only grows'

# --- an invalid row names its fields and writes nothing ------------------------
new_case escape_record_invalid
base_config
row '{"env":"prod","source":"chat","pr":"12","confidence":"sure","review":"missed","rule":"added"}'
esc record "$WORK" "$SANDBOX/row.json"
assert_jq '.outcome == "error" and (.error | test("key")) and (.error | test("pr")) and (.error | test("confidence"))' 'every bad field is named'
assert_jq '.error | test("a rule needs its class")' 'a rule without a class is refused'
[ -f "$WORK/ESCAPES.jsonl" ] && bad 'an invalid row was appended' || ok 'nothing was appended'
row '{"key":"k","env":"prod","source":"chat","confidence":"unknown","review":"unknown","rule":"none","paths":["a.ts",3]}'
esc record "$WORK" "$SANDBOX/row.json"
assert_jq '.outcome == "error" and (.error | test("paths"))' 'paths must be strings'
row '[1,2]'
esc record "$WORK" "$SANDBOX/row.json"
assert_jq '.outcome == "error"' 'a non-object is refused'

# --- seen finds the newest row of a key ----------------------------------------
new_case escape_seen
base_config
printf '%s\n' '{"key":"k1","pr":1,"at":"2026-10-01T00:00:00Z"}' 'partial{' '{"key":"k1","pr":2,"at":"2026-10-02T00:00:00Z"}' > "$WORK/ESCAPES.jsonl"
esc seen "$WORK" k1
assert_jq '.outcome == "seen" and .row.pr == 2' 'the newest row of the key, a broken line skipped'
esc seen "$WORK" other
assert_jq '.outcome == "new"' 'an unknown key is new'

# --- stats counts the window, all classes and every recurrence -----------------
new_case escape_stats
base_config
now="$(iso_ago 3600)"; old="$(iso_ago 2592000)"
{
  printf '{"key":"a","pr":1,"review":"missed","confidence":"confirmed","class":"Unchecked field","rule":"added","recurrence":false,"at":"%s"}\n' "$old"
  printf '{"key":"b","pr":2,"review":"missed","confidence":"likely","class":"Unchecked field","rule":"strengthened","recurrence":true,"at":"%s"}\n' "$now"
  printf '{"key":"c","pr":3,"review":"not_reviewed","confidence":"confirmed","class":"No timeout","rule":"added","recurrence":false,"at":"%s"}\n' "$now"
  printf '{"key":"d","pr":null,"review":"not_visible","confidence":"not_code","class":null,"rule":"none","recurrence":false,"at":"%s"}\n' "$now"
} > "$WORK/ESCAPES.jsonl"
esc stats "$WORK"
assert_jq '.outcome == "ok" and .reports == 3 and .total == 4' 'the week holds three of four reports'
assert_jq '.by_review == {"missed":1,"not_reviewed":1,"not_visible":1}' 'reports by review state'
assert_jq '.rules == {"added":1,"strengthened":1}' 'class lines added and widened'
assert_jq '.recurrences == [{"class":"Unchecked field","pr":2,"at":"'"$now"'"}]' 'a class that failed again is listed'
assert_jq '.not_reviewed == [3]' 'a PR with no review is listed'
assert_jq '.classes[0] | .class == "Unchecked field" and .n == 2 and .week == 1' 'classes rank by all-time count'
assert_jq '.hits == []' 'no review named a class yet'
{ printf '## Review at %s\n<!-- findings-json: [{"status":"new","severity":"warning","file":"a.ts","line":1,"escape":"Unchecked field"},{"status":"still","severity":"warning","file":"b.ts","line":2,"escape":"Unchecked field"},{"status":"new","severity":"critical","file":"c.ts","line":3}] -->\n' "$now"
  printf '## Review at %s\n<!-- findings-json: [{"status":"new","severity":"warning","file":"d.ts","line":4,"escape":"Unchecked field"},{"status":"new","severity":"warning","file":"e.ts","line":5,"escape":"No timeout"}] -->\n' "$old"
} > "$WORK/reviews/pr-7.md"
esc stats "$WORK"
assert_jq '.hits == [{"class":"Unchecked field","n":2,"week":1},{"class":"No timeout","n":1,"week":0}]' 'new findings that name a class count as hits, all time and this week'
esc stats "$WORK" --days 60
assert_jq '.reports == 4' 'the window is a parameter'
esc stats "$WORK" --days x
assert_jq '.outcome == "error"' 'a bad window is refused'

# --- leads: blame each frame, map commits to merged PRs ------------------------
new_case escape_leads
base_config
R="$SANDBOX/repo"; mkdir -p "$R/src"
git -C "$R" init -q 2>/dev/null
gc() { git -C "$R" -c user.email=t@t -c user.name=t "$@" 2>/dev/null; }
printf 'a\nb\nc\n' > "$R/src/user.ts"; gc add -A; gc commit -qm 'add user'
C1="$(git -C "$R" rev-parse HEAD)"
printf 'a\nB\nc\n' > "$R/src/user.ts"; gc commit -qam 'change line 2'
C2="$(git -C "$R" rev-parse HEAD)"
pr_fx() { # <sha> <number> [merged_at|null]
  jq -n --argjson n "$2" --arg m "${3:-2026-11-01T00:00:00Z}" \
    '[{number:$n, title:"PR \($n)", merged_at:(if $m == "null" then null else $m end), html_url:"https://github.com/acme/widgets/pull/\($n)"}]' \
    | fx "api repos/acme/widgets/commits/$1/pulls"
}
pr_fx "$C1" 11 2026-10-01T00:00:00Z
pr_fx "$C2" 12
CG_ESCAPE_CLONE_URL="$R" esc leads "$WORK" src/user.ts:2 ./src/user.ts:1 src/gone.ts:4
assert_jq '.outcome == "ready" and .at == "'"$C2"'"' 'the default is the tip of the default branch'
assert_jq '.frames[0] | .blame == "'"$C2"'" and .blame_pr[0].number == 12 and .line == 2' 'the failing line blames the PR that changed it'
assert_jq '.frames[1] | .path == "src/user.ts" and .blame == "'"$C1"'"' 'a ./ prefix is stripped'
assert_jq '.frames[2].error | test("not in the tree")' 'a path outside the tree is named, not fatal'
assert_jq '.reads_failed == 0' 'an absent path is not a failed read'
assert_jq '.candidates[0].number == 12 and .candidates[0].hits >= 2' 'the PR behind the most frames ranks first'
CG_ESCAPE_CLONE_URL="$R" esc leads "$WORK" --at "$C1" src/user.ts:2
assert_jq '.at == "'"$C1"'" and .frames[0].blame == "'"$C1"'"' 'a deployed SHA is blamed as it was'
pr_fx "$C2" 12 null
CG_ESCAPE_CLONE_URL="$R" esc leads "$WORK" src/user.ts:2
assert_jq '.frames[0].blame_pr == []' 'an unmerged PR is no candidate'
CG_ESCAPE_CLONE_URL="$R" esc leads "$WORK" --at 0123456789abcdef0123456789abcdef01234567 src/user.ts:2
assert_jq '.outcome == "error" and (.error | test("not found"))' 'an unknown SHA is an error'
fx_fail "api repos/acme/widgets/commits/$C2/pulls"
CG_ESCAPE_CLONE_URL="$R" esc leads "$WORK" src/user.ts:2 src/user.ts:1 src/user.ts:3 src/user.ts:2 src/user.ts:1 src/user.ts:3
assert_jq '.lookups_failed == 1 and .commits["'"$C2"'"].prs == null and (.commits["'"$C2"'"].error | test("failed"))' 'a failed PR lookup is named, never an empty list'
assert_jq '.frames[0].blame_pr == null and .commits["'"$C1"'"].prs[0].number == 11' 'the other commits still map'
assert_jq '.frames_dropped == 1 and (.frames | length) == 5 and .commits_capped == false' 'frames past the cap are counted'
CG_ESCAPE_CLONE_URL="$R" esc leads "$WORK" src/user.ts:99 src/user.ts:1
assert_jq '.reads_failed == 1 and (.frames[0].error | test("blame failed")) and .frames[1].blame == "'"$C1"'"' 'a failed blame is a counted frame error, never a frame with no lead'
esc leads "$WORK"
assert_jq '.outcome == "error"' 'no frame is an error'
ls -d "$SANDBOX"/cg-escape.* >/dev/null 2>&1 && bad 'the clone was left behind' || ok 'the clone is removed'

finish
