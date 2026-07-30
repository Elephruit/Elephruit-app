# Expansion coverage matrix

Living document. Updated at the end of every slice. Evidence is frozen at
`dfe1846` (see `docs/16`); statuses are not.

**Status** — `Met` · `Partial` · `Absent` · `Rejected` · `Unverified`

`Rejected` carries as much weight as `Absent`. It means the requirement was read, understood, and
deliberately not implemented, with an ADR saying why. It is not a gap and no slice closes it.

---

## Shared foundations

| # | Requirement | Status | Evidence | Slice |
|---|---|---|---|---|
| F1 | Parser is side-effect free and fixture-tested | Met | `CaptureParser.swift` is a pure `enum` of statics; 14 tests `CaptureAndRecurrenceTests.swift:5-127` | — |
| F2 | Unknown syntax stays literal | Met | `CaptureParser.swift:118,128,145`; `unrecognisedTokensArePreserved:59` | — |
| F3 | `CaptureDraft` carries source ranges and original text | **Met** (S6) | `originalText` verbatim; `tokens` with character ranges covering extended phrases | — |
| F4 | Tokens `#tag @person >project` | Met | `CaptureParser.swift:113-137` | — |
| F5 | `due:` is a deadline and may become overdue | **Met** (S6) | `dueDateIsADeadline` asserts through `isOverdue` | — |
| F6 | `follow:` is a start date and never becomes overdue | **Met** (S7) | Reaches `Item.deferUntil`; asserted through the Today filter, not the field | — |
| F7 | Priority tokens `!high/!medium/!low` | **Met** (S6) | Absence stays `nil` rather than becoming `.normal` | — |
| F8 | `time:` / `from:` / `to:` | Absent | Time-of-day parsing now exists; the tokens await a time-entry context to consume them | S12 |
| F9 | Natural dates — today, tomorrow, weekdays, ISO, offsets | Met | `NaturalDateParser.swift:105-161`; 6 tests | — |
| F10 | Natural dates — month names, "next Tuesday", "in 2 weeks", times | **Met** (S6) | `interpret(_:)` over whole phrases; `.monthDay` resolves to the next occurrence rather than guessing a year at parse time | — |
| F11 | DST and timezone fixtures | **Met** (S6) | 23-hour and 25-hour days in Europe/London; a time inside the spring-forward gap; weekdays across three zones | — |
| F12 | Canonical action layer | Absent | Split across 5 places, no single owner. ADR 0007 | S5 |
| F13 | Capture is undoable | Absent | `StructuralUndoCoordinator` has no create inverse | S5 |
| F14 | Action commits model + links + undo + index atomically | Rejected (in part) | Index stays fire-and-forget by decision; divergence is detected and repaired by the generation counter. ADR 0007 | S5 |
| F15 | Shortcut registry with collision detection | **Met** (S8) | `ShortcutRegistry` in `ElephruitCore`; all 20 menu literals resolve through it; palette glyphs derived | — |
| F15b | Registration of a *global* hotkey | **Met** (S9) | Carbon `RegisterEventHotKey`; no entitlement, no Accessibility prompt | — |
| F16 | Stable links; archived sources do not cascade-delete history | Met | `Item.timeEntries` is `.nullify` deliberately; `deletingAnItemDoesNotDestroyTime:228` | — |
| F17 | Attachment stable ID, relative path, UTI, size, checksum | Met | `AttachmentStore.swift:63-138` | — |
| F18 | A failed import never leaves an orphan | **Met** (S10) | Bytes rolled back when the commit fails; file-first ordering kept per ADR 0003 | — |
| F19 | Attachment bytes removed only after the transaction commits | **Met** (S1) | Row deleted and saved first; bytes after. `AttachmentStore.swift` | — |
| F19b | Grace-period cleanup rather than immediate deletion | **Met** (S10) | Seven days in `.removed/<uuid>__<epoch>`; swept by the reconciliation pass | — |
| F20 | Shared-reference safety | **Met** (S10) | Structural: one directory per attachment, so no file is ever shared. Dedup deliberately not built — see S10 | — |
| F21 | Orphan reconciliation at launch | **Met** (S10) | `AttachmentReconciliation`; dry-runnable, idempotent, offered not performed | — |
| F22 | Search indexing incremental, cancellable, off main thread | Met | `@ModelActor IndexWorker`, cursor paging, `Task.checkCancellation()`, generation-stamped rebuild | — |
| F23 | Structured filters `type/tag/project/person/is/due` | Met | `SearchQuery.swift:181-184`; 12 `is:` values | — |
| F24 | Filters `duration:` `source:` `type:time` | Absent | Not in `recognisedKeys` | S13 |
| F25 | Result categories and quotas | Absent | One flat `limit: 200`; grouping is view-level only | S13 |
| F26 | Permissions and privacy centre | Partial | Calendar has 5 explicitly-mapped states with per-state explanations and one Settings toggle. No centre | S11 |
| F27 | App degrades gracefully when a permission is denied | Met | `EventKitCalendarProvider.swift:45-56`; `.writeOnly → .denied` | — |

