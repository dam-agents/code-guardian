#!/usr/bin/env bash
# monitor-direct.sh — the monitor's direct delivery: the due alerts as one
# Slack DM to the escalation owner, sent by the monitor's pass itself, with no
# model in the loop (docs/monitor.md → **Direct delivery**). The one script
# that sends on its own.
#
#   monitor-direct.sh render <alerts.json>   -> {text, ids, skipped, url} — pure
#   monitor-direct.sh send <alerts.json>     -> {status, ids, reason, attempted}
#   monitor-direct.sh ready                  -> why a send cannot happen; empty when it can
#
# status: sent | unknown | failed | off | capped | none. `unknown` — the call
# went out and no answer came back; its ids are held, never sent twice in one
# tick. `attempted` marks a call that reached the endpoint; each counts
# against the daily cap. `send` records nothing in the alert ledger —
# monitor.sh acknowledges the sent ids and counts the attempt. The templates,
# type checks and text check: docs/monitor.md → Direct delivery.

set -u
export LC_ALL=C

MODE="${1:-}"; FILE="${2:-}"
HOME_DIR="${HOME:-/home/agent}"
WORK="${WORK_DIR:-$HOME_DIR/work}"
CONFIG="$WORK/CONFIG.md"
STATE="$WORK/MONITOR.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NOW_EPOCH=$(date -u +%s)

. "$SCRIPT_DIR/lib/common.sh"
. "$SCRIPT_DIR/lib/mcp.sh"

DIRECT_KINDS='["model_unavailable","model_recovered","github_unavailable","github_recovered",
  "heartbeat_gap","harness_drift","backup_failing","classifier_spike","review_post_blocked"]'
MAX_ALERTS=10        # alerts in one message; the rest stay for the session
DAILY_CAP=12         # direct messages in 24 h; past it the session delivers
MAX_CHARS=3500

out() { jq -nc "$@"; }

