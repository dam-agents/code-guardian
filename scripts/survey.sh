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

. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

TARGET_REF="$(cfg github_repo)"
REPO_HOST="$(refhost "$TARGET_REF")"; REPO="$(refslug "$TARGET_REF")"

mkdir -p "$SDIR" 2>/dev/null || true

# the ledger row of an area: | slug | path | last_surveyed | passes | findings |
ledger_row() { grep -E "^\| *$1 *\|" "$LEDGER" 2>/dev/null | head -1; }

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
  SHA="$(git -C "$CLONE" rev-parse HEAD 2>/dev/null || true)"

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
  out "$(jq -nc --arg s "$SLUG" --arg p "$path" --arg root "$CLONE" --arg sha "$SHA" \
    --argjson f "$FILES_JSON" --argjson n "$n" --argjson l "$lines" \
    --argjson rem "$REMAINDER" --argjson mf "$MAX_FILES" --argjson ml "$MAX_LINES" \
    '{outcome:"ready", slug:$s, path:$p, root:$root, sha:$sha, files:$f,
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

  # the commit the pass read and the files it covered, while the clone is still here
  CLONE="$TMP_ROOT/survey-$SLUG"
  SHA="$(git -C "$CLONE" rev-parse HEAD 2>/dev/null || true)"
  nfiles="$(grep -c '' "$TMP_ROOT/survey-$SLUG.keep" 2>/dev/null || printf 0)"

  F="$SDIR/$SLUG.md"
  [ -f "$F" ] || printf '# Survey — %s\n' "$path" > "$F"
  { printf '\n## Pass %s — %s — %s 🔴 · %s 🟡 · %s 🟢\n\n' "$passes" "$NOW_ISO" "$c" "$w" "$s"
    jq -r '.[] | "- \(.severity // "suggestion") — \(.summary // "?") (`\(.file // "?"):\(.line // "?")`)"
                 + (if .fix then "\n  **Fix:** \(.fix)" else "" end)' "$FINDINGS"
    printf '\n<!-- findings-json: %s -->\n' "$(jq -c . "$FINDINGS" | sed 's/--/–/g')"
    printf '<!-- pass-json: %s -->\n' "$(jq -nc --arg sha "$SHA" --argjson n "$nfiles" '{sha:$sha, files:$n}')"
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
  # the findings themselves reach the page only on the recorded opt-in
  # (docs/config.md → survey_report_findings); the index is always there
  SHOW="$(cfg survey_report_findings)"; [ "$SHOW" = "enabled" ] || SHOW="disabled"
  BASE="https://$REPO_HOST/$REPO"

  # every recorded pass, parsed from the per-area files: the heading carries
  # the counts, the two comment lines the findings and the commit it read.
  # Passes recorded before pass-json existed have no sha and link to HEAD.
  pass_json() { # <slug> <pass> <ts> <c> <w> <s> <findings-json> <pass-json>
    local f="$7" m="$8"
    printf '%s' "$f" | jq -e 'type == "array"'  >/dev/null 2>&1 || f="[]"
    printf '%s' "$m" | jq -e 'type == "object"' >/dev/null 2>&1 || m="{}"
    jq -nc --arg slug "$1" --arg p "$2" --arg ts "$3" \
      --argjson c "${4:-0}" --argjson w "${5:-0}" --argjson s "${6:-0}" \
      --argjson f "$f" --argjson m "$m" \
      '{slug:$slug, pass:$p, ts:$ts, critical:$c, warning:$w, suggestion:$s,
        sha:($m.sha // ""), files:($m.files // null), findings:$f}' 2>/dev/null
  }
  PASSES="$(for f in "$SDIR"/*.md; do
      [ -f "$f" ] || continue
      case "${f##*/}" in (LEDGER.md) continue;; esac
      slug="${f##*/}"; slug="${slug%.md}"
      p=""; ts=""; c=0; w=0; s=0; fj="[]"; pj="{}"
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
          ("## Pass "*)
            [ -n "$p" ] && pass_json "$slug" "$p" "$ts" "$c" "$w" "$s" "$fj" "$pj"
            set -- $(printf '%s' "$line" \
              | sed -E 's/^## Pass ([0-9]+) — ([^ ]+) — ([0-9]+) [^ ]+ · ([0-9]+) [^ ]+ · ([0-9]+) .*$/\1 \2 \3 \4 \5/')
            p="${1:-}"; ts="${2:-}"; c="${3:-0}"; w="${4:-0}"; s="${5:-0}"; fj="[]"; pj="{}"
            case "$p" in (''|*[!0-9]*) p="";; esac;;
          ("<!-- findings-json: "*) fj="${line#<!-- findings-json: }"; fj="${fj% -->}";;
          ("<!-- pass-json: "*)     pj="${line#<!-- pass-json: }";     pj="${pj% -->}";;
        esac
      done < "$f"
      [ -n "$p" ] && pass_json "$slug" "$p" "$ts" "$c" "$w" "$s" "$fj" "$pj"
    done | jq -sc 'sort_by(.ts) | reverse')"
  PASSES="${PASSES:-[]}"

  # the index: one row per area, severity counts of its newest pass
  TABLE="$(jq -nr --argjson rows "$ROWS" --argjson passes "$PASSES" --arg show "$SHOW" '
    $rows[] | . as $r | ([$passes[] | select(.slug == $r.slug)] | first) as $np
    | (if $show == "enabled" then "<a href=\"#\($r.slug|@html)\">\($r.path|@html)</a>" else ($r.path|@html) end) as $area
    | (if $np then [$np.critical, $np.warning, $np.suggestion] | map(tostring) else ["–","–","–"] end) as $n
    | "<tr><td>\($area)</td><td class=\"n\">\($r.passes|@html)</td><td class=\"n\">\($n[0])</td><td class=\"n\">\($n[1])</td><td class=\"n\">\($n[2])</td><td>\($r.last|@html)</td></tr>"')"

  if [ "$SHOW" = "enabled" ]; then
    NOTE="Each code location links to the commit the pass read."
    SECTIONS="$(jq -nr --argjson rows "$ROWS" --argjson passes "$PASSES" --arg base "$BASE" '
      def loc: . as $f | ($f.file // "") as $file | ($f.line // "") as $line
        | (if ($f.ref // "") == "" then "HEAD" else $f.ref end) as $ref
        | if $file == "" or $file == "?" then ""
          else "<a class=\"loc\" href=\"\($base)/blob/\($ref)/\($file|@uri|gsub("%2F"; "/"))"
               + (if ($line|tostring|test("^[0-9]+$")) then "#L\($line)" else "" end)
               + "\"><code>\($file|@html)" + (if ($line|tostring|test("^[0-9]+$")) then ":\($line)" else "" end) + "</code></a>" end;
      def sev: (.severity // "suggestion") | if IN("critical","warning","suggestion") then . else "suggestion" end;
      def finding($ref): . + {ref:$ref} | "<li><span class=\"sev \(sev)\">\(sev)</span>\(.summary // "?"|@html)\(loc)"
        + (if (.fix // "") != "" then "<span class=\"fix\"><b>Fix:</b> \(.fix|@html)</span>" else "" end) + "</li>";
      def pass: . as $p
        | "<h3>Pass \($p.pass|@html) <span class=\"pass\">— \($p.ts|@html) — \($p.critical) 🔴 · \($p.warning) 🟡 · \($p.suggestion) 🟢"
        + (if $p.files then " — \($p.files) files" else "" end)
        + (if $p.sha != "" then " at <a class=\"sha\" href=\"\($base)/tree/\($p.sha|@html)\">\($p.sha[0:7]|@html)</a>" else "" end)
        + "</span></h3>"
        + (if ($p.findings|length) == 0 then "<p class=\"meta\">No finding.</p>"
           else "<ul class=\"f\">" + ([$p.findings[] | finding($p.sha)] | join("")) + "</ul>" end);
      $rows[] | . as $r | [$passes[] | select(.slug == $r.slug)] as $ps
      | select(($ps|length) > 0)
      | "<h2 id=\"\($r.slug|@html)\">\($r.path|@html)</h2>" + ([$ps[] | pass] | join("\n"))')"
  else
    NOTE="Findings live in <code>work/survey/</code>; this page is the index."
    RECENT="$(printf '%s' "$PASSES" | jq -r '.[0:20][] |
      "<tr><td>\(.ts|@html)</td><td>\(.slug|@html)</td><td class=\"n\">pass \(.pass|@html)</td></tr>"')"
    SECTIONS="$(printf '<h2>Recent passes</h2>\n<table><thead><tr><th>when</th><th>area</th><th>pass</th></tr></thead>\n<tbody>\n%s\n</tbody></table>' "$RECENT")"
  fi
  BOT_H="$(printf '%s' "$BOT" | jq -Rr '@html')"

  cat <<EOF2
<!doctype html><meta charset="utf-8"><title>$BOT_H — codebase survey</title>
<style>
body{font:14px/1.5 system-ui,-apple-system,Segoe UI,Roboto,sans-serif;margin:2rem auto;max-width:60rem;padding:0 1rem;color:#1a1a1a;background:#fff}
h1{font-size:1.4rem;margin:0 0 .25rem}h2{font-size:1.05rem;margin:2rem 0 .5rem}h3{font-size:.95rem;margin:1.25rem 0 .4rem;font-weight:600}
.meta{color:#555;font-size:.85rem}table{border-collapse:collapse;width:100%;font-size:.9rem}
th,td{border-bottom:1px solid #e3e3e3;padding:.4rem .5rem;text-align:left}
th{background:#fafafa;font-weight:600}td.n{text-align:right;font-variant-numeric:tabular-nums}
a{color:#0b5fd1;text-decoration:none}a:hover{text-decoration:underline}
code{font:.85em ui-monospace,SFMono-Regular,Menlo,monospace;background:#f3f3f3;padding:.05rem .3rem;border-radius:3px}
ul.f{list-style:none;padding:0;margin:0}ul.f li{padding:.5rem 0;border-bottom:1px solid #eee}
.sev{display:inline-block;min-width:5.5rem;font-size:.75rem;font-weight:600;letter-spacing:.02em;text-transform:uppercase}
.sev.critical{color:#b3261e}.sev.warning{color:#9a6700}.sev.suggestion{color:#1a7f37}
.fix{display:block;margin:.2rem 0 0 5.9rem;color:#444;font-size:.88rem}.fix b{font-weight:600}
.loc{margin-left:.4rem;white-space:nowrap}.pass{color:#555;font-size:.85rem;font-weight:400}
.sha{font:.8em ui-monospace,Menlo,monospace}
@media(prefers-color-scheme:dark){body{background:#151515;color:#e8e8e8}a{color:#6fb1ff}
th{background:#1f1f1f}th,td{border-color:#2c2c2c}ul.f li{border-color:#2c2c2c}.meta,.pass{color:#9a9a9a}.fix{color:#c8c8c8}
code{background:#242424}.sev.critical{color:#ff7b72}.sev.warning{color:#e3b341}.sev.suggestion{color:#56d364}}
</style>
<h1>Codebase survey</h1>
<p class="meta">One area of the repository read in depth per run, newest first.
A survey reports what a diff cannot show — unreachable code, duplicated logic,
untested paths, drift from the repository's own conventions and decisions.
$NOTE Semantics: docs/survey.md. Generated $NOW_ISO.</p>
<h2>Areas</h2>
<table><thead><tr><th>area</th><th>passes</th><th>🔴</th><th>🟡</th><th>🟢</th><th>last pass</th></tr></thead>
<tbody>
$TABLE
</tbody></table>
$SECTIONS
EOF2
  exit 0
fi
