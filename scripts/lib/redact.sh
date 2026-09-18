#!/usr/bin/env bash
# redact.sh — mask credential shapes in a file before it is published to a
# public surface (docs/artifact.md → **Procedure**, step 1).
#
#   . scripts/lib/redact.sh
#   N="$(redact_file work/reviews/pr-artifacts/pr-42.html)"
#
# The file is rewritten in place, one `[redacted]` per masked value, and the
# count goes to stdout. A file with nothing to mask keeps its bytes and prints
# 0, and a second pass over a redacted file prints 0 again.
#
# Named shapes only, never entropy. A PR artifact is built from commit SHAs,
# base64 payloads and content hashes, which an entropy bar reads as secrets —
# entropy would blank the artifact it protects. Every rule below names one
# credential shape, so a SHA, a base64 block and a hash survive the pass
# (scripts/tests/test_redact.sh).
#
# The shapes: PEM private key blocks (on one line and across lines), an
# assignment whose key names an api key, secret, password, token or credential,
# `Bearer <token>`, AWS access key ids, GitHub tokens, Slack tokens. Markup
# between a key and its value defeats the assignment rule; the standalone
# shapes match wherever they appear.
#
# `log.sh`'s `log_redact` is the same rule for one log message. This one reads
# a whole file and reports a count, so the two stay separate.
#
# Fails closed: an unreadable file or a failed pass prints 0 and returns 1, and
# the caller publishes nothing (docs/artifact.md → **Procedure**). Needs sed
# and grep.

REDACT_MASK='[redacted]'

# One rule per shape, each inserting exactly one mask per redacted value, which
# is what makes the count below the number of values masked. `%` delimits every
# `s` command: a `,` would end one inside a `{n,m}` interval and a `#` inside a
# numeric HTML entity. An unterminated PEM block masks to the end of the file —
# a key body never survives a missing `-----END … -----`.
REDACT_SED='
s%-----BEGIN[A-Za-z0-9 ]*PRIVATE KEY-----.*-----END[A-Za-z0-9 ]*PRIVATE KEY-----%[redacted]%g
/-----BEGIN[A-Za-z0-9 ]*PRIVATE KEY-----/,/-----END[A-Za-z0-9 ]*PRIVATE KEY-----/{
s%(-----BEGIN[A-Za-z0-9 ]*PRIVATE KEY-----).*%\1[redacted]%
/-----(BEGIN|END)[A-Za-z0-9 ]*PRIVATE KEY-----/!d
}
s%([A-Za-z0-9_.-]*(api[_-]?key|secret|passwd|password|token|credential)[A-Za-z0-9_.-]*[[:space:]]*[:=][[:space:]]*(&[A-Za-z]{2,6};|&#[0-9]{2,4};|[^[:alnum:][:space:][])?[[:space:]]*)[A-Za-z0-9._~+/=-]{8,}%\1[redacted]%gI
s%(bearer[[:space:]]+)[A-Za-z0-9._~+/=-]{8,}%\1[redacted]%gI
s%(A3T[A-Z0-9]|AKIA|AGPA|AIDA|AROA|AIPA|ANPA|ANVA|ASIA)[A-Z0-9]{16}%[redacted]%g
s%(ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]{8,}%[redacted]%g
s%xox[abeoprs]-[A-Za-z0-9-]{8,}%[redacted]%g
'

# Masks in a file, counted per occurrence: the delta across the pass is the
# number of redactions, so a mask the input already carried never inflates it.
_redact_masks() { # <file>
  grep -oF "$REDACT_MASK" "$1" 2>/dev/null | grep -c . 2>/dev/null
}

redact_file() { # <file> -> count on stdout; returns 1 when the pass did not run
  local f="${1:-}" tmp="" before after
  [ -n "$f" ] && [ -f "$f" ] && [ -r "$f" ] && [ -w "$f" ] \
    || { printf '0\n'; return 1; }
  before="$(_redact_masks "$f")"
  tmp="$(mktemp "$f.redact.XXXXXX" 2>/dev/null)" || { printf '0\n'; return 1; }
  if ! sed -E "$REDACT_SED" "$f" > "$tmp" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null; printf '0\n'; return 1
  fi
  after="$(_redact_masks "$tmp")"
  # nothing masked: keep the original file, never a rewritten copy of itself
  if [ "${after:-0}" -le "${before:-0}" ]; then
    rm -f "$tmp" 2>/dev/null; printf '0\n'; return 0
  fi
  mv -f "$tmp" "$f" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; printf '0\n'; return 1; }
  printf '%s\n' "$(( after - before ))"
}
