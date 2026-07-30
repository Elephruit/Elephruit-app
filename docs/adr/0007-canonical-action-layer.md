# ADR 0007 — One canonical action layer; indexing and undo participate in the write

- **Status:** Accepted
- **Date:** 2026-07-30

## Decision

Every mutation of user content runs through a single **action** that owns, as one call:
validation, the store transaction, undo registration, and index notification.

Views, App Intents, importers and commands call actions. They do not call
`ItemRepository.create`/`update` directly, and they do not call `AppServices.noteChange`
by hand. A source-scanning test enforces the boundary.

Rejected: keeping `noteChange` as a call the caller remembers to make.

## Rationale

Responsibility for one capture is currently spread across five places with no single owner:
`CaptureParser` → `CaptureService` → `SwiftDataItemRepository.create` (validate and save) →
`StructuralUndoCoordinator` → `AppServices.noteChange` (index and counts).

The doc comment on `noteChange` states the intent exactly — "One call site rather than several,
so a new mutation cannot update the index and forget the counts — the class of bug where a badge
silently goes stale" (`AppServices.swift:236-239`). It bundles the index and the counts together.
What it cannot do is make itself be called.

There are **26 `noteChange` call sites across 10 feature files**. That is 26 chances to forget,
and one has already been taken: `CaptureIntent.perform` calls `services.capture.capture(text:)`
and returns without it, so an item captured from Shortcuts or Spotlight is written to the store
and is then unreachable by search. Silently, on the path this expansion promotes to a headline
feature.

Two further gaps follow from the same shape. `StructuralUndoCoordinator` covers move, trash,
archive, retag, status and reparent — but has **no create inverse**, so capture is not undoable;
a captured item can only be removed by a separate trip to the trash. And `CaptureService.capture`
never touches the index itself, so every future non-view caller inherits the same hole the intent
already fell into.

The technique for enforcing this already exists in the repo and is proven. `CalendarWriteSafetyTests`
scans the sources for eleven named EventKit write symbols and fails if any appears, which is how
"no write to any calendar occurs" is a fact rather than a promise. The same scan, pointed at
direct repository mutation outside the action layer, makes this boundary equally checkable.

## Consequences

1. Indexing stays **fire-and-forget**. It is not moved inside the save. The unawaited
   `Task { await engine.indexDidChange(for:) }` is what keeps FTS work off the critical path of a
   keystroke, and the measured cost of the incremental upsert — 0.2 ms — is not the problem. The
   problem was the opportunity to omit the call, and that is what the action removes.
2. Because indexing is asynchronous and `FTSSearchEngine` swallows its own upsert failure
   (`:187-189`), item and index **can still diverge**. That is accepted, and it is why the index
   already carries a generation counter and an item-count checksum that trigger a background
   rebuild on mismatch. Divergence is detected and repaired, not prevented.
3. Actions return a typed result and a recoverable error. A save failure must leave the caller's
   draft or editor state intact — `QuickCaptureView` already gets this right by clearing its text
   only inside `if didSave`, and that behaviour becomes the contract rather than one view's good
   manners.
4. Capture becomes undoable, which requires a create inverse on `StructuralUndoCoordinator`.
5. The conversion touches 10 feature files. It is wide but mechanical, and it ships **after** the
   schema freeze (ADR 0005) — running a wide diff while the schema is in flux is the worse of the
   two orderings.
