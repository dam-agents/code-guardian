#!/usr/bin/env bash
# benchmark isolation — benchmark-isolate.sh (check, bundle, start, wait,
# collect) and benchmark-child.sh (unpack, report): the repository gates, a
# bundle that never carries ground truth, the spawn request a sub-agent gets,
# the result collection with its provenance check, and the sub-agent guards of
# preflight.sh and work-backup.sh. Contract: docs/benchmark.md → Isolation.
. "$(dirname "$0")/helpers.sh"

ISO="$REPO_ROOT/scripts/benchmark-isolate.sh"
CHILD="$REPO_ROOT/scripts/benchmark-child.sh"
MCP_URL="http://platform.test/api/agents/a1/mcp"
REST_BASE="http://platform.test/api/agents/a1"
SUMMARY="token compared with == instead of a constant-time check"

check_eq() { # <actual> <expected> <description>
  if [ "$1" = "$2" ]; then printf 'ok   %s: %s\n' "$CASE" "$3"
  else printf 'FAIL %s: %s\n     got:  %s\n     want: %s\n' "$CASE" "$3" "$1" "$2"; FAILED=1; fi
}

vis_fx() { printf '{"visibility":"%s"}' "$2" | fx "api --hostname github.com repos/$1"; }

# a fixture set of one slug, a definition checkout at $FAKE_HOME and the
# platform's MCP URL — what a run on a pod has
iso_case() { # <case> [config lines…]
  new_case "$1"; shift
  base_config '- work_repo: acme/cg-state' '- definition_repo: acme/cg-def' "$@"
  printf '# Memory\n' > "$WORK/MEMORY.md"; printf '# Lessons\n' > "$WORK/LESSONS.md"
  F="$WORK/benchmark/fixture/ts-api"
  mkdir -p "$F/base" "$F/head-v1" "$F/head-v2"
  printf 'a\n' > "$F/base/a.ts"; printf 'b\n' > "$F/head-v1/a.ts"; printf 'c\n' > "$F/head-v2/a.ts"
  printf '{"number":0}' > "$F/pr.json"; : > "$F/diff-v1.patch"; : > "$F/diff-v1-v2.patch"
  printf 'prior\n' > "$F/prior-review.md"
  jq -n --arg s "$SUMMARY" '{fixture:"ts-api", defects:[{id:"D01", file:"a.ts", summary:$s}]}' > "$F/manifest.json"
  mkdir -p "$FAKE_HOME/.claude/skills/.cache" "$FAKE_HOME/.claude/skills/sec-check"
  printf 'skill\n' > "$FAKE_HOME/.claude/skills/sec-check/SKILL.md"
  printf 'abc123' > "$FAKE_HOME/.claude/skills/.cache/sec-check.sha"
  printf '{"mcpServers":{"platform-outbound":{"type":"http","url":"%s"}}}\n' "$MCP_URL" > "$FAKE_HOME/.mcp.json"
  mkdir -p "$FAKE_HOME/docs" "$SANDBOX/rest"
  printf 'definition\n' > "$FAKE_HOME/docs/x.md"
  git -C "$FAKE_HOME" init -q
  git -C "$FAKE_HOME" -c user.email=t@t -c user.name=t add docs
  git -C "$FAKE_HOME" -c user.email=t@t -c user.name=t commit -qm def
  HEAD_SHA="$(git -C "$FAKE_HOME" rev-parse HEAD)"
  vis_fx acme/cg-state private; vis_fx acme/cg-def public
  printf '{"sha":"%s"}' "$HEAD_SHA" | fx "api --hostname github.com repos/acme/cg-def/commits/$HEAD_SHA"
  printf '{"images":[{"harness":"claude-code"}]}' > "$SANDBOX/rest/GET_images.json"
  : > "$SANDBOX/rest.log"
}
iso_env() { env GH_HOST="" WORK_DIR="$WORK" HOME="$FAKE_HOME" TMPDIR="$SANDBOX" PATH="$T_DIR/bin:$PATH" \
  CURL_REST_BASE="$REST_BASE" CURL_REST_DIR="$SANDBOX/rest" CURL_REST_LOG="$SANDBOX/rest.log" \
  CURL_MCP_URL="$MCP_URL" CURL_MCP_LOG="$SANDBOX/mcp.log" CURL_MCP_DIR="$SANDBOX/mcp" \
  CLAUDECODE=1 CLAUDE_EFFORT=high CG_BENCH_POLL_S=0 "$@"; }
