#!/usr/bin/env bash
# check-definition.sh — deterministic checks of an agent definition repository:
# the Markdown instructions, scripts, manifest and version files that an
# autonomous agent reads and runs. Repository-agnostic: every check discovers
# what the repository has and skips what it does not have.
#
# Usage: check-definition.sh [--base <ref>] [<repo-dir>]
#        check-definition.sh --list-checks
#   --base  compare with <ref> (normally origin/<base-branch>): print only the
#           findings the change adds, plus the checks of the added lines and of
#           the version bump. Without --base: every finding of the tree.
# Output: one finding per line, tab-separated:
#           <FAIL|WARN|NOTE>  <check-id>  <path[:line]>  <message>
#         then one summary line. Exit 0 = no FAIL, 1 = a FAIL, 2 = usage error
#         or a missing command.
# Read-only. Needs bash 3.2+, git, jq, grep, sed, xargs, find, cmp, coreutils
# (sort uniq cut tr head tail wc mktemp basename dirname) and, with --base,
# tar — no awk, no python; BSD or GNU flavors. A missing one exits 2.

set -u
export LC_ALL=C

BASE=""
REPO="."
while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE="${2:?--base needs a ref}"; shift 2 ;;
    --list-checks) sed -n 's/^[[:space:]]*# check: //p' "$0"; exit 0 ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) REPO="$1"; shift ;;
  esac
done

for c in git jq grep sed xargs find sort uniq cut tr head tail wc cmp mktemp basename dirname; do
  command -v "$c" >/dev/null 2>&1 || { echo "missing command: $c" >&2; exit 2; }
done
[ -z "$BASE" ] || command -v tar >/dev/null 2>&1 || { echo "missing command: tar" >&2; exit 2; }
cd "$REPO" 2>/dev/null || { echo "no such directory: $REPO" >&2; exit 2; }
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "not a git repository: $REPO" >&2; exit 2; }
cd "$ROOT" || exit 2

TMP="$(mktemp -d "${TMPDIR:-/tmp}/agent-def.XXXXXX")" || exit 2
trap 'rm -rf "$TMP"' EXIT
TAB="$(printf '\t')"

emit() { printf '%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" >> "$1"; }  # <out> <level> <check> <loc> <msg>
is_semver() { case "$1" in *[!0-9.]*|.*|*.|*..*) return 1 ;; *.*.*.*) return 1 ;; *.*.*) return 0 ;; *) return 1 ;; esac; }
newest_version() { sed -nE 's/^## \[?v?([0-9]+\.[0-9]+\.[0-9]+)\]?([^0-9.].*)?$/\1/p' "$1" | head -1; }
has_shebang() { local l=""; IFS= read -r l < "$1" 2>/dev/null; case "$l" in '#!'*sh|'#!'*sh' '*|'#!'*'env bash'*) return 0 ;; esac; return 1; }
# grep_lines <tree> <list>: every line of the listed files as "path:line:text", in one process
grep_lines() { (cd "$1" && tr '\n' '\0' < "$2" | xargs -0 grep -Hn '' -- 2>/dev/null); }

# --------------------------------------------------- Markdown scan (jq) ----
# check: links         Relative Markdown links resolve to a file or directory
# check: anchors       #anchor links resolve to a heading of the target file
# check: section-refs  Prose references "<file>.md → **Label**" name a heading or bold label of that file
# check: paths         Repository paths in backticks (`scripts/x.sh`, `$HOME/docs/y.md`) exist
# Fenced code is skipped: an example in a fence is not a link, path or rule.
read -r -d '' MD_JQ <<'JQ'
def norm: reduce (split("/")[]) as $p ([];
    if $p == "" or $p == "." then . elif $p == ".." then (if length > 0 then .[:-1] else . + ["\u0001"] end)
    else . + [$p] end) | join("/");
def dirof: if test("/") then sub("/[^/]*$"; "") else "" end;
def under($d): if $d == "" then . else $d + "/" + . end;
def slug: gsub("\\]\\([^)]*\\)"; "") | gsub("[\\[\\]`*]"; "") | ascii_downcase
  | gsub("[!\"#$%&'()+,./:;<=>?@\\\\^{|}~]"; "") | gsub(" "; "-");
def skipped: test("(^|/)CHANGELOG[^/]*$|\\.template$|(^|/)templates/");
def out($l; $c; $loc; $m): [$l, $c, $loc, $m] | join("\t");
def fence: test("^[ \t]*(```|~~~)");

