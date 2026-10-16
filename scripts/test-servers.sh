#!/usr/bin/env bash
# Runs the live client tests and the UI tests against every server in test-servers.local.env
# (gitignored). Each server is a block of variables:
#
#   AUDIOBOOKSHELF_HOST=https://books.example.com      # an Audiobookshelf server (2.26 or later)
#   AUDIOBOOKSHELF_USERNAME=someone                     # a throwaway user: the tests play and
#   AUDIOBOOKSHELF_PASSWORD=…                           # write progress and bookmarks
#   AUDIOBOOKSHELF_DOWNLOAD_BOOK="a short book"         # optional
#
#   OWNAUDIO_HOST=https://demo.example.com              # an own.audio server
#   OWNAUDIO_EMAIL=guest@example.com
#   OWNAUDIO_ACCOUNT_PASSWORD=…
#   OWNAUDIO_DOWNLOAD_BOOK="a short book"               # optional
#
# Usage: scripts/test-servers.sh [audiobookshelf|ownaudio|demo] [--live-only]
# One UI test only: ONLY_TESTING=testPlaysAndResumes scripts/test-servers.sh
# (a test of another class, or a whole class: ONLY_TESTING=MisuseTests[/testHammeredPlayer])
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${TEST_OUTPUT:-/tmp/book-ios-tests}"
mkdir -p "$OUT"

# A run builds and tests a copy of the code taken at its start. Editing the checkout during a
# run otherwise makes xcodebuild reload the packages halfway, and it can hang there for good;
# bash, too, reads this script as it goes.
if [[ -z "${TEST_SNAPSHOT:-}" ]]; then
  rsync -a --delete --exclude .git --exclude .build --exclude '*.xcodeproj' --exclude DerivedData ./ "$OUT/src/"
  echo "== testing a copy of $(git rev-parse --short HEAD)$(git diff --quiet HEAD -- . && echo '' || echo ' with uncommitted changes') in $OUT/src"
  TEST_SNAPSHOT=1 exec bash "$OUT/src/scripts/test-servers.sh" "$@"
fi

source ./test-servers.local.env

SIM="${SIMULATOR_ID:-$(xcrun simctl list devices booted | grep -m1 -oE '[0-9A-F-]{36}')}"
only="${1:-all}"
live_only="${2:-}"

only_testing="${ONLY_TESTING:-}"
[[ "$only_testing" == *Tests* ]] || only_testing="PlaybackSmokeTests/$only_testing"

# Everything a run leaves, in $OUT/<name>/<time>-*: the whole xcodebuild log, the result bundle,
# the app's own log (subsystems audio.own.*), crash reports written meanwhile, and screenshots of
# the failures. The terminal shows each test as it starts and ends, every failure with its
# message, and a summary; $OUT/summary.txt collects the summaries of all runs. xcodebuild's own
# diagnostics after a failure are off: collecting them from the simulator could hang it for good.
xcode_tests() { # name dir [xcodebuild arguments…]
  local name=$1 dir=$2; shift 2
  local stamp; stamp=$(date +%Y%m%d-%H%M%S)
  local base="$dir/$stamp"
  mkdir -p "$dir"
  touch "$base.start"
  xcodegen generate >/dev/null
  xcrun simctl spawn "$SIM" log stream --level debug --style compact \
    --predicate 'subsystem BEGINSWITH "audio.own" OR (process == "OwnAudioBooks" AND messageType >= error)' \
    >"$base-app.log" 2>&1 &
  local logger=$!
  xcodebuild test -project OwnAudioBooks.xcodeproj -scheme OwnAudioBooks -destination "id=$SIM" \
    -derivedDataPath "$OUT/DerivedData" -resultBundlePath "$base.xcresult" \
    -collect-test-diagnostics never "$@" 2>&1 \
    | tee "$base-xcodebuild.log" \
    | grep --line-buffered -E "Test Case .*(started|passed|failed)|: error: |\*\* TEST|crashed|Restarting after" || true
  kill "$logger" 2>/dev/null || true
  find ~/Library/Logs/DiagnosticReports -name 'OwnAudioBooks*.ips' -newer "$base.start" -exec cp {} "$dir/" \; 2>/dev/null || true
  rm -f "$base.start"
  xcrun xcresulttool export attachments --path "$base.xcresult" --output-path "$base-failures" --only-failures >/dev/null 2>&1 || true
  summarize "$name" "$base"
}

summarize() { # name base
  local name=$1 base=$2
  python3 - "$name" "$base" <<'PY' | tee -a "$OUT/summary.txt"
import json, subprocess, sys, os
name, base = sys.argv[1], sys.argv[2]
try:
    raw = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", base + ".xcresult"],
                         capture_output=True, text=True, check=True).stdout
    nodes = json.loads(raw)["testNodes"]
except Exception as e:
    print(f"-- {name}: NO RESULTS, the run did not finish ({e.__class__.__name__}); see {base}-xcodebuild.log"); sys.exit()
cases = []
def walk(n):
    if n.get("nodeType") == "Test Case":
        msgs = []
        def m(c):
            if c.get("nodeType") == "Failure Message": msgs.append(c["name"])
            for k in c.get("children", []): m(k)
        m(n); cases.append((n["name"], n.get("result"), n.get("duration", ""), msgs))
    for c in n.get("children", []): walk(c)
for n in nodes: walk(n)
if not cases:
    print(f"-- {name}: NO TESTS RAN; see {base}-xcodebuild.log"); sys.exit()
