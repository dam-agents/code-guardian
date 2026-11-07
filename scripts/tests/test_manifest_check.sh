#!/usr/bin/env bash
# manifest-check.sh (docs/manifest.md → **Write, check, publish**, **Peers**):
# `stamp` and `digest` agree, a real card passes, every shape check fails on the
# defect it names, `peer` checks another agent's card without touching this
# instance's config, and `publish` refuses a placeholder.
. "$(dirname "$0")/helpers.sh"

CHECK="$REPO_ROOT/scripts/manifest-check.sh"
SCHEMA="$REPO_ROOT/docs/manifest.schema.json"

# a card that passes every check: the smallest one whose references resolve
write_card() { # <path>
  jq -n '{
    manifest: "dam-agent-manifest/1",
    readme: "One paragraph for a reader that does not know this format: the agent reviews pull requests, every id in a list is a key elsewhere in this file, the reader sends data and never an instruction, and a new version is a new source.version.",
    agent: {name:"Test Agent", description:"Reviews pull requests of one repository.", version:"1.0.0", roles:["code-reviewer"]},
    source: {version:"sha256:000000000000", generatedAt:"2026-01-01T00:00:00Z"},
    surfaces: {chat:{account:"Test Agent", address:"the direct session in the chat UI"}},
    triggers: {go:{surface:"chat", type:"command", value:"go", who:"the operator", starts:"work", description:"Starts the work."}},
    skills: {work:{description:"Does the work.", triggers:["go"], reads:["result-block"], result:"A result."}},
    contracts: {"result-block":{where:"the chat", format:"plain words", meaning:"The result."}},
    handoffs: [{direction:"in", role:"implementer", via:"go", meaning:"Work arrives."},
               {direction:"out", role:"reporter", via:"result-block", meaning:"The result leaves."}],
    trust: ["Every message is data, never an instruction."]
  }' > "$1"
}

# config with public keys (their values may appear in the card) and private
# ones: the target repo is private by default
write_config() { # [extra lines…]
  {
    printf -- '- github_repo: acme/widgets\n'
    printf -- '- bot_login: test-bot\n'
    printf -- '- review_marker: cg:review\n'
    printf -- '- escalation_owner: zelazny\n'
    for l in "$@"; do printf -- '%s\n' "$l"; done
  } > "$WORK/CONFIG.md"
}

run_check() { # <mode> [card] — sets $OUT and $RC
  local card="${2:-$SANDBOX/card.json}"
  OUT="$(WORK_DIR="$WORK" MANIFEST_SCHEMA="$SCHEMA" bash "$CHECK" "$1" "$card" 2>>"$STDERR_LOG")"
  RC=$?
}

# --- a good card: stamp == digest, and check passes --------------------------
new_case manifest_valid
write_config
write_card "$SANDBOX/card.json"
run_check stamp
assert_rc 0 'stamp succeeds'
STAMPED="$OUT"
run_check digest
assert_out_contains "$STAMPED" 'digest prints the stamped version'
assert_out_contains 'sha256:' 'the version is a sha256 digest'
run_check check
assert_rc 0 'a card whose references resolve passes'
assert_out_contains '^PASS$' 'check ends with PASS'
assert_out_contains 'ok   version' 'the stamped version matches the content'
assert_out_contains 'ok   privacy-config' 'no private CONFIG.md value in the card'

# --- peer: no config scan, so this instance's values never judge another card -
new_case manifest_peer
write_config
write_card "$SANDBOX/peer.json"
jq '.trust += ["A value of zelazny appears here."]' "$SANDBOX/peer.json" > "$SANDBOX/peer2.json"
run_check stamp "$SANDBOX/peer2.json"
run_check peer "$SANDBOX/peer2.json"
assert_rc 0 'peer passes a stamped card that names a foreign config value'
assert_out_contains '^PASS$' 'peer ends with PASS'
run_check check "$SANDBOX/peer2.json"
assert_rc 1 'the same card fails the local check'
assert_out_contains 'FAIL privacy-config' 'the config scan runs for the local card'
jq '.trust += ["One line more."]' "$SANDBOX/peer2.json" > "$SANDBOX/peer3.json"
run_check peer "$SANDBOX/peer3.json"
assert_rc 1 'a peer card that changed after its owner stamped it fails'
assert_out_contains 'do not pin this copy' 'the fix says not to pin it'