($list | split("\n") | map(select(length > 0))) as $files
| (reduce $files[] as $f ({}; .[$f] = "f"
    | reduce ($f | split("/") | range(1; length) as $i | .[:$i] | join("/")) as $d (.; .[$d] //= "d"))) as $exists
| ([$files[] | select(test("/")) | split("/")[0]] | unique | map({key: ., value: true}) | from_entries) as $top
| [inputs | capture("^(?<f>[^:]*):(?<n>[0-9]+):(?<t>.*)$")] | group_by(.f)
| map({f: .[0].f,
       lines: [foreach .[] as $l (false; if ($l.t | fence) then not else . end;
                 if ($l.t | fence) or . then empty else {n: ($l.n | tonumber), t: $l.t} end)]})
| (map({key: .f, value: (
      [.lines[].t | select(test("^#{1,6}[ \t]+")) | sub("^#+[ \t]+"; "") | sub("[ \t#]+$"; "")] as $h
      | {anchors: (reduce ($h[] | slug) as $s ({c: {}, a: {}};
            .a[if (.c[$s] // 0) == 0 then $s else $s + "-" + ((.c[$s]) | tostring) end] = true | .c[$s] += 1) | .a),
         labels: ([$h[] | gsub("  +"; " ")]
           + [.lines[].t | capture("^\\*\\*(?<l>[^*]+)\\*\\*") | .l])})}) | from_entries) as $A
| .[] | .f as $f | ($f | dirof) as $d | select($f | skipped | not)
| (
    # links and anchors
    ( .lines[] | .n as $n | .t | scan("\\]\\(([^) ]+)\\)") | .[0]
      | select(test("^(https?|mailto):|[<{$]|…") | not)
      | . as $t | (if test("#") then sub("#.*$"; "") else . end) as $p
      | (if test("#") then sub("^[^#]*#"; "") else "" end) as $a
      | (if $p == "" then $f
         elif $exists[($p | under($d) | norm)] then ($p | under($d) | norm)
         elif $exists[($p | norm)] then ($p | norm) else null end) as $tf
      | if $tf == null then out("FAIL"; "links"; "\($f):\($n)"; "dead link: \($t)")
        elif $a != "" and ($tf | test("\\.md$")) and $A[$tf] != null and ($A[$tf].anchors[$a] | not)
        then out("FAIL"; "anchors"; "\($f):\($n)"; "no heading for anchor: \($t)")
        else empty end ),
    # paths in backticks
    ( [ .lines[] | select(.t | contains("`")) | .n as $n | .t | scan("`([^`]+)`") | .[0]
        | select(contains("/")) | splits("[ \t]+") | select(contains("/"))
        | sub("^[\"'(]+"; "") | sub("[\"'),;.]+$"; "") | sub(":[0-9]+(-[0-9]+)?$"; "")
        | sub("^\\$HOME/"; "") | sub("^~/"; "") | sub("^/home/agent/"; "")
        | select(test("/") and (test("[<>${}*?\\[|=]|…|^(-|/|\\./|\\.\\./)") | not)
                 and test("^[A-Za-z0-9_.@-]+(/[A-Za-z0-9_.@-]+)*/?$"))
        | select($top[split("/")[0]] != null)
        | select($exists[sub("/$"; "")] == null)
        | {n: $n, w: .} ] | unique_by(.w) | sort_by(.n)[]
      | out("WARN"; "paths"; "\($f):\(.n)"; "names a path the repository does not have: \(.w)") ),
    # prose section references
    ( [.lines[].t] | join(" ")
      | [scan("\\[?[A-Za-z0-9_./-]+\\.md[`)]?[ \t]+→[ \t]+\\*\\*[^*]+\\*\\*")] | map(gsub("[ \t]+"; " ")) | unique[]
      | . as $ref
      | (sub(" → .*$"; "") | sub("^\\["; "") | sub("[`)]$"; "") | sub("^/home/agent/"; "")) as $t
      | (sub("^.* → \\*\\*"; "") | sub("\\*\\*$"; "")) as $label
      | (first(($t | under($d)), $t, ("docs/" + $t) | norm | select($exists[.] == "f")) // null) as $tf
      | if $tf == null then out("FAIL"; "section-refs"; $f; "reference to a missing file: \($ref)")
        elif ($A[$tf] == null) or any($A[$tf].labels[]; startswith($label)) then empty
        else out("FAIL"; "section-refs"; $f; "no section '\($label)' in \($tf)") end )
  )
JQ

# Text of a kit.yaml schedule task, one task per line (block or plain scalar).
kit_tasks() {
  local line ind=0 t="" intask=0 lead v
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$intask" = 1 ]; then
      lead="${line%%[![:space:]]*}"
      if [ -n "${line//[[:space:]]/}" ] && [ "${#lead}" -gt "$ind" ]; then
        t="$t${t:+ }${line#"$lead"}"; continue
      fi
      printf '%s\n' "$t"; intask=0; t=""
    fi
    if [[ "$line" =~ ^([[:space:]]*)(-[[:space:]]+)?task:[[:space:]]*[\>\|][-+]?[[:space:]]*$ ]]; then
      ind="${#BASH_REMATCH[1]}"; intask=1; t=""
    elif [[ "$line" =~ ^[[:space:]]*(-[[:space:]]+)?task:[[:space:]]*(.+)$ ]]; then
      v="${BASH_REMATCH[2]}"; v="${v#[\"\']}"; v="${v%[\"\']}"; printf '%s\n' "$v"
    fi
  done < "$1"
  [ "$intask" = 1 ] && printf '%s\n' "$t"
  return 0
}

# ------------------------------------------------------------- tree checks ----
# Checks that judge a whole tree. They run on the change and on the base; with
# --base only the findings the change adds are printed.
tree_checks() { # <tree-dir> <file-list> <out>
  local T="$1" L="$2" O="$3" s t

  grep -E '\.md$' "$L" > "$TMP/md.list"
  grep_lines "$T" "$TMP/md.list" | jq -R -n -r --rawfile list "$L" "$MD_JQ" >> "$O"

  # check: version       VERSION is plain semver and equals the newest CHANGELOG heading
  if [ -f "$T/VERSION" ]; then
    local v top
    v="$(head -1 "$T/VERSION" | tr -d '[:space:]')"
    is_semver "$v" || emit "$O" FAIL version "VERSION" "not plain semver: '$v'"
    if [ -f "$T/CHANGELOG.md" ]; then
      top="$(newest_version "$T/CHANGELOG.md")"
      [ "$v" = "$top" ] || emit "$O" FAIL version "VERSION" "VERSION $v != newest CHANGELOG.md heading ${top:-<none>}"
    fi
  fi

  # check: scaffolding   No unresolved template placeholder: TODO(creator) anywhere, {{NAME}} in an entry file or manifest
  grep -E '\.(md|sh|ya?ml|json)$' "$L" | grep -vE '\.template$|(^|/)templates/|check-definition\.sh$' > "$TMP/scaf.list"
  (cd "$T" && tr '\n' '\0' < "$TMP/scaf.list" | xargs -0 grep -nF 'TODO(creator)' /dev/null 2>/dev/null) \
    | sed -E "s/^([^:]*):([0-9]+):.*/FAIL${TAB}scaffolding${TAB}\1:\2${TAB}unresolved template marker TODO(creator)/" >> "$O"
  grep -E '(^|/)(CLAUDE|AGENTS|GEMINI|ONBOARDING|README)\.md$|^kit\.ya?ml$' "$L" > "$TMP/entry.list"
  (cd "$T" && tr '\n' '\0' < "$TMP/entry.list" | xargs -0 grep -nE '\{\{[A-Z][A-Z0-9_]*\}\}' /dev/null 2>/dev/null) \
    | sed -E "s/^([^:]*):([0-9]+):.*/FAIL${TAB}scaffolding${TAB}\1:\2${TAB}unresolved template placeholder/" >> "$O"

  # check: kit           kit.yaml: the scripts it runs exist; names are unique; each task text has a doc copy; a changed doc a task text names
  if [ -f "$T/kit.yaml" ]; then
    for s in $(grep -oE 'scripts/[A-Za-z0-9_./-]+\.sh' "$T/kit.yaml" | sort -u); do
      [ -f "$T/$s" ] || emit "$O" FAIL kit "kit.yaml" "runs $s, which the repository does not have"
    done
    grep -E '^[[:space:]]*-[[:space:]]+name:' "$T/kit.yaml" \
      | sed -E 's/.*name:[[:space:]]*//; s/["'"'"']//g; s/[[:space:]]+$//' | sort | uniq -d \
      | while IFS= read -r s; do emit "$O" FAIL kit "kit.yaml" "schedule name declared twice: $s"; done
    (cd "$T" && tr '\n' '\0' < "$TMP/md.list" | xargs -0 sed -E 's/^[[:space:]]*>[[:space:]]?//' 2>/dev/null) \
      | tr '\n' ' ' | tr -s ' ' > "$TMP/docs.norm"
    kit_tasks "$T/kit.yaml" | tr -s ' ' | while IFS= read -r t; do
      t="${t% }"; [ -n "$t" ] || continue
      grep -qF -- "$t" "$TMP/docs.norm" \
        || emit "$O" WARN kit "kit.yaml" "schedule task text has no identical copy in any doc, so the copy and its source drift: ${t:0:70}…"
    done
  fi
  return 0
}

# Checks of single files: the whole tree without --base, the changed files with it.
file_checks() { # <scope-list> <out>
  local L="$1" O="$2" f dir name line fm desc
  # check: syntax        Every shell script parses (bash -n)
  # check: exec-bit      A shell script is executable when the other scripts of its directory are
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    case "$f" in *.template) continue ;; *.sh) ;; *) has_shebang "$f" || continue ;; esac
    bash -n "$f" 2>/dev/null || emit "$O" FAIL syntax "$f" "bash -n fails"
    if has_shebang "$f" && [ ! -x "$f" ]; then
      local ex=0 nx=0
      for s in "$(dirname "$f")"/*; do
        [ -f "$s" ] && has_shebang "$s" || continue
        if [ -x "$s" ]; then ex=$((ex + 1)); else nx=$((nx + 1)); fi
      done
      [ "$ex" -gt "$nx" ] \
        && emit "$O" WARN exec-bit "$f" "not executable while most scripts beside it are: a call by path fails"
    fi
  done < "$L"

  # check: skills        A bundled SKILL.md has front matter with a name equal to its directory and a description
  while IFS= read -r f; do
    case "$f" in */SKILL.md|SKILL.md) [ -f "$f" ] || continue ;; *) continue ;; esac
    dir="$(basename "$(dirname "$f")")"; name=""; desc=""; fm=0
    while IFS= read -r line || [ -n "$line" ]; do
      if [ "$fm" = 0 ]; then
        case "$line" in ---*) fm=1; continue ;; *) break ;; esac
      fi
      case "$line" in
        ---*) fm=2; break ;;
        name:*) name="${line#name:}"; name="${name# }"; name="${name//\"/}"; name="${name//\'/}"; name="${name%% *}" ;;
        description:*) desc="${line#description:}"; desc="${desc// /}" ;;
      esac
    done < "$f"
    if [ "$fm" != 2 ]; then
      emit "$O" FAIL skills "$f" "no YAML front matter: a harness cannot list the skill"; continue
    fi
    [ "$name" = "$dir" ] || emit "$O" FAIL skills "$f" "front matter name '${name:-<none>}' != directory '$dir'"
    [ -n "$desc" ] || emit "$O" FAIL skills "$f" "no description: a harness decides when to use a skill from it"
  done < "$L"

  # check: ignored       No tracked file is ignored by .gitignore (force-added past an allowlist)
  git ls-files -ci --exclude-standard | grep -xFf "$L" | while IFS= read -r f; do
    emit "$O" WARN ignored "$f" "tracked but ignored by .gitignore: re-include it, or a later 'git add' of a sibling skips it"
  done
  return 0
}

