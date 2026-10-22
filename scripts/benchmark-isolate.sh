#!/usr/bin/env bash
# benchmark-isolate.sh — run benchmark Phase 1 in isolated platform sub-agents
# (docs/benchmark.md → Isolation). It executes on the session's command and
# never judges: it bundles each task's Phase-1 inputs, spawns one sub-agent per
# fixture and phase through the platform's Driver REST routes (the routes the
# platform's driver SDK calls: a script spawn, never delivered as a turn),
# polls them and writes their results where Phase 2 reads them.
#
#   benchmark-isolate.sh check [repos]
#   benchmark-isolate.sh bundle <fixture-dir> <first|rereview> <out.tgz>
#   benchmark-isolate.sh start [--model <m>] [--effort <e>] [--only <slug>-<phase>]… \
#                              <state-dir> <ts> <fixture-root> <slug>…
#   benchmark-isolate.sh wait <state-dir>
#   benchmark-isolate.sh collect <state-dir> <raw-dir> <expect-provenance.json>
#
# `check` prints nothing and exits 0 when the run can be isolated, else one line
# with the reason and exits 1. `repos` checks the repositories alone (preflight's
# benchmark pass): the work repo — the backup of fixture/ and results/ — is not
# public, and the definition repo the sub-agent seeds needs no credentials. The
# full check adds the seeded commit on that remote and the platform's sub-agent
# route for this harness.
#
# `bundle` stages the task's inputs (paths relative to $HOME: the fixture
# directory without manifest.json, work/MEMORY.md, LESSONS.md, CONFIG.md and
# every repo-sourced skill with its cache SHA) and refuses a bundle that holds
# a manifest, a result, or a defect summary of any manifest outside the fixture
# inputs. `start` also refuses a definition history — every commit of every
# local ref, since the sub-agent can fetch the public remote — that tracks a
# benchmark path or holds such a summary. A sub-agent gets no connection: the bundle travels in env chunks
# that `benchmark-child.sh unpack` joins in its install step.
#
# `wait` polls for at most CG_BENCH_WAIT_S (480) seconds: rc 0 when every task
# ended, rc 3 while some still run. `collect` writes each result's raw review
# and skill archive, prints one JSON object (tasks, model, harness_version,
# effort, failed[], mismatches[]) and exits 1 on a failed task, a malformed
# result, or provenance that differs from the expected (the production
# checkout's benchmark-provenance.sh output) — then it writes no raw file.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$SCRIPT_DIR/lib/toolpath.sh" ] && . "$SCRIPT_DIR/lib/toolpath.sh" 2>/dev/null
. "$SCRIPT_DIR/lib/common.sh"
. "$SCRIPT_DIR/lib/harness.sh"
. "$SCRIPT_DIR/lib/mcp.sh"

HOME_DIR="${HOME:-/home/agent}"
WORK="${WORK_DIR:-$HOME_DIR/work}"
CONFIG="$WORK/CONFIG.md"
BUNDLE_MAX="${CG_BENCH_BUNDLE_MAX:-524288}"   # base64 bytes; the env of one agent spec
CHUNK=65536                                     # one env value, under the kernel's per-string cap
TTL_MS="${CG_BENCH_TTL_MS:-10800000}"           # 3 h, queue time included
WAIT_S="${CG_BENCH_WAIT_S:-480}"
POLL_S="${CG_BENCH_POLL_S:-15}"
PHASES="first rereview"

die() { printf '%s\n' "$*"; exit 1; }

def_ref() { local r; r="$(cfg definition_repo)"; [ -n "$r" ] || r="$(origin_ref "$HOME_DIR")"; printf '%s' "$r"; }

