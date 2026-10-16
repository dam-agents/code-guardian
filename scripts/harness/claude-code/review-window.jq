# The shape of one review's slice of a Claude Code or pi session: the transcript
# entries (session + subagents) stamped at or after $since (ISO, compared to
# the second). Invoke as: jq -nR --arg since <iso> -f review-window.jq <files…>
# Consumer: log-review-step.sh (the `review_cost` event's anomaly fields,
# docs/monitor.md → Review anomaly alert).
#   peak_ctx    — the largest single API call's context (input + cache read +
#                 cache write), deduped by message id
#   repeats     — how often the most repeated identical tool call ran
#                 (same tool, same input); repeat_tool names that tool
#   max_out     — the largest tool result, in characters; a result the harness
#                 saved to a file (`<persisted-output>`, a preview in the
#                 transcript) counts at the full size it states
($since[0:19]) as $s
| [inputs | fromjson? // empty | select((.timestamp // "")[0:19] >= $s)] as $e
# a pi entry (type "message", docs/harness-pi.md) carries pi's usage fields,
# `toolCall` parts and `toolResult` messages
| def pi: .type == "message";
  ([$e[] | select(.message.usage)
    | if pi then {id: "pi:\(.id)@\(.timestamp // "")",
                  n: ((.message.usage.input // 0) + (.message.usage.cacheRead // 0)
                      + (.message.usage.cacheWrite // 0))}
      else {id: (.message.id // .uuid),
            n: ((.message.usage.input_tokens // 0) + (.message.usage.cache_read_input_tokens // 0)
                + (.message.usage.cache_creation_input_tokens // 0))} end]
   | unique_by(.id) | map(.n) | max // 0) as $ctx
| ([$e[] | if pi then select(.message.role == "assistant") | .message.content[]?
                      | select(type == "object" and .type == "toolCall")
                      | {n: .name, k: (.arguments | tojson)}
           else select(.type == "assistant") | .message.content[]?
                | select(type == "object" and .type == "tool_use") | {n: .name, k: (.input | tojson)} end]
   | group_by(.) | map({n: .[0].n, c: length}) | max_by(.c) // {n: "-", c: 0}) as $rep
| ([$e[] | if pi then select(.message.role == "toolResult") | .message.content
           else select(.type == "user") | .message.content[]?
                | select(type == "object" and .type == "tool_result") | .content end
    | (if type == "string" then . elif type == "array" then ([.[] | .text? // ""] | join("")) else "" end) as $t
    | if $t | startswith("<persisted-output>")
      then ([$t | capture("Output too large \\((?<n>[0-9.]+)(?<u>[KMG]?B)\\)")
             | (.n | tonumber) * {B: 1, KB: 1024, MB: 1048576, GB: 1073741824}[.u] | floor]
            | first // ($t | length))
      else $t | length end] | max // 0) as $out
| {peak_ctx: $ctx, repeats: $rep.c, repeat_tool: ($rep.n | gsub("[^A-Za-z0-9_.:-]"; "_")), max_out: $out}
