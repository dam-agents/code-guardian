#!/usr/bin/env bash
# Project profile (scripts/profile.sh, docs/profile.md): generation from a
# fixture repository, fingerprint-driven refresh, history and notes, the
# per-PR slice, and the degraded modes (disabled, unreachable, API fallback).
. "$(dirname "$0")/helpers.sh"

PROFILE="$REPO_ROOT/scripts/profile.sh"
GIT_ID=(-c user.name=t -c user.email=t@example.test -c commit.gpgsign=false)

# a fixture repository with one of everything the detectors read
mk_fixture() { # → $FX (path), $FX_SHA
  FX="$SANDBOX/fx"; mkdir -p "$FX"
  git -C "$FX" init -q
  git -C "$FX" checkout -q -b main 2>/dev/null || true
  git -C "$FX" config uploadpack.allowFilter true
  mkdir -p "$FX/packages/a/src" "$FX/packages/b/src" "$FX/docs/architecture" "$FX/docs/adrs" "$FX/.github/workflows"
  printf '{"name":"widgets","private":true,"workspaces":["packages/*"]}\n' > "$FX/package.json"
  printf '{"name":"@acme/api-server","description":"HTTP API for widgets"}\n' > "$FX/packages/a/package.json"
  printf '{"name":"@acme/web"}\n' > "$FX/packages/b/package.json"
  printf '# Web client\n\nThe customer-facing app.\n' > "$FX/packages/b/README.md"
  printf 'export const x = 1;\n' > "$FX/packages/a/src/index.ts"
  printf 'export const y = 1;\n' > "$FX/packages/b/src/index.tsx"
  printf -- '---\ntitle: Metrics\npaths: [packages/a/src/**]\nlast_verified: 2026-07-01\n---\n# Metrics\n' > "$FX/docs/architecture/metrics.md"
  printf '# Web\n\nSee packages/b/src for the client. Last verified: 2026-05-14\n' > "$FX/docs/architecture/web.md"
  printf -- '---\nstatus: accepted\ndate: 2026-04-02\nsubsystem: api-server\n---\n# ADR 0031: Read models are rebuilt from events\n' > "$FX/docs/adrs/0031-read-models.md"
  printf 'packages/a/** @acme/backend\n' > "$FX/CODEOWNERS"
  printf 'name: ci\non:\n  pull_request:\n  push:\n    branches: [main]\njobs: {}\n' > "$FX/.github/workflows/ci.yml"
  printf 'packages/b/src/generated/** linguist-generated=true\n' > "$FX/.gitattributes"
  printf '# Repo rules\n\n- no comments in code\n' > "$FX/CLAUDE.md"
  printf 'lockfileVersion: 9\n' > "$FX/pnpm-lock.yaml"
  fx_commit init
}
fx_commit() { git -C "$FX" add -A && git -C "$FX" "${GIT_ID[@]}" commit -qm "$1" && FX_SHA="$(git -C "$FX" rev-parse HEAD)"; }

run_profile() { # <cmd> [args…] → $OUT (the JSON status / slice)
  OUT="$(GITHUB_REPO="${TEST_REF:-$TEST_REPO}" GH_HOST="" WORK_DIR="$WORK" HOME="$FAKE_HOME" \
         CG_PROFILE_REMOTE="${PROFILE_REMOTE:-$FX}" CG_MIRROR_ROOT="$SANDBOX/mirror" \
         PATH="$T_DIR/bin:$PATH" bash "$PROFILE" "$@" 2>/dev/null)"
}
assert_profile() { # <jq expr over PROFILE.json> <description>
  if jq -e "$1" "$WORK/PROFILE.json" >/dev/null 2>&1; then printf 'ok   %s: %s\n' "$CASE" "$2"
  else printf 'FAIL %s: %s\n     expr: %s\n' "$CASE" "$2" "$1"; FAILED=1; fi
}

