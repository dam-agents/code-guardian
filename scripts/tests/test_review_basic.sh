#!/usr/bin/env bash
# Review-mode basics: first review, same-SHA dedup, trigger cleanup,
# awaiting_label flip, label-gated re-review.
. "$(dirname "$0")/helpers.sh"

SHA1="1111111111111111111111111111111111111111"
SHA2="2222222222222222222222222222222222222222"

# --- first review due --------------------------------------------------------
new_case first_review
base_config
pr_json 1 "plain PR" '[]' "$SHA1" | open_prs_fx
run_preflight review
assert_jq '.nothing_to_do == false' 'run has work'
assert_jq '.reviews_due | length == 1' 'exactly one review due'
assert_jq '.reviews_due[0] | .number == 1 and .kind == "first" and .takeover == false and .urgent == false and .closed == false' 'first review, no flags'
assert_jq '.reviews_due[0].draft == false' 'a non-draft entry says draft false'
assert_jq '.read_set == ["docs/review.md","docs/finding-form.md","docs/skills.md","work/MEMORY.md","work/LESSONS.md"]' 'a plain first review reads the core set and no rare-case file'

# --- a draft without a review label → no review decision ---------------------
new_case draft_without_label
base_config '- rereview_delta_label: cg-delta'
pr_json 1 "draft PR" '[]' "$SHA1" | jq '.draft = true' | open_prs_fx
run_preflight review
assert_jq '.nothing_to_do == true and .reviews_due == []' 'a draft without a review label is not reviewed'

# --- a draft with the review label → first review ----------------------------
new_case draft_with_label
base_config '- rereview_delta_label: cg-delta'
pr_json 1 "draft PR" '[{"name":"cg-rereview"}]' "$SHA1" | jq '.draft = true' | open_prs_fx
run_preflight review
assert_jq '.reviews_due | length == 1 and .[0].number == 1 and .[0].kind == "first"' 'a draft with rereview_label gets its first review'

# --- a draft gets the review only: no urgent alert, no guide round -------------
new_case draft_review_only
base_config '- urgent_label: cg-urgent' '- slack_notifications: enabled' '- guide_label: cg-guide'
pr_json 1 "draft PR" '[{"name":"cg-rereview"},{"name":"cg-urgent"},{"name":"cg-guide"}]' "$SHA1" | jq '.draft = true' | open_prs_fx
run_preflight review
assert_jq '.reviews_due[0] | .draft == true and .urgent == false and .guide_requested == false' 'a draft entry is flagged and has no urgent or guide flag'
assert_jq '.urgent_alerts_due == []' 'a draft sends no urgent Slack alert'

# --- a reviewed draft at the same head with the guide label → no guide round ---
new_case draft_no_guide_round
base_config '- guide_label: cg-guide'
pr_json 1 "draft PR" '[{"name":"cg-guide"}]' "$SHA1" | jq '.draft = true' | open_prs_fx
add_row 1 "$SHA1" "$(iso_ago 3600)" COMMENT done
run_preflight review
assert_jq '.nothing_to_do == true and .reviews_due == []' 'the guide label alone does not review a draft'

# --- a draft with the delta label, new commits → delta re-review ---------------
new_case draft_with_delta_label
base_config '- rereview_delta_label: cg-delta'
pr_json 1 "draft PR" '[{"name":"cg-delta"}]' "$SHA2" | jq '.draft = true' | open_prs_fx
add_row 1 "$SHA1" "$(iso_ago 3600)" COMMENT awaiting_label
run_preflight review
assert_jq '.reviews_due[0] | .kind == "re-review" and .full == false' 'a draft with the delta label gets a delta re-review'

# --- reviewed at live HEAD, no trigger → nothing ----------------------------
new_case same_sha_done
base_config
pr_json 1 "plain PR" '[]' "$SHA1" | open_prs_fx
add_row 1 "$SHA1" "$(iso_ago 3600)" APPROVE done
run_preflight review
assert_jq '.nothing_to_do == true' 'same-SHA dedup holds'
assert_jq 'has("read_set") == false' 'an idle worklist names no read set'