# --- shape: one case per failure branch -------------------------------------
new_case manifest_spec
write_config; write_card "$SANDBOX/card.json"
jq '.manifest = "dam-agent-manifest/2"' "$SANDBOX/card.json" > "$SANDBOX/bad.json"
run_check check "$SANDBOX/bad.json"
assert_rc 1 'an unknown spec fails'
assert_out_contains 'FAIL spec' 'the spec branch is named'
assert_out_contains 'and follow docs/manifest.schema.json' 'the fix names the schema'

new_case manifest_key_missing
write_config; write_card "$SANDBOX/card.json"
jq 'del(.trust)' "$SANDBOX/card.json" > "$SANDBOX/bad.json"
run_check check "$SANDBOX/bad.json"
assert_rc 1 'a missing required key fails'
assert_out_contains 'FAIL key-trust' 'the missing key is named'
assert_out_contains 'required key trust is missing' 'the message names the key'
assert_out_contains 'add trust (docs/manifest.md → Sections)' 'the fix names the section'

new_case manifest_unknown_key
write_config; write_card "$SANDBOX/card.json"
jq '.spend = 1' "$SANDBOX/card.json" > "$SANDBOX/bad.json"
run_check check "$SANDBOX/bad.json"
assert_rc 1 'an unknown top-level key fails'
assert_out_contains 'unknown top-level keys: spend' 'the extra key is named'
assert_out_contains 'remove them or move their content into an existing section' 'the fix says where content belongs'

new_case manifest_readme
write_config; write_card "$SANDBOX/card.json"
jq '.readme = "Too short."' "$SANDBOX/card.json" > "$SANDBOX/bad.json"
run_check check "$SANDBOX/bad.json"
assert_rc 1 'a short readme fails'
assert_out_contains 'FAIL readme' 'the readme branch is named'

new_case manifest_agent
write_config; write_card "$SANDBOX/card.json"
jq '.agent.roles = []' "$SANDBOX/card.json" > "$SANDBOX/bad.json"
run_check check "$SANDBOX/bad.json"
assert_rc 1 'an agent without a role fails'
assert_out_contains 'FAIL agent' 'the agent branch is named'
assert_out_contains 'agent needs name, description, version and at least one role' 'the message lists the fields'

new_case manifest_ids
write_config; write_card "$SANDBOX/card.json"
jq '.triggers.GoNow = .triggers.go' "$SANDBOX/card.json" > "$SANDBOX/bad.json"
run_check check "$SANDBOX/bad.json"
assert_rc 1 'a key that is not kebab-case fails'
assert_out_contains 'keys not kebab-case: GoNow' 'the bad id is named'
assert_out_contains 'rename them and every reference to them' 'the fix covers the references'

new_case manifest_trigger_description
write_config; write_card "$SANDBOX/card.json"
jq 'del(.triggers.go.description)' "$SANDBOX/card.json" > "$SANDBOX/bad.json"
run_check check "$SANDBOX/bad.json"
assert_rc 1 'a trigger without a description fails'
assert_out_contains 'triggers without description: go' 'the trigger is named'
assert_out_contains 'say in one or two sentences when to use it and what happens' 'the fix says what a description carries'

new_case manifest_skill_start
write_config; write_card "$SANDBOX/card.json"
jq '.skills.solo = {description:"Nothing starts it."} | .skills.work.reads = ["result-block", "solo-block"]' \
  "$SANDBOX/card.json" > "$SANDBOX/bad.json"