iso() { OUT="$(iso_env bash "$ISO" "$@" 2>>"$STDERR_LOG")"; RC=$?; }

# --- check ---------------------------------------------------------------------
iso_case check_repos_ok
iso check repos
check_eq "$RC:$OUT" "0:" 'a private work repo and a public definition repo pass silently'

iso_case check_repos_public_work_repo
vis_fx acme/cg-state public
iso check repos
check_eq "$RC" 1 'a public work repo blocks the run'
assert_out_contains 'work_repo acme/cg-state is public' 'the reason names the repository'

iso_case check_repos_unreadable_work_repo
rm -f "$GH_FIXTURES/$(fx_for 'api --hostname github.com repos/acme/cg-state')"
fx_fail 'api --hostname github.com repos/acme/cg-state'
iso check repos
check_eq "$RC" 1 'an unreadable visibility is no proof of privacy'
assert_out_contains 'visibility is unreadable' 'the reason says so'

iso_case check_repos_private_definition
vis_fx acme/cg-def private
iso check repos
check_eq "$RC" 1 'a private definition repo cannot be seeded without credentials'
assert_out_contains 'definition repo acme/cg-def is private' 'the reason names it'

iso_case check_full_ok
iso check
check_eq "$RC:$OUT" "0:" 'pushed commit and a claude-code sub-agent route pass'

iso_case check_full_commit_not_pushed
rm -f "$GH_FIXTURES/$(fx_for "api --hostname github.com repos/acme/cg-def/commits/$HEAD_SHA")"
fx_fail "api --hostname github.com repos/acme/cg-def/commits/$HEAD_SHA"
iso check
check_eq "$RC" 1 'an unpushed commit cannot be seeded'
assert_out_contains 'push it first' 'the reason gives the fix'

iso_case check_full_no_harness
printf '{"images":[{"harness":"pi"}]}' > "$SANDBOX/rest/GET_images.json"
iso check
check_eq "$RC" 1 'a harness the platform does not offer blocks the run'
assert_out_contains 'no claude-code sub-agent' 'the reason names the harness'

# --- bundle --------------------------------------------------------------------
iso_case bundle_first_holds_no_truth
iso bundle "$F" first "$SANDBOX/b.tgz"
check_eq "$RC" 0 'a clean first-review bundle builds'
LIST="$(tar -tzf "$SANDBOX/b.tgz" | sed 's#^\./##' | sort | tr '\n' ' ')"
case "$LIST" in (*manifest.json*) check_eq has-manifest none 'no manifest in the bundle';; (*) check_eq ok ok 'no manifest in the bundle';; esac
case "$LIST" in (*head-v2*|*prior-review.md*) check_eq has-v2 none 'a first review sees no v2 input';; (*) check_eq ok ok 'a first review sees no v2 input';; esac
case "$LIST" in (*work/benchmark/fixture/ts-api/head-v1/a.ts*) check_eq ok ok 'the fixture inputs sit at their production path';; (*) check_eq "$LIST" fixture 'fixture inputs';; esac
case "$LIST" in (*work/MEMORY.md*work/LESSONS.md*|*work/LESSONS.md*work/MEMORY.md*) check_eq ok ok 'memory and lessons travel';; (*) check_eq "$LIST" memory 'memory and lessons';; esac
case "$LIST" in (*.claude/skills/.cache/sec-check.sha*.claude/skills/sec-check/SKILL.md*|*.claude/skills/sec-check/SKILL.md*.claude/skills/.cache/sec-check.sha*) check_eq ok ok 'repo-sourced skills travel with their cache SHA';; (*) check_eq "$LIST" skills 'skills';; esac