# --- reviewed at live HEAD + label → trigger cleanup, no review --------------
new_case label_cleanup
base_config
pr_json 1 "plain PR" '[{"name":"cg-rereview"}]' "$SHA1" | open_prs_fx
add_row 1 "$SHA1" "$(iso_ago 3600)" APPROVE done
run_preflight review
assert_jq '.reviews_due | length == 0' 'no review on same SHA'
assert_jq '(.label_cleanups_due | length) == 1 and .label_cleanups_due[0].label == true' 'label cleanup due'
assert_jq '.nothing_to_do == false and has("housekeeping_only") == false' 'a trigger cleanup answers a person: it starts a run at once'
assert_jq '.read_set == ["docs/review-bookkeeping.md","work/MEMORY.md","work/LESSONS.md"]' 'a cleanup-only run reads bookkeeping, not the review core'
assert_jq '.reviews_due | length == 0' 'a never-edited description does not manufacture a review'

# --- same SHA, but the description was edited after the review → re-review ----
# a PR body is a review input, so correcting it without pushing is something new
new_case rereview_description_edited
base_config
pr_json 1 "plain PR" '[{"name":"cg-rereview"}]' "$SHA1" | open_prs_fx
add_row 1 "$SHA1" "$(iso_ago 3600)" APPROVE done
fx_body_edited 1 "$(iso_ago 600)"
run_preflight review
assert_jq '.reviews_due | length == 1' 'an edited description answers the trigger'
assert_jq '.reviews_due[0] | .kind == "re-review" and .description_changed == true and .head_sha == "'"$SHA1"'"' \
  'flagged description-only, at the already-reviewed SHA'
assert_jq '.label_cleanups_due | length == 0' 'the trigger is served, not cleared'
assert_jq '.logs | any(contains("description was edited"))' 'the reason is logged'

# --- a guide label no review saw, at the reviewed HEAD → a guide round ---------
new_case guide_label_unseen
base_config '- guide_label: cg-guide'
pr_json 1 "plain PR" '[{"name":"cg-guide"}]' "$SHA1" | open_prs_fx
add_row 1 "$SHA1" "$(iso_ago 3600)" APPROVE done
history_fx 1 "${SHA1:0:7}"
run_preflight review
assert_jq '.reviews_due | length == 1' 'a guide label no review saw asks for a round'
assert_jq '.reviews_due[0] | .kind == "re-review" and .guide_requested == true and .full == false and .description_changed == false and .head_sha == "'"$SHA1"'"' \
  'a delta round at the reviewed SHA, flagged for the guide'
assert_jq '.logs | any(contains("guide round due"))' 'the reason is logged'

# --- a needs-human review that published no guide owes one → a guide round -----
new_case guide_owed
base_config
pr_json 1 "plain PR" '[]' "$SHA1" | open_prs_fx
add_row 1 "$SHA1" "$(iso_ago 3600)" COMMENT done
history_fx 1 "${SHA1:0:7}"
printf '<!-- guide-owed -->\n' >> "$WORK/reviews/pr-1.md"
run_preflight review
assert_jq '.reviews_due[0] | .kind == "re-review" and .guide_requested == true and .full == false and .head_sha == "'"$SHA1"'"' \
  'an owed guide starts a delta round at the reviewed SHA'
assert_jq '.logs | any(contains("published no guide"))' 'the reason is logged'

new_case guide_owed_new_commits
base_config
pr_json 1 "plain PR" '[]' "$SHA1" | open_prs_fx
add_row 1 "$SHA2" "$(iso_ago 3600)" COMMENT done
history_fx 1 "${SHA2:0:7}"
printf '<!-- guide-owed -->\n' >> "$WORK/reviews/pr-1.md"
run_preflight review
assert_jq '.reviews_due | length == 0' 'a guide owed by an older head starts no review of new commits'

