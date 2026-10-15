#!/usr/bin/env bash
# Archives a release build and uploads it to App Store Connect for TestFlight.
#
# Needs DEVELOPMENT_TEAM in release.local.env (gitignored) and an Apple account with that team
# signed in to Xcode. The build number is the commit count, so every upload is unique.
#
# Usage: scripts/testflight.sh
set -euo pipefail
cd "$(dirname "$0")/.."
source ./release.local.env

BUILD=$(git rev-list --count HEAD)
OUT="${RELEASE_OUTPUT:-/tmp/book-ios-release}"
mkdir -p "$OUT"
cat > "$OUT/upload.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>app-store-connect</string>
	<key>destination</key><string>upload</string>
	<key>teamID</key><string>$DEVELOPMENT_TEAM</string>
	<key>signingStyle</key><string>automatic</string>
	<key>uploadSymbols</key><true/>
</dict>
</plist>
PLIST

xcodegen generate >/dev/null
echo "== archiving build $BUILD"
xcodebuild -project OwnAudioBooks.xcodeproj -scheme OwnAudioBooks -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$OUT/OwnAudioBooks.xcarchive" \
  -derivedDataPath "$OUT/DerivedData" -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" CODE_SIGN_STYLE=Automatic CURRENT_PROJECT_VERSION="$BUILD" \
  archive > "$OUT/archive.log" 2>&1 || { tail -30 "$OUT/archive.log"; exit 1; }
echo "== uploading"
xcodebuild -exportArchive -archivePath "$OUT/OwnAudioBooks.xcarchive" -exportOptionsPlist "$OUT/upload.plist" \
  -exportPath "$OUT/upload" -allowProvisioningUpdates > "$OUT/upload.log" 2>&1 || { tail -30 "$OUT/upload.log"; exit 1; }
grep -E "Upload succeeded|EXPORT SUCCEEDED" "$OUT/upload.log"
