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
| Search index | **Derived** — a SQLite FTS5 sidecar, `Application Support/Elephruit/SearchIndex.sqlite` | Never (each device indexes locally) | **Yes** | A cache. Full rebuild is a menu command. See the note below on why it is not under Caches. |
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

## The search index does not live under Caches

Phase B replaced the in-memory index with a SQLite FTS5 database. It is still **derived** in every
sense that matters — every row is a projection of an `Item`, deleting the file loses nothing, and the
app rebuilds it in the background if it is missing — but it is stored beside the store rather than
under `Caches`.

The matrix's "purgeable" column is about *authority*, and nothing has changed there. What changed is
the practical consequence of a purge. On a fifty-thousand-item library the index runs to hundreds of
megabytes, which makes it exactly the sort of file the system reclaims first under pressure, and
losing it costs a rebuild measured in seconds during which search is degraded. Search is a primary
way of using this app rather than a convenience, so it does not get to disappear when the disk fills.

The recovery a purge would have provided is still available, deliberately: **Rebuild Search Index**
discards the file and rebuilds from the store.

## What the index stores, and what it does not

A search result renders from the index alone, without touching SwiftData — asserted by
`SearchCostTests`, not assumed. That requires the index to hold every column a result row draws.

It holds a short **excerpt** of each body rather than the whole thing. The full text is indexed for
matching and is authoritative in the store; a result row shows a preview and nothing more, and
keeping every body twice over would multiply the file for no gain. Anything that needs the real body
— the editor — loads the item.
