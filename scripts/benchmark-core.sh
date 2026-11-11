#!/usr/bin/env bash
# benchmark-core.sh — mechanical steps of the benchmark core versions
# (docs/benchmark.md). Executes, never judges: it prints what it found (a
# leaking fixture, an existing version) and the agent decides what to do.
#
#   benchmark-core.sh migrate <work/benchmark dir> [--author <model|unknown>]
#   benchmark-core.sh new-version <work/benchmark dir> <staged-core-dir>
#   benchmark-core.sh memory-sha <dir>
#
# migrate — an existing fixture set becomes core version 1, idempotently:
#   copies the live work/MEMORY.md and LESSONS.md to fixture/core-memory/,
#   runs the validator's leak check against that copy (prints `leak <slug>`
#   per failing fixture, moves nothing), adds ONE non-comparable line under
#   the RESULTS.md header (when the file exists and the line is not there),
#   then writes fixture/CORE.json last: {version 1, created, migrated true,
#   memory_sha, fixtures, author_model (manifest author_model, else --author,
#   else unknown), bridged_from null}. CORE.json present → prints
#   `already core v<N>` and changes nothing.
# new-version — moves the current core (its slugs, CORE.json, core-memory/) to
#   fixture/retired/core-v<N>/ and installs every fixture dir of the staged dir
#   as version N+1, with a fresh core-memory copy of the live memory and
#   bridged_from N. Refuses (exit 1, nothing moved) under a live run lock
#   (.run-lock or trials/*/.run-lock younger than 6 h), without CORE.json, when
#   retired/core-v<N> exists, when a staged slug already exists in fixture/,
#   or when the staged set fails benchmark-validate.sh fixture against the new
#   memory copy.
# memory-sha — the run-input memory hash: `git hash-object <dir>/MEMORY.md`,
#   empty when the file is missing. The single home of the computation:
#   benchmark-provenance.sh and the validator call it.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$SCRIPT_DIR/lib/toolpath.sh" ] && . "$SCRIPT_DIR/lib/toolpath.sh" 2>/dev/null

die() { printf '%s\n' "$*" >&2; exit 1; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

memory_sha() { # <dir>
  [ -f "$1/MEMORY.md" ] || return 0
  git hash-object "$1/MEMORY.md" 2>/dev/null || true
}

# fixture dirs of a root: dirs holding manifest.json, never retired/core-memory
slugs_of() { # <root>
  local s
  for s in "$1"/*/; do
    [ -f "$s/manifest.json" ] || continue
    s="${s%/}"; s="${s##*/}"
    case "$s" in (retired|core-memory) continue;; esac
    printf '%s\n' "$s"
  done
}

# copy the live memory files (work/ = parent of the benchmark dir) to <dest>
freeze_memory() { # <bdir> <dest>
  local work f
  work="$(cd "$1/.." && pwd)"
  mkdir -p "$2" || return 1
  for f in MEMORY.md LESSONS.md; do
    [ -f "$work/$f" ] && { cp "$work/$f" "$2/$f" || return 1; }
  done
  return 0
}

# CORE.json for <root> with the given slugs
write_core() { # <root> <version> <migrated> <bridged|null> <author> <slug>...
  local root="$1" ver="$2" mig="$3" br="$4" author="$5" sha s am='{}' tmp
  shift 5
  sha="$(memory_sha "$root/core-memory")"
  for s in "$@"; do
    am="$(printf '%s' "$am" | jq --arg s "$s" --arg a "$(jq -r --arg d "$author" \
            '(.author_model // "") | if . == "" then $d else . end' "$root/$s/manifest.json" 2>/dev/null || printf '%s' "$author")" \
            '. + {($s): $a}')"
  done
  tmp="$root/CORE.json.tmp.$$"
  jq -n --argjson v "$ver" --arg c "$(now_iso)" --argjson m "$mig" --arg sha "$sha" \
        --argjson am "$am" --argjson br "$br" '
    {version: $v, created: $c, migrated: $m,
     memory_sha: (if $sha == "" then null else $sha end),
     fixtures: ($am | keys), author_model: $am, bridged_from: $br}' > "$tmp" \
    && mv "$tmp" "$root/CORE.json"
}

