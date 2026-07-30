# Expansion slices

Living, ordered. Only verified gaps from `docs/17`. Each slice is buildable, tested, and leaves
the app shippable, warning-free and green.

Ordering principle: **correctness → gates → seams → capability.** This is deliberately not the
expansion plan's chapter order, because the plan does not know about the schema freeze
(`docs/18` R1), which blocks four of its capabilities.

**Definition of done**, per slice: scope and acceptance tests written first · migration versioned
and recoverable if applicable · implementation uses canonical services · relevant tests pass ·
Release configuration builds · main workflows work by keyboard · VoiceOver labels and focus order
checked · light and dark checked · error, empty, denied and recovery states functional · indexing
and export implications handled · no prominent control is a stub · docs and ADRs updated · known
limitations and the next bounded slice recorded.

---

## S1 — Capture correctness · **next**

**Goal.** Close the four write-path bugs. No schema change, no format change.

Bugs 1–4 from `docs/16 §6`:
- `CaptureIntent.perform` never indexes what it captures.
- `CaptureBridge.adopt(_:)` is dead, so an in-process intent opens a second writer on one store.
- `CaptureService.linkPeople` inserts an `ItemLink` with no explicit save, relying on autosave in a
  process that may exit first. *Confirm with a test before fixing.*
- `AttachmentStore.remove` deletes bytes before the transaction commits, inverting ADR 0003 §3.

**Files.** `Elephruit/CaptureIntent.swift` · `Elephruit/AppEnvironment.swift` ·
`Packages/ElephruitKit/Sources/ElephruitPersistence/CaptureService.swift` ·
`.../AttachmentStore.swift`

**Acceptance.**
- An item captured through the intent is findable by search immediately after.
- A second `CaptureBridge.services()` in-process returns the adopted services, not a new stack.
- `@person` links survive an intent-process exit.
- A save failure after `remove()` leaves the bytes intact and the row consistent.

**Risk.** Low, with one wrinkle: the app target has no test coverage and no test target, so
`perform()` must be factored into a testable function reachable from the package.

---

## S2 — Editor durability

**Goal.** Bug 7. Flush the debounced editor write on terminate and resign-active, not only on
`onDisappear`.

**Acceptance.** A controlled-clock flush test; a simulated terminate loses nothing.

**Risk.** Low-medium. `scenePhase` does not fire on macOS quit, so this needs
`NSApplication.willTerminateNotification` and a synchronous flush against an async debounce.
`NSSupportsSuddenTermination` is already `false` for exactly this reason.

---

## S3 — Archive completeness

**Goal.** ADR 0009. Bugs 5–6: attachment bytes and `TimeEntry` enter the archive contract.

**Files.** `ElephruitTransfer/Exporter.swift`, `Importer.swift`, `ArchiveFormat.swift`,
`MarkdownBundle.swift`, `Tests/.../RoundTripTests.swift`

**Acceptance.**
- A managed attachment round-trips with a **matching SHA-256** — the first real use of
  `contentHash`, which is currently written and never read.
- A reference round-trips **without** its bytes being copied.
- A running timer exports and re-imports as running; exact intervals, IDs, links, tags and sources
  preserved.
- **A v1 archive still imports.**

**Risk.** Medium — a format version bump. Ships separately from S1 so the correctness fix stays
revertable.

---

## S4 — Schema freeze + first additive stage · **ships alone**

**Goal.** ADR 0005. Snapshot the V1 and V2 entity shapes as frozen types, restore a non-empty
`stages`, and land `Item.estimateMinutes` plus the `@Index` on `Item.createdAt` in that one stage.

**Files.** `ElephruitModel/SchemaV1.swift` · `ElephruitPersistence/PersistenceStack.swift` ·
`Tests/.../MigrationSafetyTests.swift`, `RealStoreMigrationTests.swift`

**Acceptance.**
- `stages.count == 1` and the app opens a real on-disk V2 store, migrates, and reads back V3
  contents. **`RealStoreMigrationTests` is env-gated off by default — it is part of this slice's
  acceptance, not skipped by it.**
- A backup is written before the stage runs, proven by test.
- A failure injected mid-migration rolls back and produces an actionable diagnostic; the original
  store survives.
- All eight `ContainmentRepair` fixtures stay green, including the `GraphFingerprint` equality
  check.
- The full-rebuild benchmark comes in under 6 s, closing the one known miss from `docs/11`.

**Risk. High.** No feature rides on it. This is the critical path for the programme.

---

## S5 — Canonical action layer

**Goal.** ADR 0007. One owner for validate → save → undo → index. Capture becomes undoable.

**Acceptance.** A source-scan test bans direct `items.create`/`items.update` outside the layer,
mirroring `CalendarWriteSafetyTests` · ⌘Z reverses a capture · every action notifies the index ·
a save failure leaves the caller's draft intact.

**Risk.** Medium-high. Wide but mechanical: 26 `noteChange` call sites across 10 files. After S4
deliberately — running a wide diff while the schema is in flux is the worse ordering.

---

## S6 — Capture grammar

**Goal.** `due:`, `follow:`, `!high|!medium|!low`, `time:`/`from:`/`to:`; month names, two-word
forms and times in `NaturalDateParser`; source ranges and original text on `CaptureDraft`, killing
the lossy `joined(separator: " ")`.

**Acceptance.** The plan's four capture fixtures parse correctly · every natural-date fixture has a
deterministic test · **`unrecognisedTokensArePreserved` still passes** · the original text
reconstructs exactly from the draft · DST-transition and timezone cases.

**Risk. Very low.** One pure, side-effect-free file that is already the best-tested unit in the
repo.

---

## S7 — `follow:` reachable

**Goal.** Add `deferUntil` to `ItemDraft` and wire `follow:` through `CaptureService`.

