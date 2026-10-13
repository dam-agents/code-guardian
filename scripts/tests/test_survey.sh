#!/usr/bin/env bash
# Codebase survey (docs/survey.md): area selection is deterministic and local,
# the cadence floor holds, and scripts/survey.sh caps one pass.
. "$(dirname "$0")/helpers.sh"

profile_fx() { # <modules-json> [history-dirs-json]
  jq -n --argjson m "$1" --argjson h "${2:-[]}" \
    '{modules:$m, noise:[{glob:"**/*.lock",class:"lockfile"}], history:{dirs:$h}}' \
    > "$WORK/PROFILE.json"
}
survey_ledger() { # <rows…>
  { printf '# Codebase survey ledger\n\n'
    printf '| area | path | last_surveyed | passes | findings |\n'
    printf '|------|------|---------------|--------|----------|\n'
    for r in "$@"; do printf '%s\n' "$r"; done
  } > "$WORK/survey/LEDGER.md"
}

# --- disabled by default ------------------------------------------------------
new_case survey_disabled
base_config
profile_fx '[{"path":"src/api","name":"api"}]'
run_preflight survey
assert_jq '.nothing_to_do == true and (.survey_due | not)' 'no survey without the key'

# --- a never-surveyed area comes first ----------------------------------------
new_case survey_first_pass
base_config '- survey: enabled'
mkdir -p "$WORK/survey"
profile_fx '[{"path":"src/api","name":"api"},{"path":"src/ui","name":"ui"}]'
survey_ledger "| src_ui | src/ui | $(iso_ago 2592000) | 2 | 4 |"
run_preflight survey
assert_jq '.nothing_to_do == false' 'a due survey is work'
assert_jq '.survey_due | .slug == "src_api" and .path == "src/api" and .pass == 1 and .last_surveyed == null' 'the area nobody surveyed is chosen first'

# --- everything surveyed → the oldest pass wins -------------------------------
new_case survey_oldest
base_config '- survey: enabled'
mkdir -p "$WORK/survey"
profile_fx '[{"path":"src/api","name":"api"},{"path":"src/ui","name":"ui"}]'
survey_ledger "| src_api | src/api | $(iso_ago 1209600) | 1 | 2 |" \
              "| src_ui | src/ui | $(iso_ago 2592000) | 2 | 4 |"
run_preflight survey
assert_jq '.survey_due | .slug == "src_ui" and .pass == 3' 'the area surveyed longest ago is next, with its pass counted on'

# --- the cadence floor holds --------------------------------------------------
new_case survey_interval
base_config '- survey: enabled'
mkdir -p "$WORK/survey"
profile_fx '[{"path":"src/api","name":"api"}]'
survey_ledger "| src_api | src/api | $(iso_ago 86400) | 1 | 2 |"
run_preflight survey
assert_jq '.nothing_to_do == true' 'a survey inside the interval does not fire'
assert_jq '[.logs[] | select(test("< 7d"))] | length == 1' 'the floor says why'

# --- no profile → nothing to survey, never a guess ---------------------------
new_case survey_no_profile
base_config '- survey: enabled'
run_preflight survey
assert_jq '.nothing_to_do == true' 'no profile leaves nothing to survey'
assert_jq '[.logs[] | select(test("no module"))] | length == 1' 'the reason is logged'

# --- survey.sh prepare caps one pass -----------------------------------------
new_case survey_prepare_caps
base_config '- survey: enabled'
mkdir -p "$WORK/survey" "$SANDBOX/repo/src/api"
profile_fx '[{"path":"src/api","name":"api"}]'
git -C "$SANDBOX/repo" init -q 2>/dev/null
for i in $(seq 1 60); do printf 'line\n' > "$SANDBOX/repo/src/api/f$i.ts"; done
printf 'lockfileVersion: 1\n' > "$SANDBOX/repo/src/api/pnpm.lock"
git -C "$SANDBOX/repo" add -A 2>/dev/null
git -C "$SANDBOX/repo" -c user.email=t@t -c user.name=t commit -qm init 2>/dev/null
OUT="$(CG_SURVEY_CLONE_URL="$SANDBOX/repo" TMPDIR="$SANDBOX" \
       bash "$REPO_ROOT/scripts/survey.sh" prepare "$WORK" src_api 2>/dev/null)"
assert_jq '.outcome == "ready" and .counted.files == 40' 'the pass stops at the file cap'
assert_jq '.truncated == true and .remainder == 20' 'the rest is left for the next pass'
assert_jq '[.files[] | select(endswith(".lock"))] | length == 0' 'a noise glob is not surveyed as code'
assert_jq '.sha | test("^[0-9a-f]{40}$")' 'the pass names the commit it reads'

