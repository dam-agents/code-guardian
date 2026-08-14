#!/usr/bin/env bash
# benchmark-validate.sh — deterministic gates for the benchmark
# (docs/benchmark.md). Read-only; prints `ok`/`FAIL <id> — <detail>; fix: …`
# lines and exits non-zero when any check fails.
#
#   benchmark-validate.sh fixture <fixture-dir>...   # before a set is used
#   benchmark-validate.sh results <results.json>     # before results are kept
#
# Why this is a script and not a doc rule: both failures it catches are
# invisible at run time. A fixture that names its own defects still scores
# (the scorer reads findings-json and the manifest, never the code), and a
# results file with a drifted shape still renders — the numbers are simply
# wrong, permanently, because the results history is append-only.
#
# fixture mode — the trees, diffs, and prior review are Phase-1 inputs the
# reviewing session reads, so ground truth may live in manifest.json ONLY:
#   leak_ids        no defect ids (D01/D1, DEFECT-1, BUG-2 …) outside the manifest
#   leak_words      no answer-key vocabulary (seeded/intentional/bait/
#                   false positive/on purpose/seeded defect/seeded bug …)
#   leak_fixmarks   no v2 delta giveaways (`FIXED`, `still present`, `unfixed`)
#   diff_paths      diff hunks are repo-relative (no base/ | head-v1/ | head-v2/
#                   prefixes — `git diff --no-index` adds them and every
#                   finding then fails to match the manifest)
#   structure       base/ head-v1/ head-v2/ manifest.json prior-review.md
#                   pr.json diff-v1.patch diff-v1-v2.patch all present
#   manifest        parses; every defect has id/file/class/severity and a
#                   line_v1 or line_v2; fixed defects carry fix_line_v2
#
# results mode — the shape the report and the monthly gate consume:
#   json            parses as an object
#   fields          ts / trigger / model / definition_version present
#   trigger         one of scheduled | manual | trial
#   fixtures_shape  fixtures is an OBJECT keyed by slug, never an array
#                   (an array renders its sections as 0,1,2… and breaks the
#                   index submode)
#   per_fixture     each slug has first + rereview; seconds numeric; tokens
#                   is null or carries all five counters
#   judge_key       the run-level judge field is `judge` (not benchmark_judge)
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$SCRIPT_DIR/lib/toolpath.sh" ] && . "$SCRIPT_DIR/lib/toolpath.sh" 2>/dev/null

RC=0
ok()   { printf 'ok   %s: %s\n' "$1" "$2"; }
fail() { printf 'FAIL %s: %s\n' "$1" "$2"; RC=1; }

# defect-id shapes a generating session reaches for, plus answer-key words.
# Deliberately narrow: they must not fire on ordinary code (`D1` alone is not
# matched — it needs the id-like context of a comment marker or two digits).
ID_RE='\b(D[0-9]{2}|DEFECT[-_ ]?[0-9]+|BUG[-_ ]?[0-9]+)\b'
WORD_RE='seeded|intentionally|intentional|on purpose|false.positive|answer key|ground truth|bait'
FIXMARK_RE='\b(FIXED|still present|still-present|unfixed|not fixed)\b'

