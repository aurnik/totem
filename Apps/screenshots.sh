#!/bin/zsh
# Captures App Store marketing screenshots of the iOS app on the simulator,
# one per ScreenshotFixture scene, at native 6.9" resolution (1320×2868).
#
#   Apps/screenshots.sh [output-dir]
#
# Builds a Debug copy into its own DerivedData (never the shared one — see
# CLAUDE.md on stale builds), seeds each scene through the `--screenshot`
# launch argument, and shuts the simulator down again when done.
set -euo pipefail

cd "$(dirname "$0")"
out="${1:-${TMPDIR:-/tmp}/totem-screenshots}"
device="iPhone 17 Pro Max"
scenes=(friends chat voice four)
derived="${TMPDIR:-/tmp}/totem-screenshots-derived"

udid=$(xcrun simctl list devices available -j \
  | python3 -c "import json,sys; d=json.load(sys.stdin)['devices']
print(next(x['udid'] for r,l in d.items() if 'iOS' in r for x in l if x['name']=='$device'))")

xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b >/dev/null
xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged \
  --batteryLevel 100 --cellularBars 4 --wifiBars 3 --operatorName ''

dest="platform=iOS Simulator,id=$udid"
xcodebuild -project Totem.xcodeproj -scheme Totem-iOS -configuration Debug \
  -destination "$dest" -derivedDataPath "$derived" build -quiet
products=$(xcodebuild -project Totem.xcodeproj -scheme Totem-iOS -configuration Debug \
  -destination "$dest" -derivedDataPath "$derived" -showBuildSettings 2>/dev/null \
  | awk '/ BUILT_PRODUCTS_DIR =/ {print $3}')
bundle=$(xcodebuild -project Totem.xcodeproj -scheme Totem-iOS -configuration Debug \
  -destination "$dest" -derivedDataPath "$derived" -showBuildSettings 2>/dev/null \
  | awk '/ PRODUCT_BUNDLE_IDENTIFIER =/ {print $3}')
xcrun simctl install "$udid" "$products/Totem-iOS.app"

mkdir -p "$out"
for scene in $scenes; do
  xcrun simctl launch --terminate-running-process "$udid" "$bundle" --screenshot "$scene" >/dev/null
  sleep 4
  xcrun simctl io "$udid" screenshot "$out/$scene.png" >/dev/null 2>&1
  echo "$out/$scene.png"
done

xcrun simctl shutdown "$udid"
