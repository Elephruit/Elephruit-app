# Storage responsibility matrix

The governing rule: **each fact has exactly one authoritative home.** Everything
else is a derived cache that can be deleted and rebuilt without loss.

| Data | Authoritative home | Synced by | Rebuildable? | Rationale |
|---|---|---|---|---|
| Notes, tasks, projects, areas, tags, collections, saved searches, daily entries | **SwiftData** (`Elephruit.store` in App Support) | CloudKit private DB (Phase 4) | No — this *is* the data | Structured, relational, queryable, needs migrations |
| People, organisations, interactions | **SwiftData** | CloudKit private DB | No | Same graph as everything else; a separate store would break cross-entity links and search |
| Item↔item links (wiki-links, relations) | **SwiftData** (`ItemLink` entity) | CloudKit private DB | Partly — reconstructable from note bodies for `[[…]]` links, but explicit relations are not | Links need their own metadata (kind, created date, resolved state) |
| Attachment **bytes** | **Files on disk**, inside the app's Application Support (`Attachments/<uuid>/<filename>`) | CloudKit `CKAsset` (Phase 4) | No | Blobs do not belong in a relational store; keeps the store small and migrations fast |
| Attachment **metadata** (filename, UTI, size, hash, thumbnail ref) | **SwiftData** (`Attachment` entity) | CloudKit private DB | No | It is graph data; the bytes are the payload |
| Thumbnails / previews | **Caches directory** | Never | **Yes** | Purgeable by the OS by design |
| References to files the user keeps *outside* the app | **SwiftData** — security-scoped bookmark `Data` + last-known path | CloudKit (bookmark may fail to resolve on another Mac; handled as a stale-reference state) | No | Sandbox requires bookmarks; the user owns the file, we own the pointer |
| Search index | **Derived** — in-memory index + Core Spotlight | Never (each device indexes locally) | **Yes** | A cache. Full rebuild is a menu command. |
| Full-text search text (`searchText` projection) | **SwiftData**, denormalised column on each item | Rides along with the item | **Yes** (recomputed from fields) | Makes predicate-based search fast without a join |
| Window layout, sidebar width, selected view, sort order, inspector visibility | **UserDefaults** via `@AppStorage` + `SceneStorage` | No (deliberately per-device) | Yes | Lightweight, per-device preference — not user content |
| Feature flags / dev-mode toggle | **UserDefaults** | No | Yes | — |
| Tokens, credentials, secrets for any future integration | **Keychain Services** (`kSecClassGenericPassword`, `ThisDeviceOnly`) | No | No | The only correct home. Never SwiftData, never UserDefaults, never logs. |
| Sync state / last-known CloudKit change token | **Managed by SwiftData+CloudKit internally**; our own status is transient in memory | — | Yes | Do not shadow framework-owned state |
| Exported archives | **User-chosen location** via `NSSavePanel` (security-scoped) | No | N/A | The user owns their exports |
| Diagnostics | **OSLog** only | No | N/A | Never written to a file, never uploaded, never contains user content |
| Document-style storage in the iCloud ubiquity container | **Not used in v1** | — | — | See ADR below. The app is a library app, not a document app. |

## Decisions worth stating explicitly

### Why SwiftData and not Core Data
SwiftData over the same SQLite substrate, with `@Model` macros, typed predicates,
`VersionedSchema` migrations, and first-class CloudKit mirroring, is enough for this
model. The known constraints — no true many-to-many without an explicit join
entity, CloudKit requiring optionals/defaults and forbidding unique constraints on
synced entities — are accommodated by the model design rather than fought. If a
future need appears that SwiftData genuinely cannot express (custom SQL for FTS5,
for instance), the fallback is a **derived** FTS index alongside the SwiftData store,
not a migration to Core Data. Documented in `docs/adr/0001-swiftdata.md`.

### Why attachment bytes are not in the store
Blobs inflate the store file, slow migrations, and make CloudKit record sizes
unpredictable. Files on disk keyed by the attachment's UUID give O(1) access, cheap
export (copy the tree), and a trivially inspectable layout. `.externalStorage` would
work but hands lifecycle control to the framework and complicates export; explicit
files are clearer and Trash-restorable.

### Why not the iCloud ubiquity container in v1
Elephruit is a library app with one store, not a document app with many files.
Putting the SwiftData store in a ubiquity container invites multi-writer corruption;
CloudKit record-level mirroring is the supported path and merges properly.
Ubiquity may earn a place later for *exported archives* — never for the live store.

### Why `searchText` is denormalised onto items
A single indexed string column per item lets the fast path be one `#Predicate`
`localizedStandardContains` scan, keeping search useful before the in-memory index
warms and after a cache purge. It is recomputed on every save from the item's own
fields, so it can never drift into being a second source of truth.
