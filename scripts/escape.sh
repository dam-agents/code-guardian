#!/usr/bin/env bash
# escape.sh — the mechanical half of learning from an escaped defect
# (docs/escapes.md): an error a running environment showed after merge.
#
# The agent decides the introducing PR, the review state and the defect class;
# this script gives leads and keeps the ledger. It never judges.
#
#   leads  <work-dir> [--at <sha>] <path[:line]>…
#                                  blame each stack frame (≤ 5) in a blobless
#                                  clone at <sha> (default: the default branch)
#                                  and map the commits to their PRs — leads only
#   seen   <work-dir> <key>        the newest ledger row with this key, if any
#   record <work-dir> <row-file>   validate one row (docs/escapes.md → **The
#                                  ledger**), stamp `at`, append it
#   stats  <work-dir> [--days N]   the audit's counts over the last N days (7),
#                                  and the review findings that named a class
#
# Every subcommand prints one JSON object with `outcome` and exits 0.
# Files: work/ESCAPES.jsonl (append-only), $TMPDIR/cg-escape.* (leads clone,
# removed on exit). Requires bash, git, jq, gh (leads only) — awk-free.
# Overrides (tests): CG_ESCAPE_CLONE_URL.

set -u
export LC_ALL=C

CMD="${1:-}"; shift 2>/dev/null || true
case "$CMD" in (leads|seen|record|stats) ;;
  (*) printf 'usage: %s leads|seen|record|stats <work-dir> …\n' "$0" >&2; exit 2;; esac

WORK="${1:-}"; shift 2>/dev/null || true
[ -n "$WORK" ] && [ -d "$WORK" ] || { printf '{"outcome":"error","error":"work dir missing"}\n'; exit 0; }

CONFIG="$WORK/CONFIG.md"
LEDGER="$WORK/ESCAPES.jsonl"
MAX_FRAMES=5
MAX_COMMITS=15

out()  { printf '%s\n' "$1"; exit 0; }
fail() { out "$(jq -nc --arg e "$1" --arg c "$CMD" '{outcome:"error", step:$c, error:$e}')"; }

. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

# the ledger as one array; a partial line a concurrent writer left is skipped
rows() { [ -f "$LEDGER" ] || { printf '[]'; return; }; jq -Rsc '[split("\n")[] | fromjson? | select(type == "object")]' < "$LEDGER"; }

# -------------------------------------------------------------------- seen --
if [ "$CMD" = "seen" ]; then
  KEY="${1:-}"; [ -n "$KEY" ] || fail "no key given"
  out "$(rows | jq -c --arg k "$KEY" '[.[] | select(.key == $k)] | last
    | if . == null then {outcome:"new"} else {outcome:"seen", row:.} end')"
fi

# ------------------------------------------------------------------ record --
if [ "$CMD" = "record" ]; then
  F="${1:-}"; [ -f "$F" ] || fail "row file missing"
  ROW="$(jq -c '. + {pr:(.pr // null), class:(.class // null), recurrence:(.recurrence // false), paths:(.paths // [])}' "$F" 2>/dev/null)" \
    || fail "row is not a JSON object"
  ERR="$(printf '%s' "$ROW" | jq -r '
    def str: type == "string" and length > 0;
    [ (if (.key | str) then empty else "key" end),
      (if (.env | str) then empty else "env" end),
      (if (.source | str) then empty else "source" end),
      (if .pr == null or (.pr | type == "number") then empty else "pr" end),
      (if (.confidence | IN("confirmed","likely","unknown","not_code")) then empty else "confidence" end),
      (if (.review | IN("raised","weak","missed","not_reviewed","not_visible","unknown")) then empty else "review" end),
      (if .class == null or ((.class | str) and (.class | length) <= 80) then empty else "class" end),
      (if (.rule | IN("added","strengthened","none")) then empty else "rule" end),
      (if (.recurrence | type == "boolean") then empty else "recurrence" end),
      (if ((.paths | type == "array") and all(.paths[]; str)) then empty else "paths" end),
      (if .rule != "none" and .class == null then "class (a rule needs its class)" else empty end)
    ] | join(", ")' 2>/dev/null)"
  [ -z "$ERR" ] || fail "invalid field(s): $ERR"
  NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  LINE="$(printf '%s' "$ROW" | jq -c --arg t "$NOW" '. + {at:$t}')"
  append() { printf '%s\n' "$LINE" >> "$LEDGER"; }
  with_state_lock "$LEDGER" append || fail "append failed"
  out "$(jq -nc --argjson r "$LINE" '{outcome:"recorded", row:$r}')"
