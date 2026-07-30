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

## S1 — Capture correctness · **done**

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

**Outcome.** All four closed. Bug 3 was **confirmed first**, as planned: a test asserting
`context.hasChanges == false` after a capture, and reading the link back through a second context,
failed before the fix — the `@person` link genuinely never reached the store. `AppServices.captureText`
now composes capture and index so the intent cannot do half of it, and lives in a target that has
tests. `CaptureBridge.adopt` is wired in `AppEnvironment.start()`. Attachment deletion now removes
bytes only after the transaction commits.

**527 tests pass** (+6), zero warnings; Debug and Release build.

**Known limitation.** The attachment-ordering fix has no direct test for its failure path: inducing
a SwiftData save failure in-process is not tractable, so the recoverable-direction property rests on
the code and ADR 0003 rather than on an assertion. The orphan sweep in S10 is what makes that
direction observable, and the test belongs there.

---

## S2 — Editor durability · **done**

**Goal.** Bug 7. Flush the debounced editor write on terminate and resign-active, not only on
`onDisappear`.

**Acceptance.** A controlled-clock flush test; a simulated terminate loses nothing.

**Risk.** Low-medium. `scenePhase` does not fire on macOS quit, so this needs
`NSApplication.willTerminateNotification` and a synchronous flush against an async debounce.
`NSSupportsSuddenTermination` is already `false` for exactly this reason.

**Outcome.** The debounce became a type, `PendingSave`, rather than a `Task` the view juggles —
which is what made the property assertable without a window: scheduled work runs **exactly once**,
whichever of the timer and the flush arrives first. `ItemDetailView` now flushes on
`willTerminateNotification` and `didResignActiveNotification` as well as `onDisappear`.

**534 tests pass** (+7), zero warnings; Debug and Release build.

**Known limitation.** The notification wiring itself is not asserted — that needs a UI test host,
which arrives in S15. What is asserted is everything the notification calls into.

---

## S3 — Archive completeness · **done**

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

**Outcome — and a correction to this plan.** No version bump was needed. The format's own stated
rule is that "additive changes keep the version and rely on tolerant decoding"
(`ArchiveFormat.swift:20`), and both additions are additive. What that rule required, and did not
have, was decoding that is genuinely tolerant: `ArchiveDocument` used synthesised `Codable`, so a
missing `timeEntries` key would have failed the whole read and made an additive change breaking
after all. It now decodes every collection with a default.

`TimeEntry` is in the archive with exact intervals, links, tags and source; a running timer
re-imports as running rather than being given an end it never had. Attachment bytes are written
into the bundle at the path the archive names, and `bundlePath` is now `nil` for a reference —
Elephruit does not own those bytes and must not claim a path it never wrote. `Importer.importBundle`
restores them; without the folder, an attachment arrives as a lost reference with a warning, which
is the existing "a missing file is a state" behaviour rather than a new failure.

**545 tests pass** (+11), zero warnings; Debug and Release build.

**Deliberate limitation.** The single-file JSON archive still carries attachment *metadata* only —
bytes need a folder to live in. The bundle README now says which format is the complete backup
rather than leaving the user to find out.

---

## S4 — Additive schema change, and the freeze question answered · **done**

**Goal, as planned.** Freeze the V1 and V2 entity shapes, restore a non-empty `stages`, and land
`Item.estimateMinutes` plus the `@Index` on `Item.createdAt`.

**What actually happened — the plan's premise was wrong.** Stage 0 read the checksum-collision note
in `SchemaV1.swift` as "no stored property may move until the old model types are frozen," and
called that the critical path for the whole programme. Tested rather than reasoned about, it is not
true. The collision only bites when the migration plan holds **more than one version**; a plan
holding one never compares two checksums. Additive changes ship by inference, as `TimeEntry` already
did.

So the freeze was **not done**, and ADR 0005 was rewritten to say when it actually becomes
mandatory — the first change inference cannot perform: a rename, a type change, a derived value.
Roughly twenty duplicated model types were queued in front of four capabilities that never needed
them.

**What was done instead.**

- **A genuine legacy store, and the test that had never run.** `RealStoreMigrationTests` is gated on
  `ELEPHRUIT_LEGACY_STORE` and no such store had ever been produced, so the one test that exercises
  a real cross-version migration had never executed. One was generated from a git worktree at
  `71f49ae` — a commit that predates `TimeEntry` entirely, with no `TimeEntry.swift` in the tree —
  and those bytes now migrate through V1 → V2 → V3 with items, tags, containment and links all
  readable, and an empty time table rather than an invented one.
- `Item.estimateMinutes`, optional so that an item written before the field has *no estimate* rather
  than a zero. Zero is a claim that something takes no time.
- `#Index<Item>([\.createdAt])`, which the rebuild streams on.
- Schema bumped to 0.0.3, because the version identifier is what the `.schema-version` stamp is
  compared against and the stamp is what triggers the backup. A test asserts a migrating launch
  leaves a backup behind, and the version literal is pinned so a future bump is deliberate.

