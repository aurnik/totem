#!/bin/bash
# Archives and exports an ad-hoc IPA whose provisioning profile includes every
# registered device, stamped with a monotonic build number (the app's update
# check compares these). Usage:
#   sign.sh <UDID>      register that device first, then build
#   sign.sh --rebuild   just publish a new build (updates for existing devices)
# Requires:
#   ASC_KEY_ID        App Store Connect API key ID
#   ASC_ISSUER_ID     App Store Connect issuer ID
#   ASC_KEY_PATH      path to the .p8 private key
#   ONBOARD_BASE_URL  public https base, baked into the app as its default
#                     server URL (optional for a build, required for friends)
set -euo pipefail
cd "$(dirname "$0")"
UDID="${1:?usage: sign.sh <UDID> | sign.sh --rebuild}"

: "${ASC_KEY_ID:?ASC_KEY_ID is not set}"
: "${ASC_ISSUER_ID:?ASC_ISSUER_ID is not set}"
: "${ASC_KEY_PATH:?ASC_KEY_PATH is not set}"

if [ "$UDID" != "--rebuild" ]; then
    if [ ! -d .venv ]; then
        python3 -m venv .venv
        ./.venv/bin/pip -q install PyJWT cryptography
    fi
    ./.venv/bin/python register_device.py "$UDID"
fi

REPO="$(cd ../.. && pwd)"
BUILD="$REPO/Server/onboard/build"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
AUTH=(-allowProvisioningUpdates
      -authenticationKeyPath "$ASC_KEY_PATH"
      -authenticationKeyID "$ASC_KEY_ID"
      -authenticationKeyIssuerID "$ASC_ISSUER_ID")

cd "$REPO/Apps"
xcodegen generate
xcodebuild -project Totem.xcodeproj -scheme Totem-iOS -configuration Release \
    -destination "generic/platform=iOS" \
    -archivePath "$BUILD/Totem.xcarchive" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    TOTEM_SERVER_URL="${ONBOARD_BASE_URL:-}" \
    archive "${AUTH[@]}"
xcodebuild -exportArchive -archivePath "$BUILD/Totem.xcarchive" \
    -exportPath "$BUILD/export" \
    -exportOptionsPlist "$REPO/Server/onboard/export-options.plist" "${AUTH[@]}"
cp "$BUILD/export/Totem-iOS.ipa" "$BUILD/totem.ipa"
echo "$BUILD_NUMBER" > "$BUILD/version.txt"
echo "onboard build $BUILD_NUMBER complete"
