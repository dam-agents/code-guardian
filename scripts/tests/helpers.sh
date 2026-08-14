# helpers.sh — shared plumbing for the preflight stub tests. Sourced by every
# test_*.sh. Portable across the pod (GNU) and macOS (BSD): bash 3.2+, no awk.
set -u

T_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$T_DIR/../.." && pwd)"
TEST_REPO="acme/widgets"   # the fake target repo every fixture uses
TEST_REF=""                # set per case to pass a host-prefixed target ref
FAILED=0
SANDBOXES=()
trap 'rm -rf "${SANDBOXES[@]:-}"' EXIT

# fresh sandbox per case: work dir, seeded REVIEWS.md, fixtures dir, fake HOME
new_case() { # <case-name>
  CASE="$1"; TEST_REF=""
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/cg-test.XXXXXX")"
  SANDBOXES+=("$SANDBOX")
  WORK="$SANDBOX/work"; GH_FIXTURES="$SANDBOX/fixtures"; FAKE_HOME="$SANDBOX/home"
  export GH_FIXTURES
  mkdir -p "$WORK/reviews" "$GH_FIXTURES" "$FAKE_HOME"
  {
    printf '# Reviewed PRs\n\n'
    printf '| PR | Commit | Timestamp | Verdict | Status |\n'
    printf '|----|--------|-----------|---------|--------|\n'
  } > "$WORK/REVIEWS.md"
}

# fixture slug for a gh invocation — MUST mirror tests/bin/gh
fx_for() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

# append a REVIEWS.md row
add_row() { # <number> <sha> <ts> <verdict> <status>
  printf '| %s | %s | %s | %s | %s |\n' "$1" "$2" "$3" "$4" "$5" >> "$WORK/REVIEWS.md"
}

# minimal CONFIG.md most cases share; extra keys via stdin-less args
base_config() { # [extra lines…]
  {
    printf -- '- bot_login: test-bot\n'
    printf -- '- review_marker: cg:review\n'
    printf -- '- rereview_label: cg-rereview\n'
    for l in "$@"; do printf -- '%s\n' "$l"; done
  } > "$WORK/CONFIG.md"
}

# one open-PR object for the pulls?state=open fixture
pr_json() { # <number> <title> <labels-json> <sha> [author]
  jq -n --argjson n "$1" --arg t "$2" --argjson l "$3" --arg sha "$4" --arg a "${5:-alice}" \
    '{number:$n, title:$t, draft:false, user:{login:$a},
      head:{sha:$sha, ref:("b"+($n|tostring))}, base:{ref:"main"},
      created_at:"2026-07-01T00:00:00Z", labels:$l, assignees:[],
      requested_reviewers:[], html_url:("https://example.test/pr/"+($n|tostring))}'
}

# the open-PR list fixture from pr_json objects passed on stdin (jq slurp)
open_prs_fx() { jq -s . | fx 'api repos/acme/widgets/pulls?state=open&per_page=100'; }

# write a fixture from stdin for the given gh argument string
fx() { cat > "$GH_FIXTURES/$(fx_for "$1")"; }

# make the given gh invocation fail with an exit code (default 1) — tests/bin/gh
fx_fail()      { printf '%s' "${2:-1}" > "$GH_FIXTURES/$(fx_for "$1").rc"; }
# same, but only the next call fails; later calls serve the body fixture
fx_fail_once() { printf 'once:%s' "${2:-1}" > "$GH_FIXTURES/$(fx_for "$1").rc"; }

# ISO-8601 UTC timestamp <n> seconds in the past (GNU + BSD date)
iso_ago() {
  local s=$(( $(date -u +%s) - $1 ))
  date -u -d "@$s" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -r "$s" +%Y-%m-%dT%H:%M:%SZ
}

# run preflight in the sandbox; JSON lands in $OUT. GH_HOST is blanked so the
# ambient default host is `github.com` whatever the developer's shell exports —
# a case exercises another host through TEST_REF, never the environment.
run_preflight() { # <mode>
  OUT="$(GITHUB_REPO="${TEST_REF:-$TEST_REPO}" GH_HOST="" WORK_DIR="$WORK" HOME="$FAKE_HOME" \
         PATH="$T_DIR/bin:$PATH" bash "$REPO_ROOT/scripts/preflight.sh" "$1")"
}

assert_jq() { # <jq boolean expression> <description>
  if printf '%s' "$OUT" | jq -e "$1" >/dev/null 2>&1; then
    printf 'ok   %s: %s\n' "$CASE" "$2"
  else
    printf 'FAIL %s: %s\n     expr: %s\n     out:  %s\n' \
      "$CASE" "$2" "$1" "$(printf '%s' "$OUT" | jq -c . 2>/dev/null || printf '%s' "$OUT")"
    FAILED=1
  fi
}

assert_file_contains() { # <file> <grep pattern> <description>
  if grep -q "$2" "$1" 2>/dev/null; then
    printf 'ok   %s: %s\n' "$CASE" "$3"
  else
    printf 'FAIL %s: %s (pattern %s not in %s)\n' "$CASE" "$3" "$2" "$1"
    FAILED=1
  fi
}

finish() { exit "$FAILED"; }
