# ADR 0001 — SwiftData as the primary persistence layer

- **Status:** Accepted
- **Date:** 2026-07-29

## Context

The app needs a local, relational, migratable store for ~14 entity types with a
dense link graph, and eventual private-iCloud sync. The candidates are SwiftData,
Core Data (with `NSPersistentCloudKitContainer`), or a hand-rolled SQLite layer.

## Decision

Use **SwiftData** for all structured user content.

## Rationale

- SwiftData sits on the same SQLite substrate and the same CloudKit mirroring
  machinery as Core Data, so the durability and sync stories are equivalent.
- `@Model` + typed `#Predicate` + `VersionedSchema` gives compile-time safety over
  Core Data's stringly-typed model editor and `NSManagedObject` subclasses.
- Observation integration with SwiftUI removes an entire layer of glue
  (`NSFetchedResultsController` equivalents, `@FetchRequest` bridging).
- Its constraints (no polymorphic relationships, no unique constraints under
  CloudKit, unordered to-many) are known up front and are accommodated by the model
  design in `docs/04-domain-model.md`, not discovered late.

## Consequences

- No polymorphic relationships → one `Item` node type discriminated by `kind`
  (see ADR 0002).
- No ordered relationships → `CollectionMembership.position`.
- No FTS → search index is a **derived** artifact behind a protocol (see ADR 0004).
- Every released schema version stays in source forever for migration testing.

## Escape hatch

If a requirement appears that SwiftData genuinely cannot express, the response is to
add a **derived** store beside it (e.g. a rebuildable SQLite FTS5 index), not to
migrate the source of truth to Core Data. Because all persistence access goes through
repository protocols, such a change is contained to one module.
