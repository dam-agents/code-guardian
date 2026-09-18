#!/usr/bin/env bash
# lib/redact.sh — the redaction pass a PR artifact goes through before it is
# published to a public surface. Two halves matter equally: every credential
# shape the redactor knows is masked, and the material an artifact is made of —
# commit SHAs, base64 payloads, content hashes — survives it. The second half
# is why the pass names shapes instead of measuring entropy. Contract:
# docs/artifact.md → **Procedure**.
. "$(dirname "$0")/helpers.sh"

. "$REPO_ROOT/scripts/lib/redact.sh"

SANDBOX="$(mktemp -d)"
SANDBOXES+=("$SANDBOX")

ok()  { printf 'ok   %s: %s\n' "$CASE" "$1"; }
bad() { printf 'FAIL %s: %s\n' "$CASE" "$1"; RC=1; }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1 (got '$2', want '$3')"; }
RC=0

# redact one line in its own file and report what is left of it
redacted_line() { # <line>
  printf '%s\n' "$1" > "$SANDBOX/line.txt"
  redact_file "$SANDBOX/line.txt" >/dev/null
  cat "$SANDBOX/line.txt"
}

# <description> <line> — the value is gone and the mask is there
masks() { # <description> <line> <secret>
  local out; out="$(redacted_line "$2")"
  case "$out" in
    *"$3"*)        bad "$1 (secret survived: $out)";;
    *'[redacted]'*) ok "$1";;
    *)             bad "$1 (no mask: $out)";;
  esac
}

# <description> <line> — the line comes back byte for byte
keeps() { # <description> <line>
  is "$1" "$(redacted_line "$2")" "$2"
}

CASE=every_shape_is_masked
masks 'an api_key assignment'        'api_key=ABCDEFGH12345678'      'ABCDEFGH12345678'
masks 'an apikey: value'             'apikey: 0123456789abcdef'      '0123456789abcdef'
masks 'a secret= value'              'SECRET = supersecretvalue1'    'supersecretvalue1'
masks 'a password= value'            'password=hunter2hunter2'       'hunter2hunter2'
masks 'a quoted password value'      'db_password: "s3cr3t-value-here"' 's3cr3t-value-here'
masks 'an HTML-escaped token value'  'access_token=&quot;abcdefgh12345678&quot;' 'abcdefgh12345678'
masks 'a bearer authorization'       'Authorization: Bearer eyJhbGciOiJIUzI1NiJ9xyz' 'eyJhbGciOiJIUzI1NiJ9xyz'
masks 'an AWS access key id'         'aws_id = AKIAIOSFODNN7EXAMPLE' 'AKIAIOSFODNN7EXAMPLE'
masks 'an AWS secret access key'     'aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY' 'wJalrXUtnFEMI/K7MDENG'
masks 'a GitHub token'               'see ghp_16CharactersAndMoreABCDEFG here' 'ghp_16CharactersAndMoreABCDEFG'
masks 'a Slack token'                'slack=xoxb-123456789012-abcdefghijkl' 'xoxb-123456789012-abcdefghijkl'

CASE=private_key_blocks
cat > "$SANDBOX/pem.html" <<'EOF'
<pre>
-----BEGIN RSA PRIVATE KEY-----
MIIEpAIBAAKCAQEA1234567890abcdefghijklmnopqrstuvwxyz
QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVowMTIzNDU2Nzg5
-----END RSA PRIVATE KEY-----
</pre>
<p>tail of the artifact</p>
EOF
is 'a multi-line block is one redaction' "$(redact_file "$SANDBOX/pem.html")" '1'
grep -q 'MIIEpAIBAAKCAQEA' "$SANDBOX/pem.html" \
  && bad 'the key body survived the block' || ok 'the key body is gone'
grep -q 'tail of the artifact' "$SANDBOX/pem.html" \
  && ok 'the rest of the artifact is kept' || bad 'the block ate the rest of the file'
masks 'a block on one line' \
  'key: -----BEGIN EC PRIVATE KEY-----MIIEpAIBAAKCAQEAxyz-----END EC PRIVATE KEY-----' \
  'MIIEpAIBAAKCAQEAxyz'
# a hunk that cut the block short must still lose the key body — the pass masks
# to the end of the file rather than let a body through (lib/redact.sh)
printf -- '-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEAtruncated\n' > "$SANDBOX/cut.html"
redact_file "$SANDBOX/cut.html" >/dev/null
grep -q 'MIIEpAIBAAKCAQEAtruncated' "$SANDBOX/cut.html" \
  && bad 'an unterminated block leaked its body' || ok 'an unterminated block is masked too'

CASE=the_artifact_survives
# the whole reason the pass names shapes instead of measuring entropy: every
# one of these sits above the entropy bar a reference redactor would use, and
# every one of them is ordinary artifact content
keeps 'a short commit SHA'   'reviewed at 89634a6'
keeps 'a full commit SHA'    'commit 4943d48b1a2c3d4e5f60718293a4b5c6d7e8f900'
keeps 'a base64 payload'     'TG9yZW0gaXBzdW0gZG9sb3Igc2l0IGFtZXQsIGNvbnNlY3RldHVy='
keeps 'a sha256 digest'      'sha256: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
keeps 'an md5 digest'        'md5 d41d8cd98f00b204e9800998ecf8427e'
keeps 'a highlighted token span' '<span class="token operator">=</span>'
keeps 'prose about bearer tokens' 'Bearer tokens are rotated every hour.'

CASE=a_clean_file_is_untouched
cat > "$SANDBOX/clean.html" <<'EOF'
<html><body>
<p>PR #42 review artifact, commit 89634a6</p>
<pre>TG9yZW0gaXBzdW0gZG9sb3Igc2l0IGFtZXQ=</pre>
</body></html>
EOF
cp "$SANDBOX/clean.html" "$SANDBOX/clean.orig"
is 'a file with no secret reports zero' "$(redact_file "$SANDBOX/clean.html")" '0'
cmp -s "$SANDBOX/clean.html" "$SANDBOX/clean.orig" \
  && ok 'and keeps its bytes' || bad 'a clean file was rewritten'

CASE=the_count_is_the_contract
cat > "$SANDBOX/many.html" <<'EOF'
api_key=ABCDEFGH12345678
password=hunter2hunter2
commit 89634a6 stays
EOF
is 'one mask per masked value' "$(redact_file "$SANDBOX/many.html")" '2'
is 'a second pass finds nothing' "$(redact_file "$SANDBOX/many.html")" '0'
printf 'a log line said [redacted] already\napi_key=ABCDEFGH12345678\n' > "$SANDBOX/pre.html"
is 'a mask the file already carried is not counted' "$(redact_file "$SANDBOX/pre.html")" '1'

CASE=a_pass_that_cannot_run_fails_closed
out="$(redact_file "$SANDBOX/no-such-file.html")"; rc=$?
is 'a missing file prints zero' "$out" '0'
is 'and reports the failure'    "$rc" '1'
out="$(redact_file)"; rc=$?
is 'no argument prints zero'    "$out" '0'
is 'and reports the failure'    "$rc" '1'
# the pass leaves no temp file next to the artifact it rewrote
is 'no temp file is left behind' "$(ls "$SANDBOX" | grep -c '\.redact\.')" '0'

exit "$RC"
