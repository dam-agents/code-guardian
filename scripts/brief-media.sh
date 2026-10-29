#!/usr/bin/env bash
# brief-media.sh — the screenshots and recordings of merged PRs, downloaded for
# the daily brief's thread (docs/brief.md → **Screenshots**).
#
# The agent picks the PRs; this script fetches their media. It reads only the
# PR body and the PR author's first comment, rendered by GitHub, and keeps
# only media GitHub itself hosts: uploaded attachments and files of the target
# repository. A file whose first bytes are not an image or a video is dropped.
#
#   fetch <work-dir> <pr>…   download into $CG_BRIEF_MEDIA_DIR (default
#                            $HOME/brief-media), emptied first
#   clean                    remove that directory
#
# Prints one JSON object and exits 0: {outcome, dir, media[{pr, path, kind,
# bytes, alt}], skipped[{pr, host, reason}]}. No URL is printed: an uploaded
# attachment's URL carries a short-lived token. The GitHub token goes only to
# `gh`, never to curl. Requires bash, jq, gh, curl, od, sed/grep — awk-free.

set -u
export LC_ALL=C

DIR="${CG_BRIEF_MEDIA_DIR:-$HOME/brief-media}"
PER_PR=3          # media per PR
MAX_TOTAL=5       # media per brief
MAX_BYTES=52428800  # the platform's attachment cap (50 MB)

out() { printf '%s\n' "$1"; exit 0; }
fail() { out "$(jq -nc --arg e "$1" '{outcome:"error", error:$e}')"; }

CMD="${1:-}"; shift 2>/dev/null || true
case "$CMD" in
  (clean) rm -rf "$DIR"; out '{"outcome":"ok"}';;
  (fetch) ;;
  (*) printf 'usage: %s fetch <work-dir> <pr>… | clean\n' "$0" >&2; exit 2;;
esac

WORK="${1:-}"; shift 2>/dev/null || true
[ -n "$WORK" ] && [ -d "$WORK" ] || fail "work dir missing"
CONFIG="$WORK/CONFIG.md"
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
TARGET_REF="$(cfg github_repo)"
[ -n "$TARGET_REF" ] || TARGET_REF="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)"
[ -n "$TARGET_REF" ] || fail "no target repository"
HOST="$(refhost "$TARGET_REF")"; REPO="$(refslug "$TARGET_REF")"
export GH_HOST="$HOST"
HTML='Accept: application/vnd.github.html+json'

rm -rf "$DIR"; mkdir -p "$DIR" || fail "cannot create $DIR"
MEDIA='[]'; SKIPPED='[]'; TOTAL=0

skip() { # <pr> <url> <reason>
  local h="${2#*://}"; h="${h%%/*}"
  SKIPPED="$(jq -c --argjson p "$1" --arg h "$h" --arg r "$3" '. + [{pr:$p, host:$h, reason:$r}]' <<<"$SKIPPED")"
}

# image|video and the extension, from the first bytes; empty when neither
kind_of() { # <file>
  local x; x="$(od -An -tx1 -N12 "$1" 2>/dev/null | tr -d ' \n')"
  case "$x" in
    (89504e47*) echo "image png";;
    (ffd8ff*) echo "image jpg";;
    (47494638*) echo "image gif";;
    (52494646????????57454250*) echo "image webp";;
    (????????66747970*) echo "video mp4";;
    (1a45dfa3*) echo "video webm";;
  esac
}

# a file of the target repository: <ref>/<path> after the repo prefix; a ref
# with slashes is tried at each split, shortest first
fetch_repo_file() { # <ref/path> <dest>
  local rest="${1%%\?*}" ref="" path i
  for i in 1 2 3; do
    ref="${ref:+$ref/}${rest%%/*}"; path="${rest#*/}"
    [ "$path" = "$rest" ] && return 1
    gh api "repos/$REPO/contents/$path?ref=$ref" -H 'Accept: application/vnd.github.raw' > "$2" 2>/dev/null \
      && return 0
    rest="$path"
  done
  return 1
}

