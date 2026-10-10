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

# --- report findings: off unless the key enables them ------------------------
survey_area_fx() { # one recorded pass of src_api whose summary carries markup
  survey_ledger "| src_api | src/api | $(iso_ago 86400) | 1 | 1 |"
  printf '[{"severity":"warning","summary":"leaks `<script>x</script>`","file":"src/api/a.ts","line":7,"fix":"close it"}]' > "$SANDBOX/f.json"
  { printf '# Survey — src/api\n\n## Pass 1 — 2026-10-01T00:00:00Z — 0 🔴 · 1 🟡 · 0 🟢\n\n'
    printf '<!-- findings-json: %s -->\n' "$(jq -c . "$SANDBOX/f.json")"
  } > "$WORK/survey/src_api.md"
}
new_case survey_report_findings_off
base_config '- survey: enabled'
mkdir -p "$WORK/survey"
survey_area_fx
bash "$REPO_ROOT/scripts/survey.sh" report "$WORK" > "$SANDBOX/report.html" 2>/dev/null
grep -q 'src/api/a.ts\|<h2>Findings' "$SANDBOX/report.html" \
  && { printf 'FAIL %s: findings published without the key\n' "$CASE"; FAILED=1; } \
  || printf 'ok   %s: a missing key keeps the page an index\n' "$CASE"

new_case survey_report_findings_on
base_config '- survey: enabled' '- survey_report_findings: enabled'
mkdir -p "$WORK/survey"
survey_area_fx
bash "$REPO_ROOT/scripts/survey.sh" report "$WORK" > "$SANDBOX/report.html" 2>/dev/null
assert_file_contains "$SANDBOX/report.html" '<a href="#area-src_api">src/api</a>' 'the area row links to its findings'
assert_file_contains "$SANDBOX/report.html" '<h3 id="area-src_api">' 'the area has its anchor'
assert_file_contains "$SANDBOX/report.html" 'src/api/a.ts:7' 'the finding names its file and line'
assert_file_contains "$SANDBOX/report.html" '<strong>Fix:</strong> close it' 'the Fix line is shown'
assert_file_contains "$SANDBOX/report.html" '<code>&lt;script&gt;x&lt;/script&gt;</code>' 'finding text is escaped, backticks become code'
grep -q '<script>' "$SANDBOX/report.html" \
  && { printf 'FAIL %s: finding text reached the page unescaped\n' "$CASE"; FAILED=1; } \
  || printf 'ok   %s: no markup from a finding runs\n' "$CASE"
printf '\n## Pass 2 — 2026-10-08T00:00:00Z — 0 🔴 · 0 🟡 · 0 🟢\n\n<!-- findings-json: [{broken -->\n' >> "$WORK/survey/src_api.md"
bash "$REPO_ROOT/scripts/survey.sh" report "$WORK" > "$SANDBOX/report.html" 2>/dev/null
assert_file_contains "$SANDBOX/report.html" 'Pass 2 — 2026-10-08T00:00:00Z' 'a pass whose findings do not parse still appears'
assert_file_contains "$SANDBOX/report.html" 'could not be read' 'and says that its findings could not be read'
assert_file_contains "$SANDBOX/report.html" 'src/api/a.ts:7' 'the readable pass still renders'

finish
