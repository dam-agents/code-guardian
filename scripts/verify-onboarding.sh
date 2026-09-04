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
# Detects, never repairs (same contract as preflight.sh): no GitHub writes, no
# local writes beyond one structured log event. Every FAIL line carries a
# `fix:` instruction for the agent to apply; re-run after fixing until the
# script prints PASS.
#
#   ok   <check> — <detail>                      passed
#   warn <check> — <detail>                      informational, never blocks
#   FAIL <check> — <problem> — fix: <instruction>
#
# Default run is offline (structure only). `--live` adds the "does it actually
# work" pass on top: GitHub authentication per configured host, bot identity,
# target/definition/work-repo access, the re-review label, every skill source,
# and one read-only `preflight.sh review` as the end-to-end proof (which writes
# its own log lines and warms the skill cache — no GitHub writes).
#
# Exit 0 iff nothing FAILed.
#
# Requires: bash, git, jq, sed/grep/cut/tr (no awk — not available in the pod);
# `--live` additionally needs an authenticated `gh`.

set -u
export LC_ALL=C

LIVE=0
case "${1:-}" in
  (--live) LIVE=1;;
  ('') ;;
  (*) printf 'usage: %s [--live]\n' "$0" >&2; exit 2;;
esac

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

# MUST mirror preflight.sh's reader, quote stripping included
cfg() { sed -n "s/^- $1:[[:space:]]*//p" "$CONFIG" 2>/dev/null | head -1 \
        | sed -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//' \
              -e 's/^[`"'"'"']//' -e 's/[`"'"'"']$//'; }
trim() { printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

# `[<host>/]<owner>/<repo>` -> host / slug, the ambient default for two segments
DEFAULT_HOST="${GH_HOST:-github.com}"
refhost() { case "$1" in (*/*/*) printf '%s' "${1%%/*}";; (*) printf '%s' "$DEFAULT_HOST";; esac; }
refslug() { case "$1" in (*/*/*) printf '%s' "${1#*/}";;  (*) printf '%s' "$1";; esac; }

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
    DEF_HOST="$(refhost "$DEF_REF")"; DEF_REPO="$(refslug "$DEF_REF")"
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
          "add '- $k: …' per ONBOARDING Step 4 (semantics: docs/config.md)"
      fi
    done

    for k in definition_repo github_repo; do
      v="$(cfg "$k")"
      if [ -n "$v" ] && ! printf '%s' "$v" | grep -Eq '^([A-Za-z0-9._-]+/)?[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'; then
        fail "config-$k-shape" "'$v' is not a [host/]owner/repo reference" "correct the '- $k:' value"
      fi
    done

    # The target repo must still resolve in a fresh scheduled run, which carries
    # no session exports: either the key is stored, or the platform sets the env
    # var for every run. A session-only export passes here and fails at 03:00.
    if [ -n "$(cfg github_repo)" ]; then
      ok config-github_repo "stored — the target resolves without the env var"
    elif [ -n "${GITHUB_REPO:-}" ]; then
      warn config-github_repo "not in CONFIG.md — the target resolves from the env var alone; confirm the platform sets it for every scheduled run, or add '- github_repo: <[host/]owner/repo>'"
    else
      fail config-github_repo "target repo unresolvable — neither \$GITHUB_REPO nor a '- github_repo:' key is set" \
        "add '- github_repo: <[host/]owner/repo>' (ONBOARDING Step 4 item 1); preflight fails every run without it"
    fi

    # A renamed/prosified key is invisible to cfg(), so the runtime silently
    # uses defaults — list what the reader will never see.
    KNOWN_KEYS="github_repo definition_repo definition_branch bot_login bot_display_name review_marker rereview_label rereview_trigger urgent_label review_progress mention_replies project_profile artifact_skill artifact_targets slack_notifications audit_report benchmark benchmark_judge benchmark_report escalation_owner stall_alert_threshold log_level active_hours active_days review_interval_active review_interval_quiet"
    UNKNOWN_KEYS=""
    while IFS= read -r k; do
      [ -z "$k" ] && continue
      case " $KNOWN_KEYS " in *" $k "*) ;; *) UNKNOWN_KEYS="$UNKNOWN_KEYS '$k'" ;; esac
    done <<EOF