# --- first check builds the profile from the mirror -------------------------
new_case profile_first_check
base_config; mk_fixture
run_profile check
assert_jq '.status == "regenerated" and .mode == "mirror"' 'first check regenerates from the mirror'
assert_jq '.base == "'"${FX_SHA:0:12}"'" and .verified == .base' 'base and verified are the fixture tip'
assert_profile '.fingerprint | type == "string" and length == 40' 'fingerprint recorded'
assert_profile '.modules | length == 3' 'root + two workspace packages detected'
assert_profile '.modules[] | select(.path == "packages/a") | .name == "@acme/api-server" and .kind == "node" and .workspace == true and .role == "HTTP API for widgets"' 'manifest name, kind, workspace flag and description'
assert_profile '.modules[] | select(.path == "packages/b") | .role | startswith("Web client")' 'README heading feeds a role when the manifest has none'
assert_profile '.docs[] | select(.page == "docs/architecture/metrics.md") | .paths == ["packages/a/src/**"] and .via == "frontmatter" and .stamp == "2026-07-01" and .title == "Metrics"' 'front-matter mapping, stamp and title'
assert_profile '.docs[] | select(.page == "docs/architecture/web.md") | .paths == ["packages/b/src/**"] and .via == "mention" and .stamp == "2026-05-14"' 'path mention mapping and Last verified line'
assert_profile '.decisions == [{id:"0031", title:"Read models are rebuilt from events", status:"accepted", scope:"api-server", date:"2026-04-02", src:"docs/adrs/0031-read-models.md"}]' 'ADR row from front matter and heading'
assert_profile '.conventions[0] | .path == "CLAUDE.md" and (.content | contains("no comments in code"))' 'convention file copied verbatim'
assert_profile '.ownership == [{pattern:"packages/a/**", owners:"@acme/backend", src:"CODEOWNERS"}]' 'CODEOWNERS rows'
assert_profile '.checks.workflows[0] | .workflow == "ci.yml" and .name == "ci" and .on == "pull_request, push"' 'workflow name and triggers'
assert_profile '[.noise[] | select(.src == ".gitattributes")] == [{glob:"packages/b/src/generated/**", class:"generated", src:".gitattributes"}]' 'linguist-generated glob joins the built-in noise'
assert_profile '.structure.doc_roots == ["docs"] and .structure.adr_dirs == ["docs/adrs"]' 'doc roots and ADR dirs recorded for the slice'
assert_file_contains "$WORK/PROFILE.md" '^## Modules (3)' 'PROFILE.md rendered'
assert_file_contains "$WORK/PROFILE.md" '^fingerprint: [0-9a-f]\{40\}' 'render carries the fingerprint header'

# --- second check: nothing moved → current, no rewrite of base ----------------
run_profile check
assert_jq '.status == "current" and .mode == "mirror"' 'unchanged tip is current'

# --- a code-only commit keeps the profile, moves verified -------------------
new_case profile_code_commit
base_config; mk_fixture
run_profile check
BASE_SHA="$FX_SHA"
printf 'export const x = 2;\n' > "$FX/packages/a/src/index.ts"; fx_commit "code change"
run_profile check
assert_jq '.status == "current"' 'a code commit leaves the structure fingerprint unchanged'
assert_jq '.verified == "'"${FX_SHA:0:12}"'" and .base == "'"${BASE_SHA:0:12}"'"' 'verified advances to the new tip, base stays'
assert_out_contains 'structure unchanged' 'the reason is stated'

# --- a manifest edit changes the fingerprint → regeneration -----------------
new_case profile_structure_commit
base_config; mk_fixture
run_profile check
printf '{"name":"@acme/api-server","description":"HTTP API v2"}\n' > "$FX/packages/a/package.json"; fx_commit "manifest change"
run_profile check
assert_jq '.status == "regenerated"' 'a manifest change regenerates'
assert_profile '.modules[] | select(.path == "packages/a") | .role == "HTTP API v2"' 'the new description is in the profile'
assert_jq '.base == "'"${FX_SHA:0:12}"'"' 'base moved to the new tip'

