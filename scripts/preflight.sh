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
#   - writes locally only: the REVIEWS.md `done`->`awaiting_label` status flip
#     (pure bookkeeping mandated by the re-review trigger gate — keeps
#     transition logs one-shot), shepherd-ledger bookkeeping for rows with no
#     nudge due,
#     HEARTBEAT.log / SHEPHERD.log lines, structured events in work/logs/
#     (via scripts/log.sh — docs/logging.md), the skill install cache, the
#     git credential helper (`gh auth setup-git`, before the agent clones), and
#     the audit-mode cleanups (14-day log retention, stale-clone sweep).
#
#   preflight.sh review    -> reviews_due / label_cleanups_due / selfheals_due
#                             / prunes_due / status_resets_due / artifacts_due
#                             / urgent_alerts_due
#                             / mentions_due (comments addressed to the bot,
#                             deduped against work/MENTIONS.md)
#                             (+ skill install, SHA-cached, only when a
#                             review/artifact is due)
#   preflight.sh shepherd  -> nudges_due (classification + age gate + cooldown
#                             + escalation ladder + merge-conflict flag already
#                             computed; the agent applies each row_update right
#                             after its send)
#   preflight.sh audit     -> weekly health check: 7-day stats + deterministic
#                             checks (auth, state consistency, log gaps/errors,
#                             orphaned gists, disk, skills); the agent adds the
#                             judgment checks and sends the report (docs/audit.md)
#   preflight.sh benchmark -> benchmark_due (create_fixture | run) when
#                             `benchmark: enabled` and the monthly gate passes
#                             (docs/benchmark.md); purely local, no API calls
#
# Output: a single JSON object on stdout. Agent contract:
#   .nothing_to_do == true  -> end the run immediately.
#   otherwise               -> process the arrays per CLAUDE.md + docs/.
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
SHEPHERD="$WORK/SHEPHERD.md"
DEVELOPERS="$WORK/DEVELOPERS.md"
SKILL_CACHE="$HOME_DIR/.claude/skills/.cache"
NOW_EPOCH=$(date -u +%s)
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# structured events log (docs/logging.md); no-op fallback keeps set -u safe
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_JOB="$MODE"
if ! . "$SCRIPT_DIR/log.sh" 2>/dev/null; then logev() { :; }; fi
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

# A CONFIG value is the text after `- <key>: `, minus a trailing comment and
# minus one layer of markdown quoting (`value`, "value") — writers reach for
# backticks, and the quoted form must resolve to the same value.
cfg() { sed -n "s/^- $1:[[:space:]]*//p" "$CONFIG" 2>/dev/null | head -1 \
        | sed -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//' \
              -e 's/^[`"'"'"']//' -e 's/[`"'"'"']$//'; }