iso_case bundle_rereview_carries_v2
iso bundle "$F" rereview "$SANDBOX/b.tgz"
LIST="$(tar -tzf "$SANDBOX/b.tgz" | tr '\n' ' ')"
case "$LIST" in (*head-v2/a.ts*prior-review.md*|*prior-review.md*head-v2/a.ts*) check_eq ok ok 'a re-review gets v2 and the prior review';; (*) check_eq "$LIST" v2 'v2 inputs';; esac

iso_case bundle_refuses_truth_in_lessons
printf '# Lessons\n- %s\n' "$SUMMARY" > "$WORK/LESSONS.md"
iso bundle "$F" first "$SANDBOX/b.tgz"
check_eq "$RC" 1 'a defect summary outside the fixture inputs refuses the bundle'
assert_out_contains 'ground truth .* in ./work/LESSONS.md' 'the refusal names the file'

iso_case bundle_refuses_truth_of_a_retired_fixture
mkdir -p "$WORK/benchmark/fixture/retired/old"
jq -n '{defects:[{summary:"retired defect summary that leaked"}]}' > "$WORK/benchmark/fixture/retired/old/manifest.json"
printf 'retired defect summary that leaked\n' > "$FAKE_HOME/.claude/skills/sec-check/SKILL.md"
iso bundle "$F" first "$SANDBOX/b.tgz"
check_eq "$RC" 1 'retired manifests count as ground truth too'

iso_case bundle_size_cap
iso_env CG_BENCH_BUNDLE_MAX=10 bash "$ISO" bundle "$F" first "$SANDBOX/b.tgz" > "$SANDBOX/out" 2>&1; RC=$?; OUT="$(cat "$SANDBOX/out")"
check_eq "$RC" 1 'a bundle over the cap is refused'
assert_out_contains 'over 10' 'the refusal names the cap'

# --- start -----------------------------------------------------------------------
iso_case start_spawns_both_phases
iso start --effort high "$SANDBOX/st" 20261101T060000Z "$WORK/benchmark/fixture" ts-api
check_eq "$RC" 0 'start spawns'
check_eq "$(grep -c '^POST /invocations$' "$SANDBOX/rest.log")" 2 'one spawn per phase'
check_eq "$(cat "$SANDBOX/st/ts-api-first.id"):$(cat "$SANDBOX/st/ts-api-rereview.id")" "inv-1:inv-2" 'ids kept per task'
B1="$(sed -n 1p "$SANDBOX/rest.log.body")"
check_eq "$(printf '%s' "$B1" | jq -c '.seed')" "{\"url\":\"https://github.com/acme/cg-def.git\",\"commit\":\"$HEAD_SHA\",\"into\":\"home\"}" 'the seed is the definition at this commit, into home'
check_eq "$(printf '%s' "$B1" | jq -c '.connections')" '[]' 'no connection reaches a sub-agent'
check_eq "$(printf '%s' "$B1" | jq -r '.harness')" claude-code 'the production harness'
check_eq "$(printf '%s' "$B1" | jq -c '.harnessConfig')" '{"configOptions":{"effort":"high"}}' 'the effort passes, the model stays the default'
check_eq "$(printf '%s' "$B1" | jq -r '[.env[] | select(.name == "CG_BENCHMARK_CHILD")][0].value')" 1 'the sub-agent knows its role'
check_eq "$(printf '%s' "$B1" | jq -r '.install.command')" 'bash "$HOME/scripts/benchmark-child.sh" unpack' 'the install step unpacks the bundle'
check_eq "$(printf '%s' "$B1" | jq -r '.prompt | test("fixture `ts-api`, phase `first`, run timestamp `20261101T060000Z`")')" true 'the prompt names the task'
check_eq "$(printf '%s' "$B1" | jq -r '.prompt | test("usage-nonce:bench-20261101T060000Z-ts-api-first")')" true 'the nonce is per task'
# the env chunks join to the bundle the checksum names
JOINED="$(printf '%s' "$B1" | jq -r '[.env[] | select(.name | startswith("CG_BENCH_B64_")) | .value] | join("")' | base64 -d | sha256sum | cut -d' ' -f1)"
check_eq "$JOINED" "$(printf '%s' "$B1" | jq -r '.env[] | select(.name == "CG_BENCH_SHA256") | .value')" 'the chunks carry the bundle intact'

