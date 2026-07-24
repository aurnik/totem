#!/bin/bash
# Archives and exports an ad-hoc IPA, stamped with a monotonic build number
# (the app's update check compares these). Signing is fully API-driven manual
# signing: provision.py ensures the bundle ID, Apple Distribution certificate,
# and a fresh ad-hoc profile (recreated to include every registered device) —
# no Xcode account, works headless. Usage:
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

# The paid team (Dead Simple LLC). project.yml carries the free personal
# team for dev builds; distribution overrides it.
TEAM_ID=BUQNMSY5Q2

if [ ! -d .venv ]; then
    python3 -m venv .venv
    ./.venv/bin/pip -q install PyJWT cryptography
fi

if [ "$UDID" != "--rebuild" ]; then
    ./.venv/bin/python register_device.py "$UDID"
fi
./.venv/bin/python provision.py

REPO="$(cd ../.. && pwd)"
BUILD="$REPO/Server/onboard/build"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"

cd "$REPO/Apps"
xcodegen generate
xcodebuild -project Totem.xcodeproj -scheme Totem-iOS -configuration Release \
    -destination "generic/platform=iOS" \
    -archivePath "$BUILD/Totem.xcarchive" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    PRODUCT_BUNDLE_IDENTIFIER=com.deadsimple.totem \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="Apple Distribution" \
    PROVISIONING_PROFILE_SPECIFIER="Totem AdHoc" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    TOTEM_SERVER_URL="${ONBOARD_BASE_URL:-}" \
    archive
xcodebuild -exportArchive -archivePath "$BUILD/Totem.xcarchive" \
    -exportPath "$BUILD/export" \
    -exportOptionsPlist "$REPO/Server/onboard/export-options.plist"
cp "$BUILD/export/Totem-iOS.ipa" "$BUILD/totem.ipa"
echo "$BUILD_NUMBER" > "$BUILD/version.txt"
echo "onboard build $BUILD_NUMBER complete"
