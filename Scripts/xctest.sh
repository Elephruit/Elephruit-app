#!/usr/bin/env bash
#
# One way to build and test this project from a worktree, without two worktrees
# standing on each other.
#
# ## Why this exists
#
# This repository is worked in many worktrees at once — often more than a dozen, several of
# them driven by agents in parallel. `xcodebuild` was never told they were separate, so by
# default every one of them shared the same Derived Data, the same cloned packages, the same
# result bundle path, and the same simulator, including that simulator's copy of the installed
# app and test runner.
#
# What that looks like when it goes wrong is not a clean error. It looks like a test failing
# with an assertion message that does not exist in your source, quoting a file path belonging
# to a branch you have never checked out — because the run picked up another worktree's compiled
# test bundle. It also looks like tests that fail once and pass alone, `IDEResultKit` failing to
# read a result bundle another process was writing, and runs that die with "Restarting after
# unexpected exit, crash, or test timeout" with nothing in the log to explain it. All four have
# happened here.
#
# So: per-worktree state, one test process at a time, and a machine-wide lock so that two
# worktrees cannot drive the simulator at once. Ordinary builds are not locked — they write only
# into this worktree's own Derived Data, and there is no reason to serialise them.
#
# ## Usage
#
#   Scripts/xctest.sh test                              # the iPhone suite
#   Scripts/xctest.sh test -only-testing:Foo/BarTests   # extra flags pass straight through
#   Scripts/xctest.sh build                             # build only, no lock taken
#
# Overridable by environment:
#   ELEPHRUIT_SCHEME        default ElephruitiOS       (Elephruit for the Mac app)
#   ELEPHRUIT_DESTINATION   default an iPhone simulator by name. Give this an `id=<UDID>` of a
#                           simulator only this worktree uses and the lock stops costing you
#                           anything — separate devices cannot collide.
#   ELEPHRUIT_LOCK_TIMEOUT  seconds to wait for the simulator lock, default 3600
#   ELEPHRUIT_IDLE_TIMEOUT  seconds of silence before a run is treated as stuck and killed,
#                           default 300. This is the limit that does the work — see below.
#   ELEPHRUIT_RUN_TIMEOUT   total seconds before a run is killed regardless, default 3600. A
#                           backstop for a process that hangs while still printing.
#   ELEPHRUIT_RESULT_BUNDLE set to 1 to write an .xcresult bundle. Off by default: it is only
#                           useful if something is going to read it, and it is implicated in
#                           xcodebuild hanging after the run.
#
# ## The watchdog
#
# `xcodebuild test` does not reliably exit when the tests are over. Observed here: the suite
# printed its summary at 08:35:48 and the process was still alive eight minutes later with no
# further output. On its own that is an annoyance; combined with a machine-wide lock it is much
# worse, because a run that never ends holds the lock forever and every other worktree queues
# behind it. So the lock is only ever held by a process that is guaranteed to die, and the trap
# takes xcodebuild down with the script rather than leaving it parented to init.
#
# The kill is on *silence*, not on elapsed time. A total timeout has to be set long enough for
# the largest honest suite, which means a hung run sits on the lock for that whole time — with a
# dozen worktrees waiting, that is the difference between a usable lock and an unusable one. A
# stuck run is not a slow run; it is a quiet one. Five minutes without a line is not a suite
# being thorough.
#
# Swift package tests (`swift test` in Packages/ElephruitKit) do not need any of this: they
# build into their own .build directory and never touch a simulator.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
STATE="$ROOT/.xcode-local"
PROJECT="$ROOT/Elephruit.xcodeproj"

SCHEME="${ELEPHRUIT_SCHEME:-ElephruitiOS}"
DESTINATION="${ELEPHRUIT_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro}"
LOCK_TIMEOUT="${ELEPHRUIT_LOCK_TIMEOUT:-3600}"
RUN_TIMEOUT="${ELEPHRUIT_RUN_TIMEOUT:-3600}"
IDLE_TIMEOUT="${ELEPHRUIT_IDLE_TIMEOUT:-300}"

# Deliberately outside any worktree: the point of it is to be the *same* lock for all of them.
#
# The path and the mechanism both have to match every other wrapper in the fleet, or the lock is
# worse than no lock — two scripts guarding the same simulator with different files each believe
# they are alone. This name and `shlock` are what `scripts/xctest.sh` on the
# schedule-feed-scrolling branch already uses; if those two ever converge into one script, this
# is the pair to keep.
LOCK_FILE="${ELEPHRUIT_LOCK_FILE:-/tmp/elephruit-simulator-tests.lock}"

# The running xcodebuild, so that every way out of this script takes it down too.
CHILD=""

# The `tail` echoing that run's output back to the terminal.
TAIL=""

# Whether this process is the one holding the lock. Checked before releasing it, so that a path
# which never acquired the lock can never delete another worktree's.
HOLDS_LOCK=0

usage() {
    cat >&2 <<'USAGE'
usage: Scripts/xctest.sh {build|test} [extra xcodebuild arguments...]

  build   compile only; takes no lock
  test    build and run tests; serialised against every other worktree

Environment: ELEPHRUIT_SCHEME, ELEPHRUIT_DESTINATION, ELEPHRUIT_LOCK_TIMEOUT,
             ELEPHRUIT_RUN_TIMEOUT, ELEPHRUIT_RESULT_BUNDLE
USAGE
    exit 64
}

