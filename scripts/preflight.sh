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
#     (pure bookkeeping mandated by the label gate — keeps transition logs
#     one-shot), shepherd-ledger bookkeeping for rows with no nudge due,
#     HEARTBEAT.log / SHEPHERD.log lines, structured events in work/logs/
#     (via scripts/log.sh — docs/logging.md), the skill install cache, and
#     the 14-day log retention cleanup in audit mode.
#
#   preflight.sh review    -> reviews_due / label_cleanups_due / selfheals_due
#                             / prunes_due / artifacts_due (+ skill install,
#                             SHA-cached, only when a review/artifact is due)
#   preflight.sh shepherd  -> nudges_due (classification + age gate + cooldown
#                             + escalation ladder already computed; the agent
#                             applies each row_update before sending)
#   preflight.sh audit     -> weekly health check: 7-day stats + deterministic
#                             checks (auth, state consistency, log gaps/errors,
#                             orphaned gists, disk, skills); the agent adds the
#                             judgment checks and sends the report (docs/audit.md)
#
# Output: a single JSON object on stdout. Agent contract:
#   .nothing_to_do == true  -> end the run immediately.
#   otherwise               -> process the arrays per CLAUDE.md + docs/.
#
# Requires: bash, gh (authenticated), jq, git, sed/grep/cut/tr, GNU date
# (Linux pod). Deliberately awk-free — awk is not available in the pod.

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
LOG_DIR="${LOG_DIR:-$WORK/logs}"

LOGS=()
log() { LOGS+=("$1"); logev info preflight "$1"; }

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

