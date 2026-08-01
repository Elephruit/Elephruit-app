# 31 — Tasks interaction scope

The task **model** is finished and right. This is a plan for the shell around it.

`TaskSystemView` already declares Inbox, Today, Upcoming, Anytime, Someday and Logbook.
`TaskScheduling.swift` already separates start, deadline and reminder, and already lets only the
deadline make anything overdue. `TaskChecklist`, `ItemKind.heading`, areas ▸ projects ▸ headings ▸
tasks, `isLaterToday`, `isSomeday`, recurrence-as-a-new-row — all of it exists, is tested, and is
argued in `docs/25-tasks-module-record.md`. **Nothing in this document changes the schema.**
`CurrentSchema` stays at 0.0.10.

What is wrong is everything between the model and the hand.

| What the module should be | What it is today |
|---|---|
| A row that expands **in place** into an editable card | A right-hand detail column (`TaskDetailView` + `TaskDetailPanels`) |
| Four small buttons on that card, each opening a focused popover | `OptionalDateRow` → `DatePicker(.compact)` form rows |
| A **bottom** bar whose contents change with what is selected | A top window toolbar with two buttons |
| A flat sidebar: Inbox ‖ Today, Upcoming, Anytime, Someday ‖ Logbook, Trash ‖ lists | Four rows plus a "More" disclosure hiding five more |
| Row metadata as small trailing glyphs | A second metadata line under every title |
| Section header: container glyph, bold title, hairline rule | `SectionHeader` inside a standard inset `List` |

Doing this also closes three open items in `docs/redesign/README.md`: **#8** (three different row
layouts for the same items), **#9** (two vocabularies for dates on screen at once), **#12** (two
disclosure affordances thirty points apart in the Tasks sidebar).

---

## The decision this rests on

**The editor is the row.** Not a column beside the row, not a sheet over it, not a popover anchored
to it. Clicking into a task makes that list row taller and puts the fields inside it; the rows above
hold still and the rows below shift down. Nothing else on screen moves, nothing else is covered, and
the task never leaves the context that explains it.

Three consequences follow, and they are the whole plan:

1. **The right-hand column for tasks stops existing** (§6). Two places to edit one task is how "Start"
   and "Defer until" ended up on screen together.
2. **Fields the task does not have are buttons; fields it has are values.** A button is present only
   while its value is absent. Setting a deadline replaces the Deadline button with a deadline chip.
   This keeps an empty task to one line of small controls instead of six empty form rows, and it is
   testable — see §Verification.
3. **The window toolbar cannot hold the actions**, because the actions now depend on whether a card
   is open. They move to a bottom bar (§4) that already has a slot: the one `TaskBatchBar` occupies.

## What we keep that the shape usually costs

`List(selection:)` stays. A card is a taller list row, and `List` is what gives us multi-select,
arrow-key navigation, `onMove` reordering, `.onDeleteCommand` and `rowSwipeActions` for free.
Rebuilding that on a `LazyVStack` would spend all of it for no visual gain. The list loses its
chrome, not its behaviour: `.listRowSeparator(.hidden)`, `.listRowBackground(Color.clear)`,
`.alternatingRowBackgrounds(.disabled)`, a centred max-width column, and our own selection fill.

The row-swaps-for-an-editor pattern is already in the codebase and is the thing to lift, not invent:
`TimeEntryGroupRow` (`ElephruitFeatures/TimeEntryEditing.swift:131`) is a `Group { if isEditing {
TimeEntryEditor(…) } else { summary } }`. `TaskRow` gets the same shape.

---

## Work, in the order it should land

Each numbered item is one commit, and each one leaves the app usable.

### 1. Flatten the Tasks sidebar

`ElephruitFeatures/TasksSidebarSection.swift`

Drop the `More` disclosure (`isMoreExpanded`, line 26). Groups, in order:

**Inbox** ‖ **Today, Upcoming, Anytime, Someday** ‖ **Logbook, Trash** ‖ *areas and projects*
(unheaded — the tree explains itself) ‖ *Smart Lists*.

`.flagged`, `.waiting` and `.all` leave `TaskSystemView`'s sidebar rows and become smart lists, which
is what they already are: `BuiltInSmartList.all` (`ElephruitCore/TaskFilter.swift`) carries thirteen
of these. Trash gets a row here even though `AppModule.trash` exists; the module row stays. Two ways
in is fine when one of them is the module and the other is the list — what #12 objected to was two
*disclosure* affordances, and after this there is one.

`ElephruitFeatures/SidebarView.swift` — add a **New List** footer beside the existing `statusLine`
safe-area inset: a `+ New List` button opening a menu of *New Project* / *New Area*, each with a
one-line explanation of which is which.

### 2. The popovers, wired into the existing detail panels first

New: `ElephruitFeatures/TaskPopovers.swift`

