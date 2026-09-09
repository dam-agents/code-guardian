# Shared usage summation over a Claude Code session transcript.
# Invoke as: jq -nR -f usage-sum.jq <transcript.jsonl>
# One pass over the raw JSONL (no intermediate re-serialization), deduped by
# message id, summed into {input, output, cache_read, cache_creation, msgs}
# plus the session's dominant `model` (what prices the tokens).
# Consumers: log-session-tokens.sh (the run-level `tokens` event) and
# usage-snapshot.sh (the benchmark's per-phase deltas) — one accounting for
# both, by construction.
[inputs | fromjson? // empty
 | select(.message.usage)
 | {id: (.message.id // .uuid), u: .message.usage, m: (.message.model // null)}]
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