$(sed -n 's/^-[[:space:]]*\([A-Za-z0-9 _-]*\):.*$/\1/p' "$CONFIG")
EOF
    if [ -n "$UNKNOWN_KEYS" ]; then
      warn config-keys "bullet(s) the runtime never reads:$UNKNOWN_KEYS — CONFIG.md is parsed as '- <key>: <value>' with the key names of docs/config.md (example: ONBOARDING Step 4 → Final shape)"
    else
      ok config-keys "every '- key:' bullet is a known configuration key"
    fi

    chk_enum() { # <key> <allowed-regex> <allowed-list-for-humans>
      local v; v="$(cfg "$1")"
      [ -z "$v" ] && return 0
      if printf '%s' "$v" | grep -Eq "^($2)\$"; then
        ok "config-$1" "'$v'"
      else
        fail "config-$1" "invalid value '$v'" "set one of: $3 (docs/config.md)"
      fi
    }
    chk_enum slack_notifications 'enabled|disabled' 'enabled | disabled'
    chk_enum rereview_trigger 'label|review-request|both' 'label | review-request | both'
    chk_enum mention_replies 'enabled|disabled' 'enabled | disabled'
    chk_enum review_progress 'enabled|disabled' 'enabled | disabled'
    chk_enum project_profile 'enabled|disabled' 'enabled | disabled'
    chk_enum audit_report 'enabled|disabled' 'enabled | disabled'
    chk_enum log_level 'info|debug' 'info | debug'
    chk_enum stall_alert_threshold '[0-9]+|off' 'an integer | 0 | off'
    # Review cadence (docs/config.md). Both intervals must
    # divide 60 or `*/N` fires unevenly across the hour boundary, and an active
    # window that wraps midnight is not expressible as a single cron.
    chk_enum review_interval_active '1|2|3|4|5|6|10|12|15|20|30|60' 'a divisor of 60: 1 2 3 4 5 6 10 12 15 20 30 60'
    chk_enum review_interval_quiet  '1|2|3|4|5|6|10|12|15|20|30|60' 'a divisor of 60: 1 2 3 4 5 6 10 12 15 20 30 60'
    chk_enum active_days 'Mon-Fri|Mon-Sun|(Mon|Tue|Wed|Thu|Fri|Sat|Sun)(,(Mon|Tue|Wed|Thu|Fri|Sat|Sun))*' \
      'Mon-Fri | Mon-Sun | a comma list of day abbreviations (Mon,Tue,...)'
    AH="$(cfg active_hours)"
    if [ -n "$AH" ]; then
      if printf '%s' "$AH" | grep -Eq '^([01][0-9]|2[0-3])-([01][0-9]|2[0-3])$'; then
        if [ "${AH%-*}" -le "${AH#*-}" ]; then
          ok config-active_hours "'$AH'"
        else
          fail config-active_hours "'$AH' spans midnight" \
            "use an ascending HH-HH range — one cron cannot wrap midnight (ONBOARDING Step 6a)"
        fi
      else
        fail config-active_hours "invalid value '$AH'" \
          "use an ascending 'HH-HH' range of platform-timezone hours, both ends inclusive (e.g. 08-21)"
      fi
    fi

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

  # --- AGENTS.md: entry pointer for a harness whose cwd is work/
  if [ -f "$WORK/AGENTS.md" ]; then
    ok work-pointer "work/AGENTS.md present"
  else
    fail work-pointer "work/AGENTS.md missing" "create it from the ONBOARDING Step 3c template"
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
      # pr-artifacts/ is the documented artifact home (docs/artifact.md)
      [ "$b" = "pr-artifacts" ] && [ -d "$f" ] && continue
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
  KNOWN="AGENTS.md CONFIG.md MEMORY.md REVIEWS.md LESSONS.md DEVELOPERS.md SHEPHERD.md MENTIONS.md PROFILE.md PROFILE.json PROFILE-NOTES.md VERSION AUDIT.log HEARTBEAT.log SHEPHERD.log logs reviews memory benchmark .gitignore .stall-alert-day .stall-alert.lock"
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

