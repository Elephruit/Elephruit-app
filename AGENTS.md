# Repository workflow

These rules apply to every task in this repository.

## Worktrees are required

- Do not make implementation, test, documentation, or configuration changes in the primary checkout.
- Before changing files, create or select a dedicated Git worktree for the task.
- Create new task branches with the `codex/` prefix unless the user requests another name.
- Keep the primary checkout on `main` and use it only for inspection, coordination, and worktree management.
- If a task begins with uncommitted changes in the primary checkout, stop and resolve their ownership with the user before creating or moving work.

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