**The known benchmark miss is closed.** Full index rebuild at 50,000 items: **5734 ms against a
6000 ms budget**, down from 6150 ms. All seven Phase B benchmarks now pass. That fix was identified
in `docs/11` and declined at the time for being a schema change to real user data.

**549 tests pass** (+4), zero warnings; Debug and Release build.

**Known limitation.** The generated legacy store lives outside the repository, so
`RealStoreMigrationTests` still skips by default on a fresh checkout. ADR 0005 records how to make
another in a few minutes; committing a binary fixture is the alternative and was not taken.

---

## S5 — Canonical action layer · **next**

**Goal.** ADR 0007. One owner for validate → save → undo → index. Capture becomes undoable.

**Acceptance.** A source-scan test bans direct `items.create`/`items.update` outside the layer,
mirroring `CalendarWriteSafetyTests` · ⌘Z reverses a capture · every action notifies the index ·
a save failure leaves the caller's draft intact.

**Risk.** Medium-high. Wide but mechanical: 26 `noteChange` call sites across 10 files. After S4
deliberately — running a wide diff while the schema is in flux is the worse ordering.

---

## S6 + S7 — Capture grammar, and `follow:` made real · **done**

**Goal.** `due:`, `follow:`, `!high|!medium|!low`, `time:`/`from:`/`to:`; month names, two-word
forms and times in `NaturalDateParser`; source ranges and original text on `CaptureDraft`, killing
the lossy `joined(separator: " ")`.

**Acceptance.** The plan's four capture fixtures parse correctly · every natural-date fixture has a
deterministic test · **`unrecognisedTokensArePreserved` still passes** · the original text
reconstructs exactly from the draft · DST-transition and timezone cases.

**Risk. Very low.** One pure, side-effect-free file that is already the best-tested unit in the
repo.

**Outcome.** Done together, because a grammar for `follow:` that nothing stores is half a feature.
All four of the plan's capture fixtures parse, and every date fixture it names has a deterministic
test. `follow:` reaches `Item.deferUntil`, asserted through the Today filter that implements
"not yet" rather than by reading the field back — it appears on the day and never becomes overdue.

`CaptureDraft` now carries `originalText` verbatim and a token list with character ranges, so the
lossy rebuilt title is no longer the only record of what was typed.

Two design notes worth keeping. A date value **extends greedily over following words while the
longer phrase still parses**, which is what makes `due:tomorrow 3pm` and `due:next Tuesday` work
without quotes — and `due:friday meeting` still leaves "meeting" in the title. And a bare number is
never a time: "Review 3 documents" must not acquire a deadline.

**587 tests pass** (+38), zero warnings; Debug and Release build.

**Deliberately not done:** `time:`, `from:` and `to:`. The plan scopes them to time-entry contexts
and Quick Jot is not one, so they would have been tokens with no consumer. They belong with the
manual-entry work in S12.

---

## S8 — Shortcut registry · **done**

**Goal.** ADR 0008. One source of truth for 40 `.keyboardShortcut` literals; the palette reads real
bindings instead of its cosmetic glyph arrays; collision detection and a Settings status row.

**Acceptance.** No command has two owners, asserted by test · every palette glyph equals its real
binding · a preference change unregisters and re-registers cleanly · a failed registration leaves
the command unbound and says so.

**Risk.** Low-medium.

**Outcome.** `ShortcutRegistry` lives in `ElephruitCore`, so the whole thing is testable without a
window and one binding can drive a menu item, a palette row and — in S9 — a Carbon registration
from a single description. All twenty menu literals in `ElephruitApp` now resolve through it;
`grep keyboardShortcut` there returns nothing. The palette's hard-coded glyph arrays are gone.

Two decisions worth keeping. **Unbound and untouched are different states**, so a command the user
deliberately cleared does not quietly come back next launch. And **a collision is reported, not
refused** — refusing would mean two shortcuts cannot be swapped without an impossible intermediate
state, and silently dropping one would be worse than either.

**602 tests pass** (+15), zero warnings; Debug and Release build.

**Not yet done, and belonging to S9:** the Settings row that surfaces a collision, and the global
registration itself. The registry is the foundation both need.

---

## S9 — Quick Jot surface · **done**

**Goal.** The plan's first vertical slice, on a foundation that now holds. `NSPanel`; the opt-in
hotkey picker; a menu-bar Quick Jot entry alongside the timer; caret autocomplete for `#`, `@`,
`>`, `due:` and `follow:`, reusing `SearchIndexStore.titles(prefix:limit:)` unchanged; focus
restoration to the previous app; draft retention across focus loss.

**Acceptance.** The plan's Quick Jot list in full, plus the first tests for `QuickCaptureView`
covering the four behaviours that are correct today and untested: ⌘↩ saves once, Escape saves
nothing, empty is refused, a save failure keeps the text.

**Risk.** Medium — the first `NSPanel` in the codebase. One acceptance item no unit test can
discharge: **verification in a signed, sandboxed Release build**, without Accessibility permission.

