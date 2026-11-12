#!/usr/bin/env bash
# benchmark-validate.sh — deterministic gates for the benchmark
# (docs/benchmark.md). Read-only; prints `ok`/`FAIL <id>: <detail>; fix: …`
# lines and exits non-zero when any check fails.
#
#   benchmark-validate.sh fixture [--memory <dir>] <fixture-dir|root>...   # before a set is used
#   benchmark-validate.sh leak <memory-dir> <fixture-dir>...  # leak_memory alone
#   benchmark-validate.sh results <results.json>     # before results are kept
#   benchmark-validate.sh results --stored <results.json>  # a kept file (audit)
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
#   tier            tier, when present, is simple | complex; a complex
#                   fixture has >= 8 base files and >= 5 hard v1 defects
#   manifest_extra  optional fields well-formed: author_model (string),
#                   added (ISO) and source (string), defect confirmed_by
#                   [{ts, model}] — confirmed_by on an adaptive fixture only
#   leak_memory     the frozen memory copy (core-memory/MEMORY.md and
#                   LESSONS.md) names no defect: not its summary, not its
#                   file:line, not its file together with the defect's code
#                   line. The copy is --memory <dir>, else <root>/core-memory
#                   beside the fixture, else ../fixture/core-memory for an
#                   adaptive one; no copy, no check
#   core            a root holding CORE.json (core version metadata): version,
#                   created, migrated, memory_sha (= benchmark-core.sh
#                   memory-sha of core-memory/), fixtures (each a fixture dir
#                   of the root), author_model, bridged_from
#   A root (the core `fixture/` or `adaptive/`) validates every fixture dir in
#   it; retired/ and core-memory/ are never fixtures.
#
# results mode — the shape the report consumes:
#   json            parses as an object
#   fields          ts / trigger / model / effort / definition_version present
#   trigger         one of scheduled | manual | trial
#   isolation       platform-subagent, or none with isolation_reason and
#                   isolation_approved (docs/benchmark.md → Isolation)
#   fixtures_shape  fixtures is an OBJECT keyed by slug, never an array
#                   (an array renders its sections as 0,1,2… and breaks the
#                   index submode)
#   per_fixture     each slug has first + rereview; seconds numeric; tokens
#                   is null or carries all five counters; first.fp is an
#                   array and rereview.churn numeric (scorer output copied
#                   whole — a dropped field renders "—" forever, since the
#                   history is append-only)
#   tiers           from definition_version 12.11.0: every first carries
#                   `tier` and `difficulty` (scorer output copied whole) — the
#                   sufficiency table pools them per tier
#   judge_key       the run-level judge field is `judge` (not benchmark_judge)
#   judge_pinned    judge scores only from the pinned judge: any non-null
#                   fixture `judge` needs a model-id `judge` and a
#                   `judge_model_used` that model matches (MODEL_JQ) — a
#                   judge that falls back to the tested model scores itself
#   judge_resolved  before a file is kept (not with --stored: the live
#                   config moves on after a run) and with a work/CONFIG.md on
#                   this host, `judge` is what `benchmark-judge.sh resolve`
#                   prints (off = null or off; under an unpicked auto, the
#                   model id of the candidate the run tried) — an
#                   operator-asked run has no worklist entry to copy it from
#   judge_reason    from definition_version 12.3.0: `judge` is never `auto`,
#                   and a model-id judge with any fixture `judge` null carries
#                   the first non-ok `reason` as `judge_reason` — else a judge
#                   that never answered leaves no trace of why
#   run_extra       optional run fields well-formed when present: run_id,
#                   models[], reference_model, core_version, memory_source
#                   (core-frozen needs core_version), bridge_from (an earlier
#                   core version), judge_panel[] (judge = its first member or
#                   off), panel_note, author_models{}, recommendation
#                   {rule, text, cites[], confidence high|medium|low},
#                   comparison {"<a>|<b>": bench-stats paired output}
#   fixture_extra   optional fixture fields well-formed: part core|adaptive|bridge,
#                   languages {<lang>: {tp, gt}}, first.fn_detail[{id, file}],
#                   judge panel[] / disagreement / fp_class[{file, line, class}]
#   filename        a `<ts>--<model-slug>.json` name carries the slug of its
#                   model (every char outside [A-Za-z0-9._-] → _) and, with a
#                   run_id, that run_id as its <ts>
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$SCRIPT_DIR/lib/toolpath.sh" ] && . "$SCRIPT_DIR/lib/toolpath.sh" 2>/dev/null
. "$SCRIPT_DIR/lib/common.sh"   # MODEL_JQ