validate_fixture() { # <dir>
  # slug on its own line: in a single `local`, later RHS cannot see earlier
  # assignments reliably, which silently emptied the slug in check ids
  local d f miss="" hits n slug
  d="${1%/}"; slug="${d##*/}"
  [ -d "$d" ] || { fail "structure[$slug]" "not a directory"; return; }
  # the documented invocation globs fixture/*/, which also matches the
  # retired-fixtures container — it is not a fixture and holds no manifest
  [ "$slug" = "retired" ] && { printf 'skip retired/: container of retired fixtures, not validated\n'; return; }

  # ---- structure
  for f in base head-v1 head-v2; do [ -d "$d/$f" ] || miss="$miss $f/"; done
  for f in manifest.json prior-review.md pr.json diff-v1.patch diff-v1-v2.patch; do
    [ -f "$d/$f" ] || miss="$miss $f"
  done
  if [ -n "$miss" ]; then
    fail "structure[$slug]" "missing:$miss; fix: create them per docs/benchmark.md → Creating the fixture set"
  else
    ok "structure[$slug]" "all fixture parts present"
  fi

  # ---- leakage, over everything the reviewing session reads
  local inputs="" p
  for p in "$d/base" "$d/head-v1" "$d/head-v2"; do [ -d "$p" ] && inputs="$inputs $p"; done
  for p in "$d/diff-v1.patch" "$d/diff-v1-v2.patch" "$d/prior-review.md"; do
    [ -f "$p" ] && inputs="$inputs $p"
  done

  if [ -n "${inputs// /}" ]; then
    hits="$(grep -rEIl "$ID_RE" $inputs 2>/dev/null | head -4 | sed "s|^$d/||" | tr "\\n" " ")"
    if [ -n "${hits// /}" ]; then
      n="$(grep -rEIh "$ID_RE" $inputs 2>/dev/null | grep -c '')"
      fail "leak_ids[$slug]" "$n line(s) name defect ids in Phase-1 inputs (${hits}…); fix: ids belong in manifest.json only — rewrite the code without them"
    else
      ok "leak_ids[$slug]" "no defect ids outside the manifest"
    fi

    hits="$(grep -rEIl "$WORD_RE" $inputs 2>/dev/null | head -4 | sed "s|^$d/||" | tr "\\n" " ")"
    if [ -n "${hits// /}" ]; then
      fail "leak_words[$slug]" "answer-key vocabulary in Phase-1 inputs (${hits}…); fix: the code must read as ordinary code — no seeded/bait/intentional notes"
    else
      ok "leak_words[$slug]" "no answer-key vocabulary"
    fi

    hits="$(grep -rEIl "$FIXMARK_RE" "$d/head-v2" "$d/diff-v1-v2.patch" 2>/dev/null | head -4 | sed "s|^$d/||" | tr "\\n" " ")"
    if [ -n "${hits// /}" ]; then
      fail "leak_fixmarks[$slug]" "v2 inputs announce the delta (${hits}…); fix: remove FIXED / still-present notes — the re-review must derive the delta itself"
    else
      ok "leak_fixmarks[$slug]" "v2 delta not announced in the inputs"
    fi
  fi

  # ---- diff paths must be repo-relative
  hits="$(grep -hE '^(\+\+\+|---) [ab]/(base|head-v1|head-v2)/' \
            "$d/diff-v1.patch" "$d/diff-v1-v2.patch" 2>/dev/null | head -2 | tr '\n' ' ')"
  if [ -n "${hits// /}" ]; then
    fail "diff_paths[$slug]" "hunk paths carry tree prefixes ($hits); fix: regenerate from a scratch git repo (docs/benchmark.md step 6) — prefixed paths never match the manifest"
  else
    ok "diff_paths[$slug]" "diff paths are repo-relative"
  fi

  # ---- manifest
  if [ -f "$d/manifest.json" ]; then
    local bad
    bad="$(jq -r '
      if (.defects | type) != "array" or (.defects | length) == 0 then "defects[] missing or empty"
      else ([.defects[]
             | select((.id // "") == "" or (.file // "") == ""
                      or (.class // "") == "" or (.severity // "") == ""
                      or ((.line_v1 // null) == null and (.line_v2 // null) == null)
                      or (.fixed_in_v2 == true and (.fix_line_v2 // null) == null))
             | .id // "?"] | if length == 0 then "" else "incomplete defect(s): " + join(",") end)
      end' "$d/manifest.json" 2>/dev/null)" || bad="not valid JSON"
    if [ -n "$bad" ]; then
      fail "manifest[$slug]" "$bad; fix: docs/benchmark.md → manifest.json (fixed defects need fix_line_v2 for the churn metric)"
    else
      ok "manifest[$slug]" "$(jq '.defects | length' "$d/manifest.json") defect(s), all complete"
    fi

    # Anchors in one file and one tree must sit >= 10 lines apart: the scorer
    # matches on a +/-3 window, so closer anchors overlap and a finding is
    # attributed to the wrong defect. v2 anchors include fix_line_v2, which is
    # what the churn metric matches against.
    bad="$(jq -r '
      def collide($pairs):
        [ $pairs[] | .lines |= (map(select(. != null)) | sort)
          | . as $g
          | [ range(0; ($g.lines | length) - 1) as $i
              | select(($g.lines[$i+1] - $g.lines[$i]) < 10)
              | "\($g.file)@\($g.tree) \($g.lines[$i])/\($g.lines[$i+1])" ] ]
        | flatten;
      ( [ .defects | group_by(.file)[]
          | {file: .[0].file, tree: "v1", lines: [.[].line_v1]} ] ) as $v1
      | ( [ .defects | group_by(.file)[]
          | {file: .[0].file, tree: "v2", lines: ([.[].line_v2] + [.[].fix_line_v2])} ] ) as $v2
      | (collide($v1) + collide($v2)) | unique
      | if length == 0 then "" else (.[0:4] | join(", ")) end' "$d/manifest.json" 2>/dev/null)"
    if [ -n "$bad" ]; then
      fail "manifest_spacing[$slug]" "anchors closer than 10 lines: $bad; fix: move the defects apart — the scorer's ±3 windows would overlap and mis-attribute findings"
    else
      ok "manifest_spacing[$slug]" "all anchors ≥10 lines apart per file and tree"
    fi
  fi
}

validate_results() { # <file>
  local f="$1" bad
  [ -f "$f" ] || { fail json "results file not readable: $f"; return; }
  jq -e 'type == "object"' "$f" >/dev/null 2>&1 \
    || { fail json "not a JSON object: $f; fix: assemble it per docs/benchmark.md → results/<ts>.json"; return; }
  ok json "parses as a JSON object"

  bad="$(jq -r '[["ts",.ts],["trigger",.trigger],["model",.model],
                 ["definition_version",.definition_version]]
                | [.[] | select(.[1] == null or .[1] == "") | .[0]] | join(",")' "$f" 2>/dev/null)"
  [ -n "$bad" ] && fail fields "missing/empty: $bad; fix: docs/benchmark.md → results/<ts>.json" \
                || ok fields "ts, trigger, model, definition_version present"

  bad="$(jq -r 'if (.trigger | IN("scheduled","manual","trial")) then "" else (.trigger // "null") end' "$f" 2>/dev/null)"
  [ -n "$bad" ] && fail trigger "unknown trigger '$bad'; fix: use scheduled | manual | trial — the monthly gate reads scheduled only" \
                || ok trigger "trigger is one of scheduled|manual|trial"

  bad="$(jq -r '.fixtures | type' "$f" 2>/dev/null)"
  if [ "$bad" = "object" ]; then
    ok fixtures_shape "fixtures is an object keyed by slug"
  else
    fail fixtures_shape "fixtures is '$bad', must be an object keyed by slug; fix: {\"<slug>\": {first,rereview}} — an array renders report sections as 0,1,2… and breaks the index submode"
  fi

  bad="$(jq -r '
    def tokens_ok: . == null or (type == "object"
      and ([.input,.output,.cache_read,.cache_creation,.msgs] | all(type == "number")));
    if (.fixtures | type) != "object" then "" else
    [ .fixtures | to_entries[] | .key as $s | .value
      | (if (.first | type) != "object" then "\($s): first missing" else empty end),
        (if (.rereview | type) != "object" then "\($s): rereview missing" else empty end),
        (if (.first.seconds | type) != "number" then "\($s): first.seconds not numeric" else empty end),
        (if (.rereview.seconds | type) != "number" then "\($s): rereview.seconds not numeric" else empty end),
        (if (.first.tokens | tokens_ok) then empty else "\($s): first.tokens malformed" end),
        (if (.rereview.tokens | tokens_ok) then empty else "\($s): rereview.tokens malformed" end)
    ] | join("; ") end' "$f" 2>/dev/null)"
  [ -n "$bad" ] && fail per_fixture "$bad; fix: seconds come from benchmark-phase.sh (never estimated); tokens is null or all five counters" \
                || ok per_fixture "every fixture carries first+rereview with numeric seconds and well-formed tokens"

  bad="$(jq -r 'if has("benchmark_judge") and (has("judge") | not) then "benchmark_judge" else "" end' "$f" 2>/dev/null)"
  [ -n "$bad" ] && fail judge_key "run-level judge field is '$bad'; fix: the key is 'judge' (report and history read that name)" \
                || ok judge_key "judge field named correctly"
}

MODE="${1:-}"; shift 2>/dev/null || true
case "$MODE" in
  (fixture)
    [ "$#" -gt 0 ] || { printf 'usage: benchmark-validate.sh fixture <fixture-dir>...\n' >&2; exit 2; }
    for d in "$@"; do validate_fixture "$d"; done;;
  (results)
    [ "$#" -gt 0 ] || { printf 'usage: benchmark-validate.sh results <results.json>\n' >&2; exit 2; }
    for f in "$@"; do validate_results "$f"; done;;
  (*) printf 'usage: benchmark-validate.sh fixture <dir>... | results <file>...\n' >&2; exit 2;;
esac

[ "$RC" -eq 0 ] && printf 'PASS — %s validation clean\n' "$MODE" \
                || printf 'FAILED — apply the fix: lines above, then re-run\n'
exit "$RC"
