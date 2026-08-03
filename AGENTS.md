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

## Language

- Use US English for all user-facing copy, documentation, comments, test names, and new identifiers.
- Preserve legacy persisted values and accepted external-input aliases only when changing their
  spelling would break compatibility; do not surface those spellings in the interface.
