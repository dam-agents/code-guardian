#!/usr/bin/env bash
# toolpath.sh — resolve shimmed CLI tools to their real binaries, once per run.
#
# Source this BEFORE the first `jq`/`gh` call (and before any `command -v jq`
# guard). Rationale and measurements: docs/logging.md → Tool path resolution.
#
# On this pod `jq` and `gh` on PATH are symlinks to `mise`, which re-resolves
# its toolchain on every invocation (~270ms vs ~17ms for the real binary).
# preflight.sh execs jq ~90x per run and the log hooks fire on every tool call,
# so the tax dominates both. This defines shell functions that call the real
# binary directly.
#
# PATH is deliberately NOT modified: the offline tests stub `gh` by prepending
# scripts/tests/bin to PATH (scripts/tests/helpers.sh), and shadowing that
# would send them to the network. A tool already resolving outside */shims/*
# (test stub, operator override, a fixed pod image) is left untouched.
#
# Degrades silently: unresolvable tools keep working through the shim. Never
# fails a run — this is a speed optimization, not a dependency.

# Cache the resolved paths: `mise bin-paths` costs ~210ms, an [ -x ] test ~0.6ms.
TOOLPATH_CACHE="${WORK_DIR:-${HOME:-/home/agent}/work}/.cache/toolpaths"

# Print "<tool> <abs-path>" per resolvable tool, consulting the cache first.
_toolpath_resolve() { # <tool>...
  local t p line found=""
  if [ -r "$TOOLPATH_CACHE" ]; then
    for t in "$@"; do
      line="$(sed -n "s|^$t ||p" "$TOOLPATH_CACHE" 2>/dev/null | head -1)"
      if [ -n "$line" ] && [ -x "$line" ]; then
        printf '%s %s\n' "$t" "$line"; found="$found $t"
      fi
    done
    # every tool served from cache — no mise call needed
    [ "$(printf '%s' "$found" | tr -s ' ' '\n' | grep -c .)" -eq "$#" ] && return 0
  fi
  # cache miss or stale: re-resolve the misses from mise's authoritative list
  # (no hard-coded versions, so a jq/gh upgrade is picked up automatically)
  local dirs
  dirs="$(mise bin-paths 2>/dev/null)" || return 0
  [ -z "$dirs" ] && return 0
  for t in "$@"; do
    case " $found " in (*" $t "*) continue;; esac
    while IFS= read -r p; do
      [ -n "$p" ] && [ -x "$p/$t" ] && { printf '%s %s\n' "$t" "$p/$t"; break; }
    done <<EOF
$dirs
EOF
  done
}

# Shadow each tool that currently resolves to a mise shim.
toolpath_init() { # [tool]... (default: jq gh)
  local resolved t p
  [ "$#" -eq 0 ] && set -- jq gh
  # only tools actually behind a shim are candidates
  local want=""
  for t in "$@"; do
    case "$(command -v "$t" 2>/dev/null)" in
      (*/shims/*) want="${want:+$want }$t";;
    esac
  done
  [ -z "$want" ] && return 0

  resolved="$(_toolpath_resolve $want 2>/dev/null)" || return 0
  [ -z "$resolved" ] && return 0

  while read -r t p; do
    [ -n "$t" ] && [ -n "$p" ] && [ -x "$p" ] || continue
    # `command` bypasses this function on re-entry, so no recursion
    eval "$t() { command '$p' \"\$@\"; }"
  done <<EOF
$resolved
EOF

  mkdir -p "$(dirname "$TOOLPATH_CACHE")" 2>/dev/null \
    && printf '%s\n' "$resolved" > "$TOOLPATH_CACHE" 2>/dev/null || true
  return 0
}

# Report tools still reaching through a shim (audit's tool_shims check).
toolpath_shimmed() { # [tool]... -> space-separated names, empty when clean
  local t out=""
  [ "$#" -eq 0 ] && set -- jq gh
  for t in "$@"; do
    # a shadowing function counts as resolved; only a bare shim path is a finding
    case "$(type -t "$t" 2>/dev/null)" in (function) continue;; esac
    case "$(command -v "$t" 2>/dev/null)" in
      (*/shims/*) out="${out:+$out }$t";;
    esac
  done
  printf '%s' "$out"
}

toolpath_init
