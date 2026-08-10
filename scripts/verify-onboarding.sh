#!/usr/bin/env bash
# verify-onboarding.sh — one-shot structure verification of an onboarded agent.
#
# Runs once at the end of ONBOARDING (Step 7, after the sentinel is written)
# and checks that onboarding produced what it promises: the definition
# checkout at $HOME and the work/ state files, with the STRUCTURE the
# templates define (ONBOARDING Steps 3b/4, docs/review.md → Tracking format).
# Shape only — required files, required keys, enum values, table headers,
# row formats; the data inside is never judged. The goal: every deployed
# instance looks the same apart from its configuration values.
#
# Detects, never repairs (same contract as preflight.sh): fully offline, no
# GitHub calls, no writes beyond one structured log event. Every FAIL line
# carries a `fix:` instruction for the agent to apply; re-run after fixing
# until the script prints PASS.
#
#   ok   <check> — <detail>                      passed
#   warn <check> — <detail>                      informational, never blocks
#   FAIL <check> — <problem> — fix: <instruction>
#
# Exit 0 iff nothing FAILed.
#
# Requires: bash, git, jq, sed/grep/cut/tr (no awk — not available in the pod).

set -u
export LC_ALL=C

HOME_DIR="${HOME:-/home/agent}"
WORK="${WORK_DIR:-$HOME_DIR/work}"
CONFIG="$WORK/CONFIG.md"

# structured events log (docs/logging.md); no-op fallback keeps set -u safe
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if ! . "$SCRIPT_DIR/log.sh" 2>/dev/null; then logev() { :; }; fi

CHECKS=0; FAILS=0; WARNS=0
ok()   { CHECKS=$((CHECKS+1)); printf 'ok   %s — %s\n' "$1" "$2"; }
fail() { CHECKS=$((CHECKS+1)); FAILS=$((FAILS+1)); printf 'FAIL %s — %s — fix: %s\n' "$1" "$2" "$3"; }
warn() { WARNS=$((WARNS+1)); printf 'warn %s — %s\n' "$1" "$2"; }

cfg() { sed -n "s/^- $1:[[:space:]]*//p" "$CONFIG" 2>/dev/null | head -1 \
        | sed -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//'; }
trim() { printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

# ---------------------------------------------------------------- definition
if [ -d "$HOME_DIR/.git" ]; then
  ok def-git "definition checkout present at \$HOME"

  if grep -q '^/\*$' "$HOME_DIR/.gitignore" 2>/dev/null; then
    ok def-gitignore "allowlist .gitignore in place ('/*' rule)"
  else
    fail def-gitignore "the allowlist rule '/*' is missing from .gitignore" \
      "restore the repo's own file: git -C \"\$HOME\" checkout -- .gitignore (ONBOARDING Step 1)"
  fi

  DIRTY="$(git -C "$HOME_DIR" status --porcelain 2>/dev/null)"
  if [ -z "$DIRTY" ]; then
    ok def-clean "git status clean — no leaks, no modified or missing definition files"
  else
    fail def-clean "git status not clean: $(printf '%s' "$DIRTY" | head -5 | tr '\n' ';' )" \
      "untracked paths (work/, .ssh, …) mean a broken allowlist — fix .gitignore per ONBOARDING Step 2; a modified/deleted definition file is restored with git -C \"\$HOME\" checkout -- <file> (never git clean)"
  fi

  # definition_repo is `[<host>/]<owner>/<repo>`; a bare slug means the ambient
  # default host, so origin must still name that host and not just any
  DEF_REF="$(cfg definition_repo)"
  if [ -n "$DEF_REF" ]; then
    case "$DEF_REF" in
      (*/*/*) DEF_HOST="${DEF_REF%%/*}"; DEF_REPO="${DEF_REF#*/}";;
      (*)     DEF_HOST="${GH_HOST:-github.com}"; DEF_REPO="$DEF_REF";;
    esac
    ORIGIN="$(git -C "$HOME_DIR" remote get-url origin 2>/dev/null)"
    case "$ORIGIN" in
      *"$DEF_HOST"[:/]"$DEF_REPO".git|*"$DEF_HOST"[:/]"$DEF_REPO")
        ok def-origin "origin matches definition_repo" ;;
      *)
        fail def-origin "origin is '$ORIGIN' but definition_repo is '$DEF_REF'" \
          "git -C \"\$HOME\" remote set-url origin \"https://<host>/<owner/repo>.git\" — or correct the definition_repo key" ;;
    esac
  fi

  DEF_BRANCH="$(cfg definition_branch)"; DEF_BRANCH="${DEF_BRANCH:-main}"
  CUR_BRANCH="$(git -C "$HOME_DIR" symbolic-ref --short -q HEAD 2>/dev/null)"
  if [ "$CUR_BRANCH" = "$DEF_BRANCH" ]; then
    ok def-branch "checkout on '$DEF_BRANCH'"
  else
    fail def-branch "checkout is on '${CUR_BRANCH:-<detached>}' but definition_branch is '$DEF_BRANCH'" \
      "switch back per docs/persistence.md → Tracked branch"
  fi