# --- the next pass resumes after the last file read, then the cycle restarts --
new_case survey_prepare_resume
base_config '- survey: enabled'
mkdir -p "$WORK/survey" "$SANDBOX/repo/src/api"
profile_fx '[{"path":"src/api","name":"api"}]'
git -C "$SANDBOX/repo" init -q 2>/dev/null
for i in $(seq 10 54); do printf 'line\n' > "$SANDBOX/repo/src/api/f$i.ts"; done
git -C "$SANDBOX/repo" add -A 2>/dev/null
git -C "$SANDBOX/repo" -c user.email=t@t -c user.name=t commit -qm init 2>/dev/null
survey_pass() { # prepare, then record an empty pass; $OUT is prepare's answer
  OUT="$(CG_SURVEY_CLONE_URL="$SANDBOX/repo" TMPDIR="$SANDBOX" \
         bash "$REPO_ROOT/scripts/survey.sh" prepare "$WORK" src_api 2>/dev/null)"
  printf '[]' > "$SANDBOX/none.json"
  TMPDIR="$SANDBOX" bash "$REPO_ROOT/scripts/survey.sh" record "$WORK" src_api "$SANDBOX/none.json" >/dev/null 2>&1
}
survey_pass
assert_jq '.after == null and .files[0] == "src/api/f10.ts" and .counted.files == 40 and .remainder == 5' 'the first pass starts at the first file'
assert_file_contains "$WORK/survey/src_api.md" '"last":"src/api/f49.ts"' 'the pass records the last file it read'
survey_pass
assert_jq '.after == "src/api/f49.ts" and .files == ["src/api/f50.ts","src/api/f51.ts","src/api/f52.ts","src/api/f53.ts","src/api/f54.ts"]' 'the next pass reads the rest of the area'
assert_jq '.truncated == false and .remainder == 0' 'the rest fits: nothing is left'
survey_pass
assert_jq '.after == null and .files[0] == "src/api/f10.ts" and .remainder == 5' 'after the last file the cycle starts again'

# --- an empty file in the area is counted as 0 lines, never a broken pass -----
new_case survey_prepare_empty_file
base_config '- survey: enabled'
mkdir -p "$WORK/survey" "$SANDBOX/repo/src/api"
profile_fx '[{"path":"src/api","name":"api"}]'
git -C "$SANDBOX/repo" init -q 2>/dev/null
printf 'line\n' > "$SANDBOX/repo/src/api/a.py"
: > "$SANDBOX/repo/src/api/b.py"
printf 'line\nline\n' > "$SANDBOX/repo/src/api/c.py"
git -C "$SANDBOX/repo" add -A 2>/dev/null
git -C "$SANDBOX/repo" -c user.email=t@t -c user.name=t commit -qm init 2>/dev/null
OUT="$(CG_SURVEY_CLONE_URL="$SANDBOX/repo" TMPDIR="$SANDBOX" \
       bash "$REPO_ROOT/scripts/survey.sh" prepare "$WORK" src_api 2>/dev/null)"
assert_jq '.outcome == "ready" and .counted.files == 3 and .counted.lines == 3' 'an empty file is listed with 0 lines'

# --- the first pass of an area learns its path from the profile --------------
new_case survey_record_first_pass
base_config '- survey: enabled'
mkdir -p "$WORK/survey"
profile_fx '[{"path":"src/api","name":"api"}]'
printf '[{"severity":"warning","summary":"duplicated parser","file":"src/api/a.ts","line":2}]' > "$SANDBOX/f.json"
TMPDIR="$SANDBOX" bash "$REPO_ROOT/scripts/survey.sh" record "$WORK" src_api "$SANDBOX/f.json" >/dev/null 2>&1
assert_file_contains "$WORK/survey/LEDGER.md" '| src_api | src/api |' 'the row carries the real path, not the slug'

# --- record appends the pass and moves the ledger row ------------------------
new_case survey_record
base_config '- survey: enabled'
mkdir -p "$WORK/survey"
survey_ledger "| src_api | src/api | $(iso_ago 1209600) | 1 | 2 |"
printf '[{"severity":"critical","summary":"unreachable export","file":"src/api/a.ts","line":4,"fix":"delete it"},
         {"severity":"suggestion","summary":"stale TODO","file":"src/api/b.ts","line":9}]' > "$SANDBOX/f.json"
