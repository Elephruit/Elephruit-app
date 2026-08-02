# Projects workspace — reconstruction notes

The Projects redesign was built in a worktree that was deleted before it merged. The commits are
unrecoverable: `git fsck` reports no unreachable objects, nothing is in the Trash, and the worktree's
admin directory went with it. This is what it contained and why, written so it can be rebuilt without
re-deriving the decisions.

The original implementation plan survived outside the repo and is committed alongside this file as
[32a-projects-workspace-original-plan.md](32a-projects-workspace-original-plan.md) — it holds the
pre-build design and phase order. This document is the *post*-build record: what was actually built, plus everything real use taught us
afterwards, which is the part the plan could not contain.

Roughly 15,000 lines across nine commits. Order of rebuild is the phase order at the end.

---

## 1. The problem it solved

`AppModule.projects` mapped to a flat `.kind(.project)` list, and opening a project landed in a
416-line `ProjectDetailView` — a brief, tasks under headings, three collapsed link sections. One way
to look at a project, no board, no assignee, no bug, no plan.

Two behaviours were also plainly broken and are worth fixing even if nothing else is rebuilt:

1. **`>Project` on a note failed outright.** `CaptureService.capture(_:)` set `itemDraft.parentID`
   for *any* kind, and `ItemValidator` then rejected the whole capture because
   `ItemKind.project.canContain(.note)` is false. Tagging a jot to a project filed **nothing**.
2. **`#bug` was only a tag.** Nothing turned it into a tracked defect.

---

## 2. The load-bearing decisions

Rebuild these first; everything else follows from them.

### Two state axes, kept apart

`ItemStatus` stays the lifecycle (`open`/`completed`/`cancelled`). It is what Today, every count,
`taskProgress()` and the Logbook read. A board's columns are a **second**, per-project, user-named
axis (`WorkflowStage`), joined to the first by `WorkflowStageCategory`
(`backlog`/`active`/`done`/`cancelled`).

- Dropping into a **terminal** category writes the status.
- Moving between two **open** categories writes *nothing at all* — both mean open, and writing it
  anyway stamps `updatedAt` on every drag.
- Dragging finished work back onto an open column **reopens** it, or the board disagrees with itself.

If the columns *were* the status, adding a column called "Blocked" would change what "open" means
everywhere in the app.

### `isWorkItem`, not `kind == .task`

`ItemKind` gains `.bug`, `.feature`, `.milestone`, `.release`. This costs **no migration** —
`kindRaw` has been a `String` since v1 for exactly this reason.

What it does cost is a sweep: **fifteen production sites** asked `kind == .task`. Under that
arrangement a bug is something that looks like work on a board and is invisible to every count, every
progress figure, and Today. Add:

```swift
extension ItemKind {
    var isWorkItem: Bool { self == .task || self == .bug || self == .feature }
    static let workItemKinds: [ItemKind]        // ordered, for pickers
    static let workItemKindSet: Set<ItemKind>   // for ItemQuery.kinds
    static let planningMarkerKinds: [ItemKind] = [.milestone, .release]
}
```

Then replace `kind == .task` with `kind.isWorkItem` in: `Item.descendantTasks`,
`Item.ungroupedTasks`, `Item.taskFacts` (`hasSubtasks`), `Item.isTaskLike`, `ItemRepository` (×4),
`TaskService` (×2), `TaskViewService` (`query.kinds`, ×4), `PeopleService`,
`PersonWorkspaceService`, `PersonTimeline`, and two view sites.

A **milestone has a status** — it is reached or not — but does **not** count as work, because
reaching it is the consequence of the work rather than a unit of it. So `countsAsWork` becomes
`isWorkItem` rather than `supportsStatus`.