else
  fail def-git "no git repository at \$HOME" "run ONBOARDING Step 1 (init + fetch + hard reset — never git clone into \$HOME)"
fi

SENTINEL="$HOME_DIR/.code-guardian-onboarded"
if [ ! -f "$SENTINEL" ]; then
  fail sentinel "\$HOME/.code-guardian-onboarded missing" \
    "finish ONBOARDING Step 7 (it writes the sentinel), then re-run this script"
elif head -1 "$SENTINEL" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'; then
  ok sentinel "present with a UTC timestamp"
else
  fail sentinel "content is not a UTC timestamp" \
    'date -u +%Y-%m-%dT%H:%M:%SZ > "$HOME/.code-guardian-onboarded"'
fi

# Harness adapter (ONBOARDING Step 1b) — only checkable on the Claude Code harness.
if [ "${CLAUDECODE:-}" != "1" ]; then
  ok hooks "not the Claude Code harness — adapter hooks not applicable"
else
  SETTINGS="$HOME_DIR/.claude/settings.json"
  MISSING_HOOKS=""
  for h in log-tool-event.sh log-session-tokens.sh log-review-step.sh enforce-review-completion.sh; do
    grep -q "$h" "$SETTINGS" 2>/dev/null || MISSING_HOOKS="$MISSING_HOOKS $h"
  done
  if [ -z "$MISSING_HOOKS" ]; then
    ok hooks "all adapter hooks registered in .claude/settings.json"
  else
    fail hooks "hooks not registered:$MISSING_HOOKS" \
      "bash \"\$HOME/scripts/harness/claude-code/install.sh\" (ONBOARDING Step 1b, idempotent)"
  fi
fi

# --------------------------------------------------------------------- work/
if [ ! -d "$WORK" ]; then
  fail work-dir "work/ does not exist" "run ONBOARDING Step 3 (provision work/)"