# ---------------------------------------------------------- the change side ----
HEAD_LIST="$TMP/head.list"
git ls-files -co --exclude-standard | while IFS= read -r f; do [ -f "$f" ] && printf '%s\n' "$f"; done \
  | sort > "$HEAD_LIST"
HEAD_OUT="$TMP/head.out"; : > "$HEAD_OUT"
OUT="$TMP/out"; : > "$OUT"
tree_checks "$ROOT" "$HEAD_LIST" "$HEAD_OUT"

if [ -z "$BASE" ]; then
  cat "$HEAD_OUT" >> "$OUT"
  file_checks "$HEAD_LIST" "$OUT"
else
  git rev-parse --verify -q "$BASE^{commit}" >/dev/null || { echo "unknown ref: $BASE" >&2; exit 2; }
  MB="$(git merge-base "$BASE" HEAD)" || { echo "no merge base with $BASE" >&2; exit 2; }

  # ---------------------------------------------------------- the base side ----
  mkdir -p "$TMP/base"
  git archive "$MB" | tar -x -C "$TMP/base"
  BASE_LIST="$TMP/base.list"
  (cd "$TMP/base" && find . -type f | sed 's,^\./,,' | sort) > "$BASE_LIST"
  BASE_OUT="$TMP/base.out"; : > "$BASE_OUT"
  tree_checks "$TMP/base" "$BASE_LIST" "$BASE_OUT"

  # A finding is the change's when its check, file and message are new. Line
  # numbers move with every edit, so they are not part of the key.
  jq -R -r -n --rawfile base "$BASE_OUT" '
    def key: split("\t") | .[2] |= sub(":[0-9]+$"; "") | join("\t");
    ($base | split("\n") | map(select(length > 0) | key) | map({key: ., value: true}) | from_entries) as $known
    | inputs | select(length > 0) | select($known[key] | not)' < "$HEAD_OUT" >> "$OUT"

  # ------------------------------------------------------- the changed files ----
  CHANGED="$TMP/changed"   # <status>\t<path>
  { git diff --name-status --no-renames "$MB" -- . ; git ls-files -o --exclude-standard | sed "s/^/A$TAB/"; } \
    | sort -t"$TAB" -k2,2 -u > "$CHANGED"
  cut -f2 "$CHANGED" | while IFS= read -r f; do [ -f "$f" ] && printf '%s\n' "$f"; done > "$TMP/changed.present"
  file_checks "$TMP/changed.present" "$OUT"

  # The lines the change adds and removes: <path>\t<line>\t<text>
  ADDED="$TMP/added"; REMOVED="$TMP/removed"; : > "$ADDED"; : > "$REMOVED"
  while IFS="$TAB" read -r st f; do
    case "$f" in *.png|*.jpg|*.jpeg|*.gif|*.ico|*.pdf|*.lock|*.woff*) continue ;; esac
    if [ "$st" = A ] && ! git cat-file -e "$MB:$f" 2>/dev/null; then
      [ -f "$f" ] || continue
      n=0
      while IFS= read -r l || [ -n "$l" ]; do
        n=$((n + 1)); printf '%s\t%s\t%s\n' "$f" "$n" "$l"
      done < "$f" >> "$ADDED"
      continue
    fi
    n=0; o=0
    while IFS= read -r l; do
      case "$l" in
        '@@'*) [[ "$l" =~ ^@@\ -([0-9]+)(,[0-9]+)?\ \+([0-9]+) ]] && { o="${BASH_REMATCH[1]}"; n="${BASH_REMATCH[3]}"; } ;;
        '+++'*|'---'*) ;;
        '+'*) printf '%s\t%s\t%s\n' "$f" "$n" "${l#+}" >> "$ADDED"; n=$((n + 1)) ;;
        '-'*) printf '%s\t%s\t%s\n' "$f" "$o" "${l#-}" >> "$REMOVED"; o=$((o + 1)) ;;
      esac
    done < <(git diff -U0 --no-color "$MB" -- "$f")
  done < "$CHANGED"

  # check: version-bump  A change to the definition bumps VERSION once, by one step, to a number not yet released
  if [ -f VERSION ] && [ -f "$TMP/base/VERSION" ]; then
    old="$(head -1 "$TMP/base/VERSION" | tr -d '[:space:]')"
    new="$(head -1 VERSION | tr -d '[:space:]')"
    if [ "$old" = "$new" ]; then
      cut -f2 "$CHANGED" | grep -qvxE 'VERSION|CHANGELOG\.md' \
        && emit "$OUT" WARN version-bump "VERSION" "the definition changed but VERSION stays $old: deployed instances cannot tell the change apart"
    elif is_semver "$old" && is_semver "$new"; then
      IFS=. read -r a b c <<EOF
