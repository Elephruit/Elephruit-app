#!/usr/bin/env bash
#
# Build this branch *merged with main*, before anyone merges it for real.
#
# ## Why this exists
#
# A branch can build, `main` can build, and the merge of the two can fail — because git merges
# text and the compiler checks meaning. Nothing in the normal loop looks at that combination:
# you build your branch, CI does not exist, and the first thing to compile the merge is the
# person who pulls after it lands.
#
# It has bitten the iPad twice. The iPad shell is the reliable victim for a structural reason
# rather than a careless one: `ElephruitiOS/Pad/` reuses views that were written for the phone,
# it is the newest part of the app so branches cut before it exist do not contain it, and a
# `grep` for a view's callers in a worktree that predates the file finds nothing and reports the
# view as unused. Deleting it is then a perfectly reasonable local decision that breaks a target
# the branch has never seen.
#
# So: merge into a throwaway worktree and build both apps. The merge is never committed and the
# branch is never touched — the worktree is deleted whatever happens.
#
# ## Usage
#
#     Scripts/premerge.sh              # against origin/main
#     Scripts/premerge.sh origin/foo   # against something else
#
# Run it before opening a PR, and again before merging one that has been open long enough for
# main to have moved. It builds; it does not test. A build is what catches this class of
# problem, and it is the part that costs a minute rather than ten.

set -euo pipefail

TARGET="${1:-origin/main}"
REMOTE="${TARGET%%/*}"
ROOT="$(git rev-parse --show-toplevel)"
SCRATCH=""

cleanup() {
    if [ -n "$SCRATCH" ]; then
        git -C "$ROOT" worktree remove --force "$SCRATCH" 2>/dev/null || true
        rm -rf "$SCRATCH"
    fi
}
trap cleanup EXIT INT TERM

# Tolerant, because the target is usually `origin/main` but is allowed to be a bare sha — which
# is not a remote, and failing to fetch one is not a reason to refuse to check it.
if [ "$REMOTE" != "$TARGET" ]; then
    echo "premerge: fetching $REMOTE" >&2
    git -C "$ROOT" fetch --quiet "$REMOTE" || true
fi

head_sha="$(git -C "$ROOT" rev-parse HEAD)"
target_sha="$(git -C "$ROOT" rev-parse "$TARGET")"

if git -C "$ROOT" merge-base --is-ancestor "$target_sha" "$head_sha"; then
    echo "premerge: already contains $TARGET — nothing to check" >&2
    exit 0
fi

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/elephruit-premerge.XXXXXX")"
rm -rf "$SCRATCH"

echo "premerge: merging $TARGET into a throwaway worktree" >&2
git -C "$ROOT" worktree add --quiet --detach "$SCRATCH" "$head_sha"

if ! git -C "$SCRATCH" merge --no-commit --no-ff "$target_sha" >/dev/null 2>&1; then
    echo "premerge: this branch conflicts with $TARGET — resolve it before merging:" >&2
    git -C "$SCRATCH" diff --name-only --diff-filter=U >&2
    exit 1
fi

# The merged worktree builds through the same wrapper, so it gets its own Derived Data rather
# than reusing — or corrupting — the state of the branch being checked.
echo "premerge: building the merged tree" >&2

status=0
for scheme in ElephruitiOS Elephruit; do
    echo "premerge: $scheme" >&2
    # `cd` first, and it is the whole check. `xctest.sh` finds the project through
    # `git rev-parse --show-toplevel`, which answers for the *current directory* rather than for
    # the script's own path — so invoking it by absolute path from here built the unmerged
    # worktree and cheerfully reported that the merge was fine. A guard that quietly checks the
    # wrong tree is worse than no guard, because it is believed.
    if (
        cd "$SCRATCH" &&
            ELEPHRUIT_SCHEME="$scheme" \
                ELEPHRUIT_DESTINATION="$( [ "$scheme" = Elephruit ] && echo "platform=macOS" || echo "generic/platform=iOS Simulator" )" \
                ./Scripts/xctest.sh build
    ) >"$SCRATCH/premerge-$scheme.log" 2>&1; then
        echo "premerge: $scheme built" >&2
    else
        echo "premerge: $scheme FAILED —" >&2
        grep -E "error:" "$SCRATCH/premerge-$scheme.log" | head -20 >&2
        status=1
    fi
done

if [ "$status" -eq 0 ]; then
    echo "premerge: the merge of this branch and $TARGET builds" >&2
else
    echo "premerge: the merge does not build. Fix it here, not after it lands." >&2
fi

exit "$status"