else
  ok work-dir "work/ present"

  if [ -e "$WORK/.git" ]; then
    fail work-plain "work/.git exists — work/ must stay a plain data directory (docs/persistence.md)" \
      "delete the stray work/.git directory (state files stay in place; backup history lives on the \$GITHUB_REPO_WORK remote)"
  else
    ok work-plain "plain data directory (no .git)"
  fi

  # --- CONFIG.md: required keys, slug shapes, enum values
  if [ ! -f "$CONFIG" ]; then
    fail config "work/CONFIG.md missing" "create it with the operator per ONBOARDING Step 4"
  else
    ok config "work/CONFIG.md present"

    for k in definition_repo bot_login review_marker; do
      if [ -n "$(cfg "$k")" ]; then
        ok "config-$k" "set"
      else
        fail "config-$k" "required key missing or empty" \
          "add '- $k: …' per ONBOARDING Step 4 (semantics: CLAUDE.md → Runtime configuration)"
      fi
    done

    for k in definition_repo github_repo; do
      v="$(cfg "$k")"
      if [ -n "$v" ] && ! printf '%s' "$v" | grep -Eq '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'; then
        fail "config-$k-shape" "'$v' is not an owner/repo slug" "correct the '- $k:' value"
      fi
    done

    chk_enum() { # <key> <allowed-regex> <allowed-list-for-humans>
      local v; v="$(cfg "$1")"
      [ -z "$v" ] && return 0
      if printf '%s' "$v" | grep -Eq "^($2)\$"; then
        ok "config-$1" "'$v'"
      else
        fail "config-$1" "invalid value '$v'" "set one of: $3 (CLAUDE.md → Runtime configuration)"
      fi
    }
    chk_enum slack_notifications 'enabled|disabled' 'enabled | disabled'
    chk_enum rereview_trigger 'label|review-request|both' 'label | review-request | both'
    chk_enum mention_replies 'enabled|disabled' 'enabled | disabled'
    chk_enum review_progress 'enabled|disabled' 'enabled | disabled'
    chk_enum audit_report 'enabled|disabled' 'enabled | disabled'
    chk_enum log_level 'info|debug' 'info | debug'
    chk_enum stall_alert_threshold '[0-9]+|off' 'an integer | 0 | off'

    AS="$(cfg artifact_skill)"
    if [ -n "$AS" ] && [ "$AS" != "none" ]; then
      if printf '%s' "$AS" | grep -Eq '^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'; then
        ok config-artifact_skill "'$AS'"
      else
        fail config-artifact_skill "invalid value '$AS'" "use '<skill>@<owner/repo>' or 'none'"
      fi
      AT="$(cfg artifact_targets)"; AT="${AT:-gist}"
      BAD_T=""
      for t in $(printf '%s' "$AT" | tr ',' ' '); do
        case "$t" in gist|dam) ;; *) BAD_T="$BAD_T $t" ;; esac
      done
      if [ -z "$BAD_T" ]; then
        ok config-artifact_targets "'$AT'"
      else
        fail config-artifact_targets "unknown target(s):$BAD_T" "use a comma-separated subset of: gist, dam"
      fi
    fi

    # --- ## Review skills table shape (rows: docs/skills.md)
    if grep -q '^## Review skills' "$CONFIG"; then
      SKILL_ROWS="$(sed -n '/^## Review skills/,/^## [^#]/p' "$CONFIG" | grep '^|' | grep -v '^|[ :-]*|' || true)"
      HEADER="$(printf '%s\n' "$SKILL_ROWS" | head -1)"
      if printf '%s' "$HEADER" | grep -Eq '^\|[[:space:]]*skill[[:space:]]*\|[[:space:]]*source[[:space:]]*\|[[:space:]]*trigger[[:space:]]*\|[[:space:]]*section[[:space:]]*\|$'; then
        ok skills-header "review-skills table header matches"
      elif [ -n "$HEADER" ]; then
        fail skills-header "unexpected header '$HEADER'" \
          "use '| skill | source | trigger | section |' (ONBOARDING Step 4 item 7, docs/skills.md)"
      fi
      BAD_SKILL=""
      while IFS= read -r row; do
        [ -z "$row" ] && continue
        cells=$(printf '%s' "$row" | tr -cd '|' | wc -c | tr -d ' ')
        src="$(trim "$(printf '%s' "$row" | cut -d'|' -f3)")"
        if [ "$cells" -ne 5 ] \
           || [ -z "$(trim "$(printf '%s' "$row" | cut -d'|' -f2)")" ] \
           || [ -z "$(trim "$(printf '%s' "$row" | cut -d'|' -f4)")" ] \
           || [ -z "$(trim "$(printf '%s' "$row" | cut -d'|' -f5)")" ] \
           || { [ "$src" != "harness" ] && ! printf '%s' "$src" | grep -Eq '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'; }; then
          BAD_SKILL="$BAD_SKILL | $row"
        fi
      done <<EOF
