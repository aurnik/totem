#!/bin/sh
# Build the iOS app and install it on a connected device.
#
# Reads these from the environment or a .env file at the repo root:
#   TOTEM_DEVICE          device UDID (xcrun devicectl list devices)
#   TOTEM_DEV_TEAM_ID     Apple developer team for automatic signing
#   TOTEM_DEV_SERVER_URL  server the phone should reach, e.g. http://my-mac.local:9047
set -e
cd "$(dirname "$0")"
if [ -f ../.env ]; then set -a; . ../.env; set +a; fi

DEVICE="${TOTEM_DEVICE:?set TOTEM_DEVICE to the device UDID}"
TEAM="${TOTEM_DEV_TEAM_ID:?set TOTEM_DEV_TEAM_ID to your Apple team ID}"
DEST="generic/platform=iOS"
SETTINGS="TOTEM_TEAM_ID=$TEAM TOTEM_DEV_SERVER_URL=${TOTEM_DEV_SERVER_URL:-}"

xcodebuild -project Totem.xcodeproj -scheme Totem-iOS -destination "$DEST" \
    -configuration Debug -allowProvisioningUpdates $SETTINGS build

# Ask xcodebuild for the product path rather than globbing DerivedData, which
# can hold more than one build of this project.
APP_DIR=$(xcodebuild -project Totem.xcodeproj -scheme Totem-iOS -destination "$DEST" \
    -configuration Debug $SETTINGS -showBuildSettings 2>/dev/null \
    | awk '/ BUILT_PRODUCTS_DIR = /{print $3; exit}')
APP="$APP_DIR/Totem-iOS.app"
[ -d "$APP" ] || { echo "No app at $APP" >&2; exit 1; }
echo "installing $APP"

# The CoreDevice tunnel drops often enough to be worth a retry.
attempt=1
while [ "$attempt" -le 3 ]; do
    if xcrun devicectl device install app --device "$DEVICE" "$APP"; then
        exit 0
    fi
    echo "install attempt $attempt failed, retrying" >&2
    attempt=$((attempt + 1))
    sleep 5
done
echo "install failed after 3 attempts" >&2
exit 1
