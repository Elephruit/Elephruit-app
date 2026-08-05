#!/bin/bash
#
# Photograph a screen of the iOS app without running a test.
#
#     scripts/shot.sh out.png [extra launch arguments…]
#
# ## Why this exists
#
# Most of what a redesign needs is a *look*, and a look was costing a full `xcodebuild test`:
# resolve the package graph, build, install, launch, drive, tear down — ninety seconds and up,
# against about eight seconds of actual app. Worse, it costs the shared simulator lock, so every
# other worktree waits while somebody squints at a screenshot.
#
# A test is for asserting something. When the question is "what does it look like now", install the
# app that is already built, launch it with the fixture arguments, and take a picture.
#
# Assertions still belong in `ElephruitiOSUITests`; this does not replace them. It replaces running
# them when nothing is being asserted.
#
# The build is your business — run `xcodebuild build` (or let `xctest.sh` do it) first. This uses
# whatever is in the worktree's derived data.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
APP="$ROOT/.xcode-local/DerivedData/Build/Products/Debug-iphonesimulator/Elephruit.app"
BUNDLE=com.elephruit.ElephruitMemory.iOS
DEVICE="${ELEPHRUIT_SIM:-iPhone 17 Pro}"

OUT="${1:?usage: shot.sh out.png [launch arguments…]}"
shift || true

if [ ! -d "$APP" ]; then
    echo "shot: no app at $APP — build first" >&2
    exit 1
fi

xcrun simctl bootstatus "$DEVICE" -b > /dev/null

# Reinstalled every time: the app under test is the thing that just changed, and simctl will happily
# keep running the previous copy otherwise.
xcrun simctl install "$DEVICE" "$APP"

# Terminated rather than relaunched over: a warm process keeps the store it opened, and the fixture
# arguments are read once at launch.
xcrun simctl terminate "$DEVICE" "$BUNDLE" 2> /dev/null || true

xcrun simctl launch "$DEVICE" "$BUNDLE" \
    -ElephruitDevelopmentMode \
    -ElephruitUseTemporaryStore \
    -ElephruitLoadSampleData \
    -ElephruitUseFixtureCalendar \
    -ElephruitFixturesAuthorized \
    "$@" > /dev/null

# The app opens its store and assembles the day synchronously before the first frame, but the
# calendar is an actor behind a permission and answers a beat later.
sleep 4

xcrun simctl io "$DEVICE" screenshot "$OUT" 2> /dev/null
echo "shot: $OUT"
