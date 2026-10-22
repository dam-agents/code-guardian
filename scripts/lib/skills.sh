#!/usr/bin/env bash
# skills.sh — the install of a repo-sourced skill into $HOME_DIR/.claude/skills
# and the lock under which an installed skill changes (docs/skills.md →
# Installation). Source lib/common.sh first; logev comes from log.sh, or a no-op.
#
# One install is one snapshot of the source's default branch: its HEAD SHA is
# the ref of the tree listing and of every file fetch, and its cache file
# (.cache/<skill>.sha) skips the next install while the SHA stays the same. The
# files are fetched into a stage and swapped in under the skills lock, so a
# reader that copies under the same lock (benchmark-isolate.sh start) never
# sees a half-installed skill beside its old cache SHA. A failed fetch keeps
# the installed copy.

# Runs <command…> while no repo-sourced skill under <home>/.claude/skills
# changes.
with_skills_lock() { # <home> <command…>
  local h="$1"; shift
  mkdir -p "$h/.claude/skills/.cache"
  with_state_lock "$h/.claude/skills/.cache/install" "$@"
}

skill_swap() { # <stage> <dest> <sha> <sha-file>
  rm -rf "$2" && mv "$1" "$2" && { [ -z "$3" ] || printf '%s' "$3" > "$4"; }
}

# prints the status: installed (N files) | cached | harness | install-failed
install_skill() { # <name> <source>
  local name="$1" src="$2" dir="$HOME_DIR/.claude/skills" cache h slug sha ref cached count=0 p rel stage
  cache="$dir/.cache"
  [ "$src" = "harness" ] && { printf 'harness'; return; }
  h="$(refhost "$src")"; slug="$(refslug "$src")"
  sha="$(gh api --hostname "$h" "repos/$slug/commits/HEAD" 2>/dev/null | jq -r '.sha // empty')"
  ref="${sha:-HEAD}"
  mkdir -p "$cache"
  cached="$(cat "$cache/$name.sha" 2>/dev/null || true)"
  if [ -n "$sha" ] && [ "$sha" = "$cached" ] && [ -d "$dir/$name" ]; then
    printf 'cached'; return
  fi
  stage="$cache/.stage-$name.${BASHPID:-$$}"
  rm -rf "$stage"
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    rel="${p#.agents/skills/$name/}"
    mkdir -p "$stage/$(dirname "$rel")"
    gh api --hostname "$h" "repos/$slug/contents/$p?ref=$ref" -H 'Accept: application/vnd.github.raw' \
      > "$stage/$rel" 2>/dev/null \
      || { rm -rf "$stage"; logev error skill_install "$name from $src: fetch of $p did not succeed"; printf 'install-failed'; return; }
    count=$((count+1))
  done < <(gh api --hostname "$h" "repos/$slug/git/trees/$ref?recursive=1" 2>/dev/null \
           | jq -r --arg pre ".agents/skills/$name/" '.tree[] | select(.type=="blob") | select(.path | startswith($pre)) | .path')
  [ "$count" -eq 0 ] && { rm -rf "$stage"; logev error skill_install "$name from $src: no files found (tree listing empty or unreachable)"; printf 'install-failed'; return; }
  with_skills_lock "$HOME_DIR" skill_swap "$stage" "$dir/$name" "$sha" "$cache/$name.sha"
  printf 'installed (%s files)' "$count"
}