# The Driver REST root: the platform MCP URL /api/agents/<id>/mcp minus /mcp.
rest_root() {
  local u; u="$(mcp_url)" || return 1
  case "$u" in (*/api/agents/*/mcp) printf '%s' "${u%/mcp}";; (*) return 1;; esac
}

# rest <METHOD> <path> [body-file] -> body on stdout; rc 0 on 2xx
rest() {
  local tmp code
  tmp="$(mktemp "${TMPDIR:-/tmp}/cg-rest.XXXXXX")" || return 1
  code="$(curl -sS --connect-timeout 5 --max-time 30 -X "$1" \
    ${3:+-H 'Content-Type: application/json' --data-binary @"$3"} \
    -o "$tmp" -w '%{http_code}' "$ROOT$2" 2>/dev/null)"
  cat "$tmp"; rm -f "$tmp"
  case "$code" in (2??) return 0;; (*) return 1;; esac
}

check_repos() {
  local wr v d
  wr="$(cfg work_repo)"
  if [ -n "$wr" ]; then
    v="$(repo_visibility "$wr")"
    case "$v" in
      (private|internal) ;;
      (public) die "work_repo $wr is public — the sub-agents could read the fixtures' ground truth from the backup; make the repository private";;
      (*) die "work_repo $wr visibility is unreadable — the run cannot show that the backup is private";;
    esac
  fi
  d="$(def_ref)"
  [ -n "$d" ] || die "definition repo unresolved — the sub-agents have nothing to seed"
  v="$(repo_visibility "$d")"
  [ "$v" = public ] || die "definition repo $d is $v — the sub-agents seed it with no credentials, so it must be public"
  return 0
}

check_full() {
  local d sha h
  check_repos || return 1
  d="$(def_ref)"
  sha="$(git -C "$HOME_DIR" rev-parse HEAD 2>/dev/null)" || die "$HOME_DIR is not a git checkout"
  gh_get --hostname "$(refhost "$d")" "repos/$(refslug "$d")/commits/$sha" >/dev/null \
    || die "HEAD ${sha:0:12} is not on $d — push it first; the sub-agents seed that commit"
  ROOT="$(rest_root)" || die "no platform sub-agent route here (no platform MCP URL of the /api/agents/<id>/mcp shape)"
  h="$(cg_harness)"
  rest GET /images | jq -e --arg h "$h" '[.images[]? | .harness] | index($h) != null' >/dev/null 2>&1 \
    || die "the platform offers no $h sub-agent to this agent (GET /images)"
  return 0
}

# the defect summaries of every manifest on disk, retired ones included: the
# strings that must never reach a sub-agent outside the fixture inputs
truth_patterns() { # <fixture-root> <out-file>
  for m in "$1"/*/manifest.json "$1"/retired/*/manifest.json; do
    [ -f "$m" ] && jq -r '.defects[]?.summary // empty | select(length >= 16)' "$m" 2>/dev/null
  done | sort -u > "$2"
}

bundle() { # <fixture-dir> <phase> <out.tgz>
  local b="${1%/}" ph="$2" out="$3" slug stage d f n pats hits
  slug="${b##*/}"
  case "$ph" in (first|rereview) ;; (*) die "phase must be first or rereview";; esac
  [ -d "$b" ] || die "no fixture directory $b"
  stage="$(mktemp -d "${TMPDIR:-/tmp}/cg-bench-stage.XXXXXX")" || die "no scratch dir"
  d="$stage/work/benchmark/fixture/$slug"; mkdir -p "$d"
  for f in base head-v1 pr.json diff-v1.patch; do
    [ -e "$b/$f" ] || { rm -rf "$stage"; die "$slug: $f missing"; }; cp -a "$b/$f" "$d/"
  done
  if [ "$ph" = rereview ]; then
    for f in head-v2 diff-v1-v2.patch prior-review.md; do
      [ -e "$b/$f" ] || { rm -rf "$stage"; die "$slug: $f missing"; }; cp -a "$b/$f" "$d/"
    done
  fi
  for f in MEMORY.md LESSONS.md CONFIG.md; do [ -f "$WORK/$f" ] && cp "$WORK/$f" "$stage/work/"; done
  for f in "$HOME_DIR"/.claude/skills/.cache/*.sha; do
    [ -f "$f" ] || continue
    n="${f##*/}"; n="${n%.sha}"
    [ -d "$HOME_DIR/.claude/skills/$n" ] || continue
    mkdir -p "$stage/.claude/skills/.cache"
    cp -a "$HOME_DIR/.claude/skills/$n" "$stage/.claude/skills/"
    cp "$f" "$stage/.claude/skills/.cache/"
  done
  if [ -n "$(find "$stage" -name manifest.json -o -name RESULTS.md -o -path '*/results/*' | head -1)" ]; then
    rm -rf "$stage"; die "$slug: the bundle holds a manifest or a result"
  fi
  pats="$stage.pats"; truth_patterns "${b%/*}" "$pats"
  if [ -s "$pats" ]; then
    hits="$(cd "$stage" && grep -rIlF -i -f "$pats" --exclude-dir=fixture . 2>/dev/null | head -3 | tr '\n' ' ')"
    [ -z "$hits" ] || { rm -rf "$stage" "$pats"; die "$slug: ground truth (a manifest defect summary) in ${hits% } — remove it before a run"; }
  fi
  rm -f "$pats"
  tar -C "$stage" -czf "$out" . || { rm -rf "$stage"; die "$slug: tar failed"; }
  rm -rf "$stage"
  n="$(base64 < "$out" | tr -d '\n' | wc -c | tr -d ' ')"
  [ "$n" -le "$BUNDLE_MAX" ] || die "$slug-$ph: bundle is $n base64 bytes, over $BUNDLE_MAX"
  return 0
}

