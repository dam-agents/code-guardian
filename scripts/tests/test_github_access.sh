#!/usr/bin/env bash
# The access check (docs/github-access.md): identity and token type, the probe
# states, the progress channel, the feature map and a probe that wrote.
. "$(dirname "$0")/helpers.sh"

SHA="1111111111111111111111111111111111111111"
H='api --hostname github.com'

run_access() { # [args…] → $OUT
  OUT="$(GH_HOST="" WORK_DIR="$WORK" HOME="$FAKE_HOME" PATH="$T_DIR/bin:$PATH" \
         bash "$REPO_ROOT/scripts/github-access.sh" "$@" 2>>"$STDERR_LOG")"
}
code_fx() { # <http-code> <gh argument string>
  printf 'HTTP/2.0 %s X\r\n\r\n{}\n' "$1" | fx "$2"
}
# an open PR #7 at $SHA on acme/widgets, logged in as <login>
target_fx() { # <login>
  printf '{"data":{"viewer":{"login":"%s"}}}' "$1" | fx "$H graphql -f query={viewer{login}}"
  printf '{"data":{"viewer":{"login":"%s"}}}' "$1" | fx "api graphql -f query={viewer{login}}"   # the cache refresh
  code_fx 200 "$H -i -X GET repos/acme/widgets"
  printf 'main\n' | fx "$H repos/acme/widgets --jq .default_branch // \"main\""
  printf '7\n' | fx "$H repos/acme/widgets/pulls?state=open&per_page=1 --jq .[0].number // empty"
  printf '%s\n' "$SHA" | fx "$H repos/acme/widgets/pulls/7 --jq .head.sha // empty"
  code_fx 422 "$H -i -X POST repos/acme/widgets/pulls/7/reviews --input -"
  code_fx 422 "$H -i -X POST repos/acme/widgets/issues/7/comments --input -"
  code_fx 200 "$H -i -X GET repos/acme/widgets/commits/$SHA/check-runs?per_page=1"
  code_fx 200 "$H -i -X GET repos/acme/widgets/actions/runs?per_page=1"
  code_fx 422 "$H -i -X POST repos/acme/widgets/git/refs --input -"
  code_fx 422 "$H -i -X POST repos/acme/widgets/issues --input -"
}

# --- a GitHub App token: check runs, no statuses ---------------------------------
new_case access_app
base_config
target_fx 'acme-app[bot]'
code_fx 403 "$H -i -X POST repos/acme/widgets/statuses/$SHA --input -"
code_fx 422 "$H -i -X POST repos/acme/widgets/check-runs --input -"
run_access
assert_jq '.identity == {login:"acme-app[bot]", kind:"app", token:"app", scopes:null}' 'an App identity'
assert_jq '.progress_channel == "check_run"' 'an App writes check runs'
assert_jq '.features.review == "ok" and .features.issues == "ok" and .features.ci_triage == "ok" and .features.agent_fixes == "ok"' 'the granted features'
assert_jq '[.probes[] | select(.id == "statuses_write") | .state] == ["denied"]' 'a 403 probe is denied'
assert_jq '.triggers.review_request == true and .triggers.artifact_assignee == true and .triggers.mention_as == ["@test-bot"] and .triggers.missing == []' 'a user bot_login keeps every trigger'
assert_jq '.unexpected == []' 'no probe wrote'
jq -e '.login == "acme-app[bot]" and .kind == "app"' "$WORK/GITHUB.json" >/dev/null \
  && printf 'ok   %s: the identity cache is refreshed\n' "$CASE" \
  || { printf 'FAIL %s: GITHUB.json missing or wrong\n' "$CASE"; FAILED=1; }

# --- an unreadable identity cache reads as absent and is written fresh ------------
for bad in corrupt empty; do
  new_case "access_cache_$bad"
  base_config
  target_fx 'acme-app[bot]'
  code_fx 403 "$H -i -X POST repos/acme/widgets/statuses/$SHA --input -"
  code_fx 422 "$H -i -X POST repos/acme/widgets/check-runs --input -"
  case "$bad" in (corrupt) printf '{"login":"test-bot","kind":' > "$WORK/GITHUB.json";; (empty) : > "$WORK/GITHUB.json";; esac
  run_access
  jq -e '.login == "acme-app[bot]" and .kind == "app" and (.checked_at | length > 0) and (has("previous") | not)' "$WORK/GITHUB.json" >/dev/null 2>&1 \
    && printf 'ok   %s: the %s cache is replaced by the token identity\n' "$CASE" "$bad" \
    || { printf 'FAIL %s: GITHUB.json %s\n' "$CASE" "$(cat "$WORK/GITHUB.json" 2>/dev/null)"; FAILED=1; }
