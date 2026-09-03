#!/usr/bin/env bash
# review-pr.sh — the mechanical half of one PR review (docs/review.md).
#
# The agent decides what a review says; this script performs the steps around
# that decision exactly as docs/review.md and docs/skills.md specify, and
# refuses when a guard fails. It never composes, drops, or reorders a finding.
#
#   prepare <n> [--eta <s>] [--on-demand]   Check 1 + live-holder re-check, the
#                                          lock row, PR context, the diff with a
#                                          hunk index, clone + base ref + per-skill
#                                          copies, skill briefs, the context pack
#   step <n> <milestone…>                  lock heartbeat + review_step event
#   context <n> <path> <line> [radius]     numbered lines around a candidate,
#                                          with "in this PR's hunks" / pre-existing
#   sweep <n> <ERE>                        occurrences over the changed files (+ a
#                                          count in untouched code)
#   collect <n>                            skill outputs → audit lines, form
#                                          warnings, skill_timing event
#   delta <n> <findings.json>              fixed / still / new against the prior
#                                          findings-json, PR-local overrides applied
#   rapid <n> --body <file>                urgent phase 1: the rapid preliminary post
#   post <n> --verdict <V> --body <file> --findings <file> [--comments <file>]
#                                [--closed-issue <id>]
#                                          Check 2 + dedup re-check, inline
#                                          eligibility, payload, POST with 422
#                                          handling, trigger removal, stale-approval
#                                          dismissal, done row, history, cleanup
#   abort <n> <reason…>                    release the lock per kind, clean up
#
# Every subcommand prints one JSON object with `outcome` and exits 0; the agent
# reads the outcome. Files: /tmp/review-pr-<n> (clone), .out/ (skill outputs),
# .s-<skill> (per-skill copies), .diff, .ctx/ (pr.json, context.json, hunks.json,
# files.json, pack.json, briefs/). GitHub writes happen only in `rapid` and
# `post` (the review the agent wrote, the label removal and approval dismissal
# docs/review.md mandates) and the progress status under review_progress.
# Requires bash, gh (authenticated), jq, git, sed/grep/cut/tr — awk-free.
# Overrides (tests): CG_CLONE_URL (clone source), CG_HOLDER_QUIET_MIN.

set -u
export LC_ALL=C

CMD="${1:-}"; N="${2:-}"
case "$CMD" in (prepare|step|context|sweep|collect|delta|rapid|post|abort) ;;
  (*) printf 'usage: %s prepare|step|context|sweep|collect|delta|rapid|post|abort <pr-number> …\n' "$0" >&2; exit 2;; esac
case "$N" in (''|*[!0-9]*) printf '{"outcome":"error","error":"pr number missing or not numeric"}\n'; exit 0;; esac
shift 2

HOME_DIR="${HOME:-/home/agent}"
WORK="${WORK_DIR:-$HOME_DIR/work}"
CONFIG="$WORK/CONFIG.md"
REVIEWS="$WORK/REVIEWS.md"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TMP_ROOT="${TMPDIR:-/tmp}"
PR_DIR="$TMP_ROOT/review-pr-$N"; OUT="$PR_DIR.out"; DIFF="$PR_DIR.diff"; CTX="$PR_DIR.ctx"
PAYLOAD="$PR_DIR.post.json"
LOCK_TTL_MIN=50; HOLDER_QUIET_MIN="${CG_HOLDER_QUIET_MIN:-20}"
INLINE_CAP=25
NOW_EPOCH=$(date -u +%s)
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_hm()  { date -u +%H:%M; }

LOG_JOB=review
if ! . "$SCRIPT_DIR/log.sh" 2>/dev/null; then logev() { :; }; fi
LOG_DIR="${LOG_DIR:-$WORK/logs}"

cfg() { sed -n "s/^- $1:[[:space:]]*//p" "$CONFIG" 2>/dev/null | head -1 \
        | sed -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//' \
              -e 's/^[`"'"'"']//' -e 's/[`"'"'"']$//'; }