# the seeded repository: no commit of any local ref — the sub-agent clones
# history and can fetch more from the public remote — tracks a benchmark path
# or holds a defect summary
seed_clean() { # <fixture-root>
  local pats hits log line
  git -C "$HOME_DIR" log --all --format= --name-only 2>/dev/null \
    | grep -qE '^work/benchmark/|(^|/)manifest\.json$|(^|/)RESULTS\.md$' \
    && die "the definition history tracks a benchmark fixture or result — it must never leave work/"
  pats="$(mktemp "${TMPDIR:-/tmp}/cg-bench-pats.XXXXXX")"; truth_patterns "$1" "$pats"
  if [ -s "$pats" ]; then
    log="$pats.log"; git -C "$HOME_DIR" log --all --reverse -p --format='commit %h' > "$log" 2>/dev/null
    line="$(grep -n -m1 -iF -f "$pats" "$log" | cut -d: -f1)"
    if [ -n "$line" ]; then
      hits="$(head -n "$line" "$log" | grep '^commit ' | tail -1 | cut -d' ' -f2)"
      rm -f "$pats" "$log"; die "ground truth (a manifest defect summary) in the definition history: commit ${hits:-unknown}"
    fi
    rm -f "$log"
  fi
  rm -f "$pats"
}

sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi; }

RESULT_SCHEMA='{"type":"object","required":["review","measure","suppressed","model","provenance","skills"],
 "properties":{"review":{"type":"string","minLength":1},"measure":{"type":"object"},
  "suppressed":{"type":"integer"},"model":{"type":"string"},"provenance":{"type":"object"},
  "skills":{"type":"object"}}}'

start() {
  local model="" effort="" only="" st ts root slug ph task nonce tgz b64 sum d url sha h env prompt body id ans rc n
  while [ "$#" -gt 0 ]; do
    case "$1" in
      (--model) model="$2"; shift 2;;
      (--effort) effort="$2"; shift 2;;
      (--only) only="$only $2"; shift 2;;
      (*) break;;
    esac
  done
  [ "$#" -ge 4 ] || die "usage: benchmark-isolate.sh start [--model m] [--effort e] [--only task]… <state-dir> <ts> <fixture-root> <slug>…"
  st="$1" ts="$2" root="${3%/}"; shift 3
  check_full || return 1
  seed_clean "$root" || return 1
  mkdir -p "$st" || die "cannot create $st"
  printf '%s\n' "$ts" > "$st/ts"; printf '%s\n' "$effort" > "$st/effort"
  d="$(def_ref)"; sha="$(git -C "$HOME_DIR" rev-parse HEAD)"
  url="https://$(refhost "$d")/$(refslug "$d").git"
  h="$(cg_harness)"
  n=0
  for slug in "$@"; do
    for ph in $PHASES; do
      task="$slug-$ph"
      [ -z "$only" ] || case " $only " in (*" $task "*) ;; (*) continue;; esac
      rm -f "$st/$task".*
      nonce="bench-$ts-$task"
      tgz="$st/$task.tgz"
      bundle "$root/$slug" "$ph" "$tgz" || return 1
      b64="$st/$task.b64"; base64 < "$tgz" | tr -d '\n' > "$b64"
      sum="$(sha256 < "$tgz")"
      env="$(fold -w "$CHUNK" "$b64" | jq -R . | jq -s --arg sum "$sum" --arg h "$h" '
        [to_entries[] | {name: ("CG_BENCH_B64_" + (.key | tostring | if length < 2 then "0" + . else . end)), value: .value}]
        + [{name: "CG_BENCH_SHA256", value: $sum}, {name: "CG_BENCH_HARNESS", value: $h},
           {name: "CG_BENCHMARK_CHILD", value: "1"}]')"
      prompt="$(sed -e "s/{{SLUG}}/$slug/g" -e "s/{{PHASE}}/$ph/g" -e "s/{{TS}}/$ts/g" -e "s/{{NONCE}}/$nonce/g" \
        "$SCRIPT_DIR/templates/benchmark-child.md")"
      body="$st/$task.req"
      jq -n --arg h "$h" --arg p "$prompt" --argjson schema "$RESULT_SCHEMA" --arg l "cg-bench $task" \
        --argjson ttl "$TTL_MS" --arg url "$url" --arg sha "$sha" --argjson env "$env" \
        --arg model "$model" --arg effort "$effort" '
        {harness: $h, prompt: $p, schema: $schema, label: $l, ttlMs: $ttl, connections: [],
         seed: {url: $url, commit: $sha, into: "home"},
         install: {command: "bash \"$HOME/scripts/benchmark-child.sh\" unpack"}, env: $env}
        + (if $model == "" and ($effort == "" or $h != "claude-code") then {}
           else {harnessConfig: ((if $model == "" then {} else {model: $model} end)
             + (if $effort == "" or $h != "claude-code" then {} else {configOptions: {effort: $effort}} end))} end)' \
        > "$body" || die "$task: request not built"
      rm -f "$b64"
      # one POST per task: a repeated call is a second sub-agent
      ans="$(rest POST /invocations "$body")"; rc=$?
      id="$(printf '%s' "$ans" | jq -r '.id // empty' 2>/dev/null)"
      [ "$rc" -eq 0 ] && [ -n "$id" ] \
        || die "$task: spawn refused — $(printf '%s' "$ans" | jq -r '.error // empty' 2>/dev/null || true)"
      rm -f "$body"
      printf '%s\n' "$id" > "$st/$task.id"; printf '%s\n' "$nonce" > "$st/$task.nonce"
      printf 'spawned %s -> %s\n' "$task" "$id"; n=$((n + 1))
    done
  done
  [ "$n" -gt 0 ] || die "no task matches${only:+ --only$only}"
}