- `TaskDatePopover` — the shared shell plus a mini-month grid. Lift the grid from the
  `LazyVGrid(GridItem(.fixed(20)) × 7)` at `CalendarMenuBar.swift:292`, which already handles leading
  blanks and the today ring and already has a public init.
- `WhenPopover` — Today · This Evening · month grid · Someday · *Add Reminder*, mapping onto
  `TaskService.commitToToday` / `moveToLaterToday` / `setStartDate` / `setSomeday` / `setReminder`.
- `DeadlinePopover` — month grid → `TaskService.setDeadline`.
- **Both date popovers open under a type-ahead field**, not a button: clicking When turns the button
  into a text field with a grey placeholder and opens the popover below it. Typing `next tue` filters
  the popover to one row reading `Tue, Aug 4 · in 3 days`. An `✕` clears the field. The parsing is the
  **existing** `TaskEntryParser` (`ElephruitCore/TaskEntryParser.swift`, 822 lines) — it already
  handles `next tue`, `by August 15`, `every Friday`. Reusing it is the point: it is what makes the
  card and quick entry agree about what a date phrase means, instead of two grammars drifting.
- `TaskTagPopover`, `TaskMovePopover`, `TaskPeoplePopover` — **promote**, do not copy, the shapes
  already written for Time in `ElephruitFeatures/TimePickers.swift`: `TimeTagPicker:456` (filter
  field, checkbox rows, "Create *x*" pinned at the bottom, `TextNormalizer.slug`),
  `TimeProjectPicker:148` with `ProjectChoice:293`, `TimePeoplePicker:361`, and the currently
  **private** `ItemSearchPopover:602`, which needs making internal.

Land all of these against the existing `TaskDetailPanels` rows, so every one is exercised before the
card exists to hold it. This is what makes §3 a layout change rather than a rewrite.

### 3. The card

New: `ElephruitFeatures/TaskCard.swift`. `TaskRow` gains `isEditing`; `TaskWorkspaceView` gains
`@State editingTaskID: UUID?`.

Top to bottom: completion control and title `TextField` · notes (`NotesField`) · checklist rows with
the per-step lifecycle already in `TaskDetailPanels.checklist`, *Make This a Subtask* included ·
chips for what is set · a trailing row of buttons for what is not.

Six buttons, and the rule from §Decision governs all six: **When · Tags · Checklist · Deadline**,
plus the two that a purist task manager refuses and we do not — **People** and **Priority**. People
uses the existing `mentions` / `participant` / `waitingOn` link kinds; priority is an existing column.
No schema change for either.

The card draws a surface fill, a hairline border and a soft shadow, inset from the column edges, so
it reads as one object lifted out of the list rather than a region of it.

Opening: click an already-selected row, Return on the selection, or double-click. Closing: Escape, or
clicking another row. Writes go through `TaskService` on the same debounce discipline
`ItemDetailView` already uses — `PendingSave`, flushed on `willTerminate`, `didResignActive` and item
change. `TaskDetailPanels`' `syncNotice` and `reviewNotice` move to the bottom of the card unchanged;
they are one quiet line each already.

**Open decision — *Add Reminder*.** `docs/25-tasks-module-record.md` item 1 records that no
`UNNotificationRequest` is ever scheduled: the app holds no notification entitlement. A prominent
"Add Reminder" that never interrupts is exactly the half-built affordance that record warns against.
Either

- **(a)** include it, and have the resulting chip say plainly that the time is *shown*, not
  *delivered*; or
- **(b)** leave it off the popover until a scheduler lands.

**Recommend (a).** The field is already on the model and already renders on the row. Hiding it in the
one place a person would go looking for it is worse than being honest about what it does. Decide
before this commit ships, because the chip's wording is part of it.

### 4. The bottom bar

New: `ElephruitFeatures/TaskBottomBar.swift`. Reuse `ActionItem`
(`ElephruitDesign/ActionItem.swift:15`) and `AdaptiveActionBar`
(`ElephruitDesign/AdaptiveActionBar.swift:72`) — they were built for this and already rank and
collapse under width pressure.

It replaces `toolbarContent` (`TaskWorkspaceView.swift:379`) and takes the
`safeAreaInset(edge: .bottom)` slot at line 85, so `TaskBatchBar` **folds into it** as the
multi-selection state instead of competing with it for the same strip.

| State | Actions |
|---|---|
| List | `+` New Task · `⊞` New Heading (projects only) · `📅` When · `→` Move · `🔍` Find |
| Card open | `→` Move · `🗑` Trash · `⋯` More (Repeat… · Duplicate · Convert to Project… · Share) |
| Multi-selection | Today's `TaskBatchBar` actions — Complete · Today · Flag · Someday · Clear |

The bar is centred on the content column, not the window, so it stays under the thing it acts on.

