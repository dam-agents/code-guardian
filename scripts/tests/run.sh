#!/usr/bin/env bash
# run.sh — run every preflight stub test (scripts/tests/test_*.sh).
# Deterministic, offline: gh/curl are stubbed via tests/bin. Used by the CI
# workflow (.github/workflows/ci.yml) and by self-modification validation
# (docs/self-modification.md §9). Exit 0 iff every assertion passed.
cd "$(dirname "$0")" || exit 1
rc=0
for t in test_*.sh; do
  echo "== $t"
  bash "$t" || rc=1
done
if [ "$rc" -eq 0 ]; then echo "ALL TESTS PASSED"; else echo "TESTS FAILED"; fi
exit "$rc"