cfg() { sed -n "s/^- $1:[[:space:]]*//p" "$CONFIG" 2>/dev/null | head -1 \
        | sed -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//'; }

trim() { printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

iso2epoch() { date -d "$1" +%s 2>/dev/null || date -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || echo 0; }

# ---------------------------------------------------------------- config ----
REPO="${GITHUB_REPO:-$(cfg github_repo)}"
[ -z "$REPO" ] && REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)"
BOT_LOGIN="$(cfg bot_login)"
REVIEW_MARKER="$(cfg review_marker)"
REREVIEW_LABEL="$(cfg rereview_label)"; REREVIEW_LABEL="${REREVIEW_LABEL:-code-guardian-review}"
ARTIFACT="$(cfg artifact_skill)"
ARTIFACT_SKILL="${ARTIFACT%%@*}"; ARTIFACT_SRC="${ARTIFACT##*@}"
{ [ "$ARTIFACT" = "none" ] || [ -z "$ARTIFACT" ]; } && ARTIFACT_SKILL=""
SLACK="$(cfg slack_notifications)"
ESCALATION_OWNER="$(cfg escalation_owner)"

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

# marker-based remote dedup, anchored at one SHA -> prints GitHub timestamp
remote_reviewed_at() { # number full_sha
  local m="<!-- $REVIEW_MARKER headRefOid=$2 -->" ts
  ts="$(gh api "repos/$REPO/pulls/$1/reviews?per_page=100" 2>/dev/null \
        | jq -r --arg m "$m" '[.[] | select(.body != null) | select(.body | contains($m)) | .submitted_at] | last // empty')"
  [ -n "$ts" ] && { printf '%s' "$ts"; return; }
  gh api "repos/$REPO/issues/$1/comments?per_page=100" 2>/dev/null \
    | jq -r --arg m "$m" '[.[] | select(.body | contains($m)) | .created_at] | last // empty'
}

# unanchored: any marker-carrying review at ANY SHA -> prints "sha<TAB>ts"
remote_reviewed_any() { # number
  gh api "repos/$REPO/pulls/$1/reviews?per_page=100" 2>/dev/null \
    | jq -r --arg m "<!-- $REVIEW_MARKER headRefOid=" '
        [.[] | select(.body != null) | select(.body | contains($m))
             | {sha: (.body | capture("headRefOid=(?<s>[0-9a-f]{40})").s), ts: .submitted_at}]
        | last // empty | if . == "" or . == null then empty else "\(.sha)\t\(.ts)" end' 2>/dev/null
}

# ------------------------------------------------------------ skill install ----
install_skill() { # name source -> status string (local writes only)
  local name="$1" src="$2" sha cached count=0 p rel
  [ "$src" = "harness" ] && { printf 'harness'; return; }
  sha="$(gh api "repos/$src/commits/main" 2>/dev/null | jq -r '.sha // empty')"
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
    curl -sSfL "https://raw.githubusercontent.com/$src/main/$p" -o "$HOME_DIR/.claude/skills/$name/$rel" \
      || { logev error skill_install "$name from $src: fetch of $p did not succeed"; printf 'install-failed'; return; }
    count=$((count+1))
  done < <(gh api "repos/$src/git/trees/main?recursive=1" 2>/dev/null \
           | jq -r --arg pre ".agents/skills/$name/" '.tree[] | select(.type=="blob") | select(.path | startswith($pre)) | .path')
  [ "$count" -eq 0 ] && { logev error skill_install "$name from $src: no files found (tree listing empty or unreachable)"; printf 'install-failed'; return; }
  [ -n "$sha" ] && printf '%s' "$sha" > "$SKILL_CACHE/$name.sha"
  printf 'installed (%s files)' "$count"
}

emit() { # reviews label_cleanups selfheals prunes artifacts nudges skills
  local nothing=true a
  for a in "$1" "$2" "$3" "$4" "$5" "$6"; do
    [ "$(printf '%s' "$a" | jq length)" -gt 0 ] && nothing=false
  done
  printf '%s\n' "$NOW_ISO $MODE nothing_to_do=$nothing ${LOGS[*]:-}" >> "$WORK/HEARTBEAT.log" 2>/dev/null
  logev info heartbeat "mode=$MODE nothing_to_do=$nothing reviews=$(printf '%s' "$1" | jq length) nudges=$(printf '%s' "$6" | jq length)"
  jq -n --arg mode "$MODE" --argjson nothing "$nothing" \
    --argjson reviews "$1" --argjson cleanups "$2" --argjson selfheals "$3" \
    --argjson prunes "$4" --argjson artifacts "$5" --argjson nudges "$6" --argjson skills "$7" \
    --argjson logs "$(printf '%s\n' "${LOGS[@]:-}" | jq -R . | jq -s '[.[] | select(length>0)]')" \
    '{mode:$mode, nothing_to_do:$nothing, reviews_due:$reviews, label_cleanups_due:$cleanups,
      selfheals_due:$selfheals, prunes_due:$prunes, artifacts_due:$artifacts,
      nudges_due:$nudges, skills:$skills, logs:$logs}'
}

