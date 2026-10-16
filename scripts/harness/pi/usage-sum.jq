# Usage summation over pi session transcripts (docs/harness-pi.md).
# Invoke as: jq -nR -f usage-sum.jq <session.jsonl>...
# Same output shape as ../claude-code/usage-sum.jq: {input, output,
# cache_read, cache_creation, msgs, model}. A pi entry id is unique within its
# file only, so the dedup key adds the entry's timestamp.
[inputs | fromjson? // empty
 | select(.type == "message" and .message.usage)
 | {id: "\(.id)@\(.timestamp // "")", u: .message.usage, m: (.message.model // null)}]
| unique_by(.id)
| {input: ([.[].u.input // 0] | add // 0),
   output: ([.[].u.output // 0] | add // 0),
   cache_read: ([.[].u.cacheRead // 0] | add // 0),
   cache_creation: ([.[].u.cacheWrite // 0] | add // 0),
   msgs: length,
   model: ([.[].m | select(. != null)] | if length == 0 then null
           else (group_by(.) | max_by(length) | .[0]) end)}