## Quick Jot

| # | Requirement | Status | Evidence | Slice |
|---|---|---|---|---|
| Q1 | Reusable floating panel, not a main-window sheet | **Met** (S9) | `QuickJotPanel`, a non-activating floating panel across all spaces | — |
| Q2 | Opens while another app is active | **Met** (S9) | Carbon hot key plus the menu-bar entry; neither needs the main window | — |
| Q3 | Global shortcut | **Met** (S9) | `GlobalHotKeyCenter`; default follows the registry's Quick Jot binding | — |
| Q4 | A global hotkey as *the* mechanism | Rejected | ADR 0008; `docs/10 §0` | — |
| Q5 | ⌘↩ saves exactly once | **Met** (S9) | Intercepted in `CaptureTextField.keyDown`; controller save tested | — |
| Q6 | Escape cancels without saving | Met, untested | `:155-156`, plus the escape ladder | S9 (test) |
| Q7 | Empty or whitespace-only refused | **Met** (S9) | `emptySavesNothing` | — |
| Q8 | Save failure retains text and explains | **Met** (S9) | Error shown in the panel; only a successful save clears | — |
| Q9 | Focus loss does not discard the draft | **Met** (S9) | Text lives on the controller; only a successful save clears it | — |
| Q10 | Focus returns to the previously active app | **Met** (S9) | Frontmost app recorded on show, reactivated on hide | — |
| Q11 | Autocomplete at caret for `#` `@` `>` `due:` `follow:` | **Met** (S9) | `CaptureCompletion`, a pure type; reuses `titleSuggestions` unchanged | — |
| Q12 | Repeated invocation never creates a second panel | **Met** (S9) | One controller owns one panel; a second show focuses it | — |
| Q13 | Menu-bar Quick Jot entry | **Met** (S9) | Beside the timer controls | — |
| Q14 | Shortcut conflict appears non-blockingly in Settings | **Met** (S9) | `ShortcutSettingsSection` reports registry collisions and system refusals | — |
| Q15 | Whole interaction works without a mouse | Unverified | Plausible; nothing asserts it | S9 |
| Q16 | Sandboxed release build works without Accessibility | Unverified | Never performed. The one item no unit test can discharge | S9 |

## Rich documents