# ---------------------------------------------------------------------- live
# Read-only "does it actually work" pass: every external surface a run depends
# on is reached once, with the same references the runtime resolves.
if [ "$LIVE" = 1 ]; then
  if [ ! -f "$CONFIG" ]; then
    fail live-config "no work/CONFIG.md to verify against" "run ONBOARDING Step 4, then re-run with --live"
  elif ! command -v gh >/dev/null 2>&1; then
    fail live-gh "the gh CLI is not installed" "install it (README → runtime requirements), then re-run with --live"
  else
    ghq() { gh api --hostname "$1" "$2" --jq "$3" 2>/dev/null; }   # read-only

    TARGET_REF="${GITHUB_REPO:-$(cfg github_repo)}"
    T_HOST="$(refhost "$TARGET_REF")"; T_REPO="$(refslug "$TARGET_REF")"

    if [ -z "$T_REPO" ]; then
      fail live-target "target repo unresolved — every run would stop at pre-flight" \
        "apply the config-github_repo fix above, then re-run with --live"
    else
      WHOAMI="$(ghq "$T_HOST" user .login)"
      BOT="$(cfg bot_login)"
      if [ -z "$WHOAMI" ]; then
        fail live-auth "no authenticated gh session on $T_HOST" "gh auth login --hostname $T_HOST (operator-only)"
      else
        ok live-auth "authenticated on $T_HOST as '$WHOAMI'"
        if [ -z "$BOT" ]; then
          : # required key — the config-bot_login check above already FAILed
        elif [ "$BOT" = "$WHOAMI" ]; then
          ok live-identity "acting as '$BOT'"
        else
          fail live-identity "the $T_HOST token belongs to '$WHOAMI' but bot_login is '$BOT' — reviews would be posted as '$WHOAMI'" \
            "authenticate as '$BOT' (operator-only) or correct the '- bot_login:' key"
        fi
      fi

      if [ "$(ghq "$T_HOST" "repos/$T_REPO" .full_name)" = "$T_REPO" ]; then
        ok live-target "target repo readable on $T_HOST"
        [ "$(ghq "$T_HOST" "repos/$T_REPO" .permissions.push)" = "true" ] \
          || warn live-target-write "no push permission — label writes and assignee handling will fail; reviews still post"
      else
        fail live-target "target repo not readable on $T_HOST" \
          "grant the account access to the repo, or correct the target reference (\$GITHUB_REPO / '- github_repo:')"
      fi

      RRL="$(cfg rereview_label)"; RRL="${RRL:-code-guardian-review}"
      URG="$(cfg urgent_label)"
      LABELS="$(gh api --hostname "$T_HOST" "repos/$T_REPO/labels?per_page=100" --paginate --jq '.[].name' 2>/dev/null)"
      has_label() { printf '%s\n' "$LABELS" | grep -Fxq "$1"; }
      if has_label "$RRL"; then
        ok live-rereview-label "'$RRL' exists on the target repo"
      else
        fail live-rereview-label "the re-review label '$RRL' does not exist — no one could request a re-review" \
          "create it on the target repo: gh label create \"$RRL\" --repo <target> --description \"Request a code-guardian re-review\" --color FBCA04"
      fi
      if [ -n "$URG" ] && ! has_label "$URG"; then
        warn live-urgent-label "the configured urgent label '$URG' does not exist — urgent handling can never trigger (create it, or drop the key)"
      fi

      # skill sources: every configured skill must exist where it installs from
      SK_ROWS="$(sed -n '/^## Review skills/,/^## [^#]/p' "$CONFIG" | grep '^|' | grep -v '^|[ :-]*|' | tail -n +2)"
      ART="$(cfg artifact_skill)"
      case "$ART" in
        (''|none) ;;
        (*) SK_ROWS="$SK_ROWS
