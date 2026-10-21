#!/usr/bin/env bash
# harness.sh — name the harness this shell runs under (docs/logging.md →
# Harness adapters; one file per harness: docs/harness-<name>.md).
#
#   cg_harness           # prints claude-code | pi | bob | <PLATFORM_HARNESS> | unknown
#   cg_harness_version   # prints the harness version line, empty when unknown
#   cg_harness_effort    # prints the session's reasoning effort, else "unknown"
#
# The env is the harness process's own, so a pod that offers several harnesses
# answers per session. Sourced by the scripts that differ per harness:
# benchmark-phase.sh, benchmark-provenance.sh, health.sh, preflight.sh (audit),
# review-pr.sh (the review footer) and verify-onboarding.sh.

cg_harness() {
  if [ "${CLAUDECODE:-}" = "1" ]; then printf 'claude-code'
  elif [ "${PI_CODING_AGENT:-}" = "true" ] || [ "${PLATFORM_HARNESS:-}" = "pi" ]; then printf 'pi'
  elif [ -n "${PLATFORM_HARNESS:-}" ]; then printf '%s' "$PLATFORM_HARNESS"
  else printf 'unknown'
  fi
}

cg_harness_version() {
  local v=""
  if [ "$(cg_harness)" = pi ]; then
    v="$(pi --version 2>/dev/null | head -1)"; [ -n "$v" ] && v="pi $v"
  else
    v="$(claude --version 2>/dev/null | head -1)"
  fi
  printf '%s' "$v"
}

# CLAUDE_EFFORT is Claude Code's, PI_REASONING_LEVEL pi's thinking level
cg_harness_effort() {
  printf '%s' "${CLAUDE_EFFORT:-${PI_REASONING_LEVEL:-unknown}}"
}