| # | Requirement | Status | Evidence | Slice |
|---|---|---|---|---|
| R1 | Rich payload with format version and revision | Absent | `Item.body` is `String`; editor is `isRichText = false` | S14 |
| R2 | Rich text stored *in* `Item.body` | Rejected | ADR 0006 — body stays the projection | — |
| R3 | RTFD as the storage format | Rejected | Prototype: drops custom attributes, so wiki-link targets and attachment identity cannot be stored. ADR 0006 | — |
| R4 | Plain-text projection, lossless | Partial | `searchText` exists and works; must additionally strip `U+FFFC` once attachments are inline | S14 |
| R5 | `RecoveryDraft` / crash-recoverable editor state | Absent | Neither exists | S14 |
| R6 | Character and paragraph formatting, lists, checklists | Absent | None | S14 |
| R7 | Tables | Absent | Prototype confirms `NSTextTable` round-trips in both candidate formats | S14 |
| R8 | Inline images and file elements | Absent | — | S14 |
| R9 | Wiki links, unresolved state, backlinks | Met | `WikiLink.swift`; `ItemLink.swift:11-16`; index-backed reconciliation `ItemRepository.swift:668-744` | — |
| R10 | ⌘K hyperlinks | Absent | ⌘K is the command palette | S14 |
| R11 | Editor zoom is display-only | Absent | No zoom | S14 |
| R12 | Autosave debounced and selection-preserving | Met | 500 ms; selection preserved on external writes | — |
| R13 | Save on focus loss or terminate | **Met** (S2) | `PendingSave` + `willTerminateNotification` and `didResignActiveNotification` in `ItemDetailView` | — |
| R14 | Multi-window revision handling | Absent | "New Window" is `.disabled(true)` | S14 |
| R15 | Export plain text and Markdown | Met | ~35 round-trip tests | — |
| R16 | Export RTF / HTML / PDF | Absent | `ExportFormat` has three cases | S14 |
| R17 | Archive preserves attachment identity and content | **Met** (S3) | Bytes written into the bundle; SHA-256 asserted equal after a round trip through two libraries | — |
| R18 | A capture commits everything it wrote | **Met** (S1) | `captureCommitsEverythingItWrote`; `@person` links were never saved before | — |

## People

| # | Requirement | Status | Evidence | Slice |
|---|---|---|---|---|
| P1 | Person identity with contact details | Partial | `ItemKind.person` + `PersonProfile` | S11 |
| P2 | Derived relationship context | Met | `PersonContext`; only `.meeting`/`.interaction` count as contact; 22 tests | — |
| P3 | Notes stay canonical and appear through links | Met | Bodies are never copied into People | — |
| P4 | Timestamped interactions | Partial | `recordInteraction` has summary/date/notes; no attachments, no suggested facts, no follow-up | S11 |
| P5 | Follow-up suggestions never act on their own | Met | Off by default; `suggestionsNeverAct:292` proves item count is unchanged | — |
| P6 | Three-column workspace | Absent | Generic kind list + a detail view that defers the workspace in its own doc comment | S11 |
| P7 | People overview | Absent | `allContexts()` exists; nothing renders it (`docs/14:123`) | S11 |
| P8 | Merged reverse-chronological timeline | Partial | Data exists; view renders a summary line and two unmerged lists | S11 |
| P9 | Celebrations | Absent | `PersonProfile.birthday` stored, read by nothing | S11 |
| P10 | Attendee → person matching | Absent | `attendeeNames` populated, consumed by nothing | S11 |
| P11 | Contacts identity and linking | Absent | No `import Contacts`, no entitlement — deliberately (`docs/15:131`). Stub only | Deferred |
| P12 | Reciprocal relationships | Absent | Planned `docs/09:432`, never implemented | Deferred |
| P13 | Observations with history and provenance | Absent | No entity; facts can only be prose | Deferred |
| P14 | Temporal estimates labelled as estimates | Absent | — | Deferred |
| P15 | Groups and smart groups | Absent | People is a flat `.kind(.person)` query | Deferred |
| P16 | Command bar for people | Partial | ⌘K palette exists and is general; no people or timer commands | Deferred |
| P17 | Meeting Brief | Absent | — | Deferred |
| P18 | My Card and share profiles | Absent | — | Deferred |
| P19 | Business-card / PDF scan import | Absent | — | Deferred |
| P20 | Relationship scores, pipelines, productivity scores | Rejected | Product principle; absent and to stay absent | — |

## Time tracking

