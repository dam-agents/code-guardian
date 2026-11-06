#!/usr/bin/env bash
# The audit infographic (docs/audit.md → **Infographic**): audit-infographic.sh
# draws what fits and returns every other part as text, so no number is lost;
# finds a renderer or says it has none; refuses output that is not a PNG;
# preflight's audit_infographic check.
. "$(dirname "$0")/helpers.sh"

IG="$REPO_ROOT/scripts/audit-infographic.sh"

report() { # → $SANDBOX/report.txt
  cat > "$SANDBOX/report.txt" <<'EOF'
🩺 *Acme Bot weekly audit* — 2026-11-06 · 🟢 41 ok · 🟡 3 warn · 🔴 1 fail

*Week in numbers* (since 2026-10-30T07:00:10Z)
• Reviews: 211 (123 first / 88 re) — ✅135 ⚠️73 ❌3
• Findings acceptance: 143/198 fixed by the next re-review
• Findings acceptance by severity: critical 2/2, warning 87/98, suggestion 50/94
• Project — coverage: 79/93 merged PRs reviewed (85%) · merge conflicts: 13 PRs
• Findings sit in: src/<generated> 1🔴/0🟡
• Spend: $1228.99 actual · per review $5.82 · model: acme/model-x ×31854
• Guides: 4 published
• Trend: trend 2026-W45: reviews 211 (▼179) · acceptance 72% (▲50pp) · coverage 85% (▼12pp) — https://example.test/a/1

*Learned this week*
• nothing new
EOF
}

# a renderer stub: writes the bytes of $STUB_BYTES to the --screenshot path
stub_renderer() { # <name> <png|text>
  mkdir -p "$SANDBOX/rbin"
  cat > "$SANDBOX/rbin/$1" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do case "\$a" in (--screenshot=*) f="\${a#--screenshot=}";; esac; done
if [ "$2" = png ]; then printf '\x89PNG\r\n\x1a\n' > "\$f"; else printf 'oops' > "\$f"; fi
EOF
  chmod +x "$SANDBOX/rbin/$1"
}

new_case infographic_html
report
OUT="$(bash "$IG" html "$SANDBOX/report.txt")"
for s in 'Acme Bot — weekly audit' '>211<' '>72 %<' '>85 %<' '\$1,229' '▼12pp' 'Approve 135' 'Request changes 3' \
         '2 / 2 · 100 %' 'PRs with merge conflicts' '\$5.82 per review' '41 ok' '4 merged PRs had no review'; do
  if printf '%s' "$OUT" | grep -q "$s"; then ok "the page shows $s"; else bad "the page lacks $s"; fi
done

new_case infographic_rest
report
OUT="$(bash "$IG" rest "$SANDBOX/report.txt")"
want='• Findings sit in: src/<generated> 1🔴/0🟡
• Spend: model: acme/model-x ×31854
• Guides: 4 published
• Trend: https://example.test/a/1'
is 'the text holds exactly the parts the picture leaves out' "$OUT" "$want"
if printf '%s' "$OUT" | grep -q 'nothing new'; then bad 'a line after the section was taken'; else ok 'the section ends at its blank line'; fi

new_case infographic_no_renderer
report
OUT="$(CG_INFOGRAPHIC_RENDERERS=cg-no-such-browser bash "$IG" render "$SANDBOX/report.txt" "$SANDBOX/out.png")"
assert_jq '.outcome == "no_renderer" and (.rest | contains("acme/model-x"))' 'no browser → no_renderer, with the text'

new_case infographic_render
report; stub_renderer cg-fake-chrome png
OUT="$(PATH="$SANDBOX/rbin:$PATH" CG_INFOGRAPHIC_RENDERERS=cg-fake-chrome bash "$IG" render "$SANDBOX/report.txt" "$SANDBOX/out.png")"
assert_jq '.outcome == "ok" and (.rest | startswith("• Findings sit in")) and (.renderer | endswith("cg-fake-chrome"))' 'a PNG from the renderer is ok, with the text'

new_case infographic_not_png
report; stub_renderer cg-fake-chrome text
OUT="$(PATH="$SANDBOX/rbin:$PATH" CG_INFOGRAPHIC_RENDERERS=cg-fake-chrome bash "$IG" render "$SANDBOX/report.txt" "$SANDBOX/out.png")"
assert_jq '.outcome == "error"' 'output that is not a PNG is an error'
[ -e "$SANDBOX/out.png" ] && bad 'the bad output stays on disk' || ok 'the bad output is removed'

new_case infographic_no_section
printf 'hello\n' > "$SANDBOX/report.txt"
OUT="$(CG_INFOGRAPHIC_RENDERERS=cg-no-such-browser bash "$IG" render "$SANDBOX/report.txt" "$SANDBOX/out.png")"
assert_jq '.outcome == "error"' 'a report without *Week in numbers* is an error'

# --- preflight: config field and the renderer check ---------------------------
new_case infographic_check_missing
base_config '- audit_infographic: enabled'
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
run_preflight review
assert_jq '.config.audit_infographic == "enabled"' 'the key reaches the config object'
CG_INFOGRAPHIC_RENDERERS=cg-no-such-browser run_preflight audit
assert_jq '.checks[] | select(.id == "audit_infographic") | .status == "warn"' 'enabled without a renderer warns'

new_case infographic_check_ok
base_config '- audit_infographic: enabled'
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
stub_renderer cg-fake-chrome png
PATH="$SANDBOX/rbin:$PATH" CG_INFOGRAPHIC_RENDERERS=cg-fake-chrome run_preflight audit
assert_jq '.checks[] | select(.id == "audit_infographic") | .status == "ok"' 'enabled with a renderer is ok'

new_case infographic_check_off
base_config
pr_json 1 "open PR" '[]' "1111111111111111111111111111111111111111" | open_prs_fx
run_preflight review
assert_jq '.config.audit_infographic == "disabled"' 'missing key = disabled'
run_preflight audit
assert_jq '[.checks[] | select(.id == "audit_infographic")] | length == 0' 'disabled → no check'

exit "$FAILED"
