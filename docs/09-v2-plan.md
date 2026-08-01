# Elephruit v2 — navigation, search, time, calendar

The milestone-1 foundation stands. This plan keeps Core, Model, Persistence, Transfer, and the
design tokens; rebuilds the Features layer's information architecture; replaces the search engine;
and adds three domains.

Companion to `docs/01`–`08`, which remain accurate except where noted here.

---

## 1. What is kept, refactored, and rebuilt

| Layer | Verdict | Reasoning |
|---|---|---|
| `ElephruitCore` | **Keep**, extend | Pure, tested, no known defects. Adds: `TimeEntry` value types, event identity types, heading kind |
| `ElephruitModel` | **Keep**, extend | `SchemaV1` → `SchemaV2` via additive lightweight migration. No entity changes shape |
| `ElephruitPersistence` | **Keep**, fix three hot paths | Repositories and validation are sound; specific queries are not (§2) |
| `ElephruitTransfer` | **Keep**, extend | Round-trip is proven. New entities join the archive |
| `ElephruitDesign` | **Keep tokens**, rework components | Spacing/type/colour scale is fine. `InspectorRow` is broken; `ItemRow` needs an event variant |
| `ElephruitSearch` | **Replace the engine** | In-memory index cannot meet the targets. Grammar and `SearchQuery` are kept verbatim |
| `ElephruitFeatures` | **Rebuild the IA**, keep the parts | Editor bridge, quick capture, palette survive. Sidebar, list, detail, inspector are reworked |
| `ElephruitIntegrations` | **Fill in** | Protocols already exist with inert defaults; EventKit becomes a real conformance |

Nothing is thrown away. The heaviest change is the Features layer, which is the newest and least
load-bearing code in the project.

---

## 2. Critique of the current information architecture

### The sidebar is a schema browser, not a workspace

`Notes / Tasks / Projects / Areas` mirrors `ItemKind`. That is the shape of the *database*, not the
shape of a working day. It sits directly beneath `Today / Upcoming / Inbox`, which *are* workflow —
so the sidebar mixes "where I work" with "where things are filed" in one undifferentiated list, and
reads like a file browser. This is the root of the feeling the sidebar is wrong.

Additional faults:

- **Every tag is listed, flat and unbounded.** At two hundred tags the sidebar is a scroll pit.
- **No Home.** Nothing answers "what is going on".
- **Favourite is a flag with no destination.** You can mark something a favourite and never see it again.
- **No pinning**, so a project you touch forty times a day is as far away as one you touch annually.
- **Nothing is collapsible or customisable.**

### One detail view for every kind

`ItemDetailView` renders title + body + backlinks regardless of kind. A project therefore gets a note
view with a different glyph — no task list, no people, no time, no calendar context. This is the
single largest IA failure, and it is why the app currently feels like a note-taking app with extra
fields rather than a connected system. `ItemKind` discriminates *data* but not *presentation*.

### Search is a detour

`⌘⇧F` opens a modal sheet; the list column has a separate "Filter this list" doing literal substring
matching. Two mechanisms, two mental models, and the good one is behind a door.

### Inbox is wrong

`ItemQuery.inbox()` is "items with no parent", which includes top-level projects and areas. A project
is not an unfiled capture. Inbox should mean *unprocessed*, not *unparented*.

### Opening a project navigates away

Selecting `.item(id:)` replaces the whole list with that item's children, so opening a project loses
your place instead of showing you the project.

### Missing interaction primitives

No multi-select, no drag and drop, no structural undo. `⌘Z` works inside the text editor and nowhere
else — a mis-drop or a wrong retag is unrecoverable except by hand.

### Four confirmed performance defects

Each verified in the current source, not inferred:

| Defect | Location | Effect at 50k items |
|---|---|---|
| Sidebar counts do a **full store fetch** — `count(matching:)` falls back to `items(...).count` whenever a query post-filters, and both Today and Inbox post-filter | `ItemRepository.count(matching:)`, `SidebarView.count(for:)` | Two full-store materialisations **per sidebar body evaluation** |
| Search resolves hits with **one fetch per result** | `SearchService.resolveCandidates` | 500 hits = 500 round trips |
| Index warm **materialises the entire store on the main actor** | `SearchService.warmIndex` | Multi-second main-thread hang at launch |
| Wiki-link resolution **fetches every active item per new link** | `ItemRepository.itemByTitle` | Typing `[[` becomes O(n) per link |