iso_case start_refuses_truth_in_the_seed
printf '%s\n' "$SUMMARY" > "$FAKE_HOME/docs/x.md"
git -C "$FAKE_HOME" -c user.email=t@t -c user.name=t commit -qam leak
HEAD_SHA="$(git -C "$FAKE_HOME" rev-parse HEAD)"
printf '{"sha":"%s"}' "$HEAD_SHA" | fx "api --hostname github.com repos/acme/cg-def/commits/$HEAD_SHA"
iso start "$SANDBOX/st" 20261101T060000Z "$WORK/benchmark/fixture" ts-api
check_eq "$RC" 1 'a seed commit with a defect summary is refused'
assert_out_contains 'ground truth .* in the seed commit: docs/x.md' 'the refusal names the file'
check_eq "$(grep -c '^POST' "$SANDBOX/rest.log")" 0 'nothing is spawned'

iso_case start_only_matches_nothing
iso start --only ts-api-second "$SANDBOX/st" 20261101T060000Z "$WORK/benchmark/fixture" ts-api
check_eq "$RC" 1 'an --only that names no task fails'
assert_out_contains 'no task matches --only ts-api-second' 'the refusal names it'

iso_case start_refused_spawn
printf '{"error":"spend limit reached"}' > "$SANDBOX/rest/POST_invocations.json"
printf '402' > "$SANDBOX/rest/POST_invocations.code"
iso start "$SANDBOX/st" 20261101T060000Z "$WORK/benchmark/fixture" ts-api
check_eq "$RC" 1 'a refused spawn stops start'
assert_out_contains 'ts-api-first: spawn refused — spend limit reached' 'the platform reason is relayed'
check_eq "$(grep -c '^POST /invocations$' "$SANDBOX/rest.log")" 1 'a refused spawn is never repeated'

# --- wait / collect ----------------------------------------------------------------
# a state dir as start leaves it, and a result the sub-agent reported
seed_state() {
  mkdir -p "$SANDBOX/st"; printf '20261101T060000Z\n' > "$SANDBOX/st/ts"
  printf 'inv-1\n' > "$SANDBOX/st/ts-api-first.id"; printf 'inv-2\n' > "$SANDBOX/st/ts-api-rereview.id"
  jq -n '{definition_version:"10.4.0", memory_sha:"m1", skill_sources:{"sec-check":"abc123"},
          effort:"high", definition_ref:{branch:"main", sha:"abc"}, harness_version:"2.1.0 (Claude Code)"}' > "$SANDBOX/expect.json"
}
done_view() { # <memory_sha>
  jq -n --arg m "$1" '{status:"done", result:{review:"## Review\nbody\n", measure:{seconds:300, tokens:{input:1,output:2,cache_read:3,cache_creation:4,msgs:5}},
    suppressed:1, model:"claude-opus-5-5", skills:{"sec-check.md":"skill out\n"},
    provenance:{definition_version:"10.4.0", memory_sha:$m, skill_sources:{"sec-check":"abc123"},
                effort:"high", definition_ref:{branch:null, sha:"abc"}, harness_version:"2.1.1 (Claude Code)"}}}'
}

iso_case wait_reports_running
seed_state
printf '{"status":"running"}' > "$SANDBOX/rest/GET_invocations_inv-1.json"
printf '{"status":"running"}' > "$SANDBOX/rest/GET_invocations_inv-2.json"
iso_env CG_BENCH_WAIT_S=0 bash "$ISO" wait "$SANDBOX/st" > "$SANDBOX/out" 2>/dev/null; RC=$?; OUT="$(cat "$SANDBOX/out")"
check_eq "$RC" 3 'running tasks ask for another wait'
assert_out_contains '2 of 2 task' 'the line counts them'