| ${ART%%@*} | ${ART##*@} | artifact | — |";;
      esac
      SK_BAD=""; SK_OK=0
      while IFS= read -r row; do
        [ -z "$row" ] && continue
        s="$(trim "$(printf '%s' "$row" | cut -d'|' -f2)" | tr -d '`')"
        src="$(trim "$(printf '%s' "$row" | cut -d'|' -f3)" | tr -d '`')"
        [ -z "$s" ] && continue
        [ "$src" = "harness" ] && continue      # provided by the harness, not fetchable
        got="$(ghq "$(refhost "$src")" "repos/$(refslug "$src")/contents/.agents/skills/$s" \
                   'if type == "array" then (.[0].name // empty) else (.name // empty) end')"
        if [ -n "$got" ]; then SK_OK=$((SK_OK+1)); else SK_BAD="$SK_BAD $s@$src"; fi
      done <<EOF
$SK_ROWS
EOF
      if [ -n "$SK_BAD" ]; then
        fail live-skills "skill path(s) not found:$SK_BAD" \
          "each source must hold .agents/skills/<skill> — correct the row's skill/source, or drop the row (docs/skills.md)"
      else
        ok live-skills "$SK_OK repo-sourced skill(s) resolve at their source"
      fi
    fi

    DEF_REF2="$(cfg definition_repo)"
    if [ -n "$DEF_REF2" ]; then
      DB="$(cfg definition_branch)"; DB="${DB:-main}"
      GOT_B="$(ghq "$(refhost "$DEF_REF2")" "repos/$(refslug "$DEF_REF2")/branches/$DB" .name)"
      if [ "$GOT_B" = "$DB" ]; then
        ok live-definition "definition repo reachable, branch '$DB' exists"
      else
        fail live-definition "cannot read branch '$DB' of the definition repo" \
          "check the account's access and the '- definition_repo:' / '- definition_branch:' values (docs/persistence.md → Tracked branch)"
      fi
    fi

    if [ -n "${GITHUB_REPO_WORK:-}" ]; then
      W_HOST="$(refhost "$GITHUB_REPO_WORK")"; W_SLUG="$(refslug "$GITHUB_REPO_WORK")"
      if [ "$(ghq "$W_HOST" "repos/$W_SLUG" .full_name)" != "$W_SLUG" ]; then
        fail live-work-repo "the work backup repo is not readable — every run's state backup would fail" \
          "create/grant access to \$GITHUB_REPO_WORK, or unset it for local-only persistence (docs/persistence.md)"
      elif [ "$(ghq "$W_HOST" "repos/$W_SLUG" .permissions.push)" != "true" ]; then
        fail live-work-repo "no push permission on the work backup repo" \
          "grant write access to the account, or unset \$GITHUB_REPO_WORK (docs/persistence.md)"
      else
        ok live-work-repo "work backup repo writable"
      fi
    else
      ok live-work-repo "local-only persistence (GITHUB_REPO_WORK unset)"
    fi

    # end-to-end proof: the entry command of every scheduled run, read-only
    PF="$(WORK_DIR="$WORK" bash "$SCRIPT_DIR/preflight.sh" review 2>/dev/null)"
    PF_ERR="$(printf '%s' "$PF" | jq -r '.error // empty' 2>/dev/null)"
    if ! printf '%s' "$PF" | jq -e 'has("nothing_to_do")' >/dev/null 2>&1; then
      fail live-preflight "preflight.sh review produced no valid worklist JSON" \
        "run 'bash \"\$HOME/scripts/preflight.sh\" review' and fix what it reports (docs/runbook.md → The pre-flight contract)"
    elif [ -n "$PF_ERR" ]; then
      fail live-preflight "preflight.sh review reported: $PF_ERR" \
        "resolve the reported cause, then re-run with --live"
    else
      ok live-preflight "preflight.sh review returns a valid worklist ($(printf '%s' "$PF" | jq -r '.reviews_due // [] | length') review(s) due)"
    fi
  fi
fi

# ------------------------------------------------------------------- summary
[ "$LIVE" = 1 ] && SCOPE="structure+live" || SCOPE="structure"
if [ "$FAILS" -eq 0 ]; then
  printf 'PASS (%s) — %d checks passed, %d warning(s)\n' "$SCOPE" "$CHECKS" "$WARNS"
  logev info onboarding_verify "PASS $SCOPE ($CHECKS checks, $WARNS warnings)"
  exit 0
else
  printf 'RESULT (%s): %d of %d checks FAILED — apply each fix above (file templates: ONBOARDING.md Steps 3b/4; key semantics: docs/config.md), then re-run this script until it prints PASS.\n' "$SCOPE" "$FAILS" "$CHECKS"
  logev error onboarding_verify "FAILED $SCOPE ($FAILS of $CHECKS checks) — agent must repair and re-run"
  exit 1
fi
