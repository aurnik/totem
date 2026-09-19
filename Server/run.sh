#!/bin/sh
# Build, sign, and serve the dev server. Set SERVER_CODESIGN_IDENTITY to a
# stable identity so the macOS firewall's incoming-connection allowance
# survives rebuilds; ad-hoc signing is re-prompted after every build.
set -e
cd "$(dirname "$0")"
if [ -f ../.env ]; then set -a; . ../.env; set +a; fi
swift build
codesign -f -s "${SERVER_CODESIGN_IDENTITY:--}" --identifier com.deadsimple.totem.server .build/debug/App
exec .build/debug/App serve --hostname 0.0.0.0 --port "${PORT:-9047}" "$@"