These directly contradict the stated performance expectations and are fixed in Phases A and B.

---

## 3. Proposed sidebar and primary navigation

Three bands. Quiet, compact, collapsible, customisable.

```
╭──────────────────────────╮
│                          │   ← no header on the first band:
│  ⌂  Home                 │     this is simply where you are
│  ◎  Today            3   │
│  ▤  Upcoming             │
│  ⌵  Inbox            2   │
│                          │
│  PINNED                  │   ← appears only when non-empty
│  ◫  Q3 Product Launch    │
│  ☺  Priya Raman          │
│  ⌕  Overdue & urgent     │
│                          │
│  LIBRARY            ⌄    │   ← collapsible, remembers state
│  ✎  Notes                │
│  ◫  Projects             │
│  ⬡  Areas                │
│  ☺  People               │
│  ▦  Calendar             │
│  ⏱  Time                 │
│  #  Tags            ›    │   ← disclosure: 8 recent + "All Tags…"
│  ⌕  Saved Searches  ›    │
│                          │
│  ⌸  Archive              │
│  ⌫  Trash                │
╰──────────────────────────╯
```

**Rules that make it quiet:**

- **Counts on Today and Inbox only.** Nothing else gets a badge. A count is a prompt to act; a count
  of every note ever written is decoration.
- **Selection is a low-opacity accent fill at 6pt radius**, not a saturated full-width bar.
- **Icons are monochrome and secondary-weight**, taking the accent colour only when selected.
- **Tags and Saved Searches are disclosure groups**, showing the eight most recently used with an
  "All Tags…" row opening a proper management view. Never an unbounded flat list.
- **Archive and Trash sit at the bottom of Library**, one step quieter than the rest.
- **200pt default width**, down from 224. Minimum 180.

**Customisation** — a "Customise Sidebar…" sheet: reorder Library rows, hide the ones you do not use,
choose whether Calendar and Time are promoted to the top band. Stored in `UserDefaults` (a per-device
preference, per the storage matrix), not in the library.

**Pinning** — any project, note, person, or saved search can be pinned. This is what `isPinned`
should have meant all along; today it only changes a font weight.

**Layout modes:**

| Mode | Shortcut | Columns |
|---|---|---|
| Full | `⌘⌃S` toggles sidebar | sidebar · list · detail |
| Two-pane | sidebar hidden | list · detail |
| Focus | `⌘⌥F` | detail only, centred, max 720pt measure |

**Inspector fix.** Replace the fixed 78pt label column with a layout that adapts: label-above-control
below ~300pt, label-beside-control above it. The three-way status control becomes a menu picker below
the breakpoint rather than a segmented control that cannot fit. No control may clip at the 240pt
minimum — enforced by a snapshot test at 240, 280, and 380pt.

---

## 4. Text wireframes

### Today

A calm working surface. Events and tasks are distinguished by *shape*, not by a badge: events have a
time gutter and no checkbox; tasks have a checkbox and no gutter.

```
┌────────────┬────────────────────────────────────────────────────────┐
│ ⌂ Home     │  Wednesday, 30 July                    ⏱ 2:14  ▸       │
│ ◎ Today  3 │  ────────────────────────────────────────────────────  │
│ ▤ Upcoming │                                                        │
│ ⌵ Inbox  2 │  NOW                                                   │
│            │  10:00 │ Design review                     Work        │
│ PINNED     │        │ ⏱ Drafting the brief · Q3 Launch   1:12  ⏸    │
│ ◫ Q3 Laun… │                                                        │
│ ☺ Priya R… │  OVERDUE                                               │
│            │  ○  Send pricing table to Priya      4d ago · Q3 Launch │
│ LIBRARY ⌄  │                                                        │
│ ✎ Notes    │  TODAY                                                 │
│ ◫ Projects │  ○  Draft the announcement                  Q3 Launch  │
│ ⬡ Areas    │  ○  Weekly review                             repeats  │
│ ☺ People   │  14:00 │ 1:1 with Sarah                    Personal    │
│ ▦ Calendar │                                                        │
│ ⏱ Time     │  DAILY NOTE                                            │
│ # Tags   › │  ┌──────────────────────────────────────────────────┐  │
│ ⌕ Saved  › │  │ Pricing conversation went better than expected…  │  │
│            │  └──────────────────────────────────────────────────┘  │
│ ⌸ Archive  │                                                        │
│ ⌫ Trash    │  ⌄ Done today (4)                                      │
└────────────┴────────────────────────────────────────────────────────┘
```