# --- TTL and definition version are backstops ---------------------------------
new_case profile_ttl_backstop
base_config; mk_fixture
run_profile check
jq '.generated = "2026-01-01T00:00:00Z"' "$WORK/PROFILE.json" > "$WORK/p.tmp" && mv "$WORK/p.tmp" "$WORK/PROFILE.json"
run_profile check
assert_jq '.status == "regenerated"' 'a profile past the TTL regenerates even with an unchanged structure'
jq '.generator = "0.0.1"' "$WORK/PROFILE.json" > "$WORK/p.tmp" && mv "$WORK/p.tmp" "$WORK/PROFILE.json"
run_profile check
assert_jq '.status == "regenerated"' 'a definition version change regenerates'
assert_profile '.generator != "0.0.1"' 'generator is the running definition version'

# --- generate is unconditional ------------------------------------------------
new_case profile_generate_forces
base_config; mk_fixture
run_profile check
run_profile generate
assert_jq '.status == "regenerated"' 'generate rebuilds an already-current profile'

# --- history: findings-json of posted reviews, aggregated per directory -------
new_case profile_history
base_config; mk_fixture
cat > "$WORK/reviews/pr-7.md" <<EOF
# PR #7: t

## Review at aaaaaaa — $(iso_ago 86400) — COMMENT

### Summary
x
<!-- findings-json: [{"status":"new","severity":"critical","file":"packages/a/src/query.ts","line":42,"inline":true,"summary":"unbounded query","fix":"add limit"},{"status":"still","severity":"warning","file":"packages/a/src/index.ts","line":1,"inline":false,"summary":"missing index","fix":"add index"},{"status":"fixed","severity":"warning","file":"packages/b/src/index.tsx","line":1,"inline":false,"summary":"stale prop","fix":null}] -->
<!-- cg:review headRefOid=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa -->
EOF
cat > "$WORK/reviews/pr-8.md" <<EOF
# PR #8: old

## Review at bbbbbbb — 2025-01-01T00:00:00Z — COMMENT

<!-- findings-json: [{"status":"new","severity":"critical","file":"packages/a/src/old.ts","line":1,"inline":false,"summary":"ancient","fix":"x"}] -->
EOF
run_profile check
assert_profile '.history | .reviews == 1 and .findings == 3 and .fixed == 1 and .still == 1' 'only the 90-day window counts; totals right'
assert_profile '.history.dirs[0] | .dir == "packages/a/src" and .critical == 1 and .warning == 1 and .still == 1 and .prs == 1' 'per-directory row with open counts'
assert_profile '.history.dirs[0].samples | index("unbounded query") != null' 'sample summaries kept'
assert_profile '[.history.classes[].summary] | index("ancient") == null' 'a finding outside the window is not a class'
assert_file_contains "$WORK/PROFILE.md" '^## History (90 d · 1 reviews · 3 findings' 'history header rendered'

# --- notes: agent-owned rows stamped with their source blob -------------------
new_case profile_notes
base_config; mk_fixture
printf '| paths | note | src |\n| --- | --- | --- |\n| packages/a/** | Money is integer minor units | packages/a/package.json |\n| packages/b/** | free-floating note | |\n' > "$WORK/PROFILE-NOTES.md"
run_profile check
assert_profile '.notes | length == 2' 'both rows read'
assert_profile '.notes[0] | .status == "new" and (.blob | length) == 40' 'a first-seen note is new and stamped'
assert_profile '.notes[1].status == "unanchored"' 'a note without a source is unanchored'
run_profile generate
assert_profile '.notes[0].status == "current"' 'unchanged source → current'
printf '{"name":"@acme/api-server","description":"changed"}\n' > "$FX/packages/a/package.json"; fx_commit "touch source"
run_profile check
assert_profile '.notes[0].status == "stale"' 'a changed source blob marks the note stale'
git -C "$FX" rm -q packages/a/package.json && fx_commit "drop source"
run_profile check
assert_profile '.notes[0].status == "orphan"' 'a vanished source marks the note orphan'