trim() { printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

# Emit the table rows of one `## <heading>` CONFIG section, stopping at the next
# `## ` heading — an unbounded `,$p` range would swallow the sections that follow
# (e.g. `## Watch rules` rows parsed as skills). Header/separator rows are the
# caller's to skip.
cfg_table() { sed -n "/^## $1\$/,\${ /^## $1\$/d; /^## /q; p; }" "$CONFIG" 2>/dev/null | grep -E '^\|'; }

# GNU first; the BSD fallback needs -u or the trailing Z is read as local time
iso2epoch() { date -d "$1" +%s 2>/dev/null || date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || echo 0; }

# Every repo reference is `[<host>/]<owner>/<repo>`: three segments name the
# host, two use the ambient default. DEFAULT_HOST is captured before GH_HOST is
# re-exported in the config section, so each reference resolves independently.
DEFAULT_HOST="${GH_HOST:-github.com}"
refhost() { case "$1" in (*/*/*) printf '%s' "${1%%/*}";; (*) printf '%s' "$DEFAULT_HOST";; esac; }
refslug() { case "$1" in (*/*/*) printf '%s' "${1#*/}";;  (*) printf '%s' "$1";; esac; }

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
    logev info heartbeat "mode=benchmark nothing_to_do=$1"
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
  # report surfaces: same host semantics as artifact_targets — gist renders
  # through an external service that only reaches github.com, so it is
  # dropped on any other target host (resolved without any gh fallback)
  BENCH_REPORT="$(cfg benchmark_report)"; BENCH_REPORT="${BENCH_REPORT:-gist}"
  BENCH_HOST="$(refhost "${GITHUB_REPO:-$(cfg github_repo)}")"
  EFF_REPORT=""
  for t in $(printf '%s' "$BENCH_REPORT" | tr ',' ' '); do
    case "$t" in (off|'') continue;; esac
    { [ "$t" = "gist" ] && [ "$BENCH_HOST" != "github.com" ]; } \
      && { log "benchmark_report surface gist dropped (target host $BENCH_HOST)"; continue; }
    EFF_REPORT="${EFF_REPORT:+$EFF_REPORT,}$t"
  done
  EFF_REPORT="${EFF_REPORT:-off}"
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

# Is the session holding PR #<n>'s lock still working? Two local signals, no API
# call: a `review_step … PR #<n> … locked` event identifies the holder's run id,
# and any later event from that run proves it alive. Falls back to the newest
# event of any run touching this PR when the run id can't be pinned. Prints the
# holder's run id (8 chars) + minutes since its last event, or nothing when no
# evidence of life is found. docs/review.md → **Live holder**.
holder_alive() { # <pr-number> <lock-ts>
  local n="$1" lock_ts="$2" cutoff_epoch cutoff
  cutoff_epoch=$(( NOW_EPOCH - HOLDER_QUIET_MIN * 60 ))
  cutoff="$(date -u -d "@$cutoff_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
            || date -u -r "$cutoff_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || return 1
  ls "$LOG_DIR"/events-*.jsonl >/dev/null 2>&1 || return 1
  # The `.ts >= $lock` filter bounds the scan by the lock itself, so reading the
  # whole retained set costs one pass and needs no date arithmetic. `fromjson?`
  # drops the partial line a concurrently-writing session may leave.
  cat "$LOG_DIR"/events-*.jsonl 2>/dev/null \
    | jq -c -R 'fromjson? // empty' 2>/dev/null \
    | jq -rs --arg n "PR #$n " --arg lock "$lock_ts" --arg cut "$cutoff" --argjson now "$NOW_EPOCH" '
        [ .[] | select(.ts >= $lock) ] as $since
        | ( [ $since[] | select(.event == "review_step" and (.msg | startswith($n))
              and (.msg | test("locked"))) ] | last | .run ) as $holder
        | ( if $holder then [ $since[] | select(.run == $holder) ]
            else [ $since[] | select(.msg | contains($n)) ] end ) as $ev
        | ( $ev | last ) as $l
        | if $l and $l.ts >= $cut
          then "\($l.run[0:8]) \((($now - (($l.ts[0:19] + "Z") | fromdateiso8601)) / 60) | floor)"
          else empty end' 2>/dev/null
}

# ---------------------------------------------------------------- config ----
TARGET_REF="${GITHUB_REPO:-$(cfg github_repo)}"
[ -z "$TARGET_REF" ] && TARGET_REF="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)"
REPO_HOST="$(refhost "$TARGET_REF")"; REPO="$(refslug "$TARGET_REF")"
export GH_HOST="$REPO_HOST"   # every unqualified gh call targets the review host
BOT_LOGIN="$(cfg bot_login)"
REVIEW_MARKER="$(cfg review_marker)"
REREVIEW_LABEL="$(cfg rereview_label)"; REREVIEW_LABEL="${REREVIEW_LABEL:-code-guardian-review}"
URGENT_LABEL="$(cfg urgent_label)"   # empty/missing = urgent handling off
ARTIFACT="$(cfg artifact_skill)"
ARTIFACT_SKILL="${ARTIFACT%%@*}"; ARTIFACT_SRC="${ARTIFACT##*@}"
{ [ "$ARTIFACT" = "none" ] || [ -z "$ARTIFACT" ]; } && ARTIFACT_SKILL=""
# `gist` renders through an external service that only reaches github.com, so it
# is dropped on any other target host; no surface left = feature off this run
ARTIFACT_TARGETS="$(cfg artifact_targets)"; ARTIFACT_TARGETS="${ARTIFACT_TARGETS:-gist}"
ARTIFACT_OFF_REASON=""; EFFECTIVE_TARGETS=""
for t in $(printf '%s' "$ARTIFACT_TARGETS" | tr ',' ' '); do
  { [ "$t" = "gist" ] && [ "$REPO_HOST" != "github.com" ]; } && continue
  EFFECTIVE_TARGETS="${EFFECTIVE_TARGETS:+$EFFECTIVE_TARGETS,}$t"
done
if [ -n "$ARTIFACT_SKILL" ] && [ -z "$EFFECTIVE_TARGETS" ]; then
  ARTIFACT_SKILL=""; ARTIFACT_OFF_REASON="no publish surface reachable on $REPO_HOST"
fi
SLACK="$(cfg slack_notifications)"
ESCALATION_OWNER="$(cfg escalation_owner)"
# stalled-review alert threshold: stalls per 24h that trigger one alert (0/off = disabled)
STALL_ALERT_THRESHOLD="$(cfg stall_alert_threshold)"
STALL_ALERT_THRESHOLD="${STALL_ALERT_THRESHOLD:-4}"
case "$STALL_ALERT_THRESHOLD" in
  (off|none) STALL_ALERT_THRESHOLD=0;;
  (*[!0-9]*|'') STALL_ALERT_THRESHOLD=4;;   # unparseable -> documented default
esac
# in-progress lock TTL: minutes after which a lock is *candidate* for takeover.
# Calibrated above the review pipeline's p95 (docs/review.md → Review tracking
# state) — a value under it hands live reviews to a second job.
LOCK_TTL_MIN=50
# a holder that logged anything within this window is alive whatever its lock age
# says. Must exceed the longest gap a healthy review shows between events —
# measured at 16.7 min over real runs (docs/review.md → Live holder)
HOLDER_QUIET_MIN=20
# branch of $DEFINITION_REPO this instance tracks (default main)
DEFINITION_BRANCH="$(cfg definition_branch)"; DEFINITION_BRANCH="${DEFINITION_BRANCH:-main}"
# GitHub progress signal — commit status on the reviewed SHA (docs/review.md)
PROGRESS="$(cfg review_progress)"; PROGRESS="${PROGRESS:-disabled}"
case "$PROGRESS" in
  (enabled|disabled) ;;
  (*) log "review_progress '$PROGRESS' unknown — treating as disabled"; PROGRESS=disabled;;
esac

fail_out() {  # nothing-to-do JSON with an error; the agent just logs it
  logev error preflight "$1"
  jq -n --arg mode "$MODE" --arg err "$1" \
    --argjson logs "$(printf '%s\n' "${LOGS[@]:-}" | jq -R . | jq -s '[.[] | select(length>0)]')" \
    '{mode:$mode, nothing_to_do:true, error:$err, logs:$logs}'
  exit 0
}

[ -z "$REPO" ] && fail_out "target repo unresolved (GITHUB_REPO / CONFIG.md github_repo missing)"
[ -f "$CONFIG" ] || log "work/CONFIG.md missing — running with defaults"

# ------------------------------------------------------------ open PR set ----
OPEN_JSON="$(gh api "repos/$REPO/pulls?state=open&per_page=100" 2>/dev/null)"
[ -z "$OPEN_JSON" ] && fail_out "could not list open PRs (API error) — skipping run"
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
row_field()    { printf '%s' "$1" | cut -d'|' -f"$2" | sed -e 's/^ *//' -e 's/ *$//'; }

# the ONE local REVIEWS.md write the script performs: done -> awaiting_label
# (keeps the last review's SHA/verdict/timestamp; only the status cell changes)
flip_awaiting_label() { # number
  sed -E "s/^(\| *$1 *\|.*\|) *done *\|[[:space:]]*$/\1 awaiting_label |/" "$REVIEWS" \
    > "$REVIEWS.tmp" && mv "$REVIEWS.tmp" "$REVIEWS"
}

# GET with one silent retry, captured per attempt so a failed attempt's error
# body never reaches the caller -> body on stdout; rc 1 after two failed attempts
gh_get() { # <gh api args…>
  local out
  out="$(gh api "$@" 2>/dev/null)" && { printf '%s' "$out"; return 0; }
  sleep 1
  out="$(gh api "$@" 2>/dev/null)" && { printf '%s' "$out"; return 0; }
  return 1
}
# marker scans distinguish three outcomes: a timestamp (marker found), ""
# (endpoints answered, marker verified absent), and the sentinel __api_error__
# (an endpoint failed twice — unknown, never to be treated as absent). Callers
# bump API_ERRS on the sentinel and stop probing once it reaches 2 — by then
# the API is down for the run, and each skipped call costs a retry + sleep.
API_ERRS=0

# marker-based remote dedup, anchored at one SHA -> prints GitHub timestamp
remote_reviewed_at() { # number full_sha
  local m="<!-- $REVIEW_MARKER headRefOid=$2 -->" body ts err=0
  if body="$(gh_get "repos/$REPO/pulls/$1/reviews?per_page=100")"; then
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
  body="$(gh_get "repos/$REPO/pulls/$1/reviews?per_page=100")" || { printf '__api_error__'; return 0; }
  printf '%s' "$body" | jq -r --arg m "<!-- $REVIEW_MARKER headRefOid=" '
        [.[] | select(.body != null) | select(.body | contains($m))
             | {sha: (.body | capture("headRefOid=(?<s>[0-9a-f]{40})").s), ts: .submitted_at}]
        | last // empty | if . == "" or . == null then empty else "\(.sha)\t\(.ts)" end' 2>/dev/null
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

emit() { # reviews label_cleanups selfheals prunes artifacts nudges alerts mentions skills
  local nothing=true a resets="${STATUS_RESETS_DUE:-[]}"
  for a in "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$resets"; do
    [ "$(printf '%s' "$a" | jq length)" -gt 0 ] && nothing=false
  done
  # a due stall alert is work in its own right — never let it be swallowed by an
  # otherwise idle heartbeat
  [ -n "${STALL_ALERT:-}" ] && nothing=false
  printf '%s\n' "$NOW_ISO $MODE nothing_to_do=$nothing ${LOGS[*]:-}" >> "$WORK/HEARTBEAT.log" 2>/dev/null
  logev info heartbeat "mode=$MODE nothing_to_do=$nothing reviews=$(printf '%s' "$1" | jq length) nudges=$(printf '%s' "$6" | jq length) mentions=$(printf '%s' "$8" | jq length)"
  jq -n --arg mode "$MODE" --argjson nothing "$nothing" \
    --argjson reviews "$1" --argjson cleanups "$2" --argjson selfheals "$3" \
    --argjson prunes "$4" --argjson artifacts "$5" --argjson nudges "$6" \
    --argjson alerts "$7" --argjson mentions "$8" --argjson skills "$9" \
    --argjson resets "$resets" --argjson stall "${STALL_ALERT:-null}" \
    --argjson logs "$(printf '%s\n' "${LOGS[@]:-}" | jq -R . | jq -s '[.[] | select(length>0)]')" \
    '{mode:$mode, nothing_to_do:$nothing, reviews_due:$reviews, label_cleanups_due:$cleanups,
      selfheals_due:$selfheals, prunes_due:$prunes, artifacts_due:$artifacts,
      nudges_due:$nudges, urgent_alerts_due:$alerts, mentions_due:$mentions,
      status_resets_due:$resets, skills:$skills, logs:$logs}
     + (if $stall == null then {} else {stall_alert:$stall} end)'
}

# =========================================================== REVIEW MODE ====
if [ "$MODE" = "review" ]; then
  REVIEWS_DUE='[]'; CLEANUPS_DUE='[]'; SELFHEALS_DUE='[]'; PRUNES_DUE='[]'; ARTIFACTS_DUE='[]'; ALERTS_DUE='[]'; MENTIONS_DUE='[]'; SKILLS='{}'
  STATUS_RESETS_DUE='[]'

  # re-review trigger gate (CLAUDE.md -> rereview_trigger): label | review-request | both
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

  add_review() { # number sha ref title author kind takeover prior_json urgent closed full
    # full: complete-review scope — always true for kind=first; on a re-review
    # true iff the label is the trigger (review-request / on-demand = delta)
    REVIEWS_DUE="$(printf '%s' "$REVIEWS_DUE" | jq --argjson e "$(jq -n \
      --argjson n "$1" --arg sha "$2" --arg ref "$3" --arg t "$4" --arg a "$5" \
      --arg k "$6" --argjson tk "$7" --argjson prior "$8" \
      --argjson u "${9:-false}" --argjson c "${10:-false}" --argjson f "${11:-false}" \
      '{number:$n, head_sha:$sha, head_ref:$ref, title:$t, author:$a, kind:$k, takeover:$tk, prior:$prior, urgent:$u, closed:$c, full:$f}')" '. + [$e]')"
    [ "${9:-false}" = "true" ] && [ "${10:-false}" = "false" ] \
      && log "PR #$1: $URGENT_LABEL label — rapid-first review, ordered ahead"
    return 0
  }

  # --- prune detection (verified per PR; the agent executes the prune) ---
  for n in $(reviews_rows | cut -d'|' -f2 | tr -d ' '); do
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
    if [ "$OPEN_COUNT" -eq 0 ]; then log "open PR list empty while rows exist — prune detection skipped (anomaly)"; break; fi
    PJ="$(gh api "repos/$REPO/pulls/$n" 2>/dev/null)"
    state="$(printf '%s' "$PJ" | jq -r 'if .merged then "MERGED" else (.state|ascii_upcase) end' 2>/dev/null)"
    [ -z "$state" ] && logev warn gh_api "PR #$n: state check did not respond — prune skipped this run"
    case "$state" in
      CLOSED|MERGED)
        row="$(row_for "$n")"
        if [ "$(row_field "$row" 5)" = "RAPID" ] && [ "$(row_field "$row" 6)" = "in_progress" ]; then
          # urgent PR closed after the rapid preliminary review but before the
          # full one — the agent still owes the full pass (criticals become a
          # linked issue, docs/review.md); prune happens on the next heartbeat
          kind="first"; [ -f "$WORK/reviews/pr-$n.md" ] && kind="re-review"
          full=false; [ "$kind" = "first" ] && full=true
          prior="$(jq -n --arg sha "$(row_field "$row" 3)" --arg ts "$(row_field "$row" 4)" '{sha:$sha, ts:$ts, verdict:"RAPID"}')"
          add_review "$n" "$(printf '%s' "$PJ" | jq -r .head.sha)" "$(printf '%s' "$PJ" | jq -r .head.ref)" \
            "$(printf '%s' "$PJ" | jq -r '.title|gsub("\t";" ")')" "$(printf '%s' "$PJ" | jq -r .user.login)" \
            "$kind" false "$prior" true true "$full"
          log "PR #$n: $state with rapid review posted but full review owed — closed-PR review due"
        else
          gid="$(grep -o '<!-- artifact-gist: [A-Za-z0-9]* -->' "$WORK/reviews/pr-$n.md" 2>/dev/null | head -1 | cut -d' ' -f3)"
          did="$(grep -o '<!-- artifact-dam: [A-Za-z0-9_-]* -->' "$WORK/reviews/pr-$n.md" 2>/dev/null | head -1 | cut -d' ' -f3)"
          PRUNES_DUE="$(printf '%s' "$PRUNES_DUE" | jq --argjson e "$(jq -n --argjson n "$n" --arg s "$state" --arg g "${gid:-}" --arg d "${did:-}" \
            '{number:$n, state:$s, gist_id:(if $g=="" then null else $g end), dam_id:(if $d=="" then null else $d end)}')" '. + [$e]')"
          log "PR #$n: $state — prune due"
        fi;;
      *) : ;;  # OPEN / API error -> leave the row alone
    esac
  done

  # --- per-open-PR decision ---
  while IFS=$'\t' read -r n sha ref title author labels assignees requested url; do
    has_label=0; [ "$TRIG_LABEL" -eq 1 ] && printf '%s' "$labels" | tr ',' '\n' | grep -qx "$REREVIEW_LABEL" && has_label=1
    has_request=0; [ "$TRIG_REQUEST" -eq 1 ] && printf '%s' "$requested" | tr ',' '\n' | grep -qx "$BOT_LOGIN" && has_request=1
    triggered=0; { [ "$has_label" -eq 1 ] || [ "$has_request" -eq 1 ]; } && triggered=1
    URG=false; [ -n "$URGENT_LABEL" ] && printf '%s' "$labels" | tr ',' '\n' | grep -qx "$URGENT_LABEL" && URG=true

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
          # what destroys a complete fan-out. docs/review.md → **Live holder**.
          log "PR #$n: lock past TTL (${age}m) but holder ${alive%% *} active ${alive##* }m ago — left running"
        else
          kind="first"; [ -f "$WORK/reviews/pr-$n.md" ] && kind="re-review"
          full=false; { [ "$kind" = "first" ] || [ "$has_label" -eq 1 ]; } && full=true
          log "PR #$n: stale in_progress lock (${age}m) — takeover"
          add_review "$n" "$sha" "$ref" "$title" "$author" "$kind" true "$prior" "$URG" false "$full"
        fi
      elif [ "$row_sha" = "$sha" ]; then
        # reviewed at live HEAD; trigger present -> same-SHA cleanup (agent clears it)
        if [ "$triggered" -eq 1 ]; then
          trig=""
          [ "$has_label" -eq 1 ] && trig="$REREVIEW_LABEL"
          [ "$has_request" -eq 1 ] && trig="${trig:+$trig + }review request"
          CLEANUPS_DUE="$(printf '%s' "$CLEANUPS_DUE" | jq --argjson e "$(jq -n --argjson n "$n" \
            --argjson l "$([ "$has_label" -eq 1 ] && echo true || echo false)" \
            --argjson r "$([ "$has_request" -eq 1 ] && echo true || echo false)" \
            '{number:$n, label:$l, request:$r}')" '. + [$e]')"
          log "PR #$n: $trig present but no new commits since ${row_sha:0:7} — trigger cleanup due"
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
    if [ -n "$ARTIFACT_SKILL" ] && [ -n "$BOT_LOGIN" ] && printf '%s' "$assignees" | tr ',' '\n' | grep -qx "$BOT_LOGIN"; then
      action="generate"
      grep -qE '<!-- artifact-(gist|dam):' "$WORK/reviews/pr-$n.md" 2>/dev/null && action="retry_unassign"
      ARTIFACTS_DUE="$(printf '%s' "$ARTIFACTS_DUE" | jq --argjson e "$(jq -n --argjson n "$n" --arg a "$action" \
        '{number:$n, action:$a}')" '. + [$e]')"
      log "PR #$n: artifact $action due"
    fi
  done < <(printf '%s' "$OPEN_NONDRAFT" | jq -r '.[] | [.number, .head_sha, .head_ref, (.title|gsub("\t";" ")), .author,
             ((.labels|join(","))|if .=="" then "-" else . end),
             ((.assignees|join(","))|if .=="" then "-" else . end),
             ((.requested|join(","))|if .=="" then "-" else . end), .url] | @tsv')

  # urgent entries first (stable sort — non-urgent keep their order)
  REVIEWS_DUE="$(printf '%s' "$REVIEWS_DUE" | jq 'sort_by(if .urgent then 0 else 1 end)')"

  # ------------------------------------------------- progress-signal ETA ----
  # `eta_seconds` per due review: the median wall-clock of recent completed
  # reviews, paired per (run, PR) from the `locked`/`done` review_step events
  # (docs/review.md → Progress signal on GitHub). Local files only, one jq
  # process, and only when a review is due — idle heartbeats pay nothing.
  if [ "$PROGRESS" = "enabled" ] && [ "$(printf '%s' "$REVIEWS_DUE" | jq length)" -gt 0 ]; then
    ETA_FILES=()
    while IFS= read -r f; do [ -f "$f" ] && ETA_FILES+=("$f"); done \
      < <(ls -1 "$LOG_DIR"/events-*.jsonl 2>/dev/null | sort | tail -7)
    ETA=null
    if [ "${#ETA_FILES[@]}" -gt 0 ]; then
      ETA="$(jq -R -n '
        [ inputs | fromjson? // empty
          | select(.event == "review_step")
          | select(.msg | test("PR #[0-9]+ +[0-9a-f]+ +(locked|done)$"))
          | (.msg | capture("PR #(?<n>[0-9]+) +[0-9a-f]+ +(?<step>locked|done)$")) as $c
          | {key: ((.run // "?") + "#" + $c.n), step: $c.step,
             t: (.ts | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601)} ]
        | group_by(.key)
        | map( (map(select(.step == "locked") | .t) | min) as $a
             | (map(select(.step == "done")   | .t) | max) as $b
             | if $a == null or $b == null or $b <= $a then empty
               else {end: $b, d: ($b - $a)} end )
        | sort_by(.end) | .[-20:] | map(.d) | sort
        | if length == 0 then null else .[(length / 2) | floor] end' "${ETA_FILES[@]}" 2>/dev/null)"
      [ -n "$ETA" ] || ETA=null
    fi
    REVIEWS_DUE="$(printf '%s' "$REVIEWS_DUE" | jq --argjson eta "$ETA" 'map(. + {eta_seconds: $eta})')"
  fi

  # install skills only when the agent will actually review / generate
  if [ "$(printf '%s' "$REVIEWS_DUE" | jq length)" -gt 0 ] \
     || [ "$(printf '%s' "$ARTIFACTS_DUE" | jq '[.[] | select(.action=="generate")] | length')" -gt 0 ]; then
    # git credential helper for every authenticated host, before the agent clones
    gh auth setup-git 2>/dev/null || log_warn "gh auth setup-git did not succeed — clones may fail to authenticate"
    while IFS='|' read -r _ skill src _rest; do
      skill="$(trim "$skill")"; src="$(trim "$src")"
      case "$skill" in ''|skill|-*) continue;; esac
      SKILLS="$(printf '%s' "$SKILLS" | jq --arg k "$skill" --arg v "$(install_skill "$skill" "$src")" '. + {($k):$v}')"
    done < <(cfg_table 'Review skills')
    if [ -n "$ARTIFACT_SKILL" ] && [ "$(printf '%s' "$ARTIFACTS_DUE" | jq '[.[] | select(.action=="generate")] | length')" -gt 0 ]; then
      SKILLS="$(printf '%s' "$SKILLS" | jq --arg k "$ARTIFACT_SKILL" --arg v "$(install_skill "$ARTIFACT_SKILL" "$ARTIFACT_SRC")" '. + {($k):$v}')"
    fi
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
  if [ "$MENTION_REPLIES" = "enabled" ]; then
    MSINCE="$(date -u -d "@$((NOW_EPOCH - 7*86400))" +%Y-%m-%d 2>/dev/null \
              || date -u -r "$((NOW_EPOCH - 7*86400))" +%Y-%m-%d 2>/dev/null)T00:00:00Z"
    mention_seen() { grep -qE "^\| *$1 *\|" "$WORK/MENTIONS.md" 2>/dev/null; }
    # newest-first: on a busy repo the window holds more than one page, and the
    # cap must drop the oldest comments (already answered, or aged out) rather
    # than the newest ones — ascending order starves fresh mentions forever.
    IC="$(gh api "repos/$REPO/issues/comments?since=$MSINCE&per_page=100&sort=created&direction=desc" 2>/dev/null)"
    RC="$(gh api "repos/$REPO/pulls/comments?since=$MSINCE&per_page=100&sort=created&direction=desc" 2>/dev/null)"
    { printf '%s' "$IC" | jq -e 'type=="array"' >/dev/null 2>&1; } || IC='[]'
    { printf '%s' "$RC" | jq -e 'type=="array"' >/dev/null 2>&1; } || RC='[]'
    [ "$(printf '%s' "$IC" | jq length)" -eq 100 ] \
      && log "mention scan: issue-comment page cap (100) hit — scanned the newest 100 in the window"
    [ "$(printf '%s' "$RC" | jq length)" -eq 100 ] \
      && log "mention scan: review-comment page cap (100) hit — scanned the newest 100 in the window"
    MRE="@${BOT_LOGIN}([^A-Za-z0-9-]|\$)"
    CAND="$(jq -n --argjson ic "$IC" --argjson rc "$RC" --arg re "$MRE" --arg bot "$BOT_LOGIN" '
      [ $ic[] | select((.user.login // "") != $bot and ((.user.type // "User") != "Bot"))
              | select((.body // "") | test($re))
              | {comment_id: .id, thread: "conversation",
                 number: (.issue_url | capture("/(?<n>[0-9]+)$").n | tonumber),
                 author: (.user.login // "ghost"), created_at,
                 body: ((.body // "") | .[0:1500]), url: .html_url,
                 in_reply_to: null, mentioned: true} ]
      + [ $rc[] | select((.user.login // "") != $bot and ((.user.type // "User") != "Bot"))
                | select(((.body // "") | test($re)) or (.in_reply_to_id != null))
                | {comment_id: .id, thread: "inline",
                   number: (.pull_request_url | capture("/(?<n>[0-9]+)$").n | tonumber),
                   author: (.user.login // "ghost"), created_at,
                   body: ((.body // "") | .[0:1500]), url: .html_url,
                   in_reply_to: .in_reply_to_id,
                   mentioned: ((.body // "") | test($re))} ]
      | sort_by(.created_at)' 2>/dev/null)"
    [ -z "$CAND" ] && CAND='[]'
    # PR descriptions: an @-mention in the body of any open PR (drafts
    # included; zero extra API calls — the open-PR list already carries the
    # bodies). One handling per PR: ledger key "body-<n>".
    BCAND="$(printf '%s' "$OPEN_JSON" | jq --arg re "$MRE" --arg bot "$BOT_LOGIN" '
      [ .[] | select(((.user.login // "") != $bot) and ((.user.type // "User") != "Bot"))
            | select((.body // "") | test($re))
            | {comment_id: ("body-" + (.number|tostring)), thread: "body",
               number, author: (.user.login // "ghost"), created_at,
               body: ((.body // "") | .[0:1500]), url: .html_url,
               in_reply_to: null} ]' 2>/dev/null)"
    { printf '%s' "$BCAND" | jq -e 'type=="array"' >/dev/null 2>&1; } || BCAND='[]'
    CAND="$(jq -n --argjson a "$CAND" --argjson b "$BCAND" '$a + $b | sort_by(.created_at)')"
    while IFS= read -r c; do
      [ -z "$c" ] && continue
      cid="$(printf '%s' "$c" | jq -r '.comment_id')"
      mention_seen "$cid" && continue
      # a reply without an @-mention is relevant only when the thread root is
      # the bot's inline comment (root in the same batch, else one GET)
      if [ "$(printf '%s' "$c" | jq -r '.thread + " " + (.mentioned|tostring)')" = "inline false" ]; then
        root="$(printf '%s' "$c" | jq -r '.in_reply_to')"
        root_author="$(printf '%s' "$RC" | jq -r --argjson r "$root" '[.[] | select(.id == $r) | .user.login] | first // empty')"
        [ -z "$root_author" ] && root_author="$(gh api "repos/$REPO/pulls/comments/$root" 2>/dev/null | jq -r '.user.login // empty')"
        [ "$root_author" = "$BOT_LOGIN" ] || continue
      fi
      MENTIONS_DUE="$(printf '%s' "$MENTIONS_DUE" | jq --argjson e "$(printf '%s' "$c" | jq 'del(.mentioned)')" '. + [$e]')"
      log "#$(printf '%s' "$c" | jq -r '.number'): mention $cid by $(printf '%s' "$c" | jq -r '.author') — handling due"
    done < <(printf '%s' "$CAND" | jq -c '.[]')
  fi

  # ------------------------------------------- stalled-review rate alert ----
  # A review that locked a PR and died before posting is invisible per-run: the
  # lock's TTL hands the PR to the next heartbeat, which may repeat it.
  # One stall is normal (HEAD moved, pod restart); a cluster is pathological, so
  # count the last 24h of `stale in_progress lock` takeovers across the event
  # log and emit ONE alert per UTC day when the threshold is reached.
  # Cheap by construction: two small log files, no API calls, no extra run.
  if [ "$STALL_ALERT_THRESHOLD" -gt 0 ]; then
    STALL_SINCE="$(( NOW_EPOCH - 86400 ))"
    STALL_N=0; STALL_PRS=""
    for lf in "$LOG_DIR/events-$(date -u -d @"$STALL_SINCE" +%Y-%m-%d 2>/dev/null \
                || date -u -r "$STALL_SINCE" +%Y-%m-%d 2>/dev/null)" \
              "$LOG_DIR/events-$(date -u +%Y-%m-%d).jsonl"; do
      case "$lf" in (*.jsonl) ;; (*) lf="$lf.jsonl";; esac
      [ -f "$lf" ] || continue
      while IFS="$(printf '\t')" read -r ets pr; do
        [ -n "$pr" ] || continue
        [ "$(iso2epoch "$ets")" -ge "$STALL_SINCE" ] || continue
        STALL_N=$((STALL_N+1))
        case " $STALL_PRS " in (*" $pr "*) ;; (*) STALL_PRS="$STALL_PRS $pr";; esac
      done < <(jq -r 'select(.event == "preflight" and (.msg | test("stale in_progress lock")))
                      | [.ts, (.msg | capture("PR #(?<n>[0-9]+)") | .n)] | @tsv' "$lf" 2>/dev/null)
    done
    STALL_PRS="${STALL_PRS# }"
    # per-UTC-day counts over the retained log window — turns "22 today" into a
    # trend the operator can read (is this new, or every day?)
    STALL_WEEK="$(for f in "$LOG_DIR"/events-*.jsonl; do
        [ -f "$f" ] || continue
        d="$(basename "$f" .jsonl)"; d="${d#events-}"
        c="$(jq -r 'select(.event == "preflight" and (.msg | test("stale in_progress lock"))) | 1' "$f" 2>/dev/null | grep -c . || true)"
        [ "${c:-0}" -gt 0 ] && jq -nc --arg d "$d" --argjson c "${c:-0}" '{day:$d, stalls:$c}'
      done | jq -sc 'sort_by(.day) | .[-7:]')"
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

  emit "$REVIEWS_DUE" "$CLEANUPS_DUE" "$SELFHEALS_DUE" "$PRUNES_DUE" "$ARTIFACTS_DUE" '[]' "$ALERTS_DUE" "$MENTIONS_DUE" "$SKILLS"
  exit 0
fi

# ========================================================= SHEPHERD MODE ====
if [ "$MODE" = "shepherd" ]; then
  [ "$SLACK" = "enabled" ] || { log "slack notifications disabled — shepherd skipped"; emit '[]' '[]' '[]' '[]' '[]' '[]' '[]' '[]' '{}'; exit 0; }
  [ -f "$DEVELOPERS" ] || { log "work/DEVELOPERS.md missing — shepherd skipped"; emit '[]' '[]' '[]' '[]' '[]' '[]' '[]' '[]' '{}'; exit 0; }

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
  shep_row()  { shep_rows | grep -E "^\| *$1 *\|" | head -1; }

  NEW_TABLE=""; NUDGES_DUE='[]'
  while IFS=$'\t' read -r n title author created labels requested url; do
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

    # classification from independent reviews (bot + author excluded, marker-carrying excluded)
    cls="$(gh api "repos/$REPO/pulls/$n/reviews?per_page=100" 2>/dev/null \
      | jq -r --arg a "$author" --arg b "$BOT_LOGIN" --arg m "<!-- $REVIEW_MARKER" '
          [ .[] | select(.user.login != $b and .user.login != $a)
                | select((.body // "") | contains($m) | not) ]
          | group_by(.user.login) | map(last | .state)
          | if any(. == "APPROVED") then "approved"
            elif any(. == "CHANGES_REQUESTED") then "changes_requested"
            else "awaiting_review" end')"
    [ -z "$cls" ] && { logev warn gh_api "PR #$n: review classification did not respond — defaulting to awaiting_review"; cls="awaiting_review"; }

    # merge-conflict flag (detail call — the list endpoint omits mergeable
    # state; null = still computing, treated as clean until the next sweep)
    dirty=false
    [ "$(gh api "repos/$REPO/pulls/$n" 2>/dev/null | jq -r '.mergeable_state // empty')" = "dirty" ] && dirty=true

    # class transition resets the ladder (never the clock)
    [ -n "$prev_state" ] && [ "$prev_state" != "$cls" ] && level=1

    age_h=$(( (NOW_EPOCH - $(iso2epoch "$eligible")) / 3600 ))
    since_last=999999; [ "$last" != "-" ] && since_last=$(( (NOW_EPOCH - $(iso2epoch "$last")) / 3600 ))

    due=0; new_status="watching"; next_level="$level"
    # an approved PR nudges only while it has merge conflicts (rebase ask)
    if [ "$cls" = "approved" ] && [ "$dirty" = "false" ]; then new_status="approved"
    elif [ "$status" = "held" ] && { [ -z "$prev_state" ] || [ "$prev_state" = "$cls" ]; }; then new_status="held"  # hold is sticky until the class changes
    elif [ "$age_h" -lt 24 ]; then new_status="watching"
    elif [ "$since_last" -lt 20 ]; then new_status="${status:-watching}"
    elif [ "$nudges" -eq 0 ]; then due=1; next_level=1
    elif [ "$since_last" -ge 48 ]; then due=1; next_level=$((level+1)); [ "$next_level" -gt 4 ] && next_level=4
    else new_status="${status:-watching}"
    fi

    if [ "$due" -eq 1 ]; then
      if [ "$dirty" = "true" ] || [ "$cls" = "changes_requested" ]; then
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
      [ "$next_level" -ge 4 ] && nudge_status="held"
      esc_id=""; [ "$next_level" -ge 4 ] && [ -n "$ESCALATION_OWNER" ] && esc_id="$(slack_id "$ESCALATION_OWNER")"
      mentions="$(for t in $(printf '%s' "$targets" | tr -d '!*' | tr ',' ' '); do id="$(slack_id "$t")"; [ -n "$id" ] && printf '%s\t%s\n' "$t" "$id"; done | jq -R 'split("\t") | {login:.[0], slack_id:.[1]}' | jq -s .)"
      NUDGES_DUE="$(printf '%s' "$NUDGES_DUE" | jq --argjson e "$(jq -n --argjson n "$n" --arg t "$title" --arg a "$author" --arg u "$url" \
        --argjson age "$age_h" --arg c "$cls" --argjson l "$next_level" --argjson m "$mentions" \
        --arg eo "$ESCALATION_OWNER" --arg eid "$esc_id" --arg tg "$targets" \
        --argjson nn "$((nudges+1))" --arg ns "$nudge_status" --argjson conf "$dirty" \
        '{number:$n, title:$t, author:$a, url:$u, age_hours:$age, class:$c, level:$l, targets:$tg, mentions:$m,
          conflict:$conf,
          needs_target_selection: ($m|length==0 and $c!="changes_requested" and ($conf|not)),
          escalation:{login:$eo, slack_id:$eid},
          row_update:{nudges:$nn, level:$l, status:$ns}}')" '. + [$e]')"
      log "PR #$n: nudge L$next_level due ($cls, ${age_h}h$([ "$dirty" = "true" ] && printf ', merge conflict'))"
      # send-then-record belongs to the agent: keep the row EXACTLY as-is
      new_status="${status:-watching}"; next_level="$level"
    fi

    [ -z "$reviewers" ] && reviewers="-"
    NEW_TABLE="$NEW_TABLE| $n | $eligible | $reviewers | $cls | $nudges | $last | $next_level | ${new_status:-watching} |"$'\n'
  done < <(printf '%s' "$OPEN_NONDRAFT" | jq -r '.[] | [.number, (.title|gsub("\t";" ")), .author, .created_at,
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
  SINCE_ISO="$(date -u -d "@$SINCE_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$SINCE_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  CHECKS='[]'
  check() { CHECKS="$(printf '%s' "$CHECKS" | jq --arg i "$1" --arg s "$2" --arg d "$3" '. + [{id:$i, status:$s, detail:$d}]')"; }

  # definition repo, resolved here because the connectivity checks below cover
  # every host the pipeline touches (target, definition, skill sources)
  DEF_REF="$(cfg definition_repo)"
  [ -z "$DEF_REF" ] && DEF_REF="$(git -C "$HOME_DIR" remote get-url origin 2>/dev/null \
    | sed -E 's#^(git@|https://)##; s#^([^/:]+)[:/]#\1/#; s#\.git$##')"
  DEF_HOST="$(refhost "$DEF_REF")"; DEFINITION_REPO="$(refslug "$DEF_REF")"

  AUDIT_HOSTS="$REPO_HOST"
  [ -n "$DEF_REF" ] && AUDIT_HOSTS="$AUDIT_HOSTS $DEF_HOST"
  while IFS='|' read -r _ askill asrc _rest; do
    askill="$(trim "$askill")"; asrc="$(trim "$asrc")"
    case "$askill" in (''|skill|-*) continue;; esac
    [ "$asrc" = "harness" ] && continue
    AUDIT_HOSTS="$AUDIT_HOSTS $(refhost "$asrc")"
  done < <(cfg_table 'Review skills')
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

    # Token scopes the pipeline depends on: `repo` for PR state and posting,
    # `gist` for artifact publishing (target host only). A missing scope fails
    # those calls outright, so catch it here rather than per review; granting is
    # operator-only.
    want="repo"; { [ "$h" = "$REPO_HOST" ] && [ -n "$ARTIFACT_SKILL" ]; } && want="repo gist"
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
  else check token_scopes "$scope_status" "$scope_detail — operator-only fix; repo breaks PR state and posting, gist breaks artifact publishing"; fi

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
  if [ -n "$shimmed" ]; then check tool_shims warn "still resolving through a shim, ~250ms per call: $shimmed — fix belongs in the pod image (real bin dirs ahead of the shim dir on PATH)"
  else check tool_shims ok "hot-path tools resolve to real binaries"; fi

  check target_repo ok "$OPEN_COUNT open non-draft PRs listed"

  if [ -n "${GITHUB_REPO_WORK:-}" ]; then
    if [ -e "$WORK/.git" ]; then
      check work_repo warn "work/.git present — work/ must be a plain data dir (backup runs in a tmpfs clone); remove it per docs/persistence.md"
    else
      check work_repo ok "work/ plain data dir; durable backup via tmpfs clone (any work_backup push errors surface in the log triage below)"
    fi
  else check work_repo ok "local-only persistence (GITHUB_REPO_WORK unset)"; fi

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
  elif [ "$max_gap" -gt 3600 ]; then check heartbeats warn "$hb_total heartbeats; largest gap $((max_gap/60)) min; last ${last_age_m}m ago"
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

  ghost=0
  for n in $(reviews_rows | cut -d'|' -f2 | tr -d ' '); do open_numbers | grep -qx "$n" || ghost=$((ghost+1)); done
  [ "$ghost" -gt 0 ] && check closed_rows warn "$ghost rows for non-open PRs (prune pending next heartbeat)" || check closed_rows ok "every row maps to an open PR"

  orphan_files=0
  for f in "$WORK"/reviews/pr-*.md; do
    [ -f "$f" ] || continue
    n="${f##*/pr-}"; n="${n%.md}"
    [ -n "$(row_for "$n")" ] || orphan_files=$((orphan_files+1))
  done
  [ "$orphan_files" -gt 0 ] && check orphan_history warn "$orphan_files history files without a REVIEWS.md row" || check orphan_history ok "history files all match rows"

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

  # --- artifacts & hygiene --------------------------------------------------
  [ -n "$ARTIFACT_OFF_REASON" ] && check artifact_targets warn "artifact_skill configured but disabled: $ARTIFACT_OFF_REASON"
  if [ -n "$ARTIFACT_SKILL" ] && printf '%s' ",$EFFECTIVE_TARGETS," | grep -q ',gist,'; then
    gist_ids="$(gh api "gists?per_page=100" 2>/dev/null | jq -r '.[] | select((.description // "") | test("review artifact")) | .id')"
    markers="$(grep -ho '<!-- artifact-gist: [A-Za-z0-9]* -->' "$WORK"/reviews/pr-*.md 2>/dev/null | cut -d' ' -f3 | sort -u)"
    orphans=""
    for g in $gist_ids; do printf '%s\n' "$markers" | grep -qx "$g" || orphans="${orphans:+$orphans, }$g"; done
    [ -n "$orphans" ] && check orphan_gists warn "artifact gists with no marker (leaked, never pruned): $orphans" \
      || check orphan_gists ok "every artifact gist is tracked by a marker"
  fi

  # stale-clone sweep: clones a dead session never removed (live-run cleanup is
  # the review pipeline's, docs/review.md). Reclaim only entries past the lock
  # TTL whose PR holds no in_progress lock; the number is compared exactly so
  # PR #4's sweep can never take PR #42's dirs (docs/skills.md).
  TMP_ROOT="${TMPDIR:-/tmp}"
  swept=0
  for d in "$TMP_ROOT"/review-pr-*; do
    [ -e "$d" ] || continue
    cn="${d##*/review-pr-}"; cn="${cn%%.*}"
    case "$cn" in (''|*[!0-9]*) continue;; esac
    [ "$(row_field "$(row_for "$cn")" 6)" = "in_progress" ] && continue
    [ -n "$(find "$d" -maxdepth 0 -mmin +"$LOCK_TTL_MIN" 2>/dev/null)" ] || continue
    rm -rf "$d" && swept=$((swept+1))
  done
  [ "$swept" -gt 0 ] && logev info tmp_cleanup "stale-clone sweep: reclaimed $swept review-pr-* leftover(s) from dead sessions"

  sw_note=""; [ "$swept" -gt 0 ] && sw_note=" ($swept stale reclaimed)"
  tmp_left="$(ls -d "$TMP_ROOT"/review-pr-* 2>/dev/null | grep -c . || true)"
  [ "$tmp_left" -gt 0 ] && check tmp_leftovers warn "$tmp_left leftover /tmp/review-pr-* entries$sw_note" || check tmp_leftovers ok "no clone leftovers$sw_note"

  disk="$(df -P "$WORK" 2>/dev/null | tail -1 | tr -s ' ' | cut -d' ' -f5 | tr -d '%')"
  if [ -n "$disk" ] && [ "$disk" -gt 85 ]; then check disk warn "work volume ${disk}% full"; else check disk ok "work volume ${disk:-?}% used"; fi

  while IFS='|' read -r _ skill src _rest; do
    skill="$(trim "$skill")"; src="$(trim "$src")"
    case "$skill" in (''|skill|-*) continue;; esac
    [ "$src" = "harness" ] && continue
    remote_sha="$(gh api --hostname "$(refhost "$src")" "repos/$(refslug "$src")/commits/main" 2>/dev/null | jq -r '.sha // empty')"
    cached="$(cat "$SKILL_CACHE/$skill.sha" 2>/dev/null || true)"
    if [ -z "$remote_sha" ]; then check "skill_$skill" warn "source $src unreachable"
    elif [ "$remote_sha" != "$cached" ]; then check "skill_$skill" ok "update available (installs on next review)"
    else check "skill_$skill" ok "installed and current"; fi
  done < <(cfg_table 'Review skills')

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
    git -C "$HOME_DIR" fetch -q origin "$DB" 2>/dev/null
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
  ev_jsonl() { cat "$LOG_DIR"/events-*.jsonl 2>/dev/null | jq -c -R 'fromjson? // empty' 2>/dev/null; }
  ev_err=0; ev_warn=0; recurring=""
  if ls "$LOG_DIR"/events-*.jsonl >/dev/null 2>&1; then
    ev_err="$(ev_jsonl | jq -rs --arg s "$SINCE_ISO" '[.[] | select(.ts >= $s and .level=="error")] | length' 2>/dev/null)"; ev_err="${ev_err:-0}"
    ev_warn="$(ev_jsonl | jq -rs --arg s "$SINCE_ISO" '[.[] | select(.ts >= $s and .level=="warn")] | length' 2>/dev/null)"; ev_warn="${ev_warn:-0}"
    recurring="$(ev_jsonl | jq -rs --arg s "$SINCE_ISO" \
      '[.[] | select(.ts >= $s and (.level=="error" or .level=="warn"))] | group_by(.event)
       | map(select(length >= 3) | "\(.[0].event)×\(length)") | join(", ")' 2>/dev/null)"
  fi
  if [ "$ev_err" -gt 0 ]; then
    last_err="$(ev_jsonl | jq -rs --arg s "$SINCE_ISO" \
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
    FAILURES="$(ev_jsonl | jq -s --arg s "$SINCE_ISO" '
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
  # by harness/claude-code/log-session-tokens.sh — keep the capture in sync)
  TOKENS_WEEK="$(ev_jsonl | jq -rs --arg s "$SINCE_ISO" '
    [.[] | select(.ts >= $s and .event=="tokens") | .msg
     | capture("input=(?<i>[0-9]+) output=(?<o>[0-9]+) cache_read=(?<cr>[0-9]+) cache_creation=(?<cc>[0-9]+)")]
    | {runs: length, input: ([.[].i | tonumber] | add // 0), output: ([.[].o | tonumber] | add // 0),
       cache_read: ([.[].cr | tonumber] | add // 0), cache_creation: ([.[].cc | tonumber] | add // 0)}' 2>/dev/null)"
  [ -n "$TOKENS_WEEK" ] || TOKENS_WEEK='{"runs":0}'

  # Wasted-review accounting: a run that locked a PR and never reached a
  # terminal `review_step` threw its work away — the next heartbeat redoes the
  # review at full cost. Classified by cause, deterministically, from the log:
  #   pod_restart  — a `pod_boot` warn falls inside the run's own event window
  #   hard_kill    — no `tokens` event, i.e. the SessionEnd hook never ran
  #   terminated   — SessionEnd ran but the pipeline stopped mid-way (orderly
  #                  shutdown from outside; see docs/audit.md task 27)
  # `aborted_clean` counts runs that *did* terminate explicitly — the cheap
  # outcome the Stop hook drives, so a rise here against falling `stalled` is
  # the mitigation working, not a regression.
  # One jq pass over the same files; no API calls, no extra run.
  # a run whose last event is newer than the lock TTL may still be alive
  # (no SessionEnd yet is not a kill) — exclude it rather than miscount it
  STALL_CUTOFF="$(date -u -d "@$(( NOW_EPOCH - LOCK_TTL_MIN * 60 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
                  || date -u -r "$(( NOW_EPOCH - LOCK_TTL_MIN * 60 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  STALLS_WEEK="$(ev_jsonl | jq -rs --arg s "$SINCE_ISO" --arg cut "$STALL_CUTOFF" '
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
    if [ -z "$hooks_missing" ]; then
      check harness_adapter ok "Claude Code hooks registered (tool logging + review-completion enforcement)"
    else
      check harness_adapter warn "Claude Code hooks not registered:$hooks_missing — run scripts/harness/claude-code/install.sh"
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
  logev info log_cleanup "retention: removed $removed events file(s) older than 14d, trimmed HEARTBEAT/SHEPHERD and the mention ledger to 14d"

  # --- 7-day stats -----------------------------------------------------------
  rv_total=0; rv_first=0; rv_re=0; v_app=0; v_com=0; v_req=0
  for f in "$WORK"/reviews/pr-*.md; do
    [ -f "$f" ] || continue
    idx=0
    while IFS= read -r line; do
      idx=$((idx+1))
      ts="$(printf '%s' "$line" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z' | head -1)"
      [ -z "$ts" ] && continue
      [ "$(iso2epoch "$ts")" -lt "$SINCE_EPOCH" ] && continue
      rv_total=$((rv_total+1))
      [ "$idx" -eq 1 ] && rv_first=$((rv_first+1)) || rv_re=$((rv_re+1))
      case "$line" in
        (*REQUEST_CHANGES*) v_req=$((v_req+1));;
        (*APPROVE*)         v_app=$((v_app+1));;
        (*COMMENT*)         v_com=$((v_com+1));;
      esac
    done < <(grep '^## Review at ' "$f")
  done
  nudges_wk=0
  while IFS= read -r l; do
    ts="${l%% *}"; [ "$(iso2epoch "$ts")" -ge "$SINCE_EPOCH" ] || continue
    m="$(printf '%s' "$l" | grep -oE '[0-9]+ nudges due' | cut -d' ' -f1)"
    nudges_wk=$((nudges_wk + ${m:-0}))
  done < <(cat "$WORK/SHEPHERD.log" 2>/dev/null)

  # findings effectiveness: Fixed vs Still-present bullets inside this week's
  # re-review sections (the agent judges the ratio — docs/audit.md task 26)
  fx_wk=0; sp_wk=0
  for f in "$WORK"/reviews/pr-*.md; do
    [ -f "$f" ] || continue
    in_win=0
    while IFS= read -r line; do
      case "$line" in
        ('## Review at '*)
          ts="$(printf '%s' "$line" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z' | head -1)"
          in_win=0
          [ -n "$ts" ] && [ "$(iso2epoch "$ts")" -ge "$SINCE_EPOCH" ] && in_win=1;;
        ('- ✅ **Fixed:**'*)         [ "$in_win" -eq 1 ] && fx_wk=$((fx_wk+1));;
        ('- 🔁 **Still present:**'*) [ "$in_win" -eq 1 ] && sp_wk=$((sp_wk+1));;
      esac
    done < "$f"
  done

  # reaction feedback on the bot's comments — 👍/👎 sums over the latest 100
  # inline + 100 issue comments (the two surfaces whose REST list endpoints
  # carry reactions); the agent examines down_urls (docs/audit.md)
  REACTIONS='{"up":0,"down":0,"down_urls":[],"scanned":0}'
  if [ -n "$BOT_LOGIN" ]; then
    rrc="$(gh api "repos/$REPO/pulls/comments?per_page=100&sort=created&direction=desc" 2>/dev/null)"
    ric="$(gh api "repos/$REPO/issues/comments?per_page=100&sort=created&direction=desc" 2>/dev/null)"
    { printf '%s' "$rrc" | jq -e 'type=="array"' >/dev/null 2>&1; } || rrc='[]'
    { printf '%s' "$ric" | jq -e 'type=="array"' >/dev/null 2>&1; } || ric='[]'
    REACTIONS="$(jq -n --argjson a "$rrc" --argjson b "$ric" --arg bot "$BOT_LOGIN" '
      [ ($a + $b)[] | select((.user.login // "") == $bot) ]
      | {up: (map(.reactions["+1"] // 0) | add // 0),
         down: (map(.reactions["-1"] // 0) | add // 0),
         down_urls: (map(select((.reactions["-1"] // 0) > 0) | .html_url) | .[0:10]),
         scanned: length}' 2>/dev/null)"
    [ -n "$REACTIONS" ] || REACTIONS='{"up":0,"down":0,"down_urls":[],"scanned":0}'
  fi

  STATS="$(jq -n --arg since "$SINCE_ISO" \
    --argjson open "$OPEN_COUNT" --argjson rv "$rv_total" --argjson rf "$rv_first" --argjson rr "$rv_re" \
    --argjson va "$v_app" --argjson vc "$v_com" --argjson vq "$v_req" \
    --argjson hb "$hb_total" --argjson idle "$hb_idle" --argjson nd "$nudges_wk" \
    --argjson fx "$fx_wk" --argjson sp "$sp_wk" \
    --argjson le "$ev_err" --argjson lw "$ev_warn" --argjson tw "$TOKENS_WEEK" \
    --argjson sw "$STALLS_WEEK" --argjson rx "$REACTIONS" \
    '{since:$since, open_prs:$open,
      reviews:{total:$rv, first:$rf, re_review:$rr, approve:$va, comment:$vc, request_changes:$vq},
      findings:{fixed:$fx, still_present:$sp},
      heartbeats:{total:$hb, idle:$idle}, nudges_claimed:$nd,
      log_events:{errors:$le, warns:$lw}, tokens:$tw, stalls:$sw, reactions:$rx}')"

  # wording note: never write the substring "fail"/"error" into this line —
  # the next audit's log_errors grep would flag it as a false positive
  printf '%s\n' "$NOW_ISO audit nothing_to_do=false checks=$(printf '%s' "$CHECKS" | jq length) red=$(printf '%s' "$CHECKS" | jq '[.[]|select(.status=="fail")]|length')" >> "$WORK/HEARTBEAT.log" 2>/dev/null
  jq -n --argjson stats "$STATS" --argjson checks "$CHECKS" \
    --argjson failures "${FAILURES:-[]}" \
    --argjson logs "$(printf '%s\n' "${LOGS[@]:-}" | jq -R . | jq -s '[.[] | select(length>0)]')" \
    '{mode:"audit", nothing_to_do:false, stats:$stats, checks:$checks,
      failures:$failures, logs:$logs}'
  exit 0
fi

fail_out "unknown mode '$MODE' (use review|shepherd|audit|benchmark)"
