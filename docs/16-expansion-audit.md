# Expansion audit — Stage 0

- **Frozen at:** `dfe1846fd191aa8a27a3be9ea6dc74e502d9c08b` (branch `phase-a`, tree clean)
- **Date:** 2026-07-30

This document is a **point-in-time record** and is not edited. Every `file:line` in it resolves
at the SHA above. If the audit is re-run, it gets a new number; this one is superseded, not
amended. The living companions are `docs/17` (coverage matrix), `docs/18` (architecture
checkpoint), `docs/19` (permissions) and `docs/20` (slices).

An expansion plan asks for four capabilities — Quick Jot, native rich-text notes, personal
CRM/People, and privacy-first time tracking — plus shared foundations. Six phases of that work
already exist. The plan is therefore a **specification to audit against**, not evidence that the
code is missing. This document separates what is already true from what is not.

---

## 1. Baseline

```bash
cd Packages/ElephruitKit && swift test
```

**521 tests across 72 suites pass. 0 failures. 0 warnings.** Exit 0.

| Target | Tests |
|---|---|
| ElephruitPersistenceTests | 255 |
| ElephruitCoreTests | 89 |
| ElephruitFeaturesTests | 72 |
| ElephruitSearchTests | 55 |
| ElephruitTransferTests | 32 |
| ElephruitBenchmarks | 18 (skipped unless `ELEPHRUIT_BENCHMARKS=1`) |

Not present: any CI (`.github/` does not exist), and any XCUITest target. Every prior
"N tests pass" claim in `docs/10`–`docs/15` is a manual local run. The `AccessibilityID`
identifiers placed throughout the feature code are consumed by nothing.

---

## 2. Current state

```
Elephruit (app target, 1 target, 1 shared scheme, no test target)
├── AppEnvironment          composition root; owns opening/ready/failed
├── ElephruitApp            scenes, 20 of the 40 .keyboardShortcut literals, MenuBarExtra
└── CaptureIntent           App Intent + CaptureBridge + AppShortcutsProvider

Packages/ElephruitKit (swift-tools 6.2, macOS 26, zero dependencies, warnings-as-errors)
├── ElephruitCore           pure value types; parsers; no framework beyond Foundation
│     CaptureParser · NaturalDateParser · WikiLink · TextNormalizer · DateProvider
│     ItemKind · ItemState · TimeTracking · TimeReporting · PersonContext · CalendarEvent
├── ElephruitModel          @Model types + SchemaV1/V2 + validation + ContainmentRepair
│     Item (unified, kind-discriminated) · Tag · ItemLink · Attachment · PersonProfile
│     EventReference · ItemCollection · SavedSearch · TimeEntry
├── ElephruitPersistence    repositories, services, undo, backup/restore
├── ElephruitSearch         FTS5 sidecar over a hand-rolled sqlite3 wrapper
├── ElephruitTransfer       JSON archive · Markdown bundle · CSV
├── ElephruitIntegrations   EventKit behind a protocol; Contacts stub only
├── ElephruitDesign         tokens, components, layout metrics
└── ElephruitFeatures       all SwiftUI; AppServices is the aggregate
```

Data flows one way: `Core` knows nothing; `Features` knows everything; the SwiftData dependency
stops at the repository protocols.

---

## 3. Components to retain and reuse

These are the parts the expansion should build *on*, not replace. Each is named with the test
that makes it a fact.