OUT="$(TMPDIR="$SANDBOX" bash "$REPO_ROOT/scripts/survey.sh" record "$WORK" src_api "$SANDBOX/f.json" 2>/dev/null)"
assert_jq '.outcome == "recorded" and .pass == 2 and .counts.critical == 1' 'the pass is counted on'
assert_file_contains "$WORK/survey/src_api.md" '## Pass 2' 'the pass is appended to the area file'
assert_file_contains "$WORK/survey/src_api.md" 'findings-json' 'the findings travel with it'
assert_file_contains "$WORK/survey/LEDGER.md" '| src_api | src/api | 20' 'the ledger row carries the new pass'

# --- a padded ledger row is rewritten in place, as ledger_row finds it -----------
new_case survey_record_padded_row
base_config '- survey: enabled'
mkdir -p "$WORK/survey"
survey_ledger "| src_api    | src/api | $(iso_ago 1209600) | 1 | 2 |"
printf '[{"severity":"warning","summary":"duplicated parser","file":"src/api/a.ts","line":2}]' > "$SANDBOX/f.json"
OUT="$(TMPDIR="$SANDBOX" bash "$REPO_ROOT/scripts/survey.sh" record "$WORK" src_api "$SANDBOX/f.json" 2>/dev/null)"
assert_jq '.outcome == "recorded" and .pass == 2' 'the padded row is read'
assert_file_contains "$WORK/survey/LEDGER.md" '^| src_api | src/api | .* | 2 | 1 |$' 'the padded row carries the new pass'
[ "$(grep -c 'src_api' "$WORK/survey/LEDGER.md")" = 1 ] && printf 'ok   %s: one row per area\n' "$CASE" \
  || { printf 'FAIL %s: the area has more than one row\n' "$CASE"; FAILED=1; }

# --- report renders every area -----------------------------------------------
new_case survey_report
base_config '- survey: enabled'
mkdir -p "$WORK/survey"
survey_ledger "| src_api | src/api | $(iso_ago 86400) | 3 | 7 |" \
              "| src_ui | src/ui | $(iso_ago 604800) | 1 | 0 |"
bash "$REPO_ROOT/scripts/survey.sh" report "$WORK" > "$SANDBOX/report.html" 2>/dev/null
assert_file_contains "$SANDBOX/report.html" 'src/api' 'the report lists the areas'
assert_file_contains "$SANDBOX/report.html" 'Codebase survey' 'the report has its title'
grep -q 'http://\|https://.*\(cdn\|googleapis\)' "$SANDBOX/report.html" \
  && { printf 'FAIL %s: the page loads an external asset\n' "$CASE"; FAILED=1; } \
  || printf 'ok   %s: the page is self-contained\n' "$CASE"

# --- the findings reach the page only on the opt-in ---------------------------
# One area file holds a pass recorded before pass-json existed and one real
# prepare → record round, so the old pass links to HEAD and the new to its SHA.
survey_two_passes() {
  mkdir -p "$WORK/survey" "$SANDBOX/repo/src/api"
  profile_fx '[{"path":"src/api","name":"api"}]'
  git -C "$SANDBOX/repo" init -q 2>/dev/null
  printf 'a\nb\nc\n' > "$SANDBOX/repo/src/api/a.ts"
  git -C "$SANDBOX/repo" add -A 2>/dev/null
  git -C "$SANDBOX/repo" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -qm init 2>/dev/null
  SHA="$(git -C "$SANDBOX/repo" rev-parse HEAD)"
  { printf '# Survey — src/api\n\n## Pass 1 — %s — 0 🔴 · 1 🟡 · 0 🟢\n\n- warning — old (`src/api/old.ts:7`)\n\n' "$(iso_ago 1209600)"
    printf '<!-- findings-json: [{"severity":"warning","summary":"<script>alert(1)</script> & co","file":"src/api/old.ts","line":7,"fix":"a < b"}] -->\n'
  } > "$WORK/survey/src_api.md"
  survey_ledger "| src_api | src/api | $(iso_ago 1209600) | 1 | 1 |"
  CG_SURVEY_CLONE_URL="$SANDBOX/repo" TMPDIR="$SANDBOX" \
    bash "$REPO_ROOT/scripts/survey.sh" prepare "$WORK" src_api >/dev/null 2>&1
  printf '[{"severity":"critical","summary":"token compared with ==","file":"src/api/a.ts","line":2,"fix":"use timingSafeEqual"}]' > "$SANDBOX/f.json"
  TMPDIR="$SANDBOX" bash "$REPO_ROOT/scripts/survey.sh" record "$WORK" src_api "$SANDBOX/f.json" >/dev/null 2>&1
}