Also add `Item.descendantWork()` alongside `descendantTasks()`: the latter stops at a container
boundary (right — a project's progress is its own work), but an **area** asking "is anything under me
late?" has to descend, because being the level you check is the entire purpose of an area.

### One arrangement, seven views

`WorkItemArrangement` (in `ElephruitCore`, pure) filters → groups → sorts **within** groups. Every
view runs on it. Written per view they drift, and the drift is always the same: unassigned sorts to
the top on the board and the bottom in the table, "no milestone" is a group in one and a gap in
another. The whole promise of a project workspace is that every view shows the same work.

Non-obvious rules it encodes:

- **Empty board columns are drawn; empty priority bands are not.** A column with nothing in it is
  somewhere to *drop* something — it is the column you were reaching for. A heading over a void is
  not.
- **Unassigned sorts first; "no milestone" sorts last.** Work nobody has taken is the most important
  group on a board grouped by person; a milestone residue is not a queue.
- **No deadline sorts last whichever way the arrow points.** "No date" is not a very late date.
- **`ELE-9` before `ELE-10`** — parse the number, don't string-sort.
- **A subtask whose parent is on screen gets no row of its own; one whose parent is filtered out
  keeps its row.** Otherwise filtering to "assigned to me" hides my subtask because somebody else
  owns its parent.
- **Group keys are stable and derived from what the group *is*** (`"stage.<uuid>"`,
  `"severity.major"`), so a collapsed group stays collapsed across a refresh.

### Projects is not a module you enter

A module is something you *enter*, which replaces the sidebar with its own navigation. A project is
something you *open*, and there are a dozen of them. Putting the tree behind a row called "Projects"
put the user's own structure one level further away than the Trash — and once inside, the list you
move between projects with had been swapped out.

So: the tree lives at the **top of the primary sidebar**, `AppModule.displayOrder` drops `.projects`,
and `AppModule.projects` gains `hasOwnSidebar == false`. The case stays for the shell layout and for
`module(for:)`. `SidebarView` checks `module.hasOwnSidebar` before swapping levels.

### Projects is a canvas module, and detail is a sheet

`ModuleLayoutPolicy` gives `.projects` `detail: .unavailable` and a wide primary
(`min 560, ideal 1100`), alongside Calendar and Time. A board of six columns does not fit in the
340pt a list gets.

**The work item opens in a sheet, not a drawer.** This was built as an inspector drawer first, on the
brief's "avoid excessive modals" line — and that line was explicitly withdrawn after use. A work item
is nine sections wide, none of it reads in a 440pt column, and the column came out of the board's
width, so the board paid for a pane that was still too narrow. A sheet has room for two columns
(prose left, fields right), which is what every issue tracker converges on.

Selecting and opening are **separate**: a click selects (keeping multi-select, drag and the bulk bar
working); a double-click, Return, or **Open** presents. One identifier serving both means every click
throws a sheet over the board.

---

## 3. Schema — `SchemaV11` (`0.0.11`)

> The lost work built this as `SchemaV10`. `main` has since shipped its own `SchemaV10` (the
> Reminders-home column), so the rebuild is **V11**. If you are reading this against a later `main`,
> check `CurrentSchema` and take the next number — the version literal is pinned by
> `SchemaComplianceTests` and `EstimateMigrationTests`, so a stale number fails loudly rather than
> silently.


Additive throughout: eight entities, nine nullable/defaulted columns, no rename, no type change — so
[ADR 0005](adr/0005-schema-freeze-before-the-next-stage.md)'s trigger for freezing model types is
still not met. Bump the version so `PersistenceStack` takes its backup.

Two tests pin the version literal (`SchemaComplianceTests`, `EstimateMigrationTests`) — update both.

### New entities (`ElephruitModel/ProjectRecords.swift`)

| Entity | Fields |
|---|---|
| `WorkflowStage` | `name`, `categoryRaw`, `colorName`, `sortOrder`, `wipLimit: Int` (0 = none), `project: Item?` |
| `ProjectViewRecord` | `name`, `kindRaw`, `configurationData: Data`, `sortOrder`, `symbolName`, `project: Item?` |
| `BugRecord` | `severityRaw`, `stepsToReproduce`, `expectedBehavior`, `actualBehavior`, `environment`, `affectedVersion`, `fixVersion`, `isRegression`, `verifiedAt: Date?`, `item: Item?` |
| `ItemComment` | `body`, `createdAt`, `updatedAt`, `authorID: UUID?`, `mentionedPersonIDsData`, `item: Item?` |
| `ItemActivity` | `at`, `kindRaw`, `field`, `oldValue`, `newValue`, `actorID`, `automationRuleID`, `item: Item?` |
| `AutomationRule` | `name`, `isEnabled`, `definitionData: Data`, `sortOrder`, `lastFiredAt`, `fireCount`, `lastFailureReason`, `project: Item?` |
| `CustomFieldDefinition` | `name`, `typeRaw`, `optionsData`, `sortOrder`, `isProminent`, `project: Item?` |
| `InboxNotification` | `at`, `kindRaw`, `isRead`, `summary`, `actorID`, `automationRuleID`, `item: Item?` |

All CloudKit-compliant as the project has been since v1: every attribute defaulted, no unique
constraints, every to-one optional, every pair declaring an inverse, no `.deny`.

Two decisions worth repeating:

- **`ItemActivity` stores display strings, not identifiers.** That makes history unqueryable and
  makes it *permanent*: "moved from In Review to Done" still reads correctly after the stage has been
  renamed and after it has been deleted, which is exactly when somebody looks.
- **Custom fields add no storage.** The definition names and types a key; values live in
  `Item.userMetadata`, which has been in the schema since v1. Renaming a field therefore has to
  **move the values** — a rename touching only the definition orphans every value under a name
  nothing looks for.

### New `Item` columns

`referenceKey: String?` · `projectKey: String?` · `nextReferenceNumber: Int = 1` ·
`workflowStageID: UUID?` · `boardOrder: Double = 0` · `goalTargetValue`/`goalCurrentValue: Double?` ·
`goalUnit: String?` · `releaseVersion: String?`

Plus cascade inverses: `bugRecord`, `workflowStages`, `projectViews`, `customFieldDefinitions`,
`automationRules`, `comments`, `activities`, `notifications`.

`activities` cascades (unlike `timeEntries`, which nullifies) because "moved to Done" about an item
that no longer exists is history with nothing to be history of, whereas four hours worked is a fact
about the past somebody may still need to bill for.

### New `LinkKind` cases

`.assignee`, `.duplicateOf`, `.targetsMilestone`, `.relatesToRelease`. Only `.duplicateOf` appears in
backlinks; the other three are drawn where they matter. **One assignee** is enforced in the service,
not the schema.

### `ItemValidator`

Add: only a bug carries a `bugRecord`; only a project a `projectKey`; only a release a
`releaseVersion`; only work a `workflowStageID`; only a goal the goal values. `conform(_:to:)` clears
each and *reports* the loss — turning a bug into a task drops the report, and the caller says so.

Note: converting a bug → task **keeps** the board column (still the same work in the same column);
converting to a note clears it.

### `refreshSearchText`

Fold in `referenceKey` and `bugRecord.searchableText`. Reproduction steps are what people search for
— "the crash when the list is empty" is in the steps, not the title.

---

## 4. Core value types (`ElephruitCore`)

- **`ProjectWorkspace.swift`** — `WorkflowStageCategory`, `WorkflowStageFacts`, `ProjectViewKind`
  (7 cases, each with `symbolName`, `hint`, and a `colorName`), `WorkItemGrouping`,
  `WorkItemSortField`, `WorkItemField`, `ProjectViewConfiguration` (JSON, with
  `default(for:)` per kind).
- **`BugTracking.swift`** — `BugSeverity` (critical/major/minor/cosmetic, `Comparable`, `colorName`
  with **cosmetic = nil**), `BugFacts` with `hasDetail` and `missingFieldNames`.
- **`WorkItemArrangement.swift`** — the filter/group/sort engine described above.
- **`WorkItemReference.swift`** — `ELE-42` formatting, parsing, key normalisation, `suggestedKey`,
  `uniqueKey(from:taken:)`.
- **`Automation.swift`** — `AutomationTrigger`, `AutomationAction`, `AutomationDefinition`,
  `IntegrationTarget`, `AutomationOutcome`. Unknown cases decode to `.unrecognised` and the rule is
  **not runnable**, whole.
- **`ProjectActivity.swift`** — `ActivityKind` (with `sentence(from:to:)`), `NotificationKind` (with
  `demandsAction`), `CustomFieldType`.
- **`ProjectReporting.swift`** — `ProjectHealth` (+ `concerns`), `VelocityPoint`, `CycleTimeSummary`
  (median *and* mean, `isMeaningful` at ≥5 samples, `hasLongTail`), `WorkloadEntry`,
  `ReportingPeriod`.
- **`ProjectTemplate.swift`** — blank, software, product launch, marketing, personal, general.

### Reuse `TaskFilter`, do not build a second engine

Extend `TaskFacts` with: `kind`, `referenceKey`, `workflowStageID`, `stageCategory`, `boardOrder`,
`assigneeID`, `milestoneID`, `releaseID`, `blockedByIDs`, `blocksIDs`, `isBlocked`, `severity`,
`isRegression`, `estimateMinutes`, `trackedMinutes`, `commentCount`, `customFields` — all defaulted,
so nothing existing breaks.

Extend `TaskRule` with: `.kind`, `.workflowStage`, `.stageCategory`, `.assignee`, `.unassigned`,
`.blocked`, `.milestone`, `.release`, `.severity`, `.regression`, `.hasEstimate`, `.overEstimate`,
`.customField`. **`TaskRule` has hand-written `Codable`** — update `discriminator`, `encode`, and
`init(from:)` for every new case.

A board, a table, a bug list and a smart list all ask the same question of the same facts. Two
engines are two sets of the same bug — and it means "every critical bug across the library" is a
smart list somebody can build.

**`.severity` must not match items with no severity**, or a rule asking for critical bugs sweeps in
every task in the project.

---

## 5. Services (`ElephruitPersistence`)

Seven, each knowing one thing. Wire them into `AppServices` in dependency order and add
`projectSidebar.refresh()` to `refreshDerivedState()`.

- **`ProjectWorkspaceService`** — stages, views, custom fields, project keys, `ensureWorkspace`,
  and `move(_:to:after:before:)`, which is where the two axes meet.
- **`WorkItemService`** — `createWorkItem` (reference key + board placement + history in one call),
  `assign`, dependencies with a **cycle guard**, `markDuplicate`, field setters that write history,
  comments, `bulk`.
- **`BugService`** — `record(for:)` (lazy), `fileBug`, `update`, `setSeverity`, `markVerified` /
  `clearVerification`, `awaitingVerification`, `openBugs`, `duplicates`, `rolloverUnresolvedBugs`.
- **`ProjectTemplateService`** — `createProject(named:from:in:key:)`, `apply`.
- **`AutomationEngine`** — `handle(_:on:)`, `runScheduledRules`.
- **`ProjectReportingService`** — health, velocity, cycle time, workload, burndown, goal progress.
- **`InboxService`** — `post` (deduplicated while unread), `unread`, `badgeCount`, marking read.

Behaviours that are not obvious and were deliberate:

- A **WIP limit is reported, never enforced.** A board that refuses a drop does not reduce work in
  progress; it moves it somewhere the board cannot see.
- **Reference numbers only go up**, including across deletions. A gap is the record of something
  deleted. A reference in a March commit must not start pointing at something else.
- **Removing a column asks where the work goes**, and `nil` *unplaces* rather than strands.
- **Automations cannot re-enter** — one pass per event, guarded by a flag. "When it moves to Done,
  tag it verified" plus "when tagged verified, move it to Done" is a loop somebody writes in thirty
  seconds.
- **Applying a rule to existing work is a named, separate action** ("Run Now on Everything").
- **Fixed and verified are separate facts.** `verifiedAt` is not part of `BugFacts`.
- **A duplicate is cancelled, not completed.** It was never fixed.
- **Reporting is honest about not knowing**: `completionFraction` is `nil` on an empty project,
  cycle time reports its sample size, workload reports `unestimatedCount`.

---

## 6. Views (`ElephruitFeatures`)

`ProjectsSidebarModel` + `ProjectsSidebarSection` · `ProjectWorkspaceModel` +
`ProjectWorkspaceView` (header, tab bar) · `ProjectFilterBar` · `KanbanBoardView` ·
`WorkItemListView` (+ `WorkItemGroupHeader`, `WorkItemRowView`) · `WorkItemTableView` ·
`BugTrackerView` · `ProjectCalendarView` · `ProjectTimelineView` · `ProjectOverviewView` ·
`ProjectAutomationsView` · `ProjectInboxView` · `WorkItemDetailView` (the sheet) ·
`WorkItemMenu` · `BulkActionBar` · `WorkItemSelection` · `WorkItemTitleField` ·
`ProjectSampleData`. Plus `ElephruitDesign/WorkItemViews.swift` for the shared chrome.

`SidebarSelection` gains `.project(id:viewID:)` and `.projectInbox`; `NavigationModel` gains
`projectWorkspace`.

Design rules that took feedback to arrive at:

- **Sidebar indicators are absent, not empty.** A quiet project is a name and a glyph. An overdue dot
  and an unread count only when non-zero. **No progress ring** — a partial arc beside a name is a
  mark people notice and cannot read; the figure belongs on the project header in words.
- **An area answers for everything beneath it** (`descendantWork`), or it reads as calm while a
  project inside it is three weeks late.
- **Every project ships all seven views.** A view holds no work, so an unused tab costs a word of
  width and a missing one costs finding the add menu. Templates decide the **order**, not what
  exists.
- **Tabs are coloured per kind** (overview purple, board blue, list teal, table indigo, bugs red,
  calendar orange, timeline green) — the same reason People colours phone vs email.
- **Nothing stops at the boundary of what is scheduled.** The calendar shows undated work in a band;
  the roadmap shows work aimed at nothing; grouping shows the unplaced pile.
- **Search and filter are two controls.** A filter belongs to the view and is saved; a search is
  transient and must not be. "Save as a New View" folds the search in as a rule.
- **Bulk actions get a bar, not the context menu** — a menu cannot show the count of what it is about
  to change, and it reports "14 of 20 changed" when some refuse.
- **Section headers align with their rows.** The chevron hangs in the *gutter* (`overlay(.leading)`),
  and the header's glyph shares the rows' `Theme.Size.rowGlyph` column.
- **A row's severity comes from the group it is in**, not from the item, so a heading and its rows
  cannot disagree.

---

## 7. Capture (`#bug` and `>Project`)

- `CaptureKindWords` in `TagConventions.swift`: `bug`, `feature`, `task`, `milestone`, `release` set
  `draft.kind` instead of becoming tags. `#bugs` and `#bug-triage` are untouched. `CaptureToken.Kind`
  gains `.kind`; `CaptureHighlight` says "Type bug".
- `CaptureService`: resolve the container **once**, set `parentID` when `canContain`, otherwise
  `fileItem(under:)`. Create the `BugRecord` for any `.bug` **before** the project is considered, so
  an Inbox bug still has somewhere to write reproduction steps.
- `placeInProject`: reference key + first non-terminal column.
- `CaptureVocabulary.matches(for:in:)` — prefix-then-contains over the in-memory vocabulary. **Do not
  route `>` completion through the search index**: it awaits an actor that may be warming the whole
  library, and it asked for the top twelve titles of any kind then filtered to three, so a project
  ranked thirteenth never appeared.

---

## 8. What real use found — the expensive knowledge

Eight faults, none of which a test would have predicted. This is the section worth reading twice.

1. **Keyboard shortcuts fired while typing.** `onKeyPress` is attached to the workspace (a shortcut
   bound to a row only fires while that row has focus, and a board's focus is on its scroll view) —
   so a space in a title marked the item complete *and never reached the field*, Delete trashed the
   selection, `[` moved the card. The giveaway was a bug titled "Can'tedit any bug details".
   **Fix:** `ProjectWorkspaceModel.isEditingText`, set by every field in the workspace, and every
   handler returns `.ignored` while it is true.

2. **The inspector could never open.** The shell decides whether the pane exists by asking
   `selectedItemID` and the calendar's event. A project's selection is neither, so the answer was
   always no and `hidesWhenNothingSelected` kept it shut — *nothing in a project could be edited*.
   **Fix:** `NavigationModel.projectWorkspace`. (Moot once detail became a sheet, but the lesson
   stands: a `@FocusedValue` reaches the pane's contents, not the decision that it exists.)

3. **Work could be created and never named.** The `+` made an item with an empty title, and the board
   card and bug row drew titles as plain `Text`. **Fix:** one `WorkItemTitleField` in all four views,
   and creation calls `beginRenaming`.

4. **The drawer's title could not be committed.** A vertical `TextField` treats Return as a newline,
   and its only other commit fired on `onChange(of: item.id)` — by which point you have moved on.

5. **A template rule fired on everything.** "Flag work that arrives critical" had no conditions, and
   an empty `TaskFilter` with `includesResolved` matches **all**. `AutomationSpec` needs a
   `conditions` field.

6. **No projects until you made one.** Nothing called `refreshDerivedState()` at launch. Everything
   the sidebar reads is computed on change and never during a render — but the *first* computation
   has to come from somewhere. **Fix:** call it in `RootView`'s launch task.

7. **Bugs filed under "Not a defect".** `BugRecord` is created lazily, and in the gap
   `TaskFacts.severity` read `nil`, so a bug fell out of every severity band. **Fix:** a `.bug` reads
   as `.minor` when its record has not caught up, and the group is renamed "Not a bug".

8. **A context menu whose actions silently did nothing.** `WorkItemMenu` was a separate `View` inside
   `.contextMenu`, which SwiftUI presents in its own hosting context — a custom `EnvironmentKey`
   defaulting to `nil` is not reliably inherited there. Every action read `services == nil` and
   returned early. **Fix:** pass `services` as a parameter. Also: `.onKeyPress(.delete)` is *forward*
   delete; the Mac Delete key sends a backspace.

Related trap, same family: a `contentShape(.rect)` + `onTapGesture` on a row that **contains
buttons** can swallow the button's action. Suspected cause of "I marked them Verified and they came
back" — never confirmed. See §10.

---

## 9. Tests

~120 new tests across five files. The ones that earned their keep:

- **`WorkItemModelTests`** / **`WorkItemArrangementTests`** (Core) — kind semantics, reference
  ordering, grouping totality ("grouping never loses or invents an item"), filter round-trips.
- **`ProjectSchemaTests`** / **`ProjectWorkspaceTests`** (Persistence) — cascades, the two axes, WIP
  advisory, field renames moving values, automation non-re-entry.
- **`ProjectWorkspaceJourneyTests`** / **`WorkItemEditingTests`** / **`ProjectFirstRunTests`**
  (Features) — every sample-data state exists, and each reported fault pinned.

**A test that only proves the column round-trips is not a test that the path works.** The
verification test was written twice for this reason: the first inserted a `BugRecord` and set
`verifiedAt` directly; the second goes through `BugService.markVerified` and re-reads through a fresh
context.

---

## 10. Known-remaining and deliberately-not-done

- **Never reviewed on screen in either appearance.** Screen access was declined throughout; all
  visual feedback came from the user's screenshots. What holds without looking is that no view names
  a literal colour (`SourceHygieneTests.coloursComeFromTheDesignSystem`).
- **"Marked Verified, came back after relaunch" — unresolved.** Two tests prove the service path
  persists, including for a bug with no record. The suspected cause is the row-level tap gesture
  swallowing the button (§8). A "Mark all checked" action on the band header was added as a path that
  does not depend on that diagnosis. **If it recurs, instrument rather than infer.**
- **No real integrations.** `IntegrationTarget` and `AutomationAction.external` are declared and
  refuse honestly.
- **CloudKit sync untested** for the new entities — compliant by construction, never exercised.
- **`PersonActionAvailabilityTests` "One number is named"** fails on `main` and is unrelated;
  confirmed by stashing.
- The progress ring still exists in the **Tasks** module's Areas & Projects list; it was only removed
  from the Projects sidebar.

---

## 11. Rebuild order

Each phase ends green (`swift build`, `swift test`, `xcodebuild` Debug) and is one commit.

1. **Model & schema** — `SchemaV11`, eight entities, `Item` columns, new kinds/link kinds, the
   `isWorkItem` sweep, `ItemFields`/`canContain`, migration test.
2. **Services** — the seven above, wired into `AppServices`.
3. **Sidebar** — `ProjectsSidebarModel`/`Section`, `SidebarSelection.project`, `displayOrder`.
4. **Workspace shell** — model, view, tab bar, canvas layout.
5. **Views** — arrangement first, then board, list, table, bugs, calendar, timeline, overview.
6. **Sheet, bulk actions, saved views, keyboard.**
7. **Planning & reporting.**
8. **Automations.**
9. **Capture** — `#bug` and `>Project`.
10. **Sample data, polish, docs.**

Phases 1–2 are the expensive, load-bearing half. If the rebuild is abandoned partway, stopping after
2 still leaves a coherent store and the two capture fixes are worth doing on their own.
