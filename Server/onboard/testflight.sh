#!/bin/bash
# Archive and upload a TestFlight build with API-driven manual signing
# (provision.py) and xcodebuild's built-in upload.
#
#   ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH   App Store Connect API key
#   TOTEM_TEAM_ID                             Apple developer team
#   TOTEM_SERVER_URL                          server baked into the build
#   TOTEM_TESTFLIGHT_APP_ID                   numeric App Store id (update banner)
#   TOTEM_TESTFLIGHT_JOIN_CODE                public TestFlight link code (optional)
set -euo pipefail
cd "$(dirname "$0")"

: "${ASC_KEY_ID:?ASC_KEY_ID is not set}"
: "${ASC_ISSUER_ID:?ASC_ISSUER_ID is not set}"
: "${ASC_KEY_PATH:?ASC_KEY_PATH is not set}"
: "${TOTEM_TEAM_ID:?TOTEM_TEAM_ID is not set}"
: "${TOTEM_SERVER_URL:?TOTEM_SERVER_URL is not set}"
: "${TOTEM_TESTFLIGHT_APP_ID:?TOTEM_TESTFLIGHT_APP_ID is not set}"

[ -d "$HOME/tools/xcodegen/bin" ] && PATH="$HOME/tools/xcodegen/bin:$PATH"

if [ ! -d .venv ]; then
    python3 -m venv .venv
    ./.venv/bin/pip -q install PyJWT cryptography
fi
./.venv/bin/python provision.py

REPO="$(cd ../.. && pwd)"
BUILD="$REPO/Server/onboard/build"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
mkdir -p "$BUILD"
sed "s/TEAM_ID/$TOTEM_TEAM_ID/" export-options-appstore.plist > "$BUILD/export-options.plist"

cd "$REPO/Apps"
xcodegen generate
xcodebuild -project Totem.xcodeproj -scheme Totem-iOS -configuration Release \
    -destination "generic/platform=iOS" \
    -archivePath "$BUILD/Totem-TestFlight.xcarchive" \
    DEVELOPMENT_TEAM="$TOTEM_TEAM_ID" \
    PRODUCT_BUNDLE_IDENTIFIER=com.deadsimple.totem \
    CODE_SIGN_ENTITLEMENTS="$REPO/Server/onboard/dist.entitlements" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="Apple Distribution" \
    PROVISIONING_PROFILE_SPECIFIER="Totem AppStore" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    TOTEM_SERVER_URL="$TOTEM_SERVER_URL" \
    TOTEM_TESTFLIGHT_APP_ID="$TOTEM_TESTFLIGHT_APP_ID" \
    TOTEM_TESTFLIGHT_JOIN_CODE="${TOTEM_TESTFLIGHT_JOIN_CODE:-}" \
    archive
xcodebuild -exportArchive -archivePath "$BUILD/Totem-TestFlight.xcarchive" \
    -exportPath "$BUILD/testflight-export" \
    -exportOptionsPlist "$BUILD/export-options.plist" \
    -authenticationKeyPath "$ASC_KEY_PATH" \
    -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
echo "TestFlight build $BUILD_NUMBER uploaded; it appears in App Store Connect after processing."
