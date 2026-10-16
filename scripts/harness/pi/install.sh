#!/usr/bin/env bash
# pi harness adapter — keeps the code-guardian extension linked into pi's
# auto-loaded extensions directory (docs/harness-pi.md → Adapter):
# ~/.pi/agent/extensions/code-guardian.ts → this directory's extension.ts.
# A link, so a definition update reaches pi without a re-install. Idempotent;
# effective from the next pi session. Where pi is absent (no `pi` on PATH and
# no ~/.pi/agent) it prints a notice and exits 0.
#
#   install.sh           # install or refresh
#   install.sh --check   # print `pi-extension` when the link is not current, or nothing
set -u

CHECK=0; [ "${1:-}" = "--check" ] && CHECK=1
AGENT_DIR="${PI_CODING_AGENT_DIR:-${HOME:-/home/agent}/.pi/agent}"
if ! command -v pi >/dev/null 2>&1 && [ ! -d "$AGENT_DIR" ]; then
  [ "$CHECK" = 1 ] && exit 0
  echo "pi is not installed here — no pi extension linked"
  exit 0
fi

SRC="$(cd "$(dirname "$0")" && pwd)/extension.ts"
LINK="$AGENT_DIR/extensions/code-guardian.ts"

if [ "$CHECK" = 1 ]; then
  [ -L "$LINK" ] && [ "$(readlink "$LINK")" = "$SRC" ] || echo "pi-extension"
  exit 0
fi

mkdir -p "$AGENT_DIR/extensions" || { echo "cannot create $AGENT_DIR/extensions"; exit 1; }
ln -sfn "$SRC" "$LINK" || { echo "cannot link $LINK"; exit 1; }
echo "pi extension linked: $LINK -> $SRC (effective from the next pi session)"