No cards, no dashboard tiles, no progress rings. Section labels are small caps in secondary colour.
"Done today" is collapsed by default — a quiet review, not a scoreboard.

### Search — the list becomes the results

`⌘F` focuses the search field above the list. Typing transforms the list in place. `Escape` restores
the previous context, selection intact.

```
┌────────────┬──────────────────────────────────┬─────────────────────┐
│ …sidebar…  │ ⌕ launch type:task is:open    ⊗ │  Draft the launch   │
│            │ ──────────────────────────────── │  announcement       │
│            │ 12 results in 3 kinds   ⌘S save │                     │
│            │                                  │  Q3 Product Launch  │
│            │ TASKS 4                          │  due today · #work  │
│            │ ○ Draft the ⟦launch⟧ announce…  │  ─────────────────  │
│            │   Q3 Product Launch · due today │                     │
│            │ ○ ⟦Launch⟧ checklist review     │  Tone: matter-of-   │
│            │   Q3 Product Launch             │  fact. Reference    │
│            │                                  │  [[Positioning]].   │
│            │ NOTES 6                          │                     │
│            │ ✎ Positioning Notes              │                     │
│            │   "…how this ⟦launch⟧ lands in  │                     │
│            │    the announcement…"           │                     │
│            │                                  │                     │
│            │ PEOPLE 2                         │                     │
│            │ ☺ Priya Raman  · 3 open items   │                     │
└────────────┴──────────────────────────────────┴─────────────────────┘
```

`↑`/`↓` move through results across group boundaries; `↩` opens in the detail pane *without leaving
search*, so you can walk a result set. `⌘S` saves the query. An unrecognised operator appears as an
amber line beneath the field — never silently dropped.

While the index is still building, the header reads `12 results · still indexing 34,000 of 51,200`
rather than showing a false empty state.

### Note

```
│  Positioning Notes                                      ★  ⓘ  │
│  Q3 Product Launch · #work #writing · edited 2h ago           │
│  ───────────────────────────────────────────────────────────  │
│                                                               │
│  The pitch is *less bookkeeping*, not *more features*.        │
│                                                               │
│  Three things people actually say:                            │
│                                                               │
│  1. "I have the same list in four places."                    │
│  2. "I know I wrote it down somewhere."                       │
│                                                               │
│  See [[Q3 Product Launch]] for how this lands.                │
│                                                               │
│  ───────────────────────────────────────────────────────────  │
│  ⌄ Linked from 3    ⌄ Attachments 1    ⌄ Time 0:45           │
```

The body is the view. One metadata line above, three collapsed disclosure rows below. Nothing else
competes.

### Project

Headings become a real grouping inside a project.

```
│  ◫ Q3 Product Launch                                    ★  ⓘ  │
│  Work · due in 24 days · 4 of 9 · ⏱ 6:20 of 20:00 est         │
│  ───────────────────────────────────────────────────────────  │
│  Ship pricing page and announcement by quarter end.           │
│                                                               │
│  All   Errand   Important                        ⏱ Start ▸    │
│                                                               │
│  Planning                                                 ⋯   │
│  ○  Add trip dates to calendar                                │
│  ○  Book flights                                              │
│  ○  Read about the metro                              ✎       │
│                                                               │
│  Items to buy                                             ⋯   │
│  ○  Extra camera battery                    #errand           │
│  ○  Power adapter                           #errand           │
│                                                               │
│  ⌄ Notes 3   ⌄ People 2   ⌄ Meetings 1   ⌄ Time 6:20         │
```

Tag chips along the top filter the task list in place. Dragging a heading moves its whole group.
Archiving a heading archives its tasks with it — free, because headings use the existing containment
cascade.

### Person

Personal, not sales software. The notes you keep about someone are the main surface.