**Outcome.** A `.nonactivatingPanel` that joins all spaces and floats over full-screen apps, so
capture works while looking at something else. The global shortcut is Carbon
`RegisterEventHotKey` — no entitlement, no Accessibility prompt — and a refusal is *recorded and
shown in Settings*, which is precisely the "collides silently" objection that put this off for a
phase. Menu bar gains a Quick Jot entry beside the timer.

Three design points. **The draft lives on the controller, not the view**, so closing the panel
keeps the text — the view is destroyed with the window, and `@State` there would turn an accidental
dismissal into lost work. **Only a successful save clears the field.** And **pressing the shortcut
twice focuses the panel that is open** rather than stacking a second one.

Caret autocomplete for `#`, `@`, `>`, `due:` and `follow:` reuses the same index-backed
`titleSuggestions` that already powers `[[` completion. The completion rule is a pure type, so it
is tested without a window.

**620 tests pass** (+18), zero warnings; Debug and Release build. The app was launched against a
temporary store and ran for over an hour with the registration in its launch path — no crash, no
hang.

**Not verified, and honestly the important one:** actually *pressing* ⌘⇧N in a signed sandboxed
Release build. That needs interactive input on a real desktop session and is the one acceptance
item the plan itself flags as undischargeable by test.

**Deliberate limitation.** `.keyboardShortcut` still appears on sheet default/cancel buttons. Those
are standard AppKit affordances, not nameable commands, and putting them in the registry would be
inventing bindings the system already owns.

---

## S10 — Attachment lifecycle · **done**

**Goal.** ADR 0003's own unbuilt consequences. Staged import with atomic commit; grace-period
deletion after the transaction; a launch orphan sweep; reference counting on the `contentHash`
that is currently written and never read.

**Acceptance.** A crash between file write and row insert is recoverable · the sweep is
dry-runnable and idempotent, mirroring `ContainmentRepair` · removing one reference never deletes
a file still used elsewhere · a failed import never commits a broken reference.

**Risk.** Medium.

**Outcome.** ADR 0003 named two failure modes and specified "a startup integrity pass that reports
orphans in both directions and offers recovery" as the mitigation. That pass had never been built,
so for three phases the decision's own safety net was a paragraph. `AttachmentReconciliation` is it:
dry-runnable, idempotent, offered at launch beside the containment repair and on the same terms.

Three behaviours worth stating. A **failed save now removes the bytes it just wrote** — file-first
ordering is right, but a failed commit used to leave an orphan with nothing to clean it up.
Removing an attachment **moves its bytes aside for a week** rather than destroying them; detaching
is easy to do by accident and impossible to undo. And an **orphaned folder is moved, not deleted** —
a file the app cannot account for is exactly the file it should be least confident about destroying.
A row whose bytes are gone is marked lost and never removed, because the row is the last record the
file existed.

**631 tests pass** (+11), zero warnings; Debug and Release build.

**A bug the tests caught.** The sweep first used the filesystem's creation date, which survives a
move, is not what "removed at" means, and cannot be driven by an injected clock — so the test failed
and the only alternative would have been waiting a week. The removal time is now encoded in the
folder name, which is deterministic and testable.

**Deliberately not done: content-hash deduplication.** `contentHash` is read now — the archive
round-trip verifies it — but there is no reference counting, because the per-attachment-directory
layout means no two attachments ever share a file. Reference counting would have nothing to count.
The plan's "removing one reference must not delete a file still used elsewhere" is satisfied
structurally rather than by a counter.

---

## S11 — People surfaces · **next**

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

## S13 — Time scale and search projection · **partly done, and one part refuted**

**Goal.** Fix what the 200k run found — `entries(in:)` bounding only `startedAt < upper` — then
index `TimeEntry` and add result quotas.

**Outcome on the predicate: hypothesis tested and REFUTED.** A derived `endedAtSortKey` was built,
mirroring `endedAt` with `.distantFuture` while running, indexed, with the predicate rewritten so
both bounds could be range-scanned. It measured **93.80 ms against 93.44 ms before** — no
improvement — and was **reverted**.

Reverting was the point. Standing rule R5 says prove the query cannot be made fast before adding a
derived thing; a stored property, an index and a schema version for no measured benefit is exactly
what that rule exists to stop, and unproven schema surface is worse than a slow query. The cause of
the 200k cost is now known *not* to be the predicate and known *not* to be the missing rollup.
Where it is remains open — `docs/16 §8` records the one clue, that per-entry work alone accounts
for roughly 33 ms of it.

**The scale is retired.** Benchmarks run at 10,000 entries by default; the 200,000 and 130,000 tiers
are removed rather than demoted, because a tier selectable by environment variable is a tier that
gets selected, and this one cost seven minutes of fixture building per run. All 18 benchmarks now
run in 39 seconds and pass. Anything larger needs asking first.

**Still to do:** index `TimeEntry`, add `duration:`, `source:` and `type:time`, and give search
per-category quotas. None of that was started.

**631 tests pass**, zero warnings; Debug and Release build.

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
