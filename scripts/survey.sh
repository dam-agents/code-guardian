#!/usr/bin/env bash
# survey.sh — the mechanical half of one codebase survey (docs/survey.md).
#
# The agent decides what a survey finds; this script performs the steps around
# that decision. It never judges a file, drops a finding, or chooses an area —
# preflight chooses the area, the agent reads the files this script lists.
#
#   prepare <work-dir> <slug>            clone the default branch, list the
#                                        area's reviewable files under the caps
#   record  <work-dir> <slug> <findings> append the pass to the area's file and
#                                        update the ledger row
#   report  <work-dir>                   the accumulated HTML, on stdout
#
# Every subcommand prints one JSON object with `outcome` and exits 0, except
# `report`, which prints the page. Files: $TMPDIR/survey-<slug> (clone),
# work/survey/<slug>.md (state), work/survey/LEDGER.md (index + publish ids).
# Requires bash, git, jq, gh (prepare only), sed/grep/sort — awk-free.
# Overrides (tests): CG_SURVEY_CLONE_URL.

set -u
export LC_ALL=C

CMD="${1:-}"; shift 2>/dev/null || true
case "$CMD" in (prepare|record|report) ;;
  (*) printf 'usage: %s prepare|record|report <work-dir> …\n' "$0" >&2; exit 2;; esac

WORK="${1:-}"; shift 2>/dev/null || true
[ -n "$WORK" ] && [ -d "$WORK" ] || { printf '{"outcome":"error","error":"work dir missing"}\n'; exit 0; }

CONFIG="$WORK/CONFIG.md"
SDIR="$WORK/survey"
LEDGER="$SDIR/LEDGER.md"
PROFILE="$WORK/PROFILE.json"
TMP_ROOT="${TMPDIR:-/tmp}"
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

MAX_FILES=40      # the cost bound of one pass (docs/survey.md → Bounds)
MAX_LINES=6000

out()  { printf '%s\n' "$1"; exit 0; }
fail() { out "$(jq -nc --arg e "$1" --arg c "$CMD" '{outcome:"error", step:$c, error:$e}')"; }

cfg() { sed -n "s/^- $1:[[:space:]]*//p" "$CONFIG" 2>/dev/null | head -1 \
        | sed -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//' \
              -e 's/^[`"'"'"']//' -e 's/[`"'"'"']$//'; }