# --- slice: classes, rows, verify_live, structure, history, memory ------------
new_case profile_slice
base_config; mk_fixture
cat > "$WORK/reviews/pr-7.md" <<EOF
# PR #7: t

## Review at aaaaaaa — $(iso_ago 86400) — COMMENT

<!-- findings-json: [{"status":"new","severity":"critical","file":"packages/a/src/query.ts","line":42,"inline":true,"summary":"unbounded query","fix":"add limit"}] -->
EOF
mkdir -p "$WORK/memory"
printf -- '---\nscope: [packages/a/**]\n---\n# api-server notes\n' > "$WORK/memory/api-server.md"
printf -- '---\nscope: [packages/b/**]\n---\n# web notes\n' > "$WORK/memory/web.md"
printf -- '---\nscope: [infra/**, deploy/*.yaml]\n---\n# infra notes\n' > "$WORK/memory/infra.md"
run_profile check
cat > "$SANDBOX/files.json" <<'EOF'
[{"filename":"packages/a/src/query.ts","status":"modified"},
 {"filename":"pnpm-lock.yaml","status":"modified"},
 {"filename":"packages/b/src/generated/x.ts","status":"added"},
 {"filename":"packages/a/src/query.test.ts","status":"added"},
 {"filename":"docs/architecture/metrics.md","status":"modified"},
 {"filename":"packages/a/package.json","status":"modified"},
 {"filename":"__snapshots__/a.snap","status":"added"},
 {"filename":".github/workflows/ci.yml","status":"modified"}]
EOF
run_profile slice "$SANDBOX/files.json"
assert_jq '[.files[] | .class] == ["code","lockfile","generated","test","docs","config","snapshot","config"]' 'every file gets its class'
assert_jq '.noise_count == 3' 'lockfile, generated and snapshot are noise'
assert_jq '[.profile_slice[] | select(.section == "modules")] | length == 3 and any(.[]; .row | startswith("packages/a — @acme/api-server"))' 'touched module rows (root, packages/a, packages/b)'
assert_jq '[.profile_slice[] | select(.section == "modules" and (.row | startswith("packages/a")))] | .[0].verify_live == true' 'module row whose manifest the PR edits is verify_live'
assert_jq '[.profile_slice[] | select(.section == "modules" and (.row | startswith("packages/b")))] | .[0].verify_live == false' 'a touched module whose manifest is untouched is not verify_live'
assert_jq '[.profile_slice[] | select(.section == "docs" and (.row | contains("metrics.md")))] | length == 1 and .[0].verify_live == true' 'doc page the PR edits is verify_live'
assert_jq '[.profile_slice[] | select(.section == "docs" and (.row | contains("web.md")))] | length == 1 and .[0].verify_live == false' 'doc page covering touched code but not edited is listed, not verify_live'
assert_jq '[.profile_slice[] | select(.section == "decisions")] | length == 1' 'ADR scoped to the touched module is listed'
assert_jq '[.profile_slice[] | select(.section == "ownership")] | length == 1' 'CODEOWNERS rule covering the change is listed'
assert_jq '[.profile_slice[] | select(.section == "checks")] | length == 1' 'workflow rows appear when a workflow changes'
assert_jq '.structure_changed == ["docs/architecture/metrics.md","packages/a/package.json",".github/workflows/ci.yml"]' 'structure-bearing paths of the PR are named'
assert_jq '.history_slice | length == 1 and .[0].dir == "packages/a/src"' 'history rows for the touched directory'
assert_jq '.memory_due == ["work/memory/api-server.md","work/memory/web.md"]' 'area memory whose scope matches is due, unrelated scopes are not'

# --- slice without a profile still classifies (built-in noise only) -----------
new_case profile_slice_no_profile
base_config
printf '[{"filename":"a/b.ts"},{"filename":"yarn.lock"},{"filename":"x/dist/y.js"}]\n' > "$SANDBOX/files.json"
run_profile slice "$SANDBOX/files.json"
assert_jq '[.files[].class] == ["code","lockfile","build"] and .profile_slice == [] and .memory_due == []' 'built-in classes, empty slice'

