#!/usr/bin/env bash
# ci-rollup.sh — the check rollup of one commit, in one shape (docs/ci-triage.md).
#
#   . scripts/lib/ci-rollup.sh
#   runs="$(ci_runs "$REPO" "$SHA")"        # [{name, status, conclusion, url, out}]
#   ci_terminal "$runs"                      # rc 0 when no check is queued or running
#   ci_failing "$runs"                       # [{…}] of the checks that failed
#
# Two APIs report a commit's checks: check runs (GitHub Actions and every app
# that writes them) and the older commit statuses (external CI). A repo can use
# either, so `ci_runs` reads check runs first and falls back to statuses when a
# commit has none, and normalizes both to the check-run vocabulary — `status`
# `queued`|`in_progress`|`completed`, `conclusion` `success`|`failure`|…
#
# Read-only: one or two GET calls, no writes. `gh` failures and unparseable
# answers yield `[]`, which reads as "nothing to act on" for both callers.

ci_runs() { # <owner/repo> <sha> -> JSON array
  local runs
  runs="$(gh api "repos/$1/commits/$2/check-runs?per_page=100" 2>/dev/null \
    | jq -c '[.check_runs[]? | {name, status, conclusion, url:(.details_url // ""),
               out: ((.output.title // "") + "\n" + (.output.summary // "") + "\n" + (.output.text // ""))}]' 2>/dev/null)"
  case "$runs" in (''|null) runs='[]';; esac
  if [ "$(printf '%s' "$runs" | jq 'length' 2>/dev/null || echo 0)" -eq 0 ]; then
    runs="$(gh api "repos/$1/commits/$2/status" 2>/dev/null \
      | jq -c '[.statuses[]? | {name:.context,
                 status:(if .state == "pending" then "queued" else "completed" end),
                 conclusion:(if .state == "pending" then null
                             elif .state == "success" then "success"
                             elif .state == "failure" or .state == "error" then "failure"
                             else .state end),
                 url:(.target_url // ""), out:(.description // "")}]' 2>/dev/null)"
    case "$runs" in (''|null) runs='[]';; esac
  fi
  printf '%s' "$runs"
}

# A commit with no check at all is terminal: there is nothing left to wait for.
ci_terminal() { # <runs json> -> rc 0 when terminal
  ! printf '%s' "$1" | jq -e 'any(.[]; .status != "completed")' >/dev/null 2>&1
}

# `cancelled` and `action_required` are not failures (docs/ci-triage.md).
ci_failing() { # <runs json> -> JSON array
  printf '%s' "$1" | jq -c '[.[] | select(.conclusion == "failure" or .conclusion == "timed_out")]' 2>/dev/null || printf '[]'
}