refhost() { case "$1" in (*/*/*) printf '%s' "${1%%/*}";; (*) printf '%s' "${GH_HOST:-github.com}";; esac; }
refslug() { case "$1" in (*/*/*) printf '%s' "${1#*/}";;  (*) printf '%s' "$1";; esac; }

TARGET_REF="$(cfg github_repo)"
REPO_HOST="$(refhost "$TARGET_REF")"; REPO="$(refslug "$TARGET_REF")"

mkdir -p "$SDIR" 2>/dev/null || true

# the ledger row of an area: | slug | path | last_surveyed | passes | findings |
ledger_row() { grep -E "^\| *$1 *\|" "$LEDGER" 2>/dev/null | head -1; }
row_field()  { printf '%s' "$1" | cut -d'|' -f"$2" | sed -e 's/^ *//' -e 's/ *$//'; }

# slug -> path: the ledger row first, then the profile that named the area. The
# two always agree, because the slug IS the path with its separators flattened.
area_path() { # <slug>
  local row p
  row="$(ledger_row "$1")"
  p="$(row_field "$row" 3)"
  case "$p" in (''|'-') p="";; esac
  [ -n "$p" ] || p="$(jq -r --arg s "$1" \
    '[(.modules // [])[] | .path] | map(select((. | gsub("[^A-Za-z0-9._-]"; "_")) == $s)) | first // empty' \
    "$PROFILE" 2>/dev/null)"
  printf '%s' "$p"
}

ledger_init() {
  [ -f "$LEDGER" ] && return 0
  { printf '# Codebase survey ledger\n\n'
    printf '_Maintained by scripts/survey.sh (docs/survey.md). One row per area; the passes themselves live in `<slug>.md`._\n\n'
    printf '| area | path | last_surveyed | passes | findings |\n'
    printf '|------|------|---------------|--------|----------|\n'
  } > "$LEDGER" 2>/dev/null || true
}

# ------------------------------------------------------------------ prepare --
if [ "$CMD" = "prepare" ]; then
  SLUG="${1:-}"; [ -n "$SLUG" ] || fail "no area slug given"
  ledger_init
  path="$(area_path "$SLUG")"
  [ -n "$path" ] || fail "area '$SLUG' is in neither the ledger nor the profile"

  CLONE="$TMP_ROOT/survey-$SLUG"
  rm -rf "$CLONE" 2>/dev/null
  url="${CG_SURVEY_CLONE_URL:-}"
  if [ -z "$url" ]; then
    [ -n "$REPO" ] || fail "no target repo resolved"
    url="https://$REPO_HOST/$REPO.git"
    # the credential the clone needs is the one gh already holds
    tok="$(gh auth token --hostname "$REPO_HOST" 2>/dev/null || true)"
    [ -n "$tok" ] && url="https://x-access-token:$tok@$REPO_HOST/$REPO.git"
  fi
  git clone -q --depth 1 --single-branch "$url" "$CLONE" 2>/dev/null \
    || fail "clone failed for $REPO"
  # the token never stays on disk in a remote a later command could print
  git -C "$CLONE" remote set-url origin "https://$REPO_HOST/$REPO.git" 2>/dev/null || true

  AREA="$CLONE/$path"
  [ -d "$AREA" ] || out "$(jq -nc --arg s "$SLUG" --arg p "$path" \
    '{outcome:"empty", slug:$s, path:$p, reason:"the area is not in the default branch any more"}')"

  # The profile's noise globs decide what is not code; a missing profile falls
  # back to the built-in extensions below, never to "review everything".
  NOISE_RE="$(jq -r '[(.noise // [])[] | .glob
                      | gsub("\\*\\*/"; "") | gsub("/\\*\\*"; "") | gsub("\\*"; "")
                      | select(length > 0)] | unique | join("|")' "$PROFILE" 2>/dev/null)"

  LIST="$TMP_ROOT/survey-$SLUG.files"
  : > "$LIST"
  # sorted, so the same area yields the same pass on every run
  while IFS= read -r f; do
    rel="${f#$CLONE/}"
    case "$rel" in (*/.git/*|.git/*) continue;; esac
    if [ -n "$NOISE_RE" ] && printf '%s' "$rel" | grep -qE "$NOISE_RE"; then continue; fi
    case "$rel" in
      (*.lock|*.min.js|*.map|*.snap|*.png|*.jpg|*.gif|*.svg|*.ico|*.pdf|*.zip|*.gz) continue;;
    esac
    printf '%s\n' "$rel" >> "$LIST"
  done < <(find "$AREA" -type f 2>/dev/null | sort)

  total="$(grep -c '' "$LIST" 2>/dev/null || printf 0)"
  [ "$total" -gt 0 ] || out "$(jq -nc --arg s "$SLUG" --arg p "$path" \
    '{outcome:"empty", slug:$s, path:$p, reason:"no reviewable file in the area"}')"

  # fill the pass up to both caps — whichever binds first stops it
  KEEP="$TMP_ROOT/survey-$SLUG.keep"; : > "$KEEP"
  n=0; lines=0
  while IFS= read -r rel; do
    [ "$n" -lt "$MAX_FILES" ] || break
    l="$(grep -c '' "$CLONE/$rel" 2>/dev/null || printf 0)"
    [ "$lines" -gt 0 ] && [ $((lines + l)) -gt "$MAX_LINES" ] && break
    printf '%s\n' "$rel" >> "$KEEP"
    n=$((n + 1)); lines=$((lines + l))
  done < "$LIST"

  FILES_JSON="$(jq -R . < "$KEEP" | jq -sc .)"
  REMAINDER=$((total - n))
  out "$(jq -nc --arg s "$SLUG" --arg p "$path" --arg root "$CLONE" \
    --argjson f "$FILES_JSON" --argjson n "$n" --argjson l "$lines" \
    --argjson rem "$REMAINDER" --argjson mf "$MAX_FILES" --argjson ml "$MAX_LINES" \
    '{outcome:"ready", slug:$s, path:$p, root:$root, files:$f,
      counted:{files:$n, lines:$l}, caps:{files:$mf, lines:$ml},
      truncated:($rem > 0), remainder:$rem}')"
fi

# ------------------------------------------------------------------- record --
if [ "$CMD" = "record" ]; then
  SLUG="${1:-}"; FINDINGS="${2:-}"
  [ -n "$SLUG" ] || fail "no area slug given"
  [ -n "$FINDINGS" ] && [ -f "$FINDINGS" ] || fail "findings file missing"
  jq -e 'type == "array"' "$FINDINGS" >/dev/null 2>&1 || fail "findings must be a JSON array"
  ledger_init
  row="$(ledger_row "$SLUG")"
  path="$(area_path "$SLUG")"; [ -n "$path" ] || path="$SLUG"
  passes="$(row_field "$row" 5)"; case "$passes" in (''|*[!0-9]*) passes=0;; esac
  passes=$((passes + 1))

  c="$(jq '[.[] | select(.severity == "critical")] | length' "$FINDINGS")"
  w="$(jq '[.[] | select(.severity == "warning")] | length' "$FINDINGS")"
  s="$(jq '[.[] | select(.severity == "suggestion")] | length' "$FINDINGS")"
  total=$((c + w + s))

  F="$SDIR/$SLUG.md"
  [ -f "$F" ] || printf '# Survey — %s\n' "$path" > "$F"
  { printf '\n## Pass %s — %s — %s 🔴 · %s 🟡 · %s 🟢\n\n' "$passes" "$NOW_ISO" "$c" "$w" "$s"
    jq -r '.[] | "- \(.severity // "suggestion") — \(.summary // "?") (`\(.file // "?"):\(.line // "?")`)"
                 + (if .fix then "\n  **Fix:** \(.fix)" else "" end)' "$FINDINGS"
    printf '\n<!-- findings-json: %s -->\n' "$(jq -c . "$FINDINGS" | sed 's/--/–/g')"
  } >> "$F" 2>/dev/null || fail "could not append the pass to $F"

  # rewrite the row in place (rows are full of `|`, so sed gets another delimiter)
  new="| $SLUG | $path | $NOW_ISO | $passes | $total |"
  if [ -n "$row" ]; then
    sed -E "s#^\| *$SLUG \|.*#$new#" "$LEDGER" > "$LEDGER.tmp" 2>/dev/null && mv "$LEDGER.tmp" "$LEDGER"
  else
    printf '%s\n' "$new" >> "$LEDGER"
  fi
  rm -rf "$TMP_ROOT/survey-$SLUG" "$TMP_ROOT/survey-$SLUG.files" "$TMP_ROOT/survey-$SLUG.keep" 2>/dev/null
  out "$(jq -nc --arg s "$SLUG" --argjson p "$passes" --argjson c "$c" --argjson w "$w" --argjson g "$s" \
    '{outcome:"recorded", slug:$s, pass:$p, counts:{critical:$c, warning:$w, suggestion:$g}}')"
fi

# ------------------------------------------------------------------- report --
if [ "$CMD" = "report" ]; then
  ROWS="$(grep -E '^\| *[A-Za-z0-9_.-]+ *\|' "$LEDGER" 2>/dev/null \
    | grep -vE '^\| *(area|-+) *\|' \
    | while IFS='|' read -r _ slug path last passes findings _rest; do
        jq -nc --arg s "$(printf '%s' "$slug" | sed -e 's/^ *//' -e 's/ *$//')" \
               --arg p "$(printf '%s' "$path" | sed -e 's/^ *//' -e 's/ *$//')" \
               --arg l "$(printf '%s' "$last" | sed -e 's/^ *//' -e 's/ *$//')" \
               --arg n "$(printf '%s' "$passes" | sed -e 's/^ *//' -e 's/ *$//')" \
               --arg f "$(printf '%s' "$findings" | sed -e 's/^ *//' -e 's/ *$//')" \
               '{slug:$s, path:$p, last:$l, passes:$n, findings:$f}'
      done | jq -sc 'sort_by(.last) | reverse')"
  ROWS="${ROWS:-[]}"
  BOT="$(cfg bot_display_name)"; BOT="${BOT:-Code Guardian}"

  # every recorded pass, newest first, from the per-area files
  PASSES="$(for f in "$SDIR"/*.md; do
      [ -f "$f" ] || continue
      case "${f##*/}" in (LEDGER.md) continue;; esac
      slug="${f##*/}"; slug="${slug%.md}"
      sed -n 's/^## Pass \([0-9]*\) — \([^ ]*\) — .*/\1\t\2/p' "$f" 2>/dev/null \
        | while IFS="$(printf '\t')" read -r p ts; do
            jq -nc --arg s "$slug" --arg p "$p" --arg ts "$ts" '{slug:$s, pass:$p, ts:$ts}'
          done
    done | jq -sc 'sort_by(.ts) | reverse | .[0:20]')"
  PASSES="${PASSES:-[]}"

  TABLE="$(printf '%s' "$ROWS" | jq -r '.[] |
    "<tr><td>\(.path)</td><td class=\"n\">\(.passes)</td><td class=\"n\">\(.findings)</td><td>\(.last)</td></tr>"')"
  RECENT="$(printf '%s' "$PASSES" | jq -r '.[] |
    "<tr><td>\(.ts)</td><td>\(.slug)</td><td class=\"n\">pass \(.pass)</td></tr>"')"

  cat <<EOF
