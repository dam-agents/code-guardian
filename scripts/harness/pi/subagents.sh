#!/usr/bin/env bash
# pi harness helper — the subagent fan-out pi lacks (docs/harness-pi.md →
# Subagents): run every prompt file of a directory as its own nested pi
# session, all at once, and wait for every one.
#
#   subagents.sh <dir>
#
# <dir>/<name>.prompt holds one subagent's whole prompt. Each runs as
# `pi -p` on this session's provider, model and thinking level (PI_PROVIDER,
# PI_MODEL, PI_REASONING_LEVEL — a nested pi otherwise falls back to the saved
# default model), in $HOME, with the built-in tools only (no MCP tools: a
# subagent posts nothing), no context files and a persisted session, so the
# usage snapshot finds its transcript by the nonce its prompt carries. Writes
# <name>.reply (the final text), <name>.log (stderr) and prints one JSON line
# per subagent: {"name":…,"exit":N,"reply":"<path>"}. Exit 0 once every
# subagent ended, whatever each one's exit; 2 on a usage error.
# CG_SUBAGENT_TIMEOUT (seconds, default 3600) bounds each subagent.
set -u
export LC_ALL=C

DIR="${1:-}"
[ -n "$DIR" ] && [ -d "$DIR" ] || { printf 'usage: subagents.sh <dir with *.prompt files>\n' >&2; exit 2; }
ls "$DIR"/*.prompt >/dev/null 2>&1 || { printf 'no *.prompt file in %s\n' "$DIR" >&2; exit 2; }
command -v pi >/dev/null 2>&1 || { printf 'pi not on PATH — not the pi harness\n' >&2; exit 2; }

ARGS=(-p --no-context-files --tools read,bash,edit,write)
[ -n "${PI_PROVIDER:-}" ] && [ -n "${PI_MODEL:-}" ] && ARGS+=(--provider "$PI_PROVIDER")
[ -n "${PI_MODEL:-}" ] && ARGS+=(--model "$PI_MODEL")
[ -n "${PI_REASONING_LEVEL:-}" ] && ARGS+=(--thinking "$PI_REASONING_LEVEL")
LIMIT="${CG_SUBAGENT_TIMEOUT:-3600}"
case "$LIMIT" in (''|*[!0-9]*) LIMIT=3600;; esac
TO=(); command -v timeout >/dev/null 2>&1 && TO=(timeout "$LIMIT")

names=(); pids=()
for f in "$DIR"/*.prompt; do
  n="${f##*/}"; n="${n%.prompt}"
  # the nested session gets its own id, never this session's
  ( cd "${HOME:-/home/agent}" && env -u PI_SESSION_ID -u PI_SESSION_FILE \
      ${TO[@]+"${TO[@]}"} pi "${ARGS[@]}" "$(cat "$f")" \
      > "$DIR/$n.reply" 2> "$DIR/$n.log" < /dev/null ) &
  names+=("$n"); pids+=("$!")
done

for i in "${!pids[@]}"; do
  wait "${pids[$i]}"; rc=$?
  jq -nc --arg n "${names[$i]}" --argjson e "$rc" --arg r "$DIR/${names[$i]}.reply" \
    '{name: $n, exit: $e, reply: $r}'
done
exit 0
