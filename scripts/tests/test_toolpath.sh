#!/usr/bin/env bash
# lib/toolpath.sh — shimmed tools resolve to real binaries once per run, without
# touching PATH (the offline suite stubs gh that way, so a PATH prepend here
# would send every test to the network). Contract: docs/logging.md → Tool path
# resolution.
. "$(dirname "$0")/helpers.sh"

LIB="$REPO_ROOT/scripts/lib/toolpath.sh"
# register with helpers.sh's own EXIT trap instead of adding one — a second
# `trap … EXIT` would replace theirs and leak every other case's sandbox
SANDBOX="$(mktemp -d)"
SANDBOXES+=("$SANDBOX")

# a fake mise + a fake shimmed tool, so the case never depends on the real pod
SHIMS="$SANDBOX/shims"; REAL="$SANDBOX/installs/widget/1.0"
mkdir -p "$SHIMS" "$REAL" "$SANDBOX/bin"
printf '#!/usr/bin/env bash\nprintf REAL_WIDGET\n' > "$REAL/widget"
printf '#!/usr/bin/env bash\nprintf SHIM_WIDGET\n' > "$SHIMS/widget"
printf '#!/usr/bin/env bash\n[ "$1" = bin-paths ] && printf "%%s\\n" "%s"\n' "$REAL" > "$SANDBOX/bin/mise"
chmod +x "$REAL/widget" "$SHIMS/widget" "$SANDBOX/bin/mise"

ok()   { printf 'ok   %s: %s\n' "$CASE" "$1"; }
bad()  { printf 'FAIL %s: %s\n' "$CASE" "$1"; RC=1; }
is()   { [ "$2" = "$3" ] && ok "$1" || bad "$1 (got '$2', want '$3')"; }
RC=0

# run a snippet with the fake pod on PATH and a fresh WORK_DIR
inlib() { # <work-dir> <snippet>
  PATH="$SANDBOX/bin:$SHIMS:/usr/sbin:/usr/bin:/bin" WORK_DIR="$1" \
    bash -c ". '$LIB' 2>/dev/null; toolpath_init widget; $2"
}

CASE=resolves_shimmed_tool
is 'a shimmed tool runs the real binary' "$(inlib "$SANDBOX/w1" 'widget')" 'REAL_WIDGET'
is 'it is shadowed by a function'        "$(inlib "$SANDBOX/w2" 'type -t widget')" 'function'
is 'nothing is reported as shimmed'      "$(inlib "$SANDBOX/w3" 'toolpath_shimmed widget')" ''

CASE=caches_resolution
inlib "$SANDBOX/w4" 'true'
[ -r "$SANDBOX/w4/.cache/toolpaths" ] && ok 'resolution is cached' || bad 'no cache written'
is 'cache holds the real path' \
   "$(sed -n 's|^widget ||p' "$SANDBOX/w4/.cache/toolpaths" 2>/dev/null)" "$REAL/widget"
# with mise unavailable the cache alone must still resolve
is 'cache resolves without mise' \
   "$(PATH="$SHIMS:/usr/sbin:/usr/bin:/bin" WORK_DIR="$SANDBOX/w4" \
      bash -c ". '$LIB' 2>/dev/null; toolpath_init widget; widget")" 'REAL_WIDGET'

CASE=stale_cache_recovers
mkdir -p "$SANDBOX/w5/.cache"
printf 'widget /nonexistent/widget\n' > "$SANDBOX/w5/.cache/toolpaths"
is 'a vanished binary is re-resolved' "$(inlib "$SANDBOX/w5" 'widget')" 'REAL_WIDGET'

CASE=never_shadows_a_path_override
# the gh-stub mechanism: a tool found outside */shims/* must be left alone
printf '#!/usr/bin/env bash\nprintf STUB_WIDGET\n' > "$SANDBOX/bin/widget"
chmod +x "$SANDBOX/bin/widget"
is 'an earlier PATH entry wins' "$(inlib "$SANDBOX/w6" 'widget')" 'STUB_WIDGET'
rm -f "$SANDBOX/bin/widget"

CASE=degrades_without_mise
out="$(PATH="$SHIMS:/usr/sbin:/usr/bin:/bin" WORK_DIR="$SANDBOX/w7" \
       bash -c ". '$LIB' 2>/dev/null; toolpath_init widget; echo rc=\$?; widget")"
is 'sourcing still succeeds and the shim keeps working' "$out" 'rc=0
SHIM_WIDGET'
is 'the unresolved tool is reported' \
   "$(PATH="$SHIMS:/usr/sbin:/usr/bin:/bin" WORK_DIR="$SANDBOX/w8" \
      bash -c ". '$LIB' 2>/dev/null; toolpath_init widget; toolpath_shimmed widget")" 'widget'

CASE=leaves_path_untouched
is 'PATH is not modified' \
   "$(inlib "$SANDBOX/w9" 'printf %s "$PATH"')" \
   "$SANDBOX/bin:$SHIMS:/usr/sbin:/usr/bin:/bin"

exit "$RC"
