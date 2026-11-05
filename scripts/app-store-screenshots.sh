#!/usr/bin/env bash
# Takes the App Store screenshots on the store's required sizes, in English and Czech, in light
# mode. From test-servers.local.env: SCREENSHOT_HOST, an own.audio server holding only the demo
# library (seeded by audio2's deploy/demo/seed.py, whose books and covers may be shown publicly),
# and SCREENSHOT_EMAIL / SCREENSHOT_PASSWORD, the account that owns those books and runs its
# family — the same server and account as own.audio Music's screenshots.
#
# Usage: scripts/app-store-screenshots.sh   → AppStore/screenshots/<language>/<device>/
#        ONLY_DEVICE="iPhone 17 Pro Max" LANGUAGES=en scripts/app-store-screenshots.sh
set -euo pipefail
cd "$(dirname "$0")/.."
source ./test-servers.local.env

DEVICES=("iPhone 17 Pro Max" "iPad Pro 13-inch (M5)")
[[ -n "${ONLY_DEVICE:-}" ]] && DEVICES=("$ONLY_DEVICE")
BOOK="${SCREENSHOT_BOOK:-Just So Stories}"
DERIVED="${TEST_OUTPUT:-/tmp/book-ios-tests}/DerivedData"
# Half an hour per run: the iPad simulator is sometimes very slow, and the download takes a while.

xcodegen generate >/dev/null
for device in "${DEVICES[@]}"; do
  # The newest device of that name: an older one may sit on a runtime that is no longer installed.
  id=$(xcrun simctl list devices available | grep -F "$device (" | tail -1 | grep -oE '[0-9A-F-]{36}')
  xcrun simctl boot "$id" 2>/dev/null || true
  xcrun simctl ui "$id" appearance light
  xcrun simctl status_bar "$id" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
  for language in ${LANGUAGES:-en cs}; do
    out="AppStore/screenshots/$language/$device"
    rm -rf "$out"
    mkdir -p "$out"
    echo "== $device, $language"
    TEST_RUNNER_SERVER_HOST="${SCREENSHOT_HOST:-$OWNAUDIO_HOST}" TEST_RUNNER_SERVER_USER="${SCREENSHOT_EMAIL:-$OWNAUDIO_EMAIL}" \
    TEST_RUNNER_SERVER_PASSWORD="${SCREENSHOT_PASSWORD:-$OWNAUDIO_ACCOUNT_PASSWORD}" \
    TEST_RUNNER_SCREENSHOT_DIR="$PWD/$out" TEST_RUNNER_SCREENSHOT_LANGUAGE="$language" TEST_RUNNER_SCREENSHOT_BOOK="$BOOK" \
      xcodebuild test -project OwnAudioBooks.xcodeproj -scheme OwnAudioBooks -destination "id=$id" \
        -derivedDataPath "$DERIVED" -only-testing:OwnAudioBooksUITests/AppStoreScreenshots \
        -test-timeouts-enabled YES -default-test-execution-time-allowance 1800 -maximum-test-execution-time-allowance 1800 2>&1 \
      | grep -E "Test Case.*(passed|failed)|\*\* TEST|error:"
  done
  xcrun simctl status_bar "$id" clear
done
