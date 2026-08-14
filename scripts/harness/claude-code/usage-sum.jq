# Shared usage summation over a Claude Code session transcript.
# Invoke as: jq -nR -f usage-sum.jq <transcript.jsonl>
# One pass over the raw JSONL (no intermediate re-serialization), deduped by
# message id, summed into {input, output, cache_read, cache_creation, msgs}.
# Consumers: log-session-tokens.sh (the run-level `tokens` event) and
# usage-snapshot.sh (the benchmark's per-phase deltas) — one accounting for
# both, by construction.
[inputs | fromjson? // empty
 | select(.message.usage)
 | {id: (.message.id // .uuid), u: .message.usage}]
| unique_by(.id)
| {input: ([.[].u.input_tokens // 0] | add // 0),
   output: ([.[].u.output_tokens // 0] | add // 0),
   cache_read: ([.[].u.cache_read_input_tokens // 0] | add // 0),
   cache_creation: ([.[].u.cache_creation_input_tokens // 0] | add // 0),
   msgs: length}