done

# --- a classic user token: scopes, commit statuses -------------------------------
new_case access_user
base_config
target_fx test-bot
printf 'HTTP/2.0 200 OK\r\nX-OAuth-Scopes: repo, read:org\r\n\r\n{}\n' | fx "$H user -i"
code_fx 422 "$H -i -X POST repos/acme/widgets/statuses/$SHA --input -"
code_fx 403 "$H -i -X POST repos/acme/widgets/check-runs --input -"
run_access
assert_jq '.identity.kind == "user" and .identity.token == "classic" and .identity.scopes == ["repo","read:org"]' 'a classic token with its scopes'
assert_jq '.progress_channel == "status"' 'a user token writes commit statuses'

# --- a bot bot_login serves label triggers only ------------------------------------
new_case access_bot_login
base_config
sed -i.bak 's/^- bot_login: test-bot$/- bot_login: acme-app[bot]/' "$WORK/CONFIG.md"
target_fx 'acme-app[bot]'
run_access
assert_jq '.triggers.review_request == false and .triggers.artifact_assignee == false and .triggers.label == true' 'a bot cannot be requested or assigned'
assert_jq '.triggers.mention_as == ["@acme-app", "@acme-app[bot]"]' 'people mention the App by its slug'
assert_jq '.triggers.missing == ["rereview_delta_label", "artifact_label"]' 'the label keys an App bot_login needs are named'

# --- an App bot_login with both labels has a trigger for every request -----------
new_case access_bot_login_labels
base_config '- rereview_delta_label: cg-delta' '- artifact_label: cg-artifact'
sed -i.bak 's/^- bot_login: test-bot$/- bot_login: acme-app[bot]/' "$WORK/CONFIG.md"
target_fx 'acme-app[bot]'
run_access
assert_jq '.triggers.delta_label == true and .triggers.artifact_label == true and .triggers.missing == []' 'the labels stand in for the request and the assignment'

# --- a refused issue probe is a missing feature, the review still works ----------
new_case access_issues_denied
base_config
target_fx 'acme-app[bot]'
code_fx 403 "$H -i -X POST repos/acme/widgets/issues --input -"
run_access
assert_jq '.features.issues == "missing" and .features.review == "ok"' 'comments without issue creation'

# --- GraphQL refused: the REST user read names the login -------------------------
new_case access_rest_fallback
base_config
target_fx test-bot
rm -f "$GH_FIXTURES/$(fx_for "$H graphql -f query={viewer{login}}")"
printf '{"login":"test-bot"}' | fx "$H user"
run_access
assert_jq '.identity.login == "test-bot" and .identity.kind == "user"' 'the REST read covers a refused GraphQL call'

# --- a probe that answers 2xx is reported --------------------------------------
new_case access_unexpected
base_config
target_fx 'acme-app[bot]'
code_fx 201 "$H -i -X POST repos/acme/widgets/statuses/$SHA --input -"
run_access
assert_jq '.unexpected == ["statuses_write"]' 'a probe that wrote is named'

# --- refs from the arguments, before work/CONFIG.md exists -----------------------
new_case access_args
target_fx 'acme-app[bot]'
code_fx 422 "$H -i -X POST repos/acme/state/git/refs --input -"
run_access --repo acme/widgets --work-repo acme/state --definition-repo acme/guardian
assert_jq '.target == "acme/widgets" and .features.work_backup == "ok"' 'the argument refs are probed'
assert_jq '.features.definition_prs == "unknown"' 'an unanswered probe is unknown, never ok'

# --- no login → an error, no report ----------------------------------------------
new_case access_unauthenticated
base_config
run_access
assert_jq '.error | test("not authenticated")' 'a broken connection is an error'

finish
