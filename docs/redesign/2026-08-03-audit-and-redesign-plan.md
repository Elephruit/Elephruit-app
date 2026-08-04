# Elephruit — UI/UX Audit and Redesign Plan

2026-08-03, branch `claude/macos-ui-ux-audit-5489c0`. Audit-only pass: no code was changed.

Method: full read of the shell, navigation, design system, and module registry; four parallel
code sweeps (surface inventory, design-token usage, macOS-convention/accessibility conformance,
flow tracing); review of the fourteen-module screenshot set in `docs/redesign/2026-07-31/` in both
appearances; and both prior redesign reports, whose unresolved findings are folded in rather than
rediscovered. Note the screenshots predate the Tasks→Reminders unification (PR #62), so "Tasks"
screens shown there are now the Reminders workspace, and Home/Upcoming no longer exist.

Every section and subsection is numbered for revision by reference.

---

## 1. Phase 1 — What exists

### 1.1 Framework and architecture

**Stack.** Pure SwiftUI over targeted AppKit escapes, Swift 6 strict concurrency, SwiftData.
Minimum deployment **macOS 26** (Xcode 27). One thin app target (`Elephruit/`) over one local
package (`Packages/ElephruitKit`) with eight modules: Core, Model, Persistence, Search, Design,
Transfer, Integrations, Features. Zero third-party dependencies. State lives in `@Observable`
feature models; services are constructed once in `AppEnvironment` and injected via the SwiftUI
environment; no singletons. ~1,800 tests run without Xcode.

**Scenes.** One `WindowGroup` (1180×760 default, 900×520 min), two `MenuBarExtra`s (timer,
calendar), one `Settings` scene, and three code-created `NSPanel`s (Quick Jot, Quick Log, Mini
Timer — all correctly non-activating, join-all-spaces, full-screen-auxiliary; the strongest
platform work in the app).

**The shell is fully custom — the central architectural fact for this redesign.**
`RootView.swift:328` builds the window as a plain `HStack`: a fixed-width sidebar (hand-rolled
8-pt `DragGesture` resize strip, `RootView.swift:285`) beside a `NavigationStack` whose content
panes are a second `HStack` with widths computed by `ModuleShellLayout.widths(…)`
(`ElephruitDesign/ModuleShellLayout.swift:255`) from per-module policy tables
(`ModuleLayoutPolicy.swift`). `NavigationSplitView`, `HSplitView`, and `NSSplitView` appear
zero times. Only the trailing inspector is native (`.inspector`, `RootView.swift:403`).

This was done deliberately, twice, after AppKit's split view refused the per-module width
policies (documented in `ModuleShellLayout.swift:62–66` and both prior reports). The arithmetic
is pure, well-tested (~60 tests in `ModuleLayoutTests.swift`), and genuinely good. But the
presentation costs are what make the app look and feel non-native:

1. **No sidebar material.** `.listStyle(.sidebar)` is set, then `.scrollContentBackground(.hidden)`
   (`SidebarView.swift:122`) suppresses it and `RootView.swift:334` paints opaque
   `windowBackgroundColor` — no vibrancy, no desktop tint, contradicting `Tokens.swift:200`
   ("Sidebars use a material instead").
2. **A `Color.clear` toolbar shim** sized `sidebarWidth − (isFullScreen ? 40 : 128)`
   (`RootView.swift:365`) fakes the toolbar/sidebar boundary with magic numbers tied to the
   traffic-light width.
3. **The list↔detail divider is a non-interactive `Divider()`** (`RootView.swift:469`). Users
   cannot resize the list column at all.
4. **The width-persistence pipeline is orphaned.** `ModuleColumnWidth.moduleColumnWidth(…)` and
   `ModuleLayoutStore.setWidth` have zero callers; `stored:` is always empty. Column widths are
   never user-adjustable and never restored.
5. The sidebar resize strip sets no `NSCursor`, has no double-click reset, no collapse snap.

**Other constraints that will shape the overhaul:**

- **`ReminderComposer.swift` is 2,203 lines, ~75% of it AppKit focus/popover plumbing**
  (`ReminderComposerFocusRouter`, `ReminderComposerEventMonitor`, five `NSPopover`s with
  `.applicationDefined` behavior) to make Tab traverse an inline card. Any visual change to the
  composer fights this machinery.
- **Records bypasses the shell entirely** (`RootView.swift:455`): full-width workspace beside a
  bespoke browser sidebar. Every other module goes through `contentPanes`.
- **The same person renders as two different pages** depending on route: `RecordsWorkspaceView`
  (tabs) via the sidebar, `PersonWorkspaceView` (one long scroll) via `ItemListView`/⌘K.
- **Structural undo is architecturally stranded** (§2.1.1).
- **Search is architecturally bound to `ItemListView`** — the *fallback* branch of
  `primaryPane` — so ⌘F cannot reach the five module surfaces that don't use it (§2.1.2).
- Two competing sidebar-width systems coexist (`Theme.Size.sidebar*` = 190/224/320 vs
  `SidebarMetrics` = 180/240/300); the former is only asserted in tests, the latter is what
  renders.

### 1.2 Screen and surface inventory

Full tables live in the audit transcripts; this is the complete census with the load-bearing rows.

**1.2.1 Scenes and windows** — main `WindowGroup` (`ElephruitApp.swift:19`); Timer
`MenuBarExtra` (`:38`, content `TimerControls.swift:59`); Calendar `MenuBarExtra` (`:58`,
content `CalendarMenuBar.swift:14`); Settings (`:76`); `QuickJotPanel` (`QuickJotPanel.swift:14`,
global ⌘⇧J); `QuickLogPanel` (`QuickLogPanel.swift:26`, global ⌘⇧L); `MiniTimerPanel`
(`MiniTimerPanel.swift:22`, ⌃⌘M); floating timer overlay on every screen
(`FloatingTimerView.swift:24`, mounted `RootView.swift:105`); two `NSSavePanel` bridges
(`ExportSheet.swift:131`, `TimeReportView.swift:731`). "New Window" exists and is
`.disabled(true)` — and would open `everything://main` while the registered scheme is
`elephruit` (§2.1.6).

**1.2.2 Top-level destinations.** Global: **Today** (`TodayView.swift:29`, ⌘0) and **Inbox**
(rendered by `ItemListView.swift:15`, ⌘1). Modules (`AppModule.swift:23`): Calendar
(`CalendarWorkspaceView.swift:10`, ⌘6), Reminders (`RemindersWorkspaceView.swift:6`, ⌘7),
Records (`RecordsWorkspaceView.swift:9`, ⌘5), Notes (`ItemListView` + `NotePageView.swift:15`,
⌘3), Time (Log `TimeView.swift:14` / Reports `TimeReportView.swift:20` — no shortcut), Areas,
Bookmarks, Archive, Trash (all `ItemListView`, no shortcuts). Projects is a top-level sidebar
tree (`ProjectsSidebarSection.swift:11`, ⌘4) opening `ProjectWorkspaceView.swift:10` with seven
sub-views: Board (`KanbanBoardView.swift:14`), Table (`WorkItemTableView.swift:12`), Calendar,
Timeline, Overview, Bugs (`BugTrackerView.swift:10`), List. Records has 14 scopes
(`RecordsScope.swift`) including Celebrations, Duplicates, and Needs-Follow-up.

**1.2.3 Modal and transient surfaces: ≈89 sites.** 44 `.sheet` across 20 files — 17 of them in
the People/Records cluster, and **10 on `PersonWorkspaceView` alone**; 15 `.popover`; 6
`.alert`; 16 `.confirmationDialog`; 5 `.fileImporter` + 1 `.fileExporter`. Three flows nest
modality: Quick Entry → "More…" → editor sheet; `SaveSearchSheet` inside search results; a
people-picker popover inside `LogInteractionSheet`.

**1.2.4 Toolbars.** Six real `.toolbar` bodies (window shell, item list, item detail, note
detail, Time log, Time reports, project search) — and then ten in-content bars that are *not*
window toolbars: `CalendarToolbar` (which re-implements the entire Calendar sidebar as an
overflow menu, `CalendarWorkspaceView.swift:619`), `TodayToolbar`, `TimeSurfaceTabs`,
`ProjectViewTabBar`, `ProjectBugAddBar`, `BatchActionBar`, the Reminders bottom bar,
`SectionIndexBar`, `AdaptiveActionBar`, `RecordsCommandBar`.

**1.2.5 Settings** — 9 tabs (`ElephruitApp.swift:435`): General (a single toggle), Appearance,
Time, Reminders, Calendar, Records, Shortcuts, Privacy, Advanced.

**1.2.6 States.** Empty: 45 `EmptyStateView` sites in 26 files, copy centralized in
`DetailEmptyState.swift` — the one component category at full adoption. Loading: 21
`ProgressView` sites. Error: `FailureStateView`, seven distinct in-content banners, 6 alerts.
Onboarding: Contacts import only (`ContactOnboardingView.swift`); there is no first-run
experience.

**1.2.7 Dead surfaces.** `MyCardView`, `ShareProfileCard`, `CardScanView`
(`RecordPersonDestinations.swift:162, 292, 376`) and `ContainmentRepairSummary`
(`ContainmentRepairViews.swift:170`) have zero references; the first two own a file
exporter/importer that can never fire.

### 1.3 The current design system

**1.3.1 What exists and is good.** `Theme` (`ElephruitDesign/Tokens.swift`): a 4-pt spacing
scale (2/4/8/12/16/24/40), three radii (4/6/10), ten text styles all built on `Font.TextStyle`
(Dynamic-Type-correct by construction), 24 semantic colors built exclusively on
AppKit semantic colors (zero raw RGB anywhere — test-enforced), a 13-color user palette with
SwiftUI+AppKit resolutions defined once, selection-safe `rowForeground`/`rowTint` modifiers,
and a motion namespace with centralized Reduce Motion handling. `SourceHygieneTests` enforces
the color rule, a decoration budget (≤1 shadow, ≤1 material per chain), US English, and symbol
validity. `SidebarMetricsTests`, `InspectorLayoutTests`, and `ModuleLayoutTests` (~60 tests)
assert layout arithmetic including at accessibility text sizes.

**1.3.2 Where it fails: the metric layer is not enforced, and it leaked.** 581 hardcoded
numeric design values across 82 of 157 feature files:

| Category | Count | Worst offenders |
|---|---|---|
| Fixed-size fonts `.font(.system(size:))` | 71 (16 distinct sizes, 3pt–34pt) | `TodayRows` (9), `TodayComponents` (8), `CalendarMonthView` (6, incl. a 3-pt font at `:279`) |
| Frame magic numbers | 314 | `PersonCaptureSheets` (17), `PersonContactEditor` (15) |
| Opacity literals | 96 (30 distinct alphas) | Person cluster (33 of 96) |
| Corner-radius literals | 35 (adds 9 off-scale radii: 1,2,3,7,9,12,15,16,18) | `PersonTimelineDetailSheet` (7) |
| Padding literals | 44 (incl. `.leading, 21/118/174`) | `ReminderComposer` (10) |
| Ad-hoc animations | 12 (8 durations, 4 curves; 9 bypass Reduce Motion) | `KanbanBoardView`, `TodayRows`, `RootView:186` |
| Shadows (no shadow token exists) | 9 (5 radii × 6 opacities) | Person cluster, Kanban |

**The Person/Records cluster is a second, undeclared design system**: radii 7/9/12/15/18,
eyebrow headers at `size: 10 bold, tracking 0.8` vs the token's caption/0.4, its own icon-tile
recipe at five sizes, and five of the ten worst files. Converging it removes roughly a third of
every category above.

**1.3.3 Duplicated components.** Shared `TagChip`/`FilterChip` exist with 2 uses each — against
8 local chip types plus 26 hand-built inline capsules with four different fill recipes. Eleven
local reimplementations of `SectionHeader` (three fonts, three trackings). Six "icon in a
tinted rounded square" implementations, no two identical. Four initials-avatar implementations
with two different initials algorithms. Seven+ card recipes ignoring the intended
`floatingControl()` modifier. Forty local `*Row` structs against one use of the shared
`ItemRow`. 

**1.3.4 Contradictions and dead tokens.** Two sidebar width systems (§1.1); three glyph-column
widths (20 vs 16 vs 26); three row heights (28/26/22); `Theme.Size.inspectorWidth` (280) has
zero references and matches none of the three real inspector width tables;
`Theme.Motion.reorder` and `Theme.Text.editorBodyMonospaced` are dead; `Components.swift`
itself hardcodes glyph sizes 34 vs 38 for the same element in `EmptyStateView` vs
`FailureStateView`. One live hygiene violation: `KanbanBoardView.swift:109` uses
`.black.opacity(0.18)` for a shadow, which should currently fail
`coloursComeFromTheDesignSystem`.

**1.3.5 Assets.** `AccentColor` is the only light/dark pair (a custom blue that silently
overrides the user's system accent while `Tokens.swift:209` claims selection "follows the
user's accent"); `BrandLogo`/`BrandMark` are 1×-only PNGs with empty 2×/3× slots — blurry on
every Retina display the app can run on.

### 1.4 Primary flows, as they actually run

**1.4.1 Quick capture (global).** ⌘⇧J → type with grammar → ⌘↩. **3 interactions; focus lands
correctly.** But the flow ends in *silence*: the panel closes, focus yields to the previous
app, and there is no confirmation, no destination readout, no undo — the error path is better
instrumented than the success path. A mistyped `>Project` files silently to the Inbox. The
menu-bar "Quick Jot…" sheet variant is shadowed by the Carbon hot key registered on the same
⌘⇧J, so the intended two-door design has one working door.

**1.4.2 Create a reminder "X, due Friday, in project Y."** ⌥⌘N → inline composer card →
**13 keyboard interactions** (8 tab stops; picking the project throws focus to *When*, four tab
stops away from *Deadline*). The composer's grammar deliberately parses only `#`/`@`/`>` —
typing `due:friday !high` (Quick Jot's grammar, same sigils) leaves the tokens **literally in
the title**. Return means three different things depending on the focused field. Clicking
anywhere outside the card silently commits and closes. The reminder list itself is one flat
`createdNewestFirst` query — no sections, no due-date order, no search — with no keyboard
selection and double-click required to edit. The module's policy declares detail *and*
inspector `.unavailable`, so ⌥⌘I is dead here.

**1.4.3 Today.** Space completes (rows are individually `.focusable()`), Return opens the
inspector — unconditionally re-opening it if the user closed it. Hover exposes exactly three
actions (start timer / move to tomorrow / flag). Rescheduling offers five fixed choices in a
context submenu; **an arbitrary date requires the inspector**. Quick-add is title-only — no
grammar, unlike both other capture surfaces. No multi-select. ⌘N from Today silently navigates
to Notes (the File-menu `create(_:)` only *navigates*; the actual creation shortcut lives on
`ItemListView`'s toolbar button). ⌘F does nothing (§1.4.4).

**1.4.4 Search.** In Inbox/kind lists/tags/saved searches: **⌘F → type → ↓ → ↩, 4
interactions**, with restored previous query, live preview on highlight, amber notes for
unparsed tokens, and a non-destructive Escape — the best-designed flow in the app. But
`.searchable` exists only on `ItemListView` and (with different semantics, and without the
focus request) `ProjectWorkspaceView` — so **⌘F is a silent no-op on Today, Reminders,
Calendar, Time, and Records**, and worse, it sets invisible search state whose Escape rung
swallows the next Escape press. ⌘K palette results for reminders/tasks/bugs select into
`.kind(...)` lists whose modules have no detail pane — **the row is selected and nothing
opens anywhere**.

**1.4.5 Timer.** Start from a Today row: 1 interaction (hover ▶). Stop: 1 (floating overlay).
Viewing today's total: **3 more** (⌘K → "time" → ↩ — Time has no module shortcut). Seven timer
surfaces exist (menu-bar extra, floating overlay, its collapsed pill, the Mini Timer panel, the
tracker card, per-row buttons, Quick Log panel), each with its own start/stop/discard
vocabulary. ⌃⌘T ("Start or Stop Timer") starts an *untitled* timer — no shortcut starts a timer
on the current selection.

**1.4.6 Calendar.** ⌘⇧E → natural-language entry (the parse annotates but never rewrites your
text — excellent) → ↩: **3 interactions**. Meeting brief: select event → inspector → brief —
but the brief renders **only when exactly one person is linked** and the active calendar set
allows person context; a two-person meeting shows nothing, with no explanation. Quick Entry's
"More…" dismisses one sheet to present another.

**1.4.7 Person lookup.** ⌘5 → click: 2 interactions to the tabbed workspace page. ⌘K → name →
↩: 3 interactions to the *other*, scroll-structured page. "What do I owe them" is split across
the timeline (promises), the context inspector (reminders/scheduled/shared — which
`compactWindowWidth: 1280` makes **unopenable at the app's own 1180-pt default window**), and
the Shared Work tab (⌘5 route only). ⌘⇧K (Records command bar) is bound in the registry,
displayed in Settings, and **wired to nothing**.

---

## 2. Phase 2 — Diagnosis

Severity bands: **P0 — broken or amateur-looking** (fails outright, or would embarrass the app
in a screenshot); **P1 — makes the app hard to use**; **P2 — unrefined**. Every item names its
evidence.

### 2.1 Broken functionality surfaced by the audit (all P0; fix before any visual work)

1. **⌘Z does not undo structural changes — anywhere.** `AppServices.swift:648` creates a
   standalone `UndoManager` that is never installed on any window or published via
   `\.undoManager`; no `CommandGroup(replacing: .undoRedo)` exists. All 16 structural
   operations (trash, move, retag, archive, status) register undo on a manager the Edit menu
   cannot reach. Tests pass because they call it directly. The README's "⌘Z undoes structural
   changes" claim is currently false in the app.
2. **⌘F is dead on five of seven primary surfaces** and leaves the window in an invisible
   search mode that eats the next Escape (§1.4.4).
3. **⌘K is a dead end for work items**: palette-opening any reminder/task/bug selects into a
   list whose module has no detail pane and no inspector.
4. **The Records context inspector cannot be opened at the default window size** (policy
   threshold 1280 vs `.defaultSize` 1180) — the closest thing to a "what I owe this person"
   surface is invisible until the user happens to widen the window.
5. **Four registry shortcuts are bound, shown in Settings, and wired to nothing**: ⌘⇧K records
   bar, ⌘↩ complete, ⌘⇧F flag, ⌘⇧T move-to-today — the last also *colliding* with
   `TodayToolbar`'s hardcoded ⌘⇧T. Three literal `.keyboardShortcut`s bypass the registry whose
   stated invariant is that nothing may.
6. **Dead chrome**: "New Window" disabled and pointing at an unregistered URL scheme
   (`everything://` vs registered `elephruit`); Help menu replaced by a single permanently
   disabled link (also removing macOS Help search); `.menuBarExtraStyle(.window)` documented in
   a comment but never applied, so the live-clock label the comment promises can't render as
   designed; kanban drag UTI mismatch (`com.elephruit.task-drag` declared vs
   `com.elephruit.work-item-drag` exported) meaning the declared type never matches; one live
   `SourceHygieneTests` color violation (`KanbanBoardView.swift:109`).
7. **⌃⌘F (Search Calendar) collides with the system-wide Enter Full Screen**, and ⌃⌘Space
   (Quick Reminder) collides with Emoji & Symbols.
8. **Shortcut rebinding is advertised and absent**: `ShortcutRegistry.setBinding` has zero
   callers; the Settings tab is read-only over 3 of 31 commands. The README says "you can
   rebind all of them."

### 2.2 Visual problems

1. **P0 — The empty detail pane dominates every document module.** At the default window,
   ~60–70% of Today, Notes, People, Projects, and (pre-unification) Tasks is a white void with
   a small "Nothing selected" centered in it, while titles truncate in a ~300-pt list beside
   it ("Send the revised pricing table to P…", "A note with a title long enou…"). Both prior
   passes named it; the *shape* is untouched. This single condition is most of why the app
   photographs as amateur.
2. **P0 — The app has no visual identity: everything is flat gray.** Opaque gray sidebar (no
   material), gray chips, gray rows, hairline separators everywhere; the only chroma on most
   screens is alarm red/orange on dates. The result reads as a wireframe, and in dark mode as
   one undifferentiated slab (sidebar, list, and detail are near-identical grays; chip
   boundaries vanish — prior finding #13, still open). The accent color appears almost nowhere
   except selection.
3. **P0 — Alarm-red saturation.** Overdue dates render red down entire lists (six red dates in
   nine rows in the Today screenshot); Today draws lateness red while the Reminders row
   renderer uses amber — the same item, two urgency languages on adjacent screens (prior
   finding #4, explicitly left as a product decision; it needs deciding now).
4. **P1 — The Person cluster looks like a different app**: 15/18-pt radii, tinted cards with
   shadows, 10-pt bold tracked eyebrows, saturated pill docks — beside modules built from
   28-pt hairline rows. (§1.3.2–1.3.3.)
5. **P1 — Type hierarchy collapses in the dense surfaces.** 71 fixed-size fonts, including
   7–9-pt labels in the calendar grid, Today rows, and chips — below both legibility and
   Dynamic Type. Meanwhile list rows carry three text sizes in two lines plus chips plus
   dates, so lists read as texture rather than hierarchy.
6. **P1 — Chip noise.** Tag chips right-align under dates producing ragged two-column edges;
   gray-on-gray fills; 34 chip/capsule recipes (§1.3.3) guarantee they never read as one
   system.
7. **P2 — Toolbar poverty.** Most modules show a nearly empty unified toolbar (title + sort +
   `+` + search field) while real navigation (view switching, period pickers) sits in
   in-content bars one row below — two stacked chrome rows where native apps have one
   (Calendar's is literally titled "Elephruit" with a second toolbar row beneath; prior
   finding #9).
8. **P2 — Iconography drift**: Records is `circle.grid.2x2` (meaningless for a people module);
   glyph-only meaning with no labels (link glyphs on Today calendar rows, sparkle in toolbar —
   prior finding #12); 15 distinct icon-tile sizes.
9. **P2 — Brand assets ship 1×-only** (§1.3.5) — the logo is soft on every Retina display.

### 2.3 Interaction problems

1. **P0 — Capture succeeds silently** (§1.4.1). The product's headline flow ("capture in under
   four seconds") ends with no confirmation, no destination, and no undo; a mistyped project
   files to the Inbox with the only warning gone when the panel closes.
2. **P0 — Two grammars share one syntax.** Quick Jot parses `!friday`/`due:`/`!high`; the
   Reminders composer deliberately doesn't, leaving those tokens in the title. Users cannot
   form a model of what typing does where (§1.4.2).
3. **P1 — The Reminders module is the weakest surface in the app** despite being the
   post-unification centerpiece: flat creation-order list, no sections or due grouping, no
   keyboard selection, double-click to edit, click-outside silently saves, no
   detail/inspector, and a 13-interaction happy path for "X due Friday in Y" (§1.4.2).
4. **P1 — No multi-select anywhere except `ItemListView`.** Today, Reminders, Calendar,
   Records, and Time act on one item at a time; `BatchActionBar` exists and is used once.
5. **P1 — Rescheduling from Today cannot reach an arbitrary date** without opening the
   inspector; the hover affordance offers only "tomorrow."
6. **P1 — Selection is conflated with opening.** Single click both selects and opens
   throughout (`NavigationLink` rows; Kanban selects *and* presents its editor on one tap);
   the sole double-click affordance in the app is the Reminders row. Finder/Mail convention
   (click selects; Return/double-click opens) appears nowhere.
7. **P1 — Modal pile-ups in People**: 10 sheets on one view, popovers inside sheets,
   sheet→sheet transitions in Calendar quick entry (§1.2.3). "Log Interaction" — a "quick"
   action — is a 700×620 six-section sheet.
8. **P1 — Seven timer surfaces with divergent vocabulary** and no way to start a timer on the
   current selection from the keyboard (§1.4.5).
9. **P2 — Today's Return-to-open force-reopens an inspector the user closed** — the exact
   behavior the Records policy documents removing.
10. **P2 — Inconsistent quick-add ladders**: three capture surfaces (Quick Jot, Reminders
    composer, Today quick-add) with three different capability sets.

### 2.4 Non-native behavior

1. **P0 — The window shell forgoes the native split view** (§1.1): no sidebar
   vibrancy/desktop tint, no draggable list divider, no divider cursor or double-click reset,
   toolbar boundary faked with magic numbers, per-module widths never restored. This is
   simultaneously the biggest "doesn't feel like a Mac app" item and the deepest refactor —
   split out in §4.6.
2. **P1 — Menu bar gaps**: no Format menu despite a rich-text editor; the standard Find
   submenu (`Find/Find Next/Use Selection…`) is *replaced* by app navigation so in-document
   find is gone; no Print; Help disabled; Window menu can never hold the panels (they're
   AppKit-owned) and "New Window" is dead.
3. **P1 — Keyboard model breaks platform habits**: type-to-select is implemented and tested
   (`TypeToSelectBuffer.swift`) and wired to nothing; only 9 `.focusable()` sites, so most
   custom rows/cards are outside the Tab loop; kanban cards are unreachable and unmovable by
   keyboard entirely; `.defaultFocus` unused (sheets rely on `onAppear` focus hacks); no
   `.onMoveCommand` anywhere.
4. **P1 — Drag and drop is one feature deep**: kanban-internal only, plus one attachment drop
   target. No dragging items to projects or days, no sidebar reorder, no drag-out to Finder,
   nothing onto the Dock icon — in a product whose thesis is linking things together.
5. **P2 — Trackpad swipe actions** are correctly engineered (Mail-style scroll interception,
   VoiceOver rotor mitigation) but wired into exactly one list, with per-module action sets
   defined and unused; plus an undiscoverable window-wide "swipe to hide the sidebar" gesture.
6. **P2 — Context menus** cover lists well (26 sites) but only `WorkItemTableView` uses
   `forSelectionType:`; the other 25 act on the hovered row, not the selection. Calendar grid
   events have no context menu.
7. **P2 — Selection presentation is suppressed** via an `NSTableView` reach-through
   (`NativeListSelectionHighlight.swift`) in two Time rows, forfeiting activation/contrast
   behavior the sidebar's own comments argue for keeping.

### 2.5 Missing polish

1. **P0 — Dark mode has never been reviewed on screen** (stated in `DesignReviewLaunch`'s own
   doc comment and both prior reports; the dark screenshots confirm chips and separators
   dissolve). The color plumbing is right; the composition was never checked.
2. **P0 — Increase Contrast and Differentiate-Without-Color are handled nowhere** (zero hits
   for both environment keys). All the hand-drawn 15%-alpha fills, hover washes, and hairlines
   stay fixed when the user asks for more contrast.
3. **P1 — Reduce Motion leaks**: 9 of 12 ad-hoc animations bypass the (excellent) central
   mechanism, including the two most kinetic (sidebar slide, kanban reflow); the swipe
   coordinator hard-codes a 400 ms settle.
4. **P1 — Dynamic Type leaks**: the 71 fixed sizes (§2.2.5) plus unscaled row heights
   everywhere outside the sidebar (`@ScaledMetric` used 7×, all for sidebar rows).
5. **P1 — Hit targets**: a systematic `.controlSize(.small)` habit (78 sites) and a dozen
   sub-28-pt controls (22×22 down to 18×22 in the floating timer and event inspector).
6. **P1 — State restoration is half-done**: module and sidebar width restore; selected item,
   inspector visibility, layout/focus mode, search state, scroll positions, and calendar view
   date do not. Every relaunch opens a list with an empty detail pane — feeding §2.2.1
   directly.
7. **P2 — Hover/focus asymmetry**: the custom `hoverHighlight` never responds to keyboard
   focus, and `.plain` buttons (146 sites) have no focus ring, so keyboard users get no "what
   would I hit" signal that mouse users get.
8. **P2 — Empty states are well-written but visually inert** — pale glyph + two gray lines
   centered in a huge void; the prior pass fixed the *copy* and the buttons, not the
   composition.

---

## 3. Phase 3 — Direction

### 3.1 Visual direction

**3.1.1 Recommended: "Quiet instrument" — native materials, one accent, typographic
hierarchy, content-forward layout.** The product definition demands *calm density*,
keyboard-first speed, and privacy-grade trustworthiness. The direction that serves that is not
decoration but *structure*: native window anatomy (vibrant sidebar, unified toolbar that owns
each module's controls), a disciplined type ramp doing the hierarchy work color currently
fails to do, one dependable accent used sparingly for interaction (never for status), tinted
semantic surfaces replacing today's gray-on-gray, and layouts that give the window to content
instead of to voids.

Reference points, and what to take from each:

- **Things 3** — the benchmark for calm density in exactly this domain: generous row leading
  with small metadata *below* titles, one blue reserved for interactive elements, whitespace
  as grouping instead of hairlines, a Today view that mixes calendar and tasks without a
  single box. Take: list composition, restraint with separators, the "headings not cards"
  page structure, Magic-Plus-style unambiguous creation.
- **Apple Reminders/Notes (macOS 26)** — the native anatomy: sidebar material with desktop
  tint, source-list sections with SF Symbols in accent-tinted circles, toolbar-owned view
  switching, inline `#tag` and grouped smart lists. Take: window structure, sidebar idiom,
  materials, and the standard toolbar item grammar the app currently scatters into content
  bars.
- **Fantastical** — the calendar module: colored event blocks with real fills (not 8% washes),
  a mini-month in the sidebar, natural-language entry with live parse feedback (Elephruit's
  parse-without-rewriting is already *better* — keep it and show it off), day/week/month
  density that still breathes. Take: event block treatment, hour-ruler typography, sidebar
  mini-month.
- **Craft** — the People pages: identity header with a large monogram, tinted section cards
  used *sparingly*, pill metadata that reads as designed rather than improvised. Take: the
  person page's header/two-column facts arrangement — but on system materials, not floating
  cards.

**3.1.2 Alternative: "Warm editorial"** — Bear/Agenda lineage: a serif-adjacent display face
for dates and page titles (New York), warmer paper-tinted backgrounds, heavier reliance on
typography and indentation over any chrome, almost no fills. It photographs beautifully and
suits a single-user memory tool emotionally. Not recommended as primary because: it fights
the density requirement in Calendar/Time/Kanban (data-dense grids want neutral surfaces); it
makes the eventual iPhone sibling harder to keep consistent; and it spends novelty on
surfaces where this app's differentiator is *speed and trust*, which the quiet-native
direction communicates better. Elements worth stealing regardless: New York for the Today
date rail and daily-note headers, and the discipline of letting type carry hierarchy.

### 3.2 Design system specification

**3.2.1 Color.** Keep the semantic-first architecture (it is correct and test-guarded);
*complete* it. All values resolve through AppKit semantics unless listed as custom.

| Role | Light | Dark | Source |
|---|---|---|---|
| Accent (brand) | `#2E9FD8` (0.180,0.624,0.847) | `#58B8E8` (0.345,0.722,0.910) | existing asset — **keep and commit to it** (decision D3, §4.8): links, selection, primary buttons, focused controls only. Never status. |
| Window background | `windowBackgroundColor` | same | existing |
| Content background | `textBackgroundColor` | same | existing |
| Sidebar | **system sidebar material** (vibrant) | same | new — replaces opaque paint |
| Raised surface (cards, popovers) | `underPageBackgroundColor` + elevation.1 | same | new token `Theme.Colors.raisedSurface` |
| Tinted surface (chips, callouts, selected pills) | `tint @ 12% fill / 25% stroke` | `tint @ 16% / 30%` | new tokens `tintedFill`/`tintedStroke` — replaces 30 ad-hoc alphas |
| Text primary/secondary/tertiary/placeholder | label ramp | same | existing |
| Overdue | `systemRed` — **date text and glyph only, never rows** | same | existing token; adopt the Reminders rule app-wide (resolves §2.2.3 to amber "n days late" phrasing + red reserved for *today-actionable* lateness; final call is D4) |
| Due today | `systemOrange` | same | existing |
| Completed | `systemGreen` | same | existing |
| Recording/timer | `systemRed` | same | existing |
| Capture | `systemPurple` | same | existing |
| Warning | `systemOrange` | same | existing |
| User palette | 13 system hues | same | existing |

**3.2.2 Typography** (SF Pro via text styles; all Dynamic-Type-relative — point values are the
macOS defaults for reference, never hardcoded):

| Token | Style/weight | Default pt | Role |
|---|---|---|---|
| `display` | `.largeTitle` semibold, tracking −0.4 | 26 | Today's date, person name, empty-library hero |
| `pageTitle` | `.title2` semibold, tracking −0.3 | 17 | Detail/page titles (existing `title`) |
| `sectionTitle` | `.headline` | 13 | In-content group titles (replaces ad-hoc `.headline` variants) |
| `rowTitle` / `rowTitleEmphasised` | `.body` / medium | 13 | existing |
| `rowSubtitle` | `.subheadline` | 11 | existing |
| `metadata` | `.caption` | 10 | existing |
| `eyebrow` | `.caption` semibold, uppercase, tracking +0.4 | 10 | **new** — the one sanctioned tracked-caps header; kills the 10-pt-bold/0.8 clones |
| `chip` | `.caption` medium | 10 | existing |
| `keyHint` | `.caption2` rounded medium | 10 | existing |
| `denseLabel` | `.caption2` | 10 | **new floor** — the *only* style allowed in calendar grids and month cells; the 3–9-pt literals are deleted, not tokenized |
| `editorBody` (+mono) | `.body` | 13 | existing; wire the dead mono token |

**3.2.3 Spacing — 8-pt-based scale with a 4-pt half-step.** The existing 4-pt scale's values
survive; the *grid discipline* changes: 8 is the default gap, 4 is the sanctioned half-step
for intra-row pairs, and 2 exists only as `glyphGap`. New names: `space1=4, space2=8,
space3=12, space4=16, space6=24, space8=32, space10=40` (12 stays: list-row internals need
it; it is on the half-step grid). The 1/2/3-pt micro-paddings (33 sites) round to 0 or 4. Row
vertical padding standardizes at 6 (half-step) giving the 28-pt row; page insets at 16/24.

**3.2.4 Radii**: 4 (chips, small controls) / 6 (rows, fields) / 10 (cards, popovers) / **16
(sheets & floating panels — new)**, replacing literals 12/15/16/18. Nothing else.

**3.2.5 Elevation** (new `Theme.Elevation`, replacing 9 ad-hoc shadows):

| Level | Use | Shadow |
|---|---|---|
| 0 | rows, chips, inline cards | none — border or fill only |
| 1 | raised cards, kanban cards at rest | `shadow.opacity(0.08), r 3, y 1` |
| 2 | popovers, floating timer, dragged cards | `shadow.opacity(0.16), r 10, y 4` |
| 3 | floating panels (Quick Jot/Log) | `shadow.opacity(0.22), r 20, y 8` |

**3.2.6 Icons.** SF Symbols only, `.medium` scale in rows, fixed 20-pt glyph column
(sidebar adopts 20, retiring the 16-pt `iconColumn`); tinted-circle sidebar glyphs à la
Reminders for top-level destinations (accent for Today/Inbox, palette colors for
projects/areas); one `IconTile` component (sizes S 24 / M 32 / L 44, radius 6/6/10) replacing
the six local recipes; module symbol fixes: Records → `person.crop.square.on.square.angled` or
`person.text.rectangle`, Reminders keeps `bell`… full table in the phase work.

**3.2.7 Motion.** Durations 120 ms (appearance/disappearance), 180 ms (state change), 240 ms
(spatial move) — `easeOut`; one spring (`.spring(response 0.3, damping 0.85)`) for reorder
and drag-settle; everything routed through `calmAnimation` (Reduce Motion honored by
construction); the swipe settle reads its duration from the token. The 12 ad-hoc curves are
deleted.

**3.2.8 Enforcement** — extend `SourceHygieneTests` with the numeric equivalents of the color
rule: allowlisted radii, spacing values, font constructors (`.font(.system(size:` banned
outside `Tokens.swift`), shadow API banned outside `Theme.Elevation`, `withAnimation`/
`.animation` banned outside `calmAnimation`. The color rule held at one violation in 508
files *because* it was tested; the metric layer failed *because* it wasn't. This test is the
cheapest insurance in the whole plan.

### 3.3 Target layout and navigation

**3.3.1 One window anatomy, three regions**: vibrant-material sidebar (native), content
column(s) under a real unified toolbar that owns each module's controls, native inspector.
Built on `NavigationSplitView` + `.inspector` (architecture decision §4.6; the fallback keeps
the custom shell and native-izes its presentation).

**3.3.2 One-level sidebar.** The two-level push sidebar is replaced by a single scrolling
source list — the pattern of Notes, Mail, Reminders, and Things, and the answer to "an index
is not navigation" that doesn't hide Tags/Pinned/Projects the moment you enter a module:

1. **Today** (⌘0, accent sun glyph, count) · **Inbox** (⌘1, count)
2. **Projects** — favourites + tree, exactly as now (it already won this argument in
   `AppModule.swift`'s own doc comment)
3. **Library** — Notes ⌘3, Reminders ⌘7 (due-today count), Calendar ⌘6, People ⌘5 (renamed
   from "Records" in the sidebar; kind vocabulary stays "record" internally — D5), Time ⌘8
   (new binding), Bookmarks
4. **Context section** — appears *below* Library when the selection warrants it: Calendar's
   calendars + sets; Notes' Ideas/Reference/Daily; People's groups + scopes. Disclosure
   sections in the same list, not a column swap — where you are never erases where you can go.
5. **Tags / Saved Searches** — as now, collapsed disclosure groups.
6. **Bottom rail**: Archive and Trash as small fixed rows above the sync status line (the
   Notes "Recently Deleted" pattern) — they stop being peers of Calendar. Areas moves into
   the Projects tree (an area is a container of projects; it is already rendered as one
   there).

Justification against the primary tasks: the traced flows show users pivot constantly between
Today, a project, Reminders, and a person — the two-level design taxes exactly those pivots
(module swap + push animation + a back affordance), and its payoff (short lists) is achievable
with sections. The swap also breaks the platform's spatial model: no other first-party app
replaces the whole source list on selection.

**3.3.3 The empty-detail problem is solved by policy, not copy** (kills §2.2.1):

- **Restore `selectedItemID` per module** (it's absent from `RestorationState`) so windows
  never *open* onto a void.
- Document modules (Notes, Bookmarks, Archive, Trash): auto-select the most recent item when
  selection is nil — Notes-app behavior; the editor is always alive.
- List-centric surfaces (Inbox, tag lists, saved searches): when nothing is selected the
  **list takes the window** (multi-column `Table` at width) and the detail column is absent —
  the policy engine already knows how (`hidesWhenNothingSelected`); it's just not used there.
- Reminders gets a real detail pane (§3.4.3), ending its `.unavailable` dead ends from ⌘K.

**3.3.4 Toolbar grammar.** Every module's primary controls move into the window toolbar:
view switcher (segmented/menu) on the leading edge of the content section, `+` primary
action, filter/sort menus, search field trailing. The in-content bars that duplicate sidebar
state (Time's period/grouping toolbar popups — prior finding #5; Calendar's
sidebar-as-overflow-menu) are deleted, not restyled. Calendar's second header row merges into
the one toolbar (title = month, prev/today/next as toolbar items) — resolving prior findings
#5 and #9.

### 3.4 Screen-by-screen redesigns

Each entry: layout → hierarchy → promoted/demoted → states.

**3.4.1 Today.** Two-column at ≥860 pt as now, but the day gets the toolbar (date title,
‹ › Today, filter menu) instead of a second header row. Left column: **Schedule** —
calendar events as tinted blocks with real fills on a light hour-gutter (not a list of gray
rows), joined seamlessly with due/started work in time order; **Anytime** below for undated
committed work. Right rail 320 pt: People (compact cards, §3.4.5 vocabulary), Daily note.
Overdue work presents as one collapsed amber group ("5 overdue") that expands — not six red
dates painting the column (with §3.2.1's status rule). Row grammar: checkbox · title ·
trailing date — chips move to a hover/inspector detail, killing the ragged second column.
Promote: reschedule-to-any-date (calendar popover on the hover action, not just "tomorrow");
multi-select with the existing `BatchActionBar`. Demote: the link glyph per event row
(context menu). Empty day: keep `TodayClearDayView`, restyled with the display face and the
next event's time. Quick-add adopts the full capture grammar (one parser everywhere — D2).

**3.4.2 Reminders** (the centerpiece module post-unification, currently the weakest — §2.3.3).
Structure: real `List` with keyboard selection; sections **Overdue / Today / Upcoming /
Anytime / Someday** (the scheduling model the app already argues for) with optional
project grouping; completed behind a toolbar toggle. Row: completion circle (animated,
Things-style) · title · start/deadline chip trailing (amber "n days late" phrasing) ·
project breadcrumb subtitle. Detail pane exists again (policy change): selecting shows the
`WorkItemDetailView` surface, ending the ⌘K dead end. The composer is rebuilt (§4.6.2) as a
`List`-inline row with the *capture grammar* (`>project @person #tag !date` parsed
identically to Quick Jot — D2), a visible parse preview replacing four of the eight tab
stops; Deadline and When become two adjacent chips; Return always commits; Esc always
cancels; click-outside asks nothing because commit is explicit. Space completes; ⌘↩ (the
already-bound, currently dead `completeReminder`) completes from anywhere; ⌘⇧F flags.

**3.4.3 Notes.** List column: title + one-line excerpt + relative date (already fixed), tag
chips demoted to a trailing dot-cluster with hover reveal. Detail: the editor centers its
720-pt measure on the *content* background with the toolbar owning Format (plus a real
Format menu — §4.4); when nothing is selected the most recent note opens (§3.3.3). The
notes context section (Ideas/Reference/Daily) lives in the one sidebar.

**3.4.4 Calendar.** Merge the two chrome rows into the toolbar (§3.3.4). Event blocks:
calendar-color fill at full `tintedFill` strength with a 3-pt leading bar and legible
`denseLabel` type — replacing the 8% washes that photograph as fog. Week/day scroll to
8 AM / first event on appearance. Month cells promote event pips to mini-bars with titles at
width. The sidebar context section carries the mini-month (the menu-bar extra already has
one to reuse), calendars, and sets — the overflow-menu duplicate is deleted. Meeting brief:
render for *n* linked people (composite brief), and when it can't, say why in one line with
the linking control inline — the one-person gate becomes visible instead of silent.

**3.4.5 People (Records).** One page, not two (§4.6.3): the workspace layout wins (browser
column + full-width detail), `PersonWorkspaceView`'s content becomes its Overview tab body.
The page adopts system materials: identity header (large monogram `IconTile`, name in
`display`, role/org subtitle, pronouns as plain metadata — not a chip), a plain-button
action row (the prior pass already de-pilled it), then two columns at width: facts +
contact left, timeline right. Quick facts become `LabeledContent` rows in a grouped
section — not ten tinted cards (prior finding #17 finally lands). "What you owe each other"
gets promoted to a first-class section fed by the same query the context inspector uses —
and the context inspector's 1280-pt threshold drops to fit the default window. The 10
sheets consolidate: Add Fact / Correct Fact / Add Relationship merge into one editable
inline pattern; Log Interaction slims to summary + kind + people with a "More detail"
disclosure.

**3.4.6 Time.** The toolbar owns period + grouping (sidebar duplicates deleted — prior
finding #5). Log rows group by day with a right-aligned monospaced duration column;
the tracker card becomes a toolbar-attached bar. Reports keep their table but adopt
`ReportSeriesPalette` chips at `tintedFill`. The seven timer surfaces reduce to four with
one vocabulary (menu-bar extra, in-window bar, mini panel, row buttons): the floating
overlay merges with the collapsed pill (one component, two sizes), and Quick Log's naming
panel is reachable from all of them by one verb ("Name timer…"). ⌃⌘T acts on the current
selection when there is one. Time gets ⌘8.

**3.4.7 Projects.** The workspace keeps its seven views but the tab bar moves into the
toolbar as a segmented control. Kanban cards adopt `Elevation` levels 1→2 (drag), become
focusable buttons with `.onMoveCommand` keyboard moves (§4.4), and the board gets
column-count headers. Overview's stat tiles adopt `IconTile` + `raisedSurface`.

**3.4.8 Search.** One search architecture: `beginSearch()` presents the token-grammar
search UI as an overlay of the *content column* on every surface (implementation shares
`InlineSearchResults`), so ⌘F works everywhere; module scope defaults to "this module,"
one keypress to "Everywhere." Result rows adopt the standard row grammar; work-item
results open in their project/Reminders detail (routing fix, §4.3). The palette (⌘K)
stays exactly as is — it's good.

**3.4.9 Capture surfaces.** Quick Jot: after ⌘↩, the panel confirms before closing —
120 ms state showing "✓ Inbox" (or the resolved project, with its color) in the footer;
unresolved `>name` offers "create project Y" inline before filing to Inbox. One parser
(D2) across Quick Jot, Reminders composer, Today quick-add. The panel itself adopts
`Elevation.3`, radius 16, and the capture-purple accent it already owns.

**3.4.10 Settings.** Merge General into a combined pane (its one toggle joins Appearance);
Shortcuts becomes a real key-capture editor over all 31 registry commands with per-row
reset (the model already supports it — `setBinding`/`reset`/`resetAll` are written and
uncalled). Everything else keeps its structure.

**3.4.11 Menus & system surface.** Restore the standard Find submenu (in-editor find) and
move Search Everything to ⌥⌘F… no — Search Everything keeps ⌘F as the app-wide
convention *outside* text editing contexts; in-editor, ⌘F does document find (the standard
resolution: the editor's focused context wins). Add Format menu (`TextFormattingCommands`
or explicit items mapped to the note editor). Add Edit ▸ Undo/Redo wired to the real undo
architecture (§4.3). Help menu gets a real (bundled or GitHub-doc) target or reverts to
the system default. New Window ships (scheme fix is one line — `elephruit://main`).
Menu-bar extras get their intended `.window` style.

---

## 4. Phase 4 — The plan

Phases are ordered so each leaves `main` shippable. Effort: S ≤ 1 day · M ≈ 2–4 days ·
L ≈ 1–2 weeks · XL > 2 weeks (single engineer). Risk: how likely the phase breaks behavior
or needs rework.

### 4.1 Phase A — Correctness (no visual change)

Everything in §2.1. Ship first; nothing below depends on pixels.

| # | Change | Files | Effort | Risk |
|---|---|---|---|---|
| A1 | Wire structural undo: publish the services `UndoManager` via `\.undoManager`/window; add `CommandGroup(replacing: .undoRedo)`; integration test that the *menu path* undoes a trash | `AppServices.swift`, `ElephruitApp.swift`, `RootView.swift` | M | Med — undo grouping across SwiftData needs care |
| A2 | Search reachability: route `beginSearch()` on Today/Reminders/Calendar/Time/Records to a real search presentation (interim: present the ItemListView search surface as an overlay); stop the invisible-search Escape swallow | `Navigation.swift`, `RootView.swift`, module views | M | Low |
| A3 | Fix ⌘K work-item routing (open in project workspace / Reminders detail) | `CommandPaletteView.swift`, `Navigation.swift` | S | Low |
| A4 | Wire the four dead shortcuts (⌘⇧K, ⌘↩, ⌘⇧F, ⌘⇧T); remove the three registry-bypassing literals; rebind ⌃⌘F (→ ⌥⌘F conflict-free choice) and ⌃⌘Space | `ShortcutRegistry.swift`, `ElephruitApp.swift`, `TodayToolbar.swift`, `ItemListView.swift`, `RemindersWorkspaceView.swift` | S–M | Low |
| A5 | Records inspector threshold ≤ default window; restore `selectedItemID` + inspector visibility + layout mode in `RestorationState` | `ModuleLayoutPolicy.swift`, `Navigation.swift`, `RootView.swift` | S–M | Low |
| A6 | Housekeeping: kanban UTI mismatch; `everything://`→`elephruit://` + enable New Window; `.menuBarExtraStyle(.window)`; fix/remove Help menu; delete dead surfaces (`MyCardView`, `ShareProfileCard`, `CardScanView`, `ContainmentRepairSummary`, dead tokens); fix the live `SourceHygieneTests` violation | plist, `ElephruitApp.swift`, `RecordPersonDestinations.swift`, `KanbanBoardView.swift` | S | Low |
| A7 | Shortcut editor UI over the existing registry API | `ShortcutSettingsSection.swift` | M | Low |
| A8 | Capture commit feedback + unresolved-project offer (§3.4.9 behavior only) | `QuickJotView.swift`, `CaptureComposer.swift`, `QuickJotPanel.swift` | S–M | Low |

### 4.2 Phase B — Design-system foundation

Depends on nothing above (parallelizable with A). The app looks the same or imperceptibly
better after it; every later phase gets cheaper.

| # | Change | Files | Effort | Risk |
|---|---|---|---|---|
| B1 | New tokens: `Elevation`, `tintedFill/Stroke`, `raisedSurface`, `eyebrow`, `denseLabel`, radius 16, spacing rename to the 8-pt-major scale, `IconTile` sizes | `Tokens.swift` (+new `Elevation.swift`) | S | Low |
| B2 | Hygiene tests for the metric layer (§3.2.8) with a temporary allowlist that shrinks per phase | `SourceHygieneTests.swift` | M | Low |
| B3 | Component consolidation: one `Chip` (subsuming 8 types + 26 inline capsules), one `SectionHeader` adoption pass (11 clones), `IconTile` (6 clones), `Avatar` (4 clones, one initials algorithm), card recipes → `raisedSurface`+`Elevation` | `ElephruitDesign/`, ~30 feature files | L | Med — visual diffs everywhere; gate with screenshot review via `DesignReviewLaunch` |
| B4 | Kill the 71 fixed font sizes → tokens (or deletion where <10 pt); the 12 ad-hoc animations → `calmAnimation`; the 9 shadows → `Elevation`; sub-28-pt hit targets to ≥28 | ~40 feature files | M–L | Low–Med |
| B5 | Contrast support: `colorSchemeContrast`/`differentiateWithoutColor` handling in `selectionFill`, `hoverFill`, chips, hairlines (resolve through one modifier) | `Tokens.swift`, `Components.swift` | S–M | Low |
| B6 | Retina brand assets (2×/3×), module symbol fixes | asset catalog | S | Low |

### 4.3 Phase C — Shell and navigation *(architectural — see §4.6.1 before committing)*

| # | Change | Files | Effort | Risk |
|---|---|---|---|---|
| C1 | Adopt `NavigationSplitView(sidebar:content:detail:)` + native `.inspector`; sidebar material restored; toolbar shim deleted; `ModuleShellLayout` demoted to supplying min/ideal via `navigationSplitViewColumnWidth`; user divider positions win (drop per-module ceilings) | `RootView.swift`, `SidebarView.swift`, `ModuleLayoutPolicy.swift`, `ModuleShellLayout.swift` (+~60 tests updated) | XL | **High** — this is the fight the repo lost twice; §4.6.1 defines the fallback and the exit criteria |
| C2 | One-level sidebar per §3.3.2 (sections, context section, bottom rail; Areas into the tree; counts) | `SidebarView.swift`, `SidebarModel.swift`, `AppModule.swift`, `ModuleSidebar.swift` (deleted), `RecordsModuleSidebar.swift` | L | Med — restoration compatibility for old `RestorationState` values (precedent exists: Home/Upcoming) |
| C3 | Empty-detail policy (§3.3.3): auto-select-recent in document modules; list-takes-window elsewhere | `RootView.swift`, `ModuleLayoutPolicy.swift`, `ItemListView.swift` | M | Low |
| C4 | Toolbar grammar (§3.3.4): module controls into the window toolbar; delete duplicate in-content bars (Time popups, Calendar overflow-sidebar, Calendar second header) | `TimeView.swift`, `TimeFilterBar.swift`, `CalendarWorkspaceView.swift`, `TodayToolbar.swift`, `ProjectWorkspaceView.swift` | M–L | Med |
| C5 | Keyboard platform pass: wire `TypeToSelectBuffer` into `List` surfaces; click-selects/Return-opens convention; `.defaultFocus` in sheets; focus-responsive `hoverHighlight` | list views, `Components.swift` | M | Med |

### 4.4 Phase D — Module redesigns (each independently shippable, order = user value)

| # | Screen | Per §3.4 | Files | Effort | Risk |
|---|---|---|---|---|---|
| D1 | Reminders + composer rebuild *(architectural — §4.6.2)* | 3.4.2 | `RemindersWorkspaceView.swift`, `ReminderComposer*.swift` (rewrite ~2,900→~800 lines), `ReminderStore.swift`, `ModuleLayoutPolicy.swift` | XL | High |
| D2 | Today | 3.4.1 | `Today*.swift` (9 files) | L | Med |
| D3 | Calendar | 3.4.4 | `Calendar*.swift`, `EventInspectorView.swift` | L | Med |
| D4 | People unification *(architectural — §4.6.3)* | 3.4.5 | `RecordsWorkspaceView.swift`, `PersonWorkspaceView.swift`, `PersonSheets.swift`, `PersonCaptureSheets.swift`, `RecordContextSidebar.swift` | XL | High |
| D5 | Notes (+ Format menu, in-editor find) | 3.4.3, 3.4.11 | `KindDetailViews.swift`, `NotePageView.swift`, `NoteWorkspacePanels.swift`, `ElephruitApp.swift` | M–L | Low–Med |
| D6 | Time consolidation | 3.4.6 | `Time*.swift`, `FloatingTimerView.swift`, `MiniTimerPanel.swift` | L | Med |
| D7 | Projects/Kanban (incl. keyboard moves + a11y) | 3.4.7 | `KanbanBoardView.swift`, `ProjectWorkspaceView.swift`, `ProjectOverviewView.swift` | M–L | Med |
| D8 | Search everywhere (full §3.4.8, replacing A2's interim) | 3.4.8 | `InlineSearchResults.swift`, `SearchSession.swift`, module views | L | Med |

### 4.5 Phase E — Polish and verification

| # | Change | Effort |
|---|---|---|
| E1 | Dark-mode screen review of every module via `DesignReviewLaunch` (both appearances × Increase Contrast), fixing composition (chip boundaries, separator visibility, elevation legibility) | M |
| E2 | Motion pass: transitions audited against Reduce Motion; the three sanctioned durations only | S–M |
| E3 | Multi-select + `BatchActionBar` on Today/Reminders/Records; swipe-action sets wired to the lists that declare them; context menus adopt `forSelectionType:` | M |
| E4 | Drag & drop: items → projects/sidebar, Today rows → dates, note → Finder (Transferable) | M–L |
| E5 | VoiceOver pass on the labeled-zero files (`RecordsWorkspaceView`, `WorkItemDetailView`, `MiniTimerPanel`, editors); `accessibilityFocused` after destructive actions | M |
| E6 | Empty-state recomposition on the new surfaces; first-run state for an empty library | S–M |

### 4.6 Architectural refactors, isolated for decision

These are the three items where visual goals require structural work. Each can be declined
independently; the plan degrades gracefully.

**4.6.1 The shell (C1).** *Recommended: rebuild on `NavigationSplitView`.* What changes: the
custom `HStack`, drag gesture, toolbar shim, and width solver leave the presentation path;
`ModuleShellLayout` survives as the policy source for minimums/ideals only. The honest risk:
this codebase already lost to AppKit's divider restoration twice — but both losses were in
service of *enforcing per-module ceilings*, a behavior no native Mac app has. The redesign
deliberately drops that requirement (user divider position wins, minimums enforced by content
frames — already proven to work in the first pass), which removes the losing battle rather
than re-fighting it. Exit criterion if it still fights: keep the custom shell and do the
**fallback native-ization** instead — `NSVisualEffectView` sidebar material behind the
existing column, `NSCursor` push + double-click-reset on the resize strip, a real draggable
list/detail divider, and deletion of the toolbar shim via `safeAreaInset` — M–L effort,
recovers ~70% of the native feel for ~30% of the cost. Decide after a 2-day C1 spike.

**4.6.2 `ReminderComposer` (D1).** The 2,203-line composer cannot be restyled into the §3.4.2
design; its five `NSPopover`s and custom focus router *are* its layout. Rebuild as: one
grammar parser (shared with capture — this also resolves diagnosis §2.3.2), SwiftUI-native
focus (`@FocusState` + `.defaultFocus`), popovers as `.popover` anchored chips. The rewrite
is smaller than the original because the grammar replaces most of the field-hopping.

**4.6.3 One person page (D4).** Merging `PersonWorkspaceView` into `RecordsWorkspaceView`'s
detail removes a whole parallel page, 5 of the 10 worst hardcoded-value files, and the
two-chromes problem in one move. Prerequisite for the People visual redesign, not separable
from it.

### 4.7 Suggested sequence and cumulative state

**A → B → C2+C3+C4 → D1 → D2 → C1-spike → C1-or-fallback → D3…D8 → E.** Rationale: A and B
are safe and immediately valuable; the sidebar/toolbar/empty-detail work (C2–C4) transforms
the screenshots *without* betting on the C1 fight; Reminders (D1) is the weakest surface and
the unification just made it the center of the product; the C1 spike is deferred until the
new sidebar exists so the split-view migration carries the final structure, not the old one.
After every phase the app builds warning-free, tests pass, and the phase's screens are
reviewed via `DesignReviewLaunch` in both appearances.

### 4.8 Open questions — decisions needed from you

1. **D1 — Shell bet (§4.6.1):** approve the `NavigationSplitView` spike, or go straight to
   the fallback native-ization?
2. **D2 — One grammar:** unify capture grammar across Quick Jot, the Reminders composer, and
   Today quick-add (recommended), accepting that `due:`/`!` tokens start working in the
   composer where today they stay literal?
3. **D3 — Accent:** keep the brand blue (current asset, my recommendation — predictable
   selection/link color against the 13-hue user palette) or follow the user's system accent
   (what `Tokens.swift` claims)?
4. **D4 — Overdue color:** one rule app-wide. My recommendation: amber date + "n days late"
   wording everywhere; red reserved for *due today and not done* — matches the app's own
   "red row is an accusation" argument. Alternative: red for all lateness (Today's current
   behavior).
5. **D5 — Naming:** sidebar says "People" while the module/kind system keeps "Records"
   internally — or rename nothing?
6. **D6 — Areas** into the Projects tree (recommended) or keep as a top-level module?
7. **D7 — Sidebar bottom rail:** Archive + Trash as fixed bottom rows (recommended) vs
   inside the Library section?
8. **D8 — Scope check:** the Alternative "Warm editorial" direction (§3.1.2) — reject
   entirely, or adopt its New York date-rail accent for Today/daily notes on top of the
   primary direction?
9. **D9 — First-run:** is a minimal first-launch state (sample-data offer + three-line
   orientation) in scope for Phase E, or out of scope entirely?
10. **D10 — Effort ceiling:** is XL work (C1, D1, D4 — roughly 6–8 engineer-weeks combined)
    acceptable this cycle, or should the plan re-cut to A+B+C2–C4+D2 (the maximum
    no-architecture path)?

---

*End of plan. Every numbered item above can be revised independently — reference by section
number (e.g. "revise 3.4.2", "answer D4: red").*

---

## 5. Implementation status — end of first execution session (2026-08-03)

Executed on `claude/macos-ui-ux-audit-5489c0`, 25 implementation commits, every commit leaving
the app building warning-free with all seven test targets green (~2,430 tests).

### 5.1 Shipped

- **Phase A complete** (A0–A8), plus two finds beyond the plan: six pre-existing test failures
  from the unification merges repaired, and the features test host's segfault (an NSWindow
  over-release in two tests) fixed — it had been eating the target's summary since before this
  branch.
- **Phase B complete except B4's residual sweep** (B1 tokens, B2 metric-ledger hygiene tests
  with a self-checking shrink-only allowlist, B3 components + the whole Person cluster
  converged, B5 contrast-adaptive tints, B6 assets/symbols).
- **Phase C complete except C1** (C2 one-level sidebar with the Records browser moved into its
  workspace, C3 empty-detail policy + auto-select-recent, C4 toolbar grammar for Calendar and
  Today, C5 type-to-select + focus-aware hover + declarative palette focus).
- **Phase D complete** (D1 Reminders rebuild — sectioned List, grammar composer, detail pane,
  2,203-line composer deleted; D2 Today any-date reschedule + one grammar; D3 event-block
  presence + group briefs; D4 verified-already-unified + Open Threads promoted onto the page;
  D5 Format menu + ⌘F find-in-note flip; D6 ⌘8 + selection-aware ⌃⌘T; D7 kanban keyboard +
  VoiceOver; D8 delivered via A2/A3/D1).
- **Phase E: E2, E3 (Reminders multi-select), E4 (rows drag onto projects), E5, E6 shipped.**

### 5.2 Remaining, in recommended order

1. **C1 — the shell spike** (§4.6.1). Untouched by design: an XL, high-risk refactor gated on
   its own decision, wrong to start at the tail of a long session. The fallback
   (native-ize the custom shell) remains fully specified.
2. **E1 — dark mode + Increase Contrast screen review.** Requires driving the app on a quiet
   machine; the fixture launch arguments and capture method are proven (see the C2/C3/D1
   screenshots in this session).
3. **B4 residual** — the ledger files not cleared by rewrites (fonts ~20 files, paddings ~13,
   radii ~10, shadows ~6). Mechanical; the hygiene tests enumerate every site and refuse
   regressions meanwhile.
4. Deferred small items, folded into the above: swipe-action sets on their declared lists,
   `forSelectionType:` context menus, the project tab-bar-to-toolbar move, module-scoped
   search default.