```
│  ☺ Priya Raman                                          ★  ⓘ  │
│  Head of Product · Northwind · priya@example.com               │
│  ───────────────────────────────────────────────────────────  │
│  Prefers written proposals ahead of meetings. Two kids.        │
│  Was at Acme before — knows the pricing history there.         │
│                                                               │
│  OPEN WITH PRIYA                                          2   │
│  ○  Send pricing table                          overdue 4d    │
│  ○  Agree the launch date                                     │
│                                                               │
│  RECENT                                                       │
│  ▦  14 Jul   Design review                          meeting   │
│  ✎  02 Jul   Positioning Notes                    mentioned   │
│  ✉  28 Jun   Pricing thread                     interaction   │
│                                                               │
│  ⌄ Projects 2   ⌄ Full history   + Log an interaction        │
```

No pipeline, no last-contacted nag by default. A per-person opt-in "remind me if we haven't spoken in
N weeks" exists and is off unless you set it.

### Calendar

```
│  ▦ Calendar          Day  [Week]  Month              Today    │
│  ───────────────────────────────────────────────────────────  │
│        Mon 28   Tue 29   Wed 30   Thu 31   Fri 01             │
│  09    ░░░░░░                                                 │
│  10             ▓▓▓▓▓▓   ▓▓▓▓▓▓                               │
│  11                      Design                               │
│  12    ────────────────── lunch ──────────────────            │
│  13                                        ▓▓▓▓▓▓             │
│  14    ▓▓▓▓▓▓            1:1 Sarah                            │
│  ───────────────────────────────────────────────────────────  │
│  Unscheduled this week: 7 tasks                          ▸    │
```

Selecting an event opens a detail pane showing the event's own fields (read-only, sourced live from
EventKit) plus *our* additions: linked notes, linked people, follow-up tasks, tracked time. Two
buttons: **New follow-up task** and **Track time on this**.

Declined events are hidden by default. Cancelled events appear struck through until dismissed. All-day
events sit in a band above the grid. A recurring occurrence shows "part of a series" with the rule.

### Time report

```
│  ⏱ Time              [Week]  Month  Project  Tag              │
│  22 – 28 July                                  Total 18:42    │
│  ───────────────────────────────────────────────────────────  │
│  Mon  ████████████░░░░░░░░  3:20                              │
│  Tue  ███████████████░░░░░  4:05                              │
│  Wed  ██████░░░░░░░░░░░░░░  1:45                              │
│  Thu  ██████████████████░░  5:12                              │
│  Fri  ███████████░░░░░░░░░  3:00                              │
│  ───────────────────────────────────────────────────────────  │
│  BY PROJECT                                                   │
│  Q3 Product Launch        8:15    of 20:00 est    ████░░░░░   │
│  Database migration       4:30    no estimate                 │
│  Unassigned               2:12                                │
│  ───────────────────────────────────────────────────────────  │
│  ENTRIES                                                      │
│  Wed  09:12 – 10:24   Drafting the brief    Q3 Launch   1:12  │
│  Wed  11:00 – 11:33   Standup               —           0:33  │
```

Bars are plain rules, not a charting library. Entries are editable inline — click a time to change it.

---

## 5. Data model changes

`SchemaV2`, reached by an additive lightweight migration. No existing entity changes shape, so no
custom migration stage is required — but the stage is still declared and tested per the rules in
`docs/05`.

### New: `TimeEntry`

Deliberately **not** an `Item`. A time entry has no title, no body, no children, is not linkable, and
you will accumulate hundreds of thousands. Making it an `Item` would flood the Inbox, the search
index, and every list. This is the first considered exception to "everything is an Item", and it is
the right one.

```
TimeEntry
  id: UUID
  startedAt: Date
  endedAt: Date?                 ← nil means running
  entryDescription: String
  isBillable: Bool = false
  rateMinorUnits: Int?           ← designed for, unused in v1
  currencyCode: String?
  sourceRaw: String              ← timer | manual | imported
  lastHeartbeatAt: Date?         ← crash and sleep recovery
  createdAt, updatedAt, deletedAt

  item: Item?                    ← task, project, note, person, or meeting
  tags: [Tag]
```

**Invariant: at most one entry with `endedAt == nil`.** Enforced in `TimeEntryRepository`, tested, and
indexed with `#Index([\.endedAt])` so "is anything running?" is O(1).

**Crash, sleep, and abandonment.** The running timer writes `lastHeartbeatAt` every 30 seconds, and on
`NSWorkspace.willSleepNotification`. At launch, if a running entry's heartbeat is older than five
minutes, the app offers three choices and picks none of them itself:

