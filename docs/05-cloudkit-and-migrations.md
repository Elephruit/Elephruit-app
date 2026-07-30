# CloudKit and migration strategy

## Position

CloudKit sync **ships in Phase 4, but the schema is designed for it now.** Every
constraint CloudKit imposes on a SwiftData model is honoured from v1, because
retrofitting them onto a populated store is a data migration, whereas honouring them
up front costs nothing.

The v1 store is local-only. Enabling sync later is a container-configuration change
plus an entitlement, not a model rewrite.

### Why sync is not in milestone 1

- It requires a paid Apple Developer Program membership and a provisioned iCloud
  container — external infrastructure that must be the user's explicit decision.
- Sync bugs are the most expensive class of bug in an app like this, and they are
  only meaningfully testable against a schema that has stopped changing.
- Nothing in the v1 user journeys is blocked by its absence.

**Assumption, reversible:** the container identifier will be
`iCloud.com.everything.Everything`, and the bundle identifier
`com.everything.Everything`. Both are placeholders until a real team identifier is
chosen; they are defined in one place (`Configuration/Everything.xcconfig`) so
changing them is a one-line edit.

## Constraints honoured from v1

| CloudKit + SwiftData constraint | How the model complies |
|---|---|
| Every attribute must be optional **or** have a default value | Every non-optional property has a literal default in its declaration. Verified by a test that instantiates every entity with `init()` only. |
| `@Attribute(.unique)` is unsupported on mirrored entities | No unique constraints anywhere. `Item.id` uniqueness is enforced by `ItemRepository` on insert and by the importer, and covered by a test that attempts a duplicate insert. |
| Every relationship must be optional and must have an inverse | All to-one relationships are `Optional`; all to-many pairs declare `@Relationship(inverse:)` on exactly one side. |
| `.deny` delete rules are unsupported | Only `.cascade` and `.nullify` are used. Containment cascades; associations nullify. |
| Ordered relationships are unsupported | `Collection` order lives in `CollectionMembership.position`, an attribute. |
| Large binaries bloat records | Attachment bytes live on disk (see storage matrix). Phase 4 maps them to `CKAsset` in a dedicated record, not inline. |
| Enums are safest as raw strings | All enums stored as `String` raw values with tolerant decoding for unknown cases. |

## Conflict handling

SwiftData + CloudKit resolves at the *record* level, last-writer-wins per field.
That is acceptable for most of this model and unacceptable for note bodies, where
losing the loser's edit is real data loss. Policy:

| Data | Strategy |
|---|---|
| Scalar fields (`title`, `dueAt`, flags, status) | Last-writer-wins. Acceptable: a single user rarely edits the same field on two devices simultaneously, and the loss is one keystroke-level change. |
| `body` (note text) | **Conflict preservation.** On a detected divergent update, the incoming loser's body is written to a sibling note titled `"<title> (conflicted copy — <device>, <date>)"`, linked to the winner. Never silently discarded. |
| Relationships | CloudKit merges to-many sets additively; a delete that races an add can resurrect a link. Reconciled by a startup integrity pass that drops links whose endpoints are trashed. |
| Soft deletes | `deletedAt` is a normal field and therefore merges. A tombstone always beats `nil` (a deletion is never undone by a stale edit), enforced in a merge hook rather than left to LWW. |

## Migration policy

Schemas are versioned explicitly from day one — v1 is `SchemaV1`, and the store is
opened through a `SchemaMigrationPlan` even though it currently has a single stage.
This means the first real migration is an *addition to an existing mechanism*, not
the introduction of one.

```swift
enum EverythingMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}
```

Rules:

1. **Additive changes** — new optional attribute, new entity, new relationship —
   are lightweight stages. Still declared, still tested.
2. **Anything else** — rename, type change, semantic change, splitting an entity —
   is a `.custom` stage with `willMigrate`/`didMigrate` closures and a test that
   builds a store at version *N*, migrates it, and asserts on the version *N+1*
   contents. No exceptions.
3. **Every released schema version is kept in source forever** under
   `Sources/EverythingModel/Schema/` so that migration paths remain compilable and
   testable.
4. **A pre-migration backup** of the store file is written to
   `Application Support/Everything/Backups/pre-v<N>-<timestamp>/` before any
   non-lightweight stage runs, and surfaced in the UI if migration fails.
5. **Migration failure is recoverable, never fatal.** The app opens in a degraded
   "store unavailable" state that offers: retry, reveal the backup in Finder, or
   export the raw store. It does not `fatalError`, and it does not delete anything.

## Store bootstrap sequence

```
1. Resolve store URL (App Support/Everything/Everything.store)
2. Build ModelConfiguration(schema: SchemaV1, url:, cloudKitDatabase: .none)   ← Phase 4 flips this
3. try ModelContainer(for: schema, migrationPlan:, configurations:)
   ├─ success → integrity pass (orphaned links, dangling attachments, stale bookmarks)
   └─ failure → StoreFailureState surfaced to UI with actionable recovery
4. Warm search index off the main actor
5. Donate to Core Spotlight incrementally, batched, low priority
```

Startup is never blocked on steps 4–5.

## Sync status surface (Phase 4, designed now)

A single `SyncStatus` value — `.disabled`, `.idle(lastSyncedAt:)`, `.syncing`,
`.offline`, `.error(SyncError)` — rendered as one quiet line at the bottom of the
sidebar. No spinners in the toolbar, no modal alerts. `.error` is the only state
that can be tapped for detail. The type exists in v1 and reports `.disabled`, so the
UI does not change shape when sync arrives.