fi

# ------------------------------------------------------------------- stats --
if [ "$CMD" = "stats" ]; then
  DAYS=7; [ "${1:-}" = "--days" ] && DAYS="${2:-7}"
  case "$DAYS" in (''|*[!0-9]*) fail "--days needs a number";; esac
  SINCE="$(date -u -d "@$(( $(date +%s) - DAYS * 86400 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || date -u -r "$(( $(date +%s) - DAYS * 86400 ))" +%Y-%m-%dT%H:%M:%SZ)"
  # review hits: every posted finding that names its class (findings-json
  # `escape`, docs/review-mechanics.md), the review time from its heading
  HITS="$(for f in "$WORK"/reviews/pr-*.md; do
      [ -f "$f" ] || continue; ts=""
      while IFS= read -r line; do
        case "$line" in
          ('## Review at '*) ts="$(printf '%s' "$line" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z' | head -1)";;
          (*'<!-- findings-json: '*)
            j="${line#*<!-- findings-json: }"; j="${j%% -->*}"
            printf '%s\n' "$j" | jq -c --arg ts "$ts" 'select(type == "array") | .[]
              | select(type == "object" and (.escape | type) == "string" and .status == "new")
              | {class:.escape, ts:$ts}' 2>/dev/null;;
        esac
      done < "$f"
    done | jq -sc --arg s "$SINCE" 'group_by(.class) | map({class:.[0].class, n:length,
      week:([.[] | select(.ts >= $s)] | length)}) | sort_by(-.n)')"
  [ -n "$HITS" ] || HITS='[]'
  out "$(rows | jq -c --arg s "$SINCE" --argjson hits "$HITS" '
    def count_by(f): group_by(f) | map({key: (.[0] | f | tostring), value: length}) | from_entries;
    . as $all | [.[] | select(.at >= $s)] as $w
    | {outcome:"ok", since:$s, reports:($w | length), total:($all | length),
       by_review:($w | count_by(.review)), by_confidence:($w | count_by(.confidence)),
       rules:{added:([$w[] | select(.rule == "added")] | length),
              strengthened:([$w[] | select(.rule == "strengthened")] | length)},
       recurrences:[$w[] | select(.recurrence) | {class, pr, at}],
       not_reviewed:[$w[] | select(.review == "not_reviewed") | .pr],
       hits:$hits,
       classes:([$all[] | select(.class != null)] | group_by(.class)
         | map({class: .[0].class, n: length, week: ([.[] | select(.at >= $s)] | length),
                last: (map(.at) | max)})
         | sort_by(-.n, .last) | .[:10])}')"
fi

# ------------------------------------------------------------------- leads --
AT=""
if [ "${1:-}" = "--at" ]; then AT="${2:-}"; shift 2 2>/dev/null || shift; fi
[ "$#" -gt 0 ] || fail "no stack frame given"
TARGET_REF="$(cfg github_repo)"
REPO_HOST="$(refhost "$TARGET_REF")"; REPO="$(refslug "$TARGET_REF")"
export GH_HOST="$REPO_HOST"

CLONE="$(mktemp -d "${TMPDIR:-/tmp}/cg-escape.XXXXXX")" || fail "no temp dir"
trap 'rm -rf "$CLONE"' EXIT
url="${CG_ESCAPE_CLONE_URL:-}"
if [ -z "$url" ]; then
  [ -n "$REPO" ] || fail "no target repo resolved"
  url="https://$REPO_HOST/$REPO.git"
  tok="$(gh auth token --hostname "$REPO_HOST" 2>/dev/null || true)"
  [ -n "$tok" ] && url="https://x-access-token:$tok@$REPO_HOST/$REPO.git"
fi
# blobless: blame fetches only the blobs of the frames' history
git clone -q --filter=blob:none --no-checkout "$url" "$CLONE/repo" 2>/dev/null \
  || fail "clone failed for $REPO"
