#!/usr/bin/env bash
# benchmark-child.sh — the benchmark sub-agent's side of an isolated Phase 1
# (docs/benchmark.md → Isolated review). Runs only where CG_BENCHMARK_CHILD=1.
#
#   benchmark-child.sh unpack                     # the spawn's install step
#   benchmark-child.sh report <slug> <first|rereview> <ts> <model> <suppressed>
#
# `unpack` joins the CG_BENCH_B64_<nn> env chunks benchmark-isolate.sh sent,
# checks them against CG_BENCH_SHA256, extracts the bundle into $HOME and
# installs the harness adapter of CG_BENCH_HARNESS, as onboarding Step 1b does,
# so the session that opens next runs with the production hooks, deny list and
# subagent type. `report` sends the task's result to the platform's
# report_result tool from files — the raw review, its skill archive, the phase
# helper's measurement and this checkout's provenance — so the model never
# repeats them in a tool call.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOME_DIR="${HOME:-/home/agent}"
BENCH="$HOME_DIR/work/benchmark"

[ "${CG_BENCHMARK_CHILD:-}" = 1 ] || { printf 'not a benchmark sub-agent (CG_BENCHMARK_CHILD != 1)\n' >&2; exit 2; }

b64d() { base64 -d 2>/dev/null || base64 -D; }
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi; }

case "${1:-}" in
  (unpack)
    tgz="$(mktemp "${TMPDIR:-/tmp}/cg-bench-bundle.XXXXXX")" || exit 1
    i=0
    while :; do
      n="$(printf 'CG_BENCH_B64_%02d' "$i")"
      v="$(printenv "$n" 2>/dev/null)" || break
      printf '%s' "$v"; i=$((i + 1))
    done | b64d > "$tgz"
    [ -s "$tgz" ] || { printf 'no bundle chunks in the environment\n' >&2; exit 1; }
    [ "$(sha256 < "$tgz")" = "${CG_BENCH_SHA256:-}" ] || { printf 'bundle checksum mismatch\n' >&2; exit 1; }
    tar -xzf "$tgz" -C "$HOME_DIR" || { printf 'bundle does not extract\n' >&2; exit 1; }
    rm -f "$tgz"
    case "${CG_BENCH_HARNESS:-}" in
      (claude-code) CLAUDECODE=1 bash "$SCRIPT_DIR/harness/claude-code/install.sh";;
      (pi) PI_CODING_AGENT=true bash "$SCRIPT_DIR/harness/pi/install.sh";;
    esac
    printf 'benchmark bundle unpacked into %s\n' "$HOME_DIR"
    ;;
  (report)
    [ "$#" -eq 6 ] || { printf 'usage: benchmark-child.sh report <slug> <first|rereview> <ts> <model> <suppressed>\n' >&2; exit 2; }
    slug="$2" ph="$3" ts="$4" model="$5" sup="$6"
    case "$sup" in (''|*[!0-9]*) printf 'suppressed must be a number\n' >&2; exit 2;; esac
    raw="$BENCH/results/raw/$ts-$slug-$ph.md"
    meas="$BENCH/.measure-$slug-$ph.json"
    [ -s "$raw" ] || { printf 'no raw review at %s\n' "$raw" >&2; exit 1; }
    jq -e '(.seconds | type) == "number"' "$meas" >/dev/null 2>&1 \
      || { printf 'no phase measurement at %s — save the phase helper end output there\n' "$meas" >&2; exit 1; }
    sk="${raw%.md}-skills"
    skills='{}'
    if [ -d "$sk" ]; then
      skills="$(cd "$sk" && find . -type f | sed 's#^\./##' | sort | while IFS= read -r p; do
          jq -Rs --arg p "$p" '{($p): .}' < "$p"
        done | jq -s 'add // {}')"
    fi
    prov="$(bash "$SCRIPT_DIR/benchmark-provenance.sh" "$BENCH")" || prov='{}'
    args="$(mktemp "${TMPDIR:-/tmp}/cg-bench-result.XXXXXX")" || exit 1
    jq -n --rawfile review "$raw" --slurpfile m "$meas" --argjson sup "$sup" --arg model "$model" \
      --argjson prov "$prov" --argjson skills "$skills" \
      '{result: {review: $review, measure: $m[0], suppressed: $sup, model: $model,
                 provenance: $prov, skills: $skills}}' > "$args" || { rm -f "$args"; exit 1; }
    . "$SCRIPT_DIR/lib/mcp.sh"
    MCP_TIMEOUT_S=60 mcp_call report_result "$args"; rc=$?
    rm -f "$args"
    [ "$rc" -eq 0 ] && printf '\nresult reported — end the turn now\n'
    exit "$rc"
    ;;
  (*) printf 'usage: benchmark-child.sh unpack | report <slug> <phase> <ts> <model> <suppressed>\n' >&2; exit 2;;
esac