# --- disabled by configuration -------------------------------------------------
new_case profile_disabled
base_config '- project_profile: disabled'; mk_fixture
run_profile check
assert_jq '.status == "disabled"' 'disabled key short-circuits'
[ -f "$WORK/PROFILE.json" ] && { printf 'FAIL %s: profile written despite disabled\n' "$CASE"; FAILED=1; } || printf 'ok   %s: nothing written\n' "$CASE"

# --- remote unreachable: keep what exists, never fail the run ------------------
new_case profile_unreachable
base_config; mk_fixture
PROFILE_REMOTE="$SANDBOX/does-not-exist" run_profile check
assert_jq '.status == "unavailable"' 'no profile and no remote → unavailable'
run_profile check
assert_jq '.status == "regenerated"' 'reachable again → built'
PROFILE_REMOTE="$SANDBOX/does-not-exist" run_profile check
assert_jq '.status == "unverified"' 'stored profile survives an outage as unverified'

# --- API fallback when git cannot reach the remote -----------------------------
new_case profile_api_fallback
base_config; mk_fixture
API_SHA="cccccccccccccccccccccccccccccccccccccccc"
printf '{"default_branch":"main"}\n' | fx 'api repos/acme/widgets'
printf '{"commit":{"sha":"%s"}}\n' "$API_SHA" | fx "api repos/acme/widgets/branches/main"
jq -n --arg s "$API_SHA" '{sha:$s, truncated:false, tree:[
  {type:"blob", sha:"1111111111111111111111111111111111111111", path:"package.json"},
  {type:"tree", sha:"2222222222222222222222222222222222222222", path:"svc"},
  {type:"blob", sha:"3333333333333333333333333333333333333333", path:"svc/go.mod"},
  {type:"blob", sha:"4444444444444444444444444444444444444444", path:"svc/main.go"}]}' \
  | fx "api repos/acme/widgets/git/trees/$API_SHA?recursive=1"
printf '{"name":"root-app","description":"root"}\n' | fx "api repos/acme/widgets/contents/package.json?ref=$API_SHA -H Accept: application/vnd.github.raw"
printf 'module example.com/svc\n' | fx "api repos/acme/widgets/contents/svc/go.mod?ref=$API_SHA -H Accept: application/vnd.github.raw"
PROFILE_REMOTE="$SANDBOX/does-not-exist" run_profile check
assert_jq '.status == "regenerated" and .mode == "api"' 'API tree builds the profile when git cannot'
assert_profile '[.modules[] | .path] == [".", "svc"] and (.modules[1] | .kind == "go" and .name == "example.com/svc")' 'modules from the API tree and contents'
assert_profile '.fingerprint | type == "string"' 'the API tree still yields a fingerprint'

# ============================================================ preflight wiring
SHA1="1111111111111111111111111111111111111111"
skills_config() { # base config + a skills table with always and extension rows
  base_config '' '## Review skills' '' \
    '| skill | source | trigger | section |' '| --- | --- | --- | --- |' \
    '| doc-drift | harness | always | Documentation Check |' \
    '| react-ui-engineering | harness | .tsx,.jsx | React Review |' \
    '| typescript-engineering | harness | .ts,.mts,.js | TypeScript Review |'
}
files_fx() { # <number> <files-json>
  printf '%s' "$2" | fx "api --paginate repos/acme/widgets/pulls/$1/files?per_page=100"
}