git -C "$CLONE/repo" remote set-url origin "https://$REPO_HOST/$REPO.git" 2>/dev/null || true
G() { git -C "$CLONE/repo" "$@"; }
if [ -z "$AT" ]; then AT="$(G rev-parse HEAD 2>/dev/null)"
else
  G cat-file -e "$AT^{commit}" 2>/dev/null || G fetch -q origin "$AT" 2>/dev/null \
    || fail "commit $AT not found in $REPO"
  AT="$(G rev-parse "$AT^{commit}" 2>/dev/null)"
fi

FRAMES='[]'; COMMITS=""; n=0
DROPPED=$(( $# > MAX_FRAMES ? $# - MAX_FRAMES : 0 ))
for fr in "$@"; do
  n=$((n + 1)); [ "$n" -le "$MAX_FRAMES" ] || break
  path="${fr%:*}"; line="${fr##*:}"
  case "$line" in (''|*[!0-9]*) path="$fr"; line="";; esac
  path="${path#./}"
  if ! G cat-file -e "$AT:$path" 2>/dev/null; then
    FRAMES="$(printf '%s' "$FRAMES" | jq -c --arg f "$fr" '. + [{frame:$f, error:"path not in the tree at that commit"}]')"
    continue
  fi
  blame=""
  [ -n "$line" ] && blame="$(G blame --porcelain -L "$line,$line" "$AT" -- "$path" 2>/dev/null | head -1 | cut -d' ' -f1)"
  recent="$(G log -n 3 --format=%H "$AT" -- "$path" 2>/dev/null | tr '\n' ' ')"
  FRAMES="$(printf '%s' "$FRAMES" | jq -c --arg f "$fr" --arg p "$path" --arg l "$line" --arg b "$blame" --arg r "$recent" \
    '. + [{frame:$f, path:$p, line:(if $l == "" then null else ($l|tonumber) end),
           blame:(if $b == "" then null else $b end),
           recent:($r | split(" ") | map(select(length > 0)))}]')"
  COMMITS="$COMMITS $blame $recent"
done

# commit → PRs, each distinct commit once, blame lines first
PRS='{}'; k=0; done_c=" "; LOOKUP_FAILED=0
for c in $COMMITS; do
  case "$c" in (*[!0-9a-f]*|0000000000000000000000000000000000000000) continue;; esac
  [ "${#c}" -eq 40 ] || continue
  case "$done_c" in (*" $c "*) continue;; esac
  done_c="$done_c$c "
  k=$((k + 1)); [ "$k" -le "$MAX_COMMITS" ] || break
  # a failed lookup is `prs: null` with an error, never an empty list
  if body="$(gh_get "repos/$REPO/commits/$c/pulls")" && printf '%s' "$body" | jq -e 'type == "array"' >/dev/null 2>&1; then :
  else body='null'; LOOKUP_FAILED=$((LOOKUP_FAILED + 1)); fi
  subj="$(G log -1 --format='%s%x09%aI' "$c" 2>/dev/null)"
  PRS="$(printf '%s' "$body" | jq -c --argjson acc "$PRS" --arg c "$c" --arg s "$subj" '
    $acc + {($c): ({summary:($s | split("\t")[0]), authored:($s | split("\t")[1] // null)}
      + if . == null then {prs:null, error:"PR lookup failed"}
        else {prs:[.[] | select(.merged_at != null) | {number, title, merged_at, url:.html_url}]} end)}' 2>/dev/null)" \
    || fail "PR mapping failed for $c"
done

out "$(jq -nc --arg at "$AT" --argjson f "$FRAMES" --argjson p "$PRS" \
  --argjson d "$DROPPED" --argjson lf "$LOOKUP_FAILED" --argjson mc "$k" --argjson max "$MAX_COMMITS" '
  ($f | map(. + (if .blame then {blame_pr:($p[.blame].prs // null)} else {} end))) as $frames
  | {outcome:"ready", at:$at, frames:$frames, commits:$p,
     frames_dropped:$d, lookups_failed:$lf, commits_capped:($mc > $max),
     candidates:([$frames[] | (.blame // empty), (.recent // [])[]] as $cs
       | [$cs[] | ($p[.].prs // [])[]] | group_by(.number)
       | map(.[0] + {hits:length}) | sort_by(.hits, .merged_at) | reverse | .[:5])}')"