> A timer for *Drafting the brief* was running when Everything last quit, 3 hours ago.
> **Stop it at 14:22** (last activity) · **Keep it running** · **Discard the entry**

**Two devices, two running timers.** Last-writer-wins would destroy an entry. The merge rule: close
the earlier-started entry at the later one's start, keep both. Nothing is ever deleted by a merge.

**Reports.** No rollup table in v1. A week report touches a few hundred rows and a year-by-project
report a few tens of thousands — both fast in Swift over a date-bounded fetch. A `TimeDayRollup`
derived cache is designed for but built **only if measurement demands it**.

### Changed: `EventReference`

The existing entity gains the fields that make recurring events survivable:

```
+ calendarIdentifier: String?
+ externalIdentifier: String?      ← EKEvent.calendarItemExternalIdentifier
+ occurrenceDate: Date?            ← disambiguates one occurrence of a series
+ statusRaw: String                ← confirmed | tentative | cancelled
+ participationRaw: String         ← accepted | declined | tentative | pending
+ isDetached: Bool                 ← this occurrence was edited away from the series
+ isAllDay: Bool                   (exists)
```

**The trap being avoided:** `EKEvent.eventIdentifier` is not unique per occurrence of a recurring
event. Identity must be `externalIdentifier` + `occurrenceDate`, or links attach to the wrong
occurrence and break when the series is edited. This is called out because it is the single most
common EventKit defect.

**Nothing of the event's content is copied.** We store identity, a minimal cache for offline display,
and *our own* links. EventKit remains authoritative; the cache is refreshed, never merged.

### Changed: `Item`

```
+ estimatedMinutes: Int?           ← projects and tasks; drives estimate vs actual
+ ItemKind.heading                 ← new kind
```

`ItemKind.heading` may only exist inside a project and may contain tasks. It has a title, children,
and sort order — nothing else. Modelling it as a kind rather than as a string field on each task means
drag-to-reorder, archive-cascade, and trash-restore all work on headings with no new code.

### Changed: `PersonProfile`

```
+ relationshipsData: Data?         ← [(personID, label)] — "reports to", "partner of"
+ lastInteractionAt: Date?         ← maintained on write, for Recent ordering
+ nudgeAfterDays: Int?             ← opt-in, nil by default
```

### Changed: `ItemQuery`

`inbox()` becomes *unprocessed captures*: no parent, no tags, and not a container kind. A project is
never in the Inbox.

---

## 6. Search architecture

### Replace the engine, keep the grammar

`SearchQuery` and `SearchQueryParser` are good and stay verbatim. `SearchIndex` and the resolution
path are replaced by an **SQLite FTS5 sidecar**.

SwiftData cannot express FTS5, so the index lives in its own SQLite file opened through the system
`SQLite3` module — a system library, not a third-party dependency. It remains **derived and
rebuildable**: deleting it loses nothing.

```sql
CREATE VIRTUAL TABLE documents USING fts5(
    title, body, tags, container, people,
    tokenize = 'unicode61 remove_diacritics 2',
    prefix   = '2 3 4'
);

-- Substring and near-miss matching. "aunch" finds "launch"; so does "laucnh".
CREATE VIRTUAL TABLE documents_trigram USING fts5(
    title, body, tokenize = 'trigram'
);

-- Structural filters run in SQL, not in Swift over materialised objects.
CREATE TABLE meta (
    item_id TEXT PRIMARY KEY, rowid INTEGER, kind TEXT, status TEXT,
    is_favorite INT, is_pinned INT, is_archived INT, is_trashed INT,
    due_at REAL, created_at REAL, updated_at REAL,
    container_id TEXT, title TEXT
);
CREATE INDEX meta_kind_status ON meta(kind, status, is_trashed);
CREATE INDEX meta_due ON meta(due_at);
```

**Ranking:** `bm25(documents, 10.0, 1.0, 3.0, 2.0, 2.0)` — title weighted ten times body, tags three
times. Then post-weights: exact title match, pinned, recency decay over `updated_at`, penalty for
completed and archived.

**Excerpts:** FTS5's own `snippet()`, so highlighting comes from the same engine that did the match
rather than a second pass that can disagree with it.

**The fix for one-fetch-per-result:** query results carry title, kind, snippet, and dates directly
from SQLite. The result list renders with **zero** SwiftData fetches. An `Item` is materialised only
when a result is selected.

**Index maintenance:**

