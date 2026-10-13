#!/usr/bin/env bash
# github-access.sh — what the GitHub token is and what it may do, as one JSON
# report (docs/github-access.md). Run by onboarding Step 4, a version upgrade
# and the operator's "check access" in the direct session — never by a
# scheduled run: its write probes are not preflight's read-only kind.
#
#   bash scripts/github-access.sh            # report on stdout
#     [--repo <ref>] [--work-repo <ref>] [--definition-repo <ref>]
#                                            # refs before work/CONFIG.md exists
#
# A write probe sends a request GitHub must reject on its body — 422 means the
# token holds the permission, 403/404 means it does not, and nothing is
# written. Every probe below was checked to answer 422 when granted; a probe
# that answers 2xx is reported as `unexpected` and must be removed. Never add a
# probe whose invalid body GitHub may ignore (an unknown assignee answers 201).
# Requires bash, gh (authenticated), jq.

set -u
export LC_ALL=C
HOME_DIR="${HOME:-/home/agent}"
WORK="${WORK_DIR:-$HOME_DIR/work}"
CONFIG="$WORK/CONFIG.md"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

A_REPO=""; A_WORK=""; A_DEF=""
while [ $# -gt 0 ]; do
  case "$1" in
    (--repo) A_REPO="${2:-}"; shift 2;;
    (--work-repo) A_WORK="${2:-}"; shift 2;;
    (--definition-repo) A_DEF="${2:-}"; shift 2;;
    (*) printf '{"error":"unknown argument %s"}\n' "$1"; exit 0;;
  esac
done
TARGET_REF="${A_REPO:-$(cfg github_repo)}"
[ -z "$TARGET_REF" ] && TARGET_REF="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)"
REPO_HOST="$(refhost "$TARGET_REF")"; REPO="$(refslug "$TARGET_REF")"
export GH_HOST="$REPO_HOST"
WORK_REF="${A_WORK:-$(cfg work_repo)}"
DEF_REF="${A_DEF:-$(cfg definition_repo)}"; [ -z "$DEF_REF" ] && DEF_REF="$(origin_ref "$HOME_DIR")"
BOT_LOGIN="$(cfg bot_login)"
DELTA_LABEL="$(cfg rereview_delta_label)"; ARTIFACT_LABEL="$(cfg artifact_label)"

[ -n "$REPO" ] || { printf '{"error":"target repository unresolved — set github_repo"}\n'; exit 0; }

# <host> <method> <path> [json-body] -> the HTTP status code, 000 when none
http() {
  local out
  if [ -n "${4:-}" ]; then out="$(printf '%s' "$4" | gh api --hostname "$1" -i -X "$2" "$3" --input - 2>/dev/null)"
  else out="$(gh api --hostname "$1" -i -X "$2" "$3" 2>/dev/null)"; fi
  printf '%s' "$out" | sed -n '1s/^HTTP\/[0-9.]* \([0-9]*\).*/\1/p' | grep . || printf '000'
}
# a read: 2xx granted, 403/404 denied
read_state() { case "$1" in (2??) printf granted;; (403|404) printf denied;; (*) printf unknown;; esac; }
# a write probe: 422 granted, 403/404 denied, 2xx a probe that wrote
write_state() { case "$1" in (422) printf granted;; (403|404) printf denied;; (2??) printf unexpected;; (*) printf unknown;; esac; }

PROBES='[]'
add() { # <id> <repo> <kind read|write> <code> <needed-by>
  local st; if [ "$3" = read ]; then st="$(read_state "$4")"; else st="$(write_state "$4")"; fi
  PROBES="$(printf '%s' "$PROBES" | jq -c --arg i "$1" --arg r "$2" --arg k "$3" --arg c "$4" --arg s "$st" --arg n "$5" \
    '. + [{id:$i, repo:$r, kind:$k, http:($c|tonumber), state:$s, needed_by:$n}]')"
}
skip() { # <id> <repo> <needed-by> <reason>
  PROBES="$(printf '%s' "$PROBES" | jq -c --arg i "$1" --arg r "$2" --arg n "$3" --arg w "$4" \
    '. + [{id:$i, repo:$r, kind:"write", http:null, state:"unknown", needed_by:$n, reason:$w}]')"
}

# --- identity: GraphQL viewer, else REST GET /user (lib/common.sh → gh_login) -
LOGIN="$(gh_login "$REPO_HOST")"
[ -n "$LOGIN" ] || { printf '{"error":"not authenticated on %s — the GitHub connection is broken"}\n' "$REPO_HOST"; exit 0; }
KIND="$(login_kind "$LOGIN")"
TOKEN=app; SCOPES=null
if [ "$KIND" = user ]; then
  sc="$(gh api --hostname "$REPO_HOST" user -i 2>/dev/null | sed -n 's/^[Xx]-[Oo][Aa]uth-[Ss]copes:[[:space:]]*//p' | tr -d '\r')"
  if [ -n "$sc" ]; then TOKEN=classic; SCOPES="$(printf '%s' "$sc" | jq -Rc 'split(",") | map(gsub("^ +| +$"; "")) | map(select(. != ""))')"
  else TOKEN=fine-grained; fi
fi
[ -d "$WORK" ] && { identity_refresh force >/dev/null 2>&1 || true; }

# --- the target repository ---------------------------------------------------
H="$REPO_HOST"
add repo_read "$REPO" read "$(http "$H" GET "repos/$REPO")" "every run"
DEFAULT="$(gh api --hostname "$H" "repos/$REPO" --jq '.default_branch // "main"' 2>/dev/null)"; DEFAULT="${DEFAULT:-main}"
PR="$(gh api --hostname "$H" "repos/$REPO/pulls?state=open&per_page=1" --jq '.[0].number // empty' 2>/dev/null)"
if [ -n "$PR" ]; then
  SHA="$(gh api --hostname "$H" "repos/$REPO/pulls/$PR" --jq '.head.sha // empty' 2>/dev/null)"
  add reviews_write "$REPO" write "$(http "$H" POST "repos/$REPO/pulls/$PR/reviews" '{"event":"BOGUS"}')" "posting reviews"
  add comments_write "$REPO" write "$(http "$H" POST "repos/$REPO/issues/$PR/comments" '{}')" "comments, labels, issues, mention replies"
else
  SHA="$(gh api --hostname "$H" "repos/$REPO/commits/$DEFAULT" --jq '.sha // empty' 2>/dev/null)"
  skip reviews_write "$REPO" "posting reviews" "no open pull request to probe"
  skip comments_write "$REPO" "comments, labels, issues, mention replies" "no open pull request to probe"
fi
if [ -n "$SHA" ]; then
  add statuses_write "$REPO" write "$(http "$H" POST "repos/$REPO/statuses/$SHA" '{"state":"bogus"}')" "review_progress (user token)"
  add checks_write "$REPO" write "$(http "$H" POST "repos/$REPO/check-runs" "{\"head_sha\":\"$SHA\"}")" "review_progress (GitHub App)"
  add checks_read "$REPO" read "$(http "$H" GET "repos/$REPO/commits/$SHA/check-runs?per_page=1")" "ci_triage, auto_merge"
fi
add issues_write "$REPO" write "$(http "$H" POST "repos/$REPO/issues" '{}')" "issues for findings of a closed pull request"
add actions_read "$REPO" read "$(http "$H" GET "repos/$REPO/actions/runs?per_page=1")" "ci_triage job logs"
add contents_write "$REPO" write "$(http "$H" POST "repos/$REPO/git/refs" '{}')" "auto_merge, agent_fixes"
add branch_protection_read "$REPO" read "$(http "$H" GET "repos/$REPO/branches/$DEFAULT/protection/required_status_checks")" "project profile (optional; rulesets are the fallback)"
OWNER="${REPO%%/*}"
if [ "$(gh api --hostname "$H" "users/$OWNER" --jq '.type // empty' 2>/dev/null)" = Organization ]; then
  add org_teams_read "$OWNER" read "$(http "$H" GET "orgs/$OWNER/teams?per_page=1")" "reviewer roster from teams (onboarding)"
fi

# --- the work_repo backup and the definition repository ---------------------
if [ -n "$WORK_REF" ]; then
  W="$(refslug "$WORK_REF")"
  add work_repo_write "$W" write "$(http "$(refhost "$WORK_REF")" POST "repos/$W/git/refs" '{}')" "work_repo backup"
fi
if [ -n "$DEF_REF" ]; then
  D="$(refslug "$DEF_REF")"; DH="$(refhost "$DEF_REF")"
  add definition_push "$D" write "$(http "$DH" POST "repos/$D/git/refs" '{}')" "definition PRs (push)"
  add definition_prs "$D" write "$(http "$DH" POST "repos/$D/pulls" '{}')" "definition PRs"
fi

# --- what follows for the features (docs/github-access.md → Feature map) ----
jq -n --arg l "$LOGIN" --arg k "$KIND" --arg t "$TOKEN" --argjson sc "$SCOPES" --arg b "$BOT_LOGIN" \
      --arg dl "$DELTA_LABEL" --arg al "$ARTIFACT_LABEL" --arg repo "$REPO" --argjson p "$PROBES" '
  def st($i): ([ $p[] | select(.id == $i) | .state ][0] // "unknown");
  def need($ids): if all($ids[]; st(.) == "granted") then "ok"
                  elif any($ids[]; st(.) == "denied") then "missing" else "unknown" end;
  { identity: {login:$l, kind:$k, token:$t, scopes:$sc},
    bot_login: (if $b == "" then null else $b end),
    target: $repo,
    probes: $p,
    unexpected: [ $p[] | select(.state == "unexpected") | .id ],
    progress_channel: (if $k == "app" and st("checks_write") == "granted" then "check_run"
                       elif st("statuses_write") == "granted" then "status"
                       elif st("checks_write") == "granted" then "check_run" else "none" end),
    features: {
      review: need(["repo_read","reviews_write","comments_write"]),
      issues: need(["issues_write"]),
      ci_triage: need(["checks_read","actions_read"]),
      auto_merge: need(["checks_read","contents_write"]),
      agent_fixes: need(["contents_write"]),
      work_backup: (if any($p[]; .id == "work_repo_write") then need(["work_repo_write"]) else "not_configured" end),
      definition_prs: (if any($p[]; .id == "definition_prs") then need(["definition_push","definition_prs"]) else "not_configured" end),
      roster_teams: (if any($p[]; .id == "org_teams_read") then need(["org_teams_read"]) else "not_applicable" end)
    },
    triggers: (($b != "" and ($b | endswith("[bot]") | not)) as $user
               | {label: true, delta_label: ($dl != ""), review_request: $user,
                  mention: ($b != ""),
                  mention_as: (if $b == "" then [] elif $user then ["@" + $b] else ["@" + ($b | rtrimstr("[bot]")), "@" + $b] end),
                  artifact_assignee: $user, artifact_label: ($al != "")}
               | . + {missing: ([ if $user then empty else
                                    (if $dl == "" then "rereview_delta_label" else empty end),
                                    (if $al == "" then "artifact_label" else empty end) end ])}) }'
