#!/usr/bin/env bash
# The Desk server's Login item (kit.yaml → startupItems): the platform runs this at every boot and
# restarts it when it exits (docs/desk.md → The server).
NODE="$(command -v node 2>/dev/null || ls -1 /usr/share/mise/installs/node/*/bin/node 2>/dev/null | tail -1)"
exec "${NODE:-node}" "$HOME/scripts/desk/server.mjs"