- Incremental upsert of one row on every save.
- Full rebuild on a `@ModelActor`, streamed in batches with `fetchLimit` and offset — never
  materialising the whole store, never on the main actor.
- A generation counter and item-count checksum in the sidecar; on launch a mismatch triggers a
  background rebuild while queries continue to serve from the existing index.
- **No false empty states.** The index reports `isReady` plus progress. While rebuilding, results
  come from whatever is indexed and the header says so.

### Measurable targets

Verified by a benchmark suite that **fails the build** when exceeded, against a generated corpus of
50,000 notes and tasks, 5,000 people, 2,000 projects, 200,000 time entries, and 30,000 events. Text is
generated by a Markov chain over sample prose so term frequencies are realistic — an index over
"Item 1…Item 50000" proves nothing.

| Measurement | Target | Instrument |
|---|---|---|
| Keystroke → results painted, 50k items | **< 40 ms p95** | `OSSignposter` around query + render |
| Keystroke → results painted, 200k items | < 80 ms p95 | same |
| Cold launch → window interactive | < 400 ms | signpost |
| Cold launch → index queryable (existing index) | < 150 ms | signpost |
| Full index rebuild, 50k items | < 6 s, main thread never blocked > 16 ms | signpost + hang detection |
| Sidebar render including counts | < 5 ms | signpost |
| Today view load | < 30 ms | signpost |
| Week time report over 200k entries | < 50 ms | signpost |
| Resident memory, 200k items indexed | < 150 MB | `task_info` sample |

---

## 7. Phased plan

Each phase leaves the app shippable, warning-free, and green.

### Phase A — Shell, navigation, inspector

*No new domains. This is the phase that fixes the feel.*

- New sidebar IA, collapsible groups, pinning, customisation sheet
- **Fix the sidebar count bug** — cached counts maintained on write, not full fetches
- Adaptive inspector layout
- Per-kind detail views: project, person, and note become genuinely different surfaces
- Two-pane and focus layout modes
- Multi-select and batch actions
- **Structural undo** via `UndoManager` in the repository layer: move, delete, retag, status
- Fix `itemByTitle` to use the index rather than a full fetch

**Acceptance:** sidebar renders in < 5 ms against 50k items · no inspector control clips at 240, 280,
or 380pt (snapshot-tested) · `⌘Z` reverses a move, a delete, a retag, and a status change · a project
opens as a project without losing the list · Inbox contains no projects or areas.

### Phase B — Universal search

- FTS5 sidecar, incremental maintenance, background rebuild
- Inline search replacing the list; `Escape` restores context and selection
- `person:` operator added; unrecognised operators surfaced in amber
- Save from the search bar; saved searches pinnable
- Palette retained for navigation and commands

**Acceptance:** every figure in the table above, enforced by a failing benchmark · a query mid-rebuild
shows partial results and progress, never a false empty state · deleting the sidecar and relaunching
loses nothing.

### Phase C — Time tracking

- `TimeEntry`, single-running invariant, heartbeat recovery
- `MenuBarExtra` timer
- Start/stop from a task, project, event, or the palette
- Manual entry, inline editing, continue previous
- Day / week / project / tag summaries; estimate vs actual

**Acceptance:** `kill -9` mid-timer then relaunch offers the three-way recovery · a second timer
cannot start while one runs · sleeping for an hour and waking offers the gap · week report < 50 ms
over 200k entries.

### Phase D — Calendar, read-only

*APIs, entitlements, and permission strings verified against current Apple documentation before
implementation, not from memory.*

- EventKit behind the existing `CalendarProviding` protocol, off until enabled
- Events in Today and Upcoming, visually distinct by shape
- Event ↔ note, task, person links keyed on external identifier + occurrence date
- Declined hidden, cancelled struck through, all-day banded, recurring labelled
- `EKEventStoreChanged` drives refresh

**Acceptance:** linking to one occurrence of a recurring event survives a series edit · revoking
permission in System Settings degrades to a clear explained state, not a crash · no write to any
calendar occurs — asserted by a test double that fails if a write is attempted.

### Phase E — People and daily context

Person workspace · interactions · daily notes · Home view · opt-in follow-up nudges.

### Phase F — Polish

Global quick capture · attachments · drag and drop throughout · headings in projects.

---

## 8. Decisions requiring input

See the chat summary; recorded here once answered.
