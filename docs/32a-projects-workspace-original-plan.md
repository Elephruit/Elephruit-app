# Projects as a first-class workspace

## Context

Projects today are the thinnest module in the app. `AppModule.projects` maps to a single flat
`.kind(.project)` list, and opening one lands in [ProjectDetailView.swift](Packages/ElephruitKit/Sources/ElephruitFeatures/ProjectDetailView.swift)
— a 416-line scroll of brief, tasks-under-headings, and three collapsed link sections. There is one
way to look at a project, no way to organise work beyond headings, no notion of a bug, no assignee,
no board, and no plan. The screenshot the brief opens with shows the whole of it: one project, two
tasks, and an inspector.

Almost every *primitive* the brief asks for is already in the store and unused by Projects:
`Item.estimateMinutes`, `TimeEntry`, `RecurrenceRule`, `TaskChecklist`, `Item.userMetadata`
(`[String: MetadataValue]`), `LinkKind.blockedBy`, `Tag`, `SavedSearch` (with a JSON `TaskFilter`
payload), and a full scheduling model in `TaskViewService`. What is missing is a *project* that can
hold them, ways to see them, and the item types that make a bug a bug.

Two behavioural bugs the brief names directly:

1. **Quick Jot `>Project` on a note fails.** `CaptureService.capture(_:)`
   ([CaptureService.swift:73](Packages/ElephruitKit/Sources/ElephruitPersistence/CaptureService.swift#L73))
   sets `itemDraft.parentID` for *any* kind, and `ItemValidator` then rejects it because
   `ItemKind.project.canContain(.note) == false`. Filing a note under a project is a `.filedUnder`
   **link**, which the project already reads back as "Project notes" — capture just never writes it.
2. **`#bug` is only a tag.** Nothing turns it into a tracked defect.

The outcome: a Projects experience that is its own workspace with configurable views over one
work-item model, built on the existing single-`Item` graph rather than beside it.

---

## Information architecture

**Sidebar (top level).** A permanent, collapsible **Projects** section joins the global band,
showing the real hierarchy — Area ▸ Project, favourites hoisted to a "Favourites" sub-band. Inline:
create, rename, favourite, reorder (drag), archive, and a context menu. Indicators are earned, not
decorated: a progress ring (existing `ProjectProgressDot`), a due/overdue dot, and an unread-count
badge only when non-zero. `AppModule.projects` leaves the *Modules* band — a project is a
destination, not a module — but the type stays for shell layout and `module(for:)` mapping.

**Workspace.** Selecting a project sets `SidebarSelection.project(id:viewID:)` and replaces the
middle column, exactly as `TaskWorkspaceView` and `CalendarWorkspaceView` already do in
[RootView.swift:291](Packages/ElephruitKit/Sources/ElephruitFeatures/RootView.swift#L291). Projects
becomes a **canvas** module in `ModuleLayoutPolicy` (`detail: .unavailable`) — a Kanban board cannot
live in a 340pt column. A view-tab bar sits along the top; the selected work item opens in the
**inspector drawer**, never a modal.

**Work item.** One `Item`, discriminated by kind, as ADR 0002 requires. Bugs, features and
milestones become kinds; the bug-only fields live in a satellite entity on the established
`PersonProfile` / `EventReference` pattern.

**Two orthogonal state axes.** `ItemStatus` stays the lifecycle (`open`/`completed`/`cancelled`) —
it is what Today, counts, and `taskProgress()` read, and rewriting it would break the whole app. A
**workflow stage** (board column) is a *separate*, per-project, user-configurable axis. A stage
declares a category (`backlog`/`active`/`done`/`cancelled`); moving a card into a terminal stage is
what writes `status`. This is the single most important decision here: it makes Kanban configurable
without any query in the app changing meaning.

---

## Data model — `SchemaV10` (additive, lightweight)

Per [ADR 0005](docs/adr/0005-schema-freeze-before-the-next-stage.md) and the `SchemaV9` precedent,
new entities and nullable columns migrate by inference. Version bumps to `0.0.10`
([SchemaV1.swift](Packages/ElephruitKit/Sources/ElephruitModel/SchemaV1.swift)) so the
`.schema-version` stamp triggers `PersistenceStack`'s backup. **No renames, no type changes** — so
the model-type freeze is still not triggered.

**New entities** (`ElephruitModel`):

| Entity | Holds |
|---|---|
| `WorkflowStage` | Board column: name, colour, order, `wipLimit: Int?`, `categoryRaw`, `project: Item?` |
| `ProjectViewRecord` | A configured view: name, `kindRaw`, `configurationData: Data`, order, `project: Item?` |
| `BugRecord` | Satellite on `Item`: severity, repro steps, expected, actual, environment, affected/fix version, `isRegression` |
| `ItemComment` | Body, `createdAt`, `authorID: UUID?`, `item: Item?` |
| `ItemActivity` | `at`, `kindRaw`, `field`, `oldValue`, `newValue`, `actorID`, `item: Item?` |
| `AutomationRule` | Name, `isEnabled`, JSON trigger/conditions/actions, `lastFiredAt`, `project: Item?` |
| `CustomFieldDefinition` | Name, `typeRaw`, options, order, `project: Item?` — values reuse `Item.userMetadata` |
| `InboxNotification` | `at`, `kindRaw`, `isRead`, `itemID`, `actorID`, summary |

**New `Item` attributes** (all optional or defaulted):
`referenceKey: String?` ("ELE-42") · `projectKey: String?` and `nextReferenceNumber: Int` (on the
project) · `workflowStageID: UUID?` · `boardOrder: Double` · `goalTargetValue`/`goalCurrentValue:
Double?` · `releaseVersion: String?`.

**New `ItemKind` cases:** `.bug`, `.feature`, `.milestone`, `.release`.
**New `LinkKind` cases:** `.assignee`, `.duplicateOf`, `.targetsMilestone`, `.relatesToRelease`.

### The one refactor that matters

`ItemKind` gains `isWorkItem` (`.task`, `.bug`, `.feature`). The ~15 production sites that test
`kind == .task` become `kind.isWorkItem`, so bugs and features count toward progress, appear in
Today, and flow through the scheduling model instead of silently vanishing from it. Representative
sites: [Item.swift:536,550,552](Packages/ElephruitKit/Sources/ElephruitModel/Item.swift#L536),
[ItemTask.swift:107,180](Packages/ElephruitKit/Sources/ElephruitModel/ItemTask.swift#L107),
[ItemRepository.swift:254,434,492,579](Packages/ElephruitKit/Sources/ElephruitPersistence/ItemRepository.swift#L254),
`TaskService.swift`, `TaskViewService.swift`, `PeopleService.swift`. `canContain` is widened so a
project holds headings, work items, milestones and releases; a milestone holds nothing.
`ItemFields` declares the new kinds' supported fields so `ItemValidator` keeps enforcing them.

---

## Implementation phases

Each phase ends green (`swift build`, `swift test`, `xcodebuild`) and gets its own commit.

### 1 — Model & schema
`SchemaV10`, the eight entities, the `Item` columns, the new kinds/link kinds, `isWorkItem` and its
call-site sweep, `ItemFields` declarations, `canContain` widening. Migration test extending
`RealStoreMigrationTests` proving a `V9` store opens.

### 2 — Persistence services (`ElephruitPersistence`)
`ProjectWorkspaceService` (stages, views, board moves, WIP checks, bulk edit) ·
`WorkItemService` (reference-key allocation, comments, activity, assignment, dependencies) ·
`BugService` · `ProjectTemplateService` · `AutomationEngine` · `ProjectReportingService`
(velocity, cycle time, burndown, workload) · `InboxService`. Reference keys are allocated
transactionally from `Item.nextReferenceNumber` on the project.

### 3 — Sidebar navigation *(priority 1)*
`ProjectsSidebarSection` at top level, driven by a new `ProjectsSidebarModel` that computes rows
off-render (the `SidebarModel`/`FetchAudit` contract in
[SidebarModel.swift:355](Packages/ElephruitKit/Sources/ElephruitFeatures/SidebarModel.swift#L355)
is non-negotiable — no store access while rendering). `SidebarSelection.project(id:viewID:)`,
`AppModule.displayOrder` becomes explicit and drops `.projects`, shortcut order updated.

### 4 — Project workspace shell *(priority 2)*
`ProjectWorkspaceView` in the middle column, view-tab bar with add/rename/reorder/duplicate/remove
via context menu, `ModuleLayoutPolicy` canvas layout for `.projects`, work-item inspector drawer,
`WorkItemQuickEntry` inline row (no modal), empty states, `ProjectTemplateChooser` for a new project.

### 5 — Views *(priorities 3–4)*
`KanbanBoardView` (configurable columns, swimlanes, WIP limits, drag-and-drop, collapsible groups,
quick add per column) · `WorkItemListView` (grouped, inline edit) · `WorkItemTableView`
(spreadsheet, configurable columns, inline cells) · `BugTrackerView` (severity/regression/duplicate,
bug fields shown only for bug kinds) · `ProjectCalendarView` · `RoadmapTimelineView` (milestones,
releases, dependency arrows) · `ProjectOverviewView` (goals, health, activity, progress).
Shared `WorkItemCard` / `WorkItemRow` components in `ElephruitDesign`.

### 6 — Search, filters, saved views, bulk actions *(priority 5)*
Filter/sort/group bar bound to `ProjectViewConfiguration`; saved views reuse `SavedSearch`'s
`taskFilterData` pattern; multi-select with an `AdaptiveActionBar` (component already exists);
keyboard shortcuts; project-scoped and global work-item search through the existing
`SearchCompiler` (`type:bug`, `is:blocked`, `assignee:@name`).

### 7 — Planning & reporting *(priority 6)*
Milestones and releases, measurable goals, dependency visualisation, workload/capacity, the
velocity/cycle-time/completion reports, project health summary, notification inbox.

### 8 — Automations *(priority 7)*
Trigger/condition/action values in `ElephruitCore` (pure, testable), `AutomationEngine` hooked to
repository mutation events, a rules editor in the workspace, and the five example rules from the
brief shipped as presets. Integration-ready: `AutomationAction` carries an `.external` case and
`IntegrationTarget` is declared for source control / chat / mail / calendar / docs / issue trackers
so wiring one is an added conformance, not a redesign.

### 9 — Capture *(the two named bugs)*
`CaptureParser` learns kind sigils: `#bug`, `#feature`, `#milestone` set `draft.kind` instead of
becoming ordinary tags. `CaptureService`:
- files by **link** (`fileItem`) when `canContain` is false, and by `parentID` when it is true —
  fixing `>Project` on a note;
- creates the `BugRecord`, allocates the reference key, and drops the item into the project's first
  non-terminal stage.
`QuickJotPanel` / `CaptureComposer` show the resolved destination and kind before commit, using the
existing `CaptureToken` highlight machinery.

### 10 — Sample data, polish, verification
`ProjectSampleData` alongside `TaskSampleData` — one realistic software project (board with WIP
limits, bugs at every severity, a blocked chain, a milestone, a release, an automation, comments and
activity) plus a marketing campaign and a personal plan, so every view has something true to draw.
Then: light/dark review, Reduce Motion, Increase Contrast, keyboard-only pass, narrow-window pass,
error/offline/optimistic states.

---

## Design constraints held throughout

- **No literal colours** — `SourceHygieneTests.coloursComeFromTheDesignSystem` fails the build.
  Everything through `Theme.Colors` / `Theme.Spacing` / `Theme.Text`.
- **No force unwraps, no `fatalError`, no `try!`, no singletons** — all pinned by `SourceHygieneTests`.
- Rows ask for a `Theme.Emphasis`, never a colour (`RowEmphasisTests`).
- No store access while rendering; models recompute on change (`FetchAudit`).
- Progressive disclosure: bug fields appear only for bug kinds; advanced view configuration lives
  behind a disclosure, not on the toolbar.
- Docs: `docs/30-projects-workspace-scope.md` and a record file, matching the existing numbering.

## Verification

```bash
swift build --package-path Packages/ElephruitKit
```

```bash
swift test --package-path Packages/ElephruitKit
```

```bash
xcodebuild -project Elephruit.xcodeproj -scheme Elephruit -configuration Debug build
```

Then run against a throwaway store and load sample data from **Settings ▸ Advanced ▸ Load Sample
Data**:

```bash
open -n "$(xcodebuild -project Elephruit.xcodeproj -scheme Elephruit -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}' | head -1)/Elephruit.app" --args -ElephruitDevelopmentMode -ElephruitUseTemporaryStore
```

Workflows checked on screen, in both appearances: create/rename/favourite/reorder/archive a project
from the sidebar; open a project and switch, add, rename, reorder and remove views; drag a card
across a board and watch status follow the stage category; hit a WIP limit; file a bug from Quick
Jot with `>Project #bug` and confirm the reference key, bug fields and board placement; block one
item on another and see it on the roadmap; multi-select and bulk-edit; save a view and reopen it;
fire an automation; empty states for a project with no work and a board with no columns.

## Follow-ups this pass will not close

Real integrations (GitHub, Slack, mail) — the architecture is made ready, the connectors are not
built. CloudKit sync of the new entities is CloudKit-compliant by construction but untested, since
sync has not shipped for anything yet.