wait_all() { # <state-dir>
  local st="$1" deadline f task id view status running done_n failed_n total unanswered
  ROOT="$(rest_root)" || die "no platform sub-agent route here"
  deadline=$(( $(date -u +%s) + WAIT_S ))
  while :; do
    running=0 done_n=0 failed_n=0 total=0 unanswered=0
    for f in "$st"/*.id; do
      [ -f "$f" ] || continue
      total=$((total + 1)); task="${f##*/}"; task="${task%.id}"
      if [ -f "$st/$task.result.json" ]; then done_n=$((done_n + 1)); continue; fi
      if [ -f "$st/$task.failed" ]; then failed_n=$((failed_n + 1)); continue; fi
      id="$(cat "$f")"
      view="$(rest GET "/invocations/$id" 2>/dev/null)" || { running=$((running + 1)); unanswered=$((unanswered + 1)); continue; }
      status="$(printf '%s' "$view" | jq -r '.status // empty' 2>/dev/null)"
      case "$status" in
        (done) printf '%s' "$view" | jq '.result' > "$st/$task.result.json"; done_n=$((done_n + 1));;
        (failed) printf '%s' "$view" | jq -r '.errorReason // "no reason given"' > "$st/$task.failed"; failed_n=$((failed_n + 1));;
        (*) running=$((running + 1));;
      esac
    done
    [ "$total" -gt 0 ] || die "no spawned task in $st"
    if [ "$running" -eq 0 ]; then
      printf 'all %s task(s) ended: %s done, %s failed\n' "$total" "$done_n" "$failed_n"; return 0
    fi
    if [ "$(date -u +%s)" -ge "$deadline" ]; then
      printf '%s of %s task(s) still running (%s done, %s failed%s) — call wait again\n' "$running" "$total" "$done_n" "$failed_n" \
        "$([ "$unanswered" -gt 0 ] && printf '; %s status read(s) got no answer' "$unanswered")"
      return 3
    fi
    sleep "$POLL_S"
  done
}

