# ADR 0004 — The search index is a derived, rebuildable cache

- **Status:** Accepted
- **Date:** 2026-07-29

## Context

SwiftData offers no full-text search. `#Predicate` with `localizedStandardContains`
over 20 000 note bodies will not meet the 100 ms target, and `#Predicate` cannot
express relevance ranking or term highlighting.

## Decision

`SearchEngine` is a protocol. Its v1 implementation combines:

1. **Structural filtering** via SwiftData `#Predicate` — `type:`, `tag:`, `project:`,
   `is:`, and date ranges, where predicates are strong and the store is authoritative.
2. **Free-text matching** via an in-memory inverted index over each item's
   `searchText` projection, built off the main actor at launch and updated on save.

The index is classified as **derived**: it may be deleted at any time and rebuilt
from the store with no loss. "Rebuild Search Index" is a user-visible command.

A `searchText` string is additionally denormalised onto each `Item` so that the
predicate-only path still works correctly — if slower — before the index warms or
after a purge. It is recomputed from the item's own fields on every save, so it can
never become a second source of truth.

## Escalation path

If the in-memory index outgrows available memory or startup budget, replace it with a
SQLite **FTS5** index in a separate file beside the store. This is still derived,
still rebuildable, still behind the same protocol, and requires no change to
`SchemaV1`.

## Consequence

Core Spotlight donation (Phase 2) is a *third* derived consumer of the same
projection, not a parallel implementation.