passed = sum(1 for c in cases if c[1] == "Passed")
skipped = sum(1 for c in cases if c[1] == "Skipped")
failed = [c for c in cases if c[1] == "Failed"]
crashes = [f for f in os.listdir(os.path.dirname(base)) if f.endswith(".ips")]
print(f"-- {name}: {passed} passed, {len(failed)} failed, {skipped} skipped; logs {base}-*" + (f"; {len(crashes)} crash reports" if crashes else ""))
for case, _, duration, msgs in failed:
    print(f"   FAILED {case} ({duration})")
    for msg in msgs: print(f"      {msg[:400]}")
PY
}

ui_tests() { # name host user password download-book
  local name=$1 host=$2 user=$3 password=$4 book=${5:-}
  echo "== $name: UI tests (everything in $OUT/$name)"
  mkdir -p "$OUT/$name"
  TEST_RUNNER_SERVER_HOST="$host" TEST_RUNNER_SERVER_USER="$user" TEST_RUNNER_SERVER_PASSWORD="$password" \
  TEST_RUNNER_SERVER_DOWNLOAD_BOOK="$book" TEST_RUNNER_SCREENSHOT_DIR="$OUT/$name" \
    xcode_tests "$name" "$OUT/$name" -test-timeouts-enabled YES -default-test-execution-time-allowance 420 \
      ${ONLY_TESTING:+-only-testing:"OwnAudioBooksUITests/$only_testing"}
}

# A package's live tests; a failure is reported and the run goes on to the next server.
live_tests() { # name package [env assignments…]
  local name=$1 package=$2; shift 2
  local log="$OUT/$name/$(date +%Y%m%d-%H%M%S)-live-$package.log"
  mkdir -p "$OUT/$name"
  (cd "Packages/$package" && env "$@" swift test --filter Live >"$log" 2>&1) || true
  grep -E "✘|Test run" "$log" | tee -a "$OUT/summary.txt" || echo "-- $name: live tests left no result, see $log"
}

# One build first: a change that doesn't compile stops here instead of failing every server.
echo "== building"
mkdir -p "$OUT"
xcodegen generate >/dev/null
if ! xcodebuild build-for-testing -project OwnAudioBooks.xcodeproj -scheme OwnAudioBooks -destination "id=$SIM" \
    -derivedDataPath "$OUT/DerivedData" >"$OUT/build.log" 2>&1; then
  grep -E ": error: " "$OUT/build.log" | sort -u
  echo "-- build failed, see $OUT/build.log" | tee -a "$OUT/summary.txt"
  exit 1
fi

# No server at all: the launch test, so a broken first screen is caught before any server run.
echo "== launch"
xcode_tests launch "$OUT/launch" -only-testing:OwnAudioBooksUITests/LaunchTests

if [[ "$only" == all || "$only" == audiobookshelf ]]; then
  echo "== audiobookshelf: live client tests"
  live_tests audiobookshelf AudiobookshelfKit AUDIOBOOKSHELF_HOST="$AUDIOBOOKSHELF_HOST" \
    AUDIOBOOKSHELF_USERNAME="$AUDIOBOOKSHELF_USERNAME" AUDIOBOOKSHELF_PASSWORD="$AUDIOBOOKSHELF_PASSWORD"
  live_tests audiobookshelf BookLibrary AUDIOBOOKSHELF_HOST="$AUDIOBOOKSHELF_HOST" \
    AUDIOBOOKSHELF_USERNAME="$AUDIOBOOKSHELF_USERNAME" AUDIOBOOKSHELF_PASSWORD="$AUDIOBOOKSHELF_PASSWORD"
  [[ "$live_only" == "--live-only" ]] || ui_tests audiobookshelf "$AUDIOBOOKSHELF_HOST" "$AUDIOBOOKSHELF_USERNAME" "$AUDIOBOOKSHELF_PASSWORD" "${AUDIOBOOKSHELF_DOWNLOAD_BOOK:-}"
fi

if [[ "$only" == all || "$only" == ownaudio ]]; then
  echo "== ownaudio: live client tests"
  live_tests ownaudio OwnAudioKit OWNAUDIO_HOST="$OWNAUDIO_HOST" OWNAUDIO_EMAIL="$OWNAUDIO_EMAIL" OWNAUDIO_ACCOUNT_PASSWORD="$OWNAUDIO_ACCOUNT_PASSWORD"
  # BookLibrary's live tests also import the tiny "Test Author" book the UI tests download as a
  # set; the demo server forgets it every night.
  live_tests ownaudio BookLibrary OWNAUDIO_HOST="$OWNAUDIO_HOST" OWNAUDIO_EMAIL="$OWNAUDIO_EMAIL" OWNAUDIO_ACCOUNT_PASSWORD="$OWNAUDIO_ACCOUNT_PASSWORD"
  [[ "$live_only" == "--live-only" ]] || ui_tests ownaudio "$OWNAUDIO_HOST" "$OWNAUDIO_EMAIL" "$OWNAUDIO_ACCOUNT_PASSWORD" "${OWNAUDIO_DOWNLOAD_BOOK:-}"
fi

if [[ "$only" == all || "$only" == demo ]] && [[ "$live_only" != "--live-only" ]]; then
  echo "== demo: Try the Demo Library"
  TEST_RUNNER_DEMO=1 xcode_tests demo "$OUT/demo" -only-testing:OwnAudioBooksUITests/DemoTests
fi
