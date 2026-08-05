# Repository workflow

These rules apply to every task in this repository.

## Worktrees are required

- Do not make implementation, test, documentation, or configuration changes in the primary checkout.
- Before changing files, create or select a dedicated Git worktree for the task.
- Create new task branches with the `codex/` prefix unless the user requests another name.
- Keep the primary checkout on `main` and use it only for inspection, coordination, and worktree management.
- If a task begins with uncommitted changes in the primary checkout, stop and resolve their ownership with the user before creating or moving work.

## Build and test through `Scripts/xctest.sh`

- Never call `xcodebuild` directly. Use `Scripts/xctest.sh build` and `Scripts/xctest.sh test`,
  which pass extra arguments (`-only-testing:`, and so on) straight through.
- This is not a style preference. Many worktrees are open at once and several are driven in
  parallel, and a bare `xcodebuild` shares Derived Data, cloned packages, the result bundle path
  and the simulator with all of them. The script gives each worktree its own state under
  `.xcode-local/`, runs tests serially, and takes a machine-wide lock so no two worktrees drive
  the simulator at the same time.
- Read a strange test failure with this in mind before believing it. Contention does not
  announce itself: it looks like an assertion message that does not exist in your source, a file
  path from a branch you have never checked out, a crash with nothing in the log, or a failure
  that will not reproduce when the test is run on its own. All four have happened here.
- Equally, do not blame contention by default. Most failures are real. Re-run the one test alone
  before concluding anything, and only then decide which kind of problem you have.
- `swift test` in `Packages/ElephruitKit` needs none of this — it builds into its own `.build`
  directory and never touches a simulator.
- If you write another wrapper, it must take the *same* lock: `/usr/bin/shlock` on
  `/tmp/elephruit-simulator-tests.lock`. Two wrappers guarding one simulator with different lock
  files is worse than no lock at all, because each one believes it is alone. A second wrapper
  already exists on the schedule-feed-scrolling branch as `scripts/xctest.sh`; the two share the
  lock deliberately, and should be collapsed into one script when either lands.
- `xcodebuild test` does not reliably exit when the tests are over; it has been seen alive eight
  minutes after printing its summary. The script kills a run that has gone quiet for
  `ELEPHRUIT_IDLE_TIMEOUT` (300s), so a hang cannot hold the simulator lock against every other
  worktree. Exit status 124 means it was killed — read the output, because the tests have very
  likely already finished and passed.
- Killing a stuck run is sanctioned. What is not sanctioned is killing a *healthy* one because a
  round-numbered stopwatch went off: judge by whether it has stopped making progress.
- Result bundles are off by default, being both rarely read and implicated in that hang. Set
  `ELEPHRUIT_RESULT_BUNDLE=1` when you actually need one to diagnose a failure.

## Commit incrementally

- Commit every coherent, verified step before starting the next step.
- Keep each commit narrowly scoped and give it a message that describes the completed outcome.
- Run tests or other proportionate verification before committing whenever practical.
- Do not combine unrelated changes or user-owned edits in a commit.
- Do not leave completed task work uncommitted unless the user explicitly asks for that.

## Language

- Use US English for all user-facing copy, documentation, comments, test names, and new identifiers.
- Preserve legacy persisted values and accepted external-input aliases only when changing their
  spelling would break compatibility; do not surface those spellings in the interface.