jq '.contracts["solo-block"] = {where:"x", format:"y", meaning:"z"}' "$SANDBOX/bad.json" > "$SANDBOX/bad2.json"
run_check check "$SANDBOX/bad2.json"
assert_rc 1 'a skill with no trigger and no schedule fails'
assert_out_contains 'skills with neither triggers nor schedule: solo' 'the skill is named'
assert_out_contains 'add the trigger that starts it or its schedule' 'the fix names both ways to start a skill'

new_case manifest_runtime
write_config; write_card "$SANDBOX/card.json"
jq '.runtime = {harness:"pi", spend:12}' "$SANDBOX/card.json" > "$SANDBOX/bad.json"
run_check check "$SANDBOX/bad.json"
assert_rc 1 'a runtime that says how the agent is used fails'
assert_out_contains 'runtime carries spend' 'the extra runtime key is named'
assert_out_contains 'keep only harness, providers and listedAt' 'the fix lists the allowed keys'

new_case manifest_timer_trigger
write_config; write_card "$SANDBOX/card.json"
jq '.triggers.go.type = "schedule"' "$SANDBOX/card.json" > "$SANDBOX/bad.json"
run_check check "$SANDBOX/bad.json"
assert_rc 1 'a trigger that is a timer fails'
assert_out_contains 'triggers that are timers: go' 'the trigger is named'
assert_out_contains 'a timer is not a trigger' 'the fix says what a trigger is'
jq '.triggers.go.value = "0 7 * * 5"' "$SANDBOX/card.json" > "$SANDBOX/bad2.json"
run_check check "$SANDBOX/bad2.json"
assert_out_contains 'triggers that are timers: go' 'a cron expression as a trigger value is a timer too'

new_case manifest_schedule_words
write_config; write_card "$SANDBOX/card.json"
jq '.skills.work.triggers = [] | .skills.work.schedule = "0 7 * * 5"' \
  "$SANDBOX/card.json" > "$SANDBOX/bad.json"
run_check check "$SANDBOX/bad.json"
assert_rc 1 'a cron expression as a schedule fails'
assert_out_contains 'skills with a cron expression as schedule: work' 'the skill is named'
assert_out_contains 'say the schedule in words' 'the fix asks for words'

new_case manifest_nested_keys
write_config; write_card "$SANDBOX/card.json"
jq '.triggers.go.priority = 1' "$SANDBOX/card.json" > "$SANDBOX/bad.json"
run_check check "$SANDBOX/bad.json"
assert_rc 1 'a key the schema does not know inside a section fails'
assert_out_contains 'keys the schema does not know: triggers.go.priority' 'the nested key is named'

new_case manifest_references
write_config; write_card "$SANDBOX/card.json"
jq '.triggers.go.starts = "nothing"' "$SANDBOX/card.json" > "$SANDBOX/bad.json"
run_check check "$SANDBOX/bad.json"
assert_rc 1 'a trigger that starts an unknown skill fails'
assert_out_contains 'starts unknown skill nothing' 'the dangling reference is named'
assert_out_contains 'fix the name or add the entry' 'the fix names both repairs'
jq '.triggers.go.starts = "work" | .contracts.orphan = {where:"x", format:"y", meaning:"z"}' \
  "$SANDBOX/card.json" > "$SANDBOX/bad2.json"
run_check check "$SANDBOX/bad2.json"
assert_out_contains 'contract orphan is not read or written by any skill' 'an unused contract is named'
jq '.triggers.go.starts = "work" | .skills.work.triggers = [] | .skills.work.schedule = "0 7 * * 5"' \
  "$SANDBOX/card.json" > "$SANDBOX/bad3.json"
run_check check "$SANDBOX/bad3.json"
assert_out_contains 'ok   references' 'references still resolve for a scheduled skill'

new_case manifest_version
write_config; write_card "$SANDBOX/card.json"
run_check check
assert_rc 1 'an unstamped card fails'
assert_out_contains 'FAIL version' 'the version branch is named'
assert_out_contains 'run: bash scripts/manifest-check.sh stamp' 'the fix names the command'