iso_case wait_and_collect
seed_state
done_view m1 > "$SANDBOX/rest/GET_invocations_inv-1.json"
done_view m1 > "$SANDBOX/rest/GET_invocations_inv-2.json"
iso wait "$SANDBOX/st"
check_eq "$RC" 0 'every task ended'
iso collect "$SANDBOX/st" "$SANDBOX/raw" "$SANDBOX/expect.json"
check_eq "$RC" 0 'matching provenance collects clean'
check_eq "$(cat "$SANDBOX/raw/20261101T060000Z-ts-api-first.md")" "$(printf '## Review\nbody')" 'the raw review is written'
check_eq "$(cat "$SANDBOX/raw/20261101T060000Z-ts-api-rereview-skills/sec-check.md")" 'skill out' 'the skill archive is written'
check_eq "$(printf '%s' "$OUT" | jq -c '.tasks["ts-api"].first')" '{"seconds":300,"tokens":{"input":1,"output":2,"cache_read":3,"cache_creation":4,"msgs":5},"suppressed":1,"spawn":"inv-1"}' 'per-task numbers come verbatim'
check_eq "$(printf '%s' "$OUT" | jq -r '[.model, .harness_version, .effort] | join("|")')" 'claude-opus-5-5|2.1.1 (Claude Code)|high' 'the run takes the sub-agents model, harness and effort'

iso_case collect_flags_a_drifted_input
seed_state
done_view m1 > "$SANDBOX/rest/GET_invocations_inv-1.json"
done_view m-other > "$SANDBOX/rest/GET_invocations_inv-2.json"
iso wait "$SANDBOX/st"
iso collect "$SANDBOX/st" "$SANDBOX/raw" "$SANDBOX/expect.json"
check_eq "$RC" 1 'a sub-agent with other inputs fails the collection'
check_eq "$(printf '%s' "$OUT" | jq -c '.mismatches')" '[{"task":"ts-api-rereview","fields":["memory_sha"]}]' 'the drifted field is named'
check_eq "$(ls "$SANDBOX/raw" 2>/dev/null | wc -l | tr -d ' ')" 0 'an aborted collection writes no raw file into the append-only history'

iso_case collect_takes_the_asked_effort
seed_state
printf 'high\n' > "$SANDBOX/st/effort"
for i in 1 2; do done_view m1 | jq '.result.provenance.effort = "unknown"' > "$SANDBOX/rest/GET_invocations_inv-$i.json"; done
iso wait "$SANDBOX/st"
iso collect "$SANDBOX/st" "$SANDBOX/raw" "$SANDBOX/expect.json"
check_eq "$RC:$(printf '%s' "$OUT" | jq -r '.effort')" '0:high' 'a harness that exposes no effort records the effort start asked for'

iso_case collect_names_a_failed_task
seed_state
done_view m1 > "$SANDBOX/rest/GET_invocations_inv-1.json"
printf '{"status":"failed","errorReason":"deadline"}' > "$SANDBOX/rest/GET_invocations_inv-2.json"
iso wait "$SANDBOX/st"
assert_out_contains '1 done, 1 failed' 'wait counts the failure'
iso collect "$SANDBOX/st" "$SANDBOX/raw" "$SANDBOX/expect.json"
check_eq "$RC" 1 'a failed task fails the collection'
check_eq "$(printf '%s' "$OUT" | jq -c '.failed')" '[{"task":"ts-api-rereview","reason":"deadline"}]' 'the failure keeps its reason'

