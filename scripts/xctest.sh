#!/bin/bash
#
# Run xcodebuild tests with every shared resource this repository can contend on pinned down.
#
# Usage — pass whatever you would have passed to `xcodebuild test`:
#
#     scripts/xctest.sh -scheme ElephruitiOS \
#         -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
#         -only-testing:ElephruitiOSUITests/TodayFeedUITests
#
# ## What it pins, and why
#
# **A simulator lock.** This is the one that genuinely bites. Every worktree targets the same
# handful of simulators by name, and the app has one bundle identifier — so two runs at once install
# over each other, terminate each other's process, and race on the same app container. The symptom
# is not a clean failure; it is a test that hangs at "Installing" or one that fails an assertion
# about state another run just wiped. The lock is machine-wide, taken only for simulator
# destinations, and released on any exit including a kill.
#
# **Derived data, per worktree.** Xcode already isolates this by hashing the project's path, so this
# is belt to that braces — but an explicit path is one you can delete, and sixty-odd
# `Elephruit-<random>` directories under `~/Library/Developer/Xcode/DerivedData` is what the implicit
# scheme leaves behind.
#
# **Serial testing.** UI tests drive one device; parallel workers on one device is a race by
# construction.
#
# **A result bundle, always.** Named by the moment it started, so a failure can be opened after the
# fact rather than re-run to be seen. `xcrun xcresulttool export attachments` gets the screenshots
# and the accessibility tree out of it, which is usually what a UI-test failure needs.
#
# Plain builds deliberately do *not* go through here. Building is not a shared resource, and making
# compilation wait on somebody else's simulator would be the slowest possible way to be correct.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
STATE="$ROOT/.xcode-local"
STAMP="$(date +%Y%m%d-%H%M%S)"
RESULT="$STATE/Results/$STAMP.xcresult"

mkdir -p "$STATE/DerivedData" "$STATE/Packages" "$STATE/Results"

# Only simulator runs contend for a device. A macOS test target does not.
NEEDS_DEVICE=no
for arg in "$@"; do
    case "$arg" in
        *"Simulator"*) NEEDS_DEVICE=yes ;;
    esac
done

LOCK=/tmp/elephruit-simulator-tests.lock

if [ "$NEEDS_DEVICE" = yes ]; then
    # `shlock` is the BSD tool for exactly this: it writes our pid and refuses only while the pid
    # that holds the lock is still alive, so a run killed mid-flight does not wedge every worktree.
    WAITED=0
    until /usr/bin/shlock -f "$LOCK" -p $$; do
        if [ "$WAITED" -eq 0 ]; then
            echo "xctest: waiting for the simulator lock held by pid $(cat "$LOCK" 2>/dev/null)" >&2
        fi
        if [ "$WAITED" -ge 2700 ]; then
            echo "xctest: gave up after 45 minutes waiting for $LOCK" >&2
            exit 75
        fi
        sleep 10
        WAITED=$((WAITED + 10))
    done
    trap 'rm -f "$LOCK"' EXIT
fi

echo "xctest: results → $RESULT"

xcodebuild test \
    -project "$ROOT/Elephruit.xcodeproj" \
    -derivedDataPath "$STATE/DerivedData" \
    -clonedSourcePackagesDirPath "$STATE/Packages" \
    -resultBundlePath "$RESULT" \
    -parallel-testing-enabled NO \
    -maximum-parallel-testing-workers 1 \
    "$@"
