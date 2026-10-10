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
