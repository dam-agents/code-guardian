#!/usr/bin/env bash
# review-worklist.sh — the work list one automated review leaves on one pull
# request, as one JSON object (SKILL.md → "1. Read the review").
#
#   review-worklist.sh <owner/repo> <pr-number> [--reviewer <login>]
#
# REST only (`gh api`), bash 3.2+, jq. Reads the PR's reviews, keeps the ones
# that carry a `<!-- findings-json: … -->` line — `--reviewer` keeps one
# login's only — and prints for the newest of them:
#   review            id, author, state, submitted_at, commit_id (the reviewed
#                     SHA), html_url, has_meta (a `review-meta` line parsed)
#   head              the PR's live head {sha, ref, base}
#   branch_moved      the branch moved after the review was posted
#   pr_body           the PR description as it is now
#   blocking          critical|warning entries with status new|still, critical
#                     first; each with `also` (further locations of the same
#                     finding) and `check` {run, clean} when the review carries
#                     one whose `for` is this finding's summary
#   optional          the suggestion entries still open
#   deferred          the suggestions the review dropped under its budget
#   checks_unmatched  checks whose `for` matches no blocking summary
#   rules             every distinct Fix the reviewer stated on this PR in any
#                     round, oldest first; `current` = in this round's blocking
#                     set. A Fix stated once binds every later edit too.
#   rereview          how the next round is requested: `trigger` with `label`
#                     and/or `login` from review-meta (`source: review`), else
#                     a review request to the review's author (`fallback`)
#   inline            the review's inline comments {path, line, body} — the
#                     full text and suggestion blocks behind each summary
#   authors           logins that posted findings-json reviews; author_check
#                     is "multiple" when there is more than one and no
#                     --reviewer narrowed them
# A ` – ` (en dash between spaces) inside a check's `run` is a ` -- ` the
# review's transport rewrote for HTML-comment safety; it is restored here.
# Exit 0 with outcome "ok" | "no_review"; exit 1 with outcome "error". API
# payloads reach jq through files, never through argv.
set -u

