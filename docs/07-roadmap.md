# Phased roadmap

Each phase leaves the app runnable, building without warnings, and with its tests
passing. No phase depends on a later phase's existence.

## Milestone 1 — Foundation *(this delivery)*

**Theme: capture, write, organise, find, and get your data back out.**

| Area | Scope |
|---|---|
| Shell | `NavigationSplitView` (sidebar / list / detail), multiple windows, real menu bar, full keyboard map, Settings scene |
| Data | SwiftData `SchemaV1`, local store, versioned migration plan, soft delete, repositories |
| Kinds | Note, Task, Project, Area, Bookmark, Daily entry (schema for all kinds) |
| Views | Today, Inbox, Notes, Tasks, Projects, Tags, Saved searches, Trash |
| Editor | Markdown-compatible plain-text editor over TextKit 2, `[[wiki-link]]` completion, backlinks |
| Capture | In-app Quick Capture panel with inline `#tag` / `>project` / `!date` parsing |
| Search | Token grammar, unified results, highlighting, saved searches, recent searches |
| Trash | Soft delete, restore with relationship reattachment, permanent delete |
| Transfer | Versioned JSON archive (round-trip, IDs preserved) + Markdown bundle, import with validation and duplicate detection |
| Design | Token-based design system, light/dark, reduced motion, accessibility labels and identifiers |
| Quality | Unit tests for core, persistence, search, transfer; preview fixtures; dev-mode sample data |

**Out of scope for milestone 1:** CloudKit, People/CRM UI, EventKit, Contacts,
Core Spotlight donation, Quick Look, recurrence UI, attachments UI, ENEX import,
NL/Vision enrichment, notifications.

## Phase 2 — Depth in what exists

- Attachments end to end: drag-in, managed copies, Quick Look, thumbnails, export tree
- Core Spotlight donation + "Search in Everything" from system search
- Recurrence: rule editor, next-occurrence generation, completion semantics
- `UserNotifications` for due tasks; badge policy
- Command palette expanded to every menu command, with fuzzy scoring
- Drag and drop everywhere: reorder, re-parent, tag by drop, drop files to attach
- Undo/redo coverage audit across structural mutations
- Bookmarks: paste-URL handling, title extraction from the pasteboard only (no network)
- Multi-select bulk edit
- Inspector: full metadata, provenance, user-defined fields
- First XCUITest suite over the milestone-1 journeys

## Phase 3 — People and time

- People / Organisations / Interactions UI — the personal CRM
- Contacts linking (permission-gated, Contacts stays authoritative)
- EventKit read: meetings on Today, meeting → notes/tasks/people links
- Daily log as a first-class surface: today's meetings, captures, completions
- Areas of responsibility as a real organising layer above projects
- On-device enrichment: `NaturalLanguage` for entity suggestions, `Vision` OCR for
  image attachments → `extractedText`. Explicitly opt-in, explicitly on-device.
- Goals / decisions / ideas kinds surfaced
- Import: Apple Notes export, standard note formats (ENEX, Markdown), CSV contacts, task formats

## Phase 4 — Sync and companions

- CloudKit private-database mirroring, off by default, with the sync-status surface
- Conflict-preservation policy for note bodies (see `05`)
- Multi-device integrity pass
- iPhone/iPad app reusing Core/Model/Persistence/Search/Transfer unchanged
- Menu-bar quick capture (global, outside the app)
- Share extension, Shortcuts actions, widgets
- App Store submission: privacy declaration, screenshots, notarisation

## Phase 5 — Refinement

- Rich text as an additive layer over stored Markdown (never replacing it)
- Natural-language search over the existing deterministic query model
- Graph/backlink visualisation
- Templates, routines, review workflows
- Encrypted notes, if and only if there is a real need

---

# Milestone 1 — implementation plan

Six ordered steps. Each ends with a build, a test run, and zero warnings.

### Step 1 — Project skeleton
Hand-written `Everything.xcodeproj` using file-system-synchronized groups (no
generator, no third-party tooling), `Packages/EverythingKit` with eight targets and
four test targets, `xcconfig` for identifiers and versions, entitlements, asset
catalogue, `.gitignore`. **Exit:** `xcodebuild` succeeds; `swift test` runs an empty
suite; the app launches to an empty window.

### Step 2 — Core and Model
`EverythingCore`: `ItemKind`, `ItemStatus`, `Priority`, `LinkKind`, `SourceKind`,
`RecurrenceRule`, `MetadataValue`, `ContentItem` view protocol, `Clock`, `AppError`,
`AccessibilityID`. `EverythingModel`: eight `@Model` entities, `SchemaV1`,
`EverythingMigrationPlan`. **Exit:** every CloudKit constraint asserted by test;
kind-containment and status invariants tested.

### Step 3 — Persistence
Container bootstrap with recoverable failure state, `ItemRepository` /
`TagRepository` / `CollectionRepository` protocols with SwiftData implementations,
predicate builders as pure testable functions, `searchText` projection, Trash
policy, sparse `sortOrder` allocation, integrity pass. **Exit:** persistence tests
against isolated in-memory stores, including trash/restore cascade and duplicate-ID
rejection.

### Step 4 — Design system and shell
Tokens (spacing, radius, typography, semantic colours), components (`ItemRow`,
`Chip`, `EmptyStateView`, `InspectorSection`, `SectionHeader`, `KeyHint`),
motion helper. Then the shell: sidebar, list, detail, inspector, toolbar, menus,
Settings, multiple windows. **Exit:** app navigable end to end with real data in
light and dark; every element carries a label and an identifier.

### Step 5 — Editor, capture, search
TextKit 2 editor bridge with `[[` completion and backlink extraction; Quick Capture
panel with inline token parsing; query grammar, parser, engine, highlighting, saved
searches, recent searches; command palette. **Exit:** J1, J2, J3, J7 pass by hand;
parser and engine unit tests green.

### Step 6 — Transfer, trash, tests
JSON archive codec v1 and Markdown bundle codec, importer with validation and
duplicate detection, Trash UI with restore, dev-mode sample data, preview fixtures,
final test pass. **Exit:** round-trip test proves identifiers and relationships
survive export → import; full journey walkthrough in both appearances.

## Definition of done for milestone 1

1. `xcodebuild -scheme Everything build` — succeeds, **zero warnings**.
2. `swift test` in `Packages/EverythingKit` — all tests pass.
3. No `!` force unwrap, no `try!`, no `fatalError` on a recoverable path, no
   `TODO` standing in for production behaviour. Enforced by a source-scan test.
4. All nine journeys J1–J9 performable, with J6 (People) explicitly deferred and
   labelled as such in the UI rather than half-built.
5. Reviewed in light and dark mode, with Reduce Motion and Increase Contrast on.
6. Sample data reachable **only** in previews or with the dev-mode flag set.
7. Export produces an archive that re-imports into an empty store with identical
   identifiers, relationships, and tags.