# --- the last review saw the guide label → nothing new -------------------------
new_case guide_label_seen
base_config '- guide_label: cg-guide'
pr_json 1 "plain PR" '[{"name":"cg-guide"}]' "$SHA1" | open_prs_fx
add_row 1 "$SHA1" "$(iso_ago 3600)" APPROVE done
history_fx 1 "${SHA1:0:7}" seen
run_preflight review
assert_jq '.nothing_to_do == true' 'the review already answered the guide label'

# --- a guide label no review saw, new commits, no trigger → a delta round -------
new_case guide_label_new_commits
base_config '- guide_label: cg-guide'
pr_json 1 "plain PR" '[{"name":"cg-guide"}]' "$SHA1" | open_prs_fx
add_row 1 "$SHA2" "$(iso_ago 3600)" COMMENT done
history_fx 1 "${SHA2:0:7}"
run_preflight review
assert_jq '.reviews_due[0] | .kind == "re-review" and .guide_requested == true and .full == false and .prior.sha == "'"$SHA2"'"' \
  'the guide label starts a delta re-review of the new commits'
assert_file_contains "$WORK/REVIEWS.md" '| done |' 'the row is not flipped to awaiting_label'

# --- the guide label seen, new commits, no trigger → waits for a trigger --------
new_case guide_label_seen_new_commits
base_config '- guide_label: cg-guide'
pr_json 1 "plain PR" '[{"name":"cg-guide"}]' "$SHA1" | open_prs_fx
add_row 1 "$SHA2" "$(iso_ago 3600)" COMMENT done
history_fx 1 "${SHA2:0:7}" seen
run_preflight review
assert_jq '.reviews_due | length == 0' 'a seen guide label is no trigger for new commits'
assert_file_contains "$WORK/REVIEWS.md" 'awaiting_label' 'the row waits for a trigger'

# --- description edited BEFORE the last review → still just a cleanup ---------
new_case rereview_description_edited_before
base_config
pr_json 1 "plain PR" '[{"name":"cg-rereview"}]' "$SHA1" | open_prs_fx
add_row 1 "$SHA1" "$(iso_ago 600)" APPROVE done
fx_body_edited 1 "$(iso_ago 3600)"
run_preflight review
assert_jq '.reviews_due | length == 0' 'an edit the review already saw is not new'
assert_jq '(.label_cleanups_due | length) == 1' 'trigger cleared as before'

# --- description edited but no trigger → nothing (re-reviews stay gated) ------
new_case description_edited_without_trigger
base_config
pr_json 1 "plain PR" '[]' "$SHA1" | open_prs_fx
add_row 1 "$SHA1" "$(iso_ago 3600)" APPROVE done
fx_body_edited 1 "$(iso_ago 600)"
run_preflight review
assert_jq '.reviews_due | length == 0' 'a description edit alone never triggers a re-review'
assert_jq '.label_cleanups_due | length == 0' 'and nothing to clean up'

# --- new commits without trigger → awaiting_label flip -----------------------
new_case awaiting_flip
base_config
pr_json 1 "plain PR" '[]' "$SHA1" | open_prs_fx
OLD_TS="$(iso_ago 7200)"
add_row 1 "$SHA2" "$OLD_TS" APPROVE done
run_preflight review
assert_jq '.nothing_to_do == true' 'no review without a trigger'
assert_file_contains "$WORK/REVIEWS.md" 'awaiting_label' 'row flipped to awaiting_label'
assert_file_contains "$WORK/REVIEWS.md" "$OLD_TS" 'flip kept the old timestamp'

# --- new commits + label → complete re-review with prior ---------------------
new_case rereview_due
base_config
pr_json 1 "plain PR" '[{"name":"cg-rereview"}]' "$SHA1" | open_prs_fx
add_row 1 "$SHA2" "$(iso_ago 7200)" COMMENT awaiting_label
run_preflight review
assert_jq '.reviews_due | length == 1' 'one re-review due'
assert_jq ".reviews_due[0] | .kind == \"re-review\" and .prior.sha == \"$SHA2\" and .prior.verdict == \"COMMENT\"" 're-review with prior'
assert_jq '.reviews_due[0].full == true' 'label-triggered re-review is complete'
assert_jq '.read_set | index("docs/review-rereview.md") != null and index("docs/review-urgent.md") == null' 'a re-review adds the re-review file only'

