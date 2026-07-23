#!/bin/bash
# Registers a device with App Store Connect, then archives and exports an
# ad-hoc IPA whose provisioning profile includes every registered device.
# Invoked by OnboardController with the UDID as $1; output lands in
# build/totem.ipa. Requires:
#   ASC_KEY_ID     App Store Connect API key ID
#   ASC_ISSUER_ID  App Store Connect issuer ID
#   ASC_KEY_PATH   path to the .p8 private key
set -euo pipefail
cd "$(dirname "$0")"
UDID="$1"

: "${ASC_KEY_ID:?ASC_KEY_ID is not set}"
: "${ASC_ISSUER_ID:?ASC_ISSUER_ID is not set}"
: "${ASC_KEY_PATH:?ASC_KEY_PATH is not set}"

if [ ! -d .venv ]; then
    python3 -m venv .venv
    ./.venv/bin/pip -q install PyJWT cryptography
fi
./.venv/bin/python register_device.py "$UDID"

REPO="$(cd ../.. && pwd)"
BUILD="$REPO/Server/onboard/build"
AUTH=(-allowProvisioningUpdates
      -authenticationKeyPath "$ASC_KEY_PATH"
      -authenticationKeyID "$ASC_KEY_ID"
      -authenticationKeyIssuerID "$ASC_ISSUER_ID")

cd "$REPO/Apps"
xcodebuild -project Totem.xcodeproj -scheme Totem-iOS -configuration Release \
    -destination "generic/platform=iOS" \
    -archivePath "$BUILD/Totem.xcarchive" archive "${AUTH[@]}"
xcodebuild -exportArchive -archivePath "$BUILD/Totem.xcarchive" \
    -exportPath "$BUILD/export" \
    -exportOptionsPlist "$REPO/Server/onboard/export-options.plist" "${AUTH[@]}"
cp "$BUILD/export/Totem-iOS.ipa" "$BUILD/totem.ipa"
echo "onboard build complete"