$(printf '%s\n' "$SKILL_ROWS" | tail -n +2)
EOF
      if [ -z "$BAD_SKILL" ]; then
        ok skills-rows "review-skills rows well-formed"
      else
        fail skills-rows "malformed row(s):$BAD_SKILL" \
          "each row needs 4 non-empty cells and source = 'harness' or an owner/repo slug (docs/skills.md)"
      fi
    fi

    # --- Slack coupling: roster + escalation owner
    if [ "$(cfg slack_notifications)" = "enabled" ]; then
      if [ ! -f "$WORK/DEVELOPERS.md" ]; then
        fail roster "slack_notifications enabled but work/DEVELOPERS.md missing" \
          "build the roster per ONBOARDING Step 4 → Build the developer roster"
      else
        # login -> slack_id, table or bullet format — MUST mirror preflight.sh's parsing
        ROSTER="$(grep -E '^\|' "$WORK/DEVELOPERS.md" 2>/dev/null | while IFS='|' read -r _ l sid _rest; do
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
            done < "$WORK/DEVELOPERS.md")"
        fi
        if [ -n "$ROSTER" ]; then
          ok roster "DEVELOPERS.md has $(printf '%s\n' "$ROSTER" | grep -c .) parseable member(s)"
        else
          fail roster "no parseable member entries in DEVELOPERS.md" \
            "use the table format from ONBOARDING Step 4 → Build the developer roster ('| login | slack_id | … |'), or 'login:' + 'slack_id:' bullet pairs"
        fi
        EO="$(cfg escalation_owner)"
        if [ -z "$EO" ]; then
          fail escalation-owner "slack_notifications enabled but escalation_owner missing" \
            "pick one roster login with a slack_id (ONBOARDING Step 4 item 9)"
        else
          EO_SLACK="$(printf '%s\n' "$ROSTER" | while IFS="$(printf '\t')" read -r l sid; do
              [ "$l" = "$EO" ] && { printf '%s' "$sid"; break; }; done)"
          if printf '%s' "${EO_SLACK:-}" | grep -Eq '^U[A-Z0-9]{6,}$'; then
            ok escalation-owner "'$EO' is a roster member with a slack_id"
          else
            fail escalation-owner "'$EO' is not a roster login with a valid slack_id" \
              "add the member (or their 'U…' Slack id) to work/DEVELOPERS.md, or pick another owner (ONBOARDING Step 4 item 9)"
          fi
        fi
      fi
    fi
  fi

  # --- MEMORY.md: template sections
  if [ ! -f "$WORK/MEMORY.md" ]; then
    fail memory "work/MEMORY.md missing" "create it from the ONBOARDING Step 3b template (never overwrite an existing one)"
  else
    MISSING_S=""
    for s in 'Review Style' 'Focus Areas' 'Ignore List' 'Custom Rules' 'Observed Insights' 'Feedback Log'; do
      grep -q "^## $s" "$WORK/MEMORY.md" || MISSING_S="$MISSING_S '## $s'"
    done
    if [ -z "$MISSING_S" ]; then
      ok memory "all template sections present"
    else
      fail memory "section(s) missing:$MISSING_S" \
        "re-add the missing section header(s) from the ONBOARDING Step 3b template — keep all existing content"
    fi
  fi

  # --- REVIEWS.md: header + row format (docs/review.md → Tracking format)
  if [ ! -f "$WORK/REVIEWS.md" ]; then
    fail reviews "work/REVIEWS.md missing" "create the header from the ONBOARDING Step 3b template, then reconstruct rows per Step 5"
  else
    if grep -q '^| PR | Commit | Timestamp | Verdict | Status |$' "$WORK/REVIEWS.md"; then
      ok reviews-header "tracking table header matches"
    else
      fail reviews-header "tracking table header missing/altered" \
        "restore '| PR | Commit | Timestamp | Verdict | Status |' (+ separator) from the ONBOARDING Step 3b template — keep the data rows"
    fi
    BAD_ROWS=""
    while IFS= read -r row; do
      [ -z "$row" ] && continue
      case "$row" in '| PR |'*) continue ;; esac
      printf '%s' "$row" | grep -Eq '^\|[[:space:]]*[0-9]+[[:space:]]*\|[[:space:]]*[0-9a-f]{40}[[:space:]]*\|[[:space:]]*[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z[[:space:]]*\|[^|]+\|[[:space:]]*(done|awaiting_label|in_progress)[[:space:]]*\|$' \
        || BAD_ROWS="$BAD_ROWS $row"
    done <<EOF