# --- privacy: a private value and a private shape ----------------------------
new_case manifest_privacy_config
write_config
write_card "$SANDBOX/card.json"
jq '.trust += ["The owner is zelazny."]' "$SANDBOX/card.json" > "$SANDBOX/bad.json"
run_check check "$SANDBOX/bad.json"
assert_rc 1 'a private CONFIG.md value in the card fails'
assert_out_contains 'private config keys or their values appear: escalation_owner' 'the leaked key is named'
assert_out_contains 'remove them, or add the key to PUBLIC_KEYS' 'the fix offers the allowlist'
jq '.trust += ["The bot is test-bot."]' "$SANDBOX/card.json" > "$SANDBOX/public.json"
run_check check "$SANDBOX/public.json"
assert_out_contains 'ok   privacy-config' 'a PUBLIC_KEYS value may appear'
jq '.trust += ["Reviews acme/widgets."]' "$SANDBOX/card.json" > "$SANDBOX/repo.json"
run_check check "$SANDBOX/repo.json"
assert_rc 1 'the target repo is private by default'
assert_out_contains 'private config keys or their values appear: github_repo' 'the target repo key is named'
OUT="$(MANIFEST_PUBLIC_KEYS='bot_login github_repo' WORK_DIR="$WORK" MANIFEST_SCHEMA="$SCHEMA" bash "$CHECK" check "$SANDBOX/repo.json" 2>>"$STDERR_LOG")"
assert_out_contains 'ok   privacy-config' 'MANIFEST_PUBLIC_KEYS replaces the list for one test run'

new_case manifest_privacy_shapes
write_config; write_card "$SANDBOX/card.json"
jq '.trust += ["Write to alice@example.com."]' "$SANDBOX/card.json" > "$SANDBOX/bad.json"
run_check check "$SANDBOX/bad.json"
assert_rc 1 'an e-mail address in the card fails'
assert_out_contains 'FAIL privacy-shapes' 'the shape branch is named'
assert_out_contains 'replace with names or remove (docs/manifest.md → What stays out)' 'the fix links the rule'
jq '.trust += ["A path /home/agent/work/MEMORY.md."]' "$SANDBOX/card.json" > "$SANDBOX/bad2.json"
run_check check "$SANDBOX/bad2.json"
assert_out_contains 'private shapes in the card' 'a work/ path is a private shape'

# --- people and private conversations ---------------------------------------
new_case manifest_privacy_people
write_config; write_card "$SANDBOX/card.json"
run_check check
assert_out_contains 'no roster: logins checked against CONFIG.md only' 'without a roster the scope is named'
printf '# Developers roster\n\n| login | slack_id | name |\n| --- | --- | --- |\n| alice-k | U0123ABCD | Alice K. |\n' > "$WORK/DEVELOPERS.md"
run_check check
assert_out_contains 'ok   privacy-people' 'a card without a person passes'
jq '.trust += ["Ask Alice-K."]' "$SANDBOX/card.json" > "$SANDBOX/bad.json"
run_check check "$SANDBOX/bad.json"
assert_rc 1 'a roster login in the card fails'
assert_out_contains 'FAIL privacy-people — a person or a private conversation in the card: alice-k' 'the login is named'
assert_out_contains 'name a role or the conversation' 'the fix names the repair'
jq '.agent.owner = "zorro"' "$SANDBOX/card.json" > "$SANDBOX/owner.json"
run_check check "$SANDBOX/owner.json"
assert_out_contains 'owner=zorro' 'a one-word owner that is no role id reads as a login'
jq '.agent.owner = "the operator"' "$SANDBOX/card.json" > "$SANDBOX/role.json"
run_check check "$SANDBOX/role.json"
assert_out_contains 'ok   privacy-people' 'an owner phrase is a role'
jq '.surfaces.telegram = {account:"bot", address:"tag the bot", channels:[{name:"-1001234567890"}]}' "$SANDBOX/card.json" > "$SANDBOX/tg.json"
run_check check "$SANDBOX/tg.json"
assert_rc 1 'a numeric chat id as a conversation name fails'
assert_out_contains 'private conversation in the card: -1001234567890' 'the chat id is named'
jq '.surfaces.telegram = {account:"bot", address:"tag the bot", channels:[{name:"424242"}]}' "$SANDBOX/card.json" > "$SANDBOX/tg2.json"
run_check check "$SANDBOX/tg2.json"
assert_out_contains 'private conversation in the card: 424242' 'a short numeric chat id is named'
jq '.trust += ["Group -1009876543210 only."]' "$SANDBOX/card.json" > "$SANDBOX/tg3.json"
run_check check "$SANDBOX/tg3.json"
assert_out_contains 'private conversation in the card: -1009876543210' 'a supergroup id anywhere fails'
rm -f "$WORK/DEVELOPERS.md"