render() { # <alerts.json>
  local name url
  # the display name and the share URL: one line each, checked whole
  # (\A…\z: a `$` would also match before a trailing newline)
  name="$(jq -rn --arg n "$(cfg bot_display_name)" '$n | select(test("\\A[A-Za-z0-9][A-Za-z0-9 _-]{0,39}\\z")) // "Code Guardian"')"
  url="$(jq -r '.share_url // "" | strings
    | select(test("\\Ahttps://[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+(:[0-9]{1,5})?/[A-Za-z0-9/_~%=&-]{1,200}\\z"))' \
    "$WORK/health/state.json" 2>/dev/null)"
  jq -c --arg name "$name" --arg url "$url" --argjson kinds "$DIRECT_KINDS" --argjson max "$MAX_ALERTS" '
    def ts: if type == "string" and test("\\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2}(\\.[0-9]+)?)?Z\\z")
            then .[0:10] + " " + .[11:16] + " UTC" else error("ts") end;
    def int: if type == "number" and . >= 0 and . == floor and . < 1e9 then tostring else error("int") end;
    def word: if type == "string" and test("\\A[a-z][a-z0-9_]{0,39}\\z") then . else error("word") end;
    def tool: if type == "string" and test("\\A[A-Za-z][A-Za-z0-9_-]{0,63}\\z") then . else "other" end;
    def counts(f): if type == "object" and length > 0 then to_entries | sort_by(-.value) | .[0:5]
                     | map("\(.key | f) \(.value | int)") | join(", ") else error("counts") end;
    def top: if type == "object" then to_entries | max_by(.value) | .key | word else error("top") end;
    def model_hint: if IN("authentication_failed", "cloud_credential_error") then "the credentials. The operator must fix them"
                    elif IN("rate_limit", "billing_error") then "the quota or the budget"
                    else "the model provider or the gateway" end;
    def gh_hint: if . == "auth" then "the GitHub token is not valid. The operator must replace it"
                 elif . == "access" then "the token cannot read the repository. The operator must examine its access"
                 elif . == "rate_limit" then "the GitHub API rate limit"
                 else "GitHub or the network" end;
    def parts: if type == "array" and length > 0
                 and all(.[]; IN("hooks", "automode-rules", "tool-deny", "skill-agent"))
               then join(", ") else error("parts") end;
    def line:
      if .kind == "model_unavailable" then
        if .open then "**Model API unavailable** since \(.first | ts): \(.count | int) failures in \(.runs | int) runs (\(.errors | counts(word))). The last failure was at \(.last | ts). Cause: \(.errors | top | model_hint). The agent does the missed review work after the API recovers."
        else "**Model API was unavailable** from \(.first | ts) to \(.last | ts): \(.count | int) failures in \(.runs | int) runs (\(.errors | counts(word))). Cause: \(.errors | top | model_hint)." end
      elif .kind == "model_recovered" then
        "**Model API available again.** The outage started at \(.first | ts). The last failure was at \(.last | ts)."
      elif .kind == "github_unavailable" then
        if .open then "**GitHub API unavailable** since \(.first | ts): \(.count | int) gate passes in a row could not list the open PRs (\(.errors | counts(word))). Cause: \(.errors | top | gh_hint)."
        else "**GitHub API was unavailable** from \(.first | ts) to \(.last | ts): \(.count | int) gate passes could not list the open PRs (\(.errors | counts(word))). Cause: \(.errors | top | gh_hint)." end
      elif .kind == "github_recovered" then
        "**GitHub API available again** at \(.over_at | ts), after \(.minutes | int) min."
      elif .kind == "heartbeat_gap" then
        "**Review gate silent:** no tick since \(.last | ts) (\(.silent_minutes | int) min, limit \(.limit_minutes | int) min). Do this: make sure that the review schedule is enabled and that its gate can start."
      elif .kind == "harness_drift" then
        "**Harness adapter not current:** \(.parts | parts). Do this: run `bash \"$HOME/scripts/harness/claude-code/install.sh\"`. The change applies from the next session."
      elif .kind == "backup_failing" then
        "**Work backup failing:** \(.failures | int) failed pushes since \(.first | ts). Do this: examine the access to the work repository."
      elif .kind == "classifier_spike" then
        "**Classifier refusals:** \(.count | int) in 24 h (threshold \(.threshold | int)) in \(.runs | int) runs. Tools: \(.by_tool | counts(tool)). The events log has the patterns (event classifier_block)."
      elif .kind == "review_post_blocked" then
        "**Review post refused:** the classifier refused the review post of PR #\(.pr | int) at \(.ts | ts). No later post of that PR exists. Do this: post the review again in a session, or add the missing auto-mode rule."
      else error("kind") end;
    [ .[] | select(.kind as $k | $kinds | index($k)) | {id, l: (try line catch null)} ] as $r
    | [ $r[] | select(.l != null and (.id | type) == "string") ][0:$max] as $ok
    | {ids: [$ok[].id], url: $url,
       skipped: ([.[] | .id] - [$ok[].id]),
       text: (if ($ok | length) == 0 then ""
              else "**\($name) monitor** — \($ok | length) alert\(if ($ok | length) > 1 then "s" else "" end)\n"
                   + ([$ok[] | "• " + .l] | join("\n"))
                   + (if $url != "" then "\nDashboard: \($url)" else "" end) end)}' "$1"
}

# the finished text: nothing a template cannot produce. The share URL line is
# the one render validated, and only as the last line.
text_ok() { # <text> <validated url or empty>
  local body="$1"
  [ "${#1}" -le "$MAX_CHARS" ] || return 1
  if [ -n "$2" ]; then
    case "$2" in (*[!A-Za-z0-9:/._~%=\&-]*) return 1;; esac
    case "$1" in (*$'\n'"Dashboard: $2") body="${1%$'\n'"Dashboard: $2"}";; (*) return 1;; esac
  fi
  printf '%s' "$body" | grep -Eqi '[<>@]|https?:|```|www\.|Dashboard:' && return 1
  return 0
}

