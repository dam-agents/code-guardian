#!/usr/bin/env bash
# survey.sh — the mechanical half of one codebase survey (docs/survey.md).
#
# The agent decides what a survey finds; this script performs the steps around
# that decision. It never judges a file, drops a finding, or chooses an area —
# preflight proposes the area, this script the files under the caps, and the
# agent may read past both and records why.
#
#   prepare <work-dir> <slug>            clone the default branch, list the
#                                        area's reviewable files under the caps,
#                                        after the file the last pass stopped at
#   record  <work-dir> <slug> <findings> [--last <path>] [--past <reason>]
#                                        append the pass to the area's file and
#                                        update the ledger row; --last moves the
#                                        resume point to the last area file the
#                                        agent read, --past records why the pass
#                                        went past the listed files or the area
#   report  <work-dir>                   the accumulated HTML, on stdout
#
# Every subcommand prints one JSON object with `outcome` and exits 0, except
# `report`, which prints the page with its credential shapes masked, or exits 1
# with no page when the mask did not run. Files: $TMPDIR/survey-<slug> (clone),
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
# lines of a file, 0 when empty or unreadable (`grep -c` prints 0 and exits 1
# on an empty file)
nlines() { local n; n="$(grep -c '' "$1" 2>/dev/null)"; printf '%s' "${n:-0}"; }

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
  rm -rf "$CLONE" "$TMP_ROOT/survey-$SLUG.keep" 2>/dev/null   # a crashed pass leaves no stale list
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

  total="$(nlines "$LIST")"
  [ "$total" -gt 0 ] || out "$(jq -nc --arg s "$SLUG" --arg p "$path" \
    '{outcome:"empty", slug:$s, path:$p, reason:"no reviewable file in the area"}')"

  # Resume after the file the last pass stopped at (its pass-json `last`). The
  # list is sorted, so "after" is a byte-order comparison and survives files
  # added or removed since; with no file after it, the cycle starts again.
  AFTER="$(marker_payload pass-json < "$SDIR/$SLUG.md" 2>/dev/null | jq -r '.last // empty' 2>/dev/null)"
  PASS_LIST="$TMP_ROOT/survey-$SLUG.pass"; : > "$PASS_LIST"
  if [ -n "$AFTER" ]; then
    while IFS= read -r rel; do [[ "$rel" > "$AFTER" ]] && printf '%s\n' "$rel"; done < "$LIST" > "$PASS_LIST"
  fi
  if [ -s "$PASS_LIST" ]; then mv "$PASS_LIST" "$LIST"; else AFTER=""; rm -f "$PASS_LIST"; fi
  left="$(nlines "$LIST")"

  # fill the pass up to both caps — whichever binds first stops it
  KEEP="$TMP_ROOT/survey-$SLUG.keep"; : > "$KEEP"
  n=0; lines=0
  while IFS= read -r rel; do
    [ "$n" -lt "$MAX_FILES" ] || break
    l="$(nlines "$CLONE/$rel")"
    [ "$lines" -gt 0 ] && [ $((lines + l)) -gt "$MAX_LINES" ] && break
    printf '%s\n' "$rel" >> "$KEEP"
    n=$((n + 1)); lines=$((lines + l))
  done < "$LIST"

  FILES_JSON="$(jq -R . < "$KEEP" | jq -sc .)"
  REMAINDER=$((left - n))
  out "$(jq -nc --arg s "$SLUG" --arg p "$path" --arg root "$CLONE" --arg sha "$SHA" \
    --argjson f "$FILES_JSON" --argjson n "$n" --argjson l "$lines" --arg after "$AFTER" \
    --argjson rem "$REMAINDER" --argjson mf "$MAX_FILES" --argjson ml "$MAX_LINES" \
    '{outcome:"ready", slug:$s, path:$p, root:$root, sha:$sha, files:$f,
      after:(if $after == "" then null else $after end),
      counted:{files:$n, lines:$l}, caps:{files:$mf, lines:$ml},
      truncated:($rem > 0), remainder:$rem}')"
fi