REPO=""; N=""; REVIEWER=""
while [ $# -gt 0 ]; do
  case "$1" in
    (--reviewer) REVIEWER="${2:-}"; shift 2;;
    (-h|--help) sed -n '2,34p' "$0"; exit 0;;
    (*) if [ -z "$REPO" ]; then REPO="$1"; elif [ -z "$N" ]; then N="$1"; fi; shift;;
  esac
done

err() { jq -nc --arg e "$1" '{outcome:"error", error:$e}' 2>/dev/null || printf '{"outcome":"error","error":"%s"}\n' "$1"; exit 1; }
command -v jq >/dev/null 2>&1 || err "jq is required"
command -v gh >/dev/null 2>&1 || err "gh is required"
[ -n "$REPO" ] && [ -n "$N" ] || err "usage: review-worklist.sh <owner/repo> <pr-number> [--reviewer <login>]"
case "$N" in (''|*[!0-9]*) err "pr-number must be a number, got '$N'";; esac

T="$(mktemp -d "${TMPDIR:-/tmp}/review-worklist.XXXXXX")" || err "cannot create a temp dir"
trap 'rm -rf "$T"' EXIT

# every page of reviews; a page under 100 entries is the last one
page=1
while :; do
  gh api "repos/$REPO/pulls/$N/reviews?per_page=100&page=$page" > "$T/reviews.$page.json" 2>"$T/err" \
    || err "reviews page $page: $(tr '\n' ' ' < "$T/err" | cut -c1-300)"
  jq -e 'type == "array"' "$T/reviews.$page.json" >/dev/null 2>&1 || err "reviews page $page is not a list"
  [ "$(jq length "$T/reviews.$page.json")" -ge 100 ] && [ "$page" -lt 20 ] || break
  page=$((page + 1))
done
jq -s 'add' "$T"/reviews.*.json > "$T/reviews.json"

gh api "repos/$REPO/pulls/$N" > "$T/pr.json" 2>"$T/err" \
  || err "pull request: $(tr '\n' ' ' < "$T/err" | cut -c1-300)"
jq -e '.head.sha' "$T/pr.json" >/dev/null 2>&1 || err "the pull request payload has no head"

jq -c --arg r "$REVIEWER" '
  map(select(((.body // "") | test("<!-- findings-json: ")) and ($r == "" or .user.login == $r)))
  | sort_by(.submitted_at)' "$T/reviews.json" > "$T/rounds.json"
if [ "$(jq length "$T/rounds.json")" -eq 0 ]; then
  jq -nc --arg repo "$REPO" --argjson n "$N" '{outcome:"no_review", repo:$repo, pr:$n}'; exit 0
fi

rid="$(jq -r '.[-1].id' "$T/rounds.json")"
gh api "repos/$REPO/pulls/$N/reviews/$rid/comments?per_page=100" > "$T/inline.json" 2>/dev/null || printf '[]' > "$T/inline.json"
jq -e 'type == "array"' "$T/inline.json" >/dev/null 2>&1 || printf '[]' > "$T/inline.json"

jq -n --arg repo "$REPO" --argjson n "$N" \
  --slurpfile rounds "$T/rounds.json" --slurpfile pr "$T/pr.json" --slurpfile inl "$T/inline.json" '
  # the JSON never holds a `--`, so the first ` -->` after the key closes it
  def hidden($b; $k): [ ($b // "") | capture("<!-- " + $k + ": (?<j>.*?) -->") | .j ] | first;
  def parse_findings($b): (hidden($b; "findings-json") as $j
    | if $j == null then [] else (try ($j | fromjson) catch []) end)
    | if type == "array" then map(select(type == "object")) else [] end;
  def parse_meta($b): (hidden($b; "review-meta") as $j
    | if $j == null then null else (try ($j | fromjson) catch null) end)
    | if type == "object" then . else null end;
  def open_status: ((.status // "new") | IN("new", "still"));
  def unhide: if type == "string" then gsub(" – "; " -- ") else . end;

  ($rounds[0]) as $rs | ($pr[0]) as $p | ($inl[0]) as $inline
  | ($rs[-1]) as $rev
  | parse_findings($rev.body) as $f
  | parse_meta($rev.body) as $m
  | ([ ($m.checks // [])[] | select(type == "object") | .run = (.run | unhide) ]) as $checks
  | ([ $f[] | select((.severity | IN("critical", "warning")) and open_status)
        | .also = ((.also // []) | map(select(type == "object")))
        | . as $x | .check = ([ $checks[] | select(.for == $x.summary) | {run, clean} ] | first) ]
     | map(select(.severity == "critical")) + map(select(.severity == "warning"))) as $blocking
  | ([ $f[] | select(.severity == "suggestion" and open_status) ]) as $optional
  | ([ $checks[] | . as $c | select(([ $blocking[] | select(.summary == $c.for) ] | length) == 0) ]) as $unmatched
  | ([ $rs | to_entries[] | .key as $i | .value.body | parse_findings(.)[]
        | select((.fix // "") != "") | {round: ($i + 1), severity, file, summary, fix} ]
     | group_by(.fix) | map(min_by(.round)) | sort_by(.round)
     | map(. as $r | . + {current: any($blocking[]; .fix == $r.fix)})) as $rules
  | (if (($m.rereview // null) | type) == "object"
     then ($m.rereview | {trigger: (.trigger // "label"), label: (.label // null), login: (.login // null), source: "review"})
     else {trigger: "review-request", label: null, login: $rev.user.login, source: "fallback"} end) as $rr
  | ([ $rs[].user.login ] | unique) as $authors
  | {outcome: "ok", repo: $repo, pr: $n,
     review: {id: $rev.id, author: $rev.user.login, state: $rev.state, submitted_at: $rev.submitted_at,
              commit_id: $rev.commit_id, html_url: $rev.html_url, has_meta: ($m != null)},
     rounds: ($rs | length), authors: $authors,
     author_check: (if ($authors | length) > 1 then "multiple" else "ok" end),
     head: {sha: $p.head.sha, ref: $p.head.ref, base: $p.base.ref},
     branch_moved: ($p.head.sha != $rev.commit_id),
     pr_body: ($p.body // ""),
     blocking: $blocking, optional: $optional, deferred: ($m.deferred // []),
     checks_unmatched: $unmatched, rules: $rules, rereview: $rr,
     inline: [ $inline[] | select(type == "object") | {path, line: (.line // .original_line), body} ]}' \
  || err "the worklist could not be assembled"