<!doctype html><meta charset="utf-8"><title>$BOT — codebase survey</title>
<style>
body{font:14px/1.5 system-ui,-apple-system,Segoe UI,Roboto,sans-serif;margin:2rem auto;max-width:60rem;padding:0 1rem;color:#1a1a1a}
h1{font-size:1.4rem;margin:0 0 .25rem}h2{font-size:1.05rem;margin:2rem 0 .5rem}
.meta{color:#555;font-size:.85rem}table{border-collapse:collapse;width:100%;font-size:.9rem}
th,td{border-bottom:1px solid #e3e3e3;padding:.4rem .5rem;text-align:left}
th{background:#fafafa;font-weight:600}td.n{text-align:right;font-variant-numeric:tabular-nums}
@media(prefers-color-scheme:dark){body{background:#151515;color:#e8e8e8}
th{background:#1f1f1f}th,td{border-color:#2c2c2c}.meta{color:#9a9a9a}}
</style>
<h1>Codebase survey</h1>
<p class="meta">One area of the repository read in depth per run, newest first.
A survey reports what a diff cannot show — unreachable code, duplicated logic,
untested paths, drift from the repository's own conventions and decisions.
Findings live in <code>work/survey/</code>; this page is the index.
Semantics: docs/survey.md. Generated $NOW_ISO.</p>
<h2>Areas</h2>
<table><thead><tr><th>area</th><th>passes</th><th>findings</th><th>last pass</th></tr></thead>
<tbody>
$TABLE
</tbody></table>
<h2>Recent passes</h2>
<table><thead><tr><th>when</th><th>area</th><th>pass</th></tr></thead>
<tbody>
$RECENT
</tbody></table>
EOF
  exit 0
fi