# =========================================================== REVIEW MODE ====
if [ "$MODE" = "review" ]; then
  REVIEWS_DUE='[]'; CLEANUPS_DUE='[]'; SELFHEALS_DUE='[]'; PRUNES_DUE='[]'; ARTIFACTS_DUE='[]'; SKILLS='{}'

  add_review() { # number sha ref title author kind takeover prior_json
    REVIEWS_DUE="$(printf '%s' "$REVIEWS_DUE" | jq --argjson e "$(jq -n \
      --argjson n "$1" --arg sha "$2" --arg ref "$3" --arg t "$4" --arg a "$5" \
      --arg k "$6" --argjson tk "$7" --argjson prior "$8" \
      '{number:$n, head_sha:$sha, head_ref:$ref, title:$t, author:$a, kind:$k, takeover:$tk, prior:$prior}')" '. + [$e]')"
  }

  # --- prune detection (verified per PR; the agent executes the prune) ---
  for n in $(reviews_rows | cut -d'|' -f2 | tr -d ' '); do
    open_numbers | grep -qx "$n" && continue
    if [ "$OPEN_COUNT" -eq 0 ]; then log "open PR list empty while rows exist — prune detection skipped (anomaly)"; break; fi
    state="$(gh api "repos/$REPO/pulls/$n" 2>/dev/null | jq -r 'if .merged then "MERGED" else (.state|ascii_upcase) end')"
    [ -z "$state" ] && logev warn gh_api "PR #$n: state check did not respond — prune skipped this run"
    case "$state" in
      CLOSED|MERGED)
        gid="$(grep -o '<!-- artifact-gist: [A-Za-z0-9]* -->' "$WORK/reviews/pr-$n.md" 2>/dev/null | head -1 | cut -d' ' -f3)"
        did="$(grep -o '<!-- artifact-dam: [A-Za-z0-9_-]* -->' "$WORK/reviews/pr-$n.md" 2>/dev/null | head -1 | cut -d' ' -f3)"
        PRUNES_DUE="$(printf '%s' "$PRUNES_DUE" | jq --argjson e "$(jq -n --argjson n "$n" --arg s "$state" --arg g "${gid:-}" --arg d "${did:-}" \
          '{number:$n, state:$s, gist_id:(if $g=="" then null else $g end), dam_id:(if $d=="" then null else $d end)}')" '. + [$e]')"
        log "PR #$n: $state — prune due";;
      *) : ;;  # OPEN / API error -> leave the row alone
    esac
  done

  # --- per-open-PR decision ---
  while IFS=$'\t' read -r n sha ref title author labels assignees; do
    has_label=0; printf '%s' "$labels" | tr ',' '\n' | grep -qx "$REREVIEW_LABEL" && has_label=1
    row="$(row_for "$n")"

    if [ -n "$row" ]; then
      row_sha="$(row_field "$row" 3)"; row_ts="$(row_field "$row" 4)"
      row_verdict="$(row_field "$row" 5)"; row_status="$(row_field "$row" 6)"
      prior="$(jq -n --arg sha "$row_sha" --arg ts "$row_ts" --arg v "$row_verdict" '{sha:$sha, ts:$ts, verdict:$v}')"

      if [ "$row_status" = "in_progress" ]; then
        age=$(( (NOW_EPOCH - $(iso2epoch "$row_ts")) / 60 ))
        if [ "$age" -lt 30 ]; then
          log "PR #$n: fresh in_progress lock (${age}m) — skipped"
        else
          kind="first"; [ -f "$WORK/reviews/pr-$n.md" ] && kind="re-review"
          log "PR #$n: stale in_progress lock (${age}m) — takeover"
          add_review "$n" "$sha" "$ref" "$title" "$author" "$kind" true "$prior"
        fi
      elif [ "$row_sha" = "$sha" ]; then
        # reviewed at live HEAD; label present -> same-SHA label cleanup (agent removes it)
        if [ "$has_label" -eq 1 ]; then
          CLEANUPS_DUE="$(printf '%s' "$CLEANUPS_DUE" | jq --argjson n "$n" '. + [$n]')"
          log "PR #$n: $REREVIEW_LABEL present but no new commits since ${row_sha:0:7} — label cleanup due"
        fi
      else
        # new commits since the recorded review
        if [ "$has_label" -eq 1 ]; then
          add_review "$n" "$sha" "$ref" "$title" "$author" "re-review" false "$prior"
        elif [ "$row_status" = "done" ]; then
          flip_awaiting_label "$n"
          log "PR #$n: new commits since last review — awaiting $REREVIEW_LABEL"
        fi   # already awaiting_label -> stay silent
      fi
    else
      # no local row: anchored remote check first, then the unanchored one
      ts="$(remote_reviewed_at "$n" "$sha")"
      if [ -n "$ts" ]; then
        SELFHEALS_DUE="$(printf '%s' "$SELFHEALS_DUE" | jq --argjson e "$(jq -n --argjson n "$n" --arg sha "$sha" --arg ts "$ts" \
          '{number:$n, sha:$sha, ts:$ts, status:"done"}')" '. + [$e]')"
        log "PR #$n: remote marker found at live HEAD — self-heal due"
      else
        any="$(remote_reviewed_any "$n")"
        if [ -n "$any" ]; then
          asha="${any%%$'\t'*}"; ats="${any##*$'\t'}"
          if [ "$has_label" -eq 1 ]; then
            add_review "$n" "$sha" "$ref" "$title" "$author" "re-review" false \
              "$(jq -n --arg sha "$asha" --arg ts "$ats" '{sha:$sha, ts:$ts, verdict:"SEE-GITHUB"}')"
          else
            SELFHEALS_DUE="$(printf '%s' "$SELFHEALS_DUE" | jq --argjson e "$(jq -n --argjson n "$n" --arg sha "$asha" --arg ts "$ats" \
              '{number:$n, sha:$sha, ts:$ts, status:"awaiting_label"}')" '. + [$e]')"
            log "PR #$n: reviewed on GitHub at ${asha:0:7} (no local row), new commits unlabeled — self-heal to awaiting_label due"
          fi
        else
          add_review "$n" "$sha" "$ref" "$title" "$author" "first" false null
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
             ((.assignees|join(","))|if .=="" then "-" else . end)] | @tsv')

  # install skills only when the agent will actually review / generate
  if [ "$(printf '%s' "$REVIEWS_DUE" | jq length)" -gt 0 ] \
     || [ "$(printf '%s' "$ARTIFACTS_DUE" | jq '[.[] | select(.action=="generate")] | length')" -gt 0 ]; then
    while IFS='|' read -r _ skill src _rest; do
      skill="$(trim "$skill")"; src="$(trim "$src")"
      case "$skill" in ''|skill|-*) continue;; esac
      SKILLS="$(printf '%s' "$SKILLS" | jq --arg k "$skill" --arg v "$(install_skill "$skill" "$src")" '. + {($k):$v}')"
    done < <(sed -n '/^## Review skills/,$p' "$CONFIG" 2>/dev/null | grep -E '^\|')
    if [ -n "$ARTIFACT_SKILL" ] && [ "$(printf '%s' "$ARTIFACTS_DUE" | jq '[.[] | select(.action=="generate")] | length')" -gt 0 ]; then
      SKILLS="$(printf '%s' "$SKILLS" | jq --arg k "$ARTIFACT_SKILL" --arg v "$(install_skill "$ARTIFACT_SKILL" "$ARTIFACT_SRC")" '. + {($k):$v}')"
    fi
  fi

  emit "$REVIEWS_DUE" "$CLEANUPS_DUE" "$SELFHEALS_DUE" "$PRUNES_DUE" "$ARTIFACTS_DUE" '[]' "$SKILLS"
  exit 0