RC=0
MEMORY_DIR=""
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
  [ "$slug" = "core-memory" ] && { printf 'skip core-memory/: the frozen memory copy, not a fixture\n'; return; }

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
                      or (.fixed_in_v2 == true and (.fix_line_v2 // null) == null)
                      or (has("difficulty") and .difficulty != "hard"))
             | .id // "?"] | if length == 0 then "" else "incomplete defect(s): " + join(",") end)
      end' "$d/manifest.json" 2>/dev/null)" || bad="not valid JSON"
    if [ -n "$bad" ]; then
      fail "manifest[$slug]" "$bad; fix: docs/benchmark.md → manifest.json (fixed defects need fix_line_v2; difficulty, when present, is exactly \"hard\")"
    else
      ok "manifest[$slug]" "$(jq '.defects | length' "$d/manifest.json") defect(s), all complete"
    fi

    # The task tier (docs/benchmark.md → Task tiers): simple or complex, and a
    # complex fixture is one in fact — a change across many files whose v1
    # carries enough hard defects to read hard recall from.
    bad="$(jq -r '
      if has("tier") and (.tier | IN("simple", "complex") | not) then "tier is \(.tier | tostring)"
      elif .tier != "complex" then ""
      else ([.defects[] | select(.line_v1 != null and .difficulty == "hard")] | length) as $h
        | if $h < 5 then "complex with \($h) hard v1 defect(s), needs 5" else "" end
      end' "$d/manifest.json" 2>/dev/null)" || bad="not valid JSON"
    if [ -z "$bad" ] && [ "$(jq -r '.tier // ""' "$d/manifest.json" 2>/dev/null)" = complex ]; then
      n="$(find "$d/base" -type f 2>/dev/null | grep -c '')"
      [ "$n" -ge 8 ] || bad="complex with $n base file(s), needs 8"
    fi
    if [ -n "$bad" ]; then
      fail "tier[$slug]" "$bad; fix: docs/benchmark.md → Task tiers (tier is simple or complex; a complex fixture has ≥ 8 base files and ≥ 5 hard v1 defects)"
    else
      ok "tier[$slug]" "tier $(jq -r '.tier // "simple"' "$d/manifest.json")"
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

    local part=core
    [ "$(basename "$(dirname "$d")")" = adaptive ] && part=adaptive
    bad="$(jq -r --arg part "$part" '
      def iso: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T");
      [ (if has("author_model") and ((.author_model | type) != "string" or .author_model == "")
         then "author_model not a model id or unknown" else empty end),
        (if has("added") and (.added | iso | not) then "added not an ISO timestamp" else empty end),
        (if has("source") and ((.source | type) != "string" or .source == "") then "source empty" else empty end),
        (.defects[]? | select(has("confirmed_by")) | .id as $i
         | if $part != "adaptive" then "\($i): confirmed_by on a core fixture"
           elif (.confirmed_by | type) != "array"
                or (.confirmed_by | all(type == "object" and (.ts | iso) and (.model | type) == "string") | not)
           then "\($i): confirmed_by not [{ts, model}]" else empty end)
      ] | join("; ")' "$d/manifest.json" 2>/dev/null)" || bad="not valid JSON"
    if [ -n "$bad" ]; then
      fail "manifest_extra[$slug]" "$bad; fix: docs/benchmark.md → manifest.json (author_model, adaptive added/source, confirmed_by only on adaptive defects)"
    else
      ok "manifest_extra[$slug]" "optional manifest fields well-formed"
    fi

    leak_check "$d" "$(memory_dir_for "$d")"
  fi
}

