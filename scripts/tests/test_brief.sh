#!/usr/bin/env bash
# Daily brief (docs/brief.md): the gate is deterministic — keys, weekend, the
# window from BRIEF.log, and the merged PRs in it.
. "$(dirname "$0")/helpers.sh"

CLOSED='api repos/acme/widgets/pulls?state=closed&sort=updated&direction=desc&per_page=100'
merged_fx() { # <merged_at>
  jq -n --arg m "$1" \
    '[{number:7, title:"Add export", user:{login:"alice"}, merged_at:$m, html_url:"https://example.test/pr/7"},
      {number:8, title:"Closed only", user:{login:"bob"}, merged_at:null, html_url:"https://example.test/pr/8"}]' \
    | fx "$CLOSED"
}
# the weekday is pinned (CG_BRIEF_DOW), so no case depends on the day it runs
dow() { export CG_BRIEF_DOW="$1"; }

new_case brief_disabled
base_config '- slack_notifications: enabled'
merged_fx "$(iso_ago 3600)"
run_preflight brief
assert_jq '.nothing_to_do == true and (.brief_due | not)' 'no brief without daily_brief'

new_case brief_needs_slack
base_config '- daily_brief: enabled'
merged_fx "$(iso_ago 3600)"
run_preflight brief
assert_jq '.nothing_to_do == true' 'no brief without Slack notifications'

dow 3
{
  new_case brief_due
  base_config '- daily_brief: enabled' '- slack_notifications: enabled' '- brief_language: Czech'
  merged_fx "$(iso_ago 3600)"
  run_preflight brief
  assert_jq '.nothing_to_do == false' 'a merged PR makes the brief due'
  assert_jq '.brief_due | .language == "Czech" and (.prs | length == 1) and .prs[0].number == 7 and .prs[0].author == "alice"' 'merged PRs only, with the language'

  assert_jq '.brief_due | (.until | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")) and .since < .until' 'the window carries its end, which the log records'

  new_case brief_no_log_window
  base_config '- daily_brief: enabled' '- slack_notifications: enabled'
  merged_fx "$(iso_ago 3600)"
  run_preflight brief
  assert_jq ".brief_due.since <= \"$(iso_ago $((86400 - 60)))\"" 'without a log the window opens at the previous weekday'

  new_case brief_monday_window
  dow 1
  base_config '- daily_brief: enabled' '- slack_notifications: enabled'
  merged_fx "$(iso_ago 3600)"
  run_preflight brief
  dow 3
  assert_jq ".brief_due.since <= \"$(iso_ago $((3 * 86400 - 60)))\"" 'on a Monday the window opens three days back, so the weekend is covered'

  new_case brief_after_until
  base_config '- daily_brief: enabled' '- slack_notifications: enabled'
  merged_fx "$(iso_ago 3600)"
  printf '%s\n' "$(iso_ago 7200)" > "$WORK/BRIEF.log"
  run_preflight brief
  assert_jq '.brief_due.since < .brief_due.prs[0].merged_at' 'the window starts at the recorded end, so a PR merged after it is kept'

  new_case brief_default_language
  base_config '- daily_brief: enabled' '- slack_notifications: enabled'
  merged_fx "$(iso_ago 3600)"
  run_preflight brief
  assert_jq '.brief_due.language == "English"' 'the language defaults to English'

  new_case brief_window
  base_config '- daily_brief: enabled' '- slack_notifications: enabled'
  merged_fx "$(iso_ago 7200)"
  printf '%s\n' "$(iso_ago 3600)" > "$WORK/BRIEF.log"
  run_preflight brief
  assert_jq '.nothing_to_do == true' 'a PR merged before the last brief is not repeated'

  new_case brief_api_error
  base_config '- daily_brief: enabled' '- slack_notifications: enabled'
  fx_fail "$CLOSED"
  OUT="$(GH_HOST="" WORK_DIR="$WORK" HOME="$FAKE_HOME" PATH="$T_DIR/bin:$PATH" bash "$REPO_ROOT/scripts/preflight.sh" brief 2>/dev/null)"
  assert_jq '.error != null' 'a failed read is an error, never an empty window'
}
dow 6
{
  new_case brief_weekend
  base_config '- daily_brief: enabled' '- slack_notifications: enabled'
  merged_fx "$(iso_ago 3600)"
  run_preflight brief
  assert_jq '.nothing_to_do == true' 'the weekend sends nothing; Monday covers it'
}
dow 3

new_case brief_config_object
base_config '- daily_brief: enabled' '- brief_language: German'
pr_json 1 "a new PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
run_preflight review
assert_jq '.config.daily_brief == "enabled" and .config.brief_language == "German"' 'the keys travel in the config object'

# brief-media.sh: the screenshots of the brief's thread
HTML='-H Accept: application/vnd.github.html+json'
PRIV='https://private-user-images.githubusercontent.com'
png() { printf '\211PNG\r\n\032\n\000\000\000\015'; }
media_file() { # <url> — the curl stub serves stdin for it
  cat > "$SANDBOX/files/$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')"; }