new_case survey_report_index_only
base_config '- survey: enabled'
survey_two_passes
assert_file_contains "$WORK/survey/src_api.md" "\"sha\":\"$SHA\"" 'record keeps the commit the pass read'
assert_file_contains "$WORK/survey/src_api.md" '"files":1' 'record keeps the file count'
bash "$REPO_ROOT/scripts/survey.sh" report "$WORK" > "$SANDBOX/report.html" 2>/dev/null
assert_file_contains "$SANDBOX/report.html" 'this page is the index' 'a missing key keeps the page an index'
assert_file_contains "$SANDBOX/report.html" '<td class="n">2</td><td class="n">1</td><td class="n">0</td><td class="n">0</td>' 'the index carries the severity counts of the newest pass'
grep -q 'timingSafeEqual\|blob/\|alert(1)' "$SANDBOX/report.html" \
  && { printf 'FAIL %s: a finding reached the index-only page\n' "$CASE"; FAILED=1; } \
  || printf 'ok   %s: no finding and no code link on the index-only page\n' "$CASE"

new_case survey_report_findings
base_config '- survey: enabled' '- survey_report_findings: enabled'
survey_two_passes
bash "$REPO_ROOT/scripts/survey.sh" report "$WORK" > "$SANDBOX/report.html" 2>/dev/null
assert_file_contains "$SANDBOX/report.html" '<a href="#src_api">src/api</a>' 'the index links to the area section'
assert_file_contains "$SANDBOX/report.html" "blob/$SHA/src/api/a.ts#L2\"><code>src/api/a.ts:2</code>" 'a location links to the line in the commit the pass read'
assert_file_contains "$SANDBOX/report.html" 'blob/HEAD/src/api/old.ts#L7' 'a pass without a recorded commit links to HEAD'
assert_file_contains "$SANDBOX/report.html" '<b>Fix:</b> use timingSafeEqual' 'the Fix line is on the page'
assert_file_contains "$SANDBOX/report.html" '&lt;script&gt;alert(1)&lt;/script&gt; &amp; co' 'finding text is HTML-escaped'
assert_file_contains "$SANDBOX/report.html" '<b>Fix:</b> a &lt; b' 'the Fix line is HTML-escaped'
assert_file_contains "$SANDBOX/report.html" "1 files at <a class=\"sha\" href=\"https://github.com/acme/widgets/tree/$SHA\">" 'the pass heading links to the commit'
grep -q '<script>' "$SANDBOX/report.html" \
  && { printf 'FAIL %s: raw finding text reached the page\n' "$CASE"; FAILED=1; } \
  || printf 'ok   %s: no raw finding text on the page\n' "$CASE"

# --- a double hyphen survives the findings-json round trip --------------------
new_case survey_report_double_hyphen
base_config '- survey: enabled' '- survey_report_findings: enabled'
mkdir -p "$WORK/survey"
survey_ledger "| src_api | src/api | $(iso_ago 1209600) | 0 | 0 |"
printf '[{"severity":"warning","summary":"flag --force ends a comment -->","file":"src/api/a--b.ts","line":2,"fix":"pass --dry-run"}]' > "$SANDBOX/f.json"
TMPDIR="$SANDBOX" bash "$REPO_ROOT/scripts/survey.sh" record "$WORK" src_api "$SANDBOX/f.json" >/dev/null 2>&1
sed -n 's/^<!-- findings-json: \(.*\) -->$/\1/p' "$WORK/survey/src_api.md" | grep -q -e '--' -e '–' \
  && { printf 'FAIL %s: the findings-json comment carries a double hyphen or an en dash\n' "$CASE"; FAILED=1; } \
  || printf 'ok   %s: no double hyphen and no en dash in the findings-json comment\n' "$CASE"
bash "$REPO_ROOT/scripts/survey.sh" report "$WORK" > "$SANDBOX/report.html" 2>/dev/null
assert_file_contains "$SANDBOX/report.html" 'blob/HEAD/src/api/a--b.ts#L2"><code>src/api/a--b.ts:2</code>' 'a double hyphen in a path keeps its code link'
assert_file_contains "$SANDBOX/report.html" 'flag --force ends a comment --&gt;' 'a double hyphen in the summary renders as written'
assert_file_contains "$SANDBOX/report.html" '<b>Fix:</b> pass --dry-run' 'a double hyphen in the Fix line renders as written'

