# Repository workflow

These rules apply to every task in this repository.

## AI reachability is a product invariant

- Everything a user can create, edit, complete, classify, schedule, connect, or remove in the app must also be reachable through the AI capture endpoints.
- AI reachability is not a second write path. AI produces an editable proposal, the review UI exposes every proposed field, and confirmation uses the same domain planner and atomic write executor as the manual interface.
- A feature is incomplete until its AI proposal schema, review state, write planning, and focused tests ship with its manual UI.
- Existing records needed for corrections or state changes may be supplied to the model as bounded context, but facts marked sensitive or restricted must never leave the app. Restricted data must never be sent to an AI provider under any circumstances.
- AI never writes silently. Destructive changes, identity changes, relationship changes, and completions must remain explicit in review before confirmation.

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

## Build the merge, not just the branch

- Run `Scripts/premerge.sh` before opening a pull request, and again before merging one that has
  been open long enough for `main` to have moved. It merges `origin/main` into a throwaway
  worktree, builds both apps, and throws the worktree away. It never touches your branch.
- A branch can build, `main` can build, and the merge of the two can fail, because git merges
  text and the compiler checks meaning. Nothing else in the loop ever compiles that combination.
- **The iPad is the reliable victim, and for a structural reason.** `ElephruitiOS/Pad/` reuses
  views written for the phone; it is the newest part of the app, so a branch cut before a Pad
  file exists does not contain it; and a `grep` for a view's callers in that worktree finds
  nothing and reports the view as unused. Deleting it is then a perfectly reasonable local
  decision that breaks a target the branch has never seen. This has happened twice.
- So: before removing or renaming any view, component, accessibility identifier or model in
  `ElephruitiOS/`, check `ElephruitiOS/Pad/` in *up-to-date* `main`, not only in your worktree.
  `git grep <name> origin/main` answers that in one command and does not care how old the branch
  is.

## Commit incrementally

- Commit every coherent, verified step before starting the next step.
- Keep each commit narrowly scoped and give it a message that describes the completed outcome.
- Run tests or other proportionate verification before committing whenever practical.
- Do not combine unrelated changes or user-owned edits in a commit.
- Do not leave completed task work uncommitted unless the user explicitly asks for that.

## Running tests

- Run every `xcodebuild test` through `scripts/xctest.sh`, passing the same arguments you would have
  passed to `xcodebuild test`. Do not call `xcodebuild test` directly.
- The script exists because worktrees share one machine: several of them target the same simulators
  by name, and the app has one bundle identifier, so two simulator runs at once install over each
  other and race on the same app container. The script takes a machine-wide lock for simulator
  destinations, runs tests serially, pins derived data and package checkouts under the worktree's
  own `.xcode-local/`, and always writes a result bundle.
- Plain builds — `xcodebuild build`, `swift build`, `swift test` — go through no wrapper. They
  contend for nothing, and making them queue behind somebody else's simulator would be the slowest
  possible way to be correct.
- A UI-test failure is usually diagnosed from the result bundle rather than from a second run:
  `xcrun xcresulttool export attachments --path <bundle> --output-path <dir>` yields the screenshots
  and the accessibility hierarchy at the moment of the failure.
- These runs take many minutes. Start them in the background and wait for them; never cut one short
  with a timeout, and never start a second while one is in flight.

## Language

- Use US English for all user-facing copy, documentation, comments, test names, and new identifiers.
- Preserve legacy persisted values and accepted external-input aliases only when changing their
  spelling would break compatibility; do not surface those spellings in the interface.