# a live run lock: first line `<ISO> <nonce>` younger than 6 h
lock_live() { # <bdir>
  local l iso t now
  now="$(date -u +%s)"
  for l in "$1/.run-lock" "$1"/trials/*/.run-lock; do
    [ -f "$l" ] || continue
    iso="$(head -1 "$l" | cut -d' ' -f1)"
    t="$(date -u -d "$iso" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" +%s 2>/dev/null || echo 0)"
    [ $((now - t)) -lt 21600 ] && { printf '%s' "$l"; return 0; }
  done
  return 1
}

cmd_migrate() {
  local bdir="" author=unknown fix ver slugs n line res iso s
  local -a dirs=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      (--author) author="${2:-unknown}"; shift 2 2>/dev/null || shift;;
      (*) bdir="$1"; shift;;
    esac
  done
  [ -n "$bdir" ] || die 'usage: benchmark-core.sh migrate <work/benchmark dir> [--author <model|unknown>]'
  fix="$bdir/fixture"
  if [ -f "$fix/CORE.json" ]; then
    ver="$(jq -r '.version // "?"' "$fix/CORE.json" 2>/dev/null)"
    printf 'already core v%s\n' "${ver:-?}"; return 0
  fi
  slugs="$(slugs_of "$fix")"
  [ -n "$slugs" ] || die "no fixture in $fix — nothing to migrate"
  freeze_memory "$bdir" "$fix/core-memory" || die "cannot copy the live memory to $fix/core-memory"

  # leak check against the frozen copy — reported, never acted on
  for s in $slugs; do dirs+=("$fix/$s"); done
  bash "$SCRIPT_DIR/benchmark-validate.sh" leak "$fix/core-memory" "${dirs[@]}" 2>/dev/null \
    | sed -n 's/^FAIL leak_memory\[\([^]]*\)\].*/leak \1/p'

  iso="$(now_iso)"
  res="$bdir/RESULTS.md"
  if [ -f "$res" ]; then
    if grep -q 'read the live memory — not comparable with core version 1' "$res"; then
      printf 'results-note present\n'
    else
      line="_Runs before $iso read the live memory — not comparable with core version 1._"
      awk -v line="$line" '
        !done && /^\|/ { print line; print ""; done = 1 }
        { print }
        END { if (!done) { print ""; print line } }' "$res" > "$res.tmp.$$" && mv "$res.tmp.$$" "$res"
      printf 'results-note added\n'
    fi
  else
    printf 'results-note skipped: no RESULTS.md\n'
  fi

  # shellcheck disable=SC2086
  write_core "$fix" 1 true null "$author" $slugs || die "cannot write $fix/CORE.json"
  n="$(printf '%s\n' "$slugs" | grep -c '')"
  printf 'core v1 migrated: %s fixture(s), memory_sha %s\n' "$n" "$(jq -r '.memory_sha // "none"' "$fix/CORE.json")"
}

cmd_new_version() {
  local bdir="${1:-}" staged="${2:-}" fix ver next lock old new s tmpmem out
  local -a dirs=()
  [ -n "$bdir" ] && [ -d "$staged" ] || die 'usage: benchmark-core.sh new-version <work/benchmark dir> <staged-core-dir>'
  fix="$bdir/fixture"
  lock="$(lock_live "$bdir")" && die "refused: live run lock $lock — wait until the run ends or the lock is 6 h old"
  [ -f "$fix/CORE.json" ] || die "refused: $fix/CORE.json missing — run benchmark-core.sh migrate first"
  ver="$(jq -r '.version' "$fix/CORE.json" 2>/dev/null)"
  case "$ver" in (''|*[!0-9]*) die "refused: CORE.json version is not an integer";; esac
  next=$((ver + 1))
  [ -e "$fix/retired/core-v$ver" ] && die "refused: $fix/retired/core-v$ver exists"
  new="$(slugs_of "$staged")"
  [ -n "$new" ] || die "refused: no fixture in $staged"
  old="$(jq -r '.fixtures[]' "$fix/CORE.json")"
  for s in $new; do
    printf '%s\n' "$old" | grep -qx -- "$s" && continue
    [ -e "$fix/$s" ] && die "refused: $fix/$s exists and is not in core v$ver"
  done

  tmpmem="$staged/.core-memory.tmp"
  rm -rf "$tmpmem"
  freeze_memory "$bdir" "$tmpmem" || die "refused: cannot copy the live memory"
  for s in $new; do dirs+=("$staged/$s"); done
  if ! out="$(bash "$SCRIPT_DIR/benchmark-validate.sh" fixture --memory "$tmpmem" "${dirs[@]}" 2>&1)"; then
    rm -rf "$tmpmem"
    printf '%s\n' "$out" | grep '^FAIL' >&2
    die "refused: the staged set fails validation"
  fi

  mkdir -p "$fix/retired/core-v$ver" || die "cannot create $fix/retired/core-v$ver"
  for s in $old; do
    [ -d "$fix/$s" ] && mv "$fix/$s" "$fix/retired/core-v$ver/$s"
  done
  mv "$fix/CORE.json" "$fix/retired/core-v$ver/CORE.json"
  [ -d "$fix/core-memory" ] && mv "$fix/core-memory" "$fix/retired/core-v$ver/core-memory"
  for s in $new; do mv "$staged/$s" "$fix/$s"; done
  mv "$tmpmem" "$fix/core-memory"
  # shellcheck disable=SC2086
  write_core "$fix" "$next" false "$ver" unknown $new || die "cannot write $fix/CORE.json"
  printf 'core v%s installed: %s fixture(s), core v%s retired to retired/core-v%s\n' \
    "$next" "$(printf '%s\n' "$new" | grep -c '')" "$ver" "$ver"
}

case "${1:-}" in
  (migrate) shift; cmd_migrate "$@";;
  (new-version) shift; cmd_new_version "$@";;
  (memory-sha) [ -n "${2:-}" ] || die 'usage: benchmark-core.sh memory-sha <dir>'; memory_sha "$2";;
  (*) printf 'usage: benchmark-core.sh migrate <bdir> [--author <model>] | new-version <bdir> <staged-dir> | memory-sha <dir>\n' >&2; exit 2;;
esac