# --- the sub-agent side ----------------------------------------------------------------
iso_case child_unpack_and_report
iso bundle "$F" first "$SANDBOX/b.tgz"
CH="$SANDBOX/child"; mkdir -p "$CH"; cp -a "$REPO_ROOT/scripts" "$CH/"
printf '{"mcpServers":{"platform-outbound":{"type":"http","url":"%s"}}}\n' "$MCP_URL" > "$CH/.mcp.json"
B64="$(base64 < "$SANDBOX/b.tgz" | tr -d '\n')"
SUM="$(sha256sum < "$SANDBOX/b.tgz" | cut -d' ' -f1)"
OUT="$(env -u CLAUDECODE HOME="$CH" TMPDIR="$SANDBOX" PATH="$T_DIR/bin:$PATH" CG_BENCHMARK_CHILD=1 \
  CG_BENCH_B64_00="${B64:0:100}" CG_BENCH_B64_01="${B64:100}" CG_BENCH_SHA256="$SUM" \
  bash "$CH/scripts/benchmark-child.sh" unpack 2>&1)"; RC=$?
check_eq "$RC" 0 'the install step unpacks'
check_eq "$(cat "$CH/work/benchmark/fixture/ts-api/head-v1/a.ts")" b 'the fixture lands at its production path'
check_eq "$(test -e "$CH/work/benchmark/fixture/ts-api/manifest.json" && echo yes || echo no)" no 'no manifest in the sub-agent'
check_eq "$(cat "$CH/.claude/skills/.cache/sec-check.sha")" abc123 'the skill cache SHA arrives'
mkdir -p "$CH/work/benchmark/results/raw/20261101T060000Z-ts-api-first-skills"
printf 'the review\n' > "$CH/work/benchmark/results/raw/20261101T060000Z-ts-api-first.md"
printf 'skill out\n' > "$CH/work/benchmark/results/raw/20261101T060000Z-ts-api-first-skills/sec-check.md"
printf '{"seconds":12,"tokens":null}' > "$CH/work/benchmark/.measure-ts-api-first.json"
OUT="$(env HOME="$CH" TMPDIR="$SANDBOX" PATH="$T_DIR/bin:$PATH" CG_BENCHMARK_CHILD=1 \
  CURL_MCP_URL="$MCP_URL" CURL_MCP_LOG="$SANDBOX/mcp.log" CURL_MCP_DIR="$SANDBOX/mcp" \
  bash "$CH/scripts/benchmark-child.sh" report ts-api first 20261101T060000Z claude-opus-5-5 2 2>&1)"; RC=$?
check_eq "$RC" 0 'the result is reported'
R="$(jq -c 'select(.params.name == "report_result") | .params.arguments.result' "$SANDBOX/mcp.log")"
check_eq "$(printf '%s' "$R" | jq -r '[.review, (.measure.seconds | tostring), (.suppressed | tostring), .model, .skills["sec-check.md"]] | join("|")')" \
  "$(printf 'the review\n|12|2|claude-opus-5-5|skill out\n')" 'review, measurement, count, model and skill archive travel from files'
check_eq "$(printf '%s' "$R" | jq -r '.provenance | has("memory_sha") and has("skill_sources")')" true 'the sub-agent provenance travels'

iso_case child_refuses_outside_a_sub_agent
OUT="$(env -u CG_BENCHMARK_CHILD HOME="$FAKE_HOME" bash "$CHILD" unpack 2>&1)"; RC=$?
check_eq "$RC" 2 'unpack runs only in a benchmark sub-agent'

iso_case child_guards_preflight_and_backup
OUT="$(env CG_BENCHMARK_CHILD=1 WORK_DIR="$WORK" HOME="$FAKE_HOME" PATH="$T_DIR/bin:$PATH" bash "$REPO_ROOT/scripts/preflight.sh" review 2>/dev/null)"
assert_jq '.nothing_to_do == true and (.logs | any(contains("benchmark sub-agent")))' 'preflight does nothing in a sub-agent'
OUT="$(env CG_BENCHMARK_CHILD=1 WORK_DIR="$WORK" HOME="$FAKE_HOME" PATH="$T_DIR/bin:$PATH" bash "$REPO_ROOT/scripts/work-backup.sh" persist 2>&1)"
assert_out_contains 'benchmark sub-agent — nothing to back up' 'the backup does nothing in a sub-agent'

finish