**Acceptance.** Capturing `follow:friday` produces an item hidden from Today until Friday —
asserted through the existing filters at `ItemQuery.swift:340` and `CountsService.swift:56` — and
it never becomes overdue.

**Risk.** Low. The field and every consumer already exist; only the draft cannot carry it.

---

## S8 — Shortcut registry

**Goal.** ADR 0008. One source of truth for 40 `.keyboardShortcut` literals; the palette reads real
bindings instead of its cosmetic glyph arrays; collision detection and a Settings status row.

**Acceptance.** No command has two owners, asserted by test · every palette glyph equals its real
binding · a preference change unregisters and re-registers cleanly · a failed registration leaves
the command unbound and says so.

**Risk.** Low-medium.

---

## S9 — Quick Jot surface

**Goal.** The plan's first vertical slice, on a foundation that now holds. `NSPanel`; the opt-in
hotkey picker; a menu-bar Quick Jot entry alongside the timer; caret autocomplete for `#`, `@`,
`>`, `due:` and `follow:`, reusing `SearchIndexStore.titles(prefix:limit:)` unchanged; focus
restoration to the previous app; draft retention across focus loss.

**Acceptance.** The plan's Quick Jot list in full, plus the first tests for `QuickCaptureView`
covering the four behaviours that are correct today and untested: ⌘↩ saves once, Escape saves
nothing, empty is refused, a save failure keeps the text.

**Risk.** Medium — the first `NSPanel` in the codebase. One acceptance item no unit test can
discharge: **verification in a signed, sandboxed Release build**, without Accessibility permission.

---

## S10 — Attachment lifecycle

**Goal.** ADR 0003's own unbuilt consequences. Staged import with atomic commit; grace-period
deletion after the transaction; a launch orphan sweep; reference counting on the `contentHash`
that is currently written and never read.

**Acceptance.** A crash between file write and row insert is recoverable · the sweep is
dry-runnable and idempotent, mirroring `ContainmentRepair` · removing one reference never deletes
a file still used elsewhere · a failed import never commits a broken reference.

**Risk.** Medium.

---

## S11 — People surfaces

**Goal.** Render what already exists. `PeopleService.allContexts()` as a real workspace; a merged
reverse-chronological timeline; `PersonProfile.birthday` as celebrations; `attendeeNames` as
attendee matching.

**Acceptance.** The 22 existing `PeopleTests` are unchanged · the workspace is fully keyboard
navigable and VoiceOver-labelled · empty, loading and denied states are real · light and dark
checked.

**Risk.** Low-medium. Pure consumption of derivations that are already correct and already tested.
No new entity, so **not blocked on S4**.

---

## S12 — Time surfaces

**Goal.** A Today time surface; a reports destination with CSV export and arbitrary ranges;
overlap detection between non-running entries; split and merge; estimate vs actual; ⌃⌘T bound in
the main menu, where `TimeView.swift:108` already tells the user to press it.

**Acceptance.** Overlaps are detected and never silently changed — the user chooses · split and
merge preserve total interval exactly · **the single-running invariant and all nine
`TimerRecoveryTests` are untouched** · CSV rounding never rewrites stored intervals.

**Risk.** Medium. Estimate vs actual needs S4.

---

## S13 — Time scale and search projection

**Goal.** First, fix what the 200k run found: `entries(in:)` has no lower bound on `startedAt`, so
a fixed window scans the whole history (`docs/16 §8`). Then index `TimeEntry`, add `duration:`,
`source:` and `type:time`, and give search per-category quotas so time cannot flood ordinary
results.

**Acceptance.**
- **Week report under 50 ms at 200,000 entries** — currently 93.4 ms. Prove the predicate is the
  cause before considering a rollup table (`docs/18` R5).
- Day report under 50 ms at 200,000 entries — currently 60.3 ms.
- Ordinary search shows at most a small, highly relevant Time section; full history needs the Time
  view or `type:time`.
- Keystroke p95 at 50k stays under 40 ms.

**Risk.** Medium.

---

## S14 — Note document

**Goal.** ADR 0006. The versioned run-list document, the migration, and the editor.

**Gates before any migration runs.** Round-trip fixtures for empty text, Unicode, emoji, Markdown
characters, URLs, wiki links and long notes · **exact character equality** of the regenerated
projection against the original `body` · a proven backup and rollback · the legacy read path
retained until a rollback window has passed.

**Carried in from the prototype** (`docs/16 §7`): the projection must strip `U+FFFC`; checklists
need a custom attribute because `NSTextList.MarkerFormat` has no checkbox case; pasted content
must be sanitised structurally or hard-coded colours make notes unreadable in dark mode.

**Still unprototyped and belonging here:** live editing in an `NSTextView` — caret movement through
tables, Tab-in-last-cell row creation, drag-and-drop into a cell, and VoiceOver traversal of table
structure.

**Risk.** High. Last and largest.

---

## S15 — Harness

**Goal.** Delete the legacy in-memory `DefaultSearchEngine`, still compiled, still tested, still
referenced at `ElephruitApp.swift:397` while production wires `FTSSearchEngine`. Add CI. Add an
XCUITest target that consumes the `AccessibilityID`s nothing currently reads. Instrument — or
delete — the four published v2 targets that have no instrument (`docs/16 §8`).

**Risk.** Low.

---

## Deferred beyond this list

People relationships, observations and history, Contacts identity, groups and smart groups,
Meeting Brief, My Card, card scan · calendar grid with planned-vs-actual editing · idle detection,
long-timer warnings, Pomodoro and breaks · multi-window note editing · CloudKit.

Each is a real requirement in `docs/17` with a status of `Absent`. None is scheduled until the
slice it depends on has landed, and several depend on S4.