*Convert to Project* is the one genuinely new behaviour here: a task with subtasks becomes an
`ItemKind.project` and its subtasks become its tasks. `ItemKind.canContain` already permits the
shape. Needs `TaskService.convertToProject(_:)` and a test that nothing is orphaned.

### 5. Row and list restyle

`TaskRow.swift`, `TaskWorkspaceView.swift`, `TodayRows.swift`.

- Metadata moves from a second line to **one trailing line**, keeping the existing rule verbatim —
  only what is currently true, nothing rendered as empty. Date first (coloured only once it has
  arrived), then `TagChip`s, then glyphs for notes, checklist and repeat. Glyphs, not words: no
  container name, no second line.
- Section headers become container glyph (a progress ring for a project, the area's icon for an area)
  + bold title + a hairline rule spanning the remaining width.
- Container sections truncate to five rows with a grey **"Show N more"**.
- The list gets a centred column at `Theme.Size.editorMaxWidth` (720), no separators, no alternating
  backgrounds, clear row backgrounds, and our own fill from `Theme.Colors.selection` +
  `hoverHighlight` (`ElephruitDesign/Components.swift:452`).
- Upcoming's day headers become a large day number beside the weekday name, rules between days, and
  empty days still drawn — an empty Thursday is information.

`TodayTaskRow` (`TodayRows.swift:379`) gets the same row, which is where redesign issue **#8** dies:
Today and Tasks stop drawing one object two ways.

### 6. Retire the task detail column

`ElephruitFeatures/KindDetailViews.swift`, `ItemDetailView.swift`; delete `TaskDetailPanels.swift`.

`ItemDetailView.surface(for:)` (`ItemDetailView.swift:92`) stops routing `.task` to `TaskDetailView`
(line 106). Selecting a task from anywhere — a backlink, a person's page, a search result,
`navigation.selectItem(id:)` — navigates to the list the task lives in and opens its card. Following
a link to a task should land you where the task lives, not in a detached copy of it.

Backlinks ("Linked from") and subtasks, currently only in `TaskDetailView`, move onto the card below
the checklist.

This is also where redesign issue **#9** dies: `InspectorView`'s "Due" and "Defer until"
(`InspectorView.swift:204,207`) go with the panel, leaving one vocabulary on screen — **Start,
Deadline, Reminder** — which is the vocabulary the model actually uses.

### 7. Draggable new-task control *(optional — drop this if the rest is running late)*

The `+` in the bottom bar becomes draggable: dropped between two rows it creates a task at that
position, dropped on a heading it files it there. `TaskDragPayload`
(`TaskSupportingViews.swift:220`) and the `dropDestination` plumbing at line 55 already exist to
build on.

---

## Verification

```bash
swift test --package-path Packages/ElephruitKit
```

Suites that must stay green: `TaskFeatureTests`, `TaskServiceTests` (790 lines),
`RowSwipeActionTests`, `HeadingTests`, `TrashAndQueryTests`, `TaskBenchmarks`.

New tests:

- **Button visibility.** For each of the six, the button is shown **iff** its value is absent. This is
  the §Decision rule, so it gets a test rather than a convention.
- **When never sets a deadline.** Today → `commitToToday`, This Evening → `moveToLaterToday`, a grid
  date → `setStartDate`, Someday → `setSomeday`, and *never* `setDeadline`. The whole overdue model
  rests on these being different fields; a mis-wired popover would quietly undo it.
- **One grammar.** The type-ahead field and quick entry resolve the same phrase to the same date,
  asserted through `TaskEntryParser`.
- **`convertToProject`** moves subtasks and leaves nothing orphaned.
- **Sidebar composition** — the flattened order, and that `.flagged` / `.waiting` / `.all` are still
  reachable as smart lists.

Then against synthetic data, with nothing real touched:

```bash
open -n "$(xcodebuild -project Elephruit.xcodeproj -scheme Elephruit -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}' | head -1)/Elephruit.app" --args -ElephruitDevelopmentMode -ElephruitUseTemporaryStore
```

**Settings ▸ Advanced ▸ Load Sample Data**, then walk Today, Upcoming, Anytime, a project and the
Inbox: open a card, set a date from the grid and again from the type-ahead, add a tag, add a person,
add a step, move a task, multi-select, and undo each one. Screenshot each into `docs/redesign/`
beside the existing `tasks.png`, `today.png`, `upcoming.png` and `projects.png` so there is a
before/after pair.

## Documentation to amend when this lands

- `docs/25-tasks-module-record.md` — the interaction-model section becomes wrong the moment §3 ships.
  Items 1 (notifications) and 4 (calendar in Today and Upcoming) need restating in the light of
  whatever is decided about *Add Reminder*.
- `docs/redesign/README.md` — strike **#8**, **#9** and **#12**, one line each on how they went.