# --- a due review carries profile status, inventory, slice, routing, config ---
new_case preflight_profile_wiring
skills_config; mk_fixture
mkdir -p "$WORK/memory"
printf -- '---\nscope: [packages/a/**]\n---\n# api-server notes\n' > "$WORK/memory/api-server.md"
pr_json 1 "metrics PR" '[]' "$SHA1" | open_prs_fx
files_fx 1 '[{"filename":"packages/a/src/query.ts","status":"modified"},{"filename":"packages/b/src/view.tsx","status":"added"},{"filename":"pnpm-lock.yaml","status":"modified"},{"filename":"packages/a/package.json","status":"modified"}]'
PROFILE_REMOTE="$FX" run_preflight review
assert_jq '.reviews_due | length == 1' 'review due'
assert_jq '.profile.status == "regenerated" and .profile.mode == "mirror" and (.profile.file | endswith("/PROFILE.md"))' 'profile refreshed and reported'
assert_jq '.logs | any(startswith("project profile: regenerated"))' 'profile status logged'
assert_jq '.reviews_due[0].files | length == 4 and ([.[].class] == ["code","code","lockfile","config"])' 'changed files classified'
assert_jq '.reviews_due[0] | .noise_count == 1 and .files_truncated == false' 'noise counted, list complete'
assert_jq '.reviews_due[0].profile_slice | any(.[]; .section == "modules" and (.row | startswith("packages/a")) and .verify_live == true)' 'module row with verify_live in the entry'
assert_jq '.reviews_due[0].structure_changed == ["packages/a/package.json"]' 'structure-bearing change named'
assert_jq '.reviews_due[0].memory_due == ["work/memory/api-server.md"]' 'area memory selected by scope'
assert_jq '.reviews_due[0].skill_routing == {"react-ui-engineering":["packages/b/src/view.tsx"],"typescript-engineering":["packages/a/src/query.ts"]}' 'extension routing per trigger list, always skills excluded'
assert_jq '.config | .active_hours == "00-23" and .active_days == "Mon-Sun" and .review_interval_active == 5 and .review_interval_quiet == 60' 'cadence keys resolved with their defaults'
assert_jq '.config | .bot_login == "test-bot" and .review_marker == "cg:review" and .rereview_label == "cg-rereview" and .rereview_trigger == "label" and .mention_replies == "enabled" and .slack_notifications == "disabled" and .project_profile == "enabled" and (.skills_table | length == 3) and .watch_rules == []' 'resolved config with defaults and tables'
assert_jq '.memory | .memory_limit == 120 and .over_budget == false' 'memory budget measured'
[ -f "$WORK/PROFILE.md" ] && printf 'ok   %s: PROFILE.md written under work/\n' "$CASE" || { printf 'FAIL %s: PROFILE.md missing\n' "$CASE"; FAILED=1; }

# --- overlapping trigger lists: every matching skill receives the file ------
new_case preflight_routing_inclusive
base_config '' '## Review skills' '' \
  '| skill | source | trigger | section |' '| --- | --- | --- | --- |' \
  '| lint-all | harness | .ts,.tsx | Lint |' \
  '| react-ui-engineering | harness | .tsx | React Review |'
pr_json 1 "overlap PR" '[]' "$SHA1" | open_prs_fx
files_fx 1 '[{"filename":"a.tsx","status":"added"},{"filename":"b.ts","status":"added"},{"filename":"c.md","status":"added"}]'
run_preflight review
assert_jq '.reviews_due[0].skill_routing == {"lint-all":["a.tsx","b.ts"],"react-ui-engineering":["a.tsx"]}' 'a file goes to every skill whose trigger matches (docs/skills.md)'

# --- an idle heartbeat touches neither the profile nor the config output ------
new_case preflight_profile_idle
skills_config; mk_fixture
pr_json 1 "plain PR" '[]' "$SHA1" | open_prs_fx
add_row 1 "$SHA1" "$(iso_ago 3600)" APPROVE done
PROFILE_REMOTE="$FX" run_preflight review
assert_jq '.nothing_to_do == true and has("profile") == false and has("config") == false' 'idle run emits no profile or config'
[ -f "$WORK/PROFILE.json" ] && { printf 'FAIL %s: profile built on an idle heartbeat\n' "$CASE"; FAILED=1; } || printf 'ok   %s: no profile work on an idle heartbeat\n' "$CASE"