fetch_one() { # <pr> <url> <alt>
  local url="$2" f="$DIR/$1-$((TOTAL+1)).part" k bytes
  case "$url" in
    (https://private-user-images.githubusercontent.com/*|https://user-images.githubusercontent.com/*|"https://$HOST/user-attachments/"*)
      curl -fsSL --max-time 60 --max-filesize "$MAX_BYTES" -o "$f" "$url" 2>/dev/null \
        || { rm -f "$f"; skip "$1" "$url" "download failed"; return; };;
    ("https://$HOST/$REPO/raw/"*|"https://$HOST/$REPO/blob/"*)
      fetch_repo_file "${url#"https://$HOST/$REPO/"*/}" "$f" \
        || { rm -f "$f"; skip "$1" "$url" "repository file not found"; return; };;
    ("https://raw.githubusercontent.com/$REPO/"*)
      fetch_repo_file "${url#"https://raw.githubusercontent.com/$REPO/"}" "$f" \
        || { rm -f "$f"; skip "$1" "$url" "repository file not found"; return; };;
    (*) skip "$1" "$url" "not hosted by GitHub for this repository"; return;;
  esac
  k="$(kind_of "$f")"
  [ -n "$k" ] || { rm -f "$f"; skip "$1" "$url" "not an image or a video"; return; }
  bytes="$(wc -c < "$f" | tr -d ' ')"
  [ "$bytes" -le "$MAX_BYTES" ] || { rm -f "$f"; skip "$1" "$url" "over 50 MB"; return; }
  TOTAL=$((TOTAL+1))
  mv "$f" "$DIR/$1-$TOTAL.${k#* }"
  MEDIA="$(jq -c --argjson p "$1" --arg f "$DIR/$1-$TOTAL.${k#* }" --arg k "${k%% *}" \
    --argjson b "$bytes" --arg a "$3" '. + [{pr:$p, path:$f, kind:$k, bytes:$b, alt:$a}]' <<<"$MEDIA")"
}

# src and alt of every <img>, <video> and <source> tag, as `src<TAB>alt`
media_tags() {
  grep -oE '<(img|video|source)[^>]*>' | while IFS= read -r tag; do
    src="$(printf '%s' "$tag" | sed -n 's/.* src="\([^"]*\)".*/\1/p')"
    [ -n "$src" ] || continue
    alt="$(printf '%s' "$tag" | sed -n 's/.* alt="\([^"]*\)".*/\1/p')"
    printf '%s\t%s\n' "$(printf '%s' "$src" | sed 's/&amp;/\&/g')" \
      "$(printf '%s' "$alt" | sed -e 's/&quot;/"/g' -e "s/&#39;/'/g" -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&amp;/\&/g')"
  done
}

for n in "$@"; do
  case "$n" in (''|*[!0-9]*) continue;; esac
  [ "$TOTAL" -lt "$MAX_TOTAL" ] || break
  pr="$(gh_get "repos/$REPO/pulls/$n" -H "$HTML")" || { skip "$n" "" "PR not readable"; continue; }
  author="$(jq -r '.user.login // ""' <<<"$pr")"
  comments="$(gh_get "repos/$REPO/issues/$n/comments?per_page=20" -H "$HTML")" \
    || { comments='[]'; skip "$n" "" "comments not readable"; }
  { jq -r '.body_html // ""' <<<"$pr"
    jq -r --arg a "$author" '[.[]? | select(.user.login == $a)][0].body_html // ""' <<<"$comments"
  } | media_tags > "$DIR/.tags"
  seen=""; took=0
  while IFS="$(printf '\t')" read -r url alt; do
    [ "$took" -lt "$PER_PR" ] && [ "$TOTAL" -lt "$MAX_TOTAL" ] || break
    case " $seen " in (*" $url "*) continue;; esac
    seen="$seen $url"; before=$TOTAL
    fetch_one "$n" "$url" "$alt"
    [ "$TOTAL" -gt "$before" ] && took=$((took+1))
  done < "$DIR/.tags"
done
rm -f "$DIR/.tags"

out "$(jq -nc --arg d "$DIR" --argjson m "$MEDIA" --argjson s "$SKIPPED" '{outcome:"ok", dir:$d, media:$m, skipped:$s}')"
