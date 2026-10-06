#!/usr/bin/env bash
# preflight.sh — deterministic heartbeat pre-flight for code-guardian.
#
# Detects, never acts. The script computes the run's worklist — which PRs need
# a review, an artifact, a nudge, a prune, a self-heal, or label cleanup — so
# the agent only wakes up when there is real work, and when it does, the agent
# performs every action itself per docs/ (reliability first). The script:
#
#   - makes NO GitHub writes at all (only GET calls),
#   - runs NO git commit/push (the agent persists at end of run),
#   - writes locally only: bookkeeping — the REVIEWS.md `done`->`awaiting_label`
#     flip (keeps the re-review trigger gate's transition logs one-shot),
#     shepherd-ledger bookkeeping for rows with no nudge due, PR-EVENTS.jsonl
#     facts, the housekeeping batch's wait marker, dead PR holds removed, the
#     stall-alert day claim — plus HEARTBEAT.log / SHEPHERD.log lines,
#     structured events in work/logs/ (scripts/log.sh — docs/logging.md), the
#     per-pass /tmp scratch directory (removed on exit), the skill install
#     cache, the git credential helper (`gh auth setup-git`, before the agent
#     clones), the project profile refresh (work/PROFILE.{json,md} + its /tmp
#     mirror, scripts/profile.sh — docs/profile.md), the stale-clone sweep, and
#     the audit-mode cleanups (log retention, ledger trims) with that mode's own
#     worklist at work/audit/last-worklist.json.
#
#   preflight.sh review    -> reviews_due / label_cleanups_due / selfheals_due
#                             / prunes_due / status_resets_due / artifacts_due
#                             / urgent_alerts_due / mentions_due / ci_failures_due
#                             / merges_due / fixes_due / stall_alert, the
#                             read_set, config (resolved keys) and memory
#                             (budget) whenever there is work, plus the skill
#                             install and the per-PR inventory when a review or
#                             artifact is due. Bookkeeping alone is deferred
#                             (`housekeeping_only` — docs/worklist.md -> The
#                             schedule gate)
#   preflight.sh shepherd  -> nudges_due (classification + age gate + cooldown
#                             + escalation ladder + merge-conflict flag already
#                             computed; the agent applies each row_update right
#                             after its send)
#   preflight.sh audit     -> weekly health check: 7-day stats + deterministic
#                             checks + failures[]; the agent adds the judgment
#                             checks and sends the report (docs/audit.md)
#   preflight.sh benchmark -> benchmark_due (create_fixture | run) when
#                             `benchmark: enabled` and the monthly gate passes
#                             (docs/benchmark.md); purely local, no API calls
#   preflight.sh survey    -> survey_due (the area to read, its caps and
#                             history) when `survey: enabled` and the interval
#                             passed (docs/survey.md)
#   preflight.sh memory    -> the memory budget object alone (memory_budget_json),
#                             for the consolidation to verify its bounds;
#                             local reads only, no bookkeeping
#
# Output: a single JSON object on stdout. Agent contract:
#   .nothing_to_do == true  -> end the run immediately.
#   otherwise               -> process the arrays per docs/runbook.md + docs/.
#
# Requires: bash, gh (authenticated), jq, git, sed/grep/cut/tr, GNU date
# (Linux pod). Deliberately awk-free — awk is not available in the pod.
# jq/gh are resolved past any version-manager shim by scripts/lib/toolpath.sh
# (sourced via log.sh) — ~90 jq execs per run make that a 3x difference.

set -u
export LC_ALL=C

MODE="${1:-review}"
HOME_DIR="${HOME:-/home/agent}"
WORK="${WORK_DIR:-$HOME_DIR/work}"
CONFIG="$WORK/CONFIG.md"
REVIEWS="$WORK/REVIEWS.md"
LEDGER="$WORK/REVIEW-LEDGER.jsonl"
SHEPHERD="$WORK/SHEPHERD.md"
# Append-only PR facts the weekly project-health metrics are counted from.
# The shepherd ledger cannot serve them: pruning deletes a merged PR's row,
# which is exactly the population a latency median must keep
# (docs/audit.md → task 33).
PR_EVENTS="$WORK/PR-EVENTS.jsonl"
DEVELOPERS="$WORK/DEVELOPERS.md"
SKILL_CACHE="$HOME_DIR/.claude/skills/.cache"
NOW_EPOCH=$(date -u +%s)
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# structured events log (docs/logging.md); no-op fallback keeps set -u safe
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# ci-rollup.sh is optional: unreadable, the CI triage detector stays off and
# every other decision of the run is unaffected (docs/ci-triage.md).
CI_LIB=1; . "$SCRIPT_DIR/lib/ci-rollup.sh" >/dev/null 2>&1 || CI_LIB=0
# review-records.sh is optional: unreadable, every takeover and owed closed-PR
# pass reads as a first review (full scope) and the audit counts no reviews.
RR_LIB=1; . "$SCRIPT_DIR/lib/review-records.sh" >/dev/null 2>&1 || { RR_LIB=0; rr_posted() { return 1; }; }
# holds.sh carries the live-holder rule and the PR holds. Unreadable, review
# mode stops with an `error` (fail_out below) and the audit's clone sweep judges
# a `.fix` clone by its age alone.
HOLDS_LIB=1; . "$SCRIPT_DIR/lib/holds.sh" >/dev/null 2>&1 || HOLDS_LIB=0
# paths.sh is optional: unreadable, no path glob ever matches
. "$SCRIPT_DIR/lib/paths.sh" >/dev/null 2>&1 || path_glob_match() { return 1; }
LOG_JOB="$MODE"
if ! . "$SCRIPT_DIR/log.sh" >/dev/null 2>&1; then logev() { :; }; fi
# log.sh sources lib/toolpath.sh; stub it when either file was unavailable
command -v toolpath_shimmed >/dev/null 2>&1 || toolpath_shimmed() { :; }
LOG_DIR="${LOG_DIR:-$WORK/logs}"

LOGS=()
log()     { LOGS+=("$1"); logev info preflight "$1"; }
# same, for a degradation the agent must see in the chat UI and that should be
# queryable as a warning in the structured log
log_warn() { LOGS+=("$1"); logev warn preflight "$1"; }

# Pod-restart marker: $HOME persists across restarts but the rest of the
# filesystem is reset, so an ephemeral sentinel outside $HOME is absent iff the
# pod restarted since the last run. Detect-and-log only; never gates behavior
# (docs/logging.md → pod_boot). Best-effort: any failure is swallowed.
BOOT_SENTINEL="${TMPDIR:-/tmp}/.code-guardian-pod-boot"
if [ ! -e "$BOOT_SENTINEL" ]; then
  up="$(cut -d' ' -f1 /proc/uptime 2>/dev/null)"
  logev warn pod_boot "pod restarted since last run (no sentinel)${up:+ — uptime=${up}s}"
  : > "$BOOT_SENTINEL" 2>/dev/null || true
fi

# cfg, cfg_table, trim, row_field, iso2epoch, refhost/refslug, gh_get —
# sourced before GH_HOST is re-exported in the config section
. "$SCRIPT_DIR/lib/common.sh"
# report surface keys (docs/config.md): `off` publishes nothing, anything else
# publishes to the DAM Artifact Library — a legacy value is logged, not fatal
report_surface() { # <key> <var>
  local v; v="$(cfg "$1")"
  case "$v" in
    (''|dam) printf -v "$2" dam;;
    (off) printf -v "$2" off;;
    (*) printf -v "$2" dam; log "$1 '$v' is not dam | off — publishing to dam";;
  esac
}

# benchmark run lock TTL (docs/benchmark.md): a scored run never legitimately
# exceeds it; shared by the benchmark-mode gate and the audit-mode tmp sweep
BENCH_LOCK_TTL_MIN=360

