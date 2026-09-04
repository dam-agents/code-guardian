#!/usr/bin/env bash
# profile.sh — the target repository's project profile (docs/profile.md).
#
# A deterministic map of the reviewed repository — modules, documentation ↔
# code paths, decision records, conventions, ownership, CI checks, noise
# globs, and the agent's own finding history — generated from the default
# branch and kept current by a structural fingerprint. It orients the agent
# and its skill subagents; it is never evidence for a finding.
#
#   profile.sh check                keep the profile current: ls-remote →
#                                   fetch → fingerprint → regenerate when the
#                                   structure, the TTL, or the definition
#                                   version changed; prints one JSON status
#   profile.sh generate             unconditional regeneration (onboarding,
#                                   operator request); same JSON status
#   profile.sh slice <files.json>   per-PR excerpt for a changed-file list
#                                   ([{path,status}]): classified files,
#                                   matching profile rows (+ verify_live),
#                                   structure_changed, history rows, and the
#                                   area-memory files whose scope matches
#
# Files: work/PROFILE.json (data), work/PROFILE.md (the agent-facing render),
# work/PROFILE-NOTES.md (agent-owned notes — read here, never written).
# Mirror: a bare, blob-less, depth-1 clone of the default branch under
# $CG_MIRROR_ROOT (default ${TMPDIR:-/tmp}/code-guardian-mirror), off the
# shared NFS volume (docs/persistence.md) and rebuilt whenever it is missing.
# The GitHub tree/contents API is the fallback when git cannot reach the
# remote. GitHub-read-only; local writes stay in work/PROFILE.{json,md} and
# the mirror. Requires bash, git, jq, gh, sed/grep/cut/tr, sha1sum|shasum —
# deliberately awk-free (awk is not available in the pod).
#
# Overrides (tests, operators): CG_MIRROR_ROOT, CG_PROFILE_REMOTE (clone URL),
# CG_PROFILE_TTL_DAYS (default 7).

set -u
export LC_ALL=C

CMD="${1:-check}"
HOME_DIR="${HOME:-/home/agent}"
WORK="${WORK_DIR:-$HOME_DIR/work}"
CONFIG="$WORK/CONFIG.md"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROFILE_JSON="$WORK/PROFILE.json"
PROFILE_MD="$WORK/PROFILE.md"
NOTES_MD="$WORK/PROFILE-NOTES.md"
NOW_EPOCH=$(date -u +%s)
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TTL_DAYS="${CG_PROFILE_TTL_DAYS:-7}"
TTL_ONLY_DAYS=1                       # regeneration cadence when no fingerprint is possible
HISTORY_DAYS=90
MAX_MODULES=200; MAX_DOCS=300; MAX_DECISIONS=300; MAX_OWNERS=100
MAX_CONVENTION_BYTES=12288; MAX_API_READS=80; MAX_HISTORY_ROWS=40
GENERATOR="$(head -1 "$SCRIPT_DIR/../VERSION" 2>/dev/null | tr -d '[:space:]')"
GENERATOR="${GENERATOR:-unknown}"
TAB="$(printf '\t')"

LOG_JOB="${LOG_JOB:-review}"
if ! . "$SCRIPT_DIR/log.sh" 2>/dev/null; then logev() { :; }; fi

cfg() { sed -n "s/^- $1:[[:space:]]*//p" "$CONFIG" 2>/dev/null | head -1 \
        | sed -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//' \
              -e 's/^[`"'"'"']//' -e 's/[`"'"'"']$//'; }
trim() { printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }
unquote() { sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e "s/^['\"]//" -e "s/['\"]\$//"; }
iso2epoch() { date -d "$1" +%s 2>/dev/null || date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || echo 0; }
sha1() { if command -v sha1sum >/dev/null 2>&1; then sha1sum | cut -d' ' -f1; else shasum | cut -d' ' -f1; fi; }

DEFAULT_HOST="${GH_HOST:-github.com}"
refhost() { case "$1" in (*/*/*) printf '%s' "${1%%/*}";; (*) printf '%s' "$DEFAULT_HOST";; esac; }
refslug() { case "$1" in (*/*/*) printf '%s' "${1#*/}";;  (*) printf '%s' "$1";; esac; }
TARGET_REF="${GITHUB_REPO:-$(cfg github_repo)}"
REPO_HOST="$(refhost "$TARGET_REF")"; REPO="$(refslug "$TARGET_REF")"
export GH_HOST="$REPO_HOST"
REMOTE="${CG_PROFILE_REMOTE:-https://$REPO_HOST/$REPO.git}"
MIRROR_ROOT="${CG_MIRROR_ROOT:-${TMPDIR:-/tmp}/code-guardian-mirror}"
MIRROR="$MIRROR_ROOT/$REPO_HOST/$REPO.git"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cg-profile.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------- shapes ----
# structure-bearing paths — the fingerprint's domain (docs/profile.md)
ROOT_STRUCT_RE='^(CLAUDE\.md|AGENTS\.md|CONTRIBUTING\.md|CODEOWNERS|\.gitattributes|\.editorconfig|package\.json|pnpm-workspace\.yaml|lerna\.json|nx\.json|turbo\.json|go\.work|go\.mod|Cargo\.toml|pyproject\.toml|setup\.cfg|pom\.xml|build\.gradle|build\.gradle\.kts|Makefile|Gemfile|composer\.json|[^/]+\.sln|\.github/CODEOWNERS|docs/CODEOWNERS|\.github/CONTRIBUTING\.md|\.cursorrules|\.github/copilot-instructions\.md)$'
MANIFEST_RE='(^|/)(package\.json|go\.mod|Cargo\.toml|pyproject\.toml|setup\.cfg|pom\.xml|build\.gradle|build\.gradle\.kts|[^/]+\.csproj|composer\.json|Gemfile)$'
EXCL_RE='(^|/)(node_modules|vendor|dist|build|out|target|\.git|__pycache__|\.venv|venv|bower_components|third_party|3rdparty|\.next|\.cache)(/|$)'
DOC_ROOT_RE='^(docs|doc|documentation|wiki)$'
ADR_NAME_RE='(adr|adrs|decisions|decision-records|rfcs|rfc|architecture-decisions)'
ADR_DIR_RE="(^|/)${ADR_NAME_RE}\$"
WORKFLOW_RE='^\.github/workflows/[^/]+\.ya?ml$'
CONVENTION_FILES="CLAUDE.md AGENTS.md CONTRIBUTING.md .github/CONTRIBUTING.md .cursorrules .github/copilot-instructions.md"
OWNER_FILES="CODEOWNERS .github/CODEOWNERS docs/CODEOWNERS"

builtin_noise_json() {
  jq -nc '[
    {glob:"package-lock.json",class:"lockfile"},{glob:"pnpm-lock.yaml",class:"lockfile"},{glob:"yarn.lock",class:"lockfile"},
    {glob:"bun.lockb",class:"lockfile"},{glob:"Cargo.lock",class:"lockfile"},{glob:"poetry.lock",class:"lockfile"},
    {glob:"Pipfile.lock",class:"lockfile"},{glob:"uv.lock",class:"lockfile"},{glob:"go.sum",class:"lockfile"},
    {glob:"Gemfile.lock",class:"lockfile"},{glob:"composer.lock",class:"lockfile"},{glob:"flake.lock",class:"lockfile"},
    {glob:"pubspec.lock",class:"lockfile"},{glob:"mix.lock",class:"lockfile"},{glob:"packages.lock.json",class:"lockfile"},
    {glob:"**/__snapshots__/**",class:"snapshot"},{glob:"*.snap",class:"snapshot"},
    {glob:"**/dist/**",class:"build"},{glob:"**/build/**",class:"build"},{glob:"**/target/**",class:"build"},
    {glob:"**/vendor/**",class:"vendored"},{glob:"**/node_modules/**",class:"vendored"},{glob:"**/third_party/**",class:"vendored"},
    {glob:"*.min.js",class:"minified"},{glob:"*.min.css",class:"minified"},{glob:"*.map",class:"sourcemap"},
    {glob:"**/generated/**",class:"generated"},{glob:"**/__generated__/**",class:"generated"},{glob:"*.generated.*",class:"generated"},
    {glob:"*.pb.go",class:"generated"},{glob:"*_pb2.py",class:"generated"},{glob:"*.pb.ts",class:"generated"},{glob:"*.g.dart",class:"generated"}
  ] | map(. + {src:"builtin"})'
}

