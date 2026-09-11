#!/usr/bin/env bash
# A GitHub list payload never reaches jq through argv. One argv entry is capped
# at MAX_ARG_STRLEN (128 KiB, independent of ARG_MAX) and one page of comment
# bodies clears that alone, so `--arg`/`--argjson` on a `gh api` body dies with
# "Argument list too long" — on stderr, which no log file records — and the
# caller's `|| X='[]'` turns the failure into a value no reader can tell from a
# quiet week. Payloads travel on stdin, in a file, or through `--slurpfile`.
# This case is the mechanical form of that rule (#76, #102).
. "$(dirname "$0")/helpers.sh"

# the variables bound to a whole, unfiltered `gh api` body — a substitution
# that pipes the body through jq or a function yields a reduction of it, and
# that is what a reduction is for
payload_vars() { # <script> → one variable name per line
  local line v i j piped
  local -a L=()
  while IFS= read -r line; do L+=("$line"); done < "$1"
  for ((i = 0; i < ${#L[@]}; i++)); do
    case "${L[i]}" in (*'="$(gh api'*|*'=$(gh api'*) ;; (*) continue;; esac
    v="${L[i]#"${L[i]%%[! 	]*}"}"; v="${v%%=*}"
    case "$v" in (''|*[!A-Za-z0-9_]*) continue;; esac
    piped=0
    case "${L[i]}" in (*' | '*|*'|jq'*) piped=1;; esac
    # the substitution can span lines; scan to the line that closes it
    for ((j = i + 1; j < i + 14 && j < ${#L[@]}; j++)); do
      case "${L[j - 1]}" in (*')"'*) break;; esac
      case "${L[j]}" in (*'| '*|*'|jq'*) piped=1;; esac
    done
    [ "$piped" -eq 0 ] && printf '%s\n' "$v"
  done | sort -u
}

argv_payloads() { # <script> → one `file:line` per offending use
  local v
  for v in $(payload_vars "$1"); do
    grep -nE -- "--(arg|argjson)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+\"\\\$\{?$v\}?\"" "$1" \
      | sed "s|^|$1:|"
  done
}

# --- the detector sees the shape that shipped twice -------------------------
new_case argv_detector
cat > "$SANDBOX/bad.sh" <<'BAD'
all='[]'
body="$(gh api "repos/$REPO/issues/comments?per_page=100&page=$page" 2>/dev/null)"
all="$(jq -nc --argjson a "$all" --argjson b "$body" '$a + $b')"
BAD
OUT="$(argv_payloads "$SANDBOX/bad.sh")"
assert_out_contains 'argjson b' 'a gh api body passed to jq in argv is reported'

cat > "$SANDBOX/good.sh" <<'GOOD'
body="$(gh api "repos/$REPO/issues/comments?per_page=100&page=$page" 2>/dev/null)"
printf '%s' "$body" | jq -c '.[]' >> "$out"
n="$(gh api "repos/$REPO/pulls/$n" 2>/dev/null | jq -r '.number')"
jq -n --arg n "$n" '{number:$n}'
GOOD
OUT="$(argv_payloads "$SANDBOX/good.sh")"
assert_out_absent '.' 'a body read on stdin, and a scalar taken from one, are not reported'

# --- and the scripts that call gh api are clean -----------------------------
new_case argv_payload_free
for s in preflight.sh review-pr.sh profile.sh work-backup.sh benchmark-phase.sh; do
  [ -f "$REPO_ROOT/scripts/$s" ] || continue
  OUT="$(argv_payloads "$REPO_ROOT/scripts/$s")"
  assert_out_absent '.' "scripts/$s passes no gh api payload through argv"
done

finish