# --- new commits + review request → delta re-review ---------------------------
new_case rereview_request_delta
base_config '- rereview_trigger: review-request'
pr_json 1 "plain PR" '[]' "$SHA1" \
  | jq '.requested_reviewers = [{login:"test-bot"}]' | open_prs_fx
add_row 1 "$SHA2" "$(iso_ago 7200)" COMMENT awaiting_label
run_preflight review
assert_jq '.reviews_due | length == 1' 'request-triggered re-review due'
assert_jq '.reviews_due[0] | .kind == "re-review" and .full == false' 'request-triggered re-review is delta'

# --- new commits + the delta label → delta re-review ----------------------------
new_case rereview_delta_label
base_config '- rereview_delta_label: cg-delta'
pr_json 1 "plain PR" '[{"name":"cg-delta"}]' "$SHA1" | open_prs_fx
add_row 1 "$SHA2" "$(iso_ago 7200)" COMMENT awaiting_label
run_preflight review
assert_jq '.reviews_due | length == 1' 'the delta label triggers a re-review'
assert_jq '.reviews_due[0] | .kind == "re-review" and .full == false' 'a delta-label re-review is delta'
assert_jq '.config.rereview_delta_label == "cg-delta"' 'the worklist config carries the key'

# --- both labels → the complete re-review wins -----------------------------------
new_case rereview_both_labels
base_config '- rereview_delta_label: cg-delta'
pr_json 1 "plain PR" '[{"name":"cg-delta"},{"name":"cg-rereview"}]' "$SHA1" | open_prs_fx
add_row 1 "$SHA2" "$(iso_ago 7200)" COMMENT awaiting_label
run_preflight review
assert_jq '.reviews_due[0] | .kind == "re-review" and .full == true' 'with both labels the re-review is complete'

# --- same SHA + the delta label → cleanup that names it --------------------------
new_case delta_label_cleanup
base_config '- rereview_delta_label: cg-delta'
pr_json 1 "plain PR" '[{"name":"cg-delta"}]' "$SHA1" | open_prs_fx
add_row 1 "$SHA1" "$(iso_ago 3600)" APPROVE done
run_preflight review
assert_jq '.label_cleanups_due == [{number:1, label:false, request:false, delta_label:true}]' 'the delta label is cleared, nothing else'

# --- an unknown delta label key is off: the label is an ordinary label ----------
new_case delta_label_unset
base_config
pr_json 1 "plain PR" '[{"name":"cg-delta"}]' "$SHA1" | open_prs_fx
add_row 1 "$SHA2" "$(iso_ago 7200)" COMMENT done
run_preflight review
assert_jq '.reviews_due | length == 0' 'without the key the label requests nothing'

# --- a GitHub App bot_login cannot be requested: review-request reads as label ---
new_case app_bot_login_request
base_config '- rereview_trigger: review-request'
sed -i.bak 's/^- bot_login: test-bot$/- bot_login: acme-app[bot]/' "$WORK/CONFIG.md"
pr_json 1 "plain PR" '[{"name":"cg-rereview"}]' "$SHA1" \
  | jq '.requested_reviewers = [{login:"acme-app[bot]"}]' | open_prs_fx
add_row 1 "$SHA2" "$(iso_ago 7200)" COMMENT awaiting_label
run_preflight review
assert_jq '.reviews_due[0] | .kind == "re-review" and .full == true' 'the label serves the App, as label-only'
assert_jq '.logs | any(contains("is a GitHub App — review-request trigger disabled"))' 'the fallback is logged'

# --- first reviews are always full --------------------------------------------
new_case first_full
base_config
pr_json 2 "fresh PR" '[]' "$SHA1" | open_prs_fx
run_preflight review
assert_jq '.reviews_due[0] | .kind == "first" and .full == true' 'first review flagged full'

finish