# --- disabled profile still classifies files and routes skills ----------------
new_case preflight_profile_disabled
skills_config; mk_fixture
printf -- '- project_profile: disabled\n' >> "$WORK/CONFIG.md"
pr_json 1 "plain PR" '[]' "$SHA1" | open_prs_fx
files_fx 1 '[{"filename":"a.ts","status":"added"},{"filename":"yarn.lock","status":"modified"}]'
PROFILE_REMOTE="$FX" run_preflight review
assert_jq '.profile.status == "disabled"' 'disabled reported'
assert_jq '.reviews_due[0] | ([.files[].class] == ["code","lockfile"]) and .profile_slice == [] and .skill_routing["typescript-engineering"] == ["a.ts"]' 'built-in classes and routing without a profile'

# --- an unreachable remote never blocks the review ----------------------------
new_case preflight_profile_unreachable
skills_config
pr_json 1 "plain PR" '[]' "$SHA1" | open_prs_fx
files_fx 1 '[{"filename":"a.ts","status":"added"}]'
run_preflight review
assert_jq '.reviews_due | length == 1' 'review still due'
assert_jq '.profile.status == "unavailable"' 'profile unavailable is reported, not fatal'
assert_jq '.reviews_due[0].files[0].class == "code"' 'files still classified'

# --- a failed file list leaves files null -------------------------------------
new_case preflight_files_unavailable
skills_config
pr_json 1 "plain PR" '[]' "$SHA1" | open_prs_fx
fx_fail "api --paginate repos/acme/widgets/pulls/1/files?per_page=100"
run_preflight review
assert_jq '.reviews_due[0].files == null and (.reviews_due[0] | has("skill_routing") | not)' 'no list → files null, no routing'
assert_jq '.logs | any(contains("changed-file list unavailable"))' 'the fallback is logged'

# --- memory budget: review log line + audit check -----------------------------
new_case memory_budget
base_config
pr_json 1 "plain PR" '[]' "$SHA1" | open_prs_fx
{ printf '# Review Preferences\n\n## Observed Insights\n'; for i in $(seq 1 17); do printf -- '- [observed] insight %s\n' "$i"; done; printf '\n## Feedback Log\n'; for i in $(seq 1 3); do printf -- '- [f] %s\n' "$i"; done; } > "$WORK/MEMORY.md"
run_preflight review
assert_jq '.memory | .insights == 17 and .feedback == 3 and .memory_lines == 25 and .over_budget == true' 'insight overrun measured'
assert_jq '.logs | any(startswith("memory over budget"))' 'overrun logged when a review is due'
run_preflight audit
assert_jq '.checks[] | select(.id == "memory_budget") | .status == "warn"' 'audit warns over the documented bound'
{ for i in $(seq 1 190); do printf 'line %s\n' "$i"; done; } > "$WORK/MEMORY.md"
run_preflight audit
assert_jq '.checks[] | select(.id == "memory_budget") | .status == "fail"' 'audit fails at 1.5× the bound'
printf '# Review Preferences\n\n## Feedback Log\n- one\n' > "$WORK/MEMORY.md"
run_preflight audit
assert_jq '.checks[] | select(.id == "memory_budget") | .status == "ok"' 'within bounds is ok'

# --- audit: profile_fresh ------------------------------------------------------
new_case audit_profile_fresh
base_config; mk_fixture
pr_json 1 "plain PR" '[]' "$SHA1" | open_prs_fx
PROFILE_REMOTE="$FX" run_preflight audit
assert_jq '.checks[] | select(.id == "profile_fresh") | .status == "warn" and (.detail | contains("stale until this audit"))' 'a profile built only by the audit is a warn'
PROFILE_REMOTE="$FX" run_preflight audit
assert_jq '.checks[] | select(.id == "profile_fresh") | .status == "ok"' 'a current profile is ok'
run_preflight audit
assert_jq '.checks[] | select(.id == "profile_fresh") | .status == "warn" and (.detail | contains("could not be verified"))' 'an unreachable remote is a warn, the stored profile stands'
printf -- '- project_profile: disabled\n' >> "$WORK/CONFIG.md"
run_preflight audit
assert_jq '.checks[] | select(.id == "profile_fresh") | .status == "ok" and (.detail | contains("disabled"))' 'disabled is reported ok'

finish