# ------------------------------------------------------------------- record --
if [ "$CMD" = "record" ]; then
  SLUG="${1:-}"; FINDINGS="${2:-}"; LAST=""; PAST=""
  shift 2 2>/dev/null || shift $#
  while [ $# -gt 0 ]; do case "$1" in
    (--last) LAST="${2:-}"; shift 2 2>/dev/null || shift;;
    (--past) PAST="${2:-}"; shift 2 2>/dev/null || shift;;
    (*) fail "unknown record argument '$1'";; esac; done
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

  # the commit the pass read, the files it covered and the last of them (where
  # the next pass resumes), while the clone is still here
  CLONE="$TMP_ROOT/survey-$SLUG"
  SHA="$(git -C "$CLONE" rev-parse HEAD 2>/dev/null || true)"
  KEEP="$TMP_ROOT/survey-$SLUG.keep"
  if [ -n "$LAST" ]; then
    # the pass covers the area list up to the file the agent read last
    grep -qxF -- "$LAST" "$TMP_ROOT/survey-$SLUG.files" 2>/dev/null \
      || fail "--last $LAST is not a file of this pass's area list"
    while IFS= read -r rel; do printf '%s\n' "$rel"; [ "$rel" = "$LAST" ] && break; done \
      < "$TMP_ROOT/survey-$SLUG.files" > "$KEEP.tmp" && mv "$KEEP.tmp" "$KEEP"
  fi
  nfiles="$(nlines "$KEEP")"
  last="$(tail -n 1 "$KEEP" 2>/dev/null)"

  F="$SDIR/$SLUG.md"
  [ -f "$F" ] || printf '# Survey — %s\n' "$path" > "$F"
  { printf '\n## Pass %s — %s — %s 🔴 · %s 🟡 · %s 🟢\n\n' "$passes" "$NOW_ISO" "$c" "$w" "$s"
    jq -r '.[] | "- \(.severity // "suggestion") — "
                 + ([.category, .cwe] | map(select(. != null and . != "") | tostring)
                    | if length > 0 then "[\(join(" · "))] " else "" end)
                 + "\(.summary // "?") (`\(.file // "?"):\(.line // "?")`)"
                 + (if .fix then "\n  **Fix:** \(.fix)" else "" end)' "$FINDINGS"
    # the second hyphen of each double hyphen goes in as the JSON escape \u002d:
    # no `-->` ends the comment early, and jq reads it back as a hyphen
    printf '\n<!-- findings-json: %s -->\n' "$(jq -c . "$FINDINGS" | sed 's/--/-\\u002d/g')"
    printf '<!-- pass-json: %s -->\n' "$(jq -nc --arg sha "$SHA" --argjson n "$nfiles" --arg last "$last" --arg past "$PAST" \
      '{sha:$sha, files:$n, last:(if $last == "" then null else $last end)} + (if $past == "" then {} else {past:$past} end)' | sed 's/--/-\\u002d/g')"
  } >> "$F" 2>/dev/null || fail "could not append the pass to $F"

  # rewrite the row in place (rows are full of `|`, so sed gets another delimiter)
  new="| $SLUG | $path | $NOW_ISO | $passes | $total |"
  if [ -n "$row" ]; then
    sed -E "s#^\| *$SLUG *\|.*#$new#" "$LEDGER" > "$LEDGER.tmp" 2>/dev/null && mv "$LEDGER.tmp" "$LEDGER"
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
        jq -nc --arg s "$(trim "$slug")" --arg p "$(trim "$path")" --arg l "$(trim "$last")" \
               --arg n "$(trim "$passes")" --arg f "$(trim "$findings")" \
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
  # The findings and the history go to jq on stdin: one argv entry stops at
  # 128 KiB (MAX_ARG_STRLEN), and the history grows with every pass.
  pass_json() { # <slug> <pass> <ts> <c> <w> <s> <findings-json> <pass-json>
    local f="$7" m="$8"
    printf '%s' "$f" | jq -e 'type == "array"'  >/dev/null 2>&1 || f="[]"
    printf '%s' "$m" | jq -e 'type == "object"' >/dev/null 2>&1 || m="{}"
    printf '%s' "$f" | jq -c --arg slug "$1" --arg p "$2" --arg ts "$3" \
      --argjson c "${4:-0}" --argjson w "${5:-0}" --argjson s "${6:-0}" \
      --argjson m "$m" \
      '{slug:$slug, pass:$p, ts:$ts, critical:$c, warning:$w, suggestion:$s,
        sha:($m.sha // ""), files:($m.files // null), findings:.}' 2>/dev/null
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

  # the newest pass of each area in the ledger: the tiles and the index read
  # these counts, so an area reads as its last pass, never as its history
  NEWEST="$(printf '%s' "$PASSES" | jq -c --argjson rows "$ROWS" '
    . as $passes | [$rows[] | . as $r | ([$passes[] | select(.slug == $r.slug)] | first)
                   | select(. != null)]')"
  TILES="$(printf '%s' "$NEWEST" | jq -r --argjson rows "$ROWS" '
    def tile($cls; $n; $label): "<div class=\"tile \($cls)\"><b>\($n)</b><span>\($label)</span></div>";
    ([.[].critical] | add // 0) as $c | ([.[].warning] | add // 0) as $w
    | ([$rows[].last] | map(select(test("^[0-9]"))) | max // "") as $last
    | tile(if $c > 0 then "critical" else "" end; $c; "critical, newest passes")
      + tile(if $w > 0 then "warning" else "" end; $w; "warning, newest passes")
      + tile(""; ($rows|length); "areas surveyed")
      + tile(""; (if $last == "" then "–" else $last[0:10] end); "last pass")')"

  # the index: one row per area, severity counts of its newest pass
  TABLE="$(printf '%s' "$PASSES" | jq -r --argjson rows "$ROWS" --arg show "$SHOW" '
    def count($n; $cls): if $n == "–" then "<td class=\"n\">–</td>"
      elif $n == "0" then "<td class=\"n zero\">0</td>"
      else "<td class=\"n\"><span class=\"badge \($cls)\">\($n)</span></td>" end;
    . as $passes | $rows[] | . as $r | ([$passes[] | select(.slug == $r.slug)] | first) as $np
    | (if $show == "enabled" then "<a href=\"#\($r.slug|@html)\">\($r.path|@html)</a>" else ($r.path|@html) end) as $area
    | (if $np then [$np.critical, $np.warning] | map(tostring) else ["–","–"] end) as $n
    | "<tr><td class=\"area\">\($area)</td><td class=\"n\">\($r.passes|@html)</td>\(count($n[0]; "critical"))\(count($n[1]; "warning"))<td class=\"when\" title=\"\($r.last|@html)\">\($r.last[0:10]|@html)</td></tr>"')"

  if [ "$SHOW" = "enabled" ]; then
    NOTE="Each code location links to the commit the pass read; a pass with no recorded commit links to the default branch."
    SECTIONS="$(printf '%s' "$PASSES" | jq -r --argjson rows "$ROWS" --arg base "$BASE" '
      def loc: . as $f | ($f.file // "") as $file | ($f.line // "") as $line
        | (if ($f.ref // "") == "" then "HEAD" else $f.ref end) as $ref
        | if $file == "" or $file == "?" then ""
          else "<a class=\"loc\" href=\"\($base)/blob/\($ref)/\($file|@uri|gsub("%2F"; "/"))"
               + (if ($line|tostring|test("^[0-9]+$")) then "#L\($line)" else "" end)
               + "\"><code>\($file|@html)" + (if ($line|tostring|test("^[0-9]+$")) then ":\($line)" else "" end) + "</code></a>" end;
      def sev: (.severity // "suggestion") | if IN("critical","warning","suggestion") then . else "suggestion" end;
      def rank: {critical:0, warning:1, suggestion:2}[sev];
      def tags: [(.category // empty | tostring | select(. != "")), (.cwe // empty | tostring | select(. != ""))]
        | if length == 0 then "" else "<span class=\"tags\">" + (map("<span class=\"tag\">\(.|@html)</span>") | join("")) + "</span>" end;
      def finding($ref): . + {ref:$ref} | "<li class=\"\(sev)\"><div class=\"head\"><span class=\"sev \(sev)\">\(sev)</span>\(tags)\(loc)</div>"
        + "<p class=\"sum\">\(.summary // "?"|@html)</p>"
        + (if (.fix // "") != "" then "<p class=\"fix\"><b>Fix:</b> \(.fix|@html)</p>" else "" end) + "</li>";
      def counts: "\(.critical) 🔴 · \(.warning) 🟡" + (if .suggestion > 0 then " · \(.suggestion) 🟢" else "" end);
      def meta: . as $p | "\($p.ts[0:10]|@html) — \($p|counts)"
        + (if $p.files then " — \($p.files) files" else "" end)
        + (if $p.sha != "" then " at <a class=\"sha\" href=\"\($base)/tree/\($p.sha|@html)\">\($p.sha[0:7]|@html)</a>" else "" end);
      def body: if (.findings|length) == 0 then "<p class=\"clean\">No finding in this pass.</p>"
        else "<ul class=\"f\">" + ([.findings | sort_by(rank)[] | finding(.ref // "")] | join("")) + "</ul>" end;
      def withref: . as $p | .findings |= map(. + {ref:$p.sha});
      def pass($open): (. | withref) as $p
        | if $open then "<h3>Pass \($p.pass|@html) <span class=\"pass\">\($p|meta)</span></h3>" + ($p|body)
          else "<details><summary>Pass \($p.pass|@html) <span class=\"pass\">\($p|meta)</span></summary>" + ($p|body) + "</details>" end;
      . as $passes | $rows[] | . as $r | [$passes[] | select(.slug == $r.slug)] as $ps
      | select(($ps|length) > 0)
      | "<section class=\"area-card\" id=\"\($r.slug|@html)\"><h2>\($r.path|@html)</h2>"
        + ($ps[0] | pass(true))
        + (if ($ps|length) > 1 then "<div class=\"older\"><p class=\"label\">Earlier passes</p>" + ([$ps[1:][] | pass(false)] | join("")) + "</div>" else "" end)
        + "</section>"')"
  else
    NOTE="Findings live in <code>work/survey/</code>; this page is the index."
    RECENT="$(printf '%s' "$PASSES" | jq -r '.[0:20][] |
      "<tr><td class=\"when\" title=\"\(.ts|@html)\">\(.ts[0:10]|@html)</td><td class=\"area\">\(.slug|@html)</td><td class=\"n\">pass \(.pass|@html)</td></tr>"')"
    SECTIONS="$(printf '<h2>Recent passes</h2>\n<div class="scroll"><table><thead><tr><th>when</th><th>area</th><th class="n">pass</th></tr></thead>\n<tbody>\n%s\n</tbody></table></div>' "$RECENT")"
  fi
  BOT_H="$(printf '%s' "$BOT" | jq -Rr '@html')"

  # The page is public: lib/redact.sh masks every credential shape in it
  # before it is printed (runbook.md → Hard invariants). A mask that did not
  # run prints no page and exits 1.
  . "$(cd "$(dirname "$0")" && pwd)/lib/redact.sh"
  PAGE="$(mktemp "$TMP_ROOT/survey.page.XXXXXX" 2>/dev/null)" \
    || { printf 'survey.sh report: no temp file, so no page\n' >&2; exit 1; }
  cat > "$PAGE" <<EOF2
<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Security codebase survey</title>
<style>
:root{--bg:#f6f7f9;--surface:#fff;--text:#1a1d21;--muted:#5d6570;--line:#e3e6ea;--link:#0b5fd1;--code:#f0f2f5;
--crit:#b3261e;--crit-bg:#fdecea;--warn:#8a5a00;--warn-bg:#fff4d6;--sugg:#1a7f37;--sugg-bg:#e6f4ea;--ok:#1a7f37}
@media(prefers-color-scheme:dark){:root:not([data-theme="light"]){--bg:#111316;--surface:#1a1d21;--text:#e6e8eb;--muted:#9aa3ad;--line:#2b3036;
--link:#6fb1ff;--code:#252a30;--crit:#ff8a80;--crit-bg:#3a1d1b;--warn:#f0c454;--warn-bg:#382d12;--sugg:#6ad38a;--sugg-bg:#163222;--ok:#6ad38a}}
:root[data-theme="dark"]{--bg:#111316;--surface:#1a1d21;--text:#e6e8eb;--muted:#9aa3ad;--line:#2b3036;
--link:#6fb1ff;--code:#252a30;--crit:#ff8a80;--crit-bg:#3a1d1b;--warn:#f0c454;--warn-bg:#382d12;--sugg:#6ad38a;--sugg-bg:#163222;--ok:#6ad38a}
*{box-sizing:border-box}
body{font:15px/1.55 system-ui,-apple-system,Segoe UI,Roboto,sans-serif;margin:0;padding:2rem 16px 3rem;color:var(--text);background:var(--bg)}
main{max-width:60rem;margin:0 auto}
h1{font-size:1.5rem;margin:0 0 .35rem}h2{font-size:1.1rem;margin:2.25rem 0 .75rem}
h3{font-size:.95rem;margin:0 0 .6rem;font-weight:600}
.intro{color:var(--muted);margin:0 0 1.5rem;max-width:44rem}.meta{color:var(--muted);font-size:.82rem}
a{color:var(--link);text-decoration:none}a:hover{text-decoration:underline}
code{font:.85em ui-monospace,SFMono-Regular,Menlo,monospace;background:var(--code);padding:.08rem .35rem;border-radius:4px;overflow-wrap:anywhere}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(9.5rem,1fr));gap:.75rem;margin:0 0 .5rem}
.tile{background:var(--surface);border:1px solid var(--line);border-radius:10px;padding:.8rem 1rem}
.tile b{display:block;font-size:1.6rem;line-height:1.2;font-variant-numeric:tabular-nums}
.tile span{color:var(--muted);font-size:.8rem}
.tile.critical{border-color:var(--crit);background:var(--crit-bg)}.tile.critical b{color:var(--crit)}
.tile.warning{border-color:var(--warn);background:var(--warn-bg)}.tile.warning b{color:var(--warn)}
.scroll{overflow-x:auto;background:var(--surface);border:1px solid var(--line);border-radius:10px}
table{border-collapse:collapse;width:100%;font-size:.9rem}
th,td{border-bottom:1px solid var(--line);padding:.55rem .75rem;text-align:left}
tr:last-child td{border-bottom:0}th{color:var(--muted);font-weight:600;font-size:.78rem;text-transform:uppercase;letter-spacing:.03em}
.n{text-align:right;font-variant-numeric:tabular-nums}td.zero{color:var(--muted)}td.when{color:var(--muted);white-space:nowrap}
td.area{overflow-wrap:anywhere}
.badge{display:inline-block;min-width:1.6rem;padding:.05rem .45rem;border-radius:999px;font-weight:600;text-align:center}
.badge.critical{color:var(--crit);background:var(--crit-bg)}.badge.warning{color:var(--warn);background:var(--warn-bg)}
.area-card{background:var(--surface);border:1px solid var(--line);border-radius:10px;padding:1rem 1.1rem;margin:1rem 0}
.area-card h2{margin:0 0 .75rem;font-size:1.05rem;overflow-wrap:anywhere}
.pass{color:var(--muted);font-size:.82rem;font-weight:400}
ul.f{list-style:none;padding:0;margin:0;display:grid;gap:.6rem}
ul.f li{border:1px solid var(--line);border-left:4px solid var(--line);border-radius:8px;padding:.6rem .8rem}
ul.f li.critical{border-left-color:var(--crit)}ul.f li.warning{border-left-color:var(--warn)}ul.f li.suggestion{border-left-color:var(--sugg)}
.head{display:flex;flex-wrap:wrap;align-items:center;gap:.4rem .6rem}
.sev{font-size:.7rem;font-weight:700;letter-spacing:.05em;text-transform:uppercase;padding:.1rem .5rem;border-radius:999px}
.sev.critical{color:var(--crit);background:var(--crit-bg)}.sev.warning{color:var(--warn);background:var(--warn-bg)}
.sev.suggestion{color:var(--sugg);background:var(--sugg-bg)}
.tags{display:inline-flex;flex-wrap:wrap;gap:.3rem}.tag{font-size:.72rem;color:var(--muted);border:1px solid var(--line);border-radius:4px;padding:0 .35rem}
.loc{margin-left:auto}.sum{margin:.4rem 0 0}.fix{margin:.3rem 0 0;color:var(--muted);font-size:.9rem}.fix b{color:var(--text)}
.clean{color:var(--ok);margin:0}.sha{font:.85em ui-monospace,Menlo,monospace}
.older{margin-top:1rem;border-top:1px dashed var(--line);padding-top:.6rem}.older .label{color:var(--muted);font-size:.78rem;text-transform:uppercase;letter-spacing:.03em;margin:0 0 .3rem}
details{margin:.3rem 0}summary{cursor:pointer;font-size:.9rem;padding:.25rem 0}details[open] summary{margin-bottom:.5rem}
@media(max-width:560px){.loc{margin-left:0;flex-basis:100%}th,td{padding:.5rem}}
</style>
<main>
<h1>Security codebase survey</h1>
<p class="intro">Each run reads one area of the repository as it stands and reports only what is dangerous:
security holes, data loss and reachable failures that a diff review cannot see. $NOTE</p>
<div class="tiles">
$TILES
</div>
<h2>Areas</h2>
<div class="scroll"><table><thead><tr><th>area</th><th class="n">passes</th><th class="n">🔴</th><th class="n">🟡</th><th>last pass</th></tr></thead>
<tbody>
$TABLE
</tbody></table></div>
$SECTIONS
<p class="meta">$BOT_H · semantics: docs/survey.md · generated $NOW_ISO</p>
</main>
EOF2
  if [ $? -eq 0 ] && redact_file "$PAGE" >/dev/null; then
    cat "$PAGE"; rm -f "$PAGE" 2>/dev/null; exit 0
  fi
  rm -f "$PAGE" 2>/dev/null
  printf 'survey.sh report: the page did not pass lib/redact.sh, so no page\n' >&2
  exit 1
fi
