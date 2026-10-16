# Shared usage summation over Claude Code and pi session transcripts.
# Invoke as: jq -nR -f usage-sum.jq <transcript.jsonl>...
# One pass over the raw JSONL (no intermediate re-serialization), deduped by
# message id, summed into {input, output, cache_read, cache_creation, msgs}
# plus the session's dominant `model` (what prices the tokens). A pi entry
# (docs/harness-pi.md) is mapped to Claude Code's usage fields first; its id is
# unique within its file only, so its key adds the entry's timestamp.
# Consumers: log-session-tokens.sh (the run-level `tokens` event) and the
# usage snapshots (the benchmark's per-phase deltas) — one accounting for
# all, by construction.
[inputs | fromjson? // empty
 | if .type == "message" and (.message.usage.output | type) == "number" then
     {id: "pi:\(.id)@\(.timestamp // "")", m: (.message.model // null),
      u: (.message.usage | {input_tokens: .input, output_tokens: .output,
                            cache_read_input_tokens: .cacheRead,
                            cache_creation_input_tokens: .cacheWrite})}
   elif .message.usage then
     {id: (.message.id // .uuid), u: .message.usage, m: (.message.model // null)}
   else empty end]
| unique_by(.id)
| {input: ([.[].u.input_tokens // 0] | add // 0),
   output: ([.[].u.output_tokens // 0] | add // 0),
   cache_read: ([.[].u.cache_read_input_tokens // 0] | add // 0),
   cache_creation: ([.[].u.cache_creation_input_tokens // 0] | add // 0),
   msgs: length,
   # the model that produced the most messages of the session — what prices
   # these tokens (docs/trends.md → Cost); null when the transcript names none
   model: ([.[].m | select(. != null)] | if length == 0 then null
           else (group_by(.) | max_by(length) | .[0]) end)}