| Component | Why it survives contact with the plan | Proven by |
|---|---|---|
| `CaptureParser` | Pure, side-effect-free, `Sendable`, no clock and no store. Parse and save are already separate types in separate modules, which is exactly the plan's rule | 14 tests, `CaptureAndRecurrenceTests.swift:5-127` |
| Literal preservation | Unrecognised syntax is re-appended to the title in all three branches rather than eaten | `unrecognisedTokensArePreserved:59` |
| `Item.deferUntil` | Already *is* the plan's never-overdue `follow:` semantic, plumbed end to end | `ItemQuery.swift:340`, `CountsService.swift:56` |
| Wiki links | Unresolved is a modelled first-class state, not a failure; backlinks are queries, never copies; reconciliation is index-backed via denormalised `titleMatchKey` rather than an O(n) fold | `ItemLinkPersistenceTests.swift:114`, `ItemRepository.swift:668-744` |
| FTS5 sidecar | Incremental, cancellable, off the main actor, cursor-paged; generation-stamped rebuild so a mid-rebuild query never returns a false empty | `FTSIndexTests.swift`; `searchDoesNotTouchTheStore:377` asserts **zero** SwiftData fetches while reading 50 results |
| Single-running timer | Enforced per-save; a switch is one save, so a crash cannot leave nothing running *and* nothing stopped. `reconcileConcurrentTimers` **closes rather than deletes** | `TimeEntryTests` (18), `reconcileClosesRatherThanDeletes:168` |
| Timer recovery | Heartbeat + sleep/wake; three choices plus defer; a banner, not an alert; never automatic | `TimerRecoveryTests` (9), driven against a real on-disk store |
| Attachment states | A missing file is a *state* (`referenceLostAt`) with "Locate…", not an error. Removing a reference never deletes the user's file | `missingReferenceIsRecorded`, `removingReferenceKeepsTheFile` |
| Calendar read-only | Guaranteed three ways: the protocol has no write method, `EKEventStore` never escapes the actor, and a source scan bans eleven write symbols | `CalendarWriteSafetyTests.swift:44-58` |
| Backup / restore | Keyed on the schema-version stamp, not on `stages.isEmpty` — a bug fixed once because it "silently switched the backup off on exactly the launch that needed it most" | `BackupRestoreTests` (6) |
| `ContainmentRepair` | Offered, dry-runnable, idempotent, graph-fingerprint-verified. **The template every future repair should copy** | `MigrationSafetyTests` (8 fixtures incl. 501 items) |
| Host-calibrated benchmarks | Normalised against `Benchmarks/reference.json` with a 4× absolute ceiling; both raw and normalised figures always printed | `BenchmarkHarness.swift:75-105` |
| `PersonContext` | Derivation is already correct and already tested; only the *surface* is missing | `PeopleTests` (22) |

---

## 4. Gap analysis

Sorted by the kind of work each needs, which is not the same as the plan's chapter order.

### 4.1 Validation and test work only — behaviour already correct

- Quick capture's ⌘↩ / Escape / empty-refusal / retain-text-on-error behaviours are all
  implemented correctly and have **no test at all**. `QuickCaptureView.swift:155-188`.
- Timer exclusivity, recovery, and Continue-creates-a-new-interval meet the plan's acceptance
  criteria as written.