# the frozen memory copy a fixture is checked against (empty = none)
memory_dir_for() { # <fixture-dir>
  local p
  [ -n "$MEMORY_DIR" ] && { printf '%s' "$MEMORY_DIR"; return; }
  p="$(dirname "${1%/}")"
  if [ -d "$p/core-memory" ]; then printf '%s' "$p/core-memory"
  elif [ "$(basename "$p")" = adaptive ] && [ -d "$p/../fixture/core-memory" ]; then
    printf '%s' "$p/../fixture/core-memory"
  fi
}

# leak_memory: the frozen copy must not name a defect of the fixture — by
# summary, by file:line, or by file together with the defect's code line
leak_check() { # <fixture-dir> <memory-dir>
  local d="${1%/}" mdir="$2" slug mem hits="" id file l1 l2 summ tree ln code
  slug="${d##*/}"
  [ -n "$mdir" ] || return 0
  [ -f "$mdir/MEMORY.md" ] || [ -f "$mdir/LESSONS.md" ] || return 0
  [ -f "$d/manifest.json" ] || return 0
  mem="$(cat "$mdir/MEMORY.md" "$mdir/LESSONS.md" 2>/dev/null)"
  while IFS="$(printf '\t')" read -r id file l1 l2 summ; do
    [ -n "$file" ] || continue
    if [ "${#summ}" -ge 12 ] && printf '%s' "$mem" | grep -qiF -- "$summ"; then
      hits="$hits $id(summary)"; continue
    fi
    for ln in "$l1" "$l2"; do
      [ -n "$ln" ] && printf '%s' "$mem" | grep -qF -- "$file:$ln" && { hits="$hits $id($file:$ln)"; continue 2; }
    done
    printf '%s' "$mem" | grep -qF -- "$file" || continue
    for tree in "head-v1:$l1" "head-v2:$l2"; do
      ln="${tree#*:}"; [ -n "$ln" ] || continue
      code="$(sed -n "${ln}p" "$d/${tree%%:*}/$file" 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      [ "${#code}" -ge 8 ] && printf '%s' "$mem" | grep -qF -- "$code" && { hits="$hits $id($file line)"; continue 2; }
    done
  done < <(jq -r '.defects[]? | [.id // "?", .file // "", (.line_v1 // "" | tostring),
                                 (.line_v2 // "" | tostring), (.summary // "")] | @tsv' "$d/manifest.json" 2>/dev/null)
  if [ -n "$hits" ]; then
    fail "leak_memory[$slug]" "the frozen memory copy names defect(s):$hits; fix: move the fixture to adaptive/ or retire it (docs/benchmark.md) — a reviewer that reads this memory knows the answer"
  else
    ok "leak_memory[$slug]" "the frozen memory copy names no defect"
  fi
}

# core: CORE.json of a root, when present
validate_core() { # <root>
  local r="${1%/}" bad want s
  [ -f "$r/CORE.json" ] || return 0
  bad="$(jq -r '
    if type != "object" then "not an object" else
    [ (if (.version | type) == "number" and .version >= 1 and (.version | floor) == .version then empty else "version not an integer >= 1" end),
      (if (.created | type) == "string" and (.created | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")) then empty else "created not ISO" end),
      (if (.migrated | type) == "boolean" then empty else "migrated not boolean" end),
      (if (.memory_sha | type) == "string" or .memory_sha == null then empty else "memory_sha not a string" end),
      (if (.fixtures | type) == "array" and (.fixtures | length) > 0 and (.fixtures | all(type == "string"))
       then empty else "fixtures not a non-empty slug list" end),
      (if (.author_model | type) == "object" and ([.author_model[]] | all(type == "string"))
       then empty else "author_model not {slug: model}" end),
      (if .bridged_from == null or ((.bridged_from | type) == "number" and .bridged_from < .version)
       then empty else "bridged_from not null or an earlier version" end)
    ] | join("; ") end' "$r/CORE.json" 2>/dev/null)" || bad="not valid JSON"
  if [ -z "$bad" ]; then
    for s in $(jq -r '.fixtures[]' "$r/CORE.json"); do
      [ -f "$r/$s/manifest.json" ] || bad="$bad${bad:+; }fixture $s not in the root"
    done
    if [ -d "$r/core-memory" ]; then
      want="$(bash "$SCRIPT_DIR/benchmark-core.sh" memory-sha "$r/core-memory" 2>/dev/null)"
      [ "$(jq -r '.memory_sha // ""' "$r/CORE.json")" = "$want" ] \
        || bad="$bad${bad:+; }memory_sha does not match core-memory/"
    fi
  fi
  if [ -n "$bad" ]; then
    fail core "$bad; fix: benchmark-core.sh (migrate | new-version) writes CORE.json — re-run it, never edit the file by hand"
  else
    ok core "core version $(jq -r .version "$r/CORE.json"), $(jq '.fixtures | length' "$r/CORE.json") fixture(s)"
  fi
}

# a root holds fixtures (or CORE.json); a fixture dir holds manifest.json
is_root() { # <dir>
  local d="${1%/}"
  [ -f "$d/manifest.json" ] && return 1
  [ -f "$d/CORE.json" ] && return 0
  case "${d##*/}" in (fixture|adaptive) return 0;; esac
  ls "$d"/*/manifest.json >/dev/null 2>&1
}

validate_fixture_arg() { # <dir>
  local d="${1%/}" s
  if is_root "$d"; then
    validate_core "$d"
    for s in "$d"/*/; do
      [ -d "$s" ] || continue
      case "$(basename "$s")" in (retired|core-memory) continue;; esac
      validate_fixture "$s"
    done
  else
    validate_fixture "$d"
  fi
}

validate_results() { # <file>
  local f="$1" bad
  [ -f "$f" ] || { fail json "results file not readable: $f"; return; }
  jq -e 'type == "object"' "$f" >/dev/null 2>&1 \
    || { fail json "not a JSON object: $f; fix: assemble it per docs/benchmark.md → results/<ts>.json"; return; }
  ok json "parses as a JSON object"

  bad="$(jq -r '[["ts",.ts],["trigger",.trigger],["model",.model],["effort",.effort],
                 ["definition_version",.definition_version]]
                | [.[] | select(.[1] == null or .[1] == "") | .[0]] | join(",")' "$f" 2>/dev/null)"
  [ -n "$bad" ] && fail fields "missing/empty: $bad; fix: docs/benchmark.md → results/<ts>.json" \
                || ok fields "ts, trigger, model, effort, definition_version present"

  bad="$(jq -r 'if (.trigger | IN("scheduled","manual","trial")) then "" else (.trigger // "null") end' "$f" 2>/dev/null)"
  [ -n "$bad" ] && fail trigger "unknown trigger '$bad'; fix: use manual | trial (scheduled: runs before 15.0.0)" \
                || ok trigger "trigger is one of scheduled|manual|trial"

  bad="$(jq -r 'if .isolation == "platform-subagent" then ""
    elif .isolation == "none" then
      ([["isolation_reason", .isolation_reason], ["isolation_approved", .isolation_approved]]
       | [.[] | select((.[1] // "") == "") | .[0]] | if length == 0 then "" else "isolation none without " + join(", ") end)
    else "isolation is \(.isolation // "missing")" end' "$f" 2>/dev/null)"
  [ -n "$bad" ] && fail isolation "$bad; fix: platform-subagent for a run through benchmark-isolate.sh; none only with the operator's approval and its reason (docs/benchmark.md → Isolation unavailable)" \
                || ok isolation "isolation recorded"

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
        (if (.rereview.tokens | tokens_ok) then empty else "\($s): rereview.tokens malformed" end),
        (if (.first.fp | type) == "array" then empty else "\($s): first.fp not an array" end),
        (if (.rereview.churn | type) == "number" then empty else "\($s): rereview.churn not numeric" end)
    ] | join("; ") end' "$f" 2>/dev/null)"
  [ -n "$bad" ] && fail per_fixture "$bad; fix: seconds come from benchmark-phase.sh (never estimated); tokens is null or all five counters; copy the scorer output whole — dropped fields render as — forever" \
                || ok per_fixture "every fixture carries first+rereview with numeric seconds, well-formed tokens, and whole scorer output"

  bad="$(jq -r '
    ((.definition_version // "0") | tostring | [splits("[.]") | tonumber? // 0]) as $v
    | if $v < [12, 11, 0] or (.fixtures | type) != "object" then "" else
      [ .fixtures | to_entries[] | .key as $s | .value.first | select(type == "object")
        | (if (.tier // null) | IN("simple", "complex") then empty else "\($s): first.tier missing" end),
          (if (.difficulty.easy.gt? | type) == "number" and (.difficulty.hard.gt? | type) == "number"
           then empty else "\($s): first.difficulty missing" end)
      ] | join("; ") end' "$f" 2>/dev/null)"
  [ -n "$bad" ] && fail tiers "$bad; fix: copy the scorer output whole — the sufficiency table pools tier and difficulty per tier" \
                || ok tiers "every first review carries its tier and difficulty counts"

  bad="$(jq -r 'if has("benchmark_judge") and (has("judge") | not) then "benchmark_judge" else "" end' "$f" 2>/dev/null)"
  [ -n "$bad" ] && fail judge_key "run-level judge field is '$bad'; fix: the key is 'judge' (report and history read that name)" \
                || ok judge_key "judge field named correctly"

  bad="$(jq -r "$MODEL_JQ"'
    [.fixtures // {} | if type == "object" then .[] else empty end
     | (.first.judge?, .rereview.judge?) | select(type == "object")] as $scored
    | (.judge // "" | tostring) as $j | (.judge_model_used // "" | tostring) as $u
    | ([$j] + (.judge_panel // [] | if type == "array" then . else [] end)) as $pins
    | if ($scored | length) == 0 then ""
      elif $j == "" or $j == "off" then "judge scores present, but judge is \"\($j)\""
      elif $u == "" then "judge scores present, but judge_model_used is missing"
      elif ($u | split(",") | map(sub("^ +| +$"; "")) | all(. as $m
              | any($pins[]; . as $p | $m | model_has($p)))) then ""
      else "judge is \($j), but \($u) scored" end' "$f" 2>/dev/null)"
  [ -n "$bad" ] && fail judge_pinned "$bad; fix: take judge scores and judge_model_used from benchmark-judge.sh only — set every fixture judge to null when it did not answer ok" \
                || ok judge_pinned "judge scores, if any, come from the pinned judge"

  RESOLVED=""
  [ "$STORED" = 0 ] && [ -f "${WORK_DIR:-${HOME:-/home/agent}/work}/CONFIG.md" ] \
    && RESOLVED="$(bash "$SCRIPT_DIR/benchmark-judge.sh" resolve 2>/dev/null | jq -r '.judge // empty' 2>/dev/null)"
  if [ -n "$RESOLVED" ]; then
    bad="$(jq -r --arg r "$RESOLVED" '(.judge // "off" | tostring) as $j
      | if $r == "auto" then
          (if $j == "auto" or $j == "off" then "judge is \"\($j)\" under an unpicked auto, not the candidate the run tried" else "" end)
        elif $j == $r then ""
        elif ((.judge_panel // []) | join(",")) == ($r | gsub(" "; "")) then ""
        else "judge is \"\($j)\", but benchmark-judge.sh resolve prints \"\($r)\"" end' "$f" 2>/dev/null)"
    [ -n "$bad" ] && fail judge_resolved "$bad; fix: take judge from benchmark-judge.sh resolve and run phase 2 step 6 with it" \
                  || ok judge_resolved "the run used the judge every run uses"
  fi

  bad="$(jq -r '
    [.fixtures // {} | if type == "object" then .[] else empty end
     | (.first, .rereview) | select(type == "object") | .judge] as $phases
    | (.judge // "" | tostring) as $j
    | ((.definition_version // "0") | tostring | [splits("[.]") | tonumber? // 0]) as $v
    | if $v < [12, 3, 0] then ""
      elif $j == "auto" then "judge is auto, not the resolved judge"
      elif $j == "" or $j == "off" then ""
      elif ($phases | any(. == null)) and ((.judge_reason // "") | tostring) == ""
      then "a fixture judge is null, but judge_reason is missing"
      else "" end' "$f" 2>/dev/null)"
  [ -n "$bad" ] && fail judge_reason "$bad; fix: judge is the judge from benchmark-judge.sh resolve or the call that pinned it; judge_reason is the first reason benchmark-judge.sh printed with a status other than ok" \
                || ok judge_reason "the judge is resolved, and a missing judge score has its reason"

  bad="$(jq -r '
    def strs: type == "array" and length > 0 and all(type == "string" and . != "");
    def paired: type == "object" and (.n_defects | type) == "number"
      and (.verdict | IN("a_better", "b_better", "in_noise"));
    [ (if has("run_id") and ((.run_id | type) != "string" or .run_id == "") then "run_id empty" else empty end),
      (if has("models") and (.models | strs | not) then "models not a model list" else empty end),
      (if has("reference_model") and (.reference_model != null and (.reference_model | type) != "string")
       then "reference_model not a model id or null" else empty end),
      (if has("core_version") and (.core_version != null
            and ((.core_version | type) != "number" or .core_version < 1))
       then "core_version not a version or null" else empty end),
      (if has("bridge_from") and .bridge_from != null
            and ((.bridge_from | type) != "number" or (.core_version | type) != "number"
                 or .bridge_from >= .core_version)
       then "bridge_from not an earlier core version" else empty end),
      (if has("panel_note") and .panel_note != null and (.panel_note | type) != "string"
       then "panel_note not a string or null" else empty end),
      (if has("memory_source") and (.memory_source | IN("core-frozen", "live") | not)
       then "memory_source not core-frozen | live"
       elif .memory_source == "core-frozen" and (.core_version // null) == null
       then "memory_source core-frozen without core_version" else empty end),
      (if has("judge_panel") then
         (if (.judge_panel | strs | not) then "judge_panel not a model list"
          elif ((.judge // "off") | tostring) as $j | $j != "off" and $j != .judge_panel[0]
          then "judge is not the first judge_panel member" else empty end)
       else empty end),
      (if has("author_models") and ((.author_models | type) != "object"
            or ([.author_models[]] | all(type == "string") | not))
       then "author_models not {slug: model}" else empty end),
      (if has("recommendation") then
         (.recommendation
          | if type == "object" and (.rule | type) == "string" and (.text | type) == "string"
               and (.cites | type) == "array" and (.cites | all(type == "string"))
               and (.confidence | IN("high", "medium", "low"))
            then empty else "recommendation not {rule, text, cites[], confidence high|medium|low}" end)
       else empty end),
      (if has("comparison") and ((.comparison | type) != "object"
            or ([.comparison | to_entries[] | (.key | test("[|]")) and (.value | paired)] | all | not))
       then "comparison not {\"<a>|<b>\": bench-stats paired output}" else empty end)
    ] | join("; ")' "$f" 2>/dev/null)"
  [ -n "$bad" ] && fail run_extra "$bad; fix: docs/benchmark.md → results/<ts>.json (optional run fields)" \
                || ok run_extra "optional run fields, if any, are well-formed"

  bad="$(jq -r '
    def counts: type == "object" and ([.[]] | all(type == "object"
      and (.tp | type) == "number" and (.gt | type) == "number"));
    def judge_ok($s; $ph):
      if type != "object" then empty else
        (if has("panel") and ((.panel | type) != "array"
              or (.panel | all(type == "object" and (.model | type) == "string"
                               and (.status | type) == "string") | not))
         then "\($s): \($ph).judge.panel malformed" else empty end),
        (if has("disagreement") and .disagreement != null and (.disagreement | type) != "number"
         then "\($s): \($ph).judge.disagreement not a number" else empty end),
        (if has("fp_class") and ((.fp_class | type) != "array"
              or (.fp_class | all(type == "object" and (.file | type) == "string"
                                  and (.class | IN("real", "defensible", "fabricated"))) | not))
         then "\($s): \($ph).judge.fp_class malformed" else empty end)
      end;
    if (.fixtures | type) != "object" then "" else
    [ .fixtures | to_entries[] | .key as $s | .value | select(type == "object")
      | (if has("part") and (.part | IN("core", "adaptive", "bridge") | not) then "\($s): part not core | adaptive | bridge" else empty end),
        (if (.first | type) == "object" and (.first | has("languages")) and (.first.languages | counts | not)
         then "\($s): first.languages malformed" else empty end),
        (if (.rereview | type) == "object" and (.rereview | has("languages")) and (.rereview.languages | counts | not)
         then "\($s): rereview.languages malformed" else empty end),
        (if (.first | type) == "object" and (.first | has("fn_detail"))
            and ((.first.fn_detail | type) != "array"
                 or (.first.fn_detail | all(type == "object" and (.id | type) == "string"
                                            and (.file | type) == "string") | not))
         then "\($s): first.fn_detail malformed" else empty end),
        (.first.judge? | judge_ok($s; "first")),
        (.rereview.judge? | judge_ok($s; "rereview"))
    ] | join("; ") end' "$f" 2>/dev/null)"
  [ -n "$bad" ] && fail fixture_extra "$bad; fix: copy the scorer and benchmark-judge.sh output whole; part is core or adaptive" \
                || ok fixture_extra "optional fixture fields, if any, are well-formed"

  local base="${f##*/}"
  case "$base" in
    (*--*.json)
      bad="$(jq -r --arg base "$base" '
        ($base | sub("\\.json$"; "") | split("--")) as $p
        | ((.model // "") | tostring | gsub("[^A-Za-z0-9._-]"; "_")) as $slug
        | [ (if ($p | length) != 2 then "name has more than one --" else empty end),
            (if $p[-1] != $slug then "model slug \($p[-1]) is not \($slug)" else empty end),
            (if has("run_id") and $p[0] != .run_id then "ts \($p[0]) is not run_id \(.run_id)" else empty end)
          ] | join("; ")' "$f" 2>/dev/null)"
      [ -n "$bad" ] && fail filename "$bad; fix: name a per-model file <run_id>--<model-slug>.json" \
                    || ok filename "per-model file name matches run_id and model";;
  esac
}

MODE="${1:-}"; shift 2>/dev/null || true
case "$MODE" in
  (fixture)
    [ "${1:-}" = --memory ] && { MEMORY_DIR="${2:-}"; shift 2 2>/dev/null || shift; }
    [ "$#" -gt 0 ] || { printf 'usage: benchmark-validate.sh fixture [--memory <dir>] <fixture-dir|root>...\n' >&2; exit 2; }
    for d in "$@"; do validate_fixture_arg "$d"; done;;
  (leak)
    [ "$#" -gt 1 ] || { printf 'usage: benchmark-validate.sh leak <memory-dir> <fixture-dir>...\n' >&2; exit 2; }
    MEMORY_DIR="$1"; shift
    for d in "$@"; do leak_check "$d" "$MEMORY_DIR"; done;;
  (results)
    STORED=0; [ "${1:-}" = --stored ] && { STORED=1; shift; }
    [ "$#" -gt 0 ] || { printf 'usage: benchmark-validate.sh results [--stored] <results.json>\n' >&2; exit 2; }
    for f in "$@"; do validate_results "$f"; done;;
  (*) printf 'usage: benchmark-validate.sh fixture [--memory <dir>] <dir>... | leak <memory-dir> <dir>... | results [--stored] <file>...\n' >&2; exit 2;;
esac

[ "$RC" -eq 0 ] && printf 'PASS — %s validation clean\n' "$MODE" \
                || printf 'FAILED — apply the fix: lines above, then re-run\n'
exit "$RC"
