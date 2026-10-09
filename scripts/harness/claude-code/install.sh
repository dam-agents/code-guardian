#!/usr/bin/env bash
# Claude Code harness adapter — registers the adapter hooks in
# ~/.claude/settings.json (idempotent; contract: docs/logging.md → Harness
# adapters): log-tool-event.sh on PostToolUseFailure + PostToolUse,
# log-review-step.sh on PostToolUse (Bash|Task), log-session-tokens.sh on
# SessionEnd, enforce-review-completion.sh on Stop, guard-definition-issue.sh
# on PreToolUse (Bash). It also keeps the auto-mode classifier rules for the
# agent's documented writes (autoMode.environment / autoMode.allow, entries
# tagged [code-guardian]),
# the tool deny list (permissions.deny ← denied-tools.txt, so the unused
# tools' definitions leave every request) and the `review-skill` subagent type
# (~/.claude/agents/review-skill.md ← agents/review-skill.md).
# On any other harness it prints a notice and exits 0 — the agent then logs
# tool failures manually per docs/logging.md. Changes take effect from the
# next session.
#
#   install.sh           # install or refresh
#   install.sh --check   # print the parts not current (tool-deny, skill-agent), or nothing
set -u

CHECK=0; [ "${1:-}" = "--check" ] && CHECK=1
if [ "${CLAUDECODE:-}" != "1" ]; then
  [ "$CHECK" = 1 ] && exit 0
  echo "not the Claude Code harness (CLAUDECODE != 1) — no hooks installed; manual tool-failure logging applies (docs/logging.md)"
  exit 0
fi
command -v jq >/dev/null 2>&1 || { [ "$CHECK" = 1 ] || echo "jq missing — cannot install hooks"; exit 0; }

SETTINGS="${HOME:-/home/agent}/.claude/settings.json"
ADAPTER_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$ADAPTER_DIR/log-tool-event.sh"
TOKENS="$ADAPTER_DIR/log-session-tokens.sh"
FINISH="$ADAPTER_DIR/enforce-review-completion.sh"
STEPS="$ADAPTER_DIR/log-review-step.sh"
GUARD="$ADAPTER_DIR/guard-definition-issue.sh"
AGENT_SRC="$ADAPTER_DIR/agents/review-skill.md"
AGENT_DST="$(dirname "$SETTINGS")/agents/review-skill.md"
# the deny entries this script wrote last time, so a name dropped from
# denied-tools.txt leaves settings.json too (the operator's entries stay)
OWNED="$(dirname "$SETTINGS")/.code-guardian-denied-tools.json"

# denied-tools.txt: one tool name per line, `#` comments
DENY="$(sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//' "$ADAPTER_DIR/denied-tools.txt" 2>/dev/null \
  | jq -Rsc 'split("\n") | map(select(length > 0))' 2>/dev/null)"
[ -n "$DENY" ] || DENY='[]'
PREV="$(jq -c 'if type == "array" then map(strings) else [] end' "$OWNED" 2>/dev/null)"
[ -n "$PREV" ] || PREV='[]'

if [ "$CHECK" = 1 ]; then
  missing=""
  jq -e --argjson d "$DENY" '($d - (.permissions.deny // [])) == []' "$SETTINGS" >/dev/null 2>&1 \
    || missing="$missing tool-deny"
  cmp -s "$AGENT_SRC" "$AGENT_DST" || missing="$missing skill-agent"
  printf '%s\n' "${missing# }"
  exit 0
fi

chmod +x "$SCRIPT" "$TOKENS" "$FINISH" "$STEPS" "$GUARD" "$ADAPTER_DIR/../../log.sh" 2>/dev/null || true

mkdir -p "$(dirname "$SETTINGS")"
[ -s "$SETTINGS" ] || echo '{}' > "$SETTINGS"