# --------------------------------------------------------- status output ----
emit_status() { # <status> <mode> [note]
  local base="" verified="" gen="" trunc='[]' age=null
  if [ -f "$PROFILE_JSON" ]; then
    base="$(jq -r '.base.sha // empty' "$PROFILE_JSON" 2>/dev/null)"
    verified="$(jq -r '.verified.sha // empty' "$PROFILE_JSON" 2>/dev/null)"
    gen="$(jq -r '.generated // empty' "$PROFILE_JSON" 2>/dev/null)"
    trunc="$(jq -c '.truncated // []' "$PROFILE_JSON" 2>/dev/null)"; [ -n "$trunc" ] || trunc='[]'
    [ -n "$gen" ] && age=$(( (NOW_EPOCH - $(iso2epoch "$gen")) / 3600 ))
  fi
  jq -nc --arg s "$1" --arg m "$2" --arg n "${3:-}" --arg b "$base" --arg v "$verified" --arg g "$gen" \
    --argjson t "$trunc" --argjson a "$age" --arg f "$PROFILE_MD" \
    '{status:$s, mode:$m, file:$f,
      base:(if $b=="" then null else $b[0:12] end), verified:(if $v=="" then null else $v[0:12] end),
      generated:(if $g=="" then null else $g end), age_hours:$a, truncated:$t}
     + (if $n=="" then {} else {note:$n} end)'
  logev info profile "$1 ($2)${3:+ — $3}"
  exit 0
}

# ------------------------------------------------------------- the tree ----
# TREE_FILE: "<type>\t<sha>\t<path>" for every entry (blobs and trees);
# PATHS_FILE: every path, one per line — prefix checks grep this.
MODE=""; REMOTE_SHA=""; BRANCH=""; TREE_FILE="$TMP/tree.tsv"; PATHS_FILE="$TMP/paths.txt"
API_TRUNCATED=0

default_branch() {
  local b=""
  [ -f "$PROFILE_JSON" ] && b="$(jq -r '.default_branch // empty' "$PROFILE_JSON" 2>/dev/null)"
  [ -n "$b" ] || b="$(gh api "repos/$REPO" 2>/dev/null | jq -r '.default_branch // empty' 2>/dev/null)"
  printf '%s' "${b:-main}"
}

remote_sha() { # tip of $BRANCH at the remote; empty when unreachable
  command -v git >/dev/null 2>&1 \
    && git ls-remote -q "$REMOTE" "refs/heads/$BRANCH" 2>/dev/null | head -1 | cut -f1 \
    || true
}

# The mirror is an accelerator, not state: absent → clone, present → fetch the
# tip; both under a mkdir lock so concurrent heartbeats never clone twice (a
# lock older than 15 min belongs to a dead run). Returns 0 iff the mirror holds
# $REMOTE_SHA afterwards.
mirror_ready() {
  command -v git >/dev/null 2>&1 || return 1
  mkdir -p "$(dirname "$MIRROR")" 2>/dev/null || return 1
  find "$MIRROR.lock" -maxdepth 0 -mmin +15 -exec rm -rf {} \; 2>/dev/null || true
  mkdir "$MIRROR.lock" 2>/dev/null || return 1
  local rc=0
  if [ ! -d "$MIRROR" ]; then
    git clone -q --bare --filter=blob:none --depth 1 --single-branch --branch "$BRANCH" "$REMOTE" "$MIRROR" 2>/dev/null \
      || { rm -rf "$MIRROR"; git clone -q --bare --depth 1 --single-branch --branch "$BRANCH" "$REMOTE" "$MIRROR" 2>/dev/null; } \
      || rc=1
  else
    git -C "$MIRROR" fetch -q --depth 1 origin "+refs/heads/$BRANCH:refs/heads/$BRANCH" 2>/dev/null || rc=1
  fi
  rmdir "$MIRROR.lock" 2>/dev/null || true
  [ "$rc" -eq 0 ] || return 1
  git -C "$MIRROR" cat-file -e "$REMOTE_SHA^{commit}" 2>/dev/null
}

load_tree() { # fills TREE_FILE/PATHS_FILE from the mirror, else the API; sets MODE
  if mirror_ready; then
    MODE=mirror
    git -C "$MIRROR" ls-tree -r -t --full-tree "$REMOTE_SHA" 2>/dev/null \
      | sed -E "s/^[0-9]+ (blob|tree|commit) ([0-9a-f]+)${TAB}/\1${TAB}\2${TAB}/" > "$TREE_FILE"
  else
    MODE=api
    [ -n "$REMOTE_SHA" ] || REMOTE_SHA="$(gh api "repos/$REPO/branches/$BRANCH" 2>/dev/null | jq -r '.commit.sha // empty' 2>/dev/null)"
    [ -n "$REMOTE_SHA" ] || return 1
    gh api "repos/$REPO/git/trees/$REMOTE_SHA?recursive=1" > "$TMP/tree.json" 2>/dev/null || return 1
    [ "$(jq -r '.truncated // false' "$TMP/tree.json" 2>/dev/null)" = "true" ] && API_TRUNCATED=1
    jq -r '.tree[]? | [.type, .sha, .path] | @tsv' "$TMP/tree.json" > "$TREE_FILE" 2>/dev/null
  fi
  [ -s "$TREE_FILE" ] || return 1
  cut -f3 "$TREE_FILE" > "$PATHS_FILE"
}

blobs()  { grep "^blob${TAB}" "$TREE_FILE" | cut -f3; }
trees()  { grep "^tree${TAB}" "$TREE_FILE" | cut -f3; }
blob_sha() { grep "^blob${TAB}[0-9a-f]*${TAB}$1\$" "$TREE_FILE" | head -1 | cut -f2; }
tree_sha() { grep "^tree${TAB}[0-9a-f]*${TAB}$1\$" "$TREE_FILE" | head -1 | cut -f2; }
has_path() { grep -qxF -- "$1" "$PATHS_FILE"; }
# a path that some tree entry begins with (dir prefix or exact path)
has_prefix() { grep -qE -- "^$(printf '%s' "$1" | sed 's/[][\.*^$+?(){}|]/\\&/g')(/|$)" "$PATHS_FILE"; }