$(grep '^|' "$WORK/REVIEWS.md" | grep -v '^|[ :-]*|')
EOF
    if [ -z "$BAD_ROWS" ]; then
      ok reviews-rows "all rows match the tracking format"
    else
      fail reviews-rows "malformed row(s):$BAD_ROWS" \
        "rewrite each as '| <number> | <full 40-hex sha> | <YYYY-MM-DDTHH:MM:SSZ> | <verdict> | done|awaiting_label|in_progress |' (docs/review.md → Tracking format)"
    fi
  fi

  # --- LESSONS.md
  if grep -q '^# Operational Lessons' "$WORK/LESSONS.md" 2>/dev/null; then
    ok lessons "work/LESSONS.md present"
  else
    fail lessons "work/LESSONS.md missing or lacking its '# Operational Lessons' header" \
      "create/fix it from the ONBOARDING Step 3b template (never overwrite existing entries)"
  fi

  # --- work/VERSION vs the checked-out definition
  DEFV="$(head -1 "$HOME_DIR/VERSION" 2>/dev/null)"
  WV="$(head -1 "$WORK/VERSION" 2>/dev/null)"
  if [ -z "$WV" ]; then
    fail work-version "work/VERSION missing" 'head -1 "$HOME/VERSION" > "$HOME/work/VERSION" (ONBOARDING Step 7)'
  elif [ "$WV" = "$DEFV" ]; then
    ok work-version "adopted version matches the checkout ($WV)"
  else
    fail work-version "adopted '$WV' ≠ checked-out '${DEFV:-<no VERSION>}'" \
      "run the version check & migration (docs/persistence.md → Definition version & upgrade)"
  fi

  # --- reviews/ directory + naming
  if [ ! -d "$WORK/reviews" ]; then
    fail reviews-dir "work/reviews/ missing" "mkdir -p \"\$HOME/work/reviews\" (ONBOARDING Step 3b)"
  else
    ok reviews-dir "work/reviews/ present"
    STRAY=""
    for f in "$WORK/reviews"/* "$WORK/reviews"/.[!.]*; do
      [ -e "$f" ] || continue
      b="$(basename "$f")"
      [ "$b" = ".gitkeep" ] && continue
      printf '%s' "$b" | grep -Eq '^pr-[0-9]+\.md$' || STRAY="$STRAY $b"
    done
    [ -n "$STRAY" ] && warn reviews-naming "entries not matching pr-<number>.md:$STRAY — verify they are intentional"
  fi

  # --- logs/ naming (created lazily by the first logged event)
  if [ -d "$WORK/logs" ]; then
    STRAY_L=""
    for f in "$WORK/logs"/*; do
      [ -e "$f" ] || continue
      b="$(basename "$f")"
      printf '%s' "$b" | grep -Eq '^events-[0-9]{4}-[0-9]{2}-[0-9]{2}\.jsonl$' || STRAY_L="$STRAY_L $b"
    done
    [ -n "$STRAY_L" ] && warn logs-naming "entries not matching events-YYYY-MM-DD.jsonl:$STRAY_L — verify they are intentional"
  fi

  # --- unexpected top-level entries (known = templates + runtime bookkeeping;
  #     .gitignore may arrive via restore from the work backup repo)
  KNOWN="CONFIG.md MEMORY.md REVIEWS.md LESSONS.md DEVELOPERS.md SHEPHERD.md MENTIONS.md VERSION AUDIT.log HEARTBEAT.log SHEPHERD.log logs reviews .gitignore .stall-alert-day .stall-alert.lock"
  UNKNOWN=""
  for e in "$WORK"/* "$WORK"/.[!.]*; do
    [ -e "$e" ] || continue
    b="$(basename "$e")"
    case " $KNOWN " in *" $b "*) ;; *) UNKNOWN="$UNKNOWN $b" ;; esac
  done
  if [ -z "$UNKNOWN" ]; then
    ok work-layout "no unexpected top-level entries in work/"
  else
    warn work-layout "unexpected top-level entries:$UNKNOWN — not part of the standard layout; verify they are intentional"
  fi
fi

# ------------------------------------------------------------------- summary
if [ "$FAILS" -eq 0 ]; then
  printf 'PASS — %d checks passed, %d warning(s)\n' "$CHECKS" "$WARNS"
  logev info onboarding_verify "PASS ($CHECKS checks, $WARNS warnings)"
  exit 0
else
  printf 'RESULT: %d of %d checks FAILED — apply each fix above (file templates: ONBOARDING.md Steps 3b/4; key semantics: CLAUDE.md → Runtime configuration), then re-run this script until it prints PASS.\n' "$FAILS" "$CHECKS"
  logev error onboarding_verify "FAILED ($FAILS of $CHECKS checks) — structure mismatch, agent must repair and re-run"
  exit 1
fi