# auto-mode classifier rules: the classifier blocks an issue on a repo other
# than the target and an upload of a local file unless it knows both are the
# agent's documented work (docs/logging.md → Harness adapters). The slugs come
# from work/CONFIG.md; the definition repo falls back to $HOME's origin, so
# Step 1b works before the config exists.
HOME_DIR="${HOME:-/home/agent}"
CONFIG="$HOME_DIR/work/CONFIG.md"
. "$ADAPTER_DIR/../../lib/common.sh"
DEF="$(cfg definition_repo)"
[ -n "$DEF" ] || DEF="$(origin_ref "$HOME_DIR")"
case "$DEF" in (github.com/*) DEF="${DEF#github.com/}";; esac
TARGET="$(cfg github_repo)"
AM_ENV="$(jq -nc --arg d "$DEF" --arg r "$TARGET" --arg h "$HOME_DIR" '[
  "[code-guardian] This is an unattended code review agent. It reviews pull requests on \(if $r == "" then "the github_repo of \($h)/work/CONFIG.md" else $r end)\(if $d == "" then "" else ", and its own definition repository is \($d)" end).",
  "[code-guardian] The DAM Artifact Library is a publish surface the operator configured. Its create_artifact_upload_url tool returns a presigned upload URL for one file."]')"
AM_ALLOW="$(jq -nc --arg d "$DEF" --arg h "$HOME_DIR" '
  (if $d == "" then [] else
    ["[code-guardian] Opening an anonymous tracking issue on \($d) with bash \($h)/scripts/definition-issue.sh file: the weekly audit and the channel-refused rule file them there, and the script checks the definition_issues switch and scans the draft for instance data before it sends anything."] end)
  + ["[code-guardian] Uploading a file under \($h)/work/audit/ or \($h)/work/reviews/pr-artifacts/ with curl -X PUT --data-binary to the URL that create_artifact_upload_url returned in the same session.",
     "[code-guardian] Starting a review of one pull request in a session of its own with mcp__platform-outbound__schedule_once, passing exactly the name, task and model that scripts/dispatch.sh plan printed in the same session: a review run hands every PR after its first to a one-time session that runs at once."]')"
[ -n "$DEF" ] || echo "definition repo unresolved — tracking-issue rule left out; re-run once work/CONFIG.md has definition_repo"

tmp="$(mktemp)"
if ! jq --arg c "$SCRIPT" --arg t "$TOKENS" --arg f "$FINISH" --arg s "$STEPS" --arg g "$GUARD" \
      --argjson e "$AM_ENV" --argjson a "$AM_ALLOW" --argjson deny "$DENY" --argjson prev "$PREV" '
    # own entries are replaced, the operator'"'"'s kept; a new list keeps the
    # built-in rules through "$defaults"
    def am($k; $new): .autoMode[$k] = (((.autoMode[$k] // ["$defaults"])
        | map(select(type != "string" or (startswith("[code-guardian]") | not)))) + $new);
    .autoMode //= {} | am("environment"; $e) | am("allow"; $a) |
    .hooks //= {} |
    .hooks.PostToolUseFailure = ([.hooks.PostToolUseFailure[]?
        | select([.hooks[]?.command] | index($c) | not)]
      + [{matcher:"*", hooks:[{type:"command", command:$c, timeout:15}]}]) |
    .hooks.PostToolUse = ([.hooks.PostToolUse[]?
        | select([.hooks[]?.command] | index($c) | not)
        | select([.hooks[]?.command] | index($s) | not)]
      + [{matcher:"Bash|mcp__.*", hooks:[{type:"command", command:$c, timeout:15}]}]
      + [{matcher:"Bash|Task", hooks:[{type:"command", command:$s, timeout:15}]}]) |
    .hooks.SessionEnd = ([.hooks.SessionEnd[]?
        | select([.hooks[]?.command] | index($t) | not)]
      + [{hooks:[{type:"command", command:$t, timeout:30}]}]) |
    .hooks.Stop = ([.hooks.Stop[]?
        | select([.hooks[]?.command] | index($f) | not)]
      + [{hooks:[{type:"command", command:$f, timeout:15}]}]) |
    .hooks.PreToolUse = ([.hooks.PreToolUse[]?
        | select([.hooks[]?.command] | index($g) | not)]
      + [{matcher:"Bash", hooks:[{type:"command", command:$g, timeout:10}]}]) |
    # tool deny list: own entries (this and the previous install) are replaced
    # in place of their old position at the end, the operator'"'"'s kept in order
    if ($deny | length) > 0 or ((.permissions.deny // []) | any(. as $x | $prev | index([$x])))
    then .permissions.deny = ([(.permissions.deny // [])[] | select(. as $x | ($prev + $deny) | index([$x]) | not)] + $deny)
    else . end
  ' "$SETTINGS" > "$tmp"; then
  rm -f "$tmp"
  echo "hook install did not complete — settings.json left unchanged"
  exit 0
fi

settings_same=0
jq -e -n --slurpfile old "$SETTINGS" --slurpfile new "$tmp" '$old == $new' >/dev/null 2>&1 && settings_same=1
agent_same=0
cmp -s "$AGENT_SRC" "$AGENT_DST" && agent_same=1

if [ "$settings_same" = 1 ]; then
  rm -f "$tmp"
else
  mv "$tmp" "$SETTINGS"
fi
printf '%s\n' "$DENY" > "$OWNED" 2>/dev/null || true
if [ "$agent_same" = 0 ] && [ -f "$AGENT_SRC" ]; then
  mkdir -p "$(dirname "$AGENT_DST")" && cp "$AGENT_SRC" "$AGENT_DST" \
    || echo "review-skill agent not installed — the skill fan-out uses the default subagent"
fi

if [ "$settings_same" = 1 ] && [ "$agent_same" = 1 ]; then
  echo "hooks, auto-mode rules, tool deny list and review-skill agent already installed ($SETTINGS)"
else
  echo "installed into $SETTINGS: hooks (PostToolUseFailure + PostToolUse -> $SCRIPT; PostToolUse Bash|Task -> $STEPS; SessionEnd -> $TOKENS; Stop -> $FINISH; PreToolUse Bash -> $GUARD), [code-guardian] rules -> autoMode.environment + autoMode.allow, $(printf '%s' "$DENY" | jq 'length') tools -> permissions.deny; review-skill agent -> $AGENT_DST"
fi
exit 0