# Everything this script owns, released on every exit path there is.
#
# The lock matters more than the process: a wrapper killed from outside would otherwise leave
# both a lock directory and a live xcodebuild still driving the simulator, which is the exact
# state the lock exists to prevent.
cleanup() {
    if [ -n "$CHILD" ] && kill -0 "$CHILD" 2>/dev/null; then
        kill -TERM "$CHILD" 2>/dev/null || true
        sleep 2
        kill -KILL "$CHILD" 2>/dev/null || true
    fi
    if [ -n "$TAIL" ]; then
        kill "$TAIL" 2>/dev/null || true
    fi
    if [ "$HOLDS_LOCK" = "1" ]; then
        rm -f "$LOCK_FILE"
    fi
}

# Runs xcodebuild under a watchdog, because it cannot be trusted to end.
#
# Two limits, and the idle one is the one that matters. The hang this exists for happens *after*
# the run is over — the summary prints, and then nothing, for as long as you are willing to wait.
# So the useful question is not "has this taken too long", which a large honest suite also
# answers yes to, but "has it stopped saying anything", which only a stuck run does. Output goes
# to a file so its size can be watched; `tail` puts it back on the terminal so the run still
# reads live.
#
# Killed rather than waited on, and the exit status says so: a run that had to be killed is not
# a run that passed, whatever it printed before it went quiet.
run_watched() {
    local log="$STATE/last-run.log"
    local waited=0
    local idle=0
    local size=0
    local seen=0
    local status=0

    : >"$log"

    "$@" >"$log" 2>&1 &
    CHILD=$!

    tail -f "$log" 2>/dev/null &
    TAIL=$!

    while kill -0 "$CHILD" 2>/dev/null; do
        sleep 10
        waited=$((waited + 10))

        size=$(wc -c <"$log" | tr -d ' ')
        if [ "$size" != "$seen" ]; then
            seen="$size"
            idle=0
        else
            idle=$((idle + 10))
        fi

        if [ "$idle" -ge "$IDLE_TIMEOUT" ]; then
            echo "xctest: no output for ${IDLE_TIMEOUT}s — killing a stuck xcodebuild" >&2
            echo "xctest: the tests may well have finished; read the output above" >&2
            status=124
            break
        fi

        if [ "$waited" -ge "$RUN_TIMEOUT" ]; then
            echo "xctest: still running after ${RUN_TIMEOUT}s — killing it" >&2
            status=124
            break
        fi
    done

    if [ "$status" = "124" ]; then
        kill -TERM "$CHILD" 2>/dev/null || true
        sleep 5
        kill -KILL "$CHILD" 2>/dev/null || true
        wait "$CHILD" 2>/dev/null || true
    else
        wait "$CHILD" || status=$?
    fi

    CHILD=""
    # A moment for `tail` to flush the last of the file before it is taken away.
    sleep 1
    kill "$TAIL" 2>/dev/null || true
    TAIL=""

    return "$status"
}

# `shlock`, the BSD tool that exists for exactly this. macOS ships no `flock`, and it beats a
# hand-rolled `mkdir` lock on the part that matters: it records the holder's pid and refuses the
# lock only while that pid is still alive, so a run killed before its trap fires clears itself
# instead of wedging every worktree behind a directory nobody owns.
acquire_lock() {
    local waited=0

    until /usr/bin/shlock -f "$LOCK_FILE" -p $$; do
        if [ "$waited" -eq 0 ]; then
            echo "xctest: waiting for the simulator (held by pid $(cat "$LOCK_FILE" 2>/dev/null))" >&2
        fi

        sleep 10
        waited=$((waited + 10))

        if [ "$waited" -ge "$LOCK_TIMEOUT" ]; then
            echo "xctest: gave up waiting for $LOCK_FILE after ${LOCK_TIMEOUT}s" >&2
            echo "xctest: if nothing is running, remove that file" >&2
            exit 75
        fi
    done

    HOLDS_LOCK=1
}

[ $# -ge 1 ] || usage
action="$1"
shift

trap cleanup EXIT INT TERM

mkdir -p "$STATE/DerivedData" "$STATE/Packages" "$STATE/Results"

common=(
    -project "$PROJECT"
    -scheme "$SCHEME"
    -derivedDataPath "$STATE/DerivedData"
    -clonedSourcePackagesDirPath "$STATE/Packages"
)

case "$action" in
build)
    exec xcodebuild build "${common[@]}" -destination "$DESTINATION" "$@"
    ;;
test)
    # Only simulator runs contend for a device. A `platform=macOS` destination is the machine
    # itself, and locking it would serialise runs that were never going to collide.
    case "$DESTINATION" in
    *Simulator*) acquire_lock ;;
    esac

    bundle=()
    if [ "${ELEPHRUIT_RESULT_BUNDLE:-0}" = "1" ]; then
        results="$STATE/Results/$(date +%Y%m%d-%H%M%S)-$$.xcresult"
        echo "xctest: results at $results" >&2
        bundle=(-resultBundlePath "$results")
    fi

    # `${bundle[@]+...}`, not a bare `${bundle[@]}`: macOS ships bash 3.2, where expanding an
    # empty array under `set -u` is an unbound-variable error rather than nothing at all.
    run_watched xcodebuild test "${common[@]}" \
        -destination "$DESTINATION" \
        ${bundle[@]+"${bundle[@]}"} \
        -parallel-testing-enabled NO \
        -maximum-parallel-testing-workers 1 \
        "$@"
    ;;
*)
    usage
    ;;
esac