# --- the public page carries no credential shape ------------------------------
new_case survey_report_redacted
base_config '- survey: enabled' '- survey_report_findings: enabled'
mkdir -p "$WORK/survey"
survey_ledger "| src_api | src/api | $(iso_ago 1209600) | 0 | 0 |"
printf '[{"severity":"critical","summary":"token ghp_abcdefghijklmnop1234 is committed","file":"src/api/a.ts","line":3,"fix":"move api_key = abcdefgh12345678 to the vault"}]' > "$SANDBOX/f.json"
TMPDIR="$SANDBOX" bash "$REPO_ROOT/scripts/survey.sh" record "$WORK" src_api "$SANDBOX/f.json" >/dev/null 2>&1
bash "$REPO_ROOT/scripts/survey.sh" report "$WORK" > "$SANDBOX/report.html" 2>/dev/null
assert_file_contains "$SANDBOX/report.html" 'token \[redacted] is committed' 'a token in a summary is masked on the page'
assert_file_contains "$SANDBOX/report.html" 'api_key = \[redacted] to the vault' 'a key assignment in a Fix line is masked on the page'
grep -q 'ghp_abcdefghijklmnop1234\|abcdefgh12345678' "$SANDBOX/report.html" \
  && { printf 'FAIL %s: a credential reached the page\n' "$CASE"; FAILED=1; } \
  || printf 'ok   %s: no credential on the page\n' "$CASE"
TMPDIR="$SANDBOX/no-such-dir" bash "$REPO_ROOT/scripts/survey.sh" report "$WORK" > "$SANDBOX/report.html" 2>/dev/null
RC=$?; OUT="$(cat "$SANDBOX/report.html")"
assert_rc 1 'a page the mask cannot reach exits 1'
assert_out_absent '.' 'and prints no page'

# --- a history above 128 KiB still renders ------------------------------------
# One argv entry stops at 128 KiB on Linux (MAX_ARG_STRLEN), so the history
# reaches jq on stdin. Pass 1 alone is above that bound.
new_case survey_report_large_history
base_config '- survey: enabled' '- survey_report_findings: enabled'
mkdir -p "$WORK/survey"
survey_ledger "| src_api | src/api | $(iso_ago 86400) | 2 | 1 |"
LONG="$(printf '%0300d' 0)"
{ printf '# Survey — src/api\n\n## Pass 1 — %s — 0 🔴 · 250 🟡 · 0 🟢\n\n' "$(iso_ago 1209600)"
  printf '<!-- findings-json: %s -->\n' "$(jq -nc --arg s "$LONG" \
    '[range(250) | {severity:"warning", summary:$s, file:"src/api/a.ts", line:2, fix:$s}]')"
  printf '\n## Pass 2 — %s — 0 🔴 · 1 🟡 · 0 🟢\n\n' "$(iso_ago 86400)"
  printf '<!-- findings-json: [{"severity":"warning","summary":"newest","file":"src/api/b.ts","line":1}] -->\n'
} > "$WORK/survey/src_api.md"
[ "$(( $(wc -c < "$WORK/survey/src_api.md") ))" -gt 131072 ] \
  || { printf 'FAIL %s: the fixture is not above 128 KiB\n' "$CASE"; FAILED=1; }
bash "$REPO_ROOT/scripts/survey.sh" report "$WORK" > "$SANDBOX/report.html" 2>/dev/null
assert_file_contains "$SANDBOX/report.html" '<a href="#src_api">src/api</a></td><td class="n">2</td><td class="n">0</td><td class="n">1</td>' 'the index row survives a history above 128 KiB'
n="$(grep -o '<li>' "$SANDBOX/report.html" | grep -c .)"
[ "$n" -eq 251 ] && printf 'ok   %s: every finding of a history above 128 KiB is on the page\n' "$CASE" \
  || { printf 'FAIL %s: %s of 251 findings on the page\n' "$CASE" "$n"; FAILED=1; }

# --- the resolved key travels in the worklist's config object -----------------
new_case survey_findings_config_default
base_config '- survey: enabled'
pr_json 1 "a new PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
run_preflight review
assert_jq '.config.survey_report_findings == "disabled"' 'a missing key resolves to disabled'

new_case survey_findings_config_enabled
base_config '- survey: enabled' '- survey_report_findings: enabled'
pr_json 1 "a new PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
run_preflight review
assert_jq '.config.survey_report_findings == "enabled"' 'the opt-in travels in the config object'

finish
