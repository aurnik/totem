#!/bin/sh
# Build the iOS app and install it on the phone.
#
# The path matters more than it looks: this machine has more than one
# DerivedData directory for this project, so globbing DerivedData/Totem-*
# can resolve to a stale build from hours ago and install it without
# complaint. Ask xcodebuild where it actually writes instead — that answer
# is always the one `build` just produced.
set -e
cd "$(dirname "$0")"

DEVICE="${TOTEM_DEVICE:-4FABDBEF-E20F-5818-9026-83C0F0502A78}"
DEST="generic/platform=iOS"

xcodebuild -project Totem.xcodeproj -scheme Totem-iOS -destination "$DEST" \
    -configuration Debug -allowProvisioningUpdates build

APP_DIR=$(xcodebuild -project Totem.xcodeproj -scheme Totem-iOS -destination "$DEST" \
    -configuration Debug -showBuildSettings 2>/dev/null \
    | awk '/ BUILT_PRODUCTS_DIR = /{print $3; exit}')
APP="$APP_DIR/Totem-iOS.app"
[ -d "$APP" ] || { echo "No app at $APP" >&2; exit 1; }

# Debug builds keep the real code in a side dylib; the launcher stub's
# timestamp says nothing about whether your edit made it in.
echo "installing $APP"
echo "  built $(stat -f '%Sm' "$APP/Totem-iOS.debug.dylib" 2>/dev/null || stat -f '%Sm' "$APP/Totem-iOS")"

# The CoreDevice tunnel drops often enough that one retry isn't sniffing glue.
attempt=1
while [ "$attempt" -le 3 ]; do
    if xcrun devicectl device install app --device "$DEVICE" "$APP"; then
        exit 0
    fi
    echo "install attempt $attempt failed (device locked? tunnel reset?) — retrying" >&2
    attempt=$((attempt + 1))
    sleep 5
done
echo "install failed after 3 attempts" >&2
exit 1
