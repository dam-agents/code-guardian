#!/usr/bin/env bash
# The Desk server's Login item (kit.yaml → startupItems): the platform runs this at every boot and
# restarts it when it exits (docs/desk.md → The server).
exec node "$HOME/scripts/desk/server.mjs"