| # | Requirement | Status | Evidence | Slice |
|---|---|---|---|---|
| T1 | `TimeEntry` is a separate versioned entity, not an Item | Met | SchemaV2; compound index `(endedAt, deletedAt)` | — |
| T2 | Duration derived, never stored | Met | `TimeEntry.swift:132` | — |
| T3 | Zero-or-one running timer | Met | Enforced per-save; a switch is one save; 18 tests | — |
| T4 | Crash and stale recovery, never silent | Met | Heartbeat + sleep/wake; 3 choices + defer; 9 tests against a real on-disk store | — |
| T5 | Links to archived objects preserved | Met | `.nullify`; `deletingAnItemDoesNotDestroyTime:228` | — |
| T6 | Continue creates a new interval | Met | `resumeCarriesTheSubject:329` | — |
| T7 | Full menu-bar use without the main window | Partial | Start/stop/recents present; no Quick Jot entry, no favourites | S9, S12 |
| T8 | Start from the command palette | Absent | Zero timer references in `CommandPaletteView` | S12 |
| T9 | Keyboard manual entry | Met | `ManualTimeEntrySheet`; `manualEntryNeedsDuration:119` | — |
| T10 | Today time surface | Absent | Home shows one line; no per-day timeline | S12 |
| T11 | Calendar day/week grid, planned vs actual | Absent | The `calendar` destination is declared-but-unavailable | Deferred |
| T12 | Split / merge | Absent | No repository method | S12 |
| T13 | Overlap detected, never silently changed | Absent | Two manual entries covering the same hour are accepted silently | S12 |
| T14 | Estimate vs actual — the stored field | **Met** (S4) | `Item.estimateMinutes`, optional so absence is not a zero; survives a real legacy-store migration | — |
| T14b | Estimate vs actual — surfaced in the interface | Absent | — | S12 |
| T15 | Reports with filters and presets | Partial | 5 fixed windows, 4 groupings, top-6 bars. No arbitrary ranges, no destination | S12 |
| T16 | Archive of time | **Met** (S3) | `ArchiveTimeEntry`; exact intervals, links, tags, source; a running timer re-imports running |  — |
| T16b | CSV export of a time report | Absent | — | S12 |
| T17 | Raw interval fidelity despite display rounding | Met | Duration is derived; no rounding is stored | — |
| T18 | Idle detection with inspectable decisions | Absent | The heartbeat makes it possible; nothing uses it | Deferred |
| T19 | Long-timer warnings, reminders, Pomodoro, breaks | Absent | — | Deferred |
| T20 | Time entries in search without flooding results | Absent | `TimeEntry` appears nowhere in `ElephruitSearch`; no `type:time`, no quotas | S13 |
| T21 | Week report under 50 ms at 200,000 entries | *pending re-measurement* (S13) | Predicate fixed: `endedAtSortKey` gives the lower bound somewhere indexable. Before: 93.4 ms | S13 |
| T24 | Week report under 50 ms at realistic scale (≤60k) | Met | 47.1 ms at 60,000 entries — three decades of heavy use (`docs/12`) | — |
| T22 | Team comparison, attendance, utilisation, approvals, payroll, scoring, public links | Rejected | Product principle; absent and to stay absent | — |
| T23 | Opt-in local activity suggestions | Absent | No automatic time capture of any kind | Deferred |

## Infrastructure

| # | Requirement | Status | Evidence | Slice |
|---|---|---|---|---|
| I1 | Zero third-party dependencies | Met | `Package.swift` has no `dependencies:`; FTS5 via system `sqlite3` | — |
| I2 | Warnings as errors, Debug and Release | Met | `.strict` on every target; `SWIFT_TREAT_WARNINGS_AS_ERRORS = YES` | — |
| I3 | No `@unchecked Sendable` / `nonisolated(unsafe)` / `@preconcurrency` | Met | Enforced by `SourceHygieneTests` | — |
| I4 | CI | Absent | `.github/` does not exist | S15 |
| I5 | UI tests | Absent | No XCUITest target; `AccessibilityID`s consumed by nothing | S15 |
| I6 | One search engine | Partial | Legacy `DefaultSearchEngine` still compiled, tested, and referenced at `ElephruitApp.swift:397` | S15 |
| I7 | Four published v2 performance targets instrumented | Absent | Cold launch, rebuild main-thread blocking, resident memory, 200k keystroke p95 — none has an instrument | S15 |
| I8 | Full index rebuild under 6 s at 50k | **Met** (S4) | 5734 ms with `#Index<Item>([\.createdAt])`, down from 6150 ms. The project's only known miss, now closed |  — |
| I9 | A real cross-version migration is exercised | **Met** (S4) | A store generated from commit `71f49ae` (pre-`TimeEntry`) migrates to V3 via `RealStoreMigrationTests`, which had never run before |  — |