run_media() { # <pr>…
  OUT="$(GH_HOST="" HOME="$FAKE_HOME" CG_BRIEF_MEDIA_DIR="$SANDBOX/media" CURL_FILES_DIR="$SANDBOX/files" \
    PATH="$T_DIR/bin:$PATH" bash "$REPO_ROOT/scripts/brief-media.sh" fetch "$WORK" "$@" 2>>"$STDERR_LOG")"; }

new_case brief_media
base_config
mkdir -p "$SANDBOX/files"
jq -n --arg p "$PRIV" '{user:{login:"alice"}, body_html:("<p><a href=\"x\"><img src=\"" + $p + "/1/a.png?jwt=t1&amp;x=1\" alt=\"Plans &quot;filter&quot;\"></a>"
  + "<img src=\"https://camo.githubusercontent.com/abc\" alt=\"badge\">"
  + "<img src=\"https://github.com/acme/widgets/raw/main/docs/shot.png\" alt=\"repo\">"
  + "<img src=\"" + $p + "/1/text.png?jwt=t2\" alt=\"text\"></p>")}' | fx "api repos/acme/widgets/pulls/7 $HTML"
jq -n --arg p "$PRIV" '[{user:{login:"bob"}, body_html:("<img src=\"" + $p + "/1/bob.png?jwt=t3\">")},
  {user:{login:"alice"}, body_html:("<video src=\"" + $p + "/1/rec.mp4?jwt=t4\"></video>")}]' \
  | fx "api repos/acme/widgets/issues/7/comments?per_page=20 $HTML"
png | fx "api repos/acme/widgets/contents/docs/shot.png?ref=main -H Accept: application/vnd.github.raw"
png | media_file "$PRIV/1/a.png?jwt=t1&x=1"
printf 'not an image' | media_file "$PRIV/1/text.png?jwt=t2"
png | media_file "$PRIV/1/bob.png?jwt=t3"
printf '\000\000\000\030ftypmp42' | media_file "$PRIV/1/rec.mp4?jwt=t4"
jq -n --arg p "$PRIV" '{user:{login:"carol"}, body_html:([range(4)] | map("<img src=\"" + $p + "/9/\(.).png?jwt=q\(.)\">") | join(""))}' \
  | fx "api repos/acme/widgets/pulls/9 $HTML"
for i in 0 1 2 3; do png | media_file "$PRIV/9/$i.png?jwt=q$i"; done
run_media 7 9
assert_jq '.outcome == "ok" and ([.media[] | select(.pr == 7) | .kind] == ["image","image","video"])' 'an upload, a repository file and the author'"'"'s recording'
assert_jq '.media[0].alt == "Plans \"filter\"" and (.media[0].path | endswith("/7-1.png")) and (.media[2].path | endswith(".mp4"))' 'alt text and file type travel with each file'
assert_jq '[.skipped[] | select(.pr == 7) | .reason] | sort == ["not an image or a video", "not hosted by GitHub for this repository"]' 'a badge and a non-image are skipped'
assert_jq '(.media | length) == 5 and ([.media[] | select(.pr == 9)] | length) == 2' 'at most three per PR and five in all'
assert_jq '[.media[] | select(.pr == 7) | .path] | all(test("bob") | not)' 'another commenter'"'"'s media is not taken'
assert_out_absent 'jwt' 'no attachment token in the output'
if grep -qi 'authorization' "$SANDBOX/files/calls"; then
  printf 'FAIL %s: the GitHub token reached curl\n' "$CASE"; FAILED=1
else printf 'ok   %s: curl never carries the GitHub token\n' "$CASE"; fi
[ -f "$SANDBOX/media/7-1.png" ] && printf 'ok   %s: files land in the media dir\n' "$CASE" \
  || { printf 'FAIL %s: files land in the media dir\n' "$CASE"; FAILED=1; }
OUT="$(CG_BRIEF_MEDIA_DIR="$SANDBOX/media" bash "$REPO_ROOT/scripts/brief-media.sh" clean)"
[ ! -e "$SANDBOX/media" ] && printf 'ok   %s: clean removes the media dir\n' "$CASE" \
  || { printf 'FAIL %s: clean removes the media dir\n' "$CASE"; FAILED=1; }

new_case brief_media_unreadable
base_config
mkdir -p "$SANDBOX/files"
fx_fail "api repos/acme/widgets/pulls/7 $HTML"
run_media 7
assert_jq '.outcome == "ok" and .media == [] and .skipped[0].reason == "PR not readable"' 'an unreadable PR is skipped, never an error'

new_case brief_media_comments_unreadable
base_config
mkdir -p "$SANDBOX/files"
jq -n --arg p "$PRIV" '{user:{login:"alice"}, body_html:("<img src=\"" + $p + "/1/a.png?jwt=t1\">")}' | fx "api repos/acme/widgets/pulls/7 $HTML"
fx_fail "api repos/acme/widgets/issues/7/comments?per_page=20 $HTML"
png | media_file "$PRIV/1/a.png?jwt=t1"
run_media 7
assert_jq '(.media | length) == 1 and .skipped[0].reason == "comments not readable"' 'a failed comment read is reported, and the body media still come'

finish