- Calendar denial degrades to an explained state rather than a crash, with five authorization
  states mapped explicitly including `.writeOnly → .denied` ("the honest reading: the app cannot
  see anything", `EventKitCalendarProvider.swift:45-56`).
- `RealStoreMigrationTests` is **env-gated off by default** and is the only test that exercises a
  genuine cross-version migration. Its own docstring explains why synthetic fixtures did not:
  they "already ha[ve] the shape V1 never had… it looked covered and was not."

### 4.2 Small extensions to something that already works

- `follow:` — add `deferUntil` to `ItemDraft` (`ItemRepository.swift:15-50`). The field and every
  consumer already exist; only the draft cannot carry it.
- Capture grammar — `due:`, priority tokens, `time:`/`from:`/`to:`; month names, two-word forms
  and times in `NaturalDateParser`; DST fixtures. Confined to one pure file.
- Source ranges and original text on `CaptureDraft`. Today the title is rebuilt with
  `titleWords.joined(separator: " ")` (`CaptureParser.swift:154`), so internal whitespace is
  normalised and the original string is not recoverable.
- Capture-field autocomplete — `SearchIndexStore.titles(prefix:limit:)` already backs `[[`
  completion in the detail editor and is directly reusable.
- People overview — `PeopleService.allContexts()` exists and nothing renders it (`docs/14:123`).
- Celebrations — `PersonProfile.birthday` and `birthdayHasYear` are stored and read by nothing.
- Attendee matching — `CalendarEventSummary.attendeeNames` is populated
  (`EventKitCalendarProvider.swift:209`) and consumed by nothing.
- Main-menu ⌃⌘T. It is bound only inside `MenuBarExtra`, though `TimeView.swift:108` tells the
  user to press it.

### 4.3 Refactors

- The canonical action layer (ADR 0007). 26 `noteChange` call sites across 10 files.
- The shortcut registry (ADR 0008). 40 `.keyboardShortcut` literals plus cosmetic duplicates.
- Attachment lifecycle (ADR 0003's own unbuilt consequences 2 and 3).
- Deleting the legacy in-memory `DefaultSearchEngine`, still compiled, still tested, still
  referenced at `ElephruitApp.swift:397`, while `FTSSearchEngine` is what production wires.

### 4.4 Genuinely new

- The schema freeze and the first real `MigrationStage` (ADR 0005) — **the critical path**.
- Rich documents (ADR 0006).
- People relationships, observations/history, Contacts identity, groups, briefs, My Card.
- Calendar grid, reports destination, split/merge, overlap detection, idle, Pomodoro.
- `TimeEntry` in the search index, with result quotas.

---

## 5. The gate

`SchemaV1.swift:79-95` is the constraint that reorders the whole programme, and it is not in the
expansion plan.

`ElephruitMigrationPlan.stages` is empty **deliberately**. While the versioned schemas reference
live model types, SwiftData resolves each one's full entity graph — so `SchemaV1`, which never
mentions `TimeEntry`, has it pulled in through `Item.timeEntries` and comes out byte-identical to
`SchemaV2`. Two versions with the same checksum throw, and that crashed every launch that needed
to migrate until commit `37337b7`.

The docstring names the consequence: the first change needing a custom stage "is also the one
that makes freezing the old model types mandatory rather than optional."

Every one of the four capabilities wants a stored property — `Item.estimateMinutes`, a note
format version, `ContactIdentity`/`Relationship`/`Observation`, and the `@Index` on
`Item.createdAt` that would close the one known benchmark miss. None can land first.

---

## 6. Bugs

Every one is a violation of a decision this repository already made in writing, which is what
makes them bugs rather than scope.

| # | Bug | Evidence | Slice |
|---|---|---|---|
| 1 | Items captured via Shortcuts/Spotlight are **never indexed**. `CaptureIntent.perform` calls `capture(text:)` and returns without `noteChange`. Written to the store, unreachable by search | `CaptureIntent.swift:39-56` | S1 |
| 2 | `CaptureBridge.adopt(_:)` is **dead code**. It exists to stop an in-process intent opening a second writable container on the same SQLite file; `AppEnvironment.start()` never calls it. Grep repo-wide returns only the definition | `CaptureIntent.swift:84` vs `AppEnvironment.swift:47-74` | S1 |
| 3 | `@person` links may be lost from an intent. `linkPeople` does `context.insert(ItemLink(...))` with **no explicit save**, relying on `autosaveEnabled = true`. In a process that exits right after `perform()`, autosave may never fire. *Suspected — confirm with a test first* | `CaptureService.swift:88-102`, `AppServices.swift:119` | S1 |
| 4 | Attachment bytes are deleted **before** the store transaction commits — `removeItem` → `context.delete` → `save()`. The literal inverse of ADR 0003 Consequence 3. A save failure leaves a row pointing at nothing, the non-recoverable direction that ordering exists to avoid | `AttachmentStore.swift:219-227` vs `docs/adr/0003:35` | S1 |
| 5 | Archives **name attachment files that were never written**. `bundlePath` is emitted; no code copies the bytes; `Importer` never reads `archive.attachments`. Zero occurrences of "attachment" in `RoundTripTests` | `Exporter.swift:221-234`, `MarkdownBundle.swift:176` | S3 |
| 6 | Time history is **absent from the archive entirely**. Zero `TimeEntry` references in `Sources/ElephruitTransfer` | — | S3 |
| 7 | No terminate flush. The editor flushes on `.onDisappear` only, so a force-quit loses up to 500 ms of typing | `ItemDetailView.swift:55,229-236` | S2 |

Bugs 1–4 are one slice: small, no schema change, no format change. Bugs 5–6 need an archive
format version bump and ship separately so the correctness fix stays revertable. Bug 7 needs
`NSApplication.willTerminateNotification` — `scenePhase` does not fire on macOS quit — and a
synchronous flush against an async debounce, which is a different problem in a different module.

---

## 7. Rich-document format gate

A throwaway prototype ran RTFD and `NSKeyedArchiver` against everything the plan asks a note to
hold. Full decision in **ADR 0006**; the measurements:

| Property | RTFD | `NSKeyedArchiver` |
|---|---|---|
| Custom attribute — wiki link target UUID | **lost** | kept, exact |
| Custom attribute — semantic paragraph style | **lost** | kept |
| Stable ID alongside an attachment | **lost** | kept, exact |
| `.link` with a custom URL scheme | kept | kept |
| `NSTextTable` structure, 3×3 | kept | kept |
| `NSTextList` nesting, 3 levels | kept | kept |
| Attachment bytes and filename | kept | kept |
| Encode 100,000 characters | 2.2 ms → 135 KB | 0.8 ms → 137 KB |
| Decode 100,000 characters | 1.3 ms | 0.9 ms |

Four findings that constrain the editor regardless of format:

1. **RTFD silently drops custom attributes.** This disqualifies it: Elephruit's wiki links are
   modelled relationships with stable targets, and the attribute carrying the target ID does not
   survive. The `.link` workaround with an `elephruit://item/<uuid>` URL *does* survive, but
   covers only links — attachment identity and semantic styles have no equivalent slot.
2. **Checklists have no native marker format.** `NSTextList.MarkerFormat` has no checkbox case;
   checklist state must ride on a custom attribute.
3. **An attachment appears as `U+FFFC` in `.string`.** The plain-text projection must strip it, or
   every note with an image gains a junk character in the FTS index and in Markdown export.
4. **Pasted content carries hard-coded colour.** Foreign RTF arrived with an explicit red
   foreground. Stored unsanitised it is unreadable in dark mode — the plan's "never hard-code
   black text" rule, generalised. Sanitisation must be structural.

Performance did not differentiate the candidates and did not inform the decision.

**Not covered by this prototype:** live editing behaviour in an `NSTextView` — caret movement
through tables, Tab-in-last-cell row creation, drag-and-drop into a table cell, and VoiceOver
traversal of table structure. These need a GUI harness and belong to the editor slice, not to
the format decision.

---

## 8. Performance

Measured figures are recorded in `docs/11` and `docs/12`. Two things this audit adds.

**The one known miss stands.** Full index rebuild at 50k items measured 6.15 s against a 6 s
budget. The fix is an index on `Item.createdAt` — a schema change to real user data, declined at
the time pending review (`docs/11:98-107`). It is now folded into the schema-freeze slice, which
has to touch the schema anyway.

**The 200,000-entry figure was already correctly identified as cargo.** `PhaseCBenchmarks.swift:25-42`
records the reasoning: 200,000 entries at half an hour each is a hundred thousand hours, about
fifty working years. A heavy user tracking eight sessions a day, 250 days a year, produces about
20,000 entries a decade. The realistic scales are `reduced` = 20,000 (a career) and `full` =
60,000 (three decades); `huge` = 200,000 is kept for hunting a regression in the query path, and
is opted into by name because "a benchmark nobody will wait for is a benchmark nobody runs."

### The 200,000-entry run, executed for the first time

```bash
ELEPHRUIT_BENCHMARKS=1 ELEPHRUIT_BENCHMARK_SCALE=huge swift test --filter PhaseCBenchmarks
```

Reference host `Mac17,3`, 10 cores, macOS 26.5.2, `hostFactor` 1.02. Suite took 235 s.

| Measurement | Budget | 60k (`docs/12`) | **200k (now)** | |
|---|---|---|---|---|
| `time.weekReport` | 50 ms | 47.1 ms | **93.4 ms** | ✘ 87% over |
| `time.dayReport` | 50 ms | 22.7 ms | **60.3 ms** | ✘ 21% over |
| `time.monthByProject` | 200 ms | 126.2 ms | 166.1 ms | ✔ |
| `time.yearByProject` | recorded | ~1.5 s | 1720 ms (66,671 entries read) | recorded |
| `time.runningLookup` | 5 ms | 0.04 ms | 0.04 ms | ✔ |

**It fails, and it fails in the way the suite was written to detect.** The suite's own docstring
states the bet: "The design decision this exists to check is the absence of a rollup table. A
`TimeDayRollup` derived cache was designed for and deliberately not built, on the grounds that a
week touches a few hundred rows and the arithmetic is cheap. **If that is wrong, this is where it
shows.**"

### But the evidence points at the predicate, not at the missing rollup

A week is a fixed window. Its cost should not depend on how much history sits behind it, and a
rollup is the wrong first answer to a query that should already be near-constant. Three
observations say the scan, not the arithmetic, is the cost:

1. Week-report time nearly doubled (47.1 → 93.4 ms) when only the *total* history grew. The window
   did not change.
2. A month covers roughly four times a week's rows but costs only 1.8× as much (166 vs 93 ms) —
   the signature of a large fixed cost that both queries pay.
3. `entries(in:)` (`TimeEntryRepository.swift:280-295`) has **no lower bound on `startedAt`**:

   ```swift
   $0.deletedAt == nil
       && $0.startedAt < upper
       && ($0.endedAt == nil || ($0.endedAt ?? upper) > lower)
   ```

   For any window ending now, `startedAt < upper` is true of the **entire history**. The index on
   `startedAt` cannot bound the scan from below, so every one of the 200,000 rows is materialised
   and then filtered by the `endedAt` clause. The overlap semantics are correct and must stay —
   an entry beginning yesterday evening and ending this morning belongs to both days — but they
   are currently paid for with a full scan.

**Hypothesis, not yet proven:** bounding the predicate below — by the longest plausible entry, or
by storing a non-optional end column so a single composite range index serves both bounds — turns
this into a true range scan and removes the dependence on total history. Confirming or refuting
that is the first task of the search/time-scale slice, and it must be measured before any rollup
table is considered. The compound index today is
`#Index<TimeEntry>([\.endedAt, \.deletedAt], [\.startedAt])`, which serves neither bound of this
predicate well.

**What this means for the plan.** The plan says: "If the current persistence technology cannot meet
it, report evidence and propose a realistic measured target or a derived aggregate store that
remains rebuildable." The honest report is that the cause has not been found, and that one plausible
cause has now been tested and eliminated. A derived aggregate store remains the second answer, not
the first.

**The scale itself has been retired.** Benchmarks run at 10,000 entries by default and the 200,000
tier has been removed rather than demoted — a tier selectable by an environment variable is a tier
that gets selected, and this one cost about seven minutes of fixture building before emitting a
single measurement.

At the scales that remain, the original design bet holds comfortably. 10,000 entries — roughly five
years of a heavy user tracking eight sessions a day — gives a week report of **13.9 ms against a
50 ms budget**, with the whole Phase C suite running in 23 seconds. 60,000 measured 47.1 ms.

Four published v2 targets remain **unmeasured** and have no instrument: cold launch → window
interactive < 400 ms; full rebuild with the main thread never blocked > 16 ms; resident memory
< 150 MB at 200k items indexed; keystroke → painted p95 at 200k items < 80 ms (`docs/09:506-516`).
Either instrument them or delete them; a published target nothing measures is worse than no target.

---

## 9. What the plan asks for that this codebase should not do

Recorded so it is a decision rather than an omission.

- **Rich text in `Item.body`.** Rejected, not missing. See ADR 0006.
- **A global hotkey as the mechanism.** Rejected. The App Intent stays the mechanism and the
  hotkey is the convenience — which is what `docs/10 §0` already decided. See ADR 0008.
- **A default `⌘⇧J` that is assumed to bind.** Proposed as a default, but a failed registration
  is an expected, reported outcome, not a silent one.
- **Making the index write synchronous with the save.** Rejected. Divergence is detected and
  repaired by the existing generation counter and item-count checksum; the fire-and-forget shape
  is what keeps FTS work off the critical path of a keystroke. See ADR 0007.
- **Any of workspaces, teams, approvals, payroll, attendance, pipelines, or scoring.** Absent
  today and to stay absent.
