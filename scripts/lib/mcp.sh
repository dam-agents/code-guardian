#!/usr/bin/env bash
# mcp.sh — one platform-outbound MCP tool call from a script, with no model in
# the loop (docs/monitor.md → **Direct delivery**, docs/health.md →
# **Publish**). Only the monitor's pass calls it.
#
#   . scripts/lib/mcp.sh
#   mcp_call <tool> <arguments.json>   # -> the tool's text result on stdout
#
#   rc 0  the tool answered
#   rc 1  no endpoint configured
#   rc 2  nothing sent: the endpoint did not answer the handshake, or no time left
#   rc 3  the tool refused (its reason on stdout)
#   rc 4  the call went out and no answer came back: the outcome is unknown
#
# The endpoint is the harness's own: `mcpServers["platform-outbound"].url` in
# `$HOME/.mcp.json`, else the platform's `PLATFORM_MCP_URL`. The server is
# stateless MCP over streamable HTTP, and the pod's network identity is the
# credential, so the call carries no token. The handshake (initialize →
# initialized → tools/call) is the one the platform's own script clients use.
# Arguments and answers travel in files and on stdin, never in argv: a
# dashboard is megabytes. curl honors the pod's HTTP(S)_PROXY, which routes the
# call through the agent's gateway like the harness's own calls.
#
# MCP_DEADLINE (epoch seconds) bounds every request of the caller: each one gets
# the time left, at most MCP_TIMEOUT_S, and none starts with under 3 s left.

MCP_PROTOCOL_VERSION="2025-06-18"
MCP_TIMEOUT_S="${MCP_TIMEOUT_S:-20}"

mcp_url() {
  local u
  u="$(jq -r '.mcpServers["platform-outbound"].url // empty' "${HOME:-/home/agent}/.mcp.json" 2>/dev/null)"
  [ -n "$u" ] || u="${PLATFORM_MCP_URL:-}"
  case "$u" in (http://*|https://*) printf '%s' "$u";; (*) return 1;; esac
}

# seconds one request may take: MCP_TIMEOUT_S, cut to the deadline; rc 1 under 3 s
mcp_budget() {
  local t="$MCP_TIMEOUT_S" left
  if [ -n "${MCP_DEADLINE:-}" ]; then
    left=$(( MCP_DEADLINE - $(date -u +%s) ))
    [ "$left" -lt "$t" ] && t="$left"
  fi
  [ "$t" -ge 3 ] || return 1
  printf '%s' "$t"
}

# the JSON-RPC response with id <id> from a response body (SSE `data:` lines or
# one plain object) — a response only: a request or notification the server
# sends on the same stream carries `method` and is skipped
mcp_pick() { # <id> < body
  sed -n 's/^data:[[:space:]]*//p; /^[[:space:]]*{/p' \
    | jq -c --arg id "$1" 'select(type == "object" and .id? == $id and (has("method") | not)
                                 and (has("result") or has("error")))' 2>/dev/null | head -1
}

mcp_post() { # <session id or empty> <out file> <header file or empty>  < body
  local t
  t="$(mcp_budget)" || return 28
  curl -sS -f --connect-timeout 5 --max-time "$t" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    ${1:+-H "mcp-session-id: $1"} ${3:+-D "$3"} -o "$2" --data-binary @- "$MCP_URL_RESOLVED" 2>/dev/null
}

mcp_call() { # <tool> <arguments.json>
  local tool="$1" args="$2" tmp sid rc
  MCP_URL_RESOLVED="$(mcp_url)" || return 1
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cg-mcp.XXXXXX" 2>/dev/null)" || return 2
  jq -nc --arg v "$MCP_PROTOCOL_VERSION" '{jsonrpc: "2.0", id: "cg-init", method: "initialize",
      params: {protocolVersion: $v, capabilities: {}, clientInfo: {name: "code-guardian-monitor", version: "1"}}}' \
    | mcp_post "" "$tmp/init" "$tmp/hdr"
  if [ -z "$(mcp_pick cg-init < "$tmp/init" 2>/dev/null)" ]; then rm -rf "$tmp"; return 2; fi
  sid="$(grep -i '^mcp-session-id:' "$tmp/hdr" 2>/dev/null | head -1 | cut -d: -f2- | tr -d ' \r')"
  printf '%s' '{"jsonrpc":"2.0","method":"notifications/initialized"}' | mcp_post "$sid" /dev/null ""
  # the call itself: from here on the server may act on it, so a missing answer
  # is an unknown outcome, never "not sent"; a partial body is still read
  jq -nc --arg t "$tool" --slurpfile a "$args" '{jsonrpc: "2.0", id: "cg-call", method: "tools/call",
      params: {name: $t, arguments: $a[0]}}' > "$tmp/req" || { rm -rf "$tmp"; return 2; }
  mcp_budget >/dev/null || { rm -rf "$tmp"; return 2; }
  mcp_post "$sid" "$tmp/res" "" < "$tmp/req"; rc=$?
  mcp_pick cg-call < "$tmp/res" > "$tmp/pick" 2>/dev/null
  if [ ! -s "$tmp/pick" ]; then
    rm -rf "$tmp"
    # an HTTP error status is a refusal of the request; anything else
    # (timeout, reset) may have reached the tool
    [ "$rc" -eq 22 ] && return 2
    return 4
  fi
  rc=0
  jq -e '.error == null and (.result.isError // false) == false' "$tmp/pick" >/dev/null 2>&1 || rc=3
  jq -r '([.result.content[]? | select(.type == "text") | .text] | join("\n")) as $t
    | if $t == "" then (.error.message // "") else $t end' "$tmp/pick" 2>/dev/null
  rm -rf "$tmp"
  return "$rc"
}