fi

# ========================================================= SHEPHERD MODE ====
if [ "$MODE" = "shepherd" ]; then
  [ "$SLACK" = "enabled" ] || { log "slack notifications disabled — shepherd skipped"; emit '[]' '[]' '[]' '[]' '[]' '[]' '{}'; exit 0; }
  [ -f "$DEVELOPERS" ] || { log "work/DEVELOPERS.md missing — shepherd skipped"; emit '[]' '[]' '[]' '[]' '[]' '[]' '{}'; exit 0; }

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

    # class transition resets the ladder (never the clock)
    [ -n "$prev_state" ] && [ "$prev_state" != "$cls" ] && level=1

    age_h=$(( (NOW_EPOCH - $(iso2epoch "$eligible")) / 3600 ))
    since_last=999999; [ "$last" != "-" ] && since_last=$(( (NOW_EPOCH - $(iso2epoch "$last")) / 3600 ))

    due=0; new_status="watching"; next_level="$level"
    if [ "$cls" = "approved" ]; then new_status="approved"
    elif [ "$status" = "held" ] && { [ -z "$prev_state" ] || [ "$prev_state" = "$cls" ]; }; then new_status="held"  # hold is sticky until the class changes
    elif [ "$age_h" -lt 24 ]; then new_status="watching"
    elif [ "$since_last" -lt 20 ]; then new_status="${status:-watching}"
    elif [ "$nudges" -eq 0 ]; then due=1; next_level=1
    elif [ "$since_last" -ge 48 ]; then due=1; next_level=$((level+1)); [ "$next_level" -gt 4 ] && next_level=4
    else new_status="${status:-watching}"
    fi

    if [ "$due" -eq 1 ]; then
      if [ "$cls" = "changes_requested" ]; then
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
        --argjson nn "$((nudges+1))" --arg ns "$nudge_status" \
        '{number:$n, title:$t, author:$a, url:$u, age_hours:$age, class:$c, level:$l, targets:$tg, mentions:$m,
          needs_target_selection: ($m|length==0 and $c!="changes_requested"),
          escalation:{login:$eo, slack_id:$eid},
          row_update:{nudges:$nn, level:$l, status:$ns}}')" '. + [$e]')"
      log "PR #$n: nudge L$next_level due ($cls, ${age_h}h)"
      # write-before-send belongs to the agent: keep the row EXACTLY as-is
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
    printf '_Bookkeeping maintained by scripts/preflight.sh shepherd (table only — the agent updates a row only as the write-before-send step of a nudge). Per-sweep history lives in SHEPHERD.log, append-only, never loaded into agent context._\n\n'
    printf '| PR | eligible_since | reviewers | review_state | nudges | last_nudge_at | level | status |\n'
    printf '|----|----------------|-----------|--------------|--------|---------------|-------|--------|\n'
    printf '%s' "$NEW_TABLE"
  } > "$SHEPHERD"
  printf '%s shepherd sweep: %s open PRs, %s nudges due\n' "$NOW_ISO" "$OPEN_COUNT" "$(printf '%s' "$NUDGES_DUE" | jq length)" >> "$WORK/SHEPHERD.log"

  emit '[]' '[]' '[]' '[]' '[]' "$NUDGES_DUE" '{}'
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

  # --- connectivity -----------------------------------------------------
  me="$(gh api user 2>/dev/null | jq -r '.login // empty')"
  if [ -z "$me" ]; then check github_auth fail "gh api user failed — token broken"
  elif [ -n "$BOT_LOGIN" ] && [ "$me" != "$BOT_LOGIN" ]; then check github_auth warn "authenticated as $me, expected $BOT_LOGIN"
  else check github_auth ok "authenticated as $me"; fi

  rl="$(gh api rate_limit 2>/dev/null | jq -r '.resources.core.remaining // empty')"
  if [ -z "$rl" ]; then check rate_limit warn "rate_limit endpoint unreadable"
  elif [ "$rl" -lt 500 ]; then check rate_limit warn "only $rl core API calls remaining this hour"
  else check rate_limit ok "$rl core API calls remaining"; fi

  check target_repo ok "$OPEN_COUNT open non-draft PRs listed"

  if [ -n "${GITHUB_REPO_WORK:-}" ]; then
    if [ -e "$WORK/.git" ]; then
      check work_repo warn "work/.git present — work/ must be a plain data dir (backup runs in a tmpfs clone); remove it per docs/persistence.md"
    else
      check work_repo ok "work/ plain data dir; durable backup via tmpfs clone (any work_backup push errors surface in the log triage below)"
    fi
  else check work_repo ok "local-only persistence (GITHUB_REPO_WORK unset)"; fi

  nfs_n="$(find "$WORK" -name '.nfs*' 2>/dev/null | grep -c . || true)"
  if [ "${nfs_n:-0}" -gt 0 ]; then check nfs_junk warn "$nfs_n .nfs* silly-rename file(s) under work/ — something still deletes files another process holds open"
  else check nfs_junk ok "no .nfs* silly-rename files under work/"; fi

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
    [ "$age" -gt 30 ] && stale_locks="${stale_locks:+$stale_locks, }#$(row_field "$row" 2) (${age}m)"
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

  drift=""; verified=0
  while IFS=$'\t' read -r n sha; do
    row="$(row_for "$n")"; [ -z "$row" ] && continue
    st="$(row_field "$row" 6)"; { [ "$st" = "done" ] || [ "$st" = "awaiting_label" ]; } || continue
    [ "$verified" -ge 25 ] && break
    verified=$((verified+1))
    rsha="$(row_field "$row" 3)"
    [ -z "$(remote_reviewed_at "$n" "$rsha")" ] && drift="${drift:+$drift, }#$n"
  done < <(printf '%s' "$OPEN_NONDRAFT" | jq -r '.[] | [.number, .head_sha] | @tsv')
  [ -n "$drift" ] && check state_drift fail "rows whose SHA has no marker on GitHub: $drift" \
    || check state_drift ok "$verified open-PR rows verified against GitHub markers"

  # --- artifacts & hygiene --------------------------------------------------
  if [ -n "$ARTIFACT_SKILL" ]; then
    gist_ids="$(gh api "gists?per_page=100" 2>/dev/null | jq -r '.[] | select((.description // "") | test("review artifact")) | .id')"
    markers="$(grep -ho '<!-- artifact-gist: [A-Za-z0-9]* -->' "$WORK"/reviews/pr-*.md 2>/dev/null | cut -d' ' -f3 | sort -u)"
    orphans=""
    for g in $gist_ids; do printf '%s\n' "$markers" | grep -qx "$g" || orphans="${orphans:+$orphans, }$g"; done
    [ -n "$orphans" ] && check orphan_gists warn "artifact gists with no marker (leaked, never pruned): $orphans" \
      || check orphan_gists ok "every artifact gist is tracked by a marker"
  fi

  tmp_left="$(ls -d /tmp/review-pr-* 2>/dev/null | grep -c . || true)"
  [ "$tmp_left" -gt 0 ] && check tmp_leftovers warn "$tmp_left leftover /tmp/review-pr-* directories" || check tmp_leftovers ok "no clone leftovers"

  disk="$(df -P "$WORK" 2>/dev/null | tail -1 | tr -s ' ' | cut -d' ' -f5 | tr -d '%')"
  if [ -n "$disk" ] && [ "$disk" -gt 85 ]; then check disk warn "work volume ${disk}% full"; else check disk ok "work volume ${disk:-?}% used"; fi

  while IFS='|' read -r _ skill src _rest; do
    skill="$(trim "$skill")"; src="$(trim "$src")"
    case "$skill" in (''|skill|-*) continue;; esac
    [ "$src" = "harness" ] && continue
    remote_sha="$(gh api "repos/$src/commits/main" 2>/dev/null | jq -r '.sha // empty')"
    cached="$(cat "$SKILL_CACHE/$skill.sha" 2>/dev/null || true)"
    if [ -z "$remote_sha" ]; then check "skill_$skill" warn "source $src unreachable"
    elif [ "$remote_sha" != "$cached" ]; then check "skill_$skill" ok "update available (installs on next review)"
    else check "skill_$skill" ok "installed and current"; fi
  done < <(sed -n '/^## Review skills/,$p' "$CONFIG" 2>/dev/null | grep -E '^\|')

  if [ "$SLACK" = "enabled" ]; then
    if [ ! -f "$DEVELOPERS" ]; then check roster fail "slack enabled but work/DEVELOPERS.md missing"
    elif [ -n "$ESCALATION_OWNER" ] && ! grep -q "$ESCALATION_OWNER" "$DEVELOPERS"; then check roster warn "escalation_owner '$ESCALATION_OWNER' not found in the roster"
    else check roster ok "roster present, escalation owner listed"; fi
  fi

  if [ -d "$HOME_DIR/.git" ]; then
    def_dirty="$(git -C "$HOME_DIR" status --porcelain 2>/dev/null | grep -c . || true)"
    [ "$def_dirty" -gt 0 ] && check definition warn "$def_dirty uncommitted changes in the definition checkout" \
      || check definition ok "definition checkout clean ($(git -C "$HOME_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null))"

    # definition version currency: latest (origin/main) vs checkout vs adopted
    git -C "$HOME_DIR" fetch -q origin main 2>/dev/null
    latest_v="$(git -C "$HOME_DIR" show origin/main:VERSION 2>/dev/null | head -1 | tr -d '[:space:]')"
    checkout_v="$(head -1 "$HOME_DIR/VERSION" 2>/dev/null | tr -d '[:space:]')"
    adopted_v="$(head -1 "$WORK/VERSION" 2>/dev/null | tr -d '[:space:]')"
    if [ -z "$latest_v" ]; then check definition_version warn "origin/main VERSION unreadable (fetch blocked, or main predates versioning)"
    elif [ "$checkout_v" != "$latest_v" ]; then check definition_version warn "definition outdated: running ${checkout_v:-pre-versioning}, latest is $latest_v — ask the agent to update in the direct session"
    elif [ "$adopted_v" != "$checkout_v" ]; then check definition_version warn "update pulled but not adopted: work/VERSION is ${adopted_v:-missing} vs $checkout_v — migration pending (docs/persistence.md)"
    else check definition_version ok "definition current ($checkout_v, migration adopted)"; fi
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

  # weekly token totals from `tokens` events (best-effort; msg format written
  # by harness/claude-code/log-session-tokens.sh — keep the capture in sync)
  TOKENS_WEEK="$(ev_jsonl | jq -rs --arg s "$SINCE_ISO" '
    [.[] | select(.ts >= $s and .event=="tokens") | .msg
     | capture("input=(?<i>[0-9]+) output=(?<o>[0-9]+) cache_read=(?<cr>[0-9]+) cache_creation=(?<cc>[0-9]+)")]
    | {runs: length, input: ([.[].i | tonumber] | add // 0), output: ([.[].o | tonumber] | add // 0),
       cache_read: ([.[].cr | tonumber] | add // 0), cache_creation: ([.[].cc | tonumber] | add // 0)}' 2>/dev/null)"
  [ -n "$TOKENS_WEEK" ] || TOKENS_WEEK='{"runs":0}'

  if [ "${CLAUDECODE:-}" = "1" ]; then
    if grep -q "harness/claude-code/log-tool-event.sh" "$HOME_DIR/.claude/settings.json" 2>/dev/null; then
      check harness_adapter ok "Claude Code hooks registered (automatic tool-failure logging)"
    else
      check harness_adapter warn "Claude Code harness but hooks not registered — run scripts/harness/claude-code/install.sh"
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
  logev info log_cleanup "retention: removed $removed events file(s) older than 14d, trimmed HEARTBEAT/SHEPHERD to 14d"

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

  STATS="$(jq -n --arg since "$SINCE_ISO" \
    --argjson open "$OPEN_COUNT" --argjson rv "$rv_total" --argjson rf "$rv_first" --argjson rr "$rv_re" \
    --argjson va "$v_app" --argjson vc "$v_com" --argjson vq "$v_req" \
    --argjson hb "$hb_total" --argjson idle "$hb_idle" --argjson nd "$nudges_wk" \
    --argjson le "$ev_err" --argjson lw "$ev_warn" --argjson tw "$TOKENS_WEEK" \
    '{since:$since, open_prs:$open,
      reviews:{total:$rv, first:$rf, re_review:$rr, approve:$va, comment:$vc, request_changes:$vq},
      heartbeats:{total:$hb, idle:$idle}, nudges_claimed:$nd,
      log_events:{errors:$le, warns:$lw}, tokens:$tw}')"

  # wording note: never write the substring "fail"/"error" into this line —
  # the next audit's log_errors grep would flag it as a false positive
  printf '%s\n' "$NOW_ISO audit nothing_to_do=false checks=$(printf '%s' "$CHECKS" | jq length) red=$(printf '%s' "$CHECKS" | jq '[.[]|select(.status=="fail")]|length')" >> "$WORK/HEARTBEAT.log" 2>/dev/null
  jq -n --argjson stats "$STATS" --argjson checks "$CHECKS" \
    --argjson logs "$(printf '%s\n' "${LOGS[@]:-}" | jq -R . | jq -s '[.[] | select(length>0)]')" \
    '{mode:"audit", nothing_to_do:false, stats:$stats, checks:$checks, logs:$logs}'
  exit 0
fi

fail_out "unknown mode '$MODE' (use review|shepherd|audit)"
