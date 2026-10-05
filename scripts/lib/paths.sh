#!/usr/bin/env bash
# paths.sh — match a changed path against a comma-separated glob list
# (docs/config.md → human_review_paths).
#
#   path_glob_match <path> <globs>   # prints the first matching glob; rc 0 on a match
#
# A glob is a shell pattern whose `*` crosses `/`; backticks and blanks around
# each entry are ignored. Sourced by preflight.sh and review-pr.sh.

path_glob_match() {
  local p="$1" g
  [ -n "$p" ] && [ -n "$2" ] || return 1
  while IFS= read -r g; do
    g="$(printf '%s' "$g" | tr -d '`' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -n "$g" ] || continue
    # shellcheck disable=SC2053  # $g is the pattern
    [[ "$p" == $g ]] && { printf '%s' "$g"; return 0; }
  done <<< "$(printf '%s' "$2" | tr ',' '\n')"
  return 1
}
