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
#     HEARTBEAT.log / SHEPHERD.log lines, and the skill install cache.
#
#   preflight.sh review    -> reviews_due / label_cleanups_due / selfheals_due
#                             / prunes_due / artifacts_due (+ skill install,
#                             SHA-cached, only when a review/artifact is due)
#   preflight.sh shepherd  -> nudges_due (classification + age gate + cooldown
#                             + escalation ladder already computed; the agent
#                             applies each row_update before sending)
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

LOGS=()
log() { LOGS+=("$1"); }

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
    curl -sSfL "https://raw.githubusercontent.com/$src/main/$p" -o "$HOME_DIR/.claude/skills/$name/$rel" || { printf 'install-failed'; return; }
    count=$((count+1))
  done < <(gh api "repos/$src/git/trees/main?recursive=1" 2>/dev/null \
           | jq -r --arg pre ".agents/skills/$name/" '.tree[] | select(.type=="blob") | select(.path | startswith($pre)) | .path')
  [ "$count" -eq 0 ] && { printf 'install-failed'; return; }
  [ -n "$sha" ] && printf '%s' "$sha" > "$SKILL_CACHE/$name.sha"
  printf 'installed (%s files)' "$count"
}

emit() { # reviews label_cleanups selfheals prunes artifacts nudges skills
  local nothing=true a
  for a in "$1" "$2" "$3" "$4" "$5" "$6"; do
    [ "$(printf '%s' "$a" | jq length)" -gt 0 ] && nothing=false
  done
  printf '%s\n' "$NOW_ISO $MODE nothing_to_do=$nothing ${LOGS[*]:-}" >> "$WORK/HEARTBEAT.log" 2>/dev/null
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
    [ -z "$cls" ] && cls="awaiting_review"

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

fail_out "unknown mode '$MODE' (use review|shepherd)"