: > "$TMP/api_reads"
blob_cat() { # <path> → contents; rc 1 when unreadable or capped
  if [ "$MODE" = mirror ]; then
    git -C "$MIRROR" show "$REMOTE_SHA:$1" 2>/dev/null
  else
    [ "$(grep -c . "$TMP/api_reads")" -lt "$MAX_API_READS" ] || { echo capped >> "$TMP/api_capped"; return 1; }
    echo . >> "$TMP/api_reads"
    gh api "repos/$REPO/contents/$1?ref=$REMOTE_SHA" -H 'Accept: application/vnd.github.raw' 2>/dev/null
  fi
}

# fingerprint — sorted lines over the structure-bearing entries (docs/profile.md)
fingerprint() {
  {
    grep "^blob${TAB}" "$TREE_FILE" | cut -f2,3 | grep -E -- "${TAB}${ROOT_STRUCT_RE#^}" | sed "s/^/blob /"
    grep "^blob${TAB}" "$TREE_FILE" | cut -f2,3 | grep -E -- "${TAB}.*${MANIFEST_RE}" \
      | grep -vE -- "${TAB}.*${EXCL_RE}" | grep -vE -- "${TAB}([^/]*/){7,}" | sed "s/^/blob /"
    grep "^tree${TAB}" "$TREE_FILE" | cut -f2,3 | grep -E -- "${TAB}(\.github/workflows|docs|doc|documentation|wiki)$" | sed "s/^/tree /"
    grep "^tree${TAB}" "$TREE_FILE" | cut -f2,3 | grep -iE -- "${TAB}([^/]+/){0,3}${ADR_NAME_RE}$" | sed "s/^/tree /"
    trees | grep -vE -- "$EXCL_RE" | grep -vE '.*/.*/' | sed 's/^/dir /'
  } | sort -u | sha1
}

# ------------------------------------------------------------ front matter ----
front_matter() { # <text> → the YAML block between the leading --- fences, or nothing
  local first; first="$(printf '%s\n' "$1" | head -1)"
  case "$first" in (---|---[[:space:]]*) printf '%s\n' "$1" | sed -n '2,/^---[[:space:]]*$/p' | sed '$d';; esac
}
fm_raw() { printf '%s\n' "$1" | sed -nE "s/^$2:[[:space:]]*(.*)$/\1/p" | head -1; }
fm_scalar() { fm_raw "$1" "$2" | tr -d '[]' | cut -d',' -f1 | unquote; }
fm_list() { # <fm> <key> → items, one per line
  local v; v="$(fm_raw "$1" "$2")"
  case "$v" in
    ('['*) printf '%s\n' "$v" | tr -d '[]' | tr ',' '\n' | unquote | grep -v '^$';;
    ('')  printf '%s\n' "$1" | sed -n "/^$2:[[:space:]]*$/,/^[^[:space:]]/p" \
            | sed -nE 's/^[[:space:]]*-[[:space:]]+(.*)$/\1/p' | unquote | grep -v '^$';;
    (*)   printf '%s\n' "$v" | unquote;;
  esac
}
first_heading() { printf '%s\n' "$1" | sed -nE 's/^#[[:space:]]+(.*)$/\1/p' | head -1 | sed -E 's/[[:space:]]+$//'; }

# --------------------------------------------------------------- sections ----
# every section writes one JSON array to $TMP/<name>.json; the assembly below
# merges them. Detectors emit nothing when their inputs are absent.
NOTE_TRUNC="$TMP/truncated.txt"; : > "$NOTE_TRUNC"
note_trunc() { printf '%s\n' "$1" >> "$NOTE_TRUNC"; }