cfg_table() { sed -n "/^## $1\$/,\${ /^## $1\$/d; /^## /q; p; }" "$CONFIG" 2>/dev/null | grep -E '^\|'; }
trim() { printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }
iso2epoch() { date -d "$1" +%s 2>/dev/null || date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || echo 0; }
DEFAULT_HOST="${GH_HOST:-github.com}"
refhost() { case "$1" in (*/*/*) printf '%s' "${1%%/*}";; (*) printf '%s' "$DEFAULT_HOST";; esac; }
refslug() { case "$1" in (*/*/*) printf '%s' "${1#*/}";;  (*) printf '%s' "$1";; esac; }

TARGET_REF="${GITHUB_REPO:-$(cfg github_repo)}"
REPO_HOST="$(refhost "$TARGET_REF")"; REPO="$(refslug "$TARGET_REF")"
export GH_HOST="$REPO_HOST"
BOT_LOGIN="$(cfg bot_login)"
BOT_NAME="$(cfg bot_display_name)"; BOT_NAME="${BOT_NAME:-Code Guardian}"
REVIEW_MARKER="$(cfg review_marker)"
REREVIEW_LABEL="$(cfg rereview_label)"; REREVIEW_LABEL="${REREVIEW_LABEL:-code-guardian-review}"
URGENT_LABEL="$(cfg urgent_label)"
TRIG="$(cfg rereview_trigger)"; TRIG="${TRIG:-label}"
PROGRESS="$(cfg review_progress)"; PROGRESS="${PROGRESS:-disabled}"
DEF_REF="$(cfg definition_repo)"
[ -z "$DEF_REF" ] && DEF_REF="$(git -C "$HOME_DIR" remote get-url origin 2>/dev/null | sed -E 's#^(git@|https://)##; s#^([^/:]+)[:/]#\1/#; s#\.git$##')"
DEF_HOST="$(refhost "$DEF_REF")"; DEFINITION_REPO="$(refslug "$DEF_REF")"

out() { printf '%s\n' "$1"; exit 0; }   # <json>
fail() { logev error review_pr "PR #$N: $CMD — $1"; out "$(jq -nc --arg e "$1" --arg c "$CMD" '{outcome:"error", step:$c, error:$e}')"; }
logstep() { logev info review_step "PR #$N $1"; }

# ------------------------------------------------------ REVIEWS.md rows ----
row_for()   { grep -E "^\| *$N *\|" "$REVIEWS" 2>/dev/null | head -1; }
row_field() { printf '%s' "$1" | cut -d'|' -f"$2" | sed -e 's/^ *//' -e 's/ *$//'; }
write_row() { # sha ts verdict status — replace in place, else append
  local line="| $N | $1 | $2 | $3 | $4 |"
  if [ -n "$(row_for)" ]; then
    sed -E "s#^\| *$N \|.*#$line#" "$REVIEWS" > "$REVIEWS.tmp" && mv "$REVIEWS.tmp" "$REVIEWS"
  else
    [ -f "$REVIEWS" ] || printf '# Reviewed PRs\n\n| PR | Commit | Timestamp | Verdict | Status |\n|----|--------|-----------|---------|--------|\n' > "$REVIEWS"
    printf '%s\n' "$line" >> "$REVIEWS"
  fi
}
delete_row() { grep -vE "^\| *$N *\|" "$REVIEWS" > "$REVIEWS.tmp" 2>/dev/null && mv "$REVIEWS.tmp" "$REVIEWS"; }

# --------------------------------------------------------- state files ----
ctx_get() { jq -r "$1" "$CTX/pr.json" 2>/dev/null; }
need_ctx() { [ -f "$CTX/pr.json" ] || fail "no prepared state for PR #$N — run: review-pr.sh prepare $N"; }

# ------------------------------------------------------ progress status ----
progress() { # <state> <description> [target_url] — best-effort (docs/review.md)
  [ "$PROGRESS" = "enabled" ] || return 0
  local sha; sha="$(ctx_get '.head_sha')"; [ -n "$sha" ] && [ "$sha" != "null" ] || return 0
  local desc; desc="$(printf '%s' "$2" | tr -cd '\11\12\15\40-\176' | cut -c1-138)"   # ASCII only, <140 chars
  if [ -n "${3:-}" ]; then
    gh api -X POST "repos/$REPO/statuses/$sha" -f state="$1" -f context="$REVIEW_MARKER" -f description="$desc" -f target_url="$3" >/dev/null 2>&1 \
      || logev warn progress_status "PR #$N: status write did not succeed ($1: $desc)"
  else
    gh api -X POST "repos/$REPO/statuses/$sha" -f state="$1" -f context="$REVIEW_MARKER" -f description="$desc" >/dev/null 2>&1 \
      || logev warn progress_status "PR #$N: status write did not succeed ($1: $desc)"
  fi
}

# ---------------------------------------------------------------- cleanup ----
cleanup() { rm -rf "$PR_DIR" "$OUT" "$PR_DIR".s-* "$DIFF" "$CTX" "$PAYLOAD"; }

# release the lock per kind (docs/review.md → Error handling): a first review
# deletes the row; a re-review restores the prior row as it was — `done` for a
# same-SHA (description-only) re-review, `awaiting_label` otherwise. No usable
# prior (a lock taken over from a dead run) → the row goes and self-heal
# restores it from the remote marker.
release_lock() { # <reason>
  local kind prior_sha prior_ts prior_verdict prior_status
  kind="$(ctx_get '.kind')"
  if [ "$kind" = "re-review" ]; then
    prior_sha="$(ctx_get '.prior.sha // empty')"; prior_ts="$(ctx_get '.prior.ts // empty')"
    prior_verdict="$(ctx_get '.prior.verdict // empty')"; prior_status="$(ctx_get '.prior.status // empty')"
    if printf '%s' "$prior_sha" | grep -qE '^[0-9a-f]{40}$' && [ -n "$prior_ts" ]; then
      case "$prior_status" in (done) ;; (*) prior_status=awaiting_label;; esac
      write_row "$prior_sha" "$prior_ts" "${prior_verdict:-SEE-GITHUB}" "$prior_status"
    else
      delete_row
    fi
  else
    delete_row
  fi
  progress success "no review posted — $1; retrying next heartbeat"
  logstep "$(ctx_get '.head_sha' | cut -c1-7) aborted $1"
  logev warn review_abort "PR #$N: $1"
}

# ------------------------------------------------------------- GitHub reads ----
gh_get() { local o; o="$(gh api "$@" 2>/dev/null)" && { printf '%s' "$o"; return 0; }; sleep 1; gh api "$@" 2>/dev/null; }

pr_state() { # → JSON of the live PR (Check 1 / Check 2), or empty
  gh_get "repos/$REPO/pulls/$N" | jq -c '{
    state, merged: (.merged // false), draft: (.draft // false),
    head_sha: .head.sha, head_ref: .head.ref, head_repo: (.head.repo.full_name // ""),
    base_ref: .base.ref, title: (.title // ""), author: (.user.login // ""),
    labels: [.labels[]?.name], requested: [.requested_reviewers[]?.login],
    additions: (.additions // 0), deletions: (.deletions // 0), changed_files: (.changed_files // 0),
    body: (.body // "")}' 2>/dev/null
}

trigger_live() { # <labels-json> <requested-json> → 0 when a re-review trigger is present
  local l=1 r=1
  case "$TRIG" in (label|both) printf '%s' "$1" | jq -e --arg x "$REREVIEW_LABEL" 'index($x) != null' >/dev/null 2>&1 && l=0;; esac
  case "$TRIG" in (review-request|both) [ -n "$BOT_LOGIN" ] && printf '%s' "$2" | jq -e --arg x "$BOT_LOGIN" 'index($x) != null' >/dev/null 2>&1 && r=0;; esac
  [ "$l" -eq 0 ] || [ "$r" -eq 0 ]
}

# marker-based dedup at one SHA → GitHub timestamp, "" when absent, __api_error__ when unknown
remote_reviewed_at() { # <sha>
  local m="<!-- $REVIEW_MARKER headRefOid=$1 -->" body ts err=0
  if body="$(gh_get "repos/$REPO/pulls/$N/reviews?per_page=100")"; then
    ts="$(printf '%s' "$body" | jq -r --arg m "$m" '[.[] | select(.body != null) | select(.body | contains($m)) | .submitted_at] | last // empty' 2>/dev/null)"
    [ -n "$ts" ] && { printf '%s' "$ts"; return 0; }
  else err=1; fi
  if body="$(gh_get "repos/$REPO/issues/$N/comments?per_page=100")"; then
    ts="$(printf '%s' "$body" | jq -r --arg m "$m" '[.[] | select(.body | contains($m)) | .created_at] | last // empty' 2>/dev/null)"
    [ -n "$ts" ] && { printf '%s' "$ts"; return 0; }
  else err=1; fi
  [ "$err" -eq 1 ] && printf '__api_error__'
  return 0
}

# ------------------------------------------------------------ live holder ----
# Another run owns this PR when a tree or diff of its exists AND shows life —
# a recent mtime or a foreign run's event on this PR within HOLDER_QUIET_MIN.
# A tree older than that with no such event is a dead run's leftover.
holder_alive() {
  local recent=0 e cutoff
  for e in "$PR_DIR" "$OUT" "$PR_DIR".s-* "$DIFF" "$CTX"; do
    [ -e "$e" ] || continue
    [ -n "$(find "$e" -maxdepth 0 -mmin "-$HOLDER_QUIET_MIN" 2>/dev/null)" ] && recent=1
  done
  cutoff="$(date -u -d "@$((NOW_EPOCH - HOLDER_QUIET_MIN*60))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
            || date -u -r "$((NOW_EPOCH - HOLDER_QUIET_MIN*60))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  local me="${LOG_RUN_ID:-${CLAUDE_CODE_SESSION_ID:-}}" foreign=0
  if ls "$LOG_DIR"/events-*.jsonl >/dev/null 2>&1; then
    foreign="$(cat "$LOG_DIR"/events-*.jsonl 2>/dev/null | jq -c -R 'fromjson? // empty' 2>/dev/null \
      | jq -rs --arg n "PR #$N " --arg me "$me" --arg cut "$cutoff" \
          '[ .[] | select(.ts >= $cut and (.msg|startswith($n)) and .run != $me and .event == "review_step") ] | length' 2>/dev/null)"
    foreign="${foreign:-0}"
  fi
  [ "$recent" -eq 1 ] || [ "${foreign:-0}" -gt 0 ]
}

# ----------------------------------------------------------- hunk index ----
# $DIFF → $CTX/hunks.json: {path: {right:[new-file lines in hunks], left:[old-file lines]}}
build_hunks() {
  local file="" inhunk=0 oldl=0 newl=0 line h old new tsv="$CTX/hunks.tsv"
  : > "$tsv"
  while IFS= read -r line; do
    case "$line" in
      ('diff --git '*) file=""; inhunk=0;;
      ('+++ b/'*) [ "$inhunk" -eq 0 ] && file="${line#+++ b/}";;
      ('+++ /dev/null') [ "$inhunk" -eq 0 ] && file="";;
      ('@@ '*)
        inhunk=1
        h="${line#@@ -}"; old="${h%% *}"; new="${h#* +}"; new="${new%% *}"
        oldl="${old%%,*}"; newl="${new%%,*}"
        case "$oldl" in (*[!0-9]*|'') oldl=0;; esac; case "$newl" in (*[!0-9]*|'') newl=0;; esac;;
      (*)
        [ "$inhunk" -eq 1 ] && [ -n "$file" ] || continue
        case "$line" in
          ('\ No newline'*) ;;
          ('+'*) printf '%s\tR\t%s\n' "$file" "$newl" >> "$tsv"; newl=$((newl+1));;
          ('-'*) printf '%s\tL\t%s\n' "$file" "$oldl" >> "$tsv"; oldl=$((oldl+1));;
          (*)    printf '%s\tR\t%s\n%s\tL\t%s\n' "$file" "$newl" "$file" "$oldl" >> "$tsv"; newl=$((newl+1)); oldl=$((oldl+1));;
        esac;;
    esac
  done < "$DIFF"
  jq -R -s 'split("\n") | map(select(length>0) | split("\t"))
    | group_by(.[0]) | map({key: .[0][0], value: {
        right: [.[] | select(.[1]=="R") | .[2] | tonumber],
        left:  [.[] | select(.[1]=="L") | .[2] | tonumber]}}) | from_entries' "$tsv" > "$CTX/hunks.json" 2>/dev/null \
    || printf '{}\n' > "$CTX/hunks.json"
  rm -f "$tsv"
}
in_hunk() { # <path> <line> [RIGHT|LEFT] → 0 when the line is inside this PR's hunks
  jq -e --arg p "$1" --argjson l "$2" --arg s "${3:-RIGHT}" \
    '.[$p] | (if $s == "LEFT" then .left else .right end) | index($l) != null' "$CTX/hunks.json" >/dev/null 2>&1
}

# --------------------------------------------------------- skill routing ----
skills_json() { # → [{skill, source, trigger, section}]
  cfg_table 'Review skills' | while IFS='|' read -r _ s src trig sec _rest; do
    s="$(trim "$s")"; case "$s" in (''|skill|-*|:*) continue;; esac
    jq -nc --arg s "$s" --arg src "$(trim "$src")" --arg t "$(trim "$trig")" --arg sec "$(trim "$sec")" '{skill:$s, source:$src, trigger:$t, section:$sec}'
  done | jq -s .
}

# ================================================================= prepare ====
emit_ready() { # <resumed-bool> — the prepare summary from the state files
  local j
  j="$(jq -n --slurpfile pr "$CTX/pr.json" --slurpfile sk "$CTX/skills.json" --slurpfile sl "$CTX/slice.json" --slurpfile f "$CTX/files.json" \
    --argjson resumed "$1" --arg pd "$PR_DIR" --arg diff "$DIFF" --arg ctx "$CTX" --arg out "$OUT" '
    $pr[0] + {outcome:"ready", resumed:$resumed,
      paths:{clone:$pd, diff:$diff, context:($ctx+"/context.json"), hunks:($ctx+"/hunks.json"), files:($ctx+"/files.json"),
             pack:($ctx+"/pack.json"), briefs:($ctx+"/briefs"), out:$out},
      files:$f[0], skills:$sk[0]} + $sl[0]')"
  out "$j"
}

cmd_prepare() {
  local ETA="" ONDEMAND=false me="${LOG_RUN_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
  while [ $# -gt 0 ]; do case "$1" in (--eta) ETA="${2:-}"; shift 2;; (--on-demand) ONDEMAND=true; shift;; (*) shift;; esac; done
  [ -n "$REPO" ] || fail "target repo unresolved"
  # re-entrant for the run that owns the state: a second prepare returns what
  # the first one built instead of standing down against itself
  if [ -f "$CTX/pr.json" ] && [ -f "$CTX/skills.json" ] && [ -n "$me" ] && [ "$(ctx_get '.run // empty')" = "$me" ]; then
    emit_ready true
  fi
  local PJ; PJ="$(pr_state)"; [ -n "$PJ" ] || fail "PR state unreadable (API) — retry once, then abort"
  local state draft merged sha ref base title author labels requested head_repo
  state="$(printf '%s' "$PJ" | jq -r .state)"; draft="$(printf '%s' "$PJ" | jq -r .draft)"; merged="$(printf '%s' "$PJ" | jq -r .merged)"
  sha="$(printf '%s' "$PJ" | jq -r .head_sha)"; ref="$(printf '%s' "$PJ" | jq -r .head_ref)"; base="$(printf '%s' "$PJ" | jq -r .base_ref)"
  title="$(printf '%s' "$PJ" | jq -r .title)"; author="$(printf '%s' "$PJ" | jq -r .author)"; head_repo="$(printf '%s' "$PJ" | jq -r .head_repo)"
  labels="$(printf '%s' "$PJ" | jq -c .labels)"; requested="$(printf '%s' "$PJ" | jq -c .requested)"

  local row row_status row_verdict row_sha row_ts kind=first full=true urgent=false mode=review prior=null
  row="$(row_for)"; row_status="$(row_field "$row" 6)"; row_verdict="$(row_field "$row" 5)"; row_sha="$(row_field "$row" 3)"; row_ts="$(row_field "$row" 4)"
  [ -f "$WORK/reviews/pr-$N.md" ] && kind="re-review"
  # the prior is a posted review the row records; a lock taken over from a
  # dead run has none (release_lock then deletes the row for self-heal)
  case "$row_status" in (done|awaiting_label)
    prior="$(jq -nc --arg s "$row_sha" --arg t "$row_ts" --arg v "$row_verdict" --arg st "$row_status" '{sha:$s, ts:$t, verdict:$v, status:$st}')";; esac
  [ -n "$URGENT_LABEL" ] && printf '%s' "$labels" | jq -e --arg x "$URGENT_LABEL" 'index($x) != null' >/dev/null 2>&1 && urgent=true

  # --- gates (Check 1) ---
  [ "$draft" = "true" ] && out "$(jq -nc '{outcome:"skip", reason:"draft"}')"
  # an on-demand ask for a PR already reviewed at its live HEAD: same-SHA dedup
  # (preflight-driven entries decided this already — an edited description
  # legitimately reviews the same SHA again)
  if [ "$ONDEMAND" = true ] && [ "$row_sha" = "$sha" ]; then
    case "$row_status" in (done|awaiting_label) out "$(jq -nc --arg s "${sha:0:7}" '{outcome:"skip", reason:("already reviewed at " + $s)}')";; esac
  fi
  if [ "$state" != "open" ]; then
    if [ "$row_status" = "in_progress" ] && [ "$row_verdict" = "RAPID" ]; then mode=closed
    else out "$(jq -nc --arg s "$([ "$merged" = "true" ] && echo MERGED || echo CLOSED)" '{outcome:"skip", reason:("pr " + $s + " — the next heartbeat prunes")}')"; fi
  fi
  if [ "$kind" = "re-review" ] && [ "$mode" = "review" ] && [ "$ONDEMAND" = false ] && ! trigger_live "$labels" "$requested"; then
    out "$(jq -nc '{outcome:"skip", reason:"re-review trigger withdrawn"}')"
  fi
  if [ "$kind" = "re-review" ]; then
    full=false; printf '%s' "$labels" | jq -e --arg x "$REREVIEW_LABEL" 'index($x) != null' >/dev/null 2>&1 && full=true
  fi
  if holder_alive; then
    logev info review_pr "PR #$N: holder alive at Check 1 — stood down"
    out "$(jq -nc '{outcome:"stand_down", reason:"a live run owns this PR (tree or recent events)"}')"
  fi
  [ "$mode" = "review" ] && cleanup      # a dead run's leftovers, or nothing
  mkdir -p "$CTX/briefs" 2>/dev/null || fail "cannot create $CTX"

  # --- lock ---
  local lock_verdict="-" now; now="$(now_iso)"
  [ "$row_verdict" = "RAPID" ] && [ "$row_status" = "in_progress" ] && lock_verdict="RAPID"
  write_row "$sha" "$now" "$lock_verdict" in_progress
  jq -nc --arg n "$N" --arg sha "$sha" --arg ref "$ref" --arg base "$base" --arg t "$title" --arg a "$author" \
    --arg k "$kind" --argjson full "$full" --argjson urgent "$urgent" --arg mode "$mode" --argjson prior "$prior" \
    --arg now "$now" --argjson labels "$labels" --argjson lv "$(printf '%s' "$PJ" | jq -c '{additions, deletions, changed_files}')" \
    --argjson rapid "$([ "$lock_verdict" = "RAPID" ] && echo true || echo false)" \
    --argjson od "$ONDEMAND" --arg run "$me" \
    '{number:($n|tonumber), head_sha:$sha, head_ref:$ref, base_ref:$base, title:$t, author:$a, kind:$k, full:$full,
      urgent:$urgent, mode:$mode, prior:$prior, locked_at:$now, labels:$labels, changes:$lv, rapid_posted:$rapid,
      on_demand:$od, run:(if $run=="" then null else $run end), clone:"pending"}' > "$CTX/pr.json"
  logstep "${sha:0:7} locked"
  [ -n "$ETA" ] && case "$ETA" in (*[!0-9]*) ETA="";; esac
  local eta_txt=""; [ -n "$ETA" ] && eta_txt=" · usually ~$(( (ETA + 59) / 60 < 1 ? 1 : (ETA + 59) / 60 )) min"
  progress pending "queued $(now_hm)Z · fetching diff and clone$eta_txt"

  # --- context: body, comments, reviews, inline threads (own artefacts dropped, bots flagged) ---
  local ctxj inline marker="<!-- $REVIEW_MARKER"
  ctxj="$(gh pr view "$N" --repo "$REPO" --json body,author,comments,reviews 2>/dev/null)"
  { printf '%s' "$ctxj" | jq -e 'type=="object"' >/dev/null 2>&1; } || { ctxj='{}'; logev warn gh_api "PR #$N: context fetch (pr view) did not respond — reviewing without it"; }
  inline="$(gh api "repos/$REPO/pulls/$N/comments?per_page=100" --paginate 2>/dev/null | jq -s 'map(select(type=="array")) | add // []' 2>/dev/null)"
  [ -n "$inline" ] || { inline='[]'; logev warn gh_api "PR #$N: inline threads did not respond — reviewing without them"; }
  jq -n --argjson c "$ctxj" --argjson i "$inline" --arg m "$marker" --arg bot "$BOT_LOGIN" --arg body "$(printf '%s' "$PJ" | jq -r .body)" '
    def own: ((.body // "") | contains($m));
    def isbot: ((.author.login // .user.login // "") == $bot) or ((.author.is_bot // false) == true) or ((.user.type // "") == "Bot");
    { body: $body, author: ($c.author.login // ""),
      comments: [ ($c.comments // [])[] | select(own | not) | {author: (.author.login // ""), is_bot: isbot, created_at: (.createdAt // ""), body: (.body // "")} ],
      reviews:  [ ($c.reviews // [])[]  | select(own | not) | {author: (.author.login // ""), is_bot: isbot, state, submitted_at: (.submittedAt // ""), body: (.body // "")} ],
      inline:   [ $i[] | select(own | not) | {author: (.user.login // ""), is_bot: isbot, path, line: (.line // .original_line), side: (.side // "RIGHT"), in_reply_to: .in_reply_to_id, created_at, body: (.body // "")} ] }' \
    > "$CTX/context.json" 2>/dev/null || printf '{}\n' > "$CTX/context.json"

  # --- diff + hunk index + files ---
  gh pr diff "$N" --repo "$REPO" > "$DIFF" 2>/dev/null || { : > "$DIFF"; logev warn gh_api "PR #$N: diff fetch did not respond"; }
  build_hunks
  grep -E '^\+\+\+ b/' "$DIFF" | sed 's#^+++ b/##' | sort -u | jq -R . | jq -s 'map({path:., status:"modified"})' > "$CTX/files.raw.json"
  local slice
  slice="$(bash "$SCRIPT_DIR/profile.sh" slice "$CTX/files.raw.json" 2>/dev/null)"
  { printf '%s' "$slice" | jq -e 'has("files")' >/dev/null 2>&1; } \
    || slice="$(jq -c '{files: map(. + {class:"code"}), noise_count:0, profile_slice:[], structure_changed:[], history_slice:[], memory_due:[]}' "$CTX/files.raw.json")"
  printf '%s' "$slice" | jq '.files' > "$CTX/files.json"
  printf '%s' "$slice" | jq '{profile_slice, structure_changed, history_slice, memory_due, noise_count}' > "$CTX/slice.json"
  rm -f "$CTX/files.raw.json"

  # --- clone + base ref (skipped in closed mode: the branch may be gone) ---
  local clone=skipped url
  if [ "$mode" = "review" ]; then
    url="${CG_CLONE_URL:-https://$REPO_HOST/$REPO.git}"
    clone=ok
    if [ -n "$head_repo" ] && [ "$head_repo" != "$REPO" ] && [ -z "${CG_CLONE_URL:-}" ]; then
      # fork PR: base-repo clone at the base branch, the PR head fetched by ref
      { git clone -q --depth 50 --branch "$base" --single-branch "$url" "$PR_DIR" \
        && git -C "$PR_DIR" fetch -q --depth 50 origin "pull/$N/head:refs/heads/pr-$N" "$base:refs/remotes/origin/$base" \
        && git -C "$PR_DIR" checkout -q "pr-$N"; } 2>/dev/null || clone=failed
    else
      { git clone -q --depth 50 --branch "$ref" --single-branch "$url" "$PR_DIR" \
        && git -C "$PR_DIR" fetch -q --depth 50 origin "$base:refs/remotes/origin/$base"; } 2>/dev/null || clone=failed
    fi
    if [ "$clone" = "ok" ]; then logstep "${sha:0:7} cloned"
    else rm -rf "$PR_DIR"; logev error clone "PR #$N: clone of $ref did not succeed — every skill is clone-failed"; fi
  fi
  jq --arg c "$clone" '.clone = $c' "$CTX/pr.json" > "$CTX/pr.json.tmp" && mv "$CTX/pr.json.tmp" "$CTX/pr.json"

  # --- skills: inclusive routing, per-skill copies, briefs from the template ---
  local skills nrun=0 tpl profile="$WORK/PROFILE.md"
  skills="$(skills_json)"
  tpl="$(cat "$SCRIPT_DIR/templates/skill-brief.md" 2>/dev/null)"
  local vl vlblock=""
  vl="$(jq -r '[.profile_slice[]? | select(.verify_live) | .row] + (.structure_changed // []) | unique | .[]' "$CTX/slice.json" 2>/dev/null | sed 's/^/- /')"
  [ -n "$vl" ] && vlblock=$' Rows and paths this PR itself changes — read them live, never from the map:\n'"$vl"
  local SK='{}' s trig files status brief copy fblock
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    trig="$(printf '%s' "$skills" | jq -r --arg s "$s" '.[] | select(.skill==$s) | .trigger')"
    files='[]'; status=run
    if [ "$trig" != "always" ]; then
      files="$(jq -c --arg t "$trig" '($t | split(",") | map(gsub("\\s";"") | select(length>0))) as $exts
        | [ .[] | .path | select((split("/") | last | if contains(".") then "." + (split(".") | last) else "" end) as $e | $exts | index($e) != null) ]' "$CTX/files.json")"
      [ "$(printf '%s' "$files" | jq length)" -eq 0 ] && status=no-matching-files
    fi
    [ "$status" = run ] && [ "$clone" != ok ] && status=clone-failed
    brief=""; copy=""
    if [ "$status" = run ]; then
      nrun=$((nrun+1)); copy="$PR_DIR"
      if [ "$trig" = "always" ]; then fblock=$'\nScope: the whole clone (an `always` skill).'
      else fblock=$'\nRouted files (paths relative to the working directory):\n'"$(printf '%s' "$files" | jq -r '.[] | "- " + .')"; fi
      brief="$CTX/briefs/$s.md"
      local t="$tpl"
      t="${t//\{\{SKILL\}\}/$s}"; t="${t//\{\{PR\}\}/$N}"; t="${t//\{\{REPO\}\}/$REPO_HOST/$REPO}"
      t="${t//\{\{HEAD_SHA\}\}/$sha}"; t="${t//\{\{BASE_REF\}\}/$base}"; t="${t//\{\{OUT_FILE\}\}/$OUT/$s.txt}"
      t="${t//\{\{PROFILE\}\}/$profile}"; t="${t//\{\{FILES_BLOCK\}\}/$fblock}"; t="${t//\{\{VERIFY_LIVE_BLOCK\}\}/$vlblock}"
      printf '%s\n' "$t" > "$brief.tmp"
      mv "$brief.tmp" "$brief"
    fi
    SK="$(printf '%s' "$SK" | jq --arg s "$s" --arg st "$status" --argjson f "$files" --arg b "$brief" --arg c "$copy" \
      '. + {($s): {status:$st, files:$f, brief:(if $b=="" then null else $b end), workdir:(if $c=="" then null else $c end)}}')"
  done < <(printf '%s' "$skills" | jq -r '.[].skill')
  if [ "$nrun" -gt 1 ]; then
    mkdir -p "$OUT"
    while IFS= read -r s; do
      [ -n "$s" ] || continue
      cp -a "$PR_DIR" "$PR_DIR.s-$s" 2>/dev/null && SK="$(printf '%s' "$SK" | jq --arg s "$s" --arg c "$PR_DIR.s-$s" '.[$s].workdir = $c')"
      sed -i.bak "s#{{WORKDIR}}#$PR_DIR.s-$s#g" "$CTX/briefs/$s.md" 2>/dev/null; rm -f "$CTX/briefs/$s.md.bak"
    done < <(printf '%s' "$SK" | jq -r 'to_entries[] | select(.value.status=="run") | .key')
  elif [ "$nrun" -eq 1 ]; then
    mkdir -p "$OUT"
    s="$(printf '%s' "$SK" | jq -r 'to_entries[] | select(.value.status=="run") | .key')"
    sed -i.bak "s#{{WORKDIR}}#$PR_DIR#g" "$CTX/briefs/$s.md" 2>/dev/null; rm -f "$CTX/briefs/$s.md.bak"
  fi
  printf '%s' "$SK" > "$CTX/skills.json"

  # --- context pack: per changed code/test file, who references it and its hunks ---
  if [ "$clone" = ok ]; then
    local pack='{}' p b deps tests
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      b="${p##*/}"; b="${b%.*}"
      # who references this file — a whole-word grep for its basename; names
      # under three characters match everything and are skipped
      deps='[]'
      [ "${#b}" -ge 3 ] && deps="$(git -C "$PR_DIR" grep -l -w -F -- "$b" -- . ":(exclude)$p" ':(exclude)*node_modules*' ':(exclude)*vendor*' ':(exclude)*dist*' ':(exclude)*.lock' 2>/dev/null | head -12 | jq -R . | jq -s .)"
      [ -n "$deps" ] || deps='[]'
      tests="$(printf '%s' "$deps" | jq -c '[ .[] | select(test("(^|/)(test|tests|__tests__|spec|specs|e2e)/") or test("\\.(test|spec)\\.[A-Za-z0-9]+$|_test\\.go$|(^|/)test_[^/]*\\.py$")) ]')"
      pack="$(printf '%s' "$pack" | jq --arg p "$p" --argjson d "$deps" --argjson t "$tests" \
        --argjson h "$(jq -c --arg p "$p" '.[$p].right // []' "$CTX/hunks.json")" \
        '.[$p] = {dependents: ($d - $t), tests: $t, changed_lines: $h}')"
    done < <(jq -r '.[] | select(.class == "code" or .class == "test") | .path' "$CTX/files.json" | head -30)
    printf '%s' "$pack" > "$CTX/pack.json"
  else printf '{}\n' > "$CTX/pack.json"; fi

  progress pending "reviewing since $(now_hm)Z · diff + $nrun skill(s)$eta_txt"
  emit_ready false
}

# ==================================================================== step ====
cmd_step() {
  need_ctx
  local text="$*"; [ -n "$text" ] || fail "milestone text missing"
  local row sha7; row="$(row_for)"; sha7="$(ctx_get '.head_sha' | cut -c1-7)"
  [ -n "$row" ] && write_row "$(row_field "$row" 3)" "$(now_iso)" "$(row_field "$row" 5)" "$(row_field "$row" 6)"
  case "$text" in
    (locked*) logstep "$sha7 $text";;
    (*) logstep "$sha7 $text"; logstep "$sha7 locked (refresh, $text)";;
  esac
  out "$(jq -nc --arg t "$text" '{outcome:"ok", step:$t}')"
}

# ================================================================= context ====
cmd_context() {
  need_ctx
  local path="${1:-}" line="${2:-}" radius="${3:-40}"
  [ -n "$path" ] && [ -n "$line" ] || fail "usage: context <n> <path> <line> [radius]"
  case "$path" in (/*|*..*) fail "path must be relative to the clone, without ..";; esac
  case "$line$radius" in (*[!0-9]*) fail "line and radius must be numbers";; esac
  [ -f "$PR_DIR/$path" ] || fail "$path is not in the clone (clone failed, or the path is wrong)"
  local from to total inpr="no (pre-existing at this line)"
  total="$(grep -c '' "$PR_DIR/$path")"
  from=$((line - radius)); [ "$from" -lt 1 ] && from=1
  to=$((line + radius)); [ "$to" -gt "$total" ] && to="$total"
  in_hunk "$path" "$line" && inpr="yes"
  printf '# %s:%s — lines %s-%s of %s — in this PR'"'"'s hunks: %s\n' "$path" "$line" "$from" "$to" "$total" "$inpr"
  sed -n "${from},${to}p" "$PR_DIR/$path" | { i="$from"; while IFS= read -r l; do printf '%6d\t%s\n' "$i" "$l"; i=$((i+1)); done; }
  exit 0
}

# =================================================================== sweep ====
cmd_sweep() {
  need_ctx
  local re="${1:-}"; [ -n "$re" ] || fail "usage: sweep <n> <ERE>"
  [ -d "$PR_DIR" ] || fail "no clone for PR #$N"
  local files hits untouched
  files="$(jq -r '.[] | select(.class == "code" or .class == "test" or .class == "config" or .class == "docs") | .path' "$CTX/files.json")"
  hits="$( [ -n "$files" ] && printf '%s\n' "$files" | while IFS= read -r f; do git -C "$PR_DIR" grep -nE -- "$re" -- "$f" 2>/dev/null; done | jq -R . | jq -s . )"
  [ -n "$hits" ] || hits='[]'
  local all=0 c
  while IFS= read -r c; do all=$((all + ${c:-0})); done < <(git -C "$PR_DIR" grep -c -E -- "$re" 2>/dev/null | sed -E 's/^.*:([0-9]+)$/\1/')
  untouched=$(( all - $(printf '%s' "$hits" | jq length) )); [ "$untouched" -lt 0 ] && untouched=0
  out "$(jq -nc --argjson h "$hits" --argjson u "$untouched" '{outcome:"ok", changed_files_hits:$h, untouched_code_hits:$u}')"
}

# ================================================================= collect ====
cmd_collect() {
  need_ctx
  local lines='[]' warns='[]' results='{}' s st f n files timing=""
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    st="$(jq -r --arg s "$s" '.[$s].status' "$CTX/skills.json")"
    files="$(jq -r --arg s "$s" '.[$s].files | length' "$CTX/skills.json")"
    f="$OUT/$s.txt"
    case "$st" in
      (run)
        if [ -s "$f" ]; then
          n="$(grep -cE '^- (🔴|🟡|🟢)' "$f" || true)"
          if [ "$(jq -r --arg s "$s" '.[$s].files | length' "$CTX/skills.json")" -gt 0 ]; then
            lines="$(printf '%s' "$lines" | jq --arg l "PR #$N: $s ran (findings=$n, files=$files)" '. + [$l]')"
          else lines="$(printf '%s' "$lines" | jq --arg l "PR #$N: $s ran (findings=$n)" '. + [$l]')"; fi
          # form checks: every 🔴/🟡 needs a Fix line; every finding needs a path:line anchor
          local blocking fixes anchors
          blocking="$(grep -cE '^- (🔴|🟡)' "$f" || true)"; fixes="$(grep -cE '^\s*\*\*Fix:\*\*' "$f" || true)"
          anchors="$(grep -E '^- (🔴|🟡|🟢)' "$f" | grep -cE '`[^`]+:[0-9]+`' || true)"
          [ "${fixes:-0}" -lt "${blocking:-0}" ] && warns="$(printf '%s' "$warns" | jq --arg w "$s: $((blocking - fixes)) blocking finding(s) without a **Fix:** line" '. + [$w]')"
          [ "${anchors:-0}" -lt "${n:-0}" ] && warns="$(printf '%s' "$warns" | jq --arg w "$s: $((n - anchors)) finding(s) without a \`path:line\` anchor" '. + [$w]')"
          timing="$timing$s.txt=$(stat -c '%Y' "$f" 2>/dev/null || stat -f '%m' "$f" 2>/dev/null) "
          results="$(printf '%s' "$results" | jq --arg s "$s" --arg st ran --argjson n "${n:-0}" --arg f "$f" '. + {($s): {status:$st, findings:$n, file:$f}}')"
        else
          lines="$(printf '%s' "$lines" | jq --arg l "PR #$N: $s skipped (skill-errored)" '. + [$l]')"
          results="$(printf '%s' "$results" | jq --arg s "$s" '. + {($s): {status:"skill-errored", findings:0, file:null}}')"
          logev error skill_run "PR #$N: $s produced no output file — skill-errored"
        fi;;
      (*)
        lines="$(printf '%s' "$lines" | jq --arg l "PR #$N: $s skipped ($st)" '. + [$l]')"
        results="$(printf '%s' "$results" | jq --arg s "$s" --arg st "$st" '. + {($s): {status:$st, findings:0, file:null}}')";;
    esac
  done < <(jq -r 'keys[]' "$CTX/skills.json")
  [ -n "$timing" ] && logev info skill_timing "PR #$N $timing"
  out "$(jq -nc --argjson l "$lines" --argjson w "$warns" --argjson r "$results" '{outcome:"ok", audit_lines:$l, form_warnings:$w, skills:$r}')"
}

# =================================================================== delta ====
# Prior findings-json vs the current findings: same file and a line within ±3
# → matched; a matched pair with a similar summary is `still`, a dissimilar one
# is `ambiguous` (the agent decides); unmatched prior → `fixed`; unmatched
# current → `new`. PR-local overrides suppress by file:line (±2) or symbol.
cmd_delta() {
  need_ctx
  local cur="${1:-}"; [ -f "$cur" ] || fail "usage: delta <n> <findings.json>"
  jq -e 'type=="array"' "$cur" >/dev/null 2>&1 || fail "$cur is not a JSON array of findings"
  local hist="$WORK/reviews/pr-$N.md" prior='[]' overrides='[]'
  if [ -f "$hist" ]; then
    prior="$(grep -o '<!-- findings-json: .* -->' "$hist" | tail -1 | sed -e 's/^<!-- findings-json: //' -e 's/ -->$//')"
    { printf '%s' "$prior" | jq -e 'type=="array"' >/dev/null 2>&1; } || prior='[]'
    overrides="$(sed -n '/^## PR-local overrides/,/^## /p' "$hist" | grep -E '^- ' | jq -R . | jq -s .)"
  fi
  local j
  j="$(jq -n --slurpfile c "$cur" --argjson p "$prior" --argjson o "$overrides" '
    def words: (ascii_downcase | gsub("[^a-z0-9 ]";" ") | split(" ") | map(select(length > 3)) | unique);
    def similar($a; $b): (($a|words) as $x | ($b|words) as $y | ($x - ($x - $y) | length) >= 2) or (($a|ascii_downcase) == ($b|ascii_downcase));
    def near($a; $b; $tol): ($a.file == $b.file) and ($a.line != null) and ($b.line != null) and ((($a.line - $b.line) | fabs) <= $tol);
    def ovr_hits($f): ($f.file // "") as $file | ($f.line // -1000) as $l
      | ((($f.summary // "") | ascii_downcase | split(" ") | .[0]) // "") as $w
      | [ $o[] | select(. as $line
          | ([ range(-2; 3) ] | any(. as $d | $line | contains("`" + $file + ":" + (($l + $d)|tostring) + "`")))
            or ($w != "" and ($line | ascii_downcase | contains($w)) and ($line | contains("`" + $file + "`")))) ];
    ($c[0]) as $cur
    | [ $p[] | select(.status != "fixed") ] as $open
    | { still: [ $open[] as $x | $cur[] | select(near(.; $x; 3) and similar(.summary; $x.summary)) | . + {prior_line: $x.line} ],
        ambiguous: [ $open[] as $x | $cur[] | select(near(.; $x; 3) and (similar(.summary; $x.summary) | not)) | {current: ., prior: $x} ],
        fixed: [ $open[] | . as $x | select([ $cur[] | select(near(.; $x; 3)) ] | length == 0) ],
        new: [ $cur[] | . as $y | select([ $open[] | select(near($y; .; 3)) ] | length == 0) ] }
    | .suppressed = [ .new[], .still[] | select((ovr_hits(.) | length) > 0) | . + {override: (ovr_hits(.)[0])} ]
    | .new = [ .new[] | select((ovr_hits(.) | length) == 0) ] | .still = [ .still[] | select((ovr_hits(.) | length) == 0) ]
    | .block = ( ["### Changes since last review"]
        + [ .fixed[] | "- ✅ **Fixed:** \(.summary) (`\(.file):\(.line // "-")`)" ]
        + [ .still[] | "- 🔁 **Still present:** \(.summary) (`\(.file):\(.line // "-")`)" ]
        + [ .new[]   | "- 🆕 **New:** \(.summary) (`\(.file):\(.line // "-")`)" ] | join("\n") )
    | . + {outcome:"ok", prior_count: ($p|length), overrides: $o}')"
  out "$j"
}

# =================================================================== rapid ====
cmd_rapid() {
  need_ctx
  local body=""; while [ $# -gt 0 ]; do case "$1" in (--body) body="${2:-}"; shift 2;; (*) shift;; esac; done
  [ -f "$body" ] || fail "usage: rapid <n> --body <file>"
  local sha; sha="$(ctx_get '.head_sha')"
  local m="<!-- $REVIEW_MARKER:rapid headRefOid=$sha -->" r
  r="$(gh_get "repos/$REPO/pulls/$N/reviews?per_page=100" | jq -r --arg m "$m" '[.[] | select(.body != null) | select(.body | contains($m))] | length' 2>/dev/null)"
  [ "${r:-0}" -gt 0 ] && out "$(jq -nc '{outcome:"already_posted", phase:"rapid"}')"
  { cat "$body"; printf '\n\n%s\n' "$m"; } | jq -Rs --arg sha "$sha" '{commit_id:$sha, event:"COMMENT", body:.}' > "$PAYLOAD"
  local resp
  resp="$(gh api "repos/$REPO/pulls/$N/reviews" -X POST --input "$PAYLOAD" 2>/dev/null)" \
    || { sleep 1; resp="$(gh api "repos/$REPO/pulls/$N/reviews" -X POST --input "$PAYLOAD" 2>/dev/null)"; } \
    || { rm -f "$PAYLOAD"; fail "rapid POST did not succeed after one retry"; }
  rm -f "$PAYLOAD"
  write_row "$sha" "$(now_iso)" RAPID in_progress
  jq '.rapid_posted = true' "$CTX/pr.json" > "$CTX/pr.json.tmp" && mv "$CTX/pr.json.tmp" "$CTX/pr.json"
  logstep "${sha:0:7} rapid posted"
  progress pending "rapid preliminary review posted · full review running" "$(printf '%s' "$resp" | jq -r '.html_url // empty')"
  out "$(printf '%s' "$resp" | jq -c '{outcome:"posted", phase:"rapid", review_id:.id, url:.html_url}')"
}

# ==================================================================== post ====
cmd_post() {
  need_ctx
  local VERDICT="" BODY="" FINDINGS="" COMMENTS="" CLOSED_ISSUE=""
  while [ $# -gt 0 ]; do case "$1" in
    (--verdict) VERDICT="${2:-}"; shift 2;; (--body) BODY="${2:-}"; shift 2;; (--findings) FINDINGS="${2:-}"; shift 2;;
    (--comments) COMMENTS="${2:-}"; shift 2;; (--closed-issue) CLOSED_ISSUE="${2:-}"; shift 2;; (*) shift;; esac; done
  case "$VERDICT" in (APPROVE|COMMENT|REQUEST_CHANGES) ;; (*) fail "--verdict must be APPROVE | COMMENT | REQUEST_CHANGES";; esac
  [ -f "$BODY" ] || fail "--body <file> missing"
  [ -f "$FINDINGS" ] && jq -e 'type=="array"' "$FINDINGS" >/dev/null 2>&1 || fail "--findings <file> must be a JSON array"
  [ -z "$COMMENTS" ] || { [ -f "$COMMENTS" ] && jq -e 'type=="array"' "$COMMENTS" >/dev/null 2>&1; } || fail "--comments <file> must be a JSON array"
  local sha kind title; sha="$(ctx_get '.head_sha')"; kind="$(ctx_get '.kind')"; title="$(ctx_get '.title')"
  local sha7="${sha:0:7}" now; now="$(now_iso)"

  # --- Check 2 ---
  local PJ state draft labels requested live_sha
  PJ="$(pr_state)"; [ -n "$PJ" ] || { sleep 1; PJ="$(pr_state)"; }
  [ -n "$PJ" ] || { release_lock "Check 2 unreadable (API) after retry"; cleanup; out "$(jq -nc '{outcome:"aborted", reason:"Check 2 unreadable"}')"; }
  state="$(printf '%s' "$PJ" | jq -r .state)"; draft="$(printf '%s' "$PJ" | jq -r .draft)"; live_sha="$(printf '%s' "$PJ" | jq -r .head_sha)"
  labels="$(printf '%s' "$PJ" | jq -c .labels)"; requested="$(printf '%s' "$PJ" | jq -c .requested)"

  # closed at post time → no review; criticals become an issue (docs/review.md)
  if [ "$state" != "open" ] || [ "$(ctx_get '.mode')" = "closed" ]; then
    local crit; crit="$(jq -c '[ .[] | select(.severity == "critical" and .status != "fixed") ]' "$FINDINGS")"
    if [ -n "$CLOSED_ISSUE" ]; then
      append_history "$sha7" "$now" "$VERDICT" "$BODY" "$FINDINGS" "_Delivered as issue #$CLOSED_ISSUE — PR closed before posting._"
      write_row "$sha" "$now" "$VERDICT" done
      progress success "PR closed · $(printf '%s' "$crit" | jq length) critical finding(s) in issue #$CLOSED_ISSUE"
      logstep "$sha7 done"
      logev info review_pr "PR #$N: closed mid-review — $(printf '%s' "$crit" | jq length) critical finding(s) filed as issue #$CLOSED_ISSUE"
      cleanup
      out "$(jq -nc --arg i "$CLOSED_ISSUE" '{outcome:"closed_filed", issue:($i|tonumber)}')"
    fi
    if [ "$(printf '%s' "$crit" | jq length)" -eq 0 ]; then
      release_lock "closed mid-review — discarded (no critical findings)"; cleanup
      out "$(jq -nc '{outcome:"closed_discarded"}')"
    fi
    local im="<!-- $REVIEW_MARKER:issue headRefOid=$sha -->" existing
    existing="$(gh_get "repos/$REPO/issues?state=all&per_page=100" | jq -r --arg m "$im" '[.[] | select((.body // "") | contains($m)) | .number] | first // empty' 2>/dev/null)"
    out "$(jq -nc --argjson c "$crit" --arg m "$im" --arg e "${existing:-}" --arg a "$(ctx_get '.author')" \
      '{outcome:"closed_criticals", criticals:$c, issue_marker:$m, existing_issue:(if $e=="" then null else ($e|tonumber) end), author:$a,
        next:"file the issue per docs/review.md → PR closed mid-review (or reuse existing_issue), then rerun post with --closed-issue <id>"}')"
  fi
  if [ "$live_sha" != "$sha" ]; then release_lock "HEAD moved $sha7 → ${live_sha:0:7} mid-review — discarding"; cleanup; out "$(jq -nc --arg o "$sha7" --arg n "${live_sha:0:7}" '{outcome:"aborted", reason:("HEAD moved " + $o + " → " + $n)}')"; fi
  if [ "$draft" = "true" ]; then release_lock "PR became draft mid-review — discarding"; cleanup; out "$(jq -nc '{outcome:"aborted", reason:"became draft"}')"; fi
  if [ "$kind" = "re-review" ] && [ "$(ctx_get '.on_demand // false')" != "true" ] && ! trigger_live "$labels" "$requested"; then
    release_lock "re-review trigger withdrawn mid-review — discarding"; cleanup; out "$(jq -nc '{outcome:"aborted", reason:"trigger withdrawn"}')"
  fi

  # --- pre-post dedup re-check ---
  # A marker at this SHA is a duplicate — unless this is a same-SHA re-review
  # (an edited description) and the marker is older than our lock: then it is
  # the prior review being superseded, not a concurrent post.
  local ts; ts="$(remote_reviewed_at "$sha")"
  if [ -n "$ts" ] && [ "$ts" != "__api_error__" ]; then
    if [ "$kind" = "re-review" ] && [ "$(ctx_get '.prior.sha // empty')" = "$sha" ] \
       && [ "$(iso2epoch "$ts")" -lt "$(iso2epoch "$(ctx_get '.locked_at')")" ]; then
      logev info review_pr "PR #$N: same-SHA re-review — the marker at $sha7 ($ts) is the prior review"
    else
      write_row "$sha" "$ts" SEE-GITHUB done
      logstep "$sha7 aborted duplicate (review already on GitHub at $ts)"
      cleanup
      out "$(jq -nc --arg t "$ts" '{outcome:"duplicate", reason:("a review with this marker already exists on GitHub (" + $t + ") — row self-healed")}')"
    fi
  fi

  # --- inline comments: eligibility against the hunk index, cap, priority ---
  local comments='[]' moved='[]'
  if [ -n "$COMMENTS" ]; then
    local elig
    elig="$(jq -c --slurpfile h "$CTX/hunks.json" '
      def sev: (.body // "") | if test("🔴") then 0 elif test("🟡") then 1 else 2 end;
      def ok: . as $c | ($h[0][$c.path] // {right:[],left:[]}) as $hk
        | ($c.line != null) and (if ($c.side // "RIGHT") == "LEFT" then ($hk.left | index($c.line)) else ($hk.right | index($c.line)) end) != null
        | . and (if $c.start_line == null then true else (if ($c.side // "RIGHT") == "LEFT" then ($hk.left | index($c.start_line)) else ($hk.right | index($c.start_line)) end) != null end);
      map(. + {eligible: ok, sev: sev})
      | (map(select(.eligible)) | sort_by(.sev)) as $e
      | {keep: ($e[:'"$INLINE_CAP"'] | map(del(.eligible, .sev))),
         moved: ((map(select(.eligible | not)) + $e['"$INLINE_CAP"':]) | map(del(.eligible, .sev) + {reason: (if .eligible == false then "line not in a diff hunk" else "inline cap" end)}))}' "$COMMENTS")"
    comments="$(printf '%s' "$elig" | jq -c '.keep')"; moved="$(printf '%s' "$elig" | jq -c '.moved')"
  fi

  # --- payload ---
  local emoji footer fj
  case "$VERDICT" in (APPROVE) emoji="✅";; (COMMENT) emoji="⚠️";; (REQUEST_CHANGES) emoji="❌";; esac
  footer="_Review by [$BOT_NAME](https://$DEF_HOST/$DEFINITION_REPO) · automated code guardian_"
  build_payload() { # <comments-json> <moved-json> → $PAYLOAD; findings-json gets inline:false for moved anchors
    fj="$(jq -c --argjson m "$2" 'map(. as $f | if any($m[]; .path == $f.file and .line == $f.line) then .inline = false else . end)' "$FINDINGS" | sed 's/--/–/g')"
    { printf '🛡️ **%s** — %s Code Review @ `%s`\n\n' "$BOT_NAME" "$emoji" "$sha7"
      cat "$BODY"
      if [ "$(printf '%s' "$2" | jq length)" -gt 0 ]; then
        printf '\n\n### Findings not anchorable inline\n\n'
        printf '%s' "$2" | jq -r '.[] | "- `\(.path):\(.line // "-")` — \(.body | gsub("\n"; "\n  "))"'
      fi
      printf '\n\n---\n%s\n\n\n<!-- findings-json: %s -->\n<!-- %s headRefOid=%s -->\n' "$footer" "$fj" "$REVIEW_MARKER" "$sha"
    } > "$CTX/body.posted.md"
    jq -Rs --arg sha "$sha" --arg ev "$VERDICT" --argjson c "$1" '{commit_id:$sha, event:$ev, body:., comments:$c}' "$CTX/body.posted.md" > "$PAYLOAD"
  }
  build_payload "$comments" "$moved"

  # --- POST, with the documented 422 handling ---
  local resp err rc=0
  resp="$(gh api "repos/$REPO/pulls/$N/reviews" -X POST --input "$PAYLOAD" 2>"$CTX/post.err")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    err="$(cat "$CTX/post.err" 2>/dev/null)"
    if printf '%s' "$err" | grep -qiE 'commit_id|not the latest|latest commit'; then
      release_lock "422 commit_id mismatch — HEAD moved at post time"; rm -f "$PAYLOAD"; cleanup
      out "$(jq -nc '{outcome:"aborted", reason:"422 commit_id mismatch"}')"
    fi
    if printf '%s' "$err" | grep -qiE '"line"|position|diff' && [ "$(printf '%s' "$comments" | jq length)" -gt 0 ]; then
      # line-not-in-diff: every inline comment moves to the summary, one retry
      moved="$(jq -nc --argjson m "$moved" --argjson c "$comments" '$m + ($c | map(. + {reason:"422 line not in diff"}))')"
      comments='[]'; build_payload "$comments" "$moved"
      logev warn post_retry "PR #$N: 422 on inline lines — retrying with every comment in the summary"
    else
      logev warn post_retry "PR #$N: POST did not succeed ($(printf '%s' "$err" | tr '\n' ' ' | cut -c1-160)) — one retry"; sleep 1
    fi
    rc=0; resp="$(gh api "repos/$REPO/pulls/$N/reviews" -X POST --input "$PAYLOAD" 2>"$CTX/post.err")" || rc=$?
    if [ "$rc" -ne 0 ]; then
      err="$(cat "$CTX/post.err" 2>/dev/null | tr '\n' ' ' | cut -c1-200)"
      logev error post_failed "PR #$N: review POST did not succeed after retry — $err"
      release_lock "post failed after retry"; rm -f "$PAYLOAD"; cleanup
      out "$(jq -nc --arg e "$err" '{outcome:"aborted", reason:"post failed after retry", error:$e}')"
    fi
  fi
  rm -f "$PAYLOAD"
  local rid url; rid="$(printf '%s' "$resp" | jq -r '.id // empty')"; url="$(printf '%s' "$resp" | jq -r '.html_url // empty')"
  logstep "$sha7 posted $VERDICT"

  # --- trigger removal, stale-approval dismissal ---
  local label_removed=false dismissed=null
  if printf '%s' "$labels" | jq -e --arg x "$REREVIEW_LABEL" 'index($x) != null' >/dev/null 2>&1; then
    if gh api -X DELETE "repos/$REPO/issues/$N/labels/$REREVIEW_LABEL" >/dev/null 2>&1; then label_removed=true
    else logev warn label_remove "PR #$N: removing $REREVIEW_LABEL did not succeed"; fi
  fi
  if [ "$kind" = "re-review" ] && [ "$VERDICT" != "APPROVE" ]; then
    local aid
    aid="$(gh_get "repos/$REPO/pulls/$N/reviews?per_page=100" | jq -r --arg b "$BOT_LOGIN" --arg m "<!-- $REVIEW_MARKER headRefOid=" --argjson me "${rid:-0}" \
      '[.[] | select(.id != $me and .state == "APPROVED" and (((.user.login // "") == $b) or ((.body // "") | contains($m))))] | last | .id // empty' 2>/dev/null)"
    if [ -n "$aid" ]; then
      if gh api "repos/$REPO/pulls/$N/reviews/$aid/dismissals" -X PUT -f event=DISMISS \
           -f message="Superseded by $BOT_NAME re-review at $sha7 — verdict is now $VERDICT." >/dev/null 2>&1; then
        dismissed="$aid"; logev info review_pr "PR #$N: dismissed stale approval $aid (APPROVE → $VERDICT)"
      else logev warn dismiss "PR #$N: dismissing stale approval $aid did not succeed"; fi
    fi
  fi

  # --- history (the body as posted), done row, terminal status, cleanup ---
  append_history "$sha7" "$now" "$VERDICT" "$CTX/body.posted.md" "$FINDINGS" ""
  write_row "$sha" "$now" "$VERDICT" done
  local c w s took
  c="$(jq '[.[] | select(.severity=="critical" and .status!="fixed")] | length' "$FINDINGS")"
  w="$(jq '[.[] | select(.severity=="warning" and .status!="fixed")] | length' "$FINDINGS")"
  s="$(jq '[.[] | select(.severity=="suggestion" and .status!="fixed")] | length' "$FINDINGS")"
  took=$(( (NOW_EPOCH - $(iso2epoch "$(ctx_get '.locked_at')")) / 60 )); [ "$took" -lt 0 ] && took=0
  progress success "$VERDICT · $c critical, $w warning, $s suggestion · took ${took}m" "$url"
  logstep "$sha7 done"
  cleanup
  out "$(jq -nc --arg v "$VERDICT" --arg id "$rid" --arg u "$url" --argjson m "$moved" --argjson lr "$label_removed" --argjson d "${dismissed:-null}" \
    --argjson c "$c" --argjson w "$w" --argjson s "$s" --argjson took "$took" \
    '{outcome:"posted", verdict:$v, review_id:(if $id=="" then null else ($id|tonumber) end), url:(if $u=="" then null else $u end),
      moved_to_summary:$m, label_removed:$lr, dismissed_approval:$d, counts:{critical:$c, warning:$w, suggestion:$s}, took_minutes:$took}')"
}

append_history() { # sha7 ts verdict body-file findings note — the body as posted
  local f="$WORK/reviews/pr-$N.md"
  mkdir -p "$WORK/reviews"
  [ -f "$f" ] || printf '# PR #%s: %s\n\n## PR-local overrides\n\n' "$N" "$(ctx_get '.title')" > "$f"
  { printf '\n## Review at %s — %s — %s\n\n' "$1" "$2" "$3"
    [ -n "$6" ] && printf '%s\n\n' "$6"
    cat "$4"
    grep -q '<!-- findings-json: ' "$4" || printf '\n\n<!-- findings-json: %s -->\n' "$(jq -c . "$5" | sed 's/--/–/g')"
    printf '\n---\n'
  } >> "$f"
}

# =================================================================== abort ====
cmd_abort() {
  need_ctx
  local reason="$*"; [ -n "$reason" ] || reason="aborted by the agent"
  release_lock "$reason"; rm -f "$PAYLOAD"; cleanup
  out "$(jq -nc --arg r "$reason" '{outcome:"aborted", reason:$r}')"
}

case "$CMD" in
  (prepare) cmd_prepare "$@";; (step) cmd_step "$@";; (context) cmd_context "$@";; (sweep) cmd_sweep "$@";;
  (collect) cmd_collect "$@";; (delta) cmd_delta "$@";; (rapid) cmd_rapid "$@";; (post) cmd_post "$@";; (abort) cmd_abort "$@";;
esac