$old
EOF
      ok="$((a + 1)).0.0 $a.$((b + 1)).0 $a.$b.$((c + 1))"
      case " $ok " in *" $new "*) ;; *)
        emit "$OUT" FAIL version-bump "VERSION" "$old -> $new is not one step (expected one of: $ok)" ;;
      esac
      esc="$(printf '%s' "$new" | sed 's/\./\\./g')"
      git show "$BASE:CHANGELOG.md" 2>/dev/null | grep -qE "^## \[?v?$esc([^0-9.]|$)" \
        && emit "$OUT" FAIL version-bump "CHANGELOG.md" "$new is already released on $BASE: re-number this change's entry upward"
    fi
  fi

  # check: changelog     Released CHANGELOG entries stay unchanged; the new entry follows the convention the released ones share
  if [ -f CHANGELOG.md ] && [ -f "$TMP/base/CHANGELOG.md" ]; then
    first="$(grep -nE '^## ' "$TMP/base/CHANGELOG.md" | head -1 | cut -d: -f1)"
    if [ -n "$first" ]; then
      tail -n "+$first" "$TMP/base/CHANGELOG.md" > "$TMP/cl.base"
      nb="$(wc -l < "$TMP/cl.base" | tr -d ' ')"
      tail -n "$nb" CHANGELOG.md | cmp -s - "$TMP/cl.base" \
        || emit "$OUT" FAIL changelog "CHANGELOG.md" "an entry released on the base was edited, moved or removed: add a new entry on top instead"
      if [ "$(newest_version CHANGELOG.md)" != "$(newest_version "$TMP/base/CHANGELOG.md")" ]; then
        sed -n '/^## /,$p' CHANGELOG.md | sed '1!{/^## /,$d;}' > "$TMP/cl.new"
        for marker in '**Upgrade:**' '**Migration:**'; do
          grep -qF -- "$marker" "$TMP/cl.base" && ! grep -qF -- "$marker" "$TMP/cl.new" \
            && emit "$OUT" WARN changelog "CHANGELOG.md" "the new entry has no $marker block, which the released entries carry"
        done
      fi
    fi
  fi

  # check: secrets       Added lines carry no credential-shaped string
  # check: instance      Added definition lines carry no machine path, e-mail or chat/member id (instance data)
  # check: todo          Added definition lines carry no TODO/FIXME (an agent reads every line as an instruction)
  # check: shell         Added script lines avoid known traps: mkdir locks, payloads in argv, git clean/add -A, unpaged lists, fail-open defaults, fixed temp paths
  # check: enforcement   A new absolute rule (never/must/always/only) in prose while no script, test or config changes
  # check: restated      An added Markdown line already stands, word for word, in another file (one home per rule)
  # check: commands      A doc names `scripts/x.sh <mode>` that the script's dispatcher does not have
  if cut -f2 "$CHANGED" | grep -qE '\.(sh|py|ts|js|ya?ml)$|(^|/)tests?/'; then has_code=1; else has_code=0; fi
  grep -E '\.md$' "$HEAD_LIST" | grep -vE '(^|/)CHANGELOG' > "$TMP/md.docs" || true
  grep_lines "$ROOT" "$TMP/md.docs" > "$TMP/docs.lines"
  jq -R -n -r --arg has_code "$has_code" --rawfile docs "$TMP/docs.lines" '
    def out($l; $c; $m): [$l, $c, "\(.f):\(.n)", $m] | join("\t");
    def squeeze: gsub("[ \t]+"; " ") | sub("^ "; "") | sub(" $"; "");
    def item: sub("^[ \t]*([-*>]|[0-9]+\\.)[ \t]+"; "");
    ($docs | split("\n") | map(capture("^(?<f>[^:]*):(?<n>[0-9]+):(?<t>.*)$")?) | group_by(.f)
      | map({key: .[0].f, value: ([foreach .[] as $l (false; if ($l.t | test("^[ \t]*(```|~~~)")) then not else . end;
              if ($l.t | test("^[ \t]*(```|~~~)")) or . then empty else ($l.t | item | squeeze) end)] | join(" "))})
      | from_entries) as $doc
    | [inputs | capture("^(?<f>[^\t]*)\t(?<n>[0-9]+)\t(?<t>.*)$")?] as $lines
    | ($lines[] | . as $x | .t as $t | .f as $f
      | ($f | test("\\.(md|ya?ml|sh|json|txt|toml|ts|js|py)$")) as $def
      | ($f | test("(^|/)CHANGELOG|check-definition\\.sh$")) as $exempt
      | ($f | test("(^|/)tests?/|(^|/)test_[^/]*$|_test\\.[a-z]+$|\\.bats$")) as $test
      | ($f | test("\\.sh$|(^|/)scripts/") and ($test | not)) as $script
      | (if $t | test("gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|xox[abposr]-[A-Za-z0-9-]{10,}|sk-ant-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{32,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY")
         then (if $test then out("WARN"; "secrets"; "credential-shaped string in a test: confirm the value is fake")
               else out("FAIL"; "secrets"; "credential-shaped string") end) else empty end),
        (select($def and ($exempt | not) and ($test | not))
         | (if ($t | test("(^|[^A-Za-z0-9_$])/(Users|home)/[a-z][a-z0-9_.-]*/")) and ($t | test("/home/agent/") | not)
            then out("WARN"; "instance"; "machine-specific absolute path: a deployed agent has another home") else empty end),
           (first($t | scan("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}")
              | select(test("@(example\\.(com|org|net)|users\\.noreply\\.github\\.com|noreply\\.)") | not))
            | $x | out("WARN"; "instance"; "e-mail address: instance data belongs in runtime config")),
           (first($t | scan("(?<![A-Za-z0-9])[UCWGD][A-Z0-9]{8,10}(?![A-Za-z0-9])")
              | select(test("[0-9]") and (test("0123|ABCD|XXXX") | not)))
            | . as $id | $x | out("WARN"; "instance"; "chat or member id \($id): instance data belongs in runtime config; examples use placeholders")),
           (if ($t | test("(^|#|<!--|//)[ \t]*([-*][ \t]+)?(TODO|FIXME|XXX)([:( ]|$)")) and ($t | test("TODO\\(creator\\)") | not)
            then out("NOTE"; "todo"; "left for later: an agent reads this line as an instruction") else empty end)),
        (select($script and ($t | test("^[ \t]*#") | not))
         | (if $t | test("(^|[;&|(! \t])mkdir[ \t]+(-[a-z]+[ \t]+)?\"?\\$[A-Za-z_{]*(lock|LOCK|Lock)")
            then out("WARN"; "shell"; "mkdir as a lock: not exclusive on every coreutils (uutils); take the lock with a noclobber file") else empty end),
           (if $t | test("--arg(json)?[ \t]+[A-Za-z_]+[ \t]+\"?\\$\\((gh|curl|cat|git) ")
            then out("WARN"; "shell"; "command output passed in argv: a large payload breaks the argument limit; read it on stdin or with --slurpfile") else empty end),
           (if $t | test("(^|[;&| \t])git[ \t]+(-C[ \t]+[^ \t]+[ \t]+)?clean([ \t]|$)")
            then out("FAIL"; "shell"; "git clean: deletes untracked files, and an agent home holds untracked secrets and state") else empty end),
           (if $t | test("(^|[;&| \t])git[ \t]+(-C[ \t]+[^ \t]+[ \t]+)?add[ \t]+(-A|--all|\\.)([ \t]|$)")
            then out("WARN"; "shell"; "git add of everything: add the named paths, so state and secrets never enter a commit") else empty end),
           (if ($t | test("gh api")) and ($t | test("per_page=|/(pulls|issues|comments|reviews|commits|runs|events)\\b")) and ($t | test("--paginate|page=") | not)
            then out("NOTE"; "shell"; "list read without --paginate: items past the first page are lost silently") else empty end),
           (if ($t | test("2>[ \t]*/dev/null")) and ($t | test("\\|\\|[ \t]*(echo|printf|true|:)|// *(0|\\[\\]|\"\")|:-0\\}"))
            then out("NOTE"; "shell"; "error hidden and replaced by a default: a failed read must not look like a real empty or zero answer") else empty end)),
        (select(($script or ($f | test("\\.md$"))) and ($exempt | not)
           and ($t | test("[\"'"'"'` =(]/tmp/[A-Za-z]")) and ($t | test("mktemp|\\$\\$|RUN_ID|run_id|\\$\\{?[A-Z_]*ID|XXXX") | not))
         | out("NOTE"; "shell"; "fixed /tmp path: two concurrent runs share it, and no sweep may own it; use mktemp or a run-unique name")),
        (select($f | test("\\.md$")) | select($f | test("(^|/)CHANGELOG") | not)
         | ($t | item | squeeze) as $s
         | (select(($s | length) >= 80 and ($t | test("^[ \t]*\\|") | not))
            | first($doc | to_entries[] | select(.key != $f and (.value | contains($s))) | .key) as $other
            | $x | out("WARN"; "restated"; "this line already stands in \($other): keep one home and link to it")),
           (select(($f | test("(^|/)README")) | not) | $t | scan("scripts/[A-Za-z0-9_/.-]+\\.sh\"?[ \t]+([a-z][a-z0-9_-]+)")
            | .[0] as $m | ["CMD", $x.f, ($x.n | tostring), ($x.t | capture("(?<s>scripts/[A-Za-z0-9_/.-]+\\.sh)\"?[ \t]+" + $m + "\\b").s), $m] | join("\t")))),
      ($lines | map(select((.f | test("\\.md$")) and (.f | test("(^|/)(CHANGELOG|README)") | not)
          and (.t | ascii_downcase | test("\\b(never|must|always|only)\\b"))))
        | select($has_code == "0") | group_by(.f)[] | .[:5][]
        | out("NOTE"; "enforcement"; "new rule in prose only: judge whether a silent violation needs a script, test or gate"))
  ' < "$ADDED" > "$TMP/added.out"
  grep -v '^CMD' "$TMP/added.out" >> "$OUT"
  grep '^CMD' "$TMP/added.out" | sort -u | while IFS="$TAB" read -r _ f n s mode; do
    sp="${s#\$HOME/}"
    [ -f "$sp" ] || continue
    grep -qE 'case[[:space:]]+"?\$(\{)?(1|cmd|mode|sub|action)' "$sp" || continue
    grep -qE "(^|[[:space:]|(])$mode(\||\))" "$sp" \
      || emit "$OUT" WARN commands "$f:$n" "names '$sp $mode', and the dispatcher of $sp has no '$mode)' case"
  done

  # check: stale-term    A backticked name the change removed still stands elsewhere (a renamed key, file, mode or event)
  jq -R -n -r --rawfile added "$ADDED" '
    def toks: [scan("`([^`]+)`") | .[0] | select(test("^[A-Za-z0-9_.:/@-]{4,}$") and test("[_./-]|[a-z][A-Z]"))];
    ($added | split("\n") | map((capture("^[^\t]*\t[0-9]+\t(?<t>.*)$")? | .t) | toks) | add // [] | unique) as $kept
    | [inputs | capture("^(?<f>[^\t]*)\t[0-9]+\t(?<t>.*)$")? | select(.f | test("\\.(md|sh|ya?ml)$")) | .t | toks[]]
    | unique - $kept | .[]' < "$REMOVED" > "$TMP/gone"
  if [ -s "$TMP/gone" ]; then
    grep -E '\.(md|sh|ya?ml|json)$' "$HEAD_LIST" | grep -vE '(^|/)CHANGELOG' \
      | tr '\n' '\0' | xargs -0 grep -HoF -f "$TMP/gone" -- 2>/dev/null | sort -u \
      | jq -R -n -r '[inputs | capture("^(?<f>[^:]*):(?<t>.*)$")?] | group_by(.t)[]
          | ["NOTE", "stale-term", .[0].f, "the change removed `\(.[0].t)`, and it still stands in: \([.[].f] | .[:3] | join(", "))"] | join("\t")' >> "$OUT"
  fi

  # check: tests         A changed script has a test that names it, and the change touches a test
  TEST_RE='(^|/)tests?/|(^|/)test_[^/]*$|_test\.[a-z]+$|\.bats$'
  grep -E "$TEST_RE" "$HEAD_LIST" > "$TMP/tests" || true
  if [ -s "$TMP/tests" ]; then
    touched="$(cut -f2 "$CHANGED" | grep -E "$TEST_RE" | head -1)"
    grep -E '\.sh$' "$TMP/changed.present" | grep -vE "$TEST_RE" | while IFS= read -r s; do
      named="$(tr '\n' '\0' < "$TMP/tests" | xargs -0 grep -lF -- "$(basename "$s")" 2>/dev/null | head -1)"
      if [ -z "$named" ]; then
        emit "$OUT" WARN tests "$s" "no test names this script: nothing checks its behavior"
      elif [ -z "$touched" ]; then
        emit "$OUT" NOTE tests "$s" "the script changed and no test did (a test that names it: $named)"
      fi
    done
  fi

  # check: orphan-doc    A new Markdown file is linked or named from another file, or no run ever reads it
  grep -E "^A$TAB.*\.md$" "$CHANGED" | cut -f2 | grep -vE '(^|/)(SKILL|CHANGELOG|README)\.md$' | while IFS= read -r f; do
    [ -f "$f" ] || continue
    hit="$(grep -E '\.(md|sh|ya?ml)$' "$HEAD_LIST" | grep -vxF -- "$f" | grep -vE '(^|/)CHANGELOG' \
      | tr '\n' '\0' | xargs -0 grep -lF -- "$(basename "$f")" 2>/dev/null | head -1)"
    [ -n "$hit" ] || emit "$OUT" WARN orphan-doc "$f" "new file that no other file links or names: no run will read it"
  done

  # A schedule task text restates the procedure of a doc it names: a changed
  # doc with an unchanged task text is a lead for two orders in one run.
  if [ -f kit.yaml ] && ! grep -qx "kit.yaml" <(cut -f2 "$CHANGED"); then
    grep -E '\.md$' "$TMP/changed.present" | grep -vE '(^|/)(CHANGELOG|README|ONBOARDING)\.md$' | while IFS= read -r f; do
      grep -qF -- "$f" kit.yaml \
        && emit "$OUT" NOTE kit "$f" "a schedule task text in kit.yaml names this doc, and the change leaves the task text as it is: check that both still give one order"
    done
  fi

  # check: size          Any growth of an always-loaded entry file; growth of 20+ lines of another Markdown file
  grep -E '\.md$' "$TMP/changed.present" | while IFS= read -r f; do
    nw="$(wc -l < "$f" | tr -d ' ')"
    od=0; [ -f "$TMP/base/$f" ] && od="$(wc -l < "$TMP/base/$f" | tr -d ' ')"
    [ "$nw" -gt "$od" ] || continue
    case "$f" in
      CLAUDE.md|AGENTS.md|GEMINI.md|*/CLAUDE.md|*/AGENTS.md)
        emit "$OUT" WARN size "$f" "always-loaded entry file grew $od -> $nw lines: every run pays for it; move procedure text to an on-demand doc" ;;
      *) [ "$od" -gt 0 ] && [ $((nw - od)) -ge 20 ] && emit "$OUT" NOTE size "$f" "$od -> $nw lines (+$((nw - od))): growth outside the new concept's one home is restated text" ;;
    esac
  done
fi

# ------------------------------------------------------------------- report ----
sort -u "$OUT" | sort -t"$TAB" -s -k2,2 > "$TMP/sorted"
for level in FAIL WARN NOTE; do grep "^$level$TAB" "$TMP/sorted"; done
nf="$(grep -c "^FAIL$TAB" "$TMP/sorted")"; nw="$(grep -c "^WARN$TAB" "$TMP/sorted")"; nn="$(grep -c "^NOTE$TAB" "$TMP/sorted")"
echo "check-definition: $nf fail, $nw warn, $nn note"
[ "$nf" -eq 0 ]
