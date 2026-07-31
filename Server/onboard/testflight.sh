#!/bin/bash
# Archives and uploads a TestFlight build to App Store Connect. Same
# API-driven manual signing as sign.sh, but with the App Store profile and
# xcodebuild's built-in upload (no Transporter needed). The app record
# (com.deadsimple.totem) must already exist in App Store Connect.
# Requires:
#   ASC_KEY_ID      App Store Connect API key ID
#   ASC_ISSUER_ID   App Store Connect issuer ID
#   ASC_KEY_PATH    path to the .p8 private key (absolute)
set -euo pipefail
cd "$(dirname "$0")"

: "${ASC_KEY_ID:?ASC_KEY_ID is not set}"
: "${ASC_ISSUER_ID:?ASC_ISSUER_ID is not set}"
: "${ASC_KEY_PATH:?ASC_KEY_PATH is not set}"

TEAM_ID=BUQNMSY5Q2
SERVER_URL="${TOTEM_SERVER_URL:-https://totem-server-production.up.railway.app}"

if [ ! -d .venv ]; then
    python3 -m venv .venv
    ./.venv/bin/pip -q install PyJWT cryptography
fi
./.venv/bin/python provision.py

REPO="$(cd ../.. && pwd)"
BUILD="$REPO/Server/onboard/build"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"

cd "$REPO/Apps"
xcodegen generate
xcodebuild -project Totem.xcodeproj -scheme Totem-iOS -configuration Release \
    -destination "generic/platform=iOS" \
    -archivePath "$BUILD/Totem-TestFlight.xcarchive" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    PRODUCT_BUNDLE_IDENTIFIER=com.deadsimple.totem \
    CODE_SIGN_ENTITLEMENTS="$REPO/Server/onboard/dist.entitlements" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="Apple Distribution" \
    PROVISIONING_PROFILE_SPECIFIER="Totem AppStore" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    TOTEM_SERVER_URL="$SERVER_URL" \
    archive
xcodebuild -exportArchive -archivePath "$BUILD/Totem-TestFlight.xcarchive" \
    -exportPath "$BUILD/testflight-export" \
    -exportOptionsPlist "$REPO/Server/onboard/export-options-appstore.plist" \
    -authenticationKeyPath "$ASC_KEY_PATH" \
    -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
echo "TestFlight build $BUILD_NUMBER uploaded — it appears in App Store Connect after processing (~5-15 min)"
