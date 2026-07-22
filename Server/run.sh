#!/bin/sh
# Build, sign, and serve. Signing with a stable identity keeps the macOS
# firewall's incoming-connection allowance across rebuilds; unsigned debug
# binaries change hash every build and get silently re-blocked.
set -e
cd "$(dirname "$0")"
swift build
codesign -f -s "Apple Development: Aurnik Islam (75RYUVCU7X)" \
    --identifier com.aurnik.totem.server .build/debug/App
exec .build/debug/App serve --hostname 0.0.0.0 --port 9047 "$@"
