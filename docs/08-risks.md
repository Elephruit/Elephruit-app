# Key risks and mitigations

Ordered by expected cost, not likelihood.

### R1 — SwiftData + CloudKit forces a schema change after data exists
*Impact: high. Likelihood: medium.*
The mirroring constraints are strict and some are only reported at container-open
time on a real iCloud account.
**Mitigation:** every constraint is honoured in `SchemaV1` (see `05`), asserted by a
test that instantiates each entity from `init()` alone and scans for unique
constraints and `.deny` rules. A migration plan exists from day one, so the first
change is an added stage, not a new mechanism. Pre-migration store backups are
written before any non-lightweight stage.

### R2 — The wide `Item` row degrades into an untyped bag
*Impact: high. Likelihood: medium.*
One entity for fourteen kinds invites "just add a field".
**Mitigation:** `ItemKind.supportedFields` is the single declaration of which kinds
use which fields, `ItemValidator` enforces it on every save path, and adding a field
without declaring its owning kinds fails a test. Feature models expose
kind-appropriate projections, so views never touch irrelevant fields.

### R3 — The two-`Item`-relationship shape on `ItemLink` hits a SwiftData bug
*Impact: high. Likelihood: medium-low.* — **RETIRED, verified 2026-07-29.**
`ItemLinkPersistenceTests` covers both endpoints surviving a refetch through a fresh
context, bidirectional links keeping their inverses distinct, many links in both
directions, cascade on delete, and unresolved-link resolution. All pass. The fallback
below was not needed and is kept only as a record of the contingency.

Two relationships from one entity to the same target type, each with its own inverse,
has historically been fragile.
**Mitigation:** this is the *first* thing built and tested in step 2 — a persistence
test creates links in both directions, saves, refetches from a fresh context, and
asserts both `outgoingLinks` and `incomingLinks` resolve. **Documented fallback if it
misbehaves:** drop the inverse on `target`, store `targetID: UUID?` as a plain
indexed attribute, and compute backlinks with an explicit fetch. That fallback costs
one query and no data-model change, so the risk is bounded.

### R4 — SwiftData predicate limitations make search slow or inexpressive
*Impact: medium-high. Likelihood: medium.*
`#Predicate` cannot express everything, has no FTS, and `localizedStandardContains`
over 20 000 bodies will not hit the 100 ms target.
**Mitigation:** search is a **protocol** with a SwiftData implementation behind it.
The fast path is an in-memory inverted index over `searchText`, built off the main
actor at launch and updated on save; SwiftData predicates handle the structural
filters (`type:`, `tag:`, `is:`, date ranges) where they are strong. If that ceiling
is reached, the documented escalation is a derived SQLite FTS5 index alongside the
store — a *cache*, rebuildable, with no impact on the source of truth. This is why
the index is classified as derived in the storage matrix.

### R5 — The text editor becomes the whole project
*Impact: high. Likelihood: medium-high.*
Text editing on Apple platforms is a tar pit. `TextEditor` is inadequate (no
selection API, no find bar, no completion anchoring); `NSTextView` is powerful and
endless.
**Mitigation:** hard scope for v1 — plain text, monospaced-optional, Markdown
*syntax awareness for `[[` completion only*, no live styling, no attributed storage.
Storage is `String`, always. Syntax highlighting and rich text are Phase 5, and
because storage is plain text they cannot corrupt anything. The bridge is one file
with a narrow protocol; a full rewrite of the editor would not touch the data model.

### R6 — Attachment bytes and store rows drift out of agreement
*Impact: medium-high. Likelihood: medium.*
Two stores (SQLite + files) means two ways to be wrong: rows with no file, files with
no row.
**Mitigation:** writes are ordered file-then-row and reconciled by a startup
integrity pass that reports orphans in both directions and offers recovery rather
than silently deleting. Permanent deletion removes bytes only *after* the store
transaction commits. Deferring attachments to Phase 2 keeps this risk out of
milestone 1 entirely.

### R7 — Strict Swift 6 concurrency versus SwiftData's non-`Sendable` context
*Impact: medium. Likelihood: high.*
`ModelContext` and `PersistentModel` are not `Sendable`; naïve `async` code will not
compile, and the tempting fixes (`@unchecked Sendable`, `nonisolated(unsafe)`) are
how data races get shipped.
**Mitigation:** an explicit rule — **models never cross an isolation boundary.**
Background work uses `@ModelActor` contexts and exchanges `PersistentIdentifier`
values and plain `Sendable` structs. No `@unchecked Sendable` anywhere; a source-scan
test enforces it.

### R8 — Scope: fourteen entities and nine journeys in one milestone
*Impact: high. Likelihood: high.*
The brief describes a product that plausibly takes a year.
**Mitigation:** the schema covers all kinds, the *UI* covers six. People/CRM,
attachments, EventKit, and sync are named phases with explicit exclusions, and the
milestone-1 definition of done is a checklist, not a vibe. Anything not on it is not
in it.

### R9 — Hand-written `.xcodeproj` breaks or drifts
*Impact: medium. Likelihood: low-medium.*
No generator means the project file is maintained by hand.
**Mitigation:** file-system-synchronized groups mean files are never enumerated in
the project, so adding a source file requires no project edit at all. All settings
live in `.xcconfig` files, so the `pbxproj` is small and rarely touched. Because
every module lives in the SPM package, `swift build`/`swift test` provide a
generator-independent second build path — if the project file were lost, only the
shell would need recreating.

### R10 — "No warnings" erodes
*Impact: medium. Likelihood: medium.*
Warnings accumulate silently and then get normalised.
**Mitigation:** `SWIFT_TREAT_WARNINGS_AS_ERRORS` is on for the app target and
`.treatAllWarnings(as: .error)` for package targets in a `strict` build
configuration, plus `-strict-concurrency=complete`. The build is verified after every
step, not at the end.

### R11 — Export claims fidelity it does not have
*Impact: medium. Likelihood: medium.*
"Export everything" is easy to say and easy to get subtly wrong — a dropped tag, a
lost link, a re-generated identifier.
**Mitigation:** the round-trip test is written *before* the exporter is finished: it
populates a store with every entity type and every relationship, exports, imports
into a fresh store, and asserts graph equality by identifier. Fidelity is a test
result, not a claim.

### R12 — Sandbox friction with user-managed files
*Impact: low-medium. Likelihood: medium.*
Security-scoped bookmarks fail to resolve after moves, renames, and on other devices.
**Mitigation:** stale references are a **modelled state** with a "Locate…" recovery
action, not an error dialog. Copy-in is the default so the common case never depends
on a bookmark.