# ============================================================ SURVEY MODE ====
# Local like the benchmark: choosing the area needs the profile and the ledger,
# both on disk, so a disabled or gated tick never touches the network. The pass
# itself is docs/survey.md — one area per run, capped by scripts/survey.sh.
if [ "$MODE" = "survey" ]; then
  survey_out() { # <nothing_to_do bool> <survey_due json | null>
    printf '%s\n' "$NOW_ISO survey nothing_to_do=$1 ${LOGS[*]:-}" >> "$WORK/HEARTBEAT.log" 2>/dev/null
    logev info heartbeat "mode=survey nothing_to_do=$1 survey=$([ "$1" = "false" ] && echo 1 || echo 0)"
    jq -n --argjson nothing "$1" --argjson due "$2" \
      --argjson logs "$(printf '%s\n' "${LOGS[@]:-}" | jq -R . | jq -s '[.[] | select(length>0)]')" \
      '{mode:"survey", nothing_to_do:$nothing, logs:$logs}
       + (if $due == null then {} else {survey_due:$due} end)'
    exit 0
  }
  [ "$(cfg survey)" = "enabled" ] || { log "survey disabled — nothing to do"; survey_out true null; }

  SURVEY_DIR="$WORK/survey"
  SURVEY_LEDGER="$SURVEY_DIR/LEDGER.md"
  SURVEY_INTERVAL_D="$(cfg survey_interval_days)"
  case "$SURVEY_INTERVAL_D" in (''|*[!0-9]*) SURVEY_INTERVAL_D=7;; esac
  report_surface survey_report EFF_SURVEY

  # the cadence floor, so a drifting cron never surveys twice in one interval
  SURVEY_LAST="$(grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' "$SURVEY_LEDGER" 2>/dev/null | sort | tail -1)"
  if [ -n "$SURVEY_LAST" ]; then
    d=$(( (NOW_EPOCH - $(iso2epoch "$SURVEY_LAST")) / 86400 ))
    if [ "$d" -lt "$SURVEY_INTERVAL_D" ]; then
      log "last survey ${d}d ago (< ${SURVEY_INTERVAL_D}d) — nothing to do"
      survey_out true null
    fi
  fi

  # Candidate areas: the profile's modules, else the default branch's top
  # directories as the profile recorded them. No profile at all = nothing to
  # survey, which is a log line, never a guess at the repository's shape.
  SURVEY_AREAS="$(jq -c '[(.modules // [])[] | {path, name: (.name // .path)}]' "$WORK/PROFILE.json" 2>/dev/null)"
  case "$SURVEY_AREAS" in (''|null) SURVEY_AREAS='[]';; esac
  if [ "$(printf '%s' "$SURVEY_AREAS" | jq length)" -eq 0 ]; then
    log "no module in work/PROFILE.json — nothing to survey (docs/profile.md)"
    survey_out true null
  fi

  # Selection, deterministic and local: never surveyed first, then the oldest
  # pass, then the most open findings the profile's history records, then the
  # name. The ledger row is `| slug | path | last_surveyed | passes | findings |`.
  SURVEY_LEDGER_JSON="$(grep -E '^\| *[A-Za-z0-9_.-]+ *\|' "$SURVEY_LEDGER" 2>/dev/null \
    | grep -vE '^\| *(area|-+) *\|' \
    | while IFS='|' read -r _ slug path last _passes _f _rest; do
        jq -nc --arg s "$(trim "$slug")" --arg p "$(trim "$path")" --arg l "$(trim "$last")" \
          '{slug:$s, path:$p, last:$l}'
      done | jq -sc .)"
  case "$SURVEY_LEDGER_JSON" in (''|null) SURVEY_LEDGER_JSON='[]';; esac
  SURVEY_HISTORY="$(jq -c '[(.history.dirs // [])[] | {dir, open: ((.critical // 0) + (.warning // 0))}]' \
    "$WORK/PROFILE.json" 2>/dev/null)"
  case "$SURVEY_HISTORY" in (''|null) SURVEY_HISTORY='[]';; esac

  SURVEY_PICK="$(jq -nc --argjson a "$SURVEY_AREAS" --argjson l "$SURVEY_LEDGER_JSON" \
    --argjson h "$SURVEY_HISTORY" '
    ($l | map({key: .slug, value: .last}) | from_entries) as $seen
    | [ $a[]
        | . as $m
        | ($m.path | gsub("[^A-Za-z0-9._-]"; "_")) as $slug
        | { slug: $slug, path: $m.path, name: $m.name,
            last: ($seen[$slug] // null),
            open: ([$h[] | select(.dir | startswith($m.path)) | .open] | add // 0) } ]
    | sort_by([(if .last == null then 0 else 1 end), (.last // ""), (- .open), .path])
    | first // null')"
  [ -n "$SURVEY_PICK" ] && [ "$SURVEY_PICK" != "null" ] || { log "no area to survey"; survey_out true null; }

  SURVEY_SLUG="$(printf '%s' "$SURVEY_PICK" | jq -r '.slug')"
  SURVEY_PATH="$(printf '%s' "$SURVEY_PICK" | jq -r '.path')"
  SURVEY_LASTP="$(printf '%s' "$SURVEY_PICK" | jq -r '.last // empty')"
  SURVEY_SLICE="$(jq -c --arg p "$SURVEY_PATH" '[(.history.dirs // [])[] | select(.dir | startswith($p))]' \
    "$WORK/PROFILE.json" 2>/dev/null)"
  case "$SURVEY_SLICE" in (''|null) SURVEY_SLICE='[]';; esac
  SURVEY_PASSES="$(grep -E "^\| *$SURVEY_SLUG *\|" "$SURVEY_LEDGER" 2>/dev/null | head -1 | cut -d'|' -f5 | tr -d ' ')"
  case "$SURVEY_PASSES" in (''|*[!0-9]*) SURVEY_PASSES=0;; esac

  log "survey due: $SURVEY_PATH (pass $((SURVEY_PASSES + 1)), last ${SURVEY_LASTP:-never})"
  survey_out false "$(jq -nc --arg s "$SURVEY_SLUG" --arg p "$SURVEY_PATH" \
    --arg n "$(printf '%s' "$SURVEY_PICK" | jq -r '.name')" \
    --arg l "${SURVEY_LASTP:-}" --argjson pass "$((SURVEY_PASSES + 1))" \
    --argjson hs "$SURVEY_SLICE" --arg rep "$EFF_SURVEY" \
    '{slug:$s, path:$p, area:$n, pass:$pass,
      last_surveyed:(if $l == "" then null else $l end),
      history_slice:$hs, report:$rep}')"
fi

# ========================================================= BENCHMARK MODE ====
# Purely local — deciding a benchmark run needs no GitHub call, so this block
# sits before the target-repo resolution (whose last fallback is a gh call)
# and the open-PR fetch: a disabled or gated benchmark tick never touches the
# network, and a missing CONFIG degrades to nothing_to_do instead of a
# resolution failure. The actions live in docs/benchmark.md: create_fixture
# (set incomplete) and run (monthly). The scheduled cadence is monthly; the
# 27-day floor keeps a drifting cron from double-running inside one calendar
# month, and only `trigger: scheduled` results feed it — manual and trial
# runs never move the official cadence.
if [ "$MODE" = "benchmark" ]; then
  bench_out() { # <nothing_to_do bool> <benchmark_due json | null>
    printf '%s\n' "$NOW_ISO benchmark nothing_to_do=$1 ${LOGS[*]:-}" >> "$WORK/HEARTBEAT.log" 2>/dev/null
    logev info heartbeat "mode=benchmark nothing_to_do=$1 benchmark=$([ "$1" = "false" ] && echo 1 || echo 0)"
    jq -n --argjson nothing "$1" --argjson due "$2" \
      --argjson logs "$(printf '%s\n' "${LOGS[@]:-}" | jq -R . | jq -s '[.[] | select(length>0)]')" \
      '{mode:"benchmark", nothing_to_do:$nothing, logs:$logs}
       + (if $due == null then {} else {benchmark_due:$due} end)'
    exit 0
  }
  BENCH="$(cfg benchmark)"
  if [ "$BENCH" != "enabled" ]; then
    log "benchmark disabled — nothing to do"
    bench_out true null
  fi
  BENCH_JUDGE="$(cfg benchmark_judge)"; BENCH_JUDGE="${BENCH_JUDGE:-off}"
  report_surface benchmark_report EFF_REPORT
  BENCH_DIR="$WORK/benchmark"
  BENCH_MIN_FIXTURES=5
  # the active set: every fixture/<slug>/ carrying a manifest (each immutable)
  BENCH_SLUGS="$(for d in "$BENCH_DIR"/fixture/*/; do
    [ -f "${d}manifest.json" ] || continue
    d="${d%/}"; printf '%s\n' "${d##*/}"
  done 2>/dev/null | sort)"
  BENCH_SLUGS_JSON="$(printf '%s\n' "$BENCH_SLUGS" | jq -R . | jq -s '[.[] | select(length > 0)]')"
  BENCH_COUNT="$(printf '%s' "$BENCH_SLUGS_JSON" | jq length)"
  if [ "$BENCH_COUNT" -lt "$BENCH_MIN_FIXTURES" ]; then
    log "benchmark enabled, fixture set incomplete ($BENCH_COUNT/$BENCH_MIN_FIXTURES) — create_fixture due"
    bench_out false "$(jq -n --argjson e "$BENCH_SLUGS_JSON" --argjson m "$BENCH_MIN_FIXTURES" \
      '{action:"create_fixture", existing:$e, min:$m}')"
  fi
  # run lock: one scored run at a time. The lock is a file the running
  # session writes (first line: <ISO> <nonce>) and removes when it ends,
  # terminal aborts included; while it is fresh no second run is emitted —
  # two concurrent runs share /tmp trees and corrupt each other's
  # measurements. Past the TTL (a benchmark run never legitimately exceeds
  # it) the lock is stale and the run proceeds over it.
  BENCH_LOCK="$BENCH_DIR/.run-lock"
  if [ -f "$BENCH_LOCK" ]; then
    BENCH_LOCK_TS="$(head -1 "$BENCH_LOCK" 2>/dev/null | cut -d' ' -f1)"
    BENCH_LOCK_AGE_M=$(( (NOW_EPOCH - $(iso2epoch "${BENCH_LOCK_TS:-1970-01-01T00:00:00Z}")) / 60 ))
    if [ "$BENCH_LOCK_AGE_M" -ge 0 ] && [ "$BENCH_LOCK_AGE_M" -lt "$BENCH_LOCK_TTL_MIN" ]; then
      log "benchmark run already in progress (lock ${BENCH_LOCK_AGE_M}m old) — nothing to do"
      bench_out true null
    fi
    log "stale benchmark run lock (${BENCH_LOCK_AGE_M}m ≥ ${BENCH_LOCK_TTL_MIN}m) — emitting run over it"
  fi

  # segmented-run ledger (docs/benchmark.md → Segmented run): a manual run
  # paused between one-fixture segments holds no lock, so the ledger is what
  # keeps a scheduled tick from starting a second run mid-pause. Past 7 days
  # the run counts as abandoned and the tick is emitted over it.
  for rn in "$BENCH_DIR"/.run-notes-*.md; do
    [ -f "$rn" ] || continue
    if [ -n "$(find "$rn" -maxdepth 0 -mtime -7 2>/dev/null)" ]; then
      log "segmented benchmark run in progress ($(basename "$rn")) — nothing to do"
      bench_out true null
    fi
    log "stale segmented-run notes ($(basename "$rn"), >7d) — emitting run over it"
  done

  # monthly gate: newest scheduled run in the canonical results/*.json (the
  # RESULTS.md index is presentation; manual/trial runs never feed the gate).
  # Per-file tolerant load — one corrupt results file never erases the gate.
  LAST_TS="$(for f in "$BENCH_DIR"/results/*.json; do
               [ -f "$f" ] || continue
               jq -c 'select(type == "object")' "$f" 2>/dev/null || true
             done | jq -rs '[.[] | select(.trigger == "scheduled") | .ts // empty]
                            | sort | last // empty')"
  if [ -n "$LAST_TS" ]; then
    BENCH_AGE_D=$(( (NOW_EPOCH - $(iso2epoch "$LAST_TS")) / 86400 ))
    if [ "$BENCH_AGE_D" -lt 27 ]; then
      log "benchmark ran ${BENCH_AGE_D}d ago (< 27d) — nothing to do"
      bench_out true null
    fi
  fi
  log "benchmark run due on $BENCH_COUNT fixture(s) (last scheduled run: ${LAST_TS:-never})"
  bench_out false "$(jq -n --argjson f "$BENCH_SLUGS_JSON" --arg r "$BENCH_DIR/fixture" \
    --arg j "$BENCH_JUDGE" --arg rep "$EFF_REPORT" --arg l "${LAST_TS:-}" \
    '{action:"run", fixtures:$f, fixture_root:$r, judge:$j, report:$rep,
      last_run:(if $l == "" then null else $l end)}')"
fi

# Is the session holding PR #<n>'s lock still working? Local signals only, no
# API call: lib/holds.sh's live_holders over the events since the lock. When no
# run logged a `locked` step on the PR since the lock — the step can predate log
# retention after a crash — a recent event naming `PR #<n> ` counts as life
# instead, from a run that has not ended the PR. Prints the live run id (8
# chars) + minutes since its last event, or nothing.
# docs/review-mechanics.md → **Live holder**.
holder_alive() { # <pr-number> <lock-ts> -> "<run> <how it is alive>", empty when not
  holder_cutoffs || return 1
  events_jsonl | jq -rs --arg n "$1" --arg lock "${2:0:19}" --arg cut "$HOLDER_CUT" --arg fcut "$FANOUT_CUT" \
      --argjson now "$NOW_EPOCH" "$HOLDER_JQ"'
      [ .[] | select(tkey >= $lock) ] as $ev
      | ($ev | pr_steps($n)) as $pr
      | ($ev | live_holders($n; $cut; $fcut)) as $h
      | if ($h | length) > 0 then ($h | map(.last) | sort_by(tkey) | last)
        elif any($pr[]; locked_step) then null
        else ([ $ev[] | select((.msg // "") | contains("PR #" + $n + " ")) | select(ended($pr; .run) | not) ]
              | alive_last($cut; $fcut)) end
      | select(. != null) as $l
      | ( ($l.msg // "") | test("fanned out") ) as $fan
      | ((($now - (($l | tkey) + "Z" | fromdateiso8601)) / 60) | floor) as $mins
      | "\($l.run[0:8]) \(if $fan then "in the skill fan-out, last event" else "active" end) \($mins)m ago"' 2>/dev/null
}

# Drop the entries of every PR another live run holds (lib/holds.sh); the first
# run after its release serves them. `reviews` runs before the review entries
# cost API calls and skill installs, `mentions` after the mention scan; each PR
# is judged and logged once (HOLDS_JUDGED). Sets REVIEWS_DUE or MENTIONS_DUE.
HOLDS_JUDGED=" "
apply_holds() { # reviews|mentions
  local var n why rc held=""
  case "$1" in (reviews) var=REVIEWS_DUE;; (mentions) var=MENTIONS_DUE;; (*) return 0;; esac
  [ -d "$HOLD_DIR" ] || return 0
  for n in $(printf '%s' "${!var}" | jq -r 'map(.number) | unique | .[]'); do
    case "$HOLDS_JUDGED" in
      (*" $n:held "*) held="$held $n"; continue;;
      (*" $n:free "*) continue;;
    esac
    why="$(hold_live "$n")"; rc=$?
    case $rc in
      0) log "#$n: $why — its reviews and mentions are left to that run"
         HOLDS_JUDGED="$HOLDS_JUDGED$n:held "; held="$held $n";;
      2) log "#$n: hold from $why released — its run is quiet"; HOLDS_JUDGED="$HOLDS_JUDGED$n:free ";;
      *) HOLDS_JUDGED="$HOLDS_JUDGED$n:free ";;
    esac
  done
  [ -n "$held" ] || return 0
  printf -v "$var" '%s' "$(printf '%s' "${!var}" | jq --arg h "$held" \
    '($h | split(" ") | map(select(length > 0) | tonumber)) as $h | map(select(.number | IN($h[]) | not))')"
}

# jq helpers the audit statistics and the progress ETA share: an event
# timestamp as epoch, a median whose mid-point of an even count is rounded by
# <f> (floor for minutes and seconds, round for sizes and hours), and the
# review_step events since <s> parsed into {run, pr, ts, rest} — rest without
# the optional sha token.
STATS_JQ='
  def epoch: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
  def median(f): sort | if length == 0 then null
                        elif (length % 2) == 1 then .[(length / 2) | floor]
                        else ((.[length / 2 - 1] + .[length / 2]) / 2 | f) end;
  def review_steps($s):
    [ .[] | select(.ts >= $s and .event == "review_step")
      | select((.msg // "") | test("^PR #[0-9]+:? +."))
      | (.msg | capture("^PR #(?<pr>[0-9]+):? +(?<rest>.*)$")) as $c
      | { run: .run, pr: $c.pr, ts: .ts, rest: ($c.rest | sub("^[0-9a-f]{7,40}( +|$)"; "")) } ];
'
# ---------------------------------------------------------------- config ----
TARGET_REF="$(cfg github_repo)"
[ -z "$TARGET_REF" ] && TARGET_REF="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)"
REPO_HOST="$(refhost "$TARGET_REF")"; REPO="$(refslug "$TARGET_REF")"
export GH_HOST="$REPO_HOST"   # every unqualified gh call targets the review host
BOT_LOGIN="$(cfg bot_login)"
WORK_REPO="$(cfg work_repo)"   # empty = local-only persistence (docs/persistence.md)
REVIEW_MARKER="$(cfg review_marker)"
REREVIEW_LABEL="$(cfg rereview_label)"; REREVIEW_LABEL="${REREVIEW_LABEL:-code-guardian-review}"
URGENT_LABEL="$(cfg urgent_label)"   # empty/missing = urgent handling off
ARTIFACT="$(cfg artifact_skill)"
ARTIFACT_SKILL="${ARTIFACT%%@*}"; ARTIFACT_SRC="${ARTIFACT##*@}"
{ [ "$ARTIFACT" = "none" ] || [ -z "$ARTIFACT" ]; } && ARTIFACT_SKILL=""
ARTIFACT_RETRY_H=24   # generate backoff after a dam-unavailable skip (docs/artifact.md)
SLACK="$(cfg slack_notifications)"
ESCALATION_OWNER="$(cfg escalation_owner)"
# stalled-review alert threshold: stalls per 24h that trigger one alert (0/off = disabled)
STALL_ALERT_THRESHOLD="$(cfg stall_alert_threshold)"
STALL_ALERT_THRESHOLD="${STALL_ALERT_THRESHOLD:-4}"
# one takeover event -> {ts, pr, lock}; lock = "" on a line written before 8.2.1.
# Applied per event under `try`: an event it cannot read is skipped.
STALL_SEL='select(.event == "preflight" and (.msg | test("stale in_progress lock")))
  | {ts, pr: (.msg | capture("PR #(?<n>[0-9]+)") | .n | tonumber),
     lock: ((.msg | capture("locked (?<l>[^ )]+)") | .l) // "")}'
# stalls(scope): takeover events -> one event per stall, its first line. A
# keyed line counts once per (PR, lock time); an unkeyed line once per (PR,
# scope), and only when no keyed line of that PR shares the scope
STALL_DEFS='def stalls(scope): map(.scope = (.ts | scope))
  | ([.[] | select(.lock != "") | [.pr, .scope]] | unique) as $kp
  | (map(select(.lock != "")) | group_by([.pr, .lock]) | map(min_by(.ts)))
    + (map(select(.lock == "" and ([.pr, .scope] | IN($kp[]) | not)))
       | group_by([.pr, .scope]) | map(min_by(.ts)));'
case "$STALL_ALERT_THRESHOLD" in
  (off|none) STALL_ALERT_THRESHOLD=0;;
  (*[!0-9]*|'') STALL_ALERT_THRESHOLD=4;;   # unparseable -> documented default
esac
# Review cadence (docs/config.md). The crons themselves live
# in the platform scheduler (ONBOARDING Step 6a); the only thing read here is
# the quiet interval, because the audit's heartbeat-gap check is measured
# against it — a legitimate quiet-hour gap must never read as a missed
# heartbeat. Never stricter than the historical one-hour tolerance.
REVIEW_INTERVAL_QUIET="$(cfg review_interval_quiet)"
case "$REVIEW_INTERVAL_QUIET" in
  (''|*[!0-9]*) REVIEW_INTERVAL_QUIET=60;;          # missing/unparseable -> default
  (*) [ "$REVIEW_INTERVAL_QUIET" -ge 1 ] || REVIEW_INTERVAL_QUIET=60;;
esac
HB_GAP_MAX_S=$(( REVIEW_INTERVAL_QUIET * 90 ))      # 1.5x the quiet interval
[ "$HB_GAP_MAX_S" -ge 3600 ] || HB_GAP_MAX_S=3600
# in-progress lock TTL: minutes after which a lock is *candidate* for takeover.
# Calibrated above the review pipeline's p95 (docs/review-mechanics.md → Review tracking
# state) — a value under it hands live reviews to a second job.
LOCK_TTL_MIN=50
MENTION_PAGES=3                       # comment pages the mention scan follows (docs/mentions.md)
# HOLDER_QUIET_MIN and FANOUT_QUIET_MIN, the live-holder windows: lib/holds.sh
# branch of $DEFINITION_REPO this instance tracks (default main)
DEFINITION_BRANCH="$(cfg definition_branch)"; DEFINITION_BRANCH="${DEFINITION_BRANCH:-main}"
# GitHub progress signal — commit status on the reviewed SHA (docs/review.md)
PROGRESS="$(cfg review_progress)"; PROGRESS="${PROGRESS:-disabled}"
case "$PROGRESS" in
  (enabled|disabled) ;;
  (*) log "review_progress '$PROGRESS' unknown — treating as disabled"; PROGRESS=disabled;;
esac
# CI failure triage — one comment explaining a failing check (docs/ci-triage.md)
CI_TRIAGE="$(cfg ci_triage)"; CI_TRIAGE="${CI_TRIAGE:-disabled}"
case "$CI_TRIAGE" in
  (enabled|disabled) ;;
  (*) log "ci_triage '$CI_TRIAGE' unknown — treating as disabled"; CI_TRIAGE=disabled;;
esac
if [ "$CI_TRIAGE" = "enabled" ] && [ "$CI_LIB" -eq 0 ]; then
  CI_TRIAGE=disabled
  log_warn "lib/ci-rollup.sh unreadable — CI failure triage disabled this run"
fi
CI_TRIAGE_WINDOW_H=24   # age of the posted review past which CI is stale news
# Housekeeping deferral (docs/worklist.md → **The schedule gate**): bookkeeping
# alone never starts a session immediately — it rides along with the next run
# that has work of its own, and forces a run of its own only past this wait or
# this many pending items. The count caps both the batch and the per-row state
# check each pending prune costs every tick.
HOUSEKEEPING_DEFER_H=6
HOUSEKEEPING_MAX_ITEMS=10
HOUSEKEEPING_SINCE="$WORK/.housekeeping-since"

# The resolved configuration the agent works from (docs/config.md → Runtime
# configuration): every key with its default applied, plus the two tables as
# rows — emitted with the worklist whenever there is work, so a run never
# parses work/CONFIG.md itself. Values only; nothing here is a decision.
BOT_NAME="$(cfg bot_display_name)"; BOT_NAME="${BOT_NAME:-Code Guardian}"
PROJECT_PROFILE="$(cfg project_profile)"; PROJECT_PROFILE="${PROJECT_PROFILE:-enabled}"
SKILLS_TABLE="$(skills_table_json)"; [ -n "$SKILLS_TABLE" ] || SKILLS_TABLE='[]'
WATCH_RULES="$(cfg_table 'Watch rules' | while IFS='|' read -r _ id wf notify note _rest; do
    id="$(trim "$id")"; case "$id" in (''|id|-*|:*) continue;; esac
    jq -nc --arg id "$id" --arg w "$(trim "$wf")" --arg n "$(trim "$notify")" --arg note "$(trim "$note")" \
      '{id:$id, watch_for:$w, notify:$n, note:$note}'
  done | jq -s .)"; [ -n "$WATCH_RULES" ] || WATCH_RULES='[]'
report_surface audit_trend AUDIT_TREND
CONFIG_JSON="$(jq -nc --arg repo "$REPO" --arg host "$REPO_HOST" --arg bot "$BOT_LOGIN" --arg name "$BOT_NAME" \
  --arg marker "$REVIEW_MARKER" --arg lbl "$REREVIEW_LABEL" --arg trig "$(cfg rereview_trigger)" --arg urg "$URGENT_LABEL" \
  --arg prog "$PROGRESS" --arg ci "$CI_TRIAGE" --arg mr "$(cfg mention_replies)" --arg ma "$(cfg mention_authors)" --arg art "${ARTIFACT_SKILL:+$ARTIFACT}" \
  --arg slack "$SLACK" --arg audit "$(cfg audit_report)" --arg atr "$AUDIT_TREND" \
  --arg eo "$ESCALATION_OWNER" --argjson stall "$STALL_ALERT_THRESHOLD" \
  --arg ll "$(cfg log_level)" --arg def "$(cfg definition_repo)" --arg db "$DEFINITION_BRANCH" --arg pp "$PROJECT_PROFILE" \
  --arg wr "$WORK_REPO" --arg ss "$(cfg shepherd_scope)" --arg hp "$(cfg human_review_paths | tr -d '`')" \
  --arg am "$(cfg auto_merge)" --arg aml "$(cfg auto_merge_label)" --arg amx "$(cfg auto_merge_max_lines)" --arg amm "$(cfg auto_merge_method)" \
  --arg af "$(cfg agent_fixes)" --arg afl "$(cfg agent_fix_label)" \
  --arg bench "$(cfg benchmark)" --arg bj "$(cfg benchmark_judge)" --arg br "$(cfg benchmark_report)" \
  --arg mrn "$(cfg merge_ready_nudge)" --arg sv "$(cfg survey)" --arg sr "$(cfg survey_report)" --arg sid "$(cfg survey_interval_days)" \
  --argjson skills "$SKILLS_TABLE" --argjson watches "$WATCH_RULES" \
  --arg ah "$(cfg active_hours)" --arg ad "$(cfg active_days)" --arg ria "$(cfg review_interval_active)" --argjson riq "$REVIEW_INTERVAL_QUIET" '
  {github_repo:$repo, repo_host:$host, bot_login:(if $bot=="" then null else $bot end), bot_display_name:$name,
   active_hours:(if $ah=="" then "00-23" else $ah end), active_days:(if $ad=="" then "Mon-Sun" else $ad end),
   review_interval_active:(if ($ria|test("^[0-9]+$")) then ($ria|tonumber) else 5 end), review_interval_quiet:$riq,
   review_marker:(if $marker=="" then null else $marker end), rereview_label:$lbl,
   rereview_trigger:(if $trig=="" then "label" else $trig end), urgent_label:(if $urg=="" then null else $urg end),
   review_progress:$prog, ci_triage:$ci, mention_replies:(if $mr=="" then "enabled" else $mr end),
   mention_authors:(if $ma=="anyone" then "anyone" else "collaborators" end),
   artifact_skill:(if $art=="" then "none" else $art end),
   slack_notifications:(if $slack=="" then "disabled" else $slack end), audit_report:(if $audit=="" then "enabled" else $audit end),
   audit_trend:$atr,
   escalation_owner:(if $eo=="" then null else $eo end), stall_alert_threshold:$stall,
   log_level:(if $ll=="" then "info" else $ll end), definition_repo:(if $def=="" then null else $def end), definition_branch:$db,
   work_repo:(if $wr=="" then null else $wr end),
   shepherd_scope:(if $ss=="needs_human" then "needs_human" else "all" end),
   human_review_paths:(if $hp=="" then null else $hp end),
   auto_merge:(if $am=="enabled" and $aml!="" then "enabled" else "disabled" end),
   auto_merge_label:(if $aml=="" then null else $aml end),
   auto_merge_max_lines:(if ($amx|test("^[0-9]+$")) then ($amx|tonumber) else 100 end),
   auto_merge_method:(if ($amm|IN("merge","squash","rebase")) then $amm else "squash" end),
   agent_fixes:(if $af=="enabled" and $afl!="" then "enabled" else "disabled" end),
   agent_fix_label:(if $afl=="" then null else $afl end),
   project_profile:$pp, benchmark:(if $bench=="" then "disabled" else $bench end),
   benchmark_judge:(if $bj=="" then "off" else $bj end), benchmark_report:(if $br=="off" then "off" else "dam" end),
   merge_ready_nudge:(if $mrn=="enabled" then "enabled" else "disabled" end),
   survey:(if $sv=="enabled" then "enabled" else "disabled" end), survey_report:(if $sr=="off" then "off" else "dam" end),
   survey_interval_days:(if ($sid|test("^[0-9]+$")) then ($sid|tonumber) else 7 end),
   skills_table:$skills, watch_rules:$watches}')"

# Memory budget (docs/preferences.md → Two layers): the caps of the layer every
# run reads whole, measured. The archive (work/memory/archive/) has no cap and
# is never measured. Review runs log an overrun; the audit turns it into a
# check and a mandatory consolidation. Local reads only, no judgment.
memory_budget_json() {
  local ml=0 ins=0 fb=0 ls=0 lng=0 ll=0 llng=0 over=false f t body tover='[]' tunsc='[]' tmax=0
  [ -f "$WORK/MEMORY.md" ] && ml="$(grep -c '' "$WORK/MEMORY.md" 2>/dev/null || true)"
  ins="$(sed -n '/^## Observed Insights/,/^## /p' "$WORK/MEMORY.md" 2>/dev/null | grep -c '^- ' || true)"
  fb="$(sed -n '/^## Feedback Log/,/^## /p' "$WORK/MEMORY.md" 2>/dev/null | grep -c '^- ' || true)"
  ls="$(grep -c '^## ' "$WORK/LESSONS.md" 2>/dev/null || true)"
  [ -f "$WORK/LESSONS.md" ] && ll="$(grep -c '' "$WORK/LESSONS.md" 2>/dev/null || true)"
  llng="$(grep -cE '^.{201,}' "$WORK/LESSONS.md" 2>/dev/null || true)"
  # a rule whose wording never moved to the archive (docs/preferences.md →
  # Entry form): the line, not the file, is what the next consolidation distills
  # whole-line length: "- " plus 119 or more is 121+, so the bound itself passes
  lng="$(grep -cE '^- .{119,}' "$WORK/MEMORY.md" 2>/dev/null || true)"
  # area files: the body after the front matter holds rule lines only; a file
  # without `scope:` (or its alias `paths:`, as profile.sh reads it) is never
  # loaded by a review, so it belongs in the archive
  for f in "$WORK"/memory/*.md; do
    [ -f "$f" ] || continue
    t="${f##*/}"; t="${t%.md}"
    # front matter: the lines between a first-line `---` and the next `---`
    if ! sed -n '1{/^---$/!q;d;}; /^---$/q; p' "$f" | grep -qE '^(scope|paths):'; then
      tunsc="$(printf '%s' "$tunsc" | jq -c --arg t "$t" '. + [$t]')"; continue
    fi
    body="$(sed '1,/^---$/d' "$f")"
    b="$(printf '%s\n' "$body" | grep -c . || true)"
    [ "$b" -gt "$tmax" ] && tmax="$b"
    if [ "$b" -gt 40 ] || printf '%s\n' "$body" | grep -qE '^.{121,}'; then
      tover="$(printf '%s' "$tover" | jq -c --arg t "$t" '. + [$t]')"
    fi
  done
  { [ "${ml:-0}" -gt 120 ] || [ "${ins:-0}" -gt 15 ] || [ "${fb:-0}" -gt 20 ] \
    || [ "${ls:-0}" -gt 10 ] || [ "${lng:-0}" -gt 0 ] || [ "${ll:-0}" -gt 100 ] || [ "${llng:-0}" -gt 0 ] \
    || [ "$tover" != '[]' ] || [ "$tunsc" != '[]' ]; } && over=true
  jq -nc --argjson ml "${ml:-0}" --argjson ins "${ins:-0}" --argjson fb "${fb:-0}" --argjson ls "${ls:-0}" \
    --argjson lng "${lng:-0}" --argjson ll "${ll:-0}" --argjson llng "${llng:-0}" \
    --argjson tover "$tover" --argjson tunsc "$tunsc" --argjson tmax "$tmax" --argjson over "$over" \
    '{memory_lines:$ml, memory_limit:120, insights:$ins, insights_limit:15, feedback:$fb, feedback_limit:20,
      lessons_sections:$ls, lessons_limit:10, lessons_lines:$ll, lessons_lines_limit:100,
      lessons_long_lines:$llng, lessons_line_limit:200, long_lines:$lng, line_limit:120,
      area_over:$tover, area_unscoped:$tunsc, area_max_lines:$tmax, area_lines_limit:40, over_budget:$over}'
}
MEMORY_JSON="$(memory_budget_json)"
# memory mode: the budget alone, so a consolidation measures its own result
# (docs/preferences.md → Weekly memory consolidation) — local reads, no bookkeeping
[ "$MODE" = "memory" ] && { printf '%s\n' "$MEMORY_JSON"; exit 0; }
PROFILE_JSON_OUT='null'

# preflight could not decide (no repo, no answer from the API): the JSON names
# the cause in `error` and the exit code is 2, so the gate reports a broken
# gate and the session starts (precheck.sh), never an idle tick.
fail_out() {
  logev error preflight "$1"
  jq -n --arg mode "$MODE" --arg err "$1" \
    --argjson logs "$(printf '%s\n' "${LOGS[@]:-}" | jq -R . | jq -s '[.[] | select(length>0)]')" \
    '{mode:$mode, nothing_to_do:true, error:$err, logs:$logs}'
  exit 2
}

[ -z "$REPO" ] && fail_out "target repo unresolved (CONFIG.md github_repo missing)"
[ "$MODE" = "review" ] && [ "$HOLDS_LIB" -eq 0 ] \
  && fail_out "lib/holds.sh unreadable — live holders and PR holds cannot be judged"
[ -f "$CONFIG" ] || log "work/CONFIG.md missing — running with defaults"

# ------------------------------------------------------------ open PR set ----
# an open-PR list is always a JSON array, `[]` included: anything else is no
# answer, and the API's own error text names the cause
OPEN_ERR="$(mktemp "${TMPDIR:-/tmp}/cg-open-err.XXXXXX" 2>/dev/null)" || OPEN_ERR=/dev/null
OPEN_JSON="$(gh api "repos/$REPO/pulls?state=open&per_page=100" 2>"$OPEN_ERR")"
if ! printf '%s' "$OPEN_JSON" | jq -e 'type == "array"' >/dev/null 2>&1; then
  OPEN_WHY="$(head -c 300 "$OPEN_ERR" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
  [ "$OPEN_ERR" = /dev/null ] || rm -f "$OPEN_ERR"
  fail_out "could not list open PRs on $REPO (API error${OPEN_WHY:+: $OPEN_WHY})"
fi
[ "$OPEN_ERR" = /dev/null ] || rm -f "$OPEN_ERR"
OPEN_NONDRAFT="$(printf '%s' "$OPEN_JSON" | jq '[.[] | select(.draft==false) | {
    number, title, author: .user.login, head_sha: .head.sha, head_ref: .head.ref,
    base_ref: .base.ref, created_at,
    labels: [.labels[]?.name], assignees: [.assignees[]?.login],
    requested: [.requested_reviewers[]?.login], url: .html_url }]')"
OPEN_COUNT="$(printf '%s' "$OPEN_NONDRAFT" | jq length)"
open_numbers() { printf '%s' "$OPEN_JSON" | jq -r '.[].number'; }   # incl. drafts (never pruned)

# ------------------------------------------------------- REVIEWS.md access ----
reviews_rows() { grep -E '^\| *[0-9]+ *\|' "$REVIEWS" 2>/dev/null || true; }
row_for()      { reviews_rows | grep -E "^\| *$1 *\|" | head -1; }
# The newest `## Review at` section of PR <n>'s history file, only while it
# reviewed <head-sha>: a call on older code never stands in for the current
# one, and a rapid pass (no review-meta) never borrows an older section's.
last_review_section() { # <pr-number> <head-sha>
  local f="$WORK/reviews/pr-$1.md" sec s7
  [ -f "$f" ] || return 0
  sec="$(sed -n -e '/^## Review at /h' -e '/^## Review at /!H' -e '${x;p;}' "$f" 2>/dev/null)"
  s7="$(printf '%s\n' "$sec" | head -1 | sed -n -E 's/^## Review at ([0-9a-f]+) .*/\1/p')"
  case "$2" in ("$s7"*) [ -n "$s7" ] || return 0;; (*) return 0;; esac
  printf '%s\n' "$sec"
}
# the PR numbers that own a file in reviews/ — the history file, the carry
# record, the review artifact (the files a prune deletes)
pr_file_numbers() {
  local f
  for f in "$WORK"/reviews/pr-*.md "$WORK"/reviews/pr-*.carry.json "$WORK"/reviews/pr-artifacts/pr-*.html; do
    [ -e "$f" ] || continue
    f="${f##*/pr-}"; f="${f%%.*}"; case "$f" in (''|*[!0-9]*) ;; (*) printf '%s\n' "$f";; esac
  done | sort -un
}
# prune candidates: every row in row order, then every PR file owner without a
# row — the urgent alert, an override or a CI triage marker writes the file
# before the first review, a draft's status reset deletes the row, and a prune
# cut short leaves the rest of the PR's files behind
prune_candidates() {
  reviews_rows | cut -d'|' -f2 | tr -d ' '
  pr_file_numbers | grep -vxF -f <(reviews_rows | cut -d'|' -f2 | tr -d ' '; echo '-')
}

# stale-clone sweep: clones a dead session never removed (live-run cleanup is
# the review pipeline's, docs/review.md). Reclaim only entries past the lock TTL
# whose PR holds no in_progress lock; the number is compared exactly so PR #4's
# sweep can never take PR #42's dirs (docs/skills.md). Runs on every heartbeat:
# an aborted run leaves its clone behind, and a weekly sweep let a week of them
# accumulate. Prints the count.
sweep_stale_clones() {
  local root="${TMPDIR:-/tmp}" d cn n=0
  for d in "$root"/review-pr-*; do
    [ -e "$d" ] || continue
    cn="${d##*/review-pr-}"; cn="${cn%%.*}"
    case "$cn" in (''|*[!0-9]*) continue;; esac
    [ "$(row_field "$(row_for "$cn")" 6)" = "in_progress" ] && continue
    # a fix round writes no lock row: its PR hold is what says it still runs
    case "$d" in (*.fix) [ "$HOLDS_LIB" -eq 1 ] && hold_live "$cn" >/dev/null && continue;; esac
    [ -n "$(find "$d" -maxdepth 0 -mmin +"$LOCK_TTL_MIN" 2>/dev/null)" ] || continue
    rm -rf "$d" && n=$((n+1))
  done
  [ "$n" -gt 0 ] && logev info tmp_cleanup "stale-clone sweep: reclaimed $n review-pr-* leftover(s) from dead sessions"
  printf '%s' "$n"
}

# the ONE local REVIEWS.md write the script performs: done -> awaiting_label
# (keeps the last review's SHA/verdict/timestamp; only the status cell changes)
flip_awaiting_label() { # number
  sed -E "s/^(\| *$1 *\|.*\|) *done *\|[[:space:]]*$/\1 awaiting_label |/" "$REVIEWS" \
    > "$REVIEWS.tmp" && mv "$REVIEWS.tmp" "$REVIEWS"
}

# marker scans distinguish three outcomes: a timestamp (marker found), ""
# (endpoints answered, marker verified absent), and the sentinel __api_error__
# (an endpoint failed twice — unknown, never to be treated as absent). Callers
# bump API_ERRS on the sentinel and stop probing once it reaches 2 — by then
# the API is down for the run, and each skipped call costs a retry + sleep.
API_ERRS=0
# Scratch for the parallel reads and the per-PR answers one scan hands the next
# (the reviews page, prune states, file lists, skill and profile status). One
# directory per pass; precheck.sh sweeps one a killed pass left behind.
PF_TMP="$(mktemp -d "${TMPDIR:-/tmp}/cg-pf.XXXXXX")"
trap 'rm -rf "$PF_TMP"' EXIT
REVIEWS_BODY="$PF_TMP/reviews-page"

# marker-based remote dedup, anchored at one SHA -> prints GitHub timestamp
remote_reviewed_at() { # number full_sha
  local m="<!-- $REVIEW_MARKER headRefOid=$2 -->" body ts err=0
  : > "$REVIEWS_BODY" 2>/dev/null
  if body="$(gh_get "repos/$REPO/pulls/$1/reviews?per_page=100")"; then
    { printf 'pr=%s\n' "$1"; printf '%s' "$body"; } > "$REVIEWS_BODY" 2>/dev/null
    ts="$(printf '%s' "$body" \
      | jq -r --arg m "$m" '[.[] | select(.body != null) | select(.body | contains($m)) | .submitted_at] | last // empty')"
    [ -n "$ts" ] && { printf '%s' "$ts"; return 0; }
  else err=1; fi
  if body="$(gh_get "repos/$REPO/issues/$1/comments?per_page=100")"; then
    ts="$(printf '%s' "$body" \
      | jq -r --arg m "$m" '[.[] | select(.body | contains($m)) | .created_at] | last // empty')"
    [ -n "$ts" ] && { printf '%s' "$ts"; return 0; }
  else err=1; fi
  [ "$err" -eq 1 ] && printf '__api_error__'
  return 0
}

# unanchored: any marker-carrying review at ANY SHA -> prints "sha<TAB>ts"
remote_reviewed_any() { # number
  local body
  # the anchored scan of the same PR just read this endpoint: reuse its answer
  if [ "$(head -1 "$REVIEWS_BODY" 2>/dev/null)" = "pr=$1" ]; then
    body="$(tail -n +2 "$REVIEWS_BODY")"
  else
    body="$(gh_get "repos/$REPO/pulls/$1/reviews?per_page=100")" || { printf '__api_error__'; return 0; }
  fi
  printf '%s' "$body" | jq -r --arg m "<!-- $REVIEW_MARKER headRefOid=" '
        [.[] | select(.body != null) | select(.body | contains($m))
             | {sha: (.body | capture("headRefOid=(?<s>[0-9a-f]{40})").s), ts: .submitted_at}]
        | last // empty | if . == "" or . == null then empty else "\(.sha)\t\(.ts)" end' 2>/dev/null
}

# Prune state checks, batched: one GraphQL call per 50 rows instead of one REST
# call per row. Still verified per PR — each alias names one PR by number. Every
# PR the batch leaves unanswered (a failed call, a null alias) is absent from the
# output, and the caller reads it with the per-PR REST call as before. Prints
# JSONL {n, pj}; pj carries the REST `pulls/<n>` fields the prune loop reads.
# GraphQL names a bot author without the `[bot]` suffix that REST carries.
prune_states() { # <number…>
  local q="" n i=0
  for n in "$@" ''; do
    if [ -n "$n" ]; then
      q="$q p$n: pullRequest(number:$n){state closedAt headRefOid headRefName title author{__typename login}}"
      i=$((i+1))
      [ "$i" -lt 50 ] && continue
    fi
    [ -n "$q" ] || continue
    gh api graphql -f o="${REPO%%/*}" -f r="${REPO#*/}" -f query="query PruneStates(\$o:String!,\$r:String!){repository(owner:\$o,name:\$r){$q}}" 2>/dev/null \
      | jq -c '(.data.repository // {}) | to_entries[] | select(.value != null and .value.state != null)
          | {n: (.key | ltrimstr("p") | tonumber),
             pj: {merged: (.value.state == "MERGED"), state: (.value.state | ascii_downcase), closed_at: .value.closedAt,
                  head: {sha: .value.headRefOid, ref: .value.headRefName},
                  title: .value.title, user: {login: (.value.author | if . == null then "ghost"
                    elif .__typename == "Bot" then "\(.login)[bot]" else .login end)}}}' 2>/dev/null
    q=""; i=0
  done
}

# Changed-file lists of the due PRs, fetched four at a time ahead of the
# inventory loop -> $PF_TMP/files-<n>. An empty file is a list that did not
# answer, exactly as the loop's own call reads it; a missing file sends the loop
# to its own call.
prefetch_files() { # <number…>
  local n i=0
  for n in "$@"; do
    ( out="$(gh api --paginate "repos/$REPO/pulls/$n/files?per_page=100" 2>/dev/null)" || out=""
      printf '%s' "$out" > "$PF_TMP/files-$n.part" && mv "$PF_TMP/files-$n.part" "$PF_TMP/files-$n" ) &
    i=$((i+1)); [ $((i % 4)) -eq 0 ] && wait
  done
  wait
}

# ------------------------------------------------------------ skill install ----
install_skill() { # name source -> status string (local writes only)
  local name="$1" src="$2" h slug sha cached count=0 p rel
  [ "$src" = "harness" ] && { printf 'harness'; return; }
  h="$(refhost "$src")"; slug="$(refslug "$src")"
  sha="$(gh api --hostname "$h" "repos/$slug/commits/main" 2>/dev/null | jq -r '.sha // empty')"
  mkdir -p "$SKILL_CACHE"
  cached="$(cat "$SKILL_CACHE/$name.sha" 2>/dev/null || true)"
  if [ -n "$sha" ] && [ "$sha" = "$cached" ] && [ -d "$HOME_DIR/.claude/skills/$name" ]; then
    printf 'cached'; return
  fi
  rm -rf "$HOME_DIR/.claude/skills/$name"
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    rel="${p#.agents/skills/$name/}"
    mkdir -p "$HOME_DIR/.claude/skills/$name/$(dirname "$rel")"
    gh api --hostname "$h" "repos/$slug/contents/$p?ref=main" -H 'Accept: application/vnd.github.raw' \
      > "$HOME_DIR/.claude/skills/$name/$rel" 2>/dev/null \
      || { logev error skill_install "$name from $src: fetch of $p did not succeed"; printf 'install-failed'; return; }
    count=$((count+1))
  done < <(gh api --hostname "$h" "repos/$slug/git/trees/main?recursive=1" 2>/dev/null \
           | jq -r --arg pre ".agents/skills/$name/" '.tree[] | select(.type=="blob") | select(.path | startswith($pre)) | .path')
  [ "$count" -eq 0 ] && { logev error skill_install "$name from $src: no files found (tree listing empty or unreachable)"; printf 'install-failed'; return; }
  [ -n "$sha" ] && printf '%s' "$sha" > "$SKILL_CACHE/$name.sha"
  printf 'installed (%s files)' "$count"
}

# The wait a pending housekeeping batch has already served. Review mode only:
# a shepherd sweep carries no bookkeeping and must never consume the review
# heartbeat's clock. Prints nothing when there is no batch.
hk_batch_since() { # <pending count>
  local since
  [ "$MODE" = "review" ] || return 0
  [ "$1" -gt 0 ] || { rm -f "$HOUSEKEEPING_SINCE" 2>/dev/null; return 0; }
  since="$(head -1 "$HOUSEKEEPING_SINCE" 2>/dev/null || true)"
  if [ -z "$since" ]; then
    since="$NOW_ISO"
    printf '%s\n' "$since" > "$HOUSEKEEPING_SINCE" 2>/dev/null || true
  fi
  printf '%s' "$since"
}

emit() { # reviews label_cleanups selfheals prunes artifacts nudges alerts mentions skills
  local nothing=true a resets="${STATUS_RESETS_DUE:-[]}" cifail="${CI_FAILURES_DUE:-[]}" merges="${MERGES_DUE:-[]}" fixes="${FIXES_DUE:-[]}"
  local hk_only=false hk_n=0 hk_since hk_age=0
  # Tier 1 — a person is waiting for it, so it starts a session on its own.
  # A label cleanup answers a person who put a trigger on a reviewed SHA.
  for a in "$1" "$2" "$5" "$6" "$7" "$8" "$cifail" "$merges" "$fixes"; do
    [ "$(printf '%s' "$a" | jq length)" -gt 0 ] && nothing=false
  done
  # a due stall alert is work in its own right — never let it be swallowed by an
  # otherwise idle heartbeat, and never deferred: this pass already spent its
  # once-per-UTC-day claim, so a skipped fire loses the alert
  [ -n "${STALL_ALERT:-}" ] && nothing=false
  # Tier 2 — bookkeeping nobody waits on, deferrable (HOUSEKEEPING_DEFER_H).
  for a in "$3" "$4" "$resets"; do
    hk_n=$(( hk_n + $(printf '%s' "$a" | jq length) ))
  done
  hk_since="$(hk_batch_since "$hk_n")"
  if [ "$hk_n" -gt 0 ] && [ -n "$hk_since" ]; then
    hk_age=$(( (NOW_EPOCH - $(iso2epoch "$hk_since")) / 3600 ))
    if [ "$nothing" = "false" ]; then
      log "housekeeping: $hk_n bookkeeping item(s) ride along with this run"
    elif [ "$hk_age" -ge "$HOUSEKEEPING_DEFER_H" ] || [ "$hk_n" -ge "$HOUSEKEEPING_MAX_ITEMS" ]; then
      nothing=false; hk_only=true
      log "housekeeping batch: $hk_n item(s) pending since $hk_since — a bookkeeping-only run"
    else
      log "housekeeping: $hk_n item(s) pending since $hk_since (${hk_age}h of ${HOUSEKEEPING_DEFER_H}h) — deferred to the next run with work"
    fi
  fi
  printf '%s\n' "$NOW_ISO $MODE nothing_to_do=$nothing ${LOGS[*]:-}" >> "$WORK/HEARTBEAT.log" 2>/dev/null
  # the audit's wake-up count reads these keys back (stats.wakeups); the
  # audit_wakeups_roundtrip test holds writer and reader together
  logev info heartbeat "mode=$MODE nothing_to_do=$nothing reviews=$(printf '%s' "$1" | jq length) nudges=$(printf '%s' "$6" | jq length) mentions=$(printf '%s' "$8" | jq length) artifacts=$(printf '%s' "$5" | jq length) cleanups=$(printf '%s' "$2" | jq length) alerts=$(printf '%s' "$7" | jq length) ci=$(printf '%s' "$cifail" | jq length) merges=$(printf '%s' "$merges" | jq length) fixes=$(printf '%s' "$fixes" | jq length) stall=$([ -n "${STALL_ALERT:-}" ] && echo 1 || echo 0) housekeeping=$([ "$hk_only" = "true" ] && echo 1 || echo 0)"
  jq -n --arg mode "$MODE" --argjson nothing "$nothing" \
    --argjson reviews "$1" --argjson cleanups "$2" --argjson selfheals "$3" \
    --argjson prunes "$4" --argjson artifacts "$5" --argjson nudges "$6" \
    --argjson alerts "$7" --argjson mentions "$8" --argjson skills "$9" \
    --argjson resets "$resets" --argjson cifail "$cifail" --argjson merges "$merges" --argjson fixes "$fixes" --argjson stall "${STALL_ALERT:-null}" \
    --argjson hkonly "$hk_only" \
    --argjson profile "${PROFILE_JSON_OUT:-null}" --argjson config "${CONFIG_JSON:-null}" --argjson memory "${MEMORY_JSON:-null}" \
    --argjson logs "$(printf '%s\n' "${LOGS[@]:-}" | jq -R . | jq -s '[.[] | select(length>0)]')" \
    "$READ_SET_JQ"'{mode:$mode, nothing_to_do:$nothing, reviews_due:$reviews, label_cleanups_due:$cleanups,
      selfheals_due:$selfheals, prunes_due:$prunes, artifacts_due:$artifacts,
      nudges_due:$nudges, urgent_alerts_due:$alerts, mentions_due:$mentions,
      status_resets_due:$resets, ci_failures_due:$cifail, merges_due:$merges, fixes_due:$fixes, skills:$skills, logs:$logs}
     + (if $stall == null then {} else {stall_alert:$stall} end)
     + (if $hkonly then {housekeeping_only:true} else {} end)
     + (if $nothing then {} else {config:$config, memory:$memory} end)
     + (if $profile == null then {} else {profile:$profile} end)
     | if .mode == "review" and (.nothing_to_do | not) then . + {read_set: read_set} else . end'
}

# The files a review-mode run reads before acting (docs/runbook.md → Review
# run, step 2): the core per due key, the rare cases only when an entry needs
# them. A mention reply and a CI triage comment write outward prose, so they
# read review.md for its style rules and PR-context calls. A file the run needs
# later — a `carry`, a `closed_*` post, an on-demand ask — is read on that
# trigger, not here.
READ_SET_JQ='def read_set:
  if .housekeeping_only then ["docs/review-bookkeeping.md"] else
    (if [.reviews_due, .mentions_due, .ci_failures_due, .fixes_due] | any(length > 0) then ["docs/review.md"] else [] end)
    + (if (.reviews_due | length) > 0 then ["docs/finding-form.md", "docs/skills.md"] else [] end)
    + (if any(.reviews_due[]; .kind == "re-review") then ["docs/review-rereview.md"] else [] end)
    + (if any(.reviews_due[]; .urgent == true or .closed == true) or (.urgent_alerts_due | length) > 0
       then ["docs/review-urgent.md"] else [] end)
    + (if ([.selfheals_due, .label_cleanups_due, .prunes_due, .status_resets_due] | map(length) | add) > 0
          or .stall_alert != null
       then ["docs/review-bookkeeping.md"] else [] end)
    + (if ((.reviews_due | length) > 0 or (.mentions_due | length) > 0)
          and ((.config.watch_rules // []) | length) > 0
       then ["docs/watches.md"] else [] end)
    + (if (.mentions_due | length) > 0 then ["docs/mentions.md"] else [] end)
    + (if (.ci_failures_due | length) > 0 then ["docs/ci-triage.md"] else [] end)
    + (if (.artifacts_due | length) > 0 then ["docs/artifact.md"] else [] end)
    + (if (.merges_due | length) > 0 then ["docs/auto-merge.md"] else [] end)
    + (if (.fixes_due | length) > 0 then ["docs/agent-fixes.md"] else [] end)
    + ["work/MEMORY.md", "work/LESSONS.md"]
  end;'

# =========================================================== REVIEW MODE ====
if [ "$MODE" = "review" ]; then
  REVIEWS_DUE='[]'; CLEANUPS_DUE='[]'; SELFHEALS_DUE='[]'; PRUNES_DUE='[]'; ARTIFACTS_DUE='[]'; ALERTS_DUE='[]'; MENTIONS_DUE='[]'; SKILLS='{}'
  CI_FAILURES_DUE='[]'
  STATUS_RESETS_DUE='[]'

  # an aborted or killed review leaves its clone behind, so reclaim before the
  # run rather than at the weekly audit (docs/logging.md → Retention)
  sweep_stale_clones >/dev/null

  # re-review trigger gate (docs/config.md -> rereview_trigger): label | review-request | both
  REREVIEW_TRIGGER="$(cfg rereview_trigger)"; REREVIEW_TRIGGER="${REREVIEW_TRIGGER:-label}"
  TRIG_LABEL=1; TRIG_REQUEST=0
  case "$REREVIEW_TRIGGER" in
    label) ;;
    review-request) TRIG_LABEL=0; TRIG_REQUEST=1;;
    both) TRIG_REQUEST=1;;
    *) log "rereview_trigger '$REREVIEW_TRIGGER' unknown — using label";;
  esac
  if [ "$TRIG_REQUEST" -eq 1 ] && [ -z "$BOT_LOGIN" ]; then
    TRIG_REQUEST=0; TRIG_LABEL=1
    log "bot_login missing — review-request trigger disabled this run (label-only)"
  fi
  TRIG_DESC="$REREVIEW_LABEL"
  [ "$TRIG_REQUEST" -eq 1 ] && TRIG_DESC="review request"
  [ "$TRIG_LABEL" -eq 1 ] && [ "$TRIG_REQUEST" -eq 1 ] && TRIG_DESC="$REREVIEW_LABEL or review request"

  add_review() { # number sha ref title author kind takeover prior_json urgent closed full desc
    # full: complete-review scope — always true for kind=first; on a re-review
    # true iff the label is the trigger (review-request / on-demand = delta)
    # desc: the trigger is answered by an edited PR body, not by new commits —
    # the diff is unchanged and the description is the new input
    REVIEWS_DUE="$(printf '%s' "$REVIEWS_DUE" | jq --argjson e "$(jq -n \
      --argjson n "$1" --arg sha "$2" --arg ref "$3" --arg t "$4" --arg a "$5" \
      --arg k "$6" --argjson tk "$7" --argjson prior "$8" \
      --argjson u "${9:-false}" --argjson c "${10:-false}" --argjson f "${11:-false}" \
      --argjson d "${12:-false}" \
      '{number:$n, head_sha:$sha, head_ref:$ref, title:$t, author:$a, kind:$k, takeover:$tk, prior:$prior, urgent:$u, closed:$c, full:$f, description_changed:$d}')" '. + [$e]')"
    [ "${9:-false}" = "true" ] && [ "${10:-false}" = "false" ] \
      && log "PR #$1: $URGENT_LABEL label — rapid-first review, ordered ahead"
    return 0
  }

  # --- prune detection (verified per PR; the agent executes the prune) ---
  # an empty open list is a true count (the list call fails the run on any
  # non-array answer), so drafts-only or no open PR still prunes
  PRUNE_STATES="$PF_TMP/prune-states.jsonl"; : > "$PRUNE_STATES"
  prune_states $(prune_candidates | grep -vxF -f <(open_numbers; echo '-') | sort -un) \
    > "$PRUNE_STATES"
  for n in $(prune_candidates); do
    if open_numbers | grep -qx "$n"; then
      # Open, but absent from the non-draft set = turned draft. A draft is never
      # reviewed, so a lock on it is abandoned work: the agent closes out its
      # progress status and deletes the row (self-dedup — no row, no reset).
      if [ "$PROGRESS" = "enabled" ] \
         && ! printf '%s' "$OPEN_NONDRAFT" | jq -e --argjson n "$n" 'any(.number == $n)' >/dev/null 2>&1; then
        row="$(row_for "$n")"
        if [ "$(row_field "$row" 6)" = "in_progress" ] \
           && [ $(( (NOW_EPOCH - $(iso2epoch "$(row_field "$row" 4)")) / 60 )) -ge "$LOCK_TTL_MIN" ]; then
          STATUS_RESETS_DUE="$(printf '%s' "$STATUS_RESETS_DUE" | jq --argjson e "$(jq -n \
            --argjson n "$n" --arg sha "$(row_field "$row" 3)" --arg r "draft" \
            '{number:$n, sha:$sha, reason:$r}')" '. + [$e]')"
          log "PR #$n: locked review abandoned (PR is now a draft) — progress status reset due"
        fi
      fi
      continue
    fi
    PJ="$(jq -c --argjson n "$n" 'select(.n == $n) | .pj' "$PRUNE_STATES" 2>/dev/null | head -1)"
    [ -n "$PJ" ] || PJ="$(gh api "repos/$REPO/pulls/$n" 2>/dev/null)"
    # a number with no pull request (a history file named for an issue): no
    # state to verify, no prune — the audit's orphan_history check reports it
    if printf '%s' "$PJ" | jq -e '.message? == "Not Found"' >/dev/null 2>&1; then
      log "PR #$n: no pull request with this number — prune skipped"; continue
    fi
    state="$(printf '%s' "$PJ" | jq -r 'if .merged then "MERGED" else (.state|ascii_upcase) end' 2>/dev/null)"
    [ -z "$state" ] && logev warn gh_api "PR #$n: state check did not respond — prune skipped this run"
    case "$state" in
      CLOSED|MERGED)
        row="$(row_for "$n")"
        if [ "$(row_field "$row" 5)" = "RAPID" ] && [ "$(row_field "$row" 6)" = "in_progress" ]; then
          # urgent PR closed after the rapid preliminary review but before the
          # full one — the agent still owes the full pass (criticals become a
          # linked issue, docs/review.md); prune happens on the next heartbeat
          kind="first"; rr_posted "$WORK/reviews/pr-$n.md" && kind="re-review"
          full=false; [ "$kind" = "first" ] && full=true
          prior="$(jq -n --arg sha "$(row_field "$row" 3)" --arg ts "$(row_field "$row" 4)" '{sha:$sha, ts:$ts, verdict:"RAPID"}')"
          add_review "$n" "$(printf '%s' "$PJ" | jq -r .head.sha)" "$(printf '%s' "$PJ" | jq -r .head.ref)" \
            "$(printf '%s' "$PJ" | jq -r '.title|gsub("\t";" ")')" "$(printf '%s' "$PJ" | jq -r .user.login)" \
            "$kind" false "$prior" true true "$full"
          log "PR #$n: $state with rapid review posted but full review owed — closed-PR review due"
        else
          did="$(grep -o '<!-- artifact-dam: [A-Za-z0-9_-]* -->' "$WORK/reviews/pr-$n.md" 2>/dev/null | head -1 | cut -d' ' -f3)"
          PRUNES_DUE="$(printf '%s' "$PRUNES_DUE" | jq --argjson e "$(jq -n --argjson n "$n" --arg s "$state" --arg d "${did:-}" \
            '{number:$n, state:$s, dam_id:(if $d=="" then null else $d end)}')" '. + [$e]')"
          log "PR #$n: $state — prune due"
        fi;;
      *) : ;;  # OPEN / API error -> leave the row alone
    esac
  done

  # --- per-open-PR decision ---
  while IFS=$'\t' read -r n sha ref title author labels assignees requested url; do
    has_label=0; [ "$TRIG_LABEL" -eq 1 ] && printf '%s' "$labels" | tr ',' '\n' | grep -qxF "$REREVIEW_LABEL" && has_label=1
    has_request=0; [ "$TRIG_REQUEST" -eq 1 ] && printf '%s' "$requested" | tr ',' '\n' | grep -qxF "$BOT_LOGIN" && has_request=1
    triggered=0; { [ "$has_label" -eq 1 ] || [ "$has_request" -eq 1 ]; } && triggered=1
    URG=false; [ -n "$URGENT_LABEL" ] && printf '%s' "$labels" | tr ',' '\n' | grep -qxF "$URGENT_LABEL" && URG=true

    # one-time urgent Slack alert (agent sends; marker in the history file is
    # the dedup — written by the agent right after the send, docs/review.md)
    if [ "$URG" = "true" ] && [ "$SLACK" = "enabled" ] \
       && ! grep -q '<!-- urgent-announced:' "$WORK/reviews/pr-$n.md" 2>/dev/null; then
      ALERTS_DUE="$(printf '%s' "$ALERTS_DUE" | jq --argjson e "$(jq -n --argjson n "$n" --arg t "$title" --arg a "$author" --arg u "$url" \
        '{number:$n, title:$t, author:$a, url:$u}')" '. + [$e]')"
      log "PR #$n: $URGENT_LABEL label found — Slack alert due"
    fi
    row="$(row_for "$n")"

    if [ -n "$row" ]; then
      row_sha="$(row_field "$row" 3)"; row_ts="$(row_field "$row" 4)"
      row_verdict="$(row_field "$row" 5)"; row_status="$(row_field "$row" 6)"
      prior="$(jq -n --arg sha "$row_sha" --arg ts "$row_ts" --arg v "$row_verdict" '{sha:$sha, ts:$ts, verdict:$v}')"

      if [ "$row_status" = "in_progress" ]; then
        age=$(( (NOW_EPOCH - $(iso2epoch "$row_ts")) / 60 ))
        if [ "$age" -lt "$LOCK_TTL_MIN" ]; then
          log "PR #$n: fresh in_progress lock (${age}m) — skipped"
        elif alive="$(holder_alive "$n" "$row_ts")" && [ -n "$alive" ]; then
          # Past the TTL but demonstrably still working: the holder finishes and
          # posts (fastest delivery, no work thrown away). Taking over here is
          # what destroys a complete fan-out. docs/review-mechanics.md → **Live holder**.
          log "PR #$n: lock past TTL (${age}m) but holder $alive — left running"
        else
          kind="first"; rr_posted "$WORK/reviews/pr-$n.md" && kind="re-review"
          full=false; { [ "$kind" = "first" ] || [ "$has_label" -eq 1 ]; } && full=true
          log "PR #$n: stale in_progress lock (${age}m, locked $row_ts) — takeover"
          add_review "$n" "$sha" "$ref" "$title" "$author" "$kind" true "$prior" "$URG" false "$full"
        fi
      elif [ "$row_sha" = "$sha" ]; then
        # Reviewed at live HEAD. A trigger here is not automatically stale: a PR
        # body can be corrected without a new commit, and the body is a review
        # input (docs/review.md -> PR context), so an edit after the recorded
        # review IS something new to review. One GraphQL call, and only in this
        # branch — the case that would otherwise do nothing at all.
        if [ "$triggered" -eq 1 ]; then
          trig=""
          [ "$has_label" -eq 1 ] && trig="$REREVIEW_LABEL"
          [ "$has_request" -eq 1 ] && trig="${trig:+$trig + }review request"
          body_edited="$(gh api graphql -F n="$n" -f o="${REPO%%/*}" -f r="${REPO#*/}" -f query='
              query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){
                pullRequest(number:$n){lastEditedAt}}}' 2>/dev/null \
            | jq -r '.data.repository.pullRequest.lastEditedAt // empty' 2>/dev/null)"
          if [ -n "$body_edited" ] && [ "$(iso2epoch "$body_edited")" -gt "$(iso2epoch "$row_ts")" ]; then
            add_review "$n" "$sha" "$ref" "$title" "$author" "re-review" false "$prior" "$URG" false \
              "$([ "$has_label" -eq 1 ] && echo true || echo false)" true
            log "PR #$n: $trig present, no new commits since ${row_sha:0:7} but the description was edited $body_edited — re-review due"
          else
            CLEANUPS_DUE="$(printf '%s' "$CLEANUPS_DUE" | jq --argjson e "$(jq -n --argjson n "$n" \
              --argjson l "$([ "$has_label" -eq 1 ] && echo true || echo false)" \
              --argjson r "$([ "$has_request" -eq 1 ] && echo true || echo false)" \
              '{number:$n, label:$l, request:$r}')" '. + [$e]')"
            log "PR #$n: $trig present but nothing new since ${row_sha:0:7} (no commits, no description edit) — trigger cleanup due"
          fi
        fi
        # CI triage: the review is posted, so a failing check on the reviewed
        # SHA is news the agent can explain. The rollup is read only inside the
        # window and only until the marker exists, which bounds it to the few
        # PRs reviewed in the last day (docs/ci-triage.md).
        if [ "$CI_TRIAGE" = "enabled" ] && [ "$row_status" = "done" ] \
           && ! grep -qF "<!-- ci-triage: $sha -->" "$WORK/reviews/pr-$n.md" 2>/dev/null \
           && [ $(( (NOW_EPOCH - $(iso2epoch "$row_ts")) / 3600 )) -lt "$CI_TRIAGE_WINDOW_H" ]; then
          ci_runs_json="$(ci_runs "$REPO" "$sha")"
          ci_fail_json="$(ci_failing "$ci_runs_json")"
          if ci_terminal "$ci_runs_json" && [ "$(printf '%s' "$ci_fail_json" | jq 'length')" -gt 0 ]; then
            CI_FAILURES_DUE="$(printf '%s' "$CI_FAILURES_DUE" | jq --argjson e "$(jq -n \
              --argjson n "$n" --arg sha "$sha" --arg u "$url" \
              --argjson c "$(printf '%s' "$ci_fail_json" | jq -c '[.[].name]')" \
              '{number:$n, sha:$sha, url:$u, checks:$c}')" '. + [$e]')"
            log "PR #$n: CI failed at ${sha:0:7} ($(printf '%s' "$ci_fail_json" | jq -r '[.[].name] | join(", ")')) — triage due"
          fi
        fi
      else
        # new commits since the recorded review
        if [ "$triggered" -eq 1 ]; then
          add_review "$n" "$sha" "$ref" "$title" "$author" "re-review" false "$prior" "$URG" false \
            "$([ "$has_label" -eq 1 ] && echo true || echo false)"
        elif [ "$row_status" = "done" ]; then
          flip_awaiting_label "$n"
          log "PR #$n: new commits since last review — awaiting $TRIG_DESC"
        fi   # already awaiting_label -> stay silent
      fi
    else
      # no local row: anchored remote check first, then the unanchored one.
      # __api_error__ defers the PR to the next heartbeat — the scan failed,
      # not the marker, and a blind add_review here would schedule a review
      # the remote may already carry.
      if [ "$API_ERRS" -ge 2 ]; then ts="__api_error__"; else ts="$(remote_reviewed_at "$n" "$sha")"; fi
      if [ "$ts" = "__api_error__" ]; then
        API_ERRS=$((API_ERRS+1))
        log_warn "PR #$n: marker scan unavailable (API errors) — review decision deferred to the next heartbeat"
      elif [ -n "$ts" ]; then
        SELFHEALS_DUE="$(printf '%s' "$SELFHEALS_DUE" | jq --argjson e "$(jq -n --argjson n "$n" --arg sha "$sha" --arg ts "$ts" \
          '{number:$n, sha:$sha, ts:$ts, status:"done"}')" '. + [$e]')"
        log "PR #$n: remote marker found at live HEAD — self-heal due"
      else
        if [ "$API_ERRS" -ge 2 ]; then any="__api_error__"; else any="$(remote_reviewed_any "$n")"; fi
        if [ "$any" = "__api_error__" ]; then
          API_ERRS=$((API_ERRS+1))
          log_warn "PR #$n: marker scan unavailable (API errors) — review decision deferred to the next heartbeat"
        elif [ -n "$any" ]; then
          asha="${any%%$'\t'*}"; ats="${any##*$'\t'}"
          if [ "$triggered" -eq 1 ]; then
            add_review "$n" "$sha" "$ref" "$title" "$author" "re-review" false \
              "$(jq -n --arg sha "$asha" --arg ts "$ats" '{sha:$sha, ts:$ts, verdict:"SEE-GITHUB"}')" "$URG" false \
              "$([ "$has_label" -eq 1 ] && echo true || echo false)"
          else
            SELFHEALS_DUE="$(printf '%s' "$SELFHEALS_DUE" | jq --argjson e "$(jq -n --argjson n "$n" --arg sha "$asha" --arg ts "$ats" \
              '{number:$n, sha:$sha, ts:$ts, status:"awaiting_label"}')" '. + [$e]')"
            log "PR #$n: reviewed on GitHub at ${asha:0:7} (no local row), new commits with no re-review trigger — self-heal to awaiting_label due"
          fi
        else
          add_review "$n" "$sha" "$ref" "$title" "$author" "first" false null "$URG" false true
        fi
      fi
    fi

    # artifact assignee gate (independent of the review decision)
    if [ -n "$ARTIFACT_SKILL" ] && [ -n "$BOT_LOGIN" ] && printf '%s' "$assignees" | tr ',' '\n' | grep -qxF "$BOT_LOGIN"; then
      action="generate"
      if grep -q '<!-- artifact-dam:' "$WORK/reviews/pr-$n.md" 2>/dev/null; then action="retry_unassign"
      else
        # a session without the DAM tools recorded when it tried (docs/artifact.md
        # step 0): the next attempt waits ARTIFACT_RETRY_H, not one heartbeat
        skip_ts="$(sed -n 's/^<!-- artifact-skip: dam-unavailable \([0-9TZ:-]*\) -->$/\1/p' "$WORK/reviews/pr-$n.md" 2>/dev/null | tail -1)"
        [ -n "$skip_ts" ] && [ $(( NOW_EPOCH - $(iso2epoch "$skip_ts") )) -lt $(( ARTIFACT_RETRY_H * 3600 )) ] && action=""
      fi
      if [ -n "$action" ]; then
        ARTIFACTS_DUE="$(printf '%s' "$ARTIFACTS_DUE" | jq --argjson e "$(jq -n --argjson n "$n" --arg a "$action" \
          '{number:$n, action:$a}')" '. + [$e]')"
        log "PR #$n: artifact $action due"
      fi
    fi
  done < <(printf '%s' "$OPEN_NONDRAFT" | jq -r '.[] | [.number, .head_sha, .head_ref, (.title|gsub("\t";" ")), .author,
             ((.labels|join(","))|if .=="" then "-" else . end),
             ((.assignees|join(","))|if .=="" then "-" else . end),
             ((.requested|join(","))|if .=="" then "-" else . end), .url] | @tsv')

  # urgent entries first (stable sort — non-urgent keep their order)
  REVIEWS_DUE="$(printf '%s' "$REVIEWS_DUE" | jq 'sort_by(if .urgent then 0 else 1 end)')"
  # a PR another run holds costs nothing below (docs/worklist.md → PR holds)
  apply_holds reviews

  # ------------------------------------------------- progress-signal ETA ----
  # `eta_seconds` per due review: the median wall-clock of recent completed
  # reviews, paired per (run, PR) from the `locked`/`done` review_step events
  # (docs/review-bookkeeping.md → Progress signal on GitHub). Local files only, one jq
  # process, and only when a review is due — idle heartbeats pay nothing.
  if [ "$PROGRESS" = "enabled" ] && [ "$(printf '%s' "$REVIEWS_DUE" | jq length)" -gt 0 ]; then
    ETA_FILES=()
    while IFS= read -r f; do [ -f "$f" ] && ETA_FILES+=("$f"); done \
      < <(ls -1 "$LOG_DIR"/events-*.jsonl 2>/dev/null | sort | tail -7)
    ETA=null
    if [ "${#ETA_FILES[@]}" -gt 0 ]; then
      ETA="$(jq -R -n "$STATS_JQ"'
        [ inputs | fromjson? // empty ] | review_steps("")
        | group_by([.run, .pr])
        | map( ([ .[] | select(.rest == "locked") | .ts | epoch ] | min) as $a
             | ([ .[] | select(.rest == "done")   | .ts | epoch ] | max) as $b
             | if $a == null or $b == null or $b <= $a then empty
               else {end: $b, d: ($b - $a)} end )
        | sort_by(.end) | .[-20:] | map(.d) | median(floor)' "${ETA_FILES[@]}" 2>/dev/null)"
      [ -n "$ETA" ] || ETA=null
    fi
    REVIEWS_DUE="$(printf '%s' "$REVIEWS_DUE" | jq --argjson eta "$ETA" 'map(. + {eta_seconds: $eta})')"
  fi

  # install skills only when the agent will actually review / generate
  if [ "$(printf '%s' "$REVIEWS_DUE" | jq length)" -gt 0 ] \
     || [ "$(printf '%s' "$ARTIFACTS_DUE" | jq '[.[] | select(.action=="generate")] | length')" -gt 0 ]; then
    # git credential helper for every authenticated host, before the agent clones.
    # stdout goes to /dev/null like every other command here: this script's own
    # stdout IS the worklist, and a second document on it breaks the gate.
    gh auth setup-git >/dev/null 2>&1 || log_warn "gh auth setup-git did not succeed — clones may fail to authenticate"
    # The profile check, the changed-file lists and the skill installs are
    # independent reads: they run side by side, and their answers are collected
    # below in the order the sequential version produced them.
    if [ "$(printf '%s' "$REVIEWS_DUE" | jq length)" -gt 0 ]; then
      [ "$PROJECT_PROFILE" = "enabled" ] \
        && { LOG_JOB=review bash "$SCRIPT_DIR/profile.sh" check > "$PF_TMP/profile-status" 2>/dev/null & PROFILE_PID=$!; }
      prefetch_files $(printf '%s' "$REVIEWS_DUE" | jq -r '.[].number') & FILES_PID=$!
    fi
    # a skill listed twice keeps its first position and its last source — the
    # key order and the installed files of back-to-back installs
    SK_NAMES=(); SK_SRCS=()
    sk_add() { # <name> <src>
      local i=0
      while [ "$i" -lt "${#SK_NAMES[@]}" ]; do
        [ "${SK_NAMES[i]}" = "$1" ] && { SK_SRCS[i]="$2"; return; }
        i=$((i+1))
      done
      SK_NAMES+=("$1"); SK_SRCS+=("$2")
    }
    while IFS=$'\t' read -r skill src; do
      sk_add "$skill" "$src"
    done < <(printf '%s' "$SKILLS_TABLE" | jq -r '.[] | [.skill, .source] | @tsv')
    if [ -n "$ARTIFACT_SKILL" ] && [ "$(printf '%s' "$ARTIFACTS_DUE" | jq '[.[] | select(.action=="generate")] | length')" -gt 0 ]; then
      sk_add "$ARTIFACT_SKILL" "$ARTIFACT_SRC"
    fi
    SK_PIDS=(); sk_i=0
    while [ "$sk_i" -lt "${#SK_NAMES[@]}" ]; do
      install_skill "${SK_NAMES[sk_i]}" "${SK_SRCS[sk_i]}" > "$PF_TMP/skill-$sk_i" & SK_PIDS+=($!)
      sk_i=$((sk_i+1))
    done
    sk_i=0
    while [ "$sk_i" -lt "${#SK_NAMES[@]}" ]; do
      wait "${SK_PIDS[sk_i]}"
      # scratch unwritable -> the side-by-side install left no answer: install here
      if [ -f "$PF_TMP/skill-$sk_i" ]; then sk_v="$(cat "$PF_TMP/skill-$sk_i")"
      else sk_v="$(install_skill "${SK_NAMES[sk_i]}" "${SK_SRCS[sk_i]}")"; fi
      SKILLS="$(printf '%s' "$SKILLS" | jq --arg k "${SK_NAMES[sk_i]}" --arg v "$sk_v" '. + {($k):$v}')"
      sk_i=$((sk_i+1))
    done
  fi

  # -------------------------------- project profile & per-PR inventory ----
  # Only when a review is due (docs/profile.md): keep the profile current, then
  # give every due entry its changed-file inventory (classified), the profile
  # rows it touches, its history rows, the area-memory files whose scope
  # matches, and the skill routing — deterministic orientation, so neither the
  # agent nor a skill subagent rebuilds the repository map per PR. One API call
  # per due PR (the file list); the slice is local. A failed list leaves
  # `files: null` and the agent builds the list from the diff as before.
  if [ "$(printf '%s' "$REVIEWS_DUE" | jq length)" -gt 0 ]; then
    if [ "$PROJECT_PROFILE" = "enabled" ]; then
      [ -n "${PROFILE_PID:-}" ] && wait "$PROFILE_PID"
      if [ -f "$PF_TMP/profile-status" ]; then PROFILE_JSON_OUT="$(cat "$PF_TMP/profile-status")"
      else PROFILE_JSON_OUT="$(LOG_JOB=review bash "$SCRIPT_DIR/profile.sh" check 2>/dev/null)"; fi
      { printf '%s' "$PROFILE_JSON_OUT" | jq -e 'has("status")' >/dev/null 2>&1; } \
        || PROFILE_JSON_OUT='{"status":"unavailable","mode":"none","note":"profile.sh produced no status"}'
      log "project profile: $(printf '%s' "$PROFILE_JSON_OUT" | jq -r '
        "\(.status) (\(.mode)\(if .base then ", base " + .base else "" end)\(if .age_hours != null then ", \(.age_hours)h old" else "" end))\(if .note then " — " + .note else "" end)"')"
    else
      PROFILE_JSON_OUT='{"status":"disabled","mode":"none"}'
    fi
    [ "$(printf '%s' "$MEMORY_JSON" | jq -r '.over_budget')" = "true" ] \
      && log "memory over budget: $(printf '%s' "$MEMORY_JSON" | jq -r '"MEMORY.md \(.memory_lines)/\(.memory_limit) lines, \(.long_lines) past \(.line_limit) chars, insights \(.insights)/\(.insights_limit), feedback \(.feedback)/\(.feedback_limit), LESSONS.md \(.lessons_sections)/\(.lessons_limit) sections, \(.lessons_lines)/\(.lessons_lines_limit) lines, area files over bound \(.area_over | length), without scope \(.area_unscoped | length)"') — consolidation due at the next audit (docs/preferences.md)"
    [ -n "${FILES_PID:-}" ] && wait "$FILES_PID"
    FILES_TMP="$(mktemp "${TMPDIR:-/tmp}/cg-files.XXXXXX")"
    NEW_DUE='[]'
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      n="$(printf '%s' "$entry" | jq -r '.number')"
      # the call's own output first: a failed or empty answer must never read
      # as "no files" (`jq -s` turns empty input into `[]`)
      if [ -f "$PF_TMP/files-$n" ]; then raw="$(cat "$PF_TMP/files-$n")"
      else raw="$(gh api --paginate "repos/$REPO/pulls/$n/files?per_page=100" 2>/dev/null)" || raw=""; fi
      [ -n "$raw" ] && raw="$(printf '%s' "$raw" | jq -s 'map(select(type=="array")) | add // []' 2>/dev/null)"
      if [ -z "$raw" ]; then
        log_warn "PR #$n: changed-file list unavailable — build it from the diff"
        entry="$(printf '%s' "$entry" | jq -c '. + {files:null}')"
      else
        trunc=false; [ "$(printf '%s' "$raw" | jq length)" -gt 1000 ] && trunc=true
        printf '%s' "$raw" | jq -c '.[:1000] | map({path:.filename, status:.status})' > "$FILES_TMP"
        slice="$(LOG_JOB=review bash "$SCRIPT_DIR/profile.sh" slice "$FILES_TMP" 2>/dev/null)"
        # the default below has the shape of a real slice, so a run that falls
        # back to it looks exactly like a repository with nothing to say: log it
        if ! printf '%s' "$slice" | jq -e 'has("files")' >/dev/null 2>&1; then
          log_warn "PR #$n: the profile slice did not build — this review gets the file list alone (docs/profile.md)"
          slice="$(jq -c '{files:(map(. + {class:"code"})), noise_count:0, profile_slice:[], structure_changed:[], history_slice:[], memory_due:[]}' "$FILES_TMP")"
        fi
        # extension routing per docs/skills.md — inclusive: every skill whose
        # trigger list holds the file's extension receives it; `always` skills
        # route nothing (they run on the whole clone); noise classes and
        # deleted files route nowhere
        routing="$(printf '%s' "$slice" | jq -c --argjson t "$SKILLS_TABLE" '
          [ $t[] | select(.trigger != "always")
            | {skill, exts: (.trigger | split(",") | map(gsub("\\s";"") | select(length>0)))} ] as $rows
          | [ .files[]? | select((.class | IN("code","test","docs","config")) and .status != "removed") | .path ] as $paths
          | reduce $rows[] as $r ({}; .[$r.skill] = [ $paths[] | select(
              (split("/") | last | if contains(".") then "." + (split(".") | last) else "" end) as $ext
              | $r.exts | index($ext) != null) ])')"
        entry="$(printf '%s' "$entry" | jq -c --argjson s "$slice" --argjson r "$routing" --argjson tr "$trunc" \
          '. + $s + {files_truncated:$tr, skill_routing:$r}')"
        [ "$trunc" = "true" ] && log "PR #$n: changed-file list capped at 1000 — build the full list from the diff"
      fi
      NEW_DUE="$(printf '%s' "$NEW_DUE" | jq -c --argjson e "$entry" '. + [$e]')"
    done < <(printf '%s' "$REVIEWS_DUE" | jq -c '.[]')
    REVIEWS_DUE="$NEW_DUE"; rm -f "$FILES_TMP"
  fi

  # --------------------------------------------------- mention detection ----
  # Human comments addressed to the bot: an @-mention anywhere in the repo's
  # PR/issue comments, or a reply inside an inline review thread rooted by a
  # bot comment. Repo-wide scan, 7-day window (2 GET calls, day-rounded so the
  # window is cache/test-stable, newest-first so the page cap drops the oldest);
  # work/MENTIONS.md rows are the dedup — the agent appends a row before acting
  # (docs/mentions.md).
  MENTION_REPLIES="$(cfg mention_replies)"; MENTION_REPLIES="${MENTION_REPLIES:-enabled}"
  if [ "$MENTION_REPLIES" = "enabled" ] && [ -z "$BOT_LOGIN" ]; then
    log "bot_login missing — mention handling disabled this run"
    MENTION_REPLIES="disabled"
  fi
  # whose mentions are handled (docs/config.md → mention_authors): the comment's
  # author_association against the set; any other value is the default
  MENTION_AUTHORS="$(cfg mention_authors)"
  [ "$MENTION_AUTHORS" = "anyone" ] || MENTION_AUTHORS="collaborators"
  if [ "$MENTION_REPLIES" = "enabled" ]; then
    MSINCE="$(epoch2iso "$((NOW_EPOCH - 7*86400))" '%Y-%m-%d')T00:00:00Z"
    mention_seen() { grep -qE "^\| *$1 *\|" "$WORK/MENTIONS.md" 2>/dev/null; }
    # newest-first: on a busy repo the window holds more than one page, and the
    # cap must drop the oldest comments (already answered, or aged out) rather
    # than the newest ones — ascending order starves fresh mentions forever.
    # One page holds 100 comments. A busy week overflows it, so follow the next
    # page while the last one came back full, up to MENTION_PAGES. The bound is
    # the cost guard: a quiet repo still pays 2 calls, a busy one at most
    # 2 x MENTION_PAGES, and the newest-first order keeps the cap dropping the
    # oldest comments rather than the fresh ones.
    # The pages accumulate in a file as JSONL, never in a shell variable: a
    # single argv entry is capped at 128 KiB (MAX_ARG_STRLEN, independent of
    # ARG_MAX), and one page of comment bodies clears that on its own, so
    # `--argjson` on the merged array dies with "Argument list too long" and
    # the scan silently degrades to zero mentions.
    # A first page that does not answer leaves the surface empty, which reads as
    # a quiet week; it comes back as -1 and the caller logs it.
    mention_pages() { # <endpoint> <outfile> -> comment count, newest first; -1 = no answer
      local ep="$1" out="$2" page=1 body n total=0
      : > "$out"
      while [ "$page" -le "$MENTION_PAGES" ]; do
        body="$(gh api "repos/$REPO/$ep?since=$MSINCE&per_page=100&sort=created&direction=desc&page=$page" 2>/dev/null)"
        if ! printf '%s' "$body" | jq -e 'type=="array"' >/dev/null 2>&1; then
          [ "$page" -eq 1 ] && total=-1
          break
        fi
        n="$(printf '%s' "$body" | jq length)"
        printf '%s' "$body" | jq -c '.[]' >> "$out" || break
        total=$((total + n))
        [ "$n" -eq 100 ] || break
        page=$((page + 1))
      done
      printf '%s' "$total"
    }
    IC_TMP="$(mktemp "${TMPDIR:-/tmp}/cg-mentions-ic.XXXXXX")"
    RC_TMP="$(mktemp "${TMPDIR:-/tmp}/cg-mentions-rc.XXXXXX")"
    # the two surfaces are independent: read them side by side
    mention_pages "issues/comments" "$IC_TMP" > "$PF_TMP/mentions-ic-count" & IC_PID=$!
    RC_N="$(mention_pages "pulls/comments" "$RC_TMP")"
    wait "$IC_PID"
    if [ -f "$PF_TMP/mentions-ic-count" ]; then IC_N="$(cat "$PF_TMP/mentions-ic-count")"
    else IC_N="$(mention_pages "issues/comments" "$IC_TMP")"; fi
    if [ "${IC_N:-0}" -lt 0 ]; then
      log_warn "mention scan: the issue-comment surface did not answer — conversation mentions are not scanned this run"
      IC_N=0
    fi
    if [ "${RC_N:-0}" -lt 0 ]; then
      log_warn "mention scan: the review-comment surface did not answer — inline mentions are not scanned this run"
      RC_N=0
    fi
    # every page full to the bound means the window still holds more; `log` from
    # inside the paging subshell would be lost with it, so say it out here.
    # The line names how far back the scan reached — the oldest created_at it
    # read — because "full" alone says nothing about how wide the scanned span is
    scan_floor() { jq -rs 'map(.created_at // empty) | min // "unknown"' "$1" 2>/dev/null || printf unknown; }
    [ "${IC_N:-0}" -ge "$((MENTION_PAGES * 100))" ] \
      && log "mention scan: issue comments still full after $MENTION_PAGES pages — scanned the newest $((MENTION_PAGES * 100)), back to $(scan_floor "$IC_TMP"); older comments in the window are not scanned"
    [ "${RC_N:-0}" -ge "$((MENTION_PAGES * 100))" ] \
      && log "mention scan: review comments still full after $MENTION_PAGES pages — scanned the newest $((MENTION_PAGES * 100)), back to $(scan_floor "$RC_TMP"); older comments in the window are not scanned"
    MRE="@${BOT_LOGIN}([^A-Za-z0-9-]|\$)"
    CAND_TMP="$(mktemp "${TMPDIR:-/tmp}/cg-mentions-cand.XXXXXX")"
    jq -nc --slurpfile ic "$IC_TMP" --slurpfile rc "$RC_TMP" --arg re "$MRE" --arg bot "$BOT_LOGIN" --arg ma "$MENTION_AUTHORS" '
      def admitted: ($ma == "anyone") or ((.author_association // "") | IN("OWNER", "MEMBER", "COLLABORATOR"));
      [ $ic[] | select((.user.login // "") != $bot and ((.user.type // "User") != "Bot"))
              | select((.body // "") | test($re))
              | {comment_id: .id, thread: "conversation",
                 number: (.issue_url | capture("/(?<n>[0-9]+)$").n | tonumber),
                 author: (.user.login // "ghost"), created_at,
                 body: ((.body // "") | .[0:1500]), url: .html_url,
                 in_reply_to: null, mentioned: true, admitted: admitted} ]
      + [ $rc[] | select((.user.login // "") != $bot and ((.user.type // "User") != "Bot"))
                | select(((.body // "") | test($re)) or (.in_reply_to_id != null))
                | {comment_id: .id, thread: "inline",
                   number: (.pull_request_url | capture("/(?<n>[0-9]+)$").n | tonumber),
                   author: (.user.login // "ghost"), created_at,
                   body: ((.body // "") | .[0:1500]), url: .html_url,
                   in_reply_to: .in_reply_to_id,
                   mentioned: ((.body // "") | test($re)), admitted: admitted} ]
      | .[]' 2>/dev/null > "$CAND_TMP"
    # PR descriptions: an @-mention in the body of any open PR (drafts
    # included; zero extra API calls — the open-PR list already carries the
    # bodies). One handling per PR: ledger key "body-<n>".
    # Appended as JSONL to the same file, for the same argv reason as the pages:
    # a busy window's candidate set is itself well past 128 KiB.
    printf '%s' "$OPEN_JSON" | jq -c --arg re "$MRE" --arg bot "$BOT_LOGIN" --arg ma "$MENTION_AUTHORS" '
      .[] | select(((.user.login // "") != $bot) and ((.user.type // "User") != "Bot"))
          | select((.body // "") | test($re))
          | {comment_id: ("body-" + (.number|tostring)), thread: "body",
             number, author: (.user.login // "ghost"), created_at,
             body: ((.body // "") | .[0:1500]), url: .html_url,
             in_reply_to: null,
             admitted: (($ma == "anyone") or ((.author_association // "") | IN("OWNER", "MEMBER", "COLLABORATOR")))}' 2>/dev/null >> "$CAND_TMP"
    CAND="$(jq -sc 'sort_by(.created_at)' "$CAND_TMP" 2>/dev/null)"
    # an empty candidate set is also what a quiet week produces, so the failure
    # that makes one must be said out loud
    if ! printf '%s' "$CAND" | jq -e 'type=="array"' >/dev/null 2>&1; then
      log_warn "mention scan: the candidate set did not parse — no mention is handled this run"
      CAND='[]'
    fi
    # author_association reads a private organization member as CONTRIBUTOR or
    # NONE when the token cannot see the membership (the default visibility),
    # so an author it leaves out gets one permission GET per run: triage or
    # more admits; read admits on a private repository only
    ACCESS_CACHE="|"; REPO_PRIVATE=""
    mention_author_has_access() { # <login>
      case "$ACCESS_CACHE" in *"|$1=y|"*) return 0;; *"|$1=n|"*) return 1;; esac
      local p r=n
      p="$(gh api "repos/$REPO/collaborators/$1/permission" 2>/dev/null \
           | jq -r '.role_name // .permission // empty' 2>/dev/null)"
      case "$p" in
        admin|maintain|write|triage) r=y;;
        read)
          [ -n "$REPO_PRIVATE" ] || REPO_PRIVATE="$(gh api "repos/$REPO" 2>/dev/null | jq -r '.private // false' 2>/dev/null)"
          [ "$REPO_PRIVATE" = "true" ] && r=y;;
      esac
      ACCESS_CACHE="$ACCESS_CACHE$1=$r|"
      [ "$r" = y ]
    }
    left_out=0
    while IFS= read -r c; do
      [ -z "$c" ] && continue
      cid="$(printf '%s' "$c" | jq -r '.comment_id')"
      mention_seen "$cid" && continue
      # a reply without an @-mention is relevant only when the thread root is
      # the bot's inline comment (root in the same batch, else one GET)
      if [ "$(printf '%s' "$c" | jq -r '.thread + " " + (.mentioned|tostring)')" = "inline false" ]; then
        root="$(printf '%s' "$c" | jq -r '.in_reply_to')"
        root_author="$(jq -r --argjson r "$root" 'select(.id == $r) | .user.login' "$RC_TMP" 2>/dev/null | head -1)"
        [ -z "$root_author" ] && root_author="$(gh api "repos/$REPO/pulls/comments/$root" 2>/dev/null | jq -r '.user.login // empty')"
        [ "$root_author" = "$BOT_LOGIN" ] || continue
      fi
      # an author outside mention_authors is counted, never emitted
      if [ "$(printf '%s' "$c" | jq -r '.admitted')" != "true" ] \
         && ! mention_author_has_access "$(printf '%s' "$c" | jq -r '.author')"; then
        left_out=$((left_out + 1)); continue
      fi
      MENTIONS_DUE="$(printf '%s' "$MENTIONS_DUE" | jq --argjson e "$(printf '%s' "$c" | jq 'del(.mentioned, .admitted)')" '. + [$e]')"
      log "#$(printf '%s' "$c" | jq -r '.number'): mention $cid by $(printf '%s' "$c" | jq -r '.author') — handling due"
    done < <(printf '%s' "$CAND" | jq -c '.[]')
    if [ "$left_out" -gt 0 ]; then
      log "mention scan: $left_out mention(s) by accounts outside mention_authors ($MENTION_AUTHORS) left out"
    fi
    # after the loop: the inline root-author lookup reads the review-comment batch
    rm -f "$IC_TMP" "$RC_TMP" "$CAND_TMP"
  fi

  # ------------------------------------------- stalled-review rate alert ----
  # A review that locked a PR and died before posting is invisible per-run: the
  # lock's TTL hands the PR to the next heartbeat, which may repeat it.
  # One stall is normal (HEAD moved, pod restart); a cluster is pathological, so
  # count the last 24h of `stale in_progress lock` takeovers across the event
  # log and emit ONE alert per UTC day when the threshold is reached.
  # A stall is one dead lock: every heartbeat that meets the same lock logs the
  # takeover again, so events count once per (PR, lock time) — a line without
  # `locked <ts>` (written before 8.2.1) once per PR, and not at all next to a
  # line of that PR that names its lock.
  # Cheap by construction: the retained log files, no API calls, no extra run.
  if [ "$STALL_ALERT_THRESHOLD" -gt 0 ]; then
    STALL_SINCE="$(( NOW_EPOCH - 86400 ))"
    STALL_SINCE_ISO="$(epoch2iso "$STALL_SINCE")"
    STALL_EVENTS="$(events_jsonl | jq -sc "[ .[] | try ($STALL_SEL) ]" 2>/dev/null)"
    [ -n "$STALL_EVENTS" ] || STALL_EVENTS='[]'
    # the window: one scope, so an unkeyed line is one stall per PR
    STALL_WIN="$(printf '%s' "$STALL_EVENTS" | jq -c --arg s "$STALL_SINCE_ISO" \
      "$STALL_DEFS"' map(select(.ts >= $s)) | stalls("")')"
    STALL_N="$(printf '%s' "$STALL_WIN" | jq length)"; STALL_N="${STALL_N:-0}"
    STALL_PRS="$(printf '%s' "$STALL_WIN" | jq -r '[.[].pr] | unique | map(tostring) | join(" ")')"
    # per-UTC-day counts over the retained log window — turns "22 today" into a
    # trend the operator can read (is this new, or every day?). A stall counts
    # on the day of its first line, an unkeyed line once per PR and day
    STALL_WEEK="$(printf '%s' "$STALL_EVENTS" | jq -c "$STALL_DEFS"' stalls(.[0:10])
      | group_by(.ts[0:10]) | map({day: .[0].ts[0:10], stalls: length}) | sort_by(.day) | .[-7:]')"
    [ -n "$STALL_WEEK" ] || STALL_WEEK='[]'
    # dedup: the marker records the last UTC day an alert was emitted. Claimed
    # with mkdir (atomic on the shared volume) so two concurrent heartbeats
    # can't both alert; the day file inside it is what's compared.
    STALL_MARKER="$WORK/.stall-alert-day"
    STALL_TODAY="$(date -u +%Y-%m-%d)"
    # a claim lock left by a run killed mid-section would suppress every future
    # alert — the section is a few local commands, so older than 5 minutes is
    # stale; rmdir only (nothing is ever created inside the dir)
    find "$WORK/.stall-alert.lock" -maxdepth 0 -mmin +5 -exec rmdir {} \; 2>/dev/null || true
    if [ "$STALL_N" -ge "$STALL_ALERT_THRESHOLD" ] \
       && [ "$(cat "$STALL_MARKER" 2>/dev/null)" != "$STALL_TODAY" ] \
       && mkdir "$WORK/.stall-alert.lock" 2>/dev/null; then
      # re-read under the lock: a racing run may have just written today's day
      if [ "$(cat "$STALL_MARKER" 2>/dev/null)" != "$STALL_TODAY" ]; then
        printf '%s\n' "$STALL_TODAY" > "$STALL_MARKER" 2>/dev/null
        STALL_ALERT="$(jq -n --argjson count "$STALL_N" \
          --argjson threshold "$STALL_ALERT_THRESHOLD" \
          --argjson week "$STALL_WEEK" \
          --argjson prs "$(printf '%s' "$STALL_PRS" | tr ' ' '\n' | jq -R . | jq -s '[.[] | select(length>0) | tonumber]')" \
          '{count:$count, threshold:$threshold, prs:$prs, window_hours:24, per_day_7d:$week}')"
        log "stalled reviews: $STALL_N in the last 24h (threshold $STALL_ALERT_THRESHOLD) on PR(s) $STALL_PRS — alert due"
        logev warn stall_rate "$STALL_N stalled review(s) in 24h (threshold $STALL_ALERT_THRESHOLD) on PR(s) $STALL_PRS"
      fi
      rmdir "$WORK/.stall-alert.lock" 2>/dev/null
    fi
  fi

  # ---------------------------------------------------------- auto-merge ----
  # docs/auto-merge.md: a PR a person labeled, that my review of its head
  # approved and called a quick check, merges once every gate holds. Only
  # labeled PRs pay the detail, files and rollup reads.
  AUTO_MERGE="$(cfg auto_merge)"; AUTO_MERGE="${AUTO_MERGE:-disabled}"
  case "$AUTO_MERGE" in
    (enabled|disabled) ;;
    (*) log "auto_merge '$AUTO_MERGE' unknown — treating as disabled"; AUTO_MERGE=disabled;;
  esac
  AM_LABEL="$(cfg auto_merge_label)"
  AM_MAX="$(cfg auto_merge_max_lines)"; case "$AM_MAX" in (''|*[!0-9]*) AM_MAX=100;; esac
  AM_METHOD="$(cfg auto_merge_method)"
  case "$AM_METHOD" in (merge|squash|rebase) ;; ('') AM_METHOD=squash;; (*) log "auto_merge_method '$AM_METHOD' unknown — using squash"; AM_METHOD=squash;; esac
  if [ "$AUTO_MERGE" = "enabled" ] && [ -z "$AM_LABEL" ]; then
    log_warn "auto_merge is enabled without auto_merge_label — auto-merge is off this run"; AUTO_MERGE=disabled
  fi
  if [ "$AUTO_MERGE" = "enabled" ] && [ "$CI_LIB" -eq 0 ]; then
    log_warn "lib/ci-rollup.sh unreadable — auto-merge is off this run"; AUTO_MERGE=disabled
  fi
  AM_HUMAN_PATHS="$(cfg human_review_paths | tr -d '`')"
  # the first gate that fails, as a log reason; nothing when every gate holds
  am_block() { # <pr-number> <head-sha>
    local n="$1" sha="$2" row sec meta det files f ci_json
    grep -qF "<!-- auto-merge-failed: $sha -->" "$WORK/reviews/pr-$n.md" 2>/dev/null \
      && { printf 'a merge of this head already failed'; return; }
    # a person reviews a fix of mine (docs/agent-fixes.md)
    grep -qF "<!-- agent-fix-pushed: " "$WORK/reviews/pr-$n.md" 2>/dev/null \
      && { printf 'the PR carries a fix of mine'; return; }
    row="$(row_for "$n")"
    { [ "$(row_field "$row" 3)" = "$sha" ] && [ "$(row_field "$row" 5)" = "APPROVE" ] \
      && [ "$(row_field "$row" 6)" = "done" ]; } \
      || { printf 'no APPROVE of mine on this head'; return; }
    sec="$(last_review_section "$n" "$sha")"
    [ -n "$sec" ] || { printf 'no review of mine on this head'; return; }
    [ "$(printf '%s\n' "$sec" | marker_payload findings-json \
         | jq '[.[] | select(type == "object") | select(.severity == "critical" or .severity == "warning")
                | select((.status // "") != "fixed")] | length' 2>/dev/null)" = "0" ] \
      || { printf 'my review has open blocking findings'; return; }
    meta="$(printf '%s\n' "$sec" | marker_payload review-meta)"
    [ "$(printf '%s' "$meta" | jq -r '(.triage.class // "") + "|" + (.triage.forced // "")' 2>/dev/null)" = "quick-check|" ] \
      || { printf 'my triage is not a quick check'; return; }
    det="$(gh api "repos/$REPO/pulls/$n" 2>/dev/null)"
    [ "$(printf '%s' "$det" | jq -r '.head.sha // ""' 2>/dev/null)" = "$sha" ] \
      || { printf 'the PR detail did not read this head'; return; }
    # has_hooks is clean on a host with pre-receive hooks
    case "$(printf '%s' "$det" | jq -r '.mergeable_state // ""')" in (clean|has_hooks) ;;
      (*) printf 'GitHub reports mergeable_state %s' "$(printf '%s' "$det" | jq -r '.mergeable_state // "unknown"')"; return;; esac
    [ "$(printf '%s' "$det" | jq '(.additions // 999999) + (.deletions // 999999)')" -le "$AM_MAX" ] \
      || { printf 'more than %s changed lines' "$AM_MAX"; return; }
    [ "$(printf '%s' "$det" | jq '.changed_files // 999')" -le 100 ] \
      || { printf 'more than 100 changed files'; return; }
    files="$(gh api "repos/$REPO/pulls/$n/files?per_page=100" 2>/dev/null)"
    printf '%s' "$files" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1 \
      || { printf 'the changed files could not be read'; return; }
    # a rename names its old path too: moving a file out of .github/ changes it
    files="$(printf '%s' "$files" | jq -r '.[] | .filename, (.previous_filename // empty)')"
    while IFS= read -r f; do
      case "$f" in (.github/*) printf 'changes %s' "$f"; return;; esac
      path_glob_match "$f" "$AM_HUMAN_PATHS" >/dev/null && { printf 'changes %s (human_review_paths)' "$f"; return; }
    done <<< "$files"
    # a person's open change request stands, whatever branch protection requires;
    # every page, oldest first, so a person's latest review is never cut off
    case "$(gh_get --paginate "repos/$REPO/pulls/$n/reviews?per_page=100" | jq -rs --arg b "$BOT_LOGIN" '
        if length == 0 or any(.[]; type != "array") then "unreadable" else
          [ add | .[] | select(.user.login != $b) | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "DISMISSED") ]
          | group_by(.user.login) | map(last | .state)
          | if any(. == "CHANGES_REQUESTED") then "changes" else "ok" end end' 2>/dev/null)" in
      (ok) ;;
      (changes) printf 'a person requested changes'; return;;
      (*) printf 'the reviews could not be read'; return;;
    esac
    ci_json="$(ci_runs "$REPO" "$sha")"
    ci_terminal "$ci_json" || { printf 'checks still running'; return; }
    [ "$(ci_failing "$ci_json" | jq 'length')" -eq 0 ] || { printf 'a check failed'; return; }
  }
  # a PR this run reviews or answers first can change its verdict, its triage
  # or its findings before the merge or fix step: the next run decides on the
  # review that stands then
  reviewed_this_run() { # <pr-number>
    printf '%s\n%s' "$REVIEWS_DUE" "$MENTIONS_DUE" | jq -se --argjson n "$1" 'add | any(.[]; .number == $n)' >/dev/null 2>&1
  }
  MERGES_DUE='[]'
  if [ "$AUTO_MERGE" = "enabled" ]; then
    while IFS=$'\t' read -r n sha; do
      [ -n "$n" ] || continue
      if reviewed_this_run "$n"; then log "PR #$n: $AM_LABEL present, no auto-merge — this run reviews or answers it first"; continue; fi
      why="$(am_block "$n" "$sha")"
      if [ -n "$why" ]; then log "PR #$n: $AM_LABEL present, no auto-merge — $why"; continue; fi
      MERGES_DUE="$(printf '%s' "$MERGES_DUE" | jq -c --argjson n "$n" --arg sha "$sha" --arg m "$AM_METHOD" '. + [{number:$n, sha:$sha, method:$m}]')"
      log "PR #$n: auto-merge due at ${sha:0:7}"
    done < <(printf '%s' "$OPEN_NONDRAFT" | jq -r --arg l "$AM_LABEL" '.[] | select(.labels | index($l)) | [.number, .head_sha] | @tsv')
  fi

  # ---------------------------------------------------------- agent fixes ----
  # docs/agent-fixes.md: a PR a person labeled, whose current head my review
  # left with open blocking findings that state their fix, gets one fix round.
  AGENT_FIXES="$(cfg agent_fixes)"; AGENT_FIXES="${AGENT_FIXES:-disabled}"
  case "$AGENT_FIXES" in
    (enabled|disabled) ;;
    (*) log "agent_fixes '$AGENT_FIXES' unknown — treating as disabled"; AGENT_FIXES=disabled;;
  esac
  AF_LABEL="$(cfg agent_fix_label)"
  if [ "$AGENT_FIXES" = "enabled" ] && [ -z "$AF_LABEL" ]; then
    log_warn "agent_fixes is enabled without agent_fix_label — agent fixes are off this run"; AGENT_FIXES=disabled
  fi
  FIXES_DUE='[]'
  if [ "$AGENT_FIXES" = "enabled" ]; then
    while IFS=$'\t' read -r n sha; do
      [ -n "$n" ] || continue
      if reviewed_this_run "$n"; then log "PR #$n: $AF_LABEL present, no fix — this run reviews or answers it first"; continue; fi
      if grep -qF "<!-- agent-fix: $sha -->" "$WORK/reviews/pr-$n.md" 2>/dev/null; then
        log "PR #$n: $AF_LABEL present, no fix — a fix round of this head already ran"; continue
      fi
      sec="$(last_review_section "$n" "$sha")"
      if [ -z "$sec" ]; then log "PR #$n: $AF_LABEL present, no fix — no review of mine on this head"; continue; fi
      nfix="$(printf '%s\n' "$sec" | marker_payload findings-json \
        | jq '[.[] | select(type == "object") | select(.severity == "critical" or .severity == "warning")
               | select((.status // "") != "fixed") | select((.fix // "") != "")] | length' 2>/dev/null)"
      case "$nfix" in (''|0|*[!0-9]*) log "PR #$n: $AF_LABEL present, no fix — my review has no open blocking finding with a fix"; continue;; esac
      hrepo="$(gh_get "repos/$REPO/pulls/$n" | jq -r '.head.repo.full_name // ""' 2>/dev/null)"
      if [ -z "$hrepo" ]; then log "PR #$n: $AF_LABEL present, no fix — the PR could not be read"; continue; fi
      if [ "$(printf '%s' "$hrepo" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]')" ]; then
        log "PR #$n: $AF_LABEL present, no fix — the head branch is not in the target repository"; continue
      fi
      FIXES_DUE="$(printf '%s' "$FIXES_DUE" | jq -c --argjson n "$n" --arg sha "$sha" --argjson k "$nfix" '. + [{number:$n, sha:$sha, findings:$k}]')"
      log "PR #$n: agent fix due at ${sha:0:7} ($nfix finding(s))"
    done < <(printf '%s' "$OPEN_NONDRAFT" | jq -r --arg l "$AF_LABEL" '.[] | select(.labels | index($l)) | [.number, .head_sha] | @tsv')
  fi

  apply_holds mentions
  emit "$REVIEWS_DUE" "$CLEANUPS_DUE" "$SELFHEALS_DUE" "$PRUNES_DUE" "$ARTIFACTS_DUE" '[]' "$ALERTS_DUE" "$MENTIONS_DUE" "$SKILLS"
  exit 0
fi

# ========================================================= SHEPHERD MODE ====
if [ "$MODE" = "shepherd" ]; then
  [ "$SLACK" = "enabled" ] || { log "slack notifications disabled — shepherd skipped"; emit '[]' '[]' '[]' '[]' '[]' '[]' '[]' '[]' '{}'; exit 0; }
  [ -f "$DEVELOPERS" ] || { log "work/DEVELOPERS.md missing — shepherd skipped"; emit '[]' '[]' '[]' '[]' '[]' '[]' '[]' '[]' '{}'; exit 0; }

  # Merge readiness: an approved, green, conflict-free PR is silent today, and
  # silence reads the same as "still waiting" (docs/shepherd.md → Ready to
  # land). Off by default, like everything that speaks to people.
  MERGE_READY="$(cfg merge_ready_nudge)"; MERGE_READY="${MERGE_READY:-disabled}"
  case "$MERGE_READY" in
    (enabled|disabled) ;;
    (*) log "merge_ready_nudge '$MERGE_READY' unknown — treating as disabled"; MERGE_READY=disabled;;
  esac
  if [ "$MERGE_READY" = "enabled" ] && [ "$CI_LIB" -eq 0 ]; then
    MERGE_READY=disabled
    log_warn "lib/ci-rollup.sh unreadable — the ready-to-land nudge is disabled this run"
  fi

  # Who the reviewer-directed nudges cover (docs/shepherd.md → Scope and brief): every
  # PR, or only the ones my last review says a person must read.
  SHEP_SCOPE="$(cfg shepherd_scope)"; SHEP_SCOPE="${SHEP_SCOPE:-all}"
  case "$SHEP_SCOPE" in
    (all|needs_human) ;;
    (*) log "shepherd_scope '$SHEP_SCOPE' unknown — treating as all"; SHEP_SCOPE=all;;
  esac

  # My last review's `triage` (docs/review-mechanics.md → Summary body format),
  # only while that review read the current head: a call on older code never
  # silences a nudge. Prints the JSON object, or nothing.
  own_triage() { # <pr-number> <head-sha>
    last_review_section "$1" "$2" | marker_payload review-meta \
      | jq -c '.triage // empty | select(type == "object")' 2>/dev/null || true
  }

  # The agent's own last word on the PR: a critical it raised and the author has
  # not fixed means the PR is not ready, whatever the humans approved. The
  # newest findings-json of the history file is that word; no file, no review,
  # and the check is vacuously clear.
  own_open_criticals() { # <pr-number> -> count
    local f="$WORK/reviews/pr-$1.md" j
    [ -f "$f" ] || { printf 0; return 0; }
    j="$(marker_payload findings-json < "$f")"
    [ -n "$j" ] || { printf 0; return 0; }
    printf '%s' "$j" | jq '[.[] | select(type == "object")
                            | select((.severity // "") == "critical")
                            | select((.status // "") != "fixed")] | length' 2>/dev/null \
      || printf 0
  }

  # roster: login -> slack_id (table or bullet format)
  ROSTER="$(grep -E '^\|' "$DEVELOPERS" 2>/dev/null | while IFS='|' read -r _ l sid _rest; do
      l="$(printf '%s' "$l" | tr -d '\` ')"; sid="$(printf '%s' "$sid" | tr -d ' ')"
      case "$l" in ('') ;; (login) ;; (-*) ;; (*) printf '%s\t%s\n' "$l" "$sid";; esac
    done)"
  if [ -z "$ROSTER" ]; then
    ROSTER="$(login=""; while IFS= read -r line; do
        case "$line" in
          (*slack_id:*) sid="$(printf '%s' "${line#*slack_id:}" | tr -d '\` ')"
                        [ -n "$login" ] && printf '%s\t%s\n' "$login" "$sid";;
          (*login:*)    login="$(printf '%s' "${line#*login:}" | tr -d '\` ')";;
        esac
      done < "$DEVELOPERS")"
  fi
  roster_has() { printf '%s\n' "$ROSTER" | cut -f1 | grep -qx "$1"; }
  slack_id() {
    while IFS=$'\t' read -r l sid; do
      [ "$l" = "$1" ] && { printf '%s' "$sid"; return; }
    done <<< "$ROSTER"
  }

  shep_rows() { grep -E '^\| *[0-9]+ *\|' "$SHEPHERD" 2>/dev/null || true; }

  # One append-only line per (PR, kind), written the first time a fact is seen
  # and never rewritten. Both facts outlive the ledger row, which pruning
  # deletes with the merged PR (docs/audit.md → task 33).
  pr_event() { # <pr> <kind> <iso ts> [extra json object]
    grep -qE "\"pr\":$1,\"kind\":\"$2\"" "$PR_EVENTS" 2>/dev/null && return 0
    local line extra="$4"
    [ -n "$extra" ] || extra='{}'
    line="$(jq -nc --argjson pr "$1" --arg k "$2" --arg ts "$3" --argjson x "$extra" \
      '{pr:$pr, kind:$k, ts:$ts} + $x' 2>/dev/null)" || return 0
    [ -n "$line" ] && printf '%s\n' "$line" >> "$PR_EVENTS" 2>/dev/null
    return 0
  }
  shep_row()  { shep_rows | grep -E "^\| *$1 *\|" | head -1; }

  # Review classification from independent reviews (bot + author excluded,
  # marker-carrying reviews excluded). Reads the reviews array on stdin and
  # prints approved | changes_requested | awaiting_review — or NOTHING when the
  # input is not an array, so a faulted read stays distinguishable from an
  # answer (the caller defers the PR rather than recording a guess).
  classify_reviews() { # <author>   < reviews-json
    jq -r --arg a "$1" --arg b "$BOT_LOGIN" --arg m "<!-- $REVIEW_MARKER" '
        if type != "array" then empty else
          [ .[] | select(.user.login != $b and .user.login != $a)
                | select((.body // "") | contains($m) | not) ]
          | group_by(.user.login) | map(last | .state)
          | if any(. == "APPROVED") then "approved"
            elif any(. == "CHANGES_REQUESTED") then "changes_requested"
            else "awaiting_review" end
        end' 2>/dev/null
  }

  NEW_TABLE=""; NUDGES_DUE='[]'
  while IFS=$'\t' read -r n title author created head_sha labels requested url; do
    row="$(shep_row "$n")"
    eligible="$(row_field "$row" 3)"
    if [ -z "$eligible" ]; then
      eligible="$(gh api "repos/$REPO/issues/$n/timeline?per_page=100" 2>/dev/null | jq -r '[.[] | select(.event=="ready_for_review") | .created_at] | last // empty')"
      [ -z "$eligible" ] && eligible="$created"
    fi
    reviewers="$(row_field "$row" 4)"
    prev_state="$(row_field "$row" 5)"
    case "$prev_state" in approved|changes_requested|awaiting_review) ;; *) prev_state="";; esac  # legacy formats
    nudges="$(row_field "$row" 6)"; nudges="${nudges:-0}"; [ "$nudges" = "-" ] && nudges=0
    last="$(row_field "$row" 7)"; last="${last:--}"
    level="$(row_field "$row" 8)"; level="${level:-1}"; case "$level" in ''|*[!0-9]*) level=1;; esac
    status="$(row_field "$row" 9)"

    # Classification, with an outage never allowed to read as an answer: REST
    # first, GraphQL as the second opinion (during the 2026-08-17 incident the
    # REST endpoint returned 404 bodies carrying a GraphQL error while the
    # GraphQL endpoint answered correctly), and if neither responds the PR is
    # deferred with its ledger row carried over untouched — the same deferral
    # the review path makes on __api_error__.
    reviews_json="$(gh api "repos/$REPO/pulls/$n/reviews?per_page=100" 2>/dev/null)"
    cls="$(printf '%s' "$reviews_json" | classify_reviews "$author")"
    if [ -z "$cls" ]; then
      reviews_json="$(gh api graphql -F n="$n" -f o="${REPO%%/*}" -f r="${REPO#*/}" -f query='
               query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){
                 pullRequest(number:$n){reviews(last:100){nodes{state body submittedAt author{login}}}}}}' 2>/dev/null \
             | jq -c 'if (.data.repository.pullRequest.reviews.nodes | type) == "array"
                      then [ .data.repository.pullRequest.reviews.nodes[]
                             | {user:{login:(.author.login // "")}, state, body,
                                submitted_at: .submittedAt} ]
                      else empty end' 2>/dev/null)"
      cls="$(printf '%s' "$reviews_json" | classify_reviews "$author")"
      [ -n "$cls" ] && logev warn gh_api "PR #$n: reviews REST read faulted — classified via GraphQL"
    fi
    if [ -z "$cls" ]; then
      logev warn gh_api "PR #$n: review classification unavailable (REST and GraphQL both faulted) — PR deferred, ledger row untouched"
      [ -n "$row" ] && NEW_TABLE="$NEW_TABLE$row"$'\n'
      continue
    fi

    # merge-conflict flag (detail call — the list endpoint omits mergeable
    # state; null = still computing, treated as clean until the next sweep)
    dirty=false
    [ "$(gh api "repos/$REPO/pulls/$n" 2>/dev/null | jq -r '.mergeable_state // empty')" = "dirty" ] && dirty=true

    # the earliest independent review is a historical fact the API carries, so
    # this fills in for PRs that were already reviewed before the file existed
    first_rev="$(printf '%s' "$reviews_json" | jq -r --arg a "$author" --arg b "$BOT_LOGIN" --arg m "<!-- $REVIEW_MARKER" '
      if type != "array" then empty else
        [ .[] | select(.user.login != $b and .user.login != $a)
              | select((.body // "") | contains($m) | not)
              | .submitted_at // empty ] | min // empty
      end' 2>/dev/null)"
    if [ -n "$first_rev" ]; then
      lat=$(( ($(iso2epoch "$first_rev") - $(iso2epoch "$eligible")) / 3600 ))
      [ "$lat" -lt 0 ] && lat=0
      pr_event "$n" first_review "$first_rev" "$(jq -nc --argjson h "$lat" --arg e "$eligible" '{latency_hours:$h, eligible_since:$e}')"
    fi
    # a conflict is only observable while it lasts, so the first sweep that sees
    # one is the record; a later rebase never erases that the PR had one
    [ "$dirty" = "true" ] && pr_event "$n" conflict "$NOW_ISO" '{}'

    # class transition resets the ladder (never the clock)
    [ -n "$prev_state" ] && [ "$prev_state" != "$cls" ] && level=1

    age_h=$(( (NOW_EPOCH - $(iso2epoch "$eligible")) / 3600 ))
    since_last=999999; [ "$last" != "-" ] && since_last=$(( (NOW_EPOCH - $(iso2epoch "$last")) / 3600 ))

    due=0; new_status="watching"; next_level="$level"; nudge_class="$cls"
    # An approved PR nudges while it has merge conflicts (rebase ask), and once
    # when it is ready to land (docs/shepherd.md → Ready to land).
    if [ "$cls" = "approved" ] && [ "$dirty" = "false" ]; then
      new_status="approved"
      # the notification is sticky while the class stays approved, so the row
      # carries it forward and the PR is told exactly once
      notified=0
      if [ "$status" = "ready-notified" ]; then
        new_status="ready-notified"; notified=1
        # the mark covers the approval it announced. An approval submitted
        # after that message — the second one, once new commits dropped the
        # first — is a new landing moment and is announced again.
        last_approval="$(printf '%s' "$reviews_json" | jq -r --arg a "$author" --arg b "$BOT_LOGIN" --arg m "<!-- $REVIEW_MARKER" '
          if type != "array" then empty else
            [ .[] | select(.user.login != $b and .user.login != $a)
                  | select((.body // "") | contains($m) | not)
                  | select(.state == "APPROVED") | .submitted_at // empty ] | max // empty
          end' 2>/dev/null)"
        [ -n "$last_approval" ] && [ "$last" != "-" ] \
          && [ "$(iso2epoch "$last_approval")" -gt "$(iso2epoch "$last")" ] && notified=0
      fi
      if [ "$MERGE_READY" = "enabled" ] && [ "$notified" -eq 0 ]; then
        # the free local check first: a PR blocked by a critical of my own pays
        # no rollup call on every sweep
        if [ "$(own_open_criticals "$n")" -gt 0 ]; then
          # the review already said this in full; a second message would repeat it
          log "PR #$n: approved, but my last review has open critical(s) — no ready-to-land nudge"
        else
          ci_json="$(ci_runs "$REPO" "$head_sha")"
          if ! ci_terminal "$ci_json"; then
            log "PR #$n: approved, checks still running — ready-to-land nudge waits"
          elif [ "$(ci_failing "$ci_json" | jq 'length')" -gt 0 ]; then
            log "PR #$n: approved but CI failed — no ready-to-land nudge"
          else
            due=1; next_level=1; nudge_class="ready_to_land"
          fi
        fi
      fi
    elif [ "$status" = "held" ] && { [ -z "$prev_state" ] || [ "$prev_state" = "$cls" ]; }; then new_status="held"  # hold is sticky until the class changes
    elif [ "$age_h" -lt 24 ]; then new_status="watching"
    elif [ "$since_last" -lt 20 ]; then new_status="${status:-watching}"
    elif [ "$nudges" -eq 0 ]; then due=1; next_level=1
    elif [ "$since_last" -ge 48 ]; then due=1; next_level=$((level+1)); [ "$next_level" -gt 4 ] && next_level=4
    else new_status="${status:-watching}"
    fi

    # a reviewer-directed nudge carries my triage; under `needs_human` a PR my
    # review of this head called a quick check gets none
    brief=""
    if [ "$due" -eq 1 ] && [ "$nudge_class" = "awaiting_review" ] && [ "$dirty" = "false" ]; then
      brief="$(own_triage "$n" "$head_sha")"
      if [ "$SHEP_SCOPE" = "needs_human" ] && [ "$(printf '%s' "$brief" | jq -r '.class // ""' 2>/dev/null)" = "quick-check" ]; then
        due=0; new_status="${status:-watching}"; next_level="$level"
        log "PR #$n: quick check per my review — no reviewer nudge (shepherd_scope: needs_human)"
      fi
    fi

    if [ "$due" -eq 1 ]; then
      if [ "$nudge_class" = "ready_to_land" ]; then
        # whoever merges is the author's call, so the message goes to them
        targets="${author}!"; nudge_status="ready-notified"
      elif [ "$dirty" = "true" ] || [ "$cls" = "changes_requested" ]; then
        # conflicts and requested changes are both the author's to resolve
        targets="${author}!"; nudge_status="nudging-author"
      else
        targets=""
        for r in $(printf '%s' "$requested" | tr ',' ' '); do
          { [ "$r" = "-" ] || [ "$r" = "$author" ]; } && continue
          roster_has "$r" && targets="${targets:+$targets, }$r"
        done
        [ -z "$targets" ] && [ -n "$reviewers" ] && [ "$reviewers" != "-" ] && targets="$reviewers"
        nudge_status="nudging"
      fi
      [ "$nudge_class" != "ready_to_land" ] && [ "$next_level" -ge 4 ] && nudge_status="held"
      esc_id=""; [ "$next_level" -ge 4 ] && [ -n "$ESCALATION_OWNER" ] && esc_id="$(slack_id "$ESCALATION_OWNER")"
      mentions="$(for t in $(printf '%s' "$targets" | tr -d '!*' | tr ',' ' '); do id="$(slack_id "$t")"; [ -n "$id" ] && printf '%s\t%s\n' "$t" "$id"; done | jq -R 'split("\t") | {login:.[0], slack_id:.[1]}' | jq -s .)"
      NUDGES_DUE="$(printf '%s' "$NUDGES_DUE" | jq --argjson e "$(jq -n --argjson n "$n" --arg t "$title" --arg a "$author" --arg u "$url" \
        --argjson age "$age_h" --arg c "$nudge_class" --argjson l "$next_level" --argjson m "$mentions" \
        --arg eo "$ESCALATION_OWNER" --arg eid "$esc_id" --arg tg "$targets" \
        --argjson nn "$((nudges+1))" --arg ns "$nudge_status" --argjson conf "$dirty" --argjson br "${brief:-null}" \
        '{number:$n, title:$t, author:$a, url:$u, age_hours:$age, class:$c, level:$l, targets:$tg, mentions:$m,
          conflict:$conf, brief:$br,
          needs_target_selection: ($m|length==0 and $c!="changes_requested"
                                   and $c!="ready_to_land" and ($conf|not)),
          escalation:{login:$eo, slack_id:$eid},
          row_update:{nudges:$nn, level:$l, status:$ns}}')" '. + [$e]')"
      log "PR #$n: nudge L$next_level due ($nudge_class, ${age_h}h$([ "$dirty" = "true" ] && printf ', merge conflict'))"
      # send-then-record belongs to the agent: keep the row EXACTLY as-is
      new_status="${status:-watching}"; next_level="$level"
    fi

    [ -z "$reviewers" ] && reviewers="-"
    NEW_TABLE="$NEW_TABLE| $n | $eligible | $reviewers | $cls | $nudges | $last | $next_level | ${new_status:-watching} |"$'\n'
  done < <(printf '%s' "$OPEN_NONDRAFT" | jq -r '.[] | [.number, (.title|gsub("\t";" ")), .author, .created_at, .head_sha,
             ((.labels|join(","))|if .=="" then "-" else . end),
             ((.requested|join(","))|if .=="" then "-" else . end), .url] | @tsv')

  # carry over rows whose PR is not in the open non-draft set: drafts keep
  # their nudge history; closed PRs wait for the verified prune (review mode).
  while IFS= read -r old; do
    [ -z "$old" ] && continue
    onum="$(printf '%s' "$old" | cut -d'|' -f2 | tr -d ' ')"
    printf '%s' "$OPEN_NONDRAFT" | jq -e --argjson nn "$onum" 'any(.[]; .number==$nn)' >/dev/null \
      || NEW_TABLE="$NEW_TABLE$old"$'\n'
  done < <(shep_rows)

  {
    printf '# PR Shepherd Ledger\n\n'
    printf '_Bookkeeping maintained by scripts/preflight.sh shepherd (table only — the agent updates a row only as the post-send record of a nudge). Per-sweep history lives in SHEPHERD.log, append-only, never loaded into agent context._\n\n'
    printf '| PR | eligible_since | reviewers | review_state | nudges | last_nudge_at | level | status |\n'
    printf '|----|----------------|-----------|--------------|--------|---------------|-------|--------|\n'
    printf '%s' "$NEW_TABLE"
  } > "$SHEPHERD"
  printf '%s shepherd sweep: %s open PRs, %s nudges due\n' "$NOW_ISO" "$OPEN_COUNT" "$(printf '%s' "$NUDGES_DUE" | jq length)" >> "$WORK/SHEPHERD.log"

  emit '[]' '[]' '[]' '[]' '[]' "$NUDGES_DUE" '[]' '[]' '{}'
  exit 0
fi

# ============================================================ AUDIT MODE ====
if [ "$MODE" = "audit" ]; then
  AUDIT_ENABLED="$(cfg audit_report)"; AUDIT_ENABLED="${AUDIT_ENABLED:-enabled}"
  if [ "$AUDIT_ENABLED" != "enabled" ]; then
    log "audit_report disabled — audit skipped"
    printf '%s\n' "$NOW_ISO audit nothing_to_do=true audit_report=disabled" >> "$WORK/HEARTBEAT.log" 2>/dev/null
    jq -n --argjson logs "$(printf '%s\n' "${LOGS[@]:-}" | jq -R . | jq -s '[.[] | select(length>0)]')" \
      '{mode:"audit", nothing_to_do:true, logs:$logs}'
    exit 0
  fi

  SINCE_EPOCH=$((NOW_EPOCH - 7*86400))
  SINCE_ISO="$(epoch2iso "$SINCE_EPOCH")"
  CHECKS='[]'
  check() { CHECKS="$(printf '%s' "$CHECKS" | jq --arg i "$1" --arg s "$2" --arg d "$3" '. + [{id:$i, status:$s, detail:$d}]')"; }

  # definition repo, resolved here because the connectivity checks below cover
  # every host the pipeline touches (target, definition, skill sources)
  DEF_REF="$(cfg definition_repo)"
  [ -z "$DEF_REF" ] && DEF_REF="$(origin_ref "$HOME_DIR")"
  DEF_HOST="$(refhost "$DEF_REF")"; DEFINITION_REPO="$(refslug "$DEF_REF")"

  AUDIT_HOSTS="$REPO_HOST"
  [ -n "$DEF_REF" ] && AUDIT_HOSTS="$AUDIT_HOSTS $DEF_HOST"
  while IFS= read -r asrc; do
    AUDIT_HOSTS="$AUDIT_HOSTS $(refhost "$asrc")"
  done < <(printf '%s' "$SKILLS_TABLE" | jq -r '.[] | select(.source != "harness") | .source')
  AUDIT_HOSTS="$(printf '%s\n' $AUDIT_HOSTS | sort -u | tr '\n' ' ')"

  # --- connectivity (one line per host the pipeline uses) ---------------
  auth_detail=""; auth_status=ok; scope_detail=""; scope_status=ok
  for h in $AUDIT_HOSTS; do
    me="$(gh api --hostname "$h" user 2>/dev/null | jq -r '.login // empty')"
    if [ -z "$me" ]; then auth_status=fail; auth_detail="${auth_detail:+$auth_detail; }$h: not authenticated (token broken or host unreachable)"
    elif [ "$h" = "$REPO_HOST" ] && [ -n "$BOT_LOGIN" ] && [ "$me" != "$BOT_LOGIN" ]; then
      [ "$auth_status" = fail ] || auth_status=warn
      auth_detail="${auth_detail:+$auth_detail; }$h: authenticated as $me, expected $BOT_LOGIN"
    else auth_detail="${auth_detail:+$auth_detail; }$h: $me"; fi

    # Token scope the pipeline depends on: `repo` for PR state and posting. A
    # missing scope fails those calls outright, so catch it here rather than per
    # review; granting is operator-only.
    want="repo"
    scopes="$(gh api --hostname "$h" user -i 2>/dev/null | sed -n 's/^[Xx]-[Oo][Aa]uth-[Ss]copes:[[:space:]]*//p' | tr -d '\r')"
    missing_scopes=""
    for s in $want; do
      case ",$(printf '%s' "$scopes" | tr -d ' ')," in (*",$s,"*) ;; (*) missing_scopes="${missing_scopes:+$missing_scopes }$s";; esac
    done
    if [ -z "$scopes" ]; then
      [ "$scope_status" = fail ] || scope_status=warn
      scope_detail="${scope_detail:+$scope_detail; }$h: scopes unreadable (fine-grained or app token?)"
    elif [ -n "$missing_scopes" ]; then
      scope_status=fail; scope_detail="${scope_detail:+$scope_detail; }$h: missing $missing_scopes"
    else scope_detail="${scope_detail:+$scope_detail; }$h: $want"; fi
  done
  check github_auth "$auth_status" "$auth_detail"
  if [ "$scope_status" = "ok" ]; then check token_scopes ok "$scope_detail"
  else check token_scopes "$scope_status" "$scope_detail — operator-only fix; repo breaks PR state and posting"; fi

  # rate limiting is reported by the target host only, and enterprise hosts may
  # not enforce it at all — unreadable is not a fault (github_auth covers tokens)
  rl="$(gh api rate_limit 2>/dev/null | jq -r '.resources.core.remaining // empty')"
  if [ -z "$rl" ]; then check rate_limit ok "$REPO_HOST does not report a core rate limit"
  elif [ "$rl" -lt 500 ]; then check rate_limit warn "only $rl core API calls remaining this hour"
  else check rate_limit ok "$rl core API calls remaining"; fi

  # CLI dependencies (see the Requires header). A missing one is not fatal by
  # itself — it makes ad-hoc commands fail mid-run in ways that read as bugs.
  missing_cli=""
  for c in gh jq git sed grep cut tr date find; do
    command -v "$c" >/dev/null 2>&1 || missing_cli="${missing_cli:+$missing_cli }$c"
  done
  if [ -n "$missing_cli" ]; then check cli_deps fail "required command(s) unavailable: $missing_cli"
  else check cli_deps ok "all required commands present (awk/diff/python are deliberately not required)"; fi

  # A present-but-shimmed tool passes cli_deps yet costs ~250ms per exec, which
  # dominates jq-heavy runs (docs/logging.md → Tool path resolution). Not a
  # failure — the run works, slower — but it must not regress silently.
  shimmed="$(toolpath_shimmed gh jq 2>/dev/null)"
  if [ -n "$shimmed" ]; then check tool_shims warn "behind a mise shim: $shimmed — the runtime shadows them per run, every other process still pays ~250ms per call; fix belongs in the pod image (real bin dirs ahead of the shim dir on PATH)"
  else check tool_shims ok "hot-path tools are not shimmed"; fi

  check target_repo ok "$OPEN_COUNT open non-draft PRs listed"

  if [ -n "$WORK_REPO" ]; then
    if [ -e "$WORK/.git" ]; then
      check work_repo warn "work/.git present — work/ must be a plain data dir (backup runs in a tmpfs clone); remove it per docs/persistence.md"
    else
      check work_repo ok "work/ plain data dir; durable backup via tmpfs clone (any work_backup push errors surface in the log triage below)"
    fi
  else check work_repo ok "local-only persistence (no work_repo)"; fi

  # count only STUCK silly-renames (>5min): a fresh .nfs* is a normal transient
  # from a concurrent data-file write and clears on its own; a stuck one means a
  # process holds a file open across unlinks (the churn 2.0.0 removed).
  nfs_n="$(find "$WORK" -name '.nfs*' 2>/dev/null | grep -c . || true)"
  nfs_stuck="$(find "$WORK" -name '.nfs*' -mmin +5 2>/dev/null | grep -c . || true)"
  if [ "${nfs_stuck:-0}" -gt 0 ]; then check nfs_junk warn "$nfs_stuck stuck .nfs* (>5min) under work/ (total $nfs_n) — a process holds files open across unlinks"
  else check nfs_junk ok "no stuck .nfs* under work/ (${nfs_n:-0} transient)"; fi

  # --- heartbeat cadence & log errors ------------------------------------
  hb_total=0; hb_idle=0; max_gap=0; prev=0; last_e=0
  while IFS= read -r line; do
    ts="${line%% *}"; e="$(iso2epoch "$ts")"
    { [ "$e" -eq 0 ] || [ "$e" -lt "$SINCE_EPOCH" ]; } && continue
    case "$line" in (*" review "*) ;; (*) continue;; esac
    hb_total=$((hb_total+1))
    case "$line" in (*"nothing_to_do=true"*) hb_idle=$((hb_idle+1));; esac
    [ "$prev" -gt 0 ] && { g=$((e-prev)); [ "$g" -gt "$max_gap" ] && max_gap=$g; }
    prev="$e"; last_e="$e"
  done < <(cat "$WORK/HEARTBEAT.log" 2>/dev/null)
  last_age_m=$(( last_e > 0 ? (NOW_EPOCH - last_e) / 60 : -1 ))
  if [ "$hb_total" -eq 0 ]; then check heartbeats fail "no review heartbeats logged in the last 7 days"
  elif [ "$max_gap" -gt "$HB_GAP_MAX_S" ]; then check heartbeats warn "$hb_total heartbeats; largest gap $((max_gap/60)) min (over the $((HB_GAP_MAX_S/60))-min quiet-cadence tolerance); last ${last_age_m}m ago"
  else check heartbeats ok "$hb_total heartbeats, largest gap $((max_gap/60)) min, last ${last_age_m}m ago"; fi

  if [ "$SLACK" = "enabled" ]; then
    sw=0
    while IFS= read -r line; do
      ts="${line%% *}"; e="$(iso2epoch "$ts")"
      [ "$e" -ge "$SINCE_EPOCH" ] && sw=$((sw+1))
    done < <(cat "$WORK/SHEPHERD.log" 2>/dev/null)
    if [ "$sw" -eq 0 ]; then check shepherd_sweeps warn "no shepherd sweeps logged in the last 7 days"
    else check shepherd_sweeps ok "$sw shepherd sweeps this week"; fi
  fi

  err_lines="$( { grep -hiE 'fail|error|anomal' "$WORK/HEARTBEAT.log" "$WORK/SHEPHERD.log" 2>/dev/null || true; } \
    | while IFS= read -r l; do ts="${l%% *}"; e="$(iso2epoch "$ts")"; [ "$e" -ge "$SINCE_EPOCH" ] && printf '%s\n' "$l"; done)"
  err_count="$(printf '%s' "$err_lines" | grep -c . || true)"
  if [ "$err_count" -gt 0 ]; then check log_errors warn "$err_count error-ish log lines this week; last: $(printf '%s\n' "$err_lines" | tail -1 | cut -c1-160)"
  else check log_errors ok "no error lines in the weekly logs"; fi

  # --- state consistency --------------------------------------------------
  stale_locks=""
  while IFS= read -r row; do
    [ -z "$row" ] && continue
    st="$(row_field "$row" 6)"; [ "$st" = "in_progress" ] || continue
    ts="$(row_field "$row" 4)"; age=$(( (NOW_EPOCH - $(iso2epoch "$ts")) / 60 ))
    [ "$age" -gt "$LOCK_TTL_MIN" ] && stale_locks="${stale_locks:+$stale_locks, }#$(row_field "$row" 2) (${age}m)"
  done < <(reviews_rows)
  [ -n "$stale_locks" ] && check stale_locks warn "stale in_progress locks: $stale_locks" || check stale_locks ok "no stale locks"

  dups="$(reviews_rows | cut -d'|' -f2 | tr -d ' ' | sort | uniq -d | tr '\n' ' ')"
  [ -n "${dups// /}" ] && check duplicate_rows fail "duplicate REVIEWS.md rows for: $dups" || check duplicate_rows ok "no duplicate rows"

  # a row for a closed PR is pruned by the next run with work, so a fresh one
  # is normal; only a row whose PR closed more than GHOST_GRACE_H ago means the
  # prune did not happen, and only that one is a warn
  GHOST_GRACE_H=72
  ghosts="$(reviews_rows | cut -d'|' -f2 | tr -d ' ' | grep -vxF -f <(open_numbers; echo '-') | sort -un | tr '\n' ' ')"
  pending=0; stuck=""; unread=""
  if [ -n "${ghosts// /}" ]; then
    gstates="$(prune_states $ghosts)"
    for n in $ghosts; do
      gpj="$(printf '%s\n' "$gstates" | jq -c --argjson n "$n" 'select(.n == $n) | .pj' 2>/dev/null | head -1)"
      [ -n "$gpj" ] || gpj="$(gh_get "repos/$REPO/pulls/$n" | jq -c '{state, closed_at}' 2>/dev/null)"
      # open, yet past the one-page open list (or reopened): a live row
      [ "$(printf '%s' "$gpj" | jq -r '.state // empty' 2>/dev/null)" = "open" ] && continue
      ca="$(printf '%s' "$gpj" | jq -r '.closed_at // empty' 2>/dev/null)"
      if [ -z "$ca" ]; then unread="${unread:+$unread, }#$n"
      elif [ $(( (NOW_EPOCH - $(iso2epoch "$ca")) / 3600 )) -ge "$GHOST_GRACE_H" ]; then stuck="${stuck:+$stuck, }#$n"
      else pending=$((pending+1)); fi
    done
  fi
  pend_note=""; [ "$pending" -gt 0 ] && pend_note=" ($pending closed PR row(s) wait for the next run with work)"
  if [ -n "$stuck" ]; then check closed_rows warn "rows for PRs closed more than ${GHOST_GRACE_H} h ago, never pruned: $stuck$pend_note"
  elif [ -n "$unread" ]; then check closed_rows warn "close time unreadable (API) for rows of non-open PRs: $unread$pend_note"
  else check closed_rows ok "every row maps to an open PR$pend_note"; fi

  # an open PR keeps its files without a row (the urgent alert before the first
  # review, a draft's override); a non-open one is a prune that did not happen
  orphans=""
  for n in $(pr_file_numbers); do
    [ -n "$(row_for "$n")" ] && continue
    open_numbers | grep -qx "$n" || orphans="$orphans #$n"
  done
  if [ -n "$orphans" ]; then
    check orphan_history warn "$(printf '%s' "$orphans" | wc -w | tr -d ' ') PR(s) keep reviews/ files without a REVIEWS.md row or an open PR:$orphans"
  else check orphan_history ok "every reviews/ file has a row or an open PR"; fi

  # memory budget (docs/preferences.md → bounds): over the documented cap is a
  # warn that makes this audit's consolidation mandatory; 1.5× the cap is a fail
  mb_detail="$(printf '%s' "$MEMORY_JSON" | jq -r 'def names: if length > 5 then (.[:5] | join(", ")) + " +\(length - 5) more" else join(", ") end;
    "MEMORY.md \(.memory_lines)/\(.memory_limit) lines · \(.long_lines) past \(.line_limit) chars · insights \(.insights)/\(.insights_limit) · feedback \(.feedback)/\(.feedback_limit) · LESSONS.md \(.lessons_sections)/\(.lessons_limit) sections, \(.lessons_lines)/\(.lessons_lines_limit) lines, \(.lessons_long_lines) past \(.lessons_line_limit) chars · area files: \(.area_over | length) over \(.area_lines_limit) lines or 120 chars\(if (.area_over | length) > 0 then " (" + (.area_over | names) + ")" else "" end)\(if (.area_unscoped | length) > 0 then " · \(.area_unscoped | length) without scope, archive them (" + (.area_unscoped | names) + ")" else "" end)"')"
  # Insights and the Feedback Log have their own counters, so an over-budget
  # MEMORY.md whose two counters sit inside bounds is carrying the lines
  # somewhere else — name the biggest sections, the consolidation needs to know
  # which ones (audit mode only: this reads the whole file).
  if [ "$(printf '%s' "$MEMORY_JSON" | jq -r '.over_budget')" = "true" ]; then
    mb_top="$(jq -Rrs 'split("\n")
      | reduce .[] as $l ({cur: "(preamble)", acc: {}};
          (if ($l | test("^## ")) then .cur = ($l | sub("^## *"; "")) else . end)
          | .acc[.cur] = ((.acc[.cur] // 0) + 1))
      | .acc | to_entries | sort_by(-.value) | .[:3]
      | map("\(.key) \(.value)") | join(" · ")' < "$WORK/MEMORY.md" 2>/dev/null)"
    [ -n "$mb_top" ] && mb_detail="$mb_detail · biggest sections: $mb_top"
  fi
  if printf '%s' "$MEMORY_JSON" | jq -e '.memory_lines > 180 or .lessons_sections > 15 or .lessons_lines > 150 or .area_max_lines > 60' >/dev/null 2>&1; then
    check memory_budget fail "far over the documented bounds — $mb_detail; consolidate now (docs/preferences.md → Weekly memory consolidation)"
  elif [ "$(printf '%s' "$MEMORY_JSON" | jq -r '.over_budget')" = "true" ]; then
    check memory_budget warn "over the documented bounds — $mb_detail; consolidation is mandatory this audit"
  else
    check memory_budget ok "within bounds — $mb_detail"
  fi

  # project profile currency (docs/profile.md → Freshness): the check refreshes
  # a stale profile, so a `regenerated` here is the backstop doing its work
  if [ "$PROJECT_PROFILE" != "enabled" ]; then
    check profile_fresh ok "project profile disabled by configuration"
  else
    pf="$(LOG_JOB=audit bash "$SCRIPT_DIR/profile.sh" check 2>/dev/null)"
    pf_status="$(printf '%s' "$pf" | jq -r '.status // "unavailable"' 2>/dev/null)"
    pf_note="$(printf '%s' "$pf" | jq -r '[.mode, (if .base then "base " + .base else empty end), (if .age_hours != null then "\(.age_hours)h old" else empty end), (.note // empty)] | join(", ")' 2>/dev/null)"
    case "$pf_status" in
      (current)      check profile_fresh ok "profile current ($pf_note)";;
      (regenerated)  check profile_fresh ok "profile refreshed by this audit ($pf_note)";;
      (unverified)   check profile_fresh warn "profile could not be verified ($pf_note)";;
      (*)            check profile_fresh fail "profile unavailable ($pf_note) — reviews run without the repository map";;
    esac
  fi

  # benchmark hygiene: the official results history must never hold a trial
  # run — trials live under trials/<id>/ only (docs/benchmark.md → Trial runs)
  if [ -d "$WORK/benchmark/results" ]; then
    tr_leak="$(grep -l '"trigger": *"trial"' "$WORK/benchmark/results"/*.json 2>/dev/null | head -3 | tr '\n' ' ')"
    if [ -n "${tr_leak// /}" ]; then
      check benchmark_hygiene fail "trial run(s) sitting in the official results/: $tr_leak— move them under trials/ per docs/benchmark.md"
    else
      check benchmark_hygiene ok "no trial runs in the official results history"
    fi
  fi

  # benchmark integrity: the active fixture set must stay leak-free and the
  # newest results file must keep the shape the report and the gate read.
  # Both are deterministic (benchmark-validate.sh), so a regression surfaces
  # here instead of quietly scoring the wrong thing (docs/benchmark.md).
  if [ -d "$WORK/benchmark/fixture" ] && [ "$(cfg benchmark)" = "enabled" ]; then
    bv_out="$(bash "$SCRIPT_DIR/benchmark-validate.sh" fixture "$WORK/benchmark/fixture"/*/ 2>/dev/null)"
    bv_bad="$(printf '%s' "$bv_out" | grep '^FAIL ' | cut -d' ' -f2 | head -4 | tr '\n' ' ')"
    if [ -n "${bv_bad// /}" ]; then
      check benchmark_fixtures fail "fixture validation failing: ${bv_bad% } — scores from this set are invalid; retire and replace it (docs/benchmark.md → Retiring a fixture set)"
    else
      check benchmark_fixtures ok "fixture set validates (no ground-truth leakage)"
    fi
    newest_res="$(ls "$WORK/benchmark/results"/*.json 2>/dev/null | sort | tail -1)"
    if [ -n "$newest_res" ]; then
      bv_bad="$(bash "$SCRIPT_DIR/benchmark-validate.sh" results "$newest_res" 2>/dev/null \
                | grep '^FAIL ' | cut -d' ' -f2 | head -4 | tr '\n' ' ')"
      if [ -n "${bv_bad// /}" ]; then
        check benchmark_results warn "newest results file (${newest_res##*/}) fails: ${bv_bad% } — the report tolerates it, later runs must not repeat the shape"
      else
        check benchmark_results ok "newest results file has the documented shape"
      fi
    fi
  fi

  drift=""; verified=0; unverifiable=0
  while IFS=$'\t' read -r n sha; do
    row="$(row_for "$n")"; [ -z "$row" ] && continue
    st="$(row_field "$row" 6)"; { [ "$st" = "done" ] || [ "$st" = "awaiting_label" ]; } || continue
    [ $((verified + unverifiable)) -ge 25 ] && break
    rsha="$(row_field "$row" 3)"
    if [ "$API_ERRS" -ge 2 ]; then ts="__api_error__"; else ts="$(remote_reviewed_at "$n" "$rsha")"; fi
    case "$ts" in
      (__api_error__) API_ERRS=$((API_ERRS+1)); unverifiable=$((unverifiable+1));;
      ('')            verified=$((verified+1)); drift="${drift:+$drift, }#$n";;
      (*)             verified=$((verified+1));;
    esac
  done < <(printf '%s' "$OPEN_NONDRAFT" | jq -r '.[] | [.number, .head_sha] | @tsv')
  if [ -n "$drift" ]; then
    extra=""; [ "$unverifiable" -gt 0 ] && extra="; $unverifiable more unverifiable (marker scan API errors)"
    check state_drift fail "rows whose SHA has no marker on GitHub: $drift$extra"
  elif [ "$unverifiable" -gt 0 ]; then
    check state_drift warn "$unverifiable of $((verified + unverifiable)) rows unverifiable (marker scan API errors); $verified verified ok"
  else
    check state_drift ok "$verified open-PR rows verified against GitHub markers"
  fi

  # --- hygiene --------------------------------------------------------------
  TMP_ROOT="${TMPDIR:-/tmp}"
  swept="$(sweep_stale_clones)"

  # benchmark leftovers of dead runs — trees, per-nonce phase state, nonce
  # caches. Swept only past the benchmark run-lock TTL: a live run touches
  # its files far more often than that, so age alone proves the run is dead.
  bswept=0
  for d in "$TMP_ROOT"/benchmark-pr-* "$TMP_ROOT"/benchmark-phase-* "$TMP_ROOT"/.bench-usage-*; do
    [ -e "$d" ] || continue
    [ -n "$(find "$d" -maxdepth 0 -mmin +"$BENCH_LOCK_TTL_MIN" 2>/dev/null)" ] || continue
    rm -rf "$d" && bswept=$((bswept+1))
  done
  [ "$bswept" -gt 0 ] && logev info tmp_cleanup "benchmark sweep: reclaimed $bswept leftover(s) from dead benchmark runs"

  sw_note=""; [ "$swept" -gt 0 ] && sw_note=" ($swept stale reclaimed)"
  # after the sweep, an entry of a live review (locked, or younger than the
  # lock TTL) is expected; only a dead one the sweep could not remove is a warn
  tmp_live=0; tmp_left=0
  for d in "$TMP_ROOT"/review-pr-*; do
    [ -e "$d" ] || continue
    cn="${d##*/review-pr-}"; cn="${cn%%.*}"
    case "$cn" in (''|*[!0-9]*) continue;; esac   # not ours: the sweep never touches it
    if [ "$(row_field "$(row_for "$cn")" 6)" = "in_progress" ] \
       || [ -z "$(find "$d" -maxdepth 0 -mmin +"$LOCK_TTL_MIN" 2>/dev/null)" ]; then tmp_live=$((tmp_live+1))
    else tmp_left=$((tmp_left+1)); fi
  done
  [ "$tmp_live" -gt 0 ] && sw_note="$sw_note ($tmp_live of a live review)"
  [ "$tmp_left" -gt 0 ] && check tmp_leftovers warn "$tmp_left dead /tmp/review-pr-* entries the sweep could not remove$sw_note" || check tmp_leftovers ok "no clone leftovers$sw_note"

  disk="$(df -P "$WORK" 2>/dev/null | tail -1 | tr -s ' ' | cut -d' ' -f5 | tr -d '%')"
  if [ -n "$disk" ] && [ "$disk" -gt 85 ]; then check disk warn "work volume ${disk}% full"; else check disk ok "work volume ${disk:-?}% used"; fi

  while IFS=$'\t' read -r skill src; do
    remote_sha="$(gh api --hostname "$(refhost "$src")" "repos/$(refslug "$src")/commits/main" 2>/dev/null | jq -r '.sha // empty')"
    cached="$(cat "$SKILL_CACHE/$skill.sha" 2>/dev/null || true)"
    if [ -z "$remote_sha" ]; then check "skill_$skill" warn "source $src unreachable"
    elif [ "$remote_sha" != "$cached" ]; then check "skill_$skill" ok "update available (installs on next review)"
    else check "skill_$skill" ok "installed and current"; fi
  done < <(printf '%s' "$SKILLS_TABLE" | jq -r '.[] | select(.source != "harness") | [.skill, .source] | @tsv')

  if [ "$SLACK" = "enabled" ]; then
    if [ ! -f "$DEVELOPERS" ]; then check roster fail "slack enabled but work/DEVELOPERS.md missing"
    elif [ -n "$ESCALATION_OWNER" ] && ! grep -q "$ESCALATION_OWNER" "$DEVELOPERS"; then check roster warn "escalation_owner '$ESCALATION_OWNER' not found in the roster"
    else check roster ok "roster present, escalation owner listed"; fi
  fi

  # open-issue backlog on the definition repo: tracking issues the agent files
  # ([audit], [channel request]) wait for the operator — surface them weekly
  if [ -z "$DEFINITION_REPO" ]; then
    check definition_issues warn "definition_repo unresolved — issue backlog not checked"
  else
    issue_line="$(gh api --hostname "$DEF_HOST" "repos/$DEFINITION_REPO/issues?state=open&per_page=100" 2>/dev/null \
      | jq -r '[.[] | select(.pull_request | not)]
               | (length | tostring) + "\t"
                 + ([.[] | "#\(.number) \(.title | .[0:60])"] | join(" · ") | .[0:240])' 2>/dev/null)"
    if [ -z "$issue_line" ]; then check definition_issues warn "definition-repo issue list unreadable"
    else
      issue_n="${issue_line%%$'\t'*}"
      if [ "${issue_n:-0}" -gt 0 ]; then
        check definition_issues warn "$issue_n open issue(s) awaiting the operator: ${issue_line#*$'\t'}"
      else check definition_issues ok "no open issues on the definition repo"; fi
    fi
  fi

  if [ -d "$HOME_DIR/.git" ]; then
    def_dirty="$(git -C "$HOME_DIR" status --porcelain 2>/dev/null | grep -c . || true)"
    [ "$def_dirty" -gt 0 ] && check definition warn "$def_dirty uncommitted changes in the definition checkout" \
      || check definition ok "definition checkout clean ($(git -C "$HOME_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null))"

    # definition version currency: latest (tracked branch) vs checkout vs adopted
    DB="$DEFINITION_BRANCH"
    git -C "$HOME_DIR" fetch -q origin "$DB" >/dev/null 2>&1
    latest_v="$(git -C "$HOME_DIR" show "origin/$DB:VERSION" 2>/dev/null | head -1 | tr -d '[:space:]')"
    checkout_v="$(head -1 "$HOME_DIR/VERSION" 2>/dev/null | tr -d '[:space:]')"
    adopted_v="$(head -1 "$WORK/VERSION" 2>/dev/null | tr -d '[:space:]')"
    cur_branch="$(git -C "$HOME_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    if [ -z "$latest_v" ]; then check definition_version warn "origin/$DB VERSION unreadable (fetch blocked, branch missing, or it predates versioning)"
    elif [ "$cur_branch" != "$DB" ]; then check definition_version warn "definition on branch '$cur_branch' but definition_branch is '$DB' — ask the agent to switch in the direct session (docs/persistence.md)"
    elif [ "$checkout_v" != "$latest_v" ]; then check definition_version warn "definition outdated: running ${checkout_v:-pre-versioning}, latest on $DB is $latest_v — ask the agent to update in the direct session"
    elif [ "$adopted_v" != "$checkout_v" ]; then check definition_version warn "update pulled but not adopted: work/VERSION is ${adopted_v:-missing} vs $checkout_v — migration pending (docs/persistence.md)"
    else check definition_version ok "definition current ($checkout_v on $DB, migration adopted)"; fi
  fi

  # --- events log: triage, harness adapter, 14-day retention (docs/logging.md)
  # the week's events, read once for every statistic of this audit
  AUDIT_EVENTS="$PF_TMP/audit-events.jsonl"
  events_jsonl | jq -c --arg s "$SINCE_ISO" 'select(.ts >= $s)' > "$AUDIT_EVENTS" 2>/dev/null
  week_events() { cat "$AUDIT_EVENTS" 2>/dev/null; }
  ev_err=0; ev_warn=0; recurring=""
  if ls "$LOG_DIR"/events-*.jsonl >/dev/null 2>&1; then
    ev_err="$(week_events | jq -rs --arg s "$SINCE_ISO" '[.[] | select(.ts >= $s and .level=="error")] | length' 2>/dev/null)"; ev_err="${ev_err:-0}"
    ev_warn="$(week_events | jq -rs --arg s "$SINCE_ISO" '[.[] | select(.ts >= $s and .level=="warn")] | length' 2>/dev/null)"; ev_warn="${ev_warn:-0}"
    recurring="$(week_events | jq -rs --arg s "$SINCE_ISO" \
      '[.[] | select(.ts >= $s and (.level=="error" or .level=="warn"))] | group_by(.event)
       | map(select(length >= 3) | "\(.[0].event)×\(length)") | join(", ")' 2>/dev/null)"
  fi
  if [ "$ev_err" -gt 0 ]; then
    last_err="$(week_events | jq -rs --arg s "$SINCE_ISO" \
      '[.[] | select(.ts >= $s and .level=="error")] | last | "\(.event): \(.msg)"' 2>/dev/null | cut -c1-160)"
    check events_errors warn "$ev_err error events this week; last: ${last_err:-?}"
  else check events_errors ok "no error events this week ($ev_warn warns)"; fi
  [ -n "$recurring" ] && check recurring_errors warn "recurring error/warn signatures this week: $recurring" \
    || check recurring_errors ok "no recurring error/warn signatures"

  # Every error event from past runs (heartbeats included) grouped into
  # signatures, so the agent diagnoses classes instead of single lines: for
  # `tool_failure` the command text is stripped and the tool name kept; for the
  # rest (`skill_install`, `nudge_send`, `gh_api`, …) the whole message is the
  # signature. Volatile bits (SHAs, numbers, /tmp paths) are normalized so one
  # root cause collapses to one row however often it recurred. `first`/`last`
  # bound each signature in time — a signature whose `last` predates a fix is
  # already resolved and must not be re-reported. Emitted as `failures` for the
  # agent's diagnosis pass (docs/audit.md task 3).
  FAILURES='[]'
  if ls "$LOG_DIR"/events-*.jsonl >/dev/null 2>&1; then
    FAILURES="$(week_events | jq -s --arg s "$SINCE_ISO" '
      def norm: gsub("[0-9a-f]{7,40}";"<sha>") | gsub("[0-9]+";"<n>")
              | gsub("/tmp/[^ ]*";"<tmp>") | gsub("\\s+";" ") | .[0:120];
      [ .[] | select(.ts >= $s and .level=="error")
            | . as $e
            | { ts, event,
                tool: (if $e.event == "tool_failure"
                       then (($e.msg // "") | (capture("^(?<t>[A-Za-z_]+)")?.t // "?"))
                       else null end),
                err:  (($e.msg // "")
                       | (if $e.event == "tool_failure"
                          then ( (capture("\\]: (?<e>.*)$")?.e)
                                 // (capture("^[A-Za-z_]+: (?<e>.*)$")?.e) // . )
                          else . end)
                       | norm ) } ]
      | group_by([.event, (.tool // ""), .err])
      | map({ event: .[0].event, tool: .[0].tool, error: .[0].err, count: length,
              first: (min_by(.ts).ts), last: (max_by(.ts).ts) })
      | sort_by(-.count) | .[:15]' 2>/dev/null)"
    [ -z "$FAILURES" ] && FAILURES='[]'
  fi
  f_groups="$(printf '%s' "$FAILURES" | jq 'length' 2>/dev/null || echo 0)"
  f_total="$(printf '%s' "$FAILURES" | jq '[.[].count] | add // 0' 2>/dev/null || echo 0)"
  if [ "${f_groups:-0}" -gt 0 ]; then
    check failures warn "$f_total error events in $f_groups signature(s) this week — diagnose each (docs/audit.md task 3)"
  elif [ "${ev_err:-0}" -gt 0 ]; then
    # ev_err counted errors but grouping produced none: the jq pass broke, and a
    # silent "all clear" would hide exactly what this check exists to surface.
    check failures warn "$ev_err error events counted but could not be grouped — read work/logs/ directly (docs/logging.md)"
  else check failures ok "no error events this week"; fi

  # weekly token totals from `tokens` events (best-effort; msg format written
  # by harness/claude-code/log-session-tokens.sh — keep the capture in sync).
  # `by_model` splits the same counters per recorded model id, which is what
  # prices a week (docs/trends.md → Cost); events written before the hook
  # recorded a model land under "unknown" and price as "—", never as a guess.
  TOKENS_WEEK="$(week_events | jq -rs --arg s "$SINCE_ISO" '
    def sums: {runs: length, input: ([.[].i | tonumber] | add // 0), output: ([.[].o | tonumber] | add // 0),
               cache_read: ([.[].cr | tonumber] | add // 0), cache_creation: ([.[].cc | tonumber] | add // 0)};
    [.[] | select(.ts >= $s and .event=="tokens") | .msg
     | capture("input=(?<i>[0-9]+) output=(?<o>[0-9]+) cache_read=(?<cr>[0-9]+) cache_creation=(?<cc>[0-9]+)( +msgs=[0-9]+)?( +model=(?<m>[^ ]+))?")]
    | sums + {by_model: (group_by(.m // "unknown")
                         | map({key: (.[0].m // "unknown"), value: sums}) | from_entries)}' 2>/dev/null)"
  [ -n "$TOKENS_WEEK" ] || TOKENS_WEEK='{"runs":0}'

  # Wake-ups — the preflight passes that found work, from the `heartbeat`
  # events emit(), survey_out() and bench_out() write: a gated fire that started
  # a session, or an ungated pass (the direct session, the rerun after a broken
  # gate). `by_work.<kind>` counts the runs that carried that work (`runs`) and
  # its items; one run can carry several kinds. `unlabelled` counts woken runs
  # that name no kind: events from before the kind keys.
  WAKEUPS_WEEK="$(week_events | jq -rs --arg s "$SINCE_ISO" '
    [ .[] | select(.ts >= $s and .event=="heartbeat") | .msg
      | [ scan("([a-z_]+)=([^ ]+)") | {key: .[0], value: .[1]} ] | from_entries
      | select(.nothing_to_do == "false") ] as $w
    | ["reviews","mentions","artifacts","nudges","cleanups","alerts","ci","merges","fixes","stall",
       "housekeeping","survey","benchmark"] as $k
    | { runs: ($w | length),
        by_mode: ($w | group_by(.mode) | map({key: (.[0].mode // "unknown"), value: length}) | from_entries),
        by_work: ([ $k[] as $x
                    | {key: $x,
                       value: { runs: ([ $w[] | select(((.[$x] // "0") | tonumber) > 0) ] | length),
                                items: ([ $w[] | (.[$x] // "0") | tonumber ] | add // 0) } } ]
                  | from_entries),
        unlabelled: ([ $w[] | select(all($k[] as $x | (.[$x] // "0") | tonumber; . == 0)) ] | length) }' 2>/dev/null)"
  [ -n "$WAKEUPS_WEEK" ] || WAKEUPS_WEEK='null'

  # Artifacts published this week, from the `artifact` outcome events the
  # artifact step writes (docs/artifact.md step 6). Counted per PR, so a
  # repeated log line cannot inflate the figure. The events survive a prune,
  # which the on-disk HTML and the history markers do not — that is why the
  # count reads the log and not `reviews/pr-artifacts/`.
  # The outcome word is read at its documented position, after the skill name:
  # "… published → DAM X, 0 redacted" is one publish, and counts in
  # `generated` alone.
  # `unreported` is the guard: preflight's own `artifact generate due` lines
  # name every PR that entered the step, so a due PR with no outcome event
  # means the step ran without logging its audit line, and the count below it
  # would silently read as zero. Due lines from the last hour are excluded —
  # that PR is handled by the next heartbeat, not missing.
  ARTIFACTS_WEEK='null'
  if [ -n "$ARTIFACT_SKILL" ]; then
    ART_CUTOFF="$(epoch2iso "$(( NOW_EPOCH - 3600 ))")"
    ARTIFACTS_WEEK="$(week_events | jq -rs --arg s "$SINCE_ISO" --arg cut "$ART_CUTOFF" '
      def prs(f): [ .[] | select(.ts >= $s) | select(f) | .msg
                    | capture("^PR #(?<n>[0-9]+)") | .n ] | unique;
      [ .[] | select(.ts >= $s) | select(.event=="artifact") | .msg
        | capture("^PR #(?<n>[0-9]+): +[^ ]+ +(?<o>published|skipped)") ] as $out
      | def outcome(w): [ $out[] | select(.o == w) | .n ] | unique;
        { generated: (outcome("published") | length),
          skipped:   (outcome("skipped")   | length),
          unreported: ((prs(.event=="preflight" and (.msg|test("artifact generate due")) and .ts <= $cut)
                        - (outcome("published") + outcome("skipped"))) | length) }' 2>/dev/null)"
    [ -n "$ARTIFACTS_WEEK" ] || ARTIFACTS_WEEK='null'
    art_unrep="$(printf '%s' "$ARTIFACTS_WEEK" | jq -r '.unreported // 0' 2>/dev/null)"
    # a broken pass reports unmeasured, never an all-zero literal, which reads
    # as "no artifact was due" and is exactly what this metric must not invent
    if [ "$ARTIFACTS_WEEK" = "null" ]; then
      check artifacts warn "artifact outcomes could not be counted this week — treat stats.artifacts as unmeasured, not zero"
    elif [ "${art_unrep:-0}" -gt 0 ]; then
      check artifacts warn "${art_unrep} artifact generation(s) with no outcome event — the step skipped its audit line, so stats.artifacts.generated is a floor (docs/artifact.md step 6)"
    else check artifacts ok "artifact outcomes logged: $(printf '%s' "$ARTIFACTS_WEEK" | jq -r '"\(.generated) published, \(.skipped) skipped"')"; fi
  fi

  # Wasted-review accounting: a run that locked a PR and never reached a
  # terminal `review_step` threw its work away — the next heartbeat redoes the
  # review at full cost. Classified by cause, deterministically, from the log:
  #   pod_restart  — a `pod_boot` warn falls inside the run's own event window
  #   hard_kill    — no `tokens` event, i.e. the SessionEnd hook never ran
  #   terminated   — SessionEnd ran but the pipeline stopped mid-way (orderly
  #                  shutdown from outside; see docs/audit.md task 28)
  # `aborted_clean` counts runs that *did* terminate explicitly — the cheap
  # outcome the Stop hook drives, so a rise here against falling `stalled` is
  # the mitigation working, not a regression.
  # One jq pass over the same files; no API calls, no extra run.
  # a run whose last event is newer than the lock TTL may still be alive
  # (no SessionEnd yet is not a kill) — exclude it rather than miscount it
  STALL_CUTOFF="$(epoch2iso "$(( NOW_EPOCH - LOCK_TTL_MIN * 60 ))")"
  STALLS_WEEK="$(week_events | jq -rs --arg s "$SINCE_ISO" --arg cut "$STALL_CUTOFF" '
    [.[] | select(.ts >= $s)] as $w
    | ($w | map(select(.event=="pod_boot") | .ts)) as $boots
    | [ $w | group_by(.run)[]
        | { run: .[0].run, day: (.[0].ts[0:10]), first: (.[0].ts), last: (.[-1].ts),
            steps: [.[] | select(.event=="review_step") | .msg
                    | select(startswith("PR #"))],
            tokens: ([.[] | select(.event=="tokens")] | length),
            out: ([.[] | select(.event=="tokens") | .msg
                   | capture("output=(?<o>[0-9]+)") | .o | tonumber] | add // 0) }
        | select(.steps | any(test(" locked")))
        | select(.last <= $cut)
        | .first as $first_ts | .last as $last_ts
        | .prs = [ .steps[] | capture("^PR #(?<n>[0-9]+)") | .n ]
        | .terminal = (.steps | any(test("(^| )(done|aborted)") and (test("skill:") | not)))
        | .aborted  = (.steps | any(test("(^| )aborted")))
        | .cause = (if .terminal then "ok"
                    elif ([$boots[] | select(. >= $first_ts and . <= $last_ts)] | length > 0)
                      then "pod_restart"
                    elif (.tokens == 0) then "hard_kill"
                    else "terminated" end) ]
    as $runs
    | { total: ($runs | length),
        stalled: ($runs | map(select(.cause != "ok")) | length),
        aborted_clean: ($runs | map(select(.terminal and .aborted)) | length),
        by_cause: ($runs | map(select(.cause != "ok") | .cause) | group_by(.)
                   | map({key: .[0], value: length}) | from_entries),
        wasted_output_tokens: ($runs | map(select(.cause != "ok") | .out) | add // 0),
        redone_prs: ($runs | map(select(.cause != "ok") | .prs) | flatten | unique),
        per_day: ($runs | group_by(.day)
                  | map({ day: .[0].day, runs: length,
                          stalled: (map(select(.cause != "ok")) | length),
                          wasted_output_tokens: (map(select(.cause != "ok") | .out) | add // 0) })) }' \
    2>/dev/null)"
  [ -n "$STALLS_WEEK" ] || STALLS_WEEK='{"total":0,"stalled":0}'

  if [ "${CLAUDECODE:-}" = "1" ]; then
    hooks_missing=""
    for h in log-tool-event.sh log-review-step.sh log-session-tokens.sh enforce-review-completion.sh; do
      grep -q "harness/claude-code/$h" "$HOME_DIR/.claude/settings.json" 2>/dev/null \
        || hooks_missing="$hooks_missing $h"
    done
    # the tracking-issue rule names definition_repo: rules written before it
    # was configured, or for another slug, are stale
    am_def="$(cfg definition_repo)"; am_def="${am_def#github.com/}"
    jq -e --arg d "$am_def" '([.autoMode.environment[]?, .autoMode.allow[]? | strings | select(startswith("[code-guardian]"))] | length > 0)
        and ($d == "" or ([.autoMode.allow[]? | strings | select(startswith("[code-guardian]") and contains($d))] | length > 0))' \
      "$HOME_DIR/.claude/settings.json" >/dev/null 2>&1 || hooks_missing="$hooks_missing autoMode-rules"
    # the tool deny list and the review-skill agent: install.sh owns both
    trim_missing="$(HOME="$HOME_DIR" bash "$SCRIPT_DIR/harness/claude-code/install.sh" --check 2>/dev/null)"
    [ -n "$trim_missing" ] && hooks_missing="$hooks_missing $trim_missing"
    if [ -z "$hooks_missing" ]; then
      check harness_adapter ok "Claude Code hooks, auto-mode rules, tool deny list and review-skill agent installed (tool logging + review-completion enforcement)"
    else
      check harness_adapter warn "Claude Code adapter not current:$hooks_missing — run scripts/harness/claude-code/install.sh"
    fi
  else
    check harness_adapter ok "non-Claude-Code harness — manual tool-failure logging applies (docs/logging.md)"
  fi

  # retention: weekly cleanup keeping >= 14 days (files are 14-21 days old when
  # deleted). The line-log trim below is read->tmp->mv: a heartbeat appending in
  # that window loses its line — accepted best-effort, one cadence data point.
  removed=0
  [ -d "$LOG_DIR" ] && removed="$(find "$LOG_DIR" -name 'events-*.jsonl' -mtime +14 -print -delete 2>/dev/null | grep -c . || true)"
  KEEP_EPOCH=$((NOW_EPOCH - 14*86400))
  for lf in "$WORK/HEARTBEAT.log" "$WORK/SHEPHERD.log"; do
    [ -f "$lf" ] || continue
    : > "$lf.tmp"
    while IFS= read -r line; do
      e="$(iso2epoch "${line%% *}")"
      { [ "$e" -eq 0 ] || [ "$e" -ge "$KEEP_EPOCH" ]; } && printf '%s\n' "$line" >> "$lf.tmp"
    done < "$lf"
    mv "$lf.tmp" "$lf"
  done
  # mention ledger: rows older than 14d fall outside the 7-day scan window and
  # can never be re-emitted — drop them (header/unparseable lines are kept)
  if [ -f "$WORK/MENTIONS.md" ]; then
    : > "$WORK/MENTIONS.md.tmp"
    while IFS= read -r line; do
      ts="$(printf '%s' "$line" | cut -d'|' -f4 | tr -d ' ')"
      e="$(iso2epoch "$ts")"
      { [ "$e" -eq 0 ] || [ "$e" -ge "$KEEP_EPOCH" ]; } && printf '%s\n' "$line" >> "$WORK/MENTIONS.md.tmp"
    done < "$WORK/MENTIONS.md"
    mv "$WORK/MENTIONS.md.tmp" "$WORK/MENTIONS.md"
  fi
  # the review ledger and the PR facts: 180 days, not 14 — they are the only
  # record of a merged PR's reviews and facts once pruning removed the history
  # file, and the trend backfill reads back over past weeks (docs/audit.md task
  # 33). Rewritten in one jq pass each (the files outgrow a line-by-line loop)
  # with the same append-during-rewrite caveat as above.
  lk="$(epoch2iso "$(( NOW_EPOCH - 180*86400 ))")"
  for f in "$LEDGER" "$PR_EVENTS"; do
    [ -f "$f" ] && [ -n "$lk" ] || continue
    if jq -c --arg k "$lk" 'select(type == "object" and (.ts // "") >= $k)' "$f" > "$f.tmp" 2>/dev/null; then
      mv "$f.tmp" "$f"
    else
      rm -f "$f.tmp"
    fi
  done
  logev info log_cleanup "retention: removed $removed events file(s) older than 14d, trimmed HEARTBEAT/SHEPHERD and the mention ledger to 14d, the review ledger and the PR facts to 180d"

  # --- 7-day stats -----------------------------------------------------------
  # Volume, verdicts and findings all come from the same week of review records
  # (lib/review-records.sh): the append-only ledger, unioned with the history
  # files still on disk. Counting the files alone measured "reviews on the PRs
  # that are still open" — pruning deletes a merged PR's file, and with it the
  # week it was reviewed in (docs/review-mechanics.md → **Review ledger**).
  if [ "$RR_LIB" -eq 1 ]; then
    REVIEWS_AGG="$(review_records "$WORK/reviews" "$LEDGER" "$SINCE_ISO" | jq -sc "$RR_AGG_JQ" 2>/dev/null)"
    [ -n "$REVIEWS_AGG" ] || REVIEWS_AGG="$RR_AGG_ZERO"
  else
    # the lib is what defines RR_AGG_ZERO, so this branch carries its own copy
    REVIEWS_AGG='{"reviews":{"total":0,"first":0,"re_review":0,"prs":0,"approve":0,"comment":0,"request_changes":0},"findings":{"fixed":0,"still_present":0,"json_reviews":0,"new":0,"late":0,"new_by_severity":{},"by_severity":{}},"suppressed":{"reviews":0,"overrides":0,"context":0,"decisions":0,"total":0},"ste":{"reviews":0,"sentences":0,"sentences_over_20":0,"avg_sentence_words":null,"over_20_share":null}}'
    logev warn review_ledger "lib/review-records.sh unreadable — the week's review counts are reported as zero, not measured"
  fi
  # shepherd activity: ledger rows whose `last_nudge_at` falls in the window —
  # one row per PR, so this is *PRs nudged*, the set task 15 measures against.
  # SHEPHERD.log's "N nudges due" lines count a PR again on every sweep it stays
  # due and count sends that failed, so they are not this number.
  nudged_prs=""
  while IFS= read -r row; do
    ts="$(row_field "$row" 7)"
    case "$ts" in ('-'|'') continue;; esac
    [ "$(iso2epoch "$ts")" -ge "$SINCE_EPOCH" ] || continue
    nudged_prs="$nudged_prs $(row_field "$row" 2)"
  done < <(grep -E '^\| *[0-9]+ *\|' "$SHEPHERD" 2>/dev/null || true)
  NUDGED_JSON="$(printf '%s\n' $nudged_prs | jq -R . | jq -sc '[.[] | select(length>0)]')"

  # review wall-clock per (run, PR): first `locked` -> `done`, from this week's
  # own review_step events. Time-to-first-review (docs/audit.md task 22) is
  # queue wait + this; without it a slow median cannot be attributed to either.
  REVIEW_DUR="$(week_events | jq -rs --arg s "$SINCE_ISO" "$STATS_JQ"'
    review_steps($s)
    | group_by([.run, .pr])
    | map({ locked: ([.[] | select(.rest | startswith("locked")) | .ts] | min),
            done:   ([.[] | select(.rest | startswith("done"))   | .ts] | max) })
    | map(select(.locked != null and .done != null)
          | (((.done | epoch) - (.locked | epoch)) / 60 | floor))
    | { n: length, median_min: median(floor) }' 2>/dev/null)"
  [ -n "$REVIEW_DUR" ] || REVIEW_DUR='{"n":0,"median_min":null}'

  # the week is counted twice, from two independent sources: reviews from the
  # ledger, durations from `review_step` events. They must stay comparable — a
  # ledger that stopped being appended to, or lost rows, shows up here instead
  # of as a metric that quietly shrinks (docs/review-mechanics.md → **Review ledger**).
  rv_n="$(printf '%s' "$REVIEWS_AGG" | jq -r '.reviews.total // 0')"
  dur_n="$(printf '%s' "$REVIEW_DUR" | jq -r '.n // 0')"
  if [ "${dur_n:-0}" -ge 10 ] && [ $(( ${rv_n:-0} * 2 )) -lt "$dur_n" ]; then
    check review_ledger warn "$rv_n review(s) on record against $dur_n completed review run(s) in the log — treat stats.reviews and stats.findings as a floor (docs/review-mechanics.md → Review ledger)"
  else
    check review_ledger ok "$rv_n review(s) on record, $dur_n completed review run(s) in the log"
  fi

  # the STE sentence bar on the week's own posted reviews (docs/review.md →
  # **The sentence bar is 20 words**). Only ledger rows carry the measurement,
  # so a week with none is reported as unmeasured and never as a pass.
  ste_n="$(printf '%s' "$REVIEWS_AGG" | jq -r '.ste.reviews // 0')"
  if [ "${ste_n:-0}" -eq 0 ]; then
    check review_style ok "no posted review carried a style measurement this week"
  else
    ste_avg="$(printf '%s' "$REVIEWS_AGG" | jq -r '.ste.avg_sentence_words // 0')"
    ste_over="$(printf '%s' "$REVIEWS_AGG" | jq -r '.ste.sentences_over_20 // 0')"
    ste_sent="$(printf '%s' "$REVIEWS_AGG" | jq -r '.ste.sentences // 0')"
    # jq compares the share: an empty or non-numeric one is never over the bar
    if printf '%s' "$REVIEWS_AGG" | jq -e '(.ste.over_20_share // 0) | ((type == "number") and (. > 0.15))' >/dev/null 2>&1; then
      check review_style warn "$ste_over of $ste_sent sentence(s) over 20 words in $ste_n review(s), average $ste_avg — rewrite the long ones (docs/review.md → The sentence bar is 20 words)"
    else
      check review_style ok "$ste_over of $ste_sent sentence(s) over 20 words in $ste_n review(s), average $ste_avg"
    fi
  fi

  # the same events, split per phase of the per-PR sequence (docs/review.md →
  # Progress logging): a median that grew is attributable to the phase that
  # grew it, instead of hiding inside one `verified` -> `posted` interval. A
  # phase whose bounding milestone is missing is not counted, never zero.
  REVIEW_PHASES="$(week_events | jq -rs --arg s "$SINCE_ISO" "$STATS_JQ"'
    def at($g; $step): [ $g[] | select(.rest | startswith($step)) | .ts ] | min;
    def span($g; $from; $to): at($g; $from) as $a | at($g; $to) as $b
      | if $a == null or $b == null then null
        else ((($b | epoch) - ($a | epoch)) / 60 | floor) end;
    review_steps($s)
    | map(select(.rest | startswith("locked (refresh") | not))
    | group_by([.run, .pr])
    | map(. as $g
          | { prepare:     span($g; "locked"; "cloned"),
              diff_review: span($g; "cloned"; "fanned out"),
              skills:      span($g; "fanned out"; "verified"),
              delta:       span($g; "verified"; "delta settled"),
              compose:     (span($g; "delta settled"; "composed") // span($g; "verified"; "composed")),
              post:        span($g; "composed"; "posted") }) as $r
    | [ "prepare", "diff_review", "skills", "delta", "compose", "post" ]
    | map(. as $k | { key: $k, value: ([ $r[] | .[$k] | select(. != null) ]
                                       | { n: length, median_min: median(floor) }) })
    | from_entries' 2>/dev/null)"
  [ -n "$REVIEW_PHASES" ] || REVIEW_PHASES='{}'

  # reaction feedback on the bot's comments — 👍/👎 sums over the latest 100
  # inline + 100 issue comments (the two surfaces whose REST list endpoints
  # carry reactions); the agent examines down_urls (docs/audit.md)
  REACTIONS='{"up":0,"down":0,"down_urls":[],"scanned":0}'
  if [ -n "$BOT_LOGIN" ]; then
    rrc="$(gh api "repos/$REPO/pulls/comments?per_page=100&sort=created&direction=desc" 2>/dev/null)"
    ric="$(gh api "repos/$REPO/issues/comments?per_page=100&sort=created&direction=desc" 2>/dev/null)"
    # an unusable read is remembered, not smoothed into an empty list: `[]` from
    # the API is a measured zero, a faulted body is not
    rx_bad=0
    { printf '%s' "$rrc" | jq -e 'type=="array"' >/dev/null 2>&1; } || { rrc='[]'; rx_bad=1; }
    { printf '%s' "$ric" | jq -e 'type=="array"' >/dev/null 2>&1; } || { ric='[]'; rx_bad=1; }
    # stdin, not argv: two pages of comments are ~768 KB, and Linux caps a
    # SINGLE argument at MAX_ARG_STRLEN (128 KiB) regardless of the much larger
    # ARG_MAX, so --argjson made execve fail with "Argument list too long" and
    # the scan silently returned nothing on every busy week.
    REACTIONS="$(printf '%s\n%s\n' "$rrc" "$ric" | jq -s --arg bot "$BOT_LOGIN" '
      [ (.[0] + .[1])[] | select((.user.login // "") == $bot) ]
      | {up: (map(.reactions["+1"] // 0) | add // 0),
         down: (map(.reactions["-1"] // 0) | add // 0),
         down_urls: (map(select((.reactions["-1"] // 0) > 0) | .html_url) | .[0:10]),
         scanned: length}' 2>/dev/null)"
    # a failed scan reports scanned:null — never an all-zero literal, which is
    # indistinguishable from a genuine zero and reads as "no reactions"
    if [ -z "$REACTIONS" ] || [ "$rx_bad" -eq 1 ]; then
      REACTIONS='{"up":0,"down":0,"down_urls":[],"scanned":null}'
      logev warn reaction_scan "reaction feedback unreadable — stats.reactions.scanned is null, not a measured zero"
    fi
    # the scan is only useful if it can fail loudly: a null `scanned` becomes a
    # warn the report must carry, so a dead check can never read as a clean zero
    if [ "$(printf '%s' "$REACTIONS" | jq -r '.scanned')" = "null" ]; then
      check reaction_scan warn "reaction feedback could not be read this week — treat stats.reactions as unmeasured, not zero"
    fi
  fi

  # trend artifact currency: the weekly append is the only writer of
  # work/audit/weeks/, so a history that stopped growing means the audit's
  # task 36 stopped running (docs/trends.md). A never-appended history is
  # info — the first audit after the upgrade creates it.
  TREND_DIR="$WORK/audit/weeks"
  trend_n=0
  [ -d "$TREND_DIR" ] && trend_n="$(ls "$TREND_DIR"/*.json 2>/dev/null | grep -c . || true)"
  if [ "${trend_n:-0}" -eq 0 ]; then
    check audit_trend ok "no trend history yet — this audit's append creates work/audit/weeks/ (docs/trends.md)"
  elif [ -z "$(find "$TREND_DIR" -name '*.json' -mtime -10 -print 2>/dev/null | head -1)" ]; then
    check audit_trend warn "$trend_n week(s) on record but none appended in 10 days — the audit's trend step stopped (docs/trends.md)"
  else
    check audit_trend ok "$trend_n week(s) on record, appended within 10 days"
  fi

  # awaiting_label backlog: rows parked on the one-time flip, waiting for a
  # human re-review trigger (docs/audit.md task 25) — count plus the age of the
  # oldest row, both read from the rows the flip already maintains.
  al_n=0; al_oldest_epoch=0
  while IFS= read -r row; do
    [ "$(row_field "$row" 6)" = "awaiting_label" ] || continue
    al_n=$((al_n+1))
    e="$(iso2epoch "$(row_field "$row" 4)")"
    { [ "$e" -gt 0 ] && { [ "$al_oldest_epoch" -eq 0 ] || [ "$e" -lt "$al_oldest_epoch" ]; }; } && al_oldest_epoch="$e"
  done < <(grep -E '^\| *[0-9]+ *\|' "$REVIEWS" 2>/dev/null || true)
  if [ "$al_oldest_epoch" -gt 0 ]; then
    AWAITING_JSON="$(jq -n --argjson n "$al_n" --argjson d "$(( (NOW_EPOCH - al_oldest_epoch) / 86400 ))" \
      '{n:$n, oldest_days:$d}')"
  else AWAITING_JSON="$(jq -n --argjson n "$al_n" '{n:$n, oldest_days:null}')"; fi

  # --- project health: the repository's week, not the agent's (docs/audit.md
  # → task 33). Local state plus one list call; every figure that was not
  # measured stays null, never zero.
  # the records reader is optional (its lib may be unreadable — the stats block
  # above says so), so both callers below go through this guard
  rr_week() {
    command -v review_records >/dev/null 2>&1 || return 0
    review_records "$WORK/reviews" "$LEDGER" "$SINCE_ISO" 2>/dev/null
  }
  # coverage — PRs merged this week against the ones this agent reviewed
  merged_nums="$(gh api "repos/$REPO/pulls?state=closed&sort=updated&direction=desc&per_page=100" 2>/dev/null \
    | jq -r --arg s "$SINCE_ISO" '[.[] | select(.merged_at != null and .merged_at >= $s) | .number] | .[]' 2>/dev/null)"
  if [ -n "$merged_nums" ]; then
    reviewed_list="$(rr_week | jq -rs '[.[] | .pr] | unique | .[]' 2>/dev/null)"
    m_total=0; m_reviewed=0
    for mn in $merged_nums; do
      m_total=$((m_total + 1))
      printf '%s\n' "$reviewed_list" | grep -qx "$mn" && m_reviewed=$((m_reviewed + 1))
    done
    COVERAGE="$(jq -n --argjson m "$m_total" --argjson r "$m_reviewed" \
      '{merged:$m, reviewed:$r, share:(if $m == 0 then null else (($r / $m * 100) | round) end)}')"
  else
    COVERAGE='{"merged":0,"reviewed":0,"share":null}'
  fi

  # PR size — from the ledger rows of the week, first reviews only, so a PR is
  # measured once however often it came back
  PR_SIZE="$(rr_week | jq -sc "$STATS_JQ"'
      [.[] | select(.kind == "first") | .size | select(type == "object")] as $s
      | { n: ($s | length),
          median_files: ([$s[] | .files | select(type == "number")] | median(round)),
          median_lines: ([$s[] | select((.additions | type) == "number" and (.deletions | type) == "number")
                              | (.additions + .deletions)] | median(round)) }' 2>/dev/null)"
  case "$PR_SIZE" in (''|null) PR_SIZE='{"n":0,"median_files":null,"median_lines":null}';; esac

  # human review latency and conflict incidence — the append-only PR facts the
  # shepherd records, which outlive the pruned ledger row
  PROJECT_EVENTS="$(jq -sc --arg s "$SINCE_ISO" "$STATS_JQ"'
      [.[] | select(type == "object" and .ts >= $s)] as $e
      | { human_latency: ([$e[] | select(.kind == "first_review") | .latency_hours
                                | select(type == "number")]
                          | { n: length, median_hours: median(round) }),
          conflicts: ([$e[] | select(.kind == "conflict") | .pr] | unique | length) }' \
    "$PR_EVENTS" 2>/dev/null)"
  case "$PROJECT_EVENTS" in (''|null) PROJECT_EVENTS='{"human_latency":{"n":0,"median_hours":null},"conflicts":0}';; esac

  # where the findings sit — the profile's own per-directory history, read
  # locally; orientation for the report, never a claim about the live code
  HOT_AREAS="$(jq -c '
      [ (.history.dirs // [])[]
        | { dir, critical: (.critical // 0), warning: (.warning // 0),
            still: (.still // 0) }
        | select(.critical + .warning > 0) ]
      | sort_by(-(.critical * 10 + .warning)) | .[0:3]' \
    "$WORK/PROFILE.json" 2>/dev/null)"
  case "$HOT_AREAS" in (''|null) HOT_AREAS='[]';; esac

  PROJECT_JSON="$(jq -nc --argjson cov "$COVERAGE" --argjson size "$PR_SIZE" \
    --argjson ev "$PROJECT_EVENTS" --argjson hot "$HOT_AREAS" \
    '{coverage:$cov, pr_size:$size, human_latency:$ev.human_latency,
      conflicts:$ev.conflicts, hot_areas:$hot}')"

  STATS="$(jq -n --arg since "$SINCE_ISO" \
    --argjson al "$AWAITING_JSON" \
    --argjson open "$OPEN_COUNT" --argjson ra "$REVIEWS_AGG" \
    --argjson dur "$REVIEW_DUR" --argjson ph "$REVIEW_PHASES" \
    --argjson hb "$hb_total" --argjson idle "$hb_idle" --argjson np "$NUDGED_JSON" \
    --argjson le "$ev_err" --argjson lw "$ev_warn" --argjson tw "$TOKENS_WEEK" \
    --argjson sw "$STALLS_WEEK" --argjson rx "$REACTIONS" --argjson art "$ARTIFACTS_WEEK" \
    --argjson proj "$PROJECT_JSON" --argjson wk "$WAKEUPS_WEEK" \
    '{since:$since, open_prs:$open, awaiting_label:$al,
      reviews:($ra.reviews + {duration:$dur, phases:$ph}),
      findings:$ra.findings, suppressed:($ra.suppressed // null), ste:($ra.ste // null),
      heartbeats:{total:$hb, idle:$idle}, wakeups:$wk, nudges:{prs_nudged:($np|length), prs:$np},
      artifacts:$art,
      log_events:{errors:$le, warns:$lw}, tokens:$tw, stalls:$sw, reactions:$rx,
      project:$proj}')"

  # wording note: never write the substring "fail"/"error" into this line —
  # the next audit's log_errors grep would flag it as a false positive
  printf '%s\n' "$NOW_ISO audit nothing_to_do=false checks=$(printf '%s' "$CHECKS" | jq length) red=$(printf '%s' "$CHECKS" | jq '[.[]|select(.status=="fail")]|length')" >> "$WORK/HEARTBEAT.log" 2>/dev/null
  AUDIT_JSON="$(jq -n --argjson stats "$STATS" --argjson checks "$CHECKS" \
    --argjson failures "${FAILURES:-[]}" \
    --argjson logs "$(printf '%s\n' "${LOGS[@]:-}" | jq -R . | jq -s '[.[] | select(length>0)]')" \
    '{mode:"audit", nothing_to_do:false, stats:$stats, checks:$checks,
      failures:$failures, logs:$logs}')"
  # bookkeeping: the same worklist on disk is the trend artifact's input, so a
  # week's numbers reach work/audit/ without passing through the agent
  # (docs/trends.md). Overwritten every audit; the week files are the record.
  mkdir -p "$WORK/audit" 2>/dev/null \
    && printf '%s\n' "$AUDIT_JSON" > "$WORK/audit/last-worklist.json" 2>/dev/null
  printf '%s\n' "$AUDIT_JSON"
  exit 0
fi

fail_out "unknown mode '$MODE' (use review|shepherd|audit|benchmark|survey|memory)"