gen_modules() {
  local ws_globs mf dir base kind name role body ws n=0 total
  # workspace globs: package.json workspaces, pnpm-workspace.yaml, go.work
  ws_globs="$( { has_path package.json && blob_cat package.json | jq -r '(.workspaces // []) | if type=="object" then (.packages // []) else . end | .[]?' 2>/dev/null
                 has_path pnpm-workspace.yaml && blob_cat pnpm-workspace.yaml | sed -nE "s/^[[:space:]]*-[[:space:]]*['\"]?([^'\"#[:space:]]+).*/\1/p"
                 has_path go.work && blob_cat go.work | sed -nE 's/^[[:space:]]*(use[[:space:]]+)?(\.\/[^[:space:])]+).*/\2/p'
               } 2>/dev/null | sed 's#^\./##; s#/$##' | grep -v '^$' | sort -u)"
  : > "$TMP/modules.jsonl"; : > "$TMP/module_dirs.txt"
  total=0
  while IFS= read -r mf; do
    [ -n "$mf" ] || continue
    total=$((total+1)); [ "$n" -lt "$MAX_MODULES" ] || continue
    case "$mf" in (*/*) dir="${mf%/*}";; (*) dir=".";; esac
    grep -qxF -- "$dir" "$TMP/module_dirs.txt" && continue   # one module per directory
    base="${mf##*/}"; name=""; role=""
    body="$(blob_cat "$mf" 2>/dev/null | head -200)"
    case "$base" in
      (package.json)  kind=node;   name="$(printf '%s' "$body" | jq -r '.name // empty' 2>/dev/null)"; role="$(printf '%s' "$body" | jq -r '.description // empty' 2>/dev/null)";;
      (go.mod)        kind=go;     name="$(printf '%s\n' "$body" | sed -nE 's/^module[[:space:]]+([^[:space:]]+).*/\1/p' | head -1)";;
      (Cargo.toml)    kind=rust;   name="$(printf '%s\n' "$body" | sed -nE 's/^name[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' | head -1)"; role="$(printf '%s\n' "$body" | sed -nE 's/^description[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' | head -1)";;
      (pyproject.toml|setup.cfg) kind=python; name="$(printf '%s\n' "$body" | sed -nE 's/^name[[:space:]]*=[[:space:]]*"?([^"[:space:]]+)"?.*/\1/p' | head -1)"; role="$(printf '%s\n' "$body" | sed -nE 's/^description[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' | head -1)";;
      (pom.xml)       kind=java;   name="$(printf '%s\n' "$body" | sed -nE 's/.*<artifactId>([^<]+)<\/artifactId>.*/\1/p' | head -1)"; role="$(printf '%s\n' "$body" | sed -nE 's/.*<description>([^<]+)<\/description>.*/\1/p' | head -1)";;
      (build.gradle|build.gradle.kts) kind=java; name="${dir##*/}";;
      (*.csproj)      kind=dotnet; name="${base%.csproj}"; role="$(printf '%s\n' "$body" | sed -nE 's/.*<Description>([^<]+)<\/Description>.*/\1/p' | head -1)";;
      (composer.json) kind=php;    name="$(printf '%s' "$body" | jq -r '.name // empty' 2>/dev/null)"; role="$(printf '%s' "$body" | jq -r '.description // empty' 2>/dev/null)";;
      (Gemfile)       kind=ruby;   name="${dir##*/}";;
      (*)             kind=other;;
    esac
    [ -n "$name" ] || name="$( [ "$dir" = "." ] && printf '%s' "${REPO##*/}" || printf '%s' "${dir##*/}")"
    if [ -z "$role" ]; then   # README: first heading + first prose line
      local rd h s
      rd="$( [ "$dir" = "." ] && printf 'README.md' || printf '%s/README.md' "$dir")"
      if has_path "$rd"; then
        rd="$(blob_cat "$rd" 2>/dev/null | head -40)"
        h="$(first_heading "$rd")"
        s="$(printf '%s\n' "$rd" | sed -n '/^#[[:space:]]/,$p' | tail -n +2 | grep -vE '^([[:space:]]*$|#|!\[|\[!|<|\||-|>|---|```)' | head -1 | sed -E 's/[[:space:]]+$//')"
        role="$h${s:+ — $s}"
      fi
    fi
    ws=false
    for g in $ws_globs; do case "$dir" in ($g) ws=true; break;; esac; done
    printf '%s\n' "$dir" >> "$TMP/module_dirs.txt"
    jq -nc --arg p "$dir" --arg n "$name" --arg k "$kind" --arg r "$role" --argjson w "$ws" --arg s "$mf" \
      '{path:$p, name:$n, kind:$k, workspace:$w, role:(if $r=="" then null else ($r|gsub("\\s+";" ")|.[0:160]) end), src:$s}' >> "$TMP/modules.jsonl"
    n=$((n+1))
  done < <(blobs | grep -E -- "$MANIFEST_RE" | grep -vE -- "$EXCL_RE" | grep -vE '^([^/]*/){7,}' | sort)
  [ "$total" -gt "$MAX_MODULES" ] && note_trunc "modules: $MAX_MODULES of $total listed (by path)"
  jq -s . "$TMP/modules.jsonl" > "$TMP/modules.json"
}

DOC_ROOTS=""; ADR_DIRS=""
detect_doc_dirs() {
  DOC_ROOTS="$(trees | grep -E -- "$DOC_ROOT_RE" | sort)"
  ADR_DIRS="$(trees | grep -iE -- "$ADR_DIR_RE" | grep -vE '^([^/]*/){4,}' | grep -vE -- "$EXCL_RE" | sort)"
}
under_adr() { local d; for d in $ADR_DIRS; do case "$1" in ("$d"/*) return 0;; esac; done; return 1; }

gen_docs() {
  local p body fm title stamp k v via n=0 total=0 sha paths tok base
  : > "$TMP/docs.jsonl"
  [ -n "$DOC_ROOTS" ] || { echo '[]' > "$TMP/docs.json"; return; }
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    under_adr "$p" && continue
    total=$((total+1)); [ "$n" -lt "$MAX_DOCS" ] || continue
    body="$(blob_cat "$p" 2>/dev/null | head -400)"
    fm="$(front_matter "$body")"
    title="$(fm_scalar "$fm" title)"; [ -n "$title" ] || title="$(first_heading "$body")"; [ -n "$title" ] || title="${p##*/}"
    stamp=""
    for k in last_verified last-verified lastVerified verified updated last_updated date; do
      stamp="$(fm_scalar "$fm" "$k")"; [ -n "$stamp" ] && break
    done
    [ -n "$stamp" ] || stamp="$(printf '%s\n' "$body" | head -40 | grep -m1 -iE 'last[ _-]?verified' | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)"
    sha="$(blob_sha "$p")"; [ -n "$stamp" ] || stamp="blob:${sha:0:7}"
    # mapping to code paths — front matter, then path mentions, then a name match
    paths=""; via=""
    for k in paths scope subsystem subsystems module modules components component code; do
      paths="$(fm_list "$fm" "$k")"; [ -n "$paths" ] && { via=frontmatter; break; }
    done
    if [ -n "$paths" ]; then
      paths="$(printf '%s\n' "$paths" | while IFS= read -r v; do
        case "$v" in
          (*/*|*\**) printf '%s\n' "$v";;
          (*) m="$(jq -r --arg v "$v" '.[] | select((.name|ascii_downcase)==($v|ascii_downcase) or ((.path|split("/")|last|ascii_downcase)==($v|ascii_downcase))) | .path' "$TMP/modules.json" 2>/dev/null | head -1)"
              if [ -n "$m" ]; then printf '%s/**\n' "$m"; else printf '**/%s/**\n' "$v"; fi;;
        esac; done | sed 's#^\./##' | sort -u)"
    else
      paths="$(printf '%s\n' "$body" | grep -oE '(^|[^A-Za-z0-9_./@:-])(\.?[A-Za-z0-9_-]+/)+[A-Za-z0-9_.-]*' \
        | sed -E 's/^[^A-Za-z0-9_./-]//; s#^\./##; s/[.,:;)]+$//' | grep -vE '^(https?|http)$|://' | sort -u | head -60 \
        | while IFS= read -r tok; do
            [ -n "$tok" ] || continue
            for d in $DOC_ROOTS; do case "$tok" in ("$d"|"$d"/*) continue 2;; esac; done
            case "$tok" in (*/*) ;; (*) continue;; esac
            tok="${tok%/}"
            has_prefix "$tok" || continue
            if grep -qxF -- "$tok" "$TMP/module_dirs.txt" || tree_sha "$tok" >/dev/null 2>&1 && [ -n "$(tree_sha "$tok")" ]; then printf '%s/**\n' "$tok"; else printf '%s\n' "$tok"; fi
          done | sort -u | head -5)"
      [ -n "$paths" ] && via=mention
    fi
    if [ -z "$paths" ]; then
      base="${p##*/}"; base="${base%.md}"
      paths="$(jq -r --arg b "$base" '[.[] | select((.path|split("/")|last|ascii_downcase)==($b|ascii_downcase) or (.name|ascii_downcase)==($b|ascii_downcase)) | .path] | if length==1 then .[0] + "/**" else empty end' "$TMP/modules.json" 2>/dev/null)"
      [ -n "$paths" ] && via=name
    fi
    jq -nc --arg p "$p" --arg t "$title" --arg s "$stamp" --arg v "$via" \
      --argjson paths "$(printf '%s\n' "$paths" | grep -v '^$' | jq -R . | jq -s .)" \
      '{page:$p, title:($t|.[0:120]), stamp:$s, paths:$paths, via:(if $v=="" then null else $v end), src:$p}' >> "$TMP/docs.jsonl"
    n=$((n+1))
  done < <(for d in $DOC_ROOTS; do blobs | grep -E -- "^$d/.*\.(md|mdx)$"; done | sort -u)
  [ "$total" -gt "$MAX_DOCS" ] && note_trunc "docs: $MAX_DOCS of $total pages listed (by path)"
  jq -s . "$TMP/docs.jsonl" > "$TMP/docs.json"
}

gen_decisions() {
  local p body fm id title status date scope n=0 total=0 d
  : > "$TMP/decisions.jsonl"
  [ -n "$ADR_DIRS" ] || { echo '[]' > "$TMP/decisions.json"; return; }
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "${p##*/}" in (README*|readme*|index*|INDEX*|*template*|*TEMPLATE*) continue;; esac
    total=$((total+1)); [ "$n" -lt "$MAX_DECISIONS" ] || continue
    body="$(blob_cat "$p" 2>/dev/null | head -80)"
    fm="$(front_matter "$body")"
    id="$(printf '%s' "${p##*/}" | sed -nE 's/^[A-Za-z-]*([0-9]+).*/\1/p')"; [ -n "$id" ] || id="-"
    title="$(fm_scalar "$fm" title)"; [ -n "$title" ] || title="$(first_heading "$body" | sed -E 's/^(ADR|RFC)[- ]?[0-9]+[:. -]*//I')"
    [ -n "$title" ] || title="${p##*/}"
    status="$(fm_scalar "$fm" status)"
    [ -n "$status" ] || status="$(printf '%s\n' "$body" | sed -n '/^##[[:space:]]*Status/,$p' | tail -n +2 | grep -v '^[[:space:]]*$' | head -1 | sed -E 's/^[*_[:space:]-]+//; s/[*_[:space:]].*$//')"
    status="$(printf '%s' "$status" | tr 'A-Z' 'a-z')"; [ -n "$status" ] || status="-"
    date="$(fm_scalar "$fm" date)"; [ -n "$date" ] || date="-"
    scope=""
    for d in subsystem subsystems scope tags components area; do
      scope="$(fm_list "$fm" "$d" | tr '\n' ',' | sed 's/,$//')"; [ -n "$scope" ] && break
    done
    jq -nc --arg id "$id" --arg t "$title" --arg s "$status" --arg d "$date" --arg sc "$scope" --arg p "$p" \
      '{id:$id, title:($t|.[0:120]), status:$s, scope:(if $sc=="" then null else ($sc|.[0:80]) end), date:$d, src:$p}' >> "$TMP/decisions.jsonl"
    n=$((n+1))
  done < <(for d in $ADR_DIRS; do blobs | grep -E -- "^$d/[^/]+\.(md|mdx)$"; done | sort -u)
  [ "$total" -gt "$MAX_DECISIONS" ] && note_trunc "decisions: $MAX_DECISIONS of $total listed (by path)"
  jq -s . "$TMP/decisions.jsonl" > "$TMP/decisions.json"
}

gen_conventions() {
  local f body bytes left="$MAX_CONVENTION_BYTES" content
  : > "$TMP/conventions.jsonl"
  for f in $CONVENTION_FILES; do
    has_path "$f" || continue
    body="$(blob_cat "$f" 2>/dev/null)"; bytes="$(printf '%s' "$body" | wc -c | tr -d ' ')"
    content=""
    if [ "$left" -gt 0 ]; then
      if [ "$bytes" -le "$left" ]; then content="$body"; left=$((left-bytes))
      else content="$(printf '%s' "$body" | head -c "$left")"; left=0; note_trunc "conventions: $f cut at $MAX_CONVENTION_BYTES bytes total"; fi
    else note_trunc "conventions: $f listed, content omitted (12 kB cap)"; fi
    jq -nc --arg p "$f" --argjson b "$bytes" --arg c "$content" '{path:$p, bytes:$b, content:(if $c=="" then null else $c end), src:$p}' >> "$TMP/conventions.jsonl"
  done
  jq -s . "$TMP/conventions.jsonl" > "$TMP/conventions.json"
}

gen_ownership() {
  local f line pat owners n=0
  : > "$TMP/ownership.jsonl"
  for f in $OWNER_FILES; do
    has_path "$f" || continue
    while IFS= read -r line; do
      case "$line" in (''|\#*) continue;; esac
      [ "$n" -lt "$MAX_OWNERS" ] || { note_trunc "ownership: first $MAX_OWNERS rules of $f listed"; break; }
      pat="$(printf '%s' "$line" | tr -s ' \t' ' ' | cut -d' ' -f1)"
      owners="$(printf '%s' "$line" | tr -s ' \t' ' ' | cut -d' ' -f2- | sed -E 's/[[:space:]]*#.*$//')"
      jq -nc --arg p "$pat" --arg o "$owners" --arg s "$f" '{pattern:$p, owners:$o, src:$s}' >> "$TMP/ownership.jsonl"
      n=$((n+1))
    done < <(blob_cat "$f" 2>/dev/null)
    break
  done
  jq -s . "$TMP/ownership.jsonl" > "$TMP/ownership.json"
}

gen_checks() {
  local w body name on req
  : > "$TMP/checks.jsonl"
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    body="$(blob_cat "$w" 2>/dev/null | head -80)"
    name="$(printf '%s\n' "$body" | sed -nE 's/^name:[[:space:]]*(.*)$/\1/p' | head -1 | unquote)"; [ -n "$name" ] || name="${w##*/}"
    on="$(printf '%s\n' "$body" | sed -nE 's/^(on|"on"):[[:space:]]*(.+)$/\2/p' | head -1 | tr -d '[]"')"
    [ -n "$on" ] || on="$(printf '%s\n' "$body" | sed -nE '/^(on|"on"):[[:space:]]*$/,/^[A-Za-z_"]/p' | sed -nE 's/^  ([A-Za-z_]+):.*$/\1/p' | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
    jq -nc --arg w "${w##*/}" --arg n "$name" --arg o "$on" --arg s "$w" '{workflow:$w, name:$n, on:(if $o=="" then null else $o end), src:$s}' >> "$TMP/checks.jsonl"
  done < <(blobs | grep -E -- "$WORKFLOW_RE" | sort)
  req="$(gh api "repos/$REPO/branches/$BRANCH/protection/required_status_checks" 2>/dev/null | jq -c '[.contexts[]?]' 2>/dev/null)"
  { printf '%s' "$req" | jq -e 'type=="array"' >/dev/null 2>&1; } || req='[]'
  jq -s --argjson r "$req" '{workflows:., required:$r}' "$TMP/checks.jsonl" > "$TMP/checks.json"
}

gen_noise() {
  local line pat cls
  builtin_noise_json | jq -c '.[]' > "$TMP/noise.jsonl"
  if has_path .gitattributes; then
    while IFS= read -r line; do
      case "$line" in (''|\#*) continue;; esac
      cls=""
      case "$line" in
        (*linguist-generated=false*|*-linguist-generated*) ;;
        (*linguist-generated*) cls=generated;;
      esac
      case "$line" in (*linguist-vendored=false*|*-linguist-vendored*) ;; (*linguist-vendored*) cls=vendored;; esac
      [ -n "$cls" ] || continue
      pat="$(printf '%s' "$line" | tr -s ' \t' ' ' | cut -d' ' -f1)"
      case "$pat" in (*/) pat="${pat}**";; esac
      jq -nc --arg g "$pat" --arg c "$cls" '{glob:$g, class:$c, src:".gitattributes"}' >> "$TMP/noise.jsonl"
    done < <(blob_cat .gitattributes 2>/dev/null)
  fi
  jq -s . "$TMP/noise.jsonl" > "$TMP/noise.json"
}

# The agent's own finding history — every posted review's findings-json line,
# aggregated per directory (docs/profile.md → History). Recomputed on every
# check: it is a record of the past, so there is nothing to cache.
history_records() {
  local f n ts line j
  for f in "$WORK"/reviews/pr-*.md; do
    [ -f "$f" ] || continue
    n="${f##*/pr-}"; n="${n%.md}"; ts=""
    while IFS= read -r line; do
      case "$line" in
        ('## Review at '*) ts="$(printf '%s' "$line" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z' | head -1)";;
        (*'<!-- findings-json: '*)
          j="${line#*<!-- findings-json: }"; j="${j%% -->*}"
          printf '%s\n' "$j" | jq -c --arg ts "$ts" --arg n "$n" 'select(type=="array") | {ts:$ts, pr:($n|tonumber? // 0), findings:.}' 2>/dev/null;;
      esac
    done < "$f"
  done
}
gen_history() {
  local since
  since="$(date -u -d "@$((NOW_EPOCH - HISTORY_DAYS*86400))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
           || date -u -r "$((NOW_EPOCH - HISTORY_DAYS*86400))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  history_records | jq -s --arg since "$since" --argjson days "$HISTORY_DAYS" --argjson max "$MAX_HISTORY_ROWS" '
    [ .[] | select(.ts >= $since) ] as $r
    | [ $r[] | .ts as $ts | .pr as $pr | .findings[]? | select(type=="object" and (.file|type)=="string")
        | . + {ts:$ts, pr:$pr, dir:(.file | if contains("/") then (split("/")[:-1] | join("/")) else "." end)} ] as $f
    | { days:$days, since:$since, reviews:($r|length), findings:($f|length),
        fixed:([$f[] | select(.status=="fixed")]|length), still:([$f[] | select(.status=="still")]|length),
        dirs: ([ $f | group_by(.dir)[]
                 | { dir: .[0].dir,
                     critical:([.[] | select(.severity=="critical" and .status!="fixed")]|length),
                     warning:([.[] | select(.severity=="warning" and .status!="fixed")]|length),
                     suggestion:([.[] | select(.severity=="suggestion")]|length),
                     still:([.[] | select(.status=="still")]|length),
                     last:(map(.ts)|max),
                     prs:(map(.pr)|unique|length),
                     samples:([.[] | select(.status!="fixed") | .summary // empty] | unique | .[-3:]) } ]
               | sort_by(-(.critical*3 + .warning*2 + .still)) | .[:$max]),
        classes: ([ $f[] | select(.status!="fixed") | (.summary // "" | ascii_downcase | gsub("[^a-z0-9 ]";"") | gsub("\\s+";" ") | .[0:60]) | select(length>0) ]
                  | group_by(.) | map({summary:.[0], count:length}) | sort_by(-.count) | .[:10]) }' > "$TMP/history.json" 2>/dev/null
  [ -s "$TMP/history.json" ] || printf '{"days":%s,"reviews":0,"findings":0,"fixed":0,"still":0,"dirs":[],"classes":[]}\n' "$HISTORY_DAYS" > "$TMP/history.json"
}

# Agent-owned notes: rows of work/PROFILE-NOTES.md, stamped here with the blob
# of their source path so a later regeneration can mark them stale/orphan.
gen_notes() {
  local row paths note src sha prev status
  : > "$TMP/notes.jsonl"
  if [ -f "$NOTES_MD" ]; then
    while IFS= read -r row; do
      paths="$(trim "$(printf '%s' "$row" | cut -d'|' -f2)")"
      note="$(trim "$(printf '%s' "$row" | cut -d'|' -f3)")"
      src="$(trim "$(printf '%s' "$row" | cut -d'|' -f4)" | tr -d '`')"
      case "$paths" in (''|paths|-*|:*) continue;; esac
      [ -n "$note" ] || continue
      sha=""; [ -n "$src" ] && sha="$(blob_sha "$src")"
      prev=""; [ -f "$PROFILE_JSON" ] && prev="$(jq -r --arg p "$paths" --arg s "$src" '.notes[]? | select(.paths==$p and .src==$s) | .blob // empty' "$PROFILE_JSON" 2>/dev/null | head -1)"
      if [ -z "$src" ]; then status=unanchored
      elif [ -z "$sha" ]; then status=orphan
      elif [ -z "$prev" ]; then status=new
      elif [ "$prev" = "$sha" ]; then status=current
      else status=stale; fi
      jq -nc --arg p "$paths" --arg n "$note" --arg s "$src" --arg b "$sha" --arg st "$status" \
        '{paths:$p, note:($n|.[0:240]), src:(if $s=="" then null else $s end), blob:(if $b=="" then null else $b end), status:$st}' >> "$TMP/notes.jsonl"
    done < <(grep -E '^\|' "$NOTES_MD" 2>/dev/null | grep -vE '^\|[[:space:]:-]*\|')
  fi
  jq -s . "$TMP/notes.jsonl" > "$TMP/notes.json"
}

# ---------------------------------------------------------------- render ----
render_md() { # PROFILE.json → PROFILE.md
  jq -r '
    def esc: tostring | gsub("\\|"; "\\|") | gsub("\n"; " ");
    def row(a): "| " + (a | map(esc) | join(" | ")) + " |";
    def table(h; rows): if (rows|length)==0 then [] else [row(h), row(h | map("---"))] + rows end;
    def section(title; h; rows): if (rows|length)==0 then [] else ["## " + title, ""] + table(h; rows) + [""] end;
    . as $p
    | [ "---", "profile: 1", "repo: \($p.repo)", "default_branch: \($p.default_branch)",
        "base: \($p.default_branch)@\($p.base.sha[0:12]) (\($p.base.ts))",
        "verified: \($p.default_branch)@\($p.verified.sha[0:12]) (\($p.verified.ts))",
        "generated: \($p.generated)", "fingerprint: \($p.fingerprint // "none")",
        "mode: \($p.mode)", "generator: \($p.generator)",
        "truncated: " + (if ($p.truncated|length)==0 then "none" else ($p.truncated|join("; ")) end),
        "---", "",
        "_Project profile of `\($p.repo)` — where things are and what the repository declares about itself (docs/profile.md). Orientation only: findings come from the diff and the clone, never from this file. Rows whose source this PR changes reach the worklist flagged `verify_live`._", "" ]
    + section("Modules (\($p.modules|length))"; ["path","name","kind","workspace","role","src"];
        [$p.modules[] | row([.path,.name,.kind,(if .workspace then "yes" else "-" end),(.role // "-"),.src])])
    + section("Docs (\($p.docs|length))"; ["paths","page","title","stamp","via"];
        [$p.docs[] | row([(if (.paths|length)==0 then "-" else (.paths|join(", ")) end), .page, .title, .stamp, (.via // "-")])])
    + section("Decisions (\($p.decisions|length))"; ["id","title","status","scope","date","src"];
        [$p.decisions[] | row([.id,.title,.status,(.scope // "-"),.date,.src])])
    + (if ($p.conventions|length)==0 then [] else
        ["## Conventions", ""] + [ $p.conventions[] | "### \(.path) (\(.bytes) bytes)", "", (.content // "_(content omitted)_"), "" ] end)
    + section("Ownership (\($p.ownership|length))"; ["pattern","owners","src"]; [$p.ownership[] | row([.pattern,.owners,.src])])
    + (if ($p.checks.workflows|length)==0 then [] else
        ["## Checks (\($p.checks.workflows|length) workflows)", ""] + table(["workflow","name","on"]; [$p.checks.workflows[] | row([.workflow,.name,(.on // "-")])])
        + [""] + (if ($p.checks.required|length)==0 then [] else ["Required status checks: " + ($p.checks.required|join(", ")), ""] end) end)
    + section("Noise (\($p.noise|length) globs — never reviewed as code)"; ["glob","class","src"]; [$p.noise[] | row([.glob,.class,.src])])
    + ["## History (\($p.history.days) d · \($p.history.reviews) reviews · \($p.history.findings) findings · \($p.history.fixed) fixed · \($p.history.still) still open)", ""]
    + (if ($p.history.dirs|length)==0 then ["_No findings recorded in the window._", ""] else
        table(["dir","critical","warning","suggestion","still","last","prs","samples"];
          [$p.history.dirs[] | row([.dir,.critical,.warning,.suggestion,.still,.last,.prs,(.samples|join("; "))])]) + [""] end)
    + (if ($p.history.classes|length)==0 then [] else
        ["### Recurring finding classes", ""] + [ $p.history.classes[] | "- \(.count)× \(.summary)" ] + [""] end)
    + section("Notes (agent-owned — work/PROFILE-NOTES.md)"; ["paths","note","src","status"]; [$p.notes[] | row([.paths,.note,(.src // "-"),.status])])
    | .[]' "$PROFILE_JSON" > "$PROFILE_MD.tmp" 2>/dev/null && mv "$PROFILE_MD.tmp" "$PROFILE_MD"
}

# ------------------------------------------------------------- generation ----
generate() { # tree already loaded; writes PROFILE.json + PROFILE.md
  local fp trunc
  fp="$(fingerprint)"
  gen_modules; detect_doc_dirs; gen_docs; gen_decisions; gen_conventions; gen_ownership; gen_checks; gen_noise; gen_history; gen_notes
  [ "$API_TRUNCATED" -eq 1 ] && { note_trunc "tree listing truncated by the API — fingerprint unavailable, ttl-only refresh"; fp=""; }
  [ -s "$TMP/api_capped" ] && note_trunc "contents cap reached ($MAX_API_READS API reads) — some rows read their source shallowly"
  trunc="$(sort -u "$NOTE_TRUNC" | jq -R . | jq -s .)"
  jq -n --arg repo "$REPO_HOST/$REPO" --arg br "$BRANCH" --arg sha "$REMOTE_SHA" --arg now "$NOW_ISO" \
    --arg fp "$fp" --arg mode "$MODE" --arg gen "$GENERATOR" --argjson trunc "$trunc" \
    --argjson doc_roots "$(printf '%s\n' $DOC_ROOTS | grep -v '^$' | jq -R . | jq -s .)" \
    --argjson adr_dirs "$(printf '%s\n' $ADR_DIRS | grep -v '^$' | jq -R . | jq -s .)" \
    --arg root_re "$ROOT_STRUCT_RE" --arg manifest_re "$MANIFEST_RE" --arg excl_re "$EXCL_RE" --arg wf_re "$WORKFLOW_RE" \
    --slurpfile modules "$TMP/modules.json" --slurpfile docs "$TMP/docs.json" --slurpfile decisions "$TMP/decisions.json" \
    --slurpfile conventions "$TMP/conventions.json" --slurpfile ownership "$TMP/ownership.json" --slurpfile checks "$TMP/checks.json" \
    --slurpfile noise "$TMP/noise.json" --slurpfile history "$TMP/history.json" --slurpfile notes "$TMP/notes.json" '
    {profile:1, repo:$repo, default_branch:$br,
     base:{sha:$sha, ts:$now}, verified:{sha:$sha, ts:$now}, generated:$now,
     fingerprint:(if $fp=="" then null else $fp end), mode:(if $fp=="" then "ttl-only" else $mode end), generator:$gen, truncated:$trunc,
     structure:{root_re:$root_re, manifest_re:$manifest_re, excl_re:$excl_re, workflow_re:$wf_re, doc_roots:$doc_roots, adr_dirs:$adr_dirs},
     modules:$modules[0], docs:$docs[0], decisions:$decisions[0], conventions:$conventions[0],
     ownership:$ownership[0], checks:$checks[0], noise:$noise[0], history:$history[0], notes:$notes[0]}' \
    > "$PROFILE_JSON.tmp" && mv "$PROFILE_JSON.tmp" "$PROFILE_JSON"
  render_md
}

refresh_history() { # verified + history (+ the branch name) only; the structure is unchanged
  gen_history
  jq --arg sha "$REMOTE_SHA" --arg now "$NOW_ISO" --arg br "$BRANCH" --slurpfile h "$TMP/history.json" \
    '.verified = {sha:$sha, ts:$now} | .history = $h[0] | .default_branch = $br' "$PROFILE_JSON" > "$PROFILE_JSON.tmp" 2>/dev/null \
    && mv "$PROFILE_JSON.tmp" "$PROFILE_JSON"
  render_md
}

profile_lock() { # one writer at a time; a lock older than 15 min is a dead run's
  find "$PROFILE_JSON.lock" -maxdepth 0 -mmin +15 -exec rm -rf {} \; 2>/dev/null || true
  mkdir "$PROFILE_JSON.lock" 2>/dev/null
}
profile_unlock() { rmdir "$PROFILE_JSON.lock" 2>/dev/null || true; }

run_check() { # <force>
  local force="$1" stored_fp stored_gen stored_ver stored_ts age_d fp live_branch
  [ "$(cfg project_profile)" = "disabled" ] && emit_status disabled none
  [ -n "$REPO" ] || emit_status unavailable none "target repo unresolved"
  BRANCH="$(default_branch)"
  REMOTE_SHA="$(remote_sha)"
  if [ -z "$REMOTE_SHA" ]; then
    # no tip under the stored branch name: the default branch may have been
    # renamed — re-resolve it from the repository once and retry
    live_branch="$(gh api "repos/$REPO" 2>/dev/null | jq -r '.default_branch // empty' 2>/dev/null)"
    if [ -n "$live_branch" ] && [ "$live_branch" != "$BRANCH" ]; then
      logev info profile "default branch is now $live_branch (profile had $BRANCH)"
      BRANCH="$live_branch"; REMOTE_SHA="$(remote_sha)"
    fi
  fi
  stored_fp=""; stored_gen=""; stored_ver=""; stored_ts=""; age_d=999999
  if [ -f "$PROFILE_JSON" ]; then
    stored_fp="$(jq -r '.fingerprint // empty' "$PROFILE_JSON" 2>/dev/null)"
    stored_gen="$(jq -r '.generator // empty' "$PROFILE_JSON" 2>/dev/null)"
    stored_ver="$(jq -r '.verified.sha // empty' "$PROFILE_JSON" 2>/dev/null)"
    stored_ts="$(jq -r '.generated // empty' "$PROFILE_JSON" 2>/dev/null)"
    [ -n "$stored_ts" ] && age_d=$(( (NOW_EPOCH - $(iso2epoch "$stored_ts")) / 86400 ))
  fi
  if [ -z "$REMOTE_SHA" ]; then
    # git cannot reach the remote — the API decides whether a tree is available
    REMOTE_SHA="$(gh api "repos/$REPO/branches/$BRANCH" 2>/dev/null | jq -r '.commit.sha // empty' 2>/dev/null)"
    if [ -z "$REMOTE_SHA" ]; then
      [ -f "$PROFILE_JSON" ] && emit_status unverified none "remote unreachable — stored profile kept"
      emit_status unavailable none "remote unreachable and no stored profile"
    fi
  fi
  profile_lock || { [ -f "$PROFILE_JSON" ] && emit_status current none "another run is refreshing the profile"; emit_status unavailable none "another run is building the profile"; }
  trap 'profile_unlock; rm -rf "$TMP"' EXIT
  if [ "$force" != force ] && [ -f "$PROFILE_JSON" ] && [ "$stored_gen" = "$GENERATOR" ] && [ -n "$stored_fp" ] \
     && [ "$REMOTE_SHA" = "$stored_ver" ] && [ "$age_d" -lt "$TTL_DAYS" ]; then
    refresh_history
    emit_status current "$(jq -r '.mode' "$PROFILE_JSON")"
  fi
  load_tree || { [ -f "$PROFILE_JSON" ] && emit_status unverified none "tree unavailable (git and API) — stored profile kept"; emit_status unavailable none "tree unavailable (git and API)"; }
  if [ "$force" != force ] && [ -f "$PROFILE_JSON" ] && [ "$stored_gen" = "$GENERATOR" ]; then
    if [ -n "$stored_fp" ] && [ "$API_TRUNCATED" -eq 0 ] && [ "$age_d" -lt "$TTL_DAYS" ]; then
      fp="$(fingerprint)"
      [ "$fp" = "$stored_fp" ] && { refresh_history; emit_status current "$MODE" "structure unchanged at ${REMOTE_SHA:0:12}"; }
    elif [ -z "$stored_fp" ] && [ "$age_d" -lt "$TTL_ONLY_DAYS" ]; then
      refresh_history; emit_status current ttl-only "no fingerprint possible — daily refresh"
    fi
  fi
  generate
  emit_status regenerated "$(jq -r '.mode' "$PROFILE_JSON")" "$(jq -r '"\(.modules|length) modules, \(.docs|length) docs, \(.decisions|length) decisions"' "$PROFILE_JSON")"
}

# ------------------------------------------------------------------ slice ----
# One jq pass: classify the changed files, pick the profile rows they touch,
# flag rows whose source they change, and select the area-memory files whose
# scope globs match (docs/preferences.md → Area-scoped memory).
run_slice() { # <files.json>
  local files="$1" memory
  [ -f "$files" ] || { echo '{"error":"files list missing"}'; exit 0; }
  memory="$( for f in "$WORK"/memory/*.md; do
      [ -f "$f" ] || continue
      fm="$(front_matter "$(head -40 "$f")")"
      scopes="$(fm_list "$fm" scope; fm_list "$fm" paths)"
      [ -n "$scopes" ] || continue
      jq -nc --arg f "work/memory/${f##*/}" --argjson s "$(printf '%s\n' "$scopes" | grep -v '^$' | jq -R . | jq -s .)" '{file:$f, scopes:$s}'
    done | jq -s . )"
  [ -n "$memory" ] || memory='[]'
  local profile
  if [ -f "$PROFILE_JSON" ]; then profile="$PROFILE_JSON"
  else profile="$TMP/empty-profile.json"; jq -n --argjson noise "$(builtin_noise_json)" '{noise:$noise, modules:[], docs:[], decisions:[], conventions:[], ownership:[], checks:{workflows:[],required:[]}, history:{dirs:[]}, structure:{doc_roots:[],adr_dirs:[]}}' > "$profile"; fi
  jq -c --slurpfile p "$profile" --slurpfile files "$files" --argjson memory "$memory" -n '
    def glob2re: [match("\\*\\*/|\\*\\*|\\*|\\?|[^*?]+"; "g") | .string]
      | map(if . == "**/" then "(.*/)?" elif . == "**" then ".*" elif . == "*" then "[^/]*" elif . == "?" then "[^/]"
            else gsub("(?<c>[.+()^$|{}\\[\\]\\\\])"; "\\\(.c)") end) | join("");
    def gmatch($glob): ($glob | ltrimstr("./") | ltrimstr("/")) as $g
      | if ($g | contains("/")) then (test("^" + ($g|glob2re) + "$") or test("^" + ($g|glob2re) + "/"))
        else ((split("/") | last) | test("^" + ($g|glob2re) + "$")) end;
    $p[0] as $p | ($files[0] // []) as $fl
    | [ $fl[] | {path:(.path // .filename), status:(.status // "modified")} | select(.path != null) ] as $files
    | [ $files[].path ] as $paths
    | ($p.noise // []) as $noise
    | ($p.structure // {}) as $st
    | def classify: . as $f | (split("/") | last) as $b
        | ([ $noise[] | .glob as $g | select($f | gmatch($g)) | .class ] | first) //
          (if ($f | test("(^|/)(test|tests|__tests__|spec|specs|e2e|testdata|fixtures)/")) or ($b | test("\\.(test|spec)\\.[A-Za-z0-9]+$|_test\\.go$|^test_.*\\.py$|Tests?\\.(java|cs|kt|swift)$")) then "test"
           elif ($f | test("\\.(md|mdx|rst|adoc|txt)$")) or any(($st.doc_roots // [])[]; . as $d | $f | startswith($d + "/")) then "docs"
           elif ($b | test("^(package\\.json|go\\.mod|Cargo\\.toml|pyproject\\.toml|setup\\.cfg|pom\\.xml|build\\.gradle(\\.kts)?|composer\\.json|Gemfile|Makefile|Dockerfile|\\..*|.*\\.(ya?ml|toml|ini|cfg|env|properties|conf))$")) or ($f | test("^\\.github/")) then "config"
           else "code" end);
      def struct: . as $f
        | (($st.root_re // null) != null and ($f | test($st.root_re)))
          or (($st.manifest_re // null) != null and ($f | test($st.manifest_re)) and (($f | test($st.excl_re // "^$")) | not))
          or (($st.workflow_re // null) != null and ($f | test($st.workflow_re)))
          or any(($st.doc_roots // [])[]; . as $d | $f | startswith($d + "/"))
          or any(($st.adr_dirs // [])[]; . as $d | $f | startswith($d + "/"));
      def touches($dir): $dir == "." or any($paths[]; startswith($dir + "/"));
      def live($src): $src != null and ($paths | index($src) != null);
      def row($section; $text; $src): {section:$section, row:$text, verify_live:live($src)};
    { files: [ $files[] | . + {class:(.path | classify)} ],
      noise_count: ([ $files[] | select((.path | classify) | IN("lockfile","snapshot","build","vendored","minified","sourcemap","generated")) ] | length),
      structure_changed: [ $paths[] | select(struct) ],
      profile_slice:
        ( [ ($p.modules // [])[] | select(touches(.path)) | row("modules"; "\(.path) — \(.name) [\(.kind)\(if .workspace then ", workspace" else "" end)]\(if .role then ": " + .role else "" end)"; .src) ]
        + [ ($p.docs // [])[] | select(any(.paths[]?; . as $g | any($paths[]; gmatch($g))) or live(.src))
            | row("docs"; "\(if (.paths|length)==0 then "-" else (.paths|join(", ")) end) → \(.page) — \(.title) (stamp \(.stamp), via \(.via // "-"))"; .src) ]
        + [ ($p.decisions // [])[] | . as $d
            | select(live(.src) or (($d.scope // "") | ascii_downcase) as $sc | $sc != "" and any(($p.modules // [])[] | select(touches(.path)) | (.name|ascii_downcase), (.path|split("/")|last|ascii_downcase); . as $n | $n != "" and ($sc | contains($n))))
            | row("decisions"; "ADR \(.id) — \(.title) [\(.status)]\(if .scope then " scope: " + .scope else "" end) (\(.src))"; .src) ]
        + [ ($p.conventions // [])[] | select(live(.src)) | row("conventions"; "\(.path) changed in this PR (\(.bytes) bytes)"; .src) ]
        + [ ($p.ownership // [])[] | .pattern as $g | select(any($paths[]; gmatch($g))) | row("ownership"; "\(.pattern) → \(.owners)"; .src) ]
        + (if any($paths[]; test("^\\.github/workflows/")) then [ ($p.checks.workflows // [])[] | row("checks"; "\(.workflow) — \(.name)\(if .on then " on " + .on else "" end)"; .src) ] else [] end)
        ),
      history_slice: [ ($p.history.dirs // [])[] | select(touches(.dir) or (.dir as $d | any($paths[]; (split("/")[:-1] | join("/")) == $d))) ],
      memory_due: [ $memory[] | select(any(.scopes[]; . as $g | any($paths[]; gmatch($g)))) | .file ] }'
}

# ------------------------------------------------------------------- main ----
case "$CMD" in
  (check)    run_check keep;;
  (generate) run_check force;;
  (slice)    run_slice "${2:-}";;
  (*) printf 'usage: %s check | generate | slice <files.json>\n' "$0" >&2; exit 2;;
esac