collect() { # <state-dir> <raw-dir> <expect.json>
  local st="$1" raw="$2" exp="$3" ts asked f task slug ph r out="[]" bad
  ts="$(cat "$st/ts" 2>/dev/null)"; [ -n "$ts" ] || die "no run timestamp in $st"
  # the effort start passed stands in where a sub-agent's harness exposes none
  asked="$(cat "$st/effort" 2>/dev/null)"
  jq -e 'type == "object"' "$exp" >/dev/null 2>&1 || die "expected provenance unreadable: $exp"
  mkdir -p "$raw"
  for f in "$st"/*.id; do
    [ -f "$f" ] || continue
    task="${f##*/}"; task="${task%.id}"; ph="${task##*-}"; slug="${task%-*}"
    r="$st/$task.result.json"
    if [ ! -f "$r" ]; then
      out="$(printf '%s' "$out" | jq --arg t "$task" --arg why "$(cat "$st/$task.failed" 2>/dev/null || printf 'not ended')" \
        '. + [{task: $t, failed: $why}]')"; continue
    fi
    bad="$(jq -r 'if (.review | type) == "string" and (.review | length) > 0
        and (.measure.seconds | type) == "number"
        and (.measure.tokens == null or (.measure.tokens | type) == "object")
        and (.suppressed | type) == "number" and (.model | type) == "string"
        and (.provenance | type) == "object" and (.skills | type) == "object"
      then "" else "malformed result" end' "$r" 2>/dev/null || printf 'unparsable result')"
    if [ -n "$bad" ]; then
      out="$(printf '%s' "$out" | jq --arg t "$task" --arg why "$bad" '. + [{task: $t, failed: $why}]')"; continue
    fi
    out="$(printf '%s' "$out" | jq --arg t "$task" --arg s "$slug" --arg ph "$ph" --arg id "$(cat "$f")" \
      --arg asked "${asked:-}" --slurpfile res "$r" --slurpfile e "$exp" '
      $res[0] as $r | $e[0] as $x
      | ($r.provenance | if (.effort // "unknown") == "unknown" and $asked != "" then .effort = $asked else . end) as $p
      | ([ ("definition_version", "memory_sha", "skill_sources")
           | select(($p[.] // null) != ($x[.] // null)) ]
         + (if ($p.definition_ref.sha // null) != ($x.definition_ref.sha // null) then ["definition_ref.sha"] else [] end)
         + (if ($p.effort // "unknown") != "unknown" and ($x.effort // "unknown") != "unknown"
               and $p.effort != $x.effort then ["effort"] else [] end)) as $diff
      | . + [{task: $t, slug: $s, phase: $ph, spawn: $id,
              seconds: $r.measure.seconds, tokens: $r.measure.tokens, suppressed: $r.suppressed,
              model: $r.model, harness_version: ($p.harness_version // null), effort: ($p.effort // "unknown"),
              differs: $diff}]')"
  done
  printf '%s' "$out" | jq '
    [.[] | select(has("failed") | not)] as $ok
    | {tasks: (reduce $ok[] as $t ({}; .[$t.slug][$t.phase] =
        {seconds: $t.seconds, tokens: $t.tokens, suppressed: $t.suppressed, spawn: $t.spawn})),
       model: ([$ok[].model] | unique | if length == 1 then .[0] else null end),
       harness_version: ([$ok[].harness_version] | unique | if length == 1 then .[0] else null end),
       effort: ([$ok[].effort] | unique | if length == 1 then .[0] else null end),
       failed: [.[] | select(has("failed")) | {task, reason: .failed}],
       mismatches: ([$ok[] | select(.differs | length > 0) | {task, fields: .differs}]
         + (if ([$ok[].model] | unique | length) > 1 then [{task: "all", fields: ["model"]}] else [] end)
         + (if ([$ok[].effort] | unique | length) > 1 then [{task: "all", fields: ["effort"]}] else [] end))}' \
    | tee "$st/collected.json"
  jq -e '(.failed | length) == 0 and (.mismatches | length) == 0' "$st/collected.json" >/dev/null || return 1
  # raw files only for a clean collection: results/raw is append-only, and an
  # aborted run records nothing
  for f in "$st"/*.result.json; do
    task="${f##*/}"; task="${task%.result.json}"
    jq -r '.review' "$f" > "$raw/$ts-$task.md"
    rm -rf "$raw/$ts-$task-skills"; mkdir -p "$raw/$ts-$task-skills"
    jq -r '.skills | keys[]' "$f" | while IFS= read -r p; do
      case "$p" in (/*|*..*|'') continue;; esac
      mkdir -p "$raw/$ts-$task-skills/$(dirname "$p")"
      jq -r --arg p "$p" '.skills[$p] | tostring' "$f" > "$raw/$ts-$task-skills/$p"
    done
  done
}

ACTION="${1:-}"; shift 2>/dev/null || true
case "$ACTION" in
  (check)
    if [ "${1:-}" = repos ]; then check_repos; else check_full; fi;;
  (bundle)
    [ "$#" -eq 3 ] || die "usage: benchmark-isolate.sh bundle <fixture-dir> <first|rereview> <out.tgz>"
    bundle "$@";;
  (start) start "$@";;
  (wait)
    [ "$#" -eq 1 ] || die "usage: benchmark-isolate.sh wait <state-dir>"
    wait_all "$1";;
  (collect)
    [ "$#" -eq 3 ] || die "usage: benchmark-isolate.sh collect <state-dir> <raw-dir> <expect-provenance.json>"
    collect "$@";;
  (*) printf 'usage: benchmark-isolate.sh check [repos] | bundle | start | wait | collect (see the header)\n' >&2; exit 2;;
esac