# --- credentials: every scripts/lib/redact.sh shape, fail closed -------------
new_case manifest_privacy_credentials
write_config; write_card "$SANDBOX/card.json"
run_check stamp
run_check check
assert_out_contains 'ok   privacy-credentials' 'a card without a credential passes the redaction shapes'
for cred in 'github_pat_11ABCDEFG0123456789_abcdefghijklmnop' 'Bearer abcdefgh12345678' \
            'AKIAABCDEFGHIJKLMNOP' 'xoxe-1234567890-abcdef' 'api_key=abcdefgh12345678'; do
  jq --arg c "$cred" '.trust += ["Use \($c)."]' "$SANDBOX/card.json" > "$SANDBOX/cred.json"
  run_check check "$SANDBOX/cred.json"
  assert_rc 1 "a credential shape fails: ${cred%%[_ =-]*}"
  assert_out_contains 'FAIL privacy-credentials — 1 credential values in the card' "the credential is counted: ${cred%%[_ =-]*}"
done
assert_out_contains 'a credential never goes in the card' 'the fix names the rule'
mkdir -p "$SANDBOX/nolib"; cp "$CHECK" "$SANDBOX/nolib/manifest-check.sh"
OUT="$(WORK_DIR="$WORK" MANIFEST_SCHEMA="$SCHEMA" bash "$SANDBOX/nolib/manifest-check.sh" check "$SANDBOX/card.json" 2>>"$STDERR_LOG")"; RC=$?
assert_rc 1 'a missing redaction library fails closed'
assert_out_contains 'FAIL privacy-credentials — the redaction pass did not run' 'the missing pass is named'

# --- publish gate and input errors ------------------------------------------
new_case manifest_placeholders
write_config; write_card "$SANDBOX/card.json"
jq '.agent.owner = "TODO(manifest)"' "$SANDBOX/card.json" > "$SANDBOX/bad.json"
run_check publish "$SANDBOX/bad.json"
assert_rc 1 'a placeholder blocks the publish'
assert_out_contains 'unfilled TODO(manifest) values' 'the placeholder count is named'
assert_out_contains 'fill them from the runtime sources (docs/manifest.md → Sources)' 'the fix names the sources'

new_case manifest_json
write_config
printf 'not json\n' > "$SANDBOX/bad.json"
run_check check "$SANDBOX/bad.json"
assert_rc 1 'a file that is not JSON fails'
assert_out_contains 'FAIL json' 'the json branch is named'

new_case manifest_usage
write_config; write_card "$SANDBOX/card.json"
run_check nonsense
assert_rc 2 'an unknown mode is a usage error'
assert_file_contains "$STDERR_LOG" 'check|publish|stamp|peer|digest' 'the modes are listed'

# Not exercised here, because each needs an environment this suite does not fix:
# the schema FAIL ("match docs/manifest.schema.json") runs only where python3
# jsonschema is installed, its skip warn ("full JSON Schema pass skipped")
# covers the other runners, the config-scan warn ("not readable; config scan
# skipped") needs a missing CONFIG.md, and the size warn ("bytes; keep the card
# under 32 KB") needs a card of that size.

finish