# why the opt-in cannot send, or nothing; the escalation owner's id on fd 3
gate_reason() {
  local eo sid
  [ "$(cfg monitor_slack_direct)" = enabled ] || { printf 'monitor_slack_direct is not enabled'; return; }
  [ "$(cfg slack_notifications)" = enabled ] || { printf 'slack_notifications is not enabled'; return; }
  eo="$(cfg escalation_owner)"
  sid="$(roster_tsv "$WORK/DEVELOPERS.md" | while IFS="$(printf '\t')" read -r l s; do [ "$l" = "$eo" ] && printf '%s\n' "$s"; done | head -1)"
  if [ -z "$eo" ] || ! printf '%s' "$sid" | grep -Eq "$SLACK_ID_RE"; then printf 'escalation_owner has no roster slack_id'; return; fi
  printf '%s' "$sid" >&3
}

case "$MODE" in
  ready) gate_reason 3>/dev/null; exit 0;;
  render)
    [ -r "$FILE" ] || { out '{error: "render needs the alerts file"}'; exit 2; }
    render "$FILE"; exit 0;;
  send) ;;
  *) out '{error: "use monitor-direct.sh render|send <alerts.json>"}'; exit 2;;
esac

[ -r "$FILE" ] || { out '{status: "failed", ids: [], reason: "alerts file unreadable"}'; exit 0; }
SID_FILE="$(mktemp "${TMPDIR:-/tmp}/cg-direct.XXXXXX")" || { out '{status: "failed", ids: [], reason: "no scratch file"}'; exit 0; }
WHY="$(gate_reason 3>"$SID_FILE")"; SID="$(cat "$SID_FILE")"; rm -f "$SID_FILE"
SID="$(printf '%s' "$SID" | head -1)"
[ -z "$WHY" ] || { out --arg why "$WHY" '{status: "off", ids: [], reason: $why}'; exit 0; }

R="$(render "$FILE")"
[ -n "$R" ] || R='{"text":"","ids":[],"skipped":[]}'
TEXT="$(printf '%s' "$R" | jq -r '.text // ""')"
IDS="$(printf '%s' "$R" | jq -c '.ids // []')"
[ -n "$TEXT" ] || { out --argjson r "$R" '{status: "none", ids: [], skipped: ($r.skipped // []), reason: "no alert renders"}'; exit 0; }
URL="$(printf '%s' "$R" | jq -r '.url // ""')"
if ! text_ok "$TEXT" "$URL"; then
  out --argjson ids "$IDS" '{status: "failed", ids: [], reason: "the rendered text failed its check", held: $ids}'; exit 0
fi

SENT_24H="$(jq --argjson now "$NOW_EPOCH" '[.direct[]? | select(type == "number" and . > $now - 86400)] | length' "$STATE" 2>/dev/null)"
if [ "${SENT_24H:-0}" -ge "$DAILY_CAP" ]; then
  out --argjson n "$SENT_24H" '{status: "capped", ids: [], reason: "\($n) direct messages in 24 h"}'; exit 0
fi

ARGS="$(mktemp "${TMPDIR:-/tmp}/cg-direct.XXXXXX")" || { out '{status: "failed", ids: [], reason: "no scratch file"}'; exit 0; }
trap 'rm -f "$ARGS"' EXIT
jq -nc --arg t "$TEXT" --arg c "$SID" '{channel: "slack", chatId: $c, text: $t}' > "$ARGS"
RES="$(mcp_call send_channel_message "$ARGS")"; RC=$?
case "$RC" in
  (0) out --argjson ids "$IDS" '{status: "sent", ids: $ids, attempted: true}';;
  (1) out '{status: "failed", ids: [], reason: "no platform-outbound endpoint"}';;
  (2) out '{status: "failed", ids: [], reason: "transport failure"}';;
  (4) out --argjson ids "$IDS" '{status: "unknown", ids: $ids, attempted: true, reason: "no answer after the call went out"}';;
  (*) out --arg why "$(printf '%s' "$RES" | tr '\n' ' ' | cut -c1-200)" '{status: "failed", ids: [], attempted: true, reason: "refused: \($why)"}';;
esac
exit 0
