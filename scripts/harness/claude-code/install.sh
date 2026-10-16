#!/usr/bin/env bash
# Claude Code harness adapter — keeps four parts current in ~/.claude
# (idempotent; what each part is: docs/logging.md → Harness adapters): the
# adapter hooks in settings.json, the [code-guardian] auto-mode classifier
# rules (autoMode.environment / autoMode.allow), the tool deny list
# (permissions.deny ← denied-tools.txt) and the `review-skill` subagent type
# (agents/review-skill.md). On any other harness it prints a notice and exits
# 0. Changes take effect from the next session.
#
#   install.sh           # install or refresh
#   install.sh --check   # print the parts not current (hooks, automode-rules,
#                        # tool-deny, skill-agent), or nothing
set -u

CHECK=0; [ "${1:-}" = "--check" ] && CHECK=1
if [ "${CLAUDECODE:-}" != "1" ]; then
  [ "$CHECK" = 1 ] && exit 0
  echo "not the Claude Code harness (CLAUDECODE != 1) — no Claude Code hooks installed; the adapter of this harness applies (docs/logging.md → Harness adapters)"
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
DENIED="$ADAPTER_DIR/log-permission-denied.sh"
APIFAIL="$ADAPTER_DIR/log-api-failure.sh"
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

# auto-mode classifier rules: the classifier blocks an issue on a repo other
# than the target, an upload of a local file, and the review steps it saw
# most (the review post, the skill subagent, the backup, the scratch cleanup;
# docs/monitor.md counts what it still blocks) unless it knows they are the
# agent's documented work (docs/logging.md → Harness adapters). The slugs come
# from work/CONFIG.md; the definition repo falls back to $HOME's origin, so
# Step 1b works before the config exists.
HOME_DIR="${HOME:-/home/agent}"
CONFIG="${WORK_DIR:-$HOME_DIR/work}/CONFIG.md"
. "$ADAPTER_DIR/../../lib/common.sh"
DEF="$(cfg definition_repo)"
[ -n "$DEF" ] || DEF="$(origin_ref "$HOME_DIR")"
case "$DEF" in (github.com/*) DEF="${DEF#github.com/}";; esac
TARGET="$(cfg github_repo)"
AM_ENV="$(jq -nc --arg d "$DEF" --arg r "$TARGET" --arg h "$HOME_DIR" '[
  "[code-guardian] This is an unattended code review agent. It reviews pull requests on \(if $r == "" then "the github_repo of \($h)/work/CONFIG.md" else $r end)\(if $d == "" then "" else ", and its own definition repository is \($d)" end).",
  "[code-guardian] The DAM Artifact Library is a publish surface the operator configured. Its create_artifact_upload_url tool returns a presigned upload URL for one file."]')"
AM_ALLOW="$(jq -nc --arg d "$DEF" --arg r "$TARGET" --arg h "$HOME_DIR" '
  (if $d == "" then [] else
    ["[code-guardian] Opening an anonymous tracking issue on \($d) with bash \($h)/scripts/definition-issue.sh file: the weekly audit and the channel-refused rule file them there, and the script checks the definition_issues switch and scans the draft for instance data before it sends anything."] end)
  + ["[code-guardian] Uploading a file under \($h)/work/audit/, \($h)/work/benchmark/, \($h)/work/reviews/pr-artifacts/ or \($h)/work/survey/ with curl -X PUT --data-binary to the URL that create_artifact_upload_url returned in the same session: the weekly trend report, the benchmark report, a PR review artifact and the survey report are published that way.",
     "[code-guardian] Running bash \($h)/scripts/review-pr.sh with any subcommand (hold, release, lock, prepare, step, post, abort, merge, fix-start, fix-push and the others): it is the review executor of the agent. Posting an APPROVE, COMMENT or REQUEST_CHANGES review on \(if $r == "" then "the target repository" else $r end) through it is the main task of the agent, and the script itself refuses a stale HEAD, a closed PR and a duplicate review.",
     "[code-guardian] Starting a subagent of type review-skill with the Agent tool: a review run gives each configured review skill one subagent, with its brief file under /tmp/review-pr-<n>.ctx/.",
     "[code-guardian] Running bash \($h)/scripts/work-backup.sh persist or restore: it backs up the \($h)/work/ directory of the agent to the work repository that work/CONFIG.md names.",
     "[code-guardian] Deleting with rm -f or rm -rf the review files and scratch of the agent: paths under \($h)/work/reviews/, /tmp/review-pr-* and /tmp/cg-*.",
     "[code-guardian] Starting a review of one pull request in a session of its own with mcp__platform-outbound__schedule_once, passing exactly the name, task and sessionTitle that scripts/dispatch.sh plan printed in the same session: a review run hands every PR after its first to a one-time session that runs at once, then titles its own session with mcp__platform-outbound__rename_session and the title scripts/dispatch.sh rest printed. Every other scheduled run titles its own session with rename_session too."]')"

if [ "$CHECK" = 1 ]; then
  missing=""
  for h in "$SCRIPT" "$TOKENS" "$FINISH" "$STEPS" "$GUARD" "$DENIED" "$APIFAIL"; do
    grep -qF "$h" "$SETTINGS" 2>/dev/null || { missing="$missing hooks"; break; }
  done
  # the installed [code-guardian] rules are exactly the ones this script writes
  # now: an older definition's rules, or a changed slug, read as not current
  jq -e --argjson e "$AM_ENV" --argjson a "$AM_ALLOW" '
      def own($k): [.autoMode[$k][]? | strings | select(startswith("[code-guardian]"))];
      own("environment") == $e and own("allow") == $a' "$SETTINGS" >/dev/null 2>&1 \
    || missing="$missing automode-rules"
  jq -e --argjson d "$DENY" '($d - (.permissions.deny // [])) == []' "$SETTINGS" >/dev/null 2>&1 \
    || missing="$missing tool-deny"
  cmp -s "$AGENT_SRC" "$AGENT_DST" || missing="$missing skill-agent"
  printf '%s\n' "${missing# }"
  exit 0
fi

[ -n "$DEF" ] || echo "definition repo unresolved — tracking-issue rule left out; re-run once work/CONFIG.md has definition_repo"

chmod +x "$SCRIPT" "$TOKENS" "$FINISH" "$STEPS" "$GUARD" "$DENIED" "$APIFAIL" "$ADAPTER_DIR/../../log.sh" 2>/dev/null || true

mkdir -p "$(dirname "$SETTINGS")"
[ -s "$SETTINGS" ] || echo '{}' > "$SETTINGS"

tmp="$(mktemp)"
if ! jq --arg c "$SCRIPT" --arg t "$TOKENS" --arg f "$FINISH" --arg s "$STEPS" --arg g "$GUARD" \
      --arg pd "$DENIED" --arg af "$APIFAIL" \
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
    .hooks.PermissionDenied = ([.hooks.PermissionDenied[]?
        | select([.hooks[]?.command] | index($pd) | not)]
      + [{matcher:"*", hooks:[{type:"command", command:$pd, timeout:10}]}]) |
    .hooks.StopFailure = ([.hooks.StopFailure[]?
        | select([.hooks[]?.command] | index($af) | not)]
      + [{hooks:[{type:"command", command:$af, timeout:10}]}]) |
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
  echo "installed into $SETTINGS: hooks (PostToolUseFailure + PostToolUse -> $SCRIPT; PostToolUse Bash|Task -> $STEPS; SessionEnd -> $TOKENS; Stop -> $FINISH; PreToolUse Bash -> $GUARD; PermissionDenied -> $DENIED; StopFailure -> $APIFAIL), [code-guardian] rules -> autoMode.environment + autoMode.allow, $(printf '%s' "$DENY" | jq 'length') tools -> permissions.deny; review-skill agent -> $AGENT_DST"
fi
exit 0
